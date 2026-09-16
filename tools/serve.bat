@echo off
setlocal
rem UTF-8 console codepage so the game's UTF-8 log output (Chinese)
rem renders correctly; the bat itself is ASCII-only so parsing is safe.
chcp 65001 >nul
rem Multiplayer server (Windows): serve.bat [port] [seats], default 9527 / 5.
rem Local AI config: ai.env (KEY=VALUE, see ai.env.example); env vars already
rem set take precedence over the file. Prefers lovec for visible server logs.
set "PORT=%~1"
set "SEATS=%~2"
if "%PORT%"=="" set "PORT=9527"
if "%SEATS%"=="" set "SEATS=5"
set "ROOT=%~dp0.."
rem Run from the project root so assets/ resolves (audio+art), whatever
rem directory the caller happens to be in.
cd /d "%ROOT%"
if exist "%ROOT%\ai.env" (
  for /f "usebackq eol=# tokens=1,* delims==" %%A in ("%ROOT%\ai.env") do if not defined %%A set "%%A=%%B"
)

where lovec >nul 2>nul
if %errorlevel%==0 (
  lovec "%ROOT%." --serve %PORT% %SEATS%
  exit /b %errorlevel%
)
if exist "%~dp0love-win64\lovec.exe" (
  "%~dp0love-win64\lovec.exe" "%ROOT%." --serve %PORT% %SEATS%
  exit /b %errorlevel%
)
where love >nul 2>nul
if %errorlevel%==0 (
  love "%ROOT%." --serve %PORT% %SEATS%
  exit /b %errorlevel%
)
if exist "%~dp0love-win64\love.exe" (
  "%~dp0love-win64\love.exe" "%ROOT%." --serve %PORT% %SEATS%
  exit /b %errorlevel%
)
echo love.exe not found: run tools\get-love.bat first, or see https://love2d.org
exit /b 1
