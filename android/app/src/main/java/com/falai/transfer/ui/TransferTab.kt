package com.falai.transfer.ui

import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.falai.transfer.discovery.Device

@Composable
fun TransferTab(
    deviceName: String,
    localIp: String,
    devices: List<Device>,
    whitelist: Set<String>,
    columns: Int,
    onPickMedia: () -> Unit,
    onPickFiles: () -> Unit,
) {
    LazyVerticalGrid(
        columns = GridCells.Fixed(columns),
        modifier = Modifier.fillMaxSize().padding(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item(span = { GridItemSpan(columns) }) { Spacer(Modifier.height(4.dp)) }

        // 本机卡片
        item(span = { GridItemSpan(columns) }) {
            Card(
                modifier = Modifier.fillMaxWidth(),
                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primary),
            ) {
                Column(Modifier.padding(16.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Filled.Star, contentDescription = null, tint = MaterialTheme.colorScheme.secondaryContainer)
                        Spacer(Modifier.size(8.dp))
                        Text("本机", color = MaterialTheme.colorScheme.onPrimary, fontWeight = FontWeight.Bold)
                    }
                    Spacer(Modifier.height(8.dp))
                    Text(deviceName, style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onPrimary)
                    Text("IP：$localIp", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onPrimary.copy(alpha = 0.8f))
                    Text("两台设备连接同一 WiFi 即可互传", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onPrimary.copy(alpha = 0.6f))
                }
            }
        }

        // 发送按钮
        item(span = { GridItemSpan(columns) }) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Button(onClick = onPickMedia, modifier = Modifier.weight(1f)) {
                    Text("照片 / 视频")
                }
                FilledTonalButton(onClick = onPickFiles, modifier = Modifier.weight(1f)) {
                    Text("选择文件")
                }
            }
        }

        item(span = { GridItemSpan(columns) }) {
            Text(
                "在线设备（${devices.size}）",
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.onBackground.copy(alpha = 0.7f),
            )
        }

        if (devices.isEmpty()) {
            item(span = { GridItemSpan(columns) }) {
                Card(Modifier.fillMaxWidth()) {
                    Text(
                        "未发现设备\n请确认对方也打开了「发来」并连接同一 WiFi",
                        modifier = Modifier.padding(20.dp),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f),
                    )
                }
            }
        } else {
            items(devices, key = { it.ip }) { device ->
                Card(Modifier.fillMaxWidth()) {
                    Row(
                        Modifier.padding(16.dp).fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(Icons.Filled.Person, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                        Spacer(Modifier.size(12.dp))
                        Column(Modifier.weight(1f)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(device.name, fontWeight = FontWeight.Medium)
                                if (device.ip in whitelist) {
                                    Spacer(Modifier.size(6.dp))
                                    Icon(
                                        Icons.Filled.Star,
                                        contentDescription = "白名单",
                                        tint = MaterialTheme.colorScheme.secondary,
                                        modifier = Modifier.size(14.dp),
                                    )
                                }
                            }
                            Text(
                                "${device.ip} · ${
                                    when (device.os) {
                                        "android" -> "安卓"
                                        "harmony" -> "鸿蒙"
                                        else -> device.os
                                    }
                                }",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f),
                            )
                        }
                    }
                }
            }
        }

        item(span = { GridItemSpan(columns) }) { Spacer(Modifier.height(4.dp)) }
    }
}
