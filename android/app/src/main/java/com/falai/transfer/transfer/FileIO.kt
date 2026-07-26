package com.falai.transfer.transfer

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import java.io.File
import java.io.InputStream

/** 待发送文件：解析出名称与准确大小（协议要求接收方知道精确字节数） */
data class ResolvedFile(val name: String, val size: Long, val uri: Uri?, val tempFile: File? = null)

object FileResolver {
    fun resolve(context: Context, uri: Uri): ResolvedFile {
        var name = "file_${System.currentTimeMillis()}"
        var size = -1L
        try {
            context.contentResolver.query(uri, null, null, null, null)?.use { c ->
                val ni = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val si = c.getColumnIndex(OpenableColumns.SIZE)
                if (c.moveToFirst()) {
                    if (ni >= 0) c.getString(ni)?.let { name = it }
                    if (si >= 0 && !c.isNull(si)) size = c.getLong(si)
                }
            }
        } catch (_: Exception) {
        }
        if (size >= 0) return ResolvedFile(name, size, uri)
        // 大小未知：先复制到缓存以获得准确字节数
        val tmp = File(context.cacheDir, "send_${System.currentTimeMillis()}_$name")
        context.contentResolver.openInputStream(uri)?.use { input ->
            tmp.outputStream().use { input.copyTo(it) }
        }
        return ResolvedFile(name, tmp.length(), null, tmp)
    }

    fun open(context: Context, f: ResolvedFile): InputStream =
        f.tempFile?.inputStream()
            ?: context.contentResolver.openInputStream(f.uri!!)
            ?: throw java.io.IOException("无法读取文件: ${f.name}")
}

data class ImportResult(val locationDesc: String, val contentUri: String?)

/**
 * 接收文件落点：照片/视频进相册，其他文件进下载目录。
 * 接收过程先写 cacheDir/incoming 下的 .part 临时文件（断点续传），收满后调用 import 导入。
 */
object FileSaver {
    fun import(context: Context, source: File, rawName: String): ImportResult {
        val name = File(rawName).name.ifBlank { "file_${System.currentTimeMillis()}" }
        val ext = name.substringAfterLast('.', "").lowercase()
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
        val resolver = context.contentResolver
        val isQ = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

        return when {
            mime.startsWith("image/") || mime.startsWith("video/") -> {
                val isImage = mime.startsWith("image/")
                val collection = if (isImage) {
                    MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                } else {
                    MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                }
                val dir = if (isImage) "Pictures/发来" else "Movies/发来"
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                    put(MediaStore.MediaColumns.MIME_TYPE, mime)
                    if (isQ) {
                        put(MediaStore.MediaColumns.RELATIVE_PATH, dir)
                        put(MediaStore.MediaColumns.IS_PENDING, 1)
                    }
                }
                val uri = resolver.insert(collection, values)
                    ?: throw java.io.IOException("无法写入相册")
                try {
                    resolver.openOutputStream(uri)?.use { out ->
                        source.inputStream().use { it.copyTo(out) }
                    } ?: throw java.io.IOException("无法写入相册")
                    if (isQ) {
                        val done = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
                        resolver.update(uri, done, null, null)
                    }
                    ImportResult("相册（$dir）", uri.toString())
                } catch (e: Exception) {
                    resolver.delete(uri, null, null)
                    throw e
                }
            }

            isQ -> {
                val values = ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, name)
                    put(MediaStore.Downloads.MIME_TYPE, mime)
                    put(MediaStore.Downloads.RELATIVE_PATH, "Download/发来")
                    put(MediaStore.Downloads.IS_PENDING, 1)
                }
                val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                    ?: throw java.io.IOException("无法写入下载目录")
                try {
                    resolver.openOutputStream(uri)?.use { out ->
                        source.inputStream().use { it.copyTo(out) }
                    } ?: throw java.io.IOException("无法写入下载目录")
                    val done = ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }
                    resolver.update(uri, done, null, null)
                    ImportResult("Download/发来", uri.toString())
                } catch (e: Exception) {
                    resolver.delete(uri, null, null)
                    throw e
                }
            }

            else -> {
                // Android 9 及以下：直接移动到公共下载目录（需 WRITE_EXTERNAL_STORAGE）
                val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "falai")
                dir.mkdirs()
                var target = File(dir, name)
                var i = 1
                while (target.exists()) {
                    val base = name.substringBeforeLast('.')
                    val suffix = if (ext.isNotEmpty()) ".$ext" else ""
                    target = File(dir, "${base}_$i$suffix")
                    i++
                }
                if (!source.renameTo(target)) {
                    source.inputStream().use { input ->
                        target.outputStream().use { input.copyTo(it) }
                    }
                }
                ImportResult(target.absolutePath, null)
            }
        }
    }
}
