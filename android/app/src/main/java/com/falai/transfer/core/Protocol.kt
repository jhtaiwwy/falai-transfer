package com.falai.transfer.core

import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException

/**
 * 通信协议常量与帧读写工具。协议契约见 docs/方案.md 第 4 节：
 * UDP 广播发现（47800）+ TCP 直传（47801），[4字节头长][JSON] + 原始字节流。
 */
object Protocol {
    const val APP_ID = "FT"
    const val VERSION = 1
    const val DISCOVERY_PORT = 47800
    const val TRANSFER_PORT = 47801
    const val BROADCAST_INTERVAL_MS = 2000L
    const val OFFLINE_TIMEOUT_MS = 6000L
    const val BUFFER_SIZE = 32 * 1024

    const val RESP_ACCEPT = "ACCEPT"
    const val RESP_REJECT = "REJECT"
    const val RESP_ACK = "ACK"
    const val RESP_DONE = "DONE"

    fun writeFrame(out: DataOutputStream, payload: ByteArray) {
        out.writeInt(payload.size)
        out.write(payload)
        out.flush()
    }

    fun writeJson(out: DataOutputStream, json: JSONObject) =
        writeFrame(out, json.toString().toByteArray(Charsets.UTF_8))

    fun writeText(out: DataOutputStream, text: String) =
        writeFrame(out, text.toByteArray(Charsets.UTF_8))

    fun readFrame(input: DataInputStream, maxLen: Int = 4 * 1024 * 1024): ByteArray {
        val len = input.readInt()
        if (len <= 0 || len > maxLen) throw IOException("非法帧长度: $len")
        val buf = ByteArray(len)
        input.readFully(buf)
        return buf
    }

    fun readJson(input: DataInputStream): JSONObject =
        JSONObject(String(readFrame(input), Charsets.UTF_8))

    fun readText(input: DataInputStream): String =
        String(readFrame(input), Charsets.UTF_8)
}
