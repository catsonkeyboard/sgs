@echo off
chcp 65001 >nul
setlocal
rem 联机服务端（Windows 版）：serve.bat [端口] [座位数]，默认 9527 / 5 座
set "PORT=%~1"
set "SEATS=%~2"
if "%PORT%"=="" set "PORT=9527"
if "%SEATS%"=="" set "SEATS=5"
set "ROOT=%~dp0.."

where love >nul 2>nul
if %errorlevel%==0 (
  love "%ROOT%." --serve %PORT% %SEATS%
  exit /b %errorlevel%
)
if exist "%~dp0love-win64\love.exe" (
  "%~dp0love-win64\love.exe" "%ROOT%." --serve %PORT% %SEATS%
  exit /b %errorlevel%
)
echo 未找到 love.exe：可先运行 tools\get-love.bat 自动下载便携版，
echo 或从 https://love2d.org 安装 / 把 zip 解压到 tools\love-win64\
exit /b 1
