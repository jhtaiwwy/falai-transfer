package com.falai.transfer.data

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

data class TransferLog(
    val id: Long = System.currentTimeMillis() + (0..999).random(),
    val timeMillis: Long,
    val outgoing: Boolean,          // true=发送 false=接收
    val peerName: String,
    val fileSummary: String,
    val sizeBytes: Long,
    val success: Boolean,
    val resultText: String,         // 成功 / 已取消 / 对方拒绝 / 失败原因
    val durationMs: Long,
    val avgSpeedBps: Double,
    val contentUri: String? = null,   // 单文件接收成功时的落点，用于点击预览
) {
    fun toJson(): JSONObject = JSONObject()
        .put("id", id)
        .put("time", timeMillis)
        .put("outgoing", outgoing)
        .put("peer", peerName)
        .put("files", fileSummary)
        .put("size", sizeBytes)
        .put("success", success)
        .put("result", resultText)
        .put("duration", durationMs)
        .put("avgSpeed", avgSpeedBps)
        .put("uri", contentUri)

    companion object {
        fun fromJson(j: JSONObject) = TransferLog(
            id = j.optLong("id"),
            timeMillis = j.optLong("time"),
            outgoing = j.optBoolean("outgoing"),
            peerName = j.optString("peer"),
            fileSummary = j.optString("files"),
            sizeBytes = j.optLong("size"),
            success = j.optBoolean("success"),
            resultText = j.optString("result"),
            durationMs = j.optLong("duration"),
            avgSpeedBps = j.optDouble("avgSpeed"),
            contentUri = j.optString("uri").takeIf { it.isNotBlank() },
        )
    }
}

/** 传输日志：JSON 文件本地持久化，支持单条删除与一键清空 */
object LogRepository {
    private lateinit var file: File
    private val _logs = MutableStateFlow<List<TransferLog>>(emptyList())
    val logs: StateFlow<List<TransferLog>> = _logs.asStateFlow()

    fun init(context: Context) {
        file = File(context.filesDir, "logs.json")
        _logs.value = load()
    }

    @Synchronized
    fun add(log: TransferLog) {
        _logs.value = listOf(log) + _logs.value
        persist()
    }

    @Synchronized
    fun delete(id: Long) {
        _logs.value = _logs.value.filterNot { it.id == id }
        persist()
    }

    @Synchronized
    fun clear() {
        _logs.value = emptyList()
        persist()
    }

    private fun load(): List<TransferLog> = try {
        val arr = JSONArray(file.readText())
        (0 until arr.length()).map { TransferLog.fromJson(arr.getJSONObject(it)) }
    } catch (_: Exception) {
        emptyList()
    }

    private fun persist() {
        try {
            val arr = JSONArray()
            _logs.value.take(500).forEach { arr.put(it.toJson()) }
            file.writeText(arr.toString())
        } catch (_: Exception) {
        }
    }
}
