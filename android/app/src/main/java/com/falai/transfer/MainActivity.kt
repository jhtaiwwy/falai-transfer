package com.falai.transfer

import android.Manifest
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.ContentTransform
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.ExperimentalAnimationApi
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.List
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Send
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.windowsizeclass.ExperimentalMaterial3WindowSizeClassApi
import androidx.compose.material3.windowsizeclass.WindowWidthSizeClass
import androidx.compose.material3.windowsizeclass.calculateWindowSizeClass
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.falai.transfer.ui.IncomingRequestDialog
import com.falai.transfer.ui.LogTab
import com.falai.transfer.ui.MineTab
import com.falai.transfer.ui.SendPreviewDialog
import com.falai.transfer.ui.TransferProgressDialog
import com.falai.transfer.ui.TransferTab
import com.falai.transfer.ui.theme.FaLaiTheme

/**
 * 与鸿蒙版（Index.ets handleTabChange）一致的 Tab 切换动画：
 * - 旧页：淡出 + 缩小到 0.92 + 反向横移 40dp
 * - 新页：从 0.95 淡入放大到 1.0
 * - 350ms FastOutSlowInEasing 曲线
 */
@OptIn(ExperimentalAnimationApi::class)
private fun tabTransition(
    currentIndex: Int,
    targetIndex: Int,
    density: Density,
): ContentTransform {
    val direction = if (targetIndex > currentIndex) 1 else -1
    val slidePx = with(density) { 40.dp.roundToPx() }
    val spec = tween<Float>(durationMillis = 350, easing = FastOutSlowInEasing)
    val enter: EnterTransition =
        fadeIn(animationSpec = spec) +
            scaleIn(initialScale = 0.95f, animationSpec = spec)
    val exit: ExitTransition =
        fadeOut(animationSpec = spec) +
            scaleOut(targetScale = 0.92f, animationSpec = spec) +
            slideOutHorizontally(
                animationSpec = tween<IntOffset>(durationMillis = 350, easing = FastOutSlowInEasing),
                targetOffsetX = { -direction * slidePx },
            )
    return enter togetherWith exit
}

class MainActivity : ComponentActivity() {
    private val vm: MainViewModel by viewModels()

    private val pickMedia = registerForActivityResult(
        ActivityResultContracts.PickMultipleVisualMedia()
    ) { uris -> vm.onFilesPicked(uris) }

    private val pickFiles = registerForActivityResult(
        ActivityResultContracts.OpenMultipleDocuments()
    ) { uris -> vm.onFilesPicked(uris) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestNeededPermissions()
        setContent {
            FaLaiTheme {
                MainScreen(
                    vm = vm,
                    onPickMedia = {
                        pickMedia.launch(
                            PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo)
                        )
                    },
                    onPickFiles = { pickFiles.launch(arrayOf("*/*")) },
                )
            }
        }
    }

    private fun requestNeededPermissions() {
        val perms = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= 33) {
            perms += Manifest.permission.POST_NOTIFICATIONS
            perms += Manifest.permission.NEARBY_WIFI_DEVICES
        }
        if (Build.VERSION.SDK_INT <= 28) {
            perms += Manifest.permission.WRITE_EXTERNAL_STORAGE
        }
        if (perms.isNotEmpty()) requestPermissions(perms.toTypedArray(), 1)
    }
}

/**
 * 多屏自适应（方案 5.1）：
 * Compact（直板/折叠态）→ 底部 NavigationBar + 单列；
 * Medium（展开态/横屏）→ 左侧 NavigationRail + 双列网格；
 * Expanded（平板）→ NavigationRail + 三列网格。
 */
@OptIn(ExperimentalMaterial3WindowSizeClassApi::class)
@Composable
fun MainScreen(
    vm: MainViewModel,
    onPickMedia: () -> Unit,
    onPickFiles: () -> Unit,
) {
    var tab by rememberSaveable { mutableIntStateOf(0) }

    val activity = androidx.compose.ui.platform.LocalContext.current as ComponentActivity
    val windowSizeClass = calculateWindowSizeClass(activity = activity)
    val columns = when (windowSizeClass.widthSizeClass) {
        WindowWidthSizeClass.Expanded -> 3
        WindowWidthSizeClass.Medium -> 2
        else -> 1
    }
    val isWide = windowSizeClass.widthSizeClass != WindowWidthSizeClass.Compact

    val devices by vm.devices.collectAsStateWithLifecycle()
    val logs by vm.logs.collectAsStateWithLifecycle()
    val progress by vm.progress.collectAsStateWithLifecycle()
    val incoming by vm.incoming.collectAsStateWithLifecycle()
    val whitelist by vm.whitelist.collectAsStateWithLifecycle()
    val deviceName by vm.deviceName.collectAsStateWithLifecycle()
    val pendingFiles by vm.pendingFiles.collectAsStateWithLifecycle()

    val navItems = listOf(
        Triple("传输", Icons.Filled.Send, 0),
        Triple("日志", Icons.Filled.List, 1),
        Triple("我的", Icons.Filled.Person, 2),
    )

    Scaffold(
        bottomBar = {
            if (!isWide) {
                NavigationBar {
                    navItems.forEach { (label, icon, index) ->
                        NavigationBarItem(
                            selected = tab == index, onClick = { tab = index },
                            icon = { Icon(icon, contentDescription = null) },
                            label = { Text(label) },
                        )
                    }
                }
            }
        },
    ) { padding ->
        Row(Modifier.fillMaxSize().padding(padding)) {
            if (isWide) {
                NavigationRail {
                    navItems.forEach { (label, icon, index) ->
                        NavigationRailItem(
                            selected = tab == index, onClick = { tab = index },
                            icon = { Icon(icon, contentDescription = null) },
                            label = { Text(label) },
                        )
                    }
                }
            }
            Box(Modifier.fillMaxSize()) {
                // 与鸿蒙版一致的 Tab 切换动画：
                // 旧页淡出 + 缩小到 0.92 + 反向横移 40dp，新页从 0.95 淡入放大到 1.0，
                // 350ms FastOutSlowInEasing 曲线，流畅不生硬。
                val density = LocalDensity.current
                AnimatedContent(
                    targetState = tab,
                    contentKey = { it },
                    transitionSpec = { tabTransition(initialState, targetState, density) },
                    label = "tabContent",
                ) { currentTab ->
                    when (currentTab) {
                        0 -> TransferTab(
                            deviceName = deviceName,
                            localIp = vm.localIp,
                            devices = devices,
                            whitelist = whitelist,
                            columns = columns,
                            onPickMedia = onPickMedia,
                            onPickFiles = onPickFiles,
                        )

                        1 -> LogTab(
                            logs = logs,
                            columns = columns,
                            onDelete = vm::deleteLog,
                            onClear = vm::clearLogs,
                        )

                        else -> MineTab(
                            deviceName = deviceName,
                            whitelist = whitelist,
                            onSaveName = vm::setDeviceName,
                            onRemoveWhitelist = vm::removeWhitelist,
                        )
                    }
                }
            }
        }
    }

    // 选完文件 → 预览 + 选择目标设备
    pendingFiles?.let { files ->
        SendPreviewDialog(
            files = files,
            devices = devices,
            onRemoveFile = vm::removePendingFile,
            onSelect = vm::sendTo,
            onAddIp = vm::addManualDevice,
            onDismiss = vm::cancelPendingSend,
        )
    }

    // 收到传输请求
    incoming?.let { req ->
        IncomingRequestDialog(
            request = req,
            onRespond = vm::respondIncoming,
        )
    }

    // 传输进度
    if (progress.show) {
        TransferProgressDialog(
            progress = progress,
            onPause = vm::pauseTransfer,
            onResume = vm::resumeTransfer,
            onCancel = vm::cancelTransfer,
            onDismiss = vm::dismissProgress,
        )
    }
}
