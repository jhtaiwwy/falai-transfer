package com.falai.transfer.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Person
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import coil.compose.AsyncImage
import com.falai.transfer.core.formatBytes
import com.falai.transfer.core.formatEta
import com.falai.transfer.core.formatSpeed
import com.falai.transfer.discovery.Device
import com.falai.transfer.transfer.Direction
import com.falai.transfer.transfer.IncomingRequest
import com.falai.transfer.transfer.ResolvedFile
import com.falai.transfer.transfer.TransferProgress
import com.falai.transfer.transfer.TransferStatus
import java.util.Locale

private fun isVisualMedia(name: String): Boolean {
    val ext = name.substringAfterLast('.', "").lowercase()
    return ext in setOf("jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "heif",
        "mp4", "mov", "mkv", "avi", "3gp", "webm")
}

/** 发送前预览：缩略图列表（可移除单个）+ 选择目标设备 + 手动输 IP */
@Composable
fun SendPreviewDialog(
    files: List<ResolvedFile>,
    devices: List<Device>,
    onRemoveFile: (Int) -> Unit,
    onSelect: (Device) -> Unit,
    onAddIp: (String) -> Boolean,
    onDismiss: () -> Unit,
) {
    var manualIp by remember { mutableStateOf("") }
    var ipError by remember { mutableStateOf(false) }

    Dialog(onDismissRequest = onDismiss) {
        Card {
            Column(Modifier.padding(20.dp).fillMaxWidth()) {
                Text(
                    "发送 ${files.size} 个文件（共 ${formatBytes(files.sumOf { it.size })}）",
                    fontWeight = FontWeight.Bold,
                )
                Spacer(Modifier.height(10.dp))

                // 文件预览列表
                LazyColumn(Modifier.heightIn(max = 180.dp)) {
                    items(files.size) { i ->
                        val f = files[i]
                        Row(
                            Modifier.fillMaxWidth().padding(vertical = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            if (isVisualMedia(f.name) && f.uri != null) {
                                AsyncImage(
                                    model = f.uri,
                                    contentDescription = null,
                                    modifier = Modifier.size(40.dp).clip(RoundedCornerShape(6.dp)),
                                    contentScale = ContentScale.Crop,
                                )
                            } else {
                                Icon(
                                    Icons.Filled.Person, contentDescription = null,
                                    modifier = Modifier.size(40.dp).padding(8.dp),
                                    tint = MaterialTheme.colorScheme.outline,
                                )
                            }
                            Spacer(Modifier.size(10.dp))
                            Column(Modifier.weight(1f)) {
                                Text(f.name, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyMedium)
                                Text(formatBytes(f.size), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f))
                            }
                            IconButton(onClick = { onRemoveFile(i) }) {
                                Icon(Icons.Filled.Close, contentDescription = "移除", modifier = Modifier.size(18.dp))
                            }
                        }
                    }
                }

                HorizontalDivider(Modifier.padding(vertical = 10.dp))
                Text("选择接收设备", fontWeight = FontWeight.Medium)
                Spacer(Modifier.height(6.dp))

                if (devices.isEmpty()) {
                    Text(
                        "未发现在线设备，可手动输入对方 IP",
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f),
                        style = MaterialTheme.typography.bodyMedium,
                    )
                } else {
                    LazyColumn(Modifier.heightIn(max = 160.dp)) {
                        items(devices, key = { it.ip }) { device ->
                            TextButton(onClick = { onSelect(device) }, modifier = Modifier.fillMaxWidth()) {
                                Icon(Icons.Filled.Person, contentDescription = null, modifier = Modifier.size(18.dp))
                                Spacer(Modifier.size(8.dp))
                                Text(
                                    "${device.name}（${device.ip}）",
                                    modifier = Modifier.fillMaxWidth(),
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                        }
                    }
                }

                Spacer(Modifier.height(6.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    OutlinedTextField(
                        value = manualIp,
                        onValueChange = { manualIp = it; ipError = false },
                        placeholder = { Text("手动输入 IP") },
                        isError = ipError,
                        singleLine = true,
                        modifier = Modifier.weight(1f),
                    )
                    Spacer(Modifier.size(8.dp))
                    OutlinedButton(onClick = {
                        val trimmed = manualIp.trim()
                        if (trimmed.matches(Regex("""^(\d{1,3}\.){3}\d{1,3}$"""))) {
                            onAddIp(trimmed)
                            onSelect(Device(trimmed, trimmed, "unknown", 47801, manual = true))
                        } else {
                            ipError = true
                        }
                    }) { Text("发送") }
                }
                if (ipError) {
                    Text("IP 格式不正确", color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
                }
                Spacer(Modifier.height(4.dp))
                TextButton(onClick = onDismiss, modifier = Modifier.align(Alignment.End)) { Text("取消") }
            }
        }
    }
}

/** 收到文件请求：接受 / 拒绝 / 信任该设备 */
@Composable
fun IncomingRequestDialog(
    request: IncomingRequest,
    onRespond: (accept: Boolean, trust: Boolean) -> Unit,
) {
    var trust by remember { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = { onRespond(false, false) },
        title = { Text("收到文件") },
        text = {
            Column {
                Text("「${request.fromName}」想发给你 ${request.fileCount} 个文件（共 ${formatBytes(request.totalBytes)}）")
                Spacer(Modifier.height(8.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(checked = trust, onCheckedChange = { trust = it })
                    Text("信任该设备，以后自动接收")
                }
            }
        },
        confirmButton = {
            Button(onClick = { onRespond(true, trust) }) { Text("接受") }
        },
        dismissButton = {
            TextButton(onClick = { onRespond(false, trust) }) { Text("拒绝") }
        },
    )
}

/** 传输进度：大圆环 + 实时速度 + 当前文件 + 暂停/继续 + 取消 */
@Composable
fun TransferProgressDialog(
    progress: TransferProgress,
    onPause: () -> Unit,
    onResume: () -> Unit,
    onCancel: () -> Unit,
    onDismiss: () -> Unit,
) {
    Dialog(onDismissRequest = { if (!progress.active) onDismiss() }) {
        Card {
            Column(
                Modifier.padding(24.dp).fillMaxWidth(),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(
                    when {
                        progress.status == TransferStatus.WAITING -> "等待对方确认…"
                        progress.status == TransferStatus.PAUSED -> "已暂停"
                        progress.active -> if (progress.direction == Direction.SEND) "正在发送到 ${progress.peerName}" else "正在接收自 ${progress.peerName}"
                        else -> if (progress.direction == Direction.SEND) "发送到 ${progress.peerName}" else "接收自 ${progress.peerName}"
                    },
                    fontWeight = FontWeight.Bold,
                    textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(20.dp))

                val fraction = if (progress.totalBytes > 0)
                    (progress.transferredBytes.toDouble() / progress.totalBytes).toFloat().coerceIn(0f, 1f)
                else 0f

                Box(contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(
                        progress = { fraction },
                        modifier = Modifier.size(140.dp),
                        strokeWidth = 10.dp,
                    )
                    Text(
                        String.format(Locale.US, "%.0f%%", fraction * 100),
                        style = MaterialTheme.typography.headlineMedium,
                        fontWeight = FontWeight.Bold,
                    )
                }
                Spacer(Modifier.height(20.dp))

                when {
                    progress.status == TransferStatus.WAITING ->
                        Text("对方确认后开始传输", color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f))

                    progress.active -> {
                        Text(
                            progress.currentFile + if (progress.fileCount > 1) "（${progress.fileIndex}/${progress.fileCount}）" else "",
                            style = MaterialTheme.typography.bodyMedium,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Spacer(Modifier.height(6.dp))
                        Text(
                            "${formatBytes(progress.transferredBytes)} / ${formatBytes(progress.totalBytes)}",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f),
                        )
                        Spacer(Modifier.height(6.dp))
                        Text(
                            if (progress.status == TransferStatus.PAUSED) "已暂停，点击继续恢复传输"
                            else "${formatSpeed(progress.speedBps)} · ${formatEta(progress.etaSeconds)}",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.secondary,
                            fontWeight = FontWeight.Medium,
                        )
                    }

                    else -> {
                        Text(
                            when (progress.status) {
                                TransferStatus.DONE -> "✓ 传输完成"
                                TransferStatus.REJECTED -> "对方拒绝了请求"
                                TransferStatus.CANCELED -> "已取消"
                                else -> "传输失败${progress.error?.let { "：$it" } ?: ""}"
                            },
                            color = if (progress.status == TransferStatus.DONE)
                                MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error,
                            fontWeight = FontWeight.Medium,
                            textAlign = TextAlign.Center,
                        )
                        Spacer(Modifier.height(4.dp))
                        Text(
                            "${formatBytes(progress.transferredBytes)} / ${formatBytes(progress.totalBytes)}",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f),
                        )
                    }
                }
                Spacer(Modifier.height(20.dp))

                if (progress.active) {
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        if (progress.direction == Direction.SEND &&
                            (progress.status == TransferStatus.TRANSFERRING || progress.status == TransferStatus.PAUSED)
                        ) {
                            FilledTonalButton(onClick = {
                                if (progress.status == TransferStatus.PAUSED) onResume() else onPause()
                            }) {
                                Text(if (progress.status == TransferStatus.PAUSED) "继续" else "暂停")
                            }
                        }
                        OutlinedButton(onClick = onCancel) { Text("取消传输") }
                    }
                } else {
                    Button(onClick = onDismiss) { Text("完成") }
                }
            }
        }
    }
}
