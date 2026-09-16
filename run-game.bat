@echo off
setlocal
rem UTF-8 console codepage so the game's UTF-8 log output (Chinese)
rem renders correctly; the bat itself is ASCII-only so parsing is safe.
chcp 65001 >nul
rem Always run from the project root: the game resolves its assets/ folder
rem relative to the working directory, so launching from elsewhere (e.g. a
rem shortcut or "Run as administrator") would silently lose art and audio.
cd /d "%~dp0"
rem GUI entry (Windows). Prefers lovec (console build: logs visible in this
rem window and curl child processes reuse it instead of flashing new ones);
rem falls back to love. Local AI config: ai.env (KEY=VALUE, see
rem ai.env.example); env vars already set take precedence over the file.
if exist "%~dp0ai.env" (
  for /f "usebackq eol=# tokens=1,* delims==" %%A in ("%~dp0ai.env") do if not defined %%A set "%%A=%%B"
)
where lovec >nul 2>nul
if %errorlevel%==0 (
  lovec "%~dp0."
  exit /b %errorlevel%
)
if exist "%~dp0tools\love-win64\lovec.exe" (
  "%~dp0tools\love-win64\lovec.exe" "%~dp0."
  exit /b %errorlevel%
)
where love >nul 2>nul
if %errorlevel%==0 (
  love "%~dp0."
  exit /b %errorlevel%
)
if exist "%~dp0tools\love-win64\love.exe" (
  "%~dp0tools\love-win64\love.exe" "%~dp0."
  exit /b %errorlevel%
)
echo love.exe not found: run tools\get-love.bat to auto-download the portable
echo build, or install from https://love2d.org / unzip into tools\love-win64\
exit /b 1
