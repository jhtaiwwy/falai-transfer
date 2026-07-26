package com.falai.transfer.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

// 与图标同色系：深靛蓝主色 + 金色点缀，浅色背景
private val LightColors = lightColorScheme(
    primary = Color(0xFF262750),
    onPrimary = Color.White,
    primaryContainer = Color(0xFFE4E3F5),
    onPrimaryContainer = Color(0xFF191A3C),
    secondary = Color(0xFFB07A1E),
    onSecondary = Color.White,
    secondaryContainer = Color(0xFFFDEBC8),
    onSecondaryContainer = Color(0xFF5C430F),
    background = Color(0xFFF6F7FB),
    surface = Color.White,
    surfaceVariant = Color(0xFFEDEEF6),
    onBackground = Color(0xFF1B1B21),
    onSurface = Color(0xFF1B1B21),
)

@Composable
fun FaLaiTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = LightColors, content = content)
}
