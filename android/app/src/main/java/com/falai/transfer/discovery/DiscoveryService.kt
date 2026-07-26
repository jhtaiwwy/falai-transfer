package com.falai.transfer.discovery

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import com.falai.transfer.core.Protocol
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.util.concurrent.ConcurrentHashMap

data class Device(
    val ip: String,
    val name: String,
    val os: String,
    val tcpPort: Int,
    val lastSeen: Long = System.currentTimeMillis(),
    val manual: Boolean = false,
)

/**
 * UDP 广播自动发现：每 2 秒广播自身信息，监听 47800 端口收集局域网内其他设备，
 * 超过 6 秒无心跳标记离线。支持手动添加 IP（应对 AP 隔离）。
 */
object DiscoveryService {
    private val _devices = MutableStateFlow<List<Device>>(emptyList())
    val devices: StateFlow<List<Device>> = _devices.asStateFlow()

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var jobs: List<Job> = emptyList()
    private var multicastLock: WifiManager.MulticastLock? = null
    private var nameProvider: () -> String = { Build.MODEL ?: "Android" }
    private var portProvider: () -> Int = { Protocol.TRANSFER_PORT }

    private val found = ConcurrentHashMap<String, Device>()
    private val manual = ConcurrentHashMap<String, Device>()

    @Volatile
    private var running = false

    fun start(context: Context, provider: () -> String, tcpPortProvider: () -> Int = { Protocol.TRANSFER_PORT }) {
        if (running) return
        running = true
        nameProvider = provider
        portProvider = tcpPortProvider
        try {
            val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicastLock = wifi.createMulticastLock("falai_discovery").apply {
                setReferenceCounted(true)
                acquire()
            }
        } catch (_: Exception) {
        }
        jobs = listOf(
            scope.launch { broadcastLoop() },
            scope.launch { listenLoop() },
            scope.launch { pruneLoop() },
        )
    }

    fun stop() {
        running = false
        jobs.forEach { it.cancel() }
        jobs = emptyList()
        try {
            multicastLock?.release()
        } catch (_: Exception) {
        }
        multicastLock = null
    }

    fun addManualDevice(ip: String): Boolean {
        val trimmed = ip.trim()
        if (!trimmed.matches(Regex("""^(\d{1,3}\.){3}\d{1,3}$"""))) return false
        manual[trimmed] = Device(trimmed, "手动添加的设备", "unknown", Protocol.TRANSFER_PORT, manual = true)
        publish()
        return true
    }

    fun ownIps(): Set<String> = try {
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback }
            .flatMap { ni -> ni.inetAddresses.toList() }
            .mapNotNull { it.hostAddress }
            .filter { !it.contains(':') }
            .toSet()
    } catch (_: Exception) {
        emptySet()
    }

    fun primaryIp(): String {
        val ips = ownIps()
        return ips.firstOrNull {
            it.startsWith("192.168.") || it.startsWith("10.") ||
                it.startsWith("172.") || it.startsWith("169.254.")
        } ?: ips.firstOrNull() ?: "未连接网络"
    }

    private fun broadcastAddresses(): List<InetAddress> {
        val addrs = mutableListOf<InetAddress>()
        try {
            NetworkInterface.getNetworkInterfaces().toList()
                .filter { it.isUp && !it.isLoopback }
                .forEach { ni ->
                    ni.interfaceAddresses.forEach { ia ->
                        ia.broadcast?.let { addrs.add(it) }
                    }
                }
        } catch (_: Exception) {
        }
        if (addrs.isEmpty()) {
            try {
                addrs.add(InetAddress.getByName("255.255.255.255"))
            } catch (_: Exception) {
            }
        }
        return addrs.distinct()
    }

    private fun selfJson(): JSONObject = JSONObject()
        .put("app", Protocol.APP_ID)
        .put("name", nameProvider())
        .put("os", "android")
        .put("tcpPort", portProvider())
        .put("version", Protocol.VERSION)

    private suspend fun broadcastLoop() {
        var socket: DatagramSocket? = null
        try {
            socket = DatagramSocket()
            socket.broadcast = true
            while (currentCoroutineContext().isActive) {
                val data = selfJson().toString().toByteArray(Charsets.UTF_8)
                for (addr in broadcastAddresses()) {
                    try {
                        socket.send(DatagramPacket(data, data.size, addr, Protocol.DISCOVERY_PORT))
                    } catch (_: Exception) {
                    }
                }
                delay(Protocol.BROADCAST_INTERVAL_MS)
            }
        } catch (_: Exception) {
        } finally {
            socket?.close()
        }
    }

    private suspend fun listenLoop() {
        var socket: DatagramSocket? = null
        try {
            socket = DatagramSocket(null)
            socket.reuseAddress = true
            socket.bind(InetSocketAddress(Protocol.DISCOVERY_PORT))
            socket.soTimeout = 1000
            val buf = ByteArray(4096)
            while (currentCoroutineContext().isActive) {
                val packet = DatagramPacket(buf, buf.size)
                try {
                    socket.receive(packet)
                } catch (_: java.net.SocketTimeoutException) {
                    continue
                }
                val senderIp = packet.address?.hostAddress ?: continue
                if (senderIp in ownIps()) continue
                try {
                    val json = JSONObject(String(packet.data, 0, packet.length, Charsets.UTF_8))
                    if (json.optString("app") != Protocol.APP_ID) continue
                    found[senderIp] = Device(
                        ip = senderIp,
                        name = json.optString("name", "未知设备"),
                        os = json.optString("os", "unknown"),
                        tcpPort = json.optInt("tcpPort", Protocol.TRANSFER_PORT),
                    )
                    publish()
                } catch (_: Exception) {
                }
            }
        } catch (_: Exception) {
        } finally {
            socket?.close()
        }
    }

    private suspend fun pruneLoop() {
        while (currentCoroutineContext().isActive) {
            delay(Protocol.BROADCAST_INTERVAL_MS)
            val now = System.currentTimeMillis()
            val before = found.size
            found.entries.removeIf { now - it.value.lastSeen > Protocol.OFFLINE_TIMEOUT_MS }
            if (found.size != before) publish()
        }
    }

    private fun publish() {
        // 广播发现的实时信息优先于手动添加的占位
        val merged = manual.toMutableMap()
        merged.putAll(found)
        _devices.value = merged.values.sortedBy { it.name }
    }
}
