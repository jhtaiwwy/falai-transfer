package com.falai.transfer

import android.app.Application
import android.net.Uri
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.falai.transfer.data.LogRepository
import com.falai.transfer.discovery.Device
import com.falai.transfer.discovery.DiscoveryService
import com.falai.transfer.transfer.FileResolver
import com.falai.transfer.transfer.ResolvedFile
import com.falai.transfer.transfer.TransferManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

class MainViewModel(application: Application) : AndroidViewModel(application) {
    private val manager = TransferManager.get(application)

    val devices = DiscoveryService.devices
    val progress = manager.progress
    val incoming = manager.incoming
    val whitelist = manager.whitelist
    val logs = LogRepository.logs

    private val _deviceName = MutableStateFlow(manager.deviceName)
    val deviceName: StateFlow<String> = _deviceName.asStateFlow()

    /** 本机 IP（进入页面时取一次即可，WiFi 变化时刷新页面会重取） */
    val localIp: String
        get() = DiscoveryService.primaryIp()

    /** 已选文件（已解析名称/大小），等待预览确认并选择目标设备 */
    private val _pendingFiles = MutableStateFlow<List<ResolvedFile>?>(null)
    val pendingFiles: StateFlow<List<ResolvedFile>?> = _pendingFiles.asStateFlow()

    init {
        LogRepository.init(application)
        manager.start()   // 先起服务端拿到实际端口，再开始广播
        DiscoveryService.start(application, { manager.deviceName }, { manager.serverPort })
    }

    fun setDeviceName(name: String) {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) return
        manager.deviceName = trimmed
        _deviceName.value = trimmed
    }

    fun onFilesPicked(uris: List<Uri>) {
        if (uris.isEmpty()) return
        val app = getApplication<Application>()
        viewModelScope.launch(Dispatchers.IO) {
            val resolved = uris.map { FileResolver.resolve(app, it) }
            _pendingFiles.value = resolved
        }
    }

    fun removePendingFile(index: Int) {
        val current = _pendingFiles.value ?: return
        val next = current.toMutableList().apply { removeAt(index) }
        _pendingFiles.value = next.ifEmpty { null }
    }

    fun sendTo(device: Device) {
        val files = _pendingFiles.value ?: return
        _pendingFiles.value = null
        manager.sendFiles(device.ip, device.tcpPort, device.name, files)
    }

    fun cancelPendingSend() {
        _pendingFiles.value?.forEach { it.tempFile?.delete() }
        _pendingFiles.value = null
    }

    fun addManualDevice(ip: String): Boolean = DiscoveryService.addManualDevice(ip)

    fun respondIncoming(accept: Boolean, trust: Boolean) = manager.respondIncoming(accept, trust)

    fun pauseTransfer() = manager.pauseTransfer()

    fun resumeTransfer() = manager.resumeTransfer()

    fun cancelTransfer() = manager.cancelTransfer()

    fun dismissProgress() = manager.dismissProgress()

    fun deleteLog(id: Long) = LogRepository.delete(id)

    fun clearLogs() = LogRepository.clear()

    fun removeWhitelist(ip: String) = manager.removeFromWhitelist(ip)
}
