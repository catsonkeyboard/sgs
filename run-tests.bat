@echo off
setlocal
rem UTF-8 console codepage so the game's UTF-8 log output (Chinese)
rem renders correctly; the bat itself is ASCII-only so parsing is safe.
chcp 65001 >nul
rem Headless tests (Windows): static lint (python, skipped if absent)
rem + unit/gameplay tests. Prefers lovec for visible console output.
set "ROOT=%~dp0"

where lovec >nul 2>nul
if %errorlevel%==0 (
  set "LOVE=lovec"
  goto :lint
)
where love >nul 2>nul
if %errorlevel%==0 (
  set "LOVE=love"
  goto :lint
)
if exist "%ROOT%tools\love-win64\lovec.exe" (
  set "LOVE=%ROOT%tools\love-win64\lovec.exe"
  goto :lint
)
if exist "%ROOT%tools\love-win64\love.exe" (
  set "LOVE=%ROOT%tools\love-win64\love.exe"
  goto :lint
)
echo love.exe not found: run tools\get-love.bat first, or see https://love2d.org
exit /b 1

:lint
echo == static lint: method definitions/calls ==
where python >nul 2>nul
if %errorlevel%==0 (
  python "%ROOT%tools\lint_methods.py" "%ROOT%src" "%ROOT%tests"
) else (
  echo python not found, skipping static lint
)

echo.
echo == gameplay and unit tests ==
"%LOVE%" "%ROOT%." --test
exit /b %errorlevel%
