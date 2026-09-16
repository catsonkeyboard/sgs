@echo off
chcp 65001 >nul
setlocal
rem 图形界面（Windows 版）：优先 PATH 里的 love，其次便携版 tools\love-win64\
where love >nul 2>nul
if %errorlevel%==0 (
  love "%~dp0."
  exit /b %errorlevel%
)
if exist "%~dp0tools\love-win64\love.exe" (
  "%~dp0tools\love-win64\love.exe" "%~dp0."
  exit /b %errorlevel%
)
echo 未找到 love.exe：可先运行 tools\get-love.bat 自动下载便携版，
echo 或从 https://love2d.org 安装 / 把 zip 解压到 tools\love-win64\
exit /b 1
