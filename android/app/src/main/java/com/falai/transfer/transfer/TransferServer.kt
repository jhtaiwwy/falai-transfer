package com.falai.transfer.transfer

import android.content.Context
import com.falai.transfer.core.Protocol
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.IOException
import java.net.BindException
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import kotlin.concurrent.thread

/**
 * 常驻 TCP 服务：端口占用时自动后移（47801~47811）；收到请求头后交由上层决定
 * 接受/拒绝（白名单自动接受）；接收先写临时 .part 文件，收满后导入相册/下载目录，
 * 相同 transferId 重连时返回各文件 offset 实现断点续传。
 */
class TransferServer(
    private val context: Context,
    private val events: Events,
) {
    interface Events {
        /** 收到传输请求；通过 callback 异步返回是否接受（可能在等待用户点弹窗） */
        fun decide(request: IncomingRequest, callback: (Boolean) -> Unit)

        /** 接受请求后回调，用于开始进度展示；resumedBytes 为断点续传已接收字节 */
        fun onReceiveBegin(peerName: String, fileCount: Int, totalBytes: Long, resumedBytes: Long)

        fun onProgress(fileName: String, fileIndex: Int, fileCount: Int, transferredBytes: Long)

        /** 一次会话结束（无论成败）。只有接受过的会话 needLog=true；savedUri 为接收成功时首个文件的落点 */
        fun onFinished(peerName: String, fileNames: List<String>, totalBytes: Long, success: Boolean, error: String?, needLog: Boolean, savedUri: String?)

        fun isBusy(): Boolean
        fun isCanceled(): Boolean
    }

    @Volatile
    var boundPort: Int = 0
        private set

    @Volatile
    private var running = false

    private val sessions = ConcurrentHashMap.newKeySet<Socket>()

    /** 端口从 47801 起依次尝试绑定，返回实际端口；全部占用返回 false */
    fun start(): Boolean {
        if (running) return boundPort > 0
        for (port in Protocol.TRANSFER_PORT..Protocol.TRANSFER_PORT + 10) {
            try {
                val ss = ServerSocket(port)
                boundPort = port
                running = true
                thread(name = "transfer-server", isDaemon = true) { loop(ss) }
                return true
            } catch (_: BindException) {
                continue
            } catch (_: Exception) {
                return false
            }
        }
        return false
    }

    fun stop() {
        running = false
        cancelSessions()
    }

    /** 取消进行中的接收会话（关闭 socket 使阻塞的 read 立即退出） */
    fun cancelSessions() {
        sessions.forEach {
            try {
                it.close()
            } catch (_: Exception) {
            }
        }
    }

    private fun loop(ss: ServerSocket) {
        try {
            while (running) {
                val socket = try {
                    ss.accept()
                } catch (_: Exception) {
                    break
                }
                thread(name = "transfer-session", isDaemon = true) { handle(socket) }
            }
        } catch (_: Exception) {
        } finally {
            try {
                ss.close()
            } catch (_: Exception) {
            }
        }
    }

    // ---------- 断点续传会话存储 ----------

    private fun sessionDir(): File = File(context.cacheDir, "incoming").apply { mkdirs() }

    private fun sanitizeTid(tid: String) = tid.replace(Regex("[^A-Za-z0-9_-]"), "").ifBlank { "x" }

    private fun metaFile(tid: String) = File(sessionDir(), "$tid.json")

    private fun partFile(tid: String, index: Int) = File(sessionDir(), "${tid}_$index.part")

    /** 计算各文件已接收字节：会话元信息与本次请求一致时取 .part 长度，否则清掉旧会话 */
    private fun computeOffsets(tid: String, files: List<Pair<String, Long>>): LongArray {
        val offsets = LongArray(files.size)
        val mf = metaFile(tid)
        try {
            if (mf.exists()) {
                val arr = JSONObject(mf.readText()).getJSONArray("files")
                val match = arr.length() == files.size && (0 until arr.length()).all { i ->
                    val o = arr.getJSONObject(i)
                    o.optString("name") == files[i].first && o.optLong("size") == files[i].second
                }
                if (match) {
                    for (i in files.indices) {
                        val part = partFile(tid, i)
                        if (part.exists()) offsets[i] = part.length().coerceAtMost(files[i].second)
                    }
                    return offsets
                }
            }
        } catch (_: Exception) {
        }
        // 会话信息不匹配：清理旧临时文件
        sessionDir().listFiles()?.filter { it.name.startsWith("${tid}_") || it.name == "$tid.json" }
            ?.forEach { it.delete() }
        return offsets
    }

    private fun saveSessionMeta(tid: String, files: List<Pair<String, Long>>) {
        try {
            val arr = JSONArray()
            files.forEach { arr.put(JSONObject().put("name", it.first).put("size", it.second)) }
            metaFile(tid).writeText(JSONObject().put("files", arr).toString())
        } catch (_: Exception) {
        }
    }

    // ---------- 会话处理 ----------

    private fun handle(socket: Socket) {
        sessions.add(socket)
        var peerName = socket.inetAddress?.hostAddress ?: "未知设备"
        val fileNames = mutableListOf<String>()
        var total = 0L
        var success = false
        var error: String? = null
        var needLog = false
        var savedUri: String? = null
        try {
            socket.soTimeout = 30_000
            val input = DataInputStream(BufferedInputStream(socket.getInputStream(), Protocol.BUFFER_SIZE))
            val out = DataOutputStream(BufferedOutputStream(socket.getOutputStream(), Protocol.BUFFER_SIZE))

            val header = Protocol.readJson(input)
            if (header.optString("app") != Protocol.APP_ID) return
            peerName = header.optString("from", peerName)
            total = header.optLong("total", 0)
            val tid = sanitizeTid(header.optString("transferId", "legacy"))
            val filesArr = header.getJSONArray("files")
            val files = (0 until filesArr.length()).map {
                val o = filesArr.getJSONObject(it)
                File(o.optString("name", "file_$it")).name to o.optLong("size", 0)
            }
            val fromIp = socket.inetAddress?.hostAddress ?: ""

            if (events.isBusy()) {
                Protocol.writeJson(out, JSONObject().put("status", Protocol.RESP_REJECT))
                return
            }

            var decided = false
            var accepted = false
            events.decide(IncomingRequest(System.currentTimeMillis(), peerName, fromIp, files.size, total)) { a ->
                accepted = a
                decided = true
            }
            val deadline = System.currentTimeMillis() + 110_000
            while (!decided && System.currentTimeMillis() < deadline) Thread.sleep(100)
            if (!decided || !accepted) {
                try {
                    Protocol.writeJson(out, JSONObject().put("status", Protocol.RESP_REJECT))
                } catch (_: Exception) {
                }
                return
            }

            // 断点续传：返回各文件已接收字节数
            val offsets = computeOffsets(tid, files)
            saveSessionMeta(tid, files)
            val offsetsJson = JSONArray()
            offsets.forEach { offsetsJson.put(it) }
            Protocol.writeJson(out, JSONObject().put("status", Protocol.RESP_ACCEPT).put("offsets", offsetsJson))

            // 数据阶段：5 分钟无数据判超时（暂停超过 5 分钟会断开，可再次重连续传）
            socket.soTimeout = 300_000
            needLog = true
            var transferred = offsets.sum()
            events.onReceiveBegin(peerName, files.size, total, transferred)

            val importedUris = mutableListOf<String>()
            for (i in files.indices) {
                val meta = Protocol.readJson(input)
                val name = File(meta.optString("name", files[i].first)).name
                val size = meta.optLong("size", files[i].second)
                val offset = meta.optLong("offset", 0).coerceIn(0, size)
                fileNames.add(name)
                val part = partFile(tid, i)
                if (offset < size) {
                    java.io.RandomAccessFile(part, "rw").use { raf ->
                        raf.seek(offset)
                        raf.setLength(offset)  // 截掉 offset 之后可能存在的脏数据
                        val buf = ByteArray(Protocol.BUFFER_SIZE)
                        var remaining = size - offset
                        while (remaining > 0) {
                            if (events.isCanceled()) throw IOException("已取消")
                            val n = input.read(buf, 0, minOf(buf.size.toLong(), remaining).toInt())
                            if (n < 0) throw IOException("连接中断")
                            raf.write(buf, 0, n)
                            remaining -= n
                            transferred += n
                            events.onProgress(name, i, files.size, transferred)
                        }
                    }
                }
                // 收满：导入相册/下载目录并删除临时文件
                val result = FileSaver.import(context, part, name)
                part.delete()
                importedUris.add(result.contentUri ?: "")
                Protocol.writeText(out, Protocol.RESP_ACK)
            }
            Protocol.writeText(out, Protocol.RESP_DONE)
            metaFile(tid).delete()
            success = true
            if (importedUris.size == 1) savedUri = importedUris[0].ifBlank { null }
            else if (importedUris.isNotEmpty()) savedUri = importedUris.first { it.isNotBlank() }
        } catch (e: Exception) {
            error = e.message ?: e.javaClass.simpleName
        } finally {
            sessions.remove(socket)
            try {
                socket.close()
            } catch (_: Exception) {
            }
            events.onFinished(peerName, fileNames, total, success, error, needLog, savedUri)
        }
    }
}
