@echo off
chcp 65001 >nul
setlocal
rem 联机图形客户端（Windows 版）：play.bat [名字] [host] [端口]
set "NAME=%~1"
set "HOST=%~2"
set "PORT=%~3"
if "%NAME%"=="" set "NAME=我"
if "%HOST%"=="" set "HOST=127.0.0.1"
if "%PORT%"=="" set "PORT=9527"
set "ROOT=%~dp0.."

where love >nul 2>nul
if %errorlevel%==0 (
  love "%ROOT%." --client %NAME% %HOST% %PORT%
  exit /b %errorlevel%
)
if exist "%~dp0love-win64\love.exe" (
  "%~dp0love-win64\love.exe" "%ROOT%." --client %NAME% %HOST% %PORT%
  exit /b %errorlevel%
)
echo 未找到 love.exe：可先运行 tools\get-love.bat 自动下载便携版，
echo 或从 https://love2d.org 安装 / 把 zip 解压到 tools\love-win64\
exit /b 1
