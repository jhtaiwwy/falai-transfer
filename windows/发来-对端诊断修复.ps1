param(
    [switch]$Fix
)

$ErrorActionPreference = "SilentlyContinue"
$OutputEncoding = [System.Text.Encoding]::UTF8

function Line { param($t) Write-Host $t }

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  发来 · 接收端网络诊断（请在【接收方】电脑上运行）" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Line ""

# ---------- 1. 主机与地址 ----------
Write-Host "[1] 本机信息" -ForegroundColor Yellow
Line ("    计算机名 : " + $env:COMPUTERNAME)
$ips = Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" }
if ($ips) {
    foreach ($ip in $ips) {
        Line ("    IP 地址  : {0} /{1}  ({2})" -f $ip.IPAddress, $ip.PrefixLength, $ip.InterfaceAlias)
    }
} else {
    Line "    !! 没有有效的局域网 IPv4 地址（未连上任何网络）"
}
$profiles = Get-NetConnectionProfile
if ($profiles) {
    foreach ($p in $profiles) {
        Line ("    网络位置 : {0} -> {1}" -f $p.Name, $p.NetworkCategory)
        if ($p.NetworkCategory -eq "Public") {
            Line "       ^ 公用网络，Windows 默认拦截一切入站连接，必须放行防火墙"
        }
    }
} else {
    Line "    !! 未识别网络（网络位置为空，极可能是断网状态）"
}
Line ""

# ---------- 2. 端口监听 ----------
Write-Host "[2] 「发来」是否在监听端口" -ForegroundColor Yellow
$listen = netstat -ano | Select-String "LISTENING" | Select-String ":4780[0-9]|:4781[01]"
if ($listen) {
    foreach ($l in $listen) { Line ("    " + $l.Line.Trim()) }
    Line "    -> 接收服务已启动"
} else {
    Line "    !! 没有 47800~47811 的监听"
    Line "    -> 「发来」未运行，或启动时端口绑定失败（被占用 / 被安全软件拦截）"
}
$udp = netstat -ano | Select-String "UDP" | Select-String ":47800"
if ($udp) { Line "    UDP 47800 已监听（设备发现正常）" } else { Line "    !! UDP 47800 未监听（设备发现异常）" }
Line ""

# ---------- 3. 进程 ----------
Write-Host "[3] 「发来」进程" -ForegroundColor Yellow
$proc = Get-Process | Where-Object { $_.ProcessName -like "*发来*" -or $_.ProcessName -like "*falai*" }
$exePath = $null
if ($proc) {
    foreach ($p in $proc) {
        Line ("    PID {0}  {1}" -f $p.Id, $p.Path)
        if (-not $exePath -and $p.Path) { $exePath = $p.Path }
    }
} else {
    Line "    !! 进程未运行，请先启动「发来」再测试"
}
if (-not $exePath) {
    $candidates = @(
        (Join-Path $env:ProgramFiles "发来\发来.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "发来\发来.exe"),
        (Join-Path $env:LOCALAPPDATA "发来\发来.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\发来\发来.exe")
    )
    foreach ($c in $candidates) { if (Test-Path $c) { $exePath = $c; break } }
}
if ($exePath) { Line ("    程序路径 : " + $exePath) }
Line ""

# ---------- 4. 防火墙 ----------
Write-Host "[4] 防火墙状态与「发来」规则" -ForegroundColor Yellow
$fw = Get-NetFirewallProfile
foreach ($f in $fw) {
    Line ("    {0,-8} 启用={1,-5} 入站默认={2}" -f $f.Name, $f.Enabled, $f.DefaultInboundAction)
}
$rules = Get-NetFirewallRule | Where-Object { $_.DisplayName -match "发来|falai" }
if ($rules) {
    foreach ($r in $rules) {
        $app = ($r | Get-NetFirewallApplicationFilter).Program
        $port = ($r | Get-NetFirewallPortFilter)
        Line ("    规则: {0} | {1} | {2} | proto={3} port={4}" -f $r.DisplayName, $r.Enabled, $r.Profile, $port.Protocol, $port.LocalPort)
        if ($app) { Line ("          程序: " + $app) }
    }
} else {
    Line "    !! 没有任何「发来」防火墙规则 —— 这就是对方不弹窗、发送端 10060 超时的直接原因"
}
Line ""

# ---------- 5. 修复 ----------
if ($Fix) {
    Write-Host "[5] 执行修复：放行防火墙入站" -ForegroundColor Yellow
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Line "    !! 需要管理员权限：请右键此脚本 -> 使用 PowerShell 运行（管理员）"
    } else {
        if (-not $exePath) {
            Line "    !! 找不到「发来.exe」路径，请先启动一次程序，或手动指定路径"
        } else {
            Get-NetFirewallRule | Where-Object { $_.DisplayName -match "^发来-文件传输" } | Remove-NetFirewallRule
            New-NetFirewallRule -DisplayName "发来-文件传输(TCP)" -Direction Inbound -Action Allow -Profile Any -Program $exePath -Protocol TCP -LocalPort "47801-47811" | Out-Null
            New-NetFirewallRule -DisplayName "发来-文件传输(UDP)" -Direction Inbound -Action Allow -Profile Any -Program $exePath -Protocol UDP -LocalPort "47800" | Out-Null
            Line "    已添加入站放行规则：TCP 47801-47811 / UDP 47800（所有网络位置）"
            Line "    并把程序加入「专用+公用」网络允许列表"
        }
    }
    Line ""
} else {
    Write-Host "[5] 如需自动修复，请用管理员身份重新运行：" -ForegroundColor Yellow
    Line ("    powershell -ExecutionPolicy Bypass -File `"" + $PSCommandPath + "`" -Fix")
    Line ""
}

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  请把以上结果截图，与发送端机器对比这两点：" -ForegroundColor Cyan
Write-Host "  1) 两台机器的 IP 是否在同一网段（前三段相同）" -ForegroundColor Cyan
Write-Host "  2) 接收端是否已有「发来」的入站放行规则" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
if (-not $Fix) { Read-Host "按回车退出" }
