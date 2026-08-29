package com.falai.transfer.transfer

import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.os.Build
import android.os.PowerManager
import android.os.SystemClock
import androidx.core.content.ContextCompat
import com.falai.transfer.core.summarizeFiles
import com.falai.transfer.data.LogRepository
import com.falai.transfer.data.TransferLog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.File
import java.net.Socket
import java.security.MessageDigest

/**
 * 传输编排：常驻服务端（端口自动后移）、客户端发送、暂停/继续、取消即断连、
 * 网络断开容错、白名单免确认、前台服务与 WakeLock、传输日志。
 */
class TransferManager private constructor(private val context: Context) {
    companion object {
        @Volatile
        private var instance: TransferManager? = null

        fun get(context: Context): TransferManager = instance ?: synchronized(this) {
            instance ?: TransferManager(context.applicationContext).also { instance = it }
        }
    }

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val prefs = context.getSharedPreferences("falai", Context.MODE_PRIVATE)

    private val _progress = MutableStateFlow(TransferProgress())
    val progress: StateFlow<TransferProgress> = _progress.asStateFlow()

    private val _incoming = MutableStateFlow<IncomingRequest?>(null)
    val incoming: StateFlow<IncomingRequest?> = _incoming.asStateFlow()

    private val _whitelist = MutableStateFlow<Set<String>>(emptySet())
    val whitelist: StateFlow<Set<String>> = _whitelist.asStateFlow()

    var deviceName: String
        get() = prefs.getString("deviceName", null)?.takeIf { it.isNotBlank() }
            ?: (Build.MODEL ?: "Android")
        set(v) = prefs.edit().putString("deviceName", v).apply()

    private val server = TransferServer(context, ServerEvents())

    /** 服务端实际绑定端口（47801 起自动后移），广播时携带 */
    val serverPort: Int
        get() = server.boundPort

    @Volatile
    private var active = false

    @Volatile
    private var canceled = false

    @Volatile
    private var paused = false

    @Volatile
    private var cancelReason: String? = null

    @Volatile
    private var clientSocket: Socket? = null

    private var pendingResponder: ((Boolean) -> Unit)? = null
    private var pendingRequest: IncomingRequest? = null
    private var transferStartTime = 0L
    private var speedJob: Job? = null
    private var lastProgressPush = 0L
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    private val wakeLock: PowerManager.WakeLock by lazy {
        (context.getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "falai:transfer")
            .apply { setReferenceCounted(false) }
    }

    fun start() {
        _whitelist.value = prefs.getStringSet("whitelist", emptySet())?.toSet() ?: emptySet()
        server.start()
        cleanupStaleIncoming()
        watchNetwork()
    }

    // ---------- 发送 ----------

    fun sendFiles(ip: String, port: Int, peerName: String, files: List<ResolvedFile>) {
        if (active || files.isEmpty()) return
        scope.launch {
            val total = files.sumOf { it.size }
            // 同一批文件（同名同大小）发给同一设备 → 相同 transferId → 自动断点续传
            val transferId = deriveTransferId(ip, files)
            begin(Direction.SEND, peerName, files.size, total)
            try {
                TransferClient.send(
                    context, ip, port, transferId, deviceName, files,
                    isCanceled = { canceled },
                    isPaused = { paused },
                    onWaitingAccept = {
                        _progress.update { it.copy(status = TransferStatus.WAITING) }
                    },
                    onProgress = { name, idx, transferred ->
                        pushProgress(name, idx, files.size, transferred)
                    },
                    onSocket = { clientSocket = it },
                )
                finish(success = true, result = "成功", error = null)
                LogRepository.add(makeLog(true, peerName, files.map { it.name }, total, true, "成功", null))
            } catch (e: TransferClient.RejectedException) {
                finish(success = false, result = "对方拒绝", error = e.message, rejected = true)
                LogRepository.add(makeLog(true, peerName, files.map { it.name }, total, false, "对方拒绝", null))
            } catch (e: Exception) {
                val result = cancelReason ?: if (canceled) "已取消" else "失败: ${e.message ?: "未知错误"}"
                finish(success = false, result = result, error = e.message)
                LogRepository.add(makeLog(true, peerName, files.map { it.name }, total, false, result, null))
            } finally {
                files.forEach { it.tempFile?.delete() }
            }
        }
    }

    private fun deriveTransferId(ip: String, files: List<ResolvedFile>): String {
        val raw = ip + files.joinToString("|") { "${it.name}:${it.size}" }
        val md5 = MessageDigest.getInstance("MD5").digest(raw.toByteArray())
        return "t" + md5.joinToString("") { "%02x".format(it) }.take(16)
    }

    // ---------- 接收 ----------

    fun respondIncoming(accept: Boolean, trust: Boolean) {
        val req = pendingRequest
        if (trust && req != null) addToWhitelist(req.fromIp)
        _incoming.value = null
        val responder = pendingResponder
        pendingResponder = null
        pendingRequest = null
        if (!accept && req != null) {
            LogRepository.add(
                TransferLog(
                    timeMillis = System.currentTimeMillis(),
                    outgoing = false,
                    peerName = req.fromName,
                    fileSummary = "${req.fileCount} 个文件",
                    sizeBytes = req.totalBytes,
                    success = false,
                    resultText = "已拒绝",
                    durationMs = 0,
                    avgSpeedBps = 0.0,
                    fileCount = req.fileCount,
                )
            )
        }
        responder?.invoke(accept)
    }

    // ---------- 暂停 / 继续 / 取消 ----------

    fun pauseTransfer() {
        if (!active || _progress.value.direction != Direction.SEND) return
        paused = true
        _progress.update { it.copy(status = TransferStatus.PAUSED, speedBps = 0.0, etaSeconds = 0) }
    }

    fun resumeTransfer() {
        if (!paused) return
        paused = false
        _progress.update { it.copy(status = TransferStatus.TRANSFERRING) }
    }

    fun cancelTransfer(reason: String? = null) {
        cancelReason = reason
        canceled = true
        paused = false
        try {
            clientSocket?.close()
        } catch (_: Exception) {
        }
        server.cancelSessions()
    }

    fun dismissProgress() {
        if (!_progress.value.active) _progress.value = TransferProgress()
    }

    // ---------- 白名单 ----------

    fun addToWhitelist(ip: String) {
        if (ip.isBlank()) return
        val set = _whitelist.value + ip
        _whitelist.value = set
        prefs.edit().putStringSet("whitelist", set).apply()
    }

    fun removeFromWhitelist(ip: String) {
        val set = _whitelist.value - ip
        _whitelist.value = set
        prefs.edit().putStringSet("whitelist", set).apply()
    }

    // ---------- 内部 ----------

    private fun begin(direction: Direction, peer: String, fileCount: Int, total: Long) {
        active = true
        canceled = false
        paused = false
        cancelReason = null
        transferStartTime = System.currentTimeMillis()
        _progress.value = TransferProgress(
            show = true,
            active = true,
            direction = direction,
            peerName = peer,
            status = TransferStatus.TRANSFERRING,
            fileCount = fileCount,
            totalBytes = total,
        )
        startForegroundAndLock()
        startSpeedJob()
    }

    private fun finish(success: Boolean, result: String, error: String?, rejected: Boolean = false) {
        speedJob?.cancel()
        speedJob = null
        stopForegroundAndLock()
        active = false
        paused = false
        _progress.update {
            it.copy(
                active = false,
                status = when {
                    success -> TransferStatus.DONE
                    rejected -> TransferStatus.REJECTED
                    canceled && cancelReason == null -> TransferStatus.CANCELED
                    else -> TransferStatus.FAILED
                },
                error = error,
                speedBps = 0.0,
                etaSeconds = 0,
            )
        }
    }

    private fun pushProgress(name: String, idx: Int, count: Int, transferred: Long) {
        // 100ms 节流，避免每 32KB 触发一次 UI 重组
        val now = SystemClock.elapsedRealtime()
        if (now - lastProgressPush < 100 && transferred < _progress.value.totalBytes) return
        lastProgressPush = now
        _progress.update {
            it.copy(
                currentFile = name,
                fileIndex = idx + 1,
                fileCount = count,
                transferredBytes = transferred,
                status = if (paused) TransferStatus.PAUSED else TransferStatus.TRANSFERRING,
            )
        }
    }

    private fun startSpeedJob() {
        speedJob?.cancel()
        speedJob = scope.launch {
            var lastBytes = 0L
            var lastTime = SystemClock.elapsedRealtime()
            while (isActive) {
                delay(500)
                val p = _progress.value
                val now = SystemClock.elapsedRealtime()
                val dt = (now - lastTime) / 1000.0
                if (dt > 0 && !paused) {
                    val speed = (p.transferredBytes - lastBytes) / dt
                    val eta = if (speed > 1) ((p.totalBytes - p.transferredBytes) / speed).toLong() else 0
                    _progress.update { it.copy(speedBps = speed.coerceAtLeast(0.0), etaSeconds = eta.coerceAtLeast(0)) }
                }
                lastBytes = p.transferredBytes
                lastTime = now
            }
        }
    }

    private fun makeLog(
        outgoing: Boolean, peer: String, files: List<String>, total: Long,
        success: Boolean, result: String, contentUri: String?,
    ): TransferLog {
        val duration = System.currentTimeMillis() - transferStartTime
        return TransferLog(
            timeMillis = System.currentTimeMillis(),
            outgoing = outgoing,
            peerName = peer,
            fileSummary = summarizeFiles(files),
            sizeBytes = total,
            success = success,
            resultText = result,
            durationMs = duration,
            avgSpeedBps = if (duration > 0 && success) total / (duration / 1000.0) else 0.0,
            contentUri = contentUri,
            fileCount = files.size,
        )
    }

    private fun cleanupStaleIncoming() {
        scope.launch {
            try {
                val dir = File(context.cacheDir, "incoming")
                val cutoff = System.currentTimeMillis() - 24 * 3600 * 1000L
                dir.listFiles()?.filter { it.lastModified() < cutoff }?.forEach { it.delete() }
            } catch (_: Exception) {
            }
        }
    }

    private fun watchNetwork() {
        if (networkCallback != null) return
        try {
            val cm = context.getSystemService(ConnectivityManager::class.java) ?: return
            val cb = object : ConnectivityManager.NetworkCallback() {
                override fun onLost(network: Network) {
                    // WiFi 断开/切换到移动网络：进行中的传输立即判失败，临时文件保留可续传
                    if (active) cancelTransfer("网络已断开或切换")
                }
            }
            cm.registerDefaultNetworkCallback(cb)
            networkCallback = cb
        } catch (_: Exception) {
        }
    }

    private fun startForegroundAndLock() {
        try {
            ContextCompat.startForegroundService(context, Intent(context, TransferService::class.java))
        } catch (_: Exception) {
        }
        try {
            if (!wakeLock.isHeld) wakeLock.acquire(30 * 60 * 1000L)
        } catch (_: Exception) {
        }
    }

    private fun stopForegroundAndLock() {
        try {
            context.stopService(Intent(context, TransferService::class.java))
        } catch (_: Exception) {
        }
        try {
            if (wakeLock.isHeld) wakeLock.release()
        } catch (_: Exception) {
        }
    }

    private inner class ServerEvents : TransferServer.Events {
        override fun decide(request: IncomingRequest, callback: (Boolean) -> Unit) {
            if (request.fromIp in _whitelist.value) {
                callback(true)   // 白名单设备免确认
                return
            }
            pendingRequest = request
            pendingResponder = callback
            _incoming.value = request
        }

        override fun onReceiveBegin(peerName: String, fileCount: Int, totalBytes: Long, resumedBytes: Long) {
            begin(Direction.RECEIVE, peerName, fileCount, totalBytes)
            if (resumedBytes > 0) {
                _progress.update { it.copy(transferredBytes = resumedBytes) }
            }
        }

        override fun onProgress(fileName: String, fileIndex: Int, fileCount: Int, transferredBytes: Long) {
            pushProgress(fileName, fileIndex, fileCount, transferredBytes)
        }

        override fun onFinished(
            peerName: String, fileNames: List<String>, totalBytes: Long,
            success: Boolean, error: String?, needLog: Boolean, savedUri: String?,
        ) {
            if (!needLog) return
            val result = when {
                success -> "成功"
                cancelReason != null -> cancelReason!!
                canceled -> "已取消"
                else -> "失败: ${error ?: "未知错误"}"
            }
            finish(success, result, error)
            LogRepository.add(makeLog(false, peerName, fileNames, totalBytes, success, result, savedUri))
        }

        override fun isBusy(): Boolean = active
        override fun isCanceled(): Boolean = canceled
    }
}
