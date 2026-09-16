@echo off
chcp 65001 >nul
setlocal
rem 无头测试（Windows 版）：静态检查（需 python，缺了跳过）+ 单测/对局测试
set "ROOT=%~dp0"

where love >nul 2>nul
if %errorlevel%==0 (
  set "LOVE=love"
  goto :lint
)
if exist "%ROOT%tools\love-win64\love.exe" (
  set "LOVE=%ROOT%tools\love-win64\love.exe"
  goto :lint
)
echo 未找到 love.exe：可先运行 tools\get-love.bat 自动下载便携版，
echo 或从 https://love2d.org 安装 / 把 zip 解压到 tools\love-win64\
exit /b 1

:lint
echo == 静态检查：方法定义/调用语法 ==
where python >nul 2>nul
if %errorlevel%==0 (
  python "%ROOT%tools\lint_methods.py" "%ROOT%src" "%ROOT%tests"
) else (
  echo （未找到 python，跳过静态检查）
)

echo.
echo == 对局与单元测试 ==
"%LOVE%" "%ROOT%." --test
exit /b %errorlevel%
