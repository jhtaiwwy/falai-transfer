@echo off
REM 去除 -flavor 参数，因为 lld-link 不需要它
setlocal enabledelayedexpansion
set args=%*
set args=!args:-flavor link =!
set args=!args:-flavor=!
"C:\Users\jht\.rustup\toolchains\stable-x86_64-pc-windows-msvc\lib\rustlib\x86_64-pc-windows-msvc\bin\gcc-ld\lld-link.exe" %args%