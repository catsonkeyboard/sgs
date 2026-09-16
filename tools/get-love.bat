@echo off
chcp 65001 >nul
setlocal
rem 一次性引导：下载 LÖVE 11.5（Windows 便携版）并解压到 tools\love-win64\
rem 之后 run-game.bat / run-tests.bat / serve.bat / play.bat 都能直接用。
rem 需要 Windows 10 1803+（自带 curl 与 tar）；老系统按提示手动下载即可。
set "ROOT=%~dp0"
set "DEST=%ROOT%love-win64"
set "ZIP=%ROOT%love-11.5.0-win64.zip"
set "URL=https://github.com/love2d/love/releases/download/11.5/love-11.5.0-win64.zip"

if exist "%DEST%\love.exe" (
  echo 已存在 %DEST%\love.exe，无需下载。
  exit /b 0
)

where curl >nul 2>nul
if not %errorlevel%==0 (
  echo 未找到 curl（Windows 10 1803+ 自带）。请手动下载并解压：
  echo   %URL%
  echo   解压到 %DEST%
  exit /b 1
)

echo 正在下载 LÖVE 11.5（约 40MB，来自 github.com/love2d）…
curl -L --fail -o "%ZIP%" "%URL%"
if not %errorlevel%==0 (
  echo 下载失败：请检查网络（或代理），也可手动从 https://love2d.org 下载。
  if exist "%ZIP%" del "%ZIP%"
  exit /b 1
)

echo 解压…
if exist "%ROOT%_love_tmp" rmdir /s /q "%ROOT%_love_tmp"
mkdir "%ROOT%_love_tmp"
tar -xf "%ZIP%" -C "%ROOT%_love_tmp" 2>nul
if not %errorlevel%==0 (
  echo tar 不可用，改用 PowerShell 解压…
  powershell -NoProfile -Command "Expand-Archive -LiteralPath '%ZIP%' -DestinationPath '%ROOT%_love_tmp'"
)
rem zip 内层目录是 love-11.5.0-win64\，挪到约定位置
move "%ROOT%_love_tmp\love-11.5.0-win64" "%DEST%" >nul 2>nul
rmdir /s /q "%ROOT%_love_tmp"
del "%ZIP%"

if exist "%DEST%\love.exe" (
  echo 完成：%DEST%\love.exe
  echo 现在可以运行 run-game.bat / run-tests.bat 了。
  exit /b 0
)
echo 解压结果异常：未找到 %DEST%\love.exe，请手动下载 %URL% 并解压到 %DEST%
exit /b 1
