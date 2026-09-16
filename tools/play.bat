@echo off
setlocal
rem UTF-8 console codepage so the game's UTF-8 log output (Chinese)
rem renders correctly; the bat itself is ASCII-only so parsing is safe.
chcp 65001 >nul
rem Multiplayer GUI client (Windows): play.bat [name] [host] [port].
rem Local AI config: ai.env (KEY=VALUE, see ai.env.example); env vars already
rem set take precedence over the file. Prefers lovec for visible client logs.
set "NAME=%~1"
set "HOST=%~2"
set "PORT=%~3"
if "%NAME%"=="" set "NAME=Player"
if "%HOST%"=="" set "HOST=127.0.0.1"
if "%PORT%"=="" set "PORT=9527"
set "ROOT=%~dp0.."
rem Run from the project root so assets/ resolves (audio+art), whatever
rem directory the caller happens to be in.
cd /d "%ROOT%"
if exist "%ROOT%\ai.env" (
  for /f "usebackq eol=# tokens=1,* delims==" %%A in ("%ROOT%\ai.env") do if not defined %%A set "%%A=%%B"
)

where lovec >nul 2>nul
if %errorlevel%==0 (
  lovec "%ROOT%." --client %NAME% %HOST% %PORT%
  exit /b %errorlevel%
)
if exist "%~dp0love-win64\lovec.exe" (
  "%~dp0love-win64\lovec.exe" "%ROOT%." --client %NAME% %HOST% %PORT%
  exit /b %errorlevel%
)
where love >nul 2>nul
if %errorlevel%==0 (
  love "%ROOT%." --client %NAME% %HOST% %PORT%
  exit /b %errorlevel%
)
if exist "%~dp0love-win64\love.exe" (
  "%~dp0love-win64\love.exe" "%ROOT%." --client %NAME% %HOST% %PORT%
  exit /b %errorlevel%
)
echo love.exe not found: run tools\get-love.bat first, or see https://love2d.org
exit /b 1
