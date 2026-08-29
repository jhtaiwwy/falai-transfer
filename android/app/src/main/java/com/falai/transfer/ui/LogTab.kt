package com.falai.transfer.ui

import android.content.Context
import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.falai.transfer.core.formatBytes
import com.falai.transfer.core.formatDuration
import com.falai.transfer.core.formatSpeed
import com.falai.transfer.core.formatTime
import com.falai.transfer.data.TransferLog
import com.falai.transfer.transfer.FileLocationOpener

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LogTab(
    logs: List<TransferLog>,
    columns: Int,
    onDelete: (Long) -> Unit,
    onClear: () -> Unit,
) {
    var confirmClear by remember { mutableStateOf(false) }

    Column(Modifier.fillMaxSize().padding(horizontal = 16.dp)) {
        Row(
            Modifier.fillMaxWidth().padding(vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                "传输日志（${logs.size}）",
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.onBackground.copy(alpha = 0.7f),
                modifier = Modifier.weight(1f),
            )
            if (logs.isNotEmpty()) {
                TextButton(onClick = { confirmClear = true }) { Text("清空") }
            }
        }

        if (logs.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text("暂无传输记录", color = MaterialTheme.colorScheme.onBackground.copy(alpha = 0.4f))
            }
        } else {
            LazyVerticalGrid(
                columns = GridCells.Fixed(columns),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                items(logs, key = { it.id }) { log ->
                    val dismissState = rememberSwipeToDismissBoxState(
                        confirmValueChange = { value ->
                            if (value == SwipeToDismissBoxValue.EndToStart) {
                                onDelete(log.id)
                            }
                            false
                        }
                    )
                    SwipeToDismissBox(
                        state = dismissState,
                        backgroundContent = {
                            Box(
                                Modifier.fillMaxSize().background(MaterialTheme.colorScheme.errorContainer)
                                    .padding(end = 20.dp),
                                contentAlignment = Alignment.CenterEnd,
                            ) {
                                Icon(Icons.Filled.Delete, contentDescription = "删除", tint = MaterialTheme.colorScheme.error)
                            }
                        },
                    ) {
                        LogCard(log)
                    }
                }
                item(span = { GridItemSpan(columns) }) { Spacer(Modifier.height(8.dp)) }
            }
        }
    }

    if (confirmClear) {
        AlertDialog(
            onDismissRequest = { confirmClear = false },
            title = { Text("清空日志") },
            text = { Text("确定删除全部传输日志吗？") },
            confirmButton = {
                TextButton(onClick = { onClear(); confirmClear = false }) { Text("清空") }
            },
            dismissButton = {
                TextButton(onClick = { confirmClear = false }) { Text("取消") }
            },
        )
    }
}

@Composable
private fun LogCard(log: TransferLog) {
    val context = LocalContext.current
    Card(
        Modifier.fillMaxWidth().clickable(enabled = log.contentUri != null) {
            val msg = FileLocationOpener.open(context, log.contentUri, log.fileCount)
            if (msg != null) Toast.makeText(context, msg, Toast.LENGTH_SHORT).show()
        }
    ) {
        Row(Modifier.padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(
                if (log.outgoing) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown,
                contentDescription = if (log.outgoing) "发送" else "接收",
                tint = if (log.success) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error,
                modifier = Modifier.size(28.dp),
            )
            Spacer(Modifier.size(10.dp))
            Column(Modifier.weight(1f)) {
                Text(log.fileSummary, fontWeight = FontWeight.Medium, maxLines = 1)
                Spacer(Modifier.height(2.dp))
                Text(
                    "${if (log.outgoing) "发往" else "来自"} ${log.peerName} · ${formatBytes(log.sizeBytes)}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f),
                )
                Text(
                    buildString {
                        append(formatTime(log.timeMillis))
                        append(" · ")
                        append(log.resultText)
                        if (log.durationMs > 0) {
                            append(" · ")
                            append(formatDuration(log.durationMs))
                        }
                        if (log.avgSpeedBps > 0) {
                            append(" · ")
                            append(formatSpeed(log.avgSpeedBps))
                        }
                        if (log.contentUri != null) append(" · 点击打开")
                    },
                    style = MaterialTheme.typography.bodySmall,
                    color = if (log.success) MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f)
                    else MaterialTheme.colorScheme.error,
                )
            }
        }
    }
}
