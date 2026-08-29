# 「发来」Windows 版技术方案

> 版本：v1.0 | 日期：2026-07-27 | 状态：方案阶段
> 基于已有的 Android + HarmonyOS 通信协议，实现 Windows 桌面客户端。

---

## 1. 目标与定位

在现有 Android（Kotlin + Jetpack Compose）和 HarmonyOS（ArkTS + ArkUI）基础上，开发 **Windows 桌面版**「发来」，使 PC 与手机/平板之间也能局域网互传文件。

核心目标：

1. **协议完全兼容**：与安卓版、鸿蒙版使用同一通信协议，三端可互相传输
2. **Windows 原生体验**：使用 Windows 原生 UI 框架，风格与系统统一
3. **功能对齐**：设备发现、文件收发、传输进度/速度、传输日志、白名单
4. **文件落点**：接收文件保存到 Windows 下载目录或用户指定目录（无 MediaStore/相册概念）

---

## 2. 技术选型

### 2.1 最终方案：Python + customtkinter + PyInstaller（推荐）

| 维度 | Python + ctk | C# + WinUI 3 | Electron |
|---|---|---|---|
| 开发速度 | ✅ 极快（环境现成，协议层同源） | ⚠️ 需安装 .NET SDK 8 + 1~2GB | ⚠️ 需安装 Node.js 依赖 |
| 原生度 | ✅ 原生 Windows 窗口 | ✅ 最原生 | ❌ Chromium 壳 |
| UI 现代感 | ✅ customtkinter Fluent 风格 | ✅ Fluent Design | ✅ 可定制 |
| exe 体积 | ⚠️ 30~50 MB（PyInstaller） | ✅ 5~10 MB | ❌ 150~200 MB |
| 协议复用 | ✅ **pc_peer.py 同源**，协议代码几乎不用改 | ❌ 需重写 | ❌ 需重写 |
| 生态成熟度 | ✅ Python 协议开发非常成熟 | ⚠️ 需安装 SDK | ✅ 成熟 |

**结论：Python + customtkinter + PyInstaller**

- **环境现成**：本机已有 Python 3.12，无需下载安装 .NET SDK
- **协议同源**：`tools/pc_peer.py` 已完整实现 UDP 发现 + TCP 传输协议，Windows 版直接复用核心逻辑
- **打包简单**：`PyInstaller --onefile` 生成独立 exe，双击即可运行
- **UI 够用**：customtkinter 提供现代圆角卡片风格，满足文件传输工具需求

---

## 3. 通信协议（完全沿用 v1.1）

与 Android/鸿蒙版协议 **100% 一致**，仅 `os` 字段值不同：

### 3.1 UDP 发现（端口 47800）

广播报文：
```json
{ "app": "FT", "name": "DESKTOP-XXX", "os": "windows", "tcpPort": 47801, "version": 1 }
```

### 3.2 TCP 传输（端口 47801~47811）

帧格式：`[4 字节大端长度][payload]`

传输流程 6 步（与 Android/鸿蒙完全一致）：

```
客户端（发送方）                              服务端（接收方）
  │ ── ① 请求头 ────────────────────────► │
  │    [4字节头长][JSON: {transferId, files, total, from}]
  │ ◄── ② {status: ACCEPT, offsets:[...]}  │
  │        或 {status: REJECT}              │
  │ ── ③ 逐文件: [4字节元信息长][JSON{name,size,offset}]
  │ ── ④ 原始字节流（32KB 块流式读写）───► │
  │ ◄── ⑤ ACK ──────────────────────────── │
  │ ◄── ⑥ DONE ─────────────────────────── │
```

### 3.3 协议常量

| 常量 | 值 | 说明 |
|---|---|---|
| `APP_ID` | `"FT"` | 应用标识 |
| `VERSION` | `1` | 协议版本 |
| `DISCOVERY_PORT` | `47800` | UDP 广播发现端口 |
| `TRANSFER_PORT` | `47801` | TCP 文件传输起始端口 |
| `PORT_TRY_COUNT` | `11` | 端口占用时尝试 47801~47811 |
| `BROADCAST_INTERVAL_MS` | `2000` | 广播间隔 2 秒 |
| `OFFLINE_TIMEOUT_MS` | `6000` | 6 秒无心跳判离线 |
| `BUFFER_SIZE` | `32 * 1024` | 32KB 流式传输块 |
| `HEADER_TIMEOUT_MS` | `30_000` | 请求头超时 |
| `DATA_TIMEOUT_MS` | `300_000` | 数据传输超时（5 分钟） |
| `ACCEPT_TIMEOUT_MS` | `120_000` | 客户端等确认超时 |
| `RESP_ACCEPT` / `RESP_REJECT` / `RESP_ACK` / `RESP_DONE` | `"ACCEPT"` 等 | 响应状态 |

---

## 4. 整体架构

### 4.1 模块划分（与 Android/鸿蒙对称）

| 模块 | 职责 | .NET 对应 |
|---|---|---|
| Protocol | 协议常量 + 帧读写工具 | `Core/Protocol.cs` |
| DiscoveryService | UDP 广播发现 + 设备列表 | `Discovery/DiscoveryService.cs` |
| TransferServer | TCP 接收服务端 + 断点续传 | `Transfer/TransferServer.cs` |
| TransferClient | TCP 发送客户端 | `Transfer/TransferClient.cs` |
| TransferManager | 传输编排（暂停/继续/取消/白名单/日志） | `Transfer/TransferManager.cs` |
| FileIO | 文件选择/读取/保存 | `Transfer/FileIO.cs` |
| LogRepository | 传输日志 JSON 持久化 | `Data/LogRepository.cs` |
| UI 层 | Fluent Design UI | `UI/` 目录（XAML + MVVM） |

### 4.2 架构图

```
┌──────────────────────────────────────────────────────────┐
│                    Windows 桌面版「发来」                  │
│                                                          │
│  ┌─────────┐  UDP 47800  ┌─────────┐  TCP 47801         │
│  │ 安卓版   │ ◄────────► │  发来    │ ◄────────► │ 鸿蒙版  │
│  │ Android │              │ Windows │              │ Harmony│
│  └─────────┘              └─────────┘              └─────────┘
│                                                          │
│  ┌──────────────────────────────────────────────────┐    │
│  │               Core / Discovery / Transfer         │    │
│  │  Protocol.cs │ DiscoveryService.cs                │    │
│  │  TransferServer.cs │ TransferClient.cs             │    │
│  │  TransferManager.cs │ FileIO.cs │ LogRepository.cs │    │
│  └──────────────────────────────────────────────────┘    │
│  ┌──────────────────────────────────────────────────┐    │
│  │                  UI (WinUI 3 + MVVM)              │    │
│  │  TransferPage │ LogPage │ SettingsPage             │    │
│  └──────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────┘
```

---

## 5. Windows 特有适配点

### 5.1 文件选择

| 场景 | Android/鸿蒙 | Windows |
|---|---|---|
| 发送端选文件 | Photo Picker / SAF / documentViewPicker | **`Windows.Storage.Pickers.FileOpenPicker`**（多选） |
| 接收端保存 | MediaStore / photoAccessHelper / DocumentViewPicker | **直接写入用户目录**（无需系统选择器） |

Windows 端发送时：
- **照片/视频**：使用 `FileOpenPicker` 筛选 `image/*, video/*`，支持多选
- **任意文件**：使用 `FileOpenPicker` 不限类型，支持多选
- 大小解析：通过 `StorageFile.Properties.GetThumbnailAsync()` 获取缩略图预览；通过 `BasicProperties.Size` 获取文件大小

Windows 端接收时：
- **无相册概念**：所有文件统一保存到下载目录（默认 `C:\Users\<用户名>\Downloads\发来`）
- 可配置保存路径（在设置页）
- 重名自动加 `_1` `_2` 后缀

### 5.2 文件保存

Android 需要 MediaStore 写入相册，鸿蒙需要 photoAccessHelper。Windows 端：
- 先写 `Temp/Incoming/<transferId>_<index>.part` 临时文件（支撑断点续传）
- 收满后 `File.Move` 到目标目录（下载目录或用户指定目录）
- 删除 `.part` 临时文件
- 会话元信息 `Temp/Incoming/<transferId>.json`

### 5.3 网络发现

- Windows 使用 `System.Net.Sockets.UdpClient` 实现 UDP 广播
- 使用 `IPGlobalProperties.GetIPGlobalProperties()` 获取本机 IP 和网卡信息
- 支持有线/无线/虚拟网卡，自动收集所有局域网 broadcast 地址
- WiFi 断开检测：监听 `NetworkChange.NetworkAddressChanged` 事件

### 5.4 后台运行

- Windows 不需要 Android 的 ForegroundService + WakeLock
- 可选：传输时显示系统托盘通知（最小化到托盘）
- 可选：开机自启动（注册表或启动文件夹）

### 5.5 UI 风格

采用 **Fluent Design** 风格，与 Windows 11 系统统一：

- 使用 WinUI 3 的 `NavigationView`（侧边栏导航）或 `TabView`（顶部标签）
- Fluent 配色（系统主题色自动适配浅色/深色模式）
- 圆角卡片布局
- 支持 Fluent UI Icons

### 5.6 窗口自适应

Windows 不支持折叠屏，但需支持：
- 窗口大小变化时 UI 自适应
- 支持窗口最大化/还原
- 支持多显示器

---

## 6. 功能清单

| # | 功能 | 说明 | 与 Android/鸿蒙对齐 |
|---|---|---|---|
| 1 | 设备发现 | UDP 广播自动发现同局域网设备，手动输入 IP 兜底 | ✅ |
| 2 | 发送文件 | 选照片/视频/任意文件（多选）→ 预览 → 选设备 → 发送 | ✅ |
| 3 | 接收文件 | 弹窗确认（白名单免确认）→ 保存到下载目录 | ✅ |
| 4 | 传输进度 | 总进度条 + 当前文件名 + 已传/总量 | ✅ |
| 5 | 实时速度 | KB/s / MB/s 显示 + 预计剩余时间 | ✅ |
| 6 | 暂停/继续 | 发送端暂停/继续传输 | ✅ |
| 7 | 断点续传 | transferId 一致性哈希 + .part 临时文件 | ✅ |
| 8 | 文件预览 | 发送前预览（缩略图/名称/大小，可移除单个） | ✅ |
| 9 | 传输日志 | 列表展示（时间、方向、对方设备、文件名、大小、结果）；支持单条删除、清空 | ✅ |
| 10 | 白名单 | 受信任设备免确认自动接收 | ✅ |
| 11 | 端口自动切换 | 47801~47811 尝试绑定 | ✅ |
| 12 | 网络容错 | WiFi 断开自动取消传输，临时文件保留 | ✅ |
| 13 | 设备名修改 | 设置页修改本机显示名 | ✅ |
| 14 | 深色模式 | Fluent Design 自动跟随系统主题 | ✅ |

---

## 7. 项目结构

```
E:\mobileApp\file-transfer\
├── android\              # 安卓版（已有）
├── harmonyos\            # 鸿蒙版（已有）
├── windows\              # Windows 版（新建）
│   ├── FalaiTransfer.sln       # 解决方案文件
│   ├── src\
│   │   ├── FalaiTransfer\      # WinUI 3 主项目
│   │   │   ├── FalaiTransfer.csproj
│   │   │   ├── App.xaml / App.xaml.cs
│   │   │   ├── MainWindow.xaml / MainWindow.xaml.cs
│   │   │   ├── Core\
│   │   │   │   ├── Protocol.cs         # 协议常量 + 帧读写
│   │   │   │   └── Format.cs           # 字节/速度/时间格式化
│   │   │   ├── Discovery\
│   │   │   │   └── DiscoveryService.cs # UDP 广播发现
│   │   │   ├── Transfer\
│   │   │   │   ├── TransferModels.cs   # 数据类/枚举
│   │   │   │   ├── TransferServer.cs   # TCP 接收服务端
│   │   │   │   ├── TransferClient.cs   # TCP 发送客户端
│   │   │   │   ├── TransferManager.cs  # 传输编排
│   │   │   │   └── FileIO.cs           # 文件选择/读取/保存
│   │   │   ├── Data\
│   │   │   │   └── LogRepository.cs    # 传输日志持久化
│   │   │   ├── UI\
│   │   │   │   ├── ViewModels\
│   │   │   │   │   ├── MainViewModel.cs
│   │   │   │   │   ├── TransferViewModel.cs
│   │   │   │   │   ├── LogViewModel.cs
│   │   │   │   │   └── SettingsViewModel.cs
│   │   │   │   ├── Views\
│   │   │   │   │   ├── MainPage.xaml / .xaml.cs
│   │   │   │   │   ├── TransferPage.xaml / .xaml.cs
│   │   │   │   │   ├── LogPage.xaml / .xaml.cs
│   │   │   │   │   ├── SettingsPage.xaml / .xaml.cs
│   │   │   │   │   └── Dialogs.xaml / .xaml.cs
│   │   │   │   └── Themes\
│   │   │   │       └── FluentTheme.xaml
│   │   │   └── Assets\               # 图标、资源
│   │   └── FalaiTransfer.Tests\      # 单元测试项目（可选）
│   ├── Directory.Build.props         # 公共构建属性
│   └── nuget.config                  # NuGet 源配置
├── tools\
│   └── pc_peer.py                    # PC 端协议模拟脚本（已有）
└── docs\
    ├── 方案.md                        # Android+鸿蒙方案
    └── 方案-windows.md                # 本方案
```

---

## 8. 构建与发布

### 8.1 开发环境

- **Python 3.12**（已有）
- **pip**（已有）
- Windows 11

### 8.2 依赖安装

```bash
cd windows
pip install customtkinter pyinstaller
```

### 8.3 运行

```bash
cd windows
python -m falai_transfer
```

### 8.4 打包 exe

```bash
cd windows
pyinstaller --onefile --name "发来" --windowed --icon=assets/icon.ico src/falai_transfer/__main__.py
```

- `--onefile`：单文件 exe
- `--windowed`：不弹出控制台窗口
- `--icon`：应用图标
- 输出在 `dist/发来.exe`

---

## 9. 与 pc_peer.py 的关系

已有 `tools/pc_peer.py` 可以作为 **自测工具** 和 **开发调试辅助**：

- 开发过程中用 `python pc_peer.py recv` 模拟手机接收端，验证 Windows 发送功能
- 用 `python pc_peer.py send <IP> <文件>` 模拟手机发送端，验证 Windows 接收功能
- 后续可将 `pc_peer.py` 升级为 Windows 版的调试模式（内置对端模拟器）

---

## 10. 开发计划与工时估算

| 阶段 | 内容 | 预估 | 依赖 |
|---|---|---|---|
| 1 | 环境搭建：安装 .NET SDK 8 + Visual Studio 2022，创建 WinUI 3 项目脚手架 | 1 h | 无 |
| 2 | 核心协议层：`Protocol.cs`（帧读写）+ `Format.cs`（格式化） | 1 h | 阶段 1 |
| 3 | 设备发现：`DiscoveryService.cs`（UDP 广播 + 监听 + 设备列表） | 2 h | 阶段 2 |
| 4 | 传输核心：`TransferServer.cs` + `TransferClient.cs`（TCP 收发、断点续传） | 3 h | 阶段 2 |
| 5 | 传输编排：`TransferManager.cs`（暂停/继续/取消/白名单/日志/网络监听） | 2 h | 阶段 3, 4 |
| 6 | 文件模块：`FileIO.cs`（文件选择器 + 流式读写 + 保存落点） | 2 h | 阶段 4 |
| 7 | 日志模块：`LogRepository.cs`（JSON 持久化） | 1 h | 阶段 5 |
| 8 | UI 开发：主页面 + 传输页 + 日志页 + 设置页（Fluent Design） | 4 h | 阶段 5~7 |
| 9 | UI 弹窗：发送预览弹窗 + 接收确认弹窗 + 传输进度弹窗 | 2 h | 阶段 8 |
| 10 | 联调测试：Windows ↔ Android 真机互传验证 | 2 h | 全阶段 |
| 11 | 打包发布：dotnet publish 生成独立 exe | 0.5 h | 阶段 10 |

**合计约 20 h**

---

## 11. 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| WinUI 3 成熟度 | 部分控件/功能可能有限制 | 优先使用稳定 API，必要时回退 WPF |
| Windows 防火墙拦截 | UDP/TCP 端口被防火墙阻止 | 首次启动时检测并提示用户放行；代码中不主动请求防火墙规则 |
| WiFi 断开检测 | Windows 网络事件与 Android 不同 | 使用 `NetworkChange.NetworkAddressChanged` + `NetworkInterface` 综合判断 |
| 文件缩略图获取 | 某些文件格式无缩略图 | `GetThumbnailAsync` 失败时显示默认文件图标 |
| 多网卡环境 | 可能广播到错误的网卡 | 收集所有局域网网卡的 broadcast 地址，广播到 `255.255.255.255` |

---

## 12. 待确认事项

1. **目标 Windows 版本**：Windows 10 1903+？还是仅 Windows 11？（影响 WinUI 3 最低要求）
2. **UI 框架**：WinUI 3（推荐）还是 WPF？（如果 VS 2022 未安装，WPF 更轻量）
3. **打包方式**：独立 exe（推荐一期）还是 MSIX？
4. **深色模式**：是否跟随系统主题？（推荐：是）
