@echo off
echo 正在构建 HarmonyOS APP 包...
cd /d E:\mobileApp\file-transfer\harmonyos
hvigorw assembleApp
echo.
echo 构建完成！
echo APP 包位置：entry\build\default\outputs\default\
pause
