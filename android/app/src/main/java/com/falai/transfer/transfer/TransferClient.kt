package com.falai.transfer.transfer

import android.content.Context
import com.falai.transfer.core.Protocol
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket

/**
 * 发送方：连接对方，发请求头（含 transferId）→ 等 {status, offsets} →
 * 逐文件从 offset 续传字节流 → 等 ACK → DONE。支持暂停/继续与断点续传。
 */
object TransferClient {
    class RejectedException(msg: String) : Exception(msg)

    fun send(
        context: Context,
        ip: String,
        port: Int,
        transferId: String,
        fromName: String,
        files: List<ResolvedFile>,
        isCanceled: () -> Boolean,
        isPaused: () -> Boolean,
        onWaitingAccept: () -> Unit,
        onProgress: (currentFile: String, fileIndex: Int, transferredBytes: Long) -> Unit,
        onSocket: (Socket?) -> Unit,
    ) {
        val total = files.sumOf { it.size }
        val socket = Socket()
        try {
            onSocket(socket)
            socket.connect(InetSocketAddress(ip, port), 8000)
            socket.tcpNoDelay = true
            val out = DataOutputStream(BufferedOutputStream(socket.getOutputStream(), Protocol.BUFFER_SIZE))
            val input = DataInputStream(BufferedInputStream(socket.getInputStream(), Protocol.BUFFER_SIZE))

            // ① 请求头
            val filesJson = JSONArray()
            files.forEach { filesJson.put(JSONObject().put("name", it.name).put("size", it.size)) }
            Protocol.writeJson(
                out, JSONObject()
                    .put("app", Protocol.APP_ID)
                    .put("version", Protocol.VERSION)
                    .put("transferId", transferId)
                    .put("from", fromName)
                    .put("total", total)
                    .put("files", filesJson)
            )

            // ② 等待对方确认（对方用户可能考虑较久）；白名单设备秒回
            onWaitingAccept()
            socket.soTimeout = 120_000
            val resp = Protocol.readJson(input)
            if (resp.optString("status") != Protocol.RESP_ACCEPT) throw RejectedException("对方拒绝了接收请求")
            socket.soTimeout = 0

            // 断点续传：各文件已接收字节数
            val offsetsJson = resp.optJSONArray("offsets")
            val offsets = LongArray(files.size) { i ->
                if (offsetsJson != null && i < offsetsJson.length()) offsetsJson.optLong(i, 0) else 0
            }
            var transferred = offsets.sum()
            if (transferred > 0) {
                val resumeIdx = offsets.indexOfFirst { it > 0 && it < files[offsets.indexOf(it)].size }
                onProgress(files[if (resumeIdx >= 0) resumeIdx else 0].name, 0, transferred)
            }

            files.forEachIndexed { idx, f ->
                if (isCanceled()) throw IOException("已取消")
                val offset = offsets[idx].coerceIn(0, f.size)
                // ③ 单文件元信息（带 offset）
                Protocol.writeJson(out, JSONObject().put("name", f.name).put("size", f.size).put("offset", offset))
                // ④ 从 offset 处续传字节流
                if (offset < f.size) {
                    FileResolver.open(context, f).use { fileIn ->
                        val buf = ByteArray(Protocol.BUFFER_SIZE)
                        // 跳到断点位置：skip 不灵时读-丢弃兜底，保证发送位置与接收方 offset 严格对齐
                        var skipped = 0L
                        while (skipped < offset) {
                            val n = fileIn.skip(offset - skipped)
                            if (n > 0) {
                                skipped += n
                                continue
                            }
                            val r = fileIn.read(buf, 0, minOf(buf.size.toLong(), offset - skipped).toInt())
                            if (r < 0) throw IOException("文件长度不足，无法续传: ${f.name}")
                            skipped += r
                        }
                        var remaining = f.size - skipped
                        while (remaining > 0) {
                            if (isCanceled()) throw IOException("已取消")
                            while (isPaused() && !isCanceled()) Thread.sleep(200)
                            if (isCanceled()) throw IOException("已取消")
                            val n = fileIn.read(buf, 0, minOf(buf.size.toLong(), remaining).toInt())
                            if (n < 0) break
                            out.write(buf, 0, n)
                            remaining -= n
                            transferred += n
                            onProgress(f.name, idx, transferred)
                        }
                        out.flush()
                        if (remaining > 0) throw IOException("读取文件中断: ${f.name}")
                    }
                }
                // ⑤ 单文件 ACK
                val ack = Protocol.readText(input)
                if (ack != Protocol.RESP_ACK) throw IOException("对端确认异常: $ack")
            }
            // ⑥ 全部完成
            Protocol.readText(input)
        } finally {
            onSocket(null)
            try {
                socket.close()
            } catch (_: Exception) {
            }
        }
    }
}
