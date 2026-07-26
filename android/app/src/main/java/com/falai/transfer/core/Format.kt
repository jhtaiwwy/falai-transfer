package com.falai.transfer.core

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

fun formatBytes(bytes: Long): String = when {
    bytes < 1024 -> "$bytes B"
    bytes < 1024 * 1024 -> String.format(Locale.US, "%.1f KB", bytes / 1024.0)
    bytes < 1024L * 1024 * 1024 -> String.format(Locale.US, "%.1f MB", bytes / 1024.0 / 1024)
    else -> String.format(Locale.US, "%.2f GB", bytes / 1024.0 / 1024 / 1024)
}

fun formatSpeed(bps: Double): String = formatBytes(bps.toLong()) + "/s"

fun formatEta(seconds: Long): String = when {
    seconds <= 0 -> "即将完成"
    seconds < 60 -> "约 ${seconds} 秒"
    seconds < 3600 -> "约 ${seconds / 60} 分 ${seconds % 60} 秒"
    else -> "约 ${seconds / 3600} 小时"
}

fun formatDuration(ms: Long): String = when {
    ms < 1000 -> "${ms}ms"
    ms < 60_000 -> String.format(Locale.US, "%.1f秒", ms / 1000.0)
    else -> "${ms / 60_000}分${(ms % 60_000) / 1000}秒"
}

fun formatTime(millis: Long): String =
    SimpleDateFormat("MM-dd HH:mm:ss", Locale.getDefault()).format(Date(millis))

fun summarizeFiles(names: List<String>): String = when {
    names.isEmpty() -> "-"
    names.size == 1 -> names[0]
    else -> "${names[0]} 等${names.size}个文件"
}
