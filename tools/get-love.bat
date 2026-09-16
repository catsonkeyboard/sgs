@echo off
setlocal
rem One-time bootstrap: download LOVE 11.5 (portable Windows build) and
rem unzip it into tools\love-win64\ . After that run-game.bat / run-tests.bat
rem / serve.bat / play.bat work out of the box.
rem Requires Windows 10 1803+ (bundled curl and tar); on older systems follow
rem the hints below to download manually.
set "ROOT=%~dp0"
set "DEST=%ROOT%love-win64"
set "ZIP=%ROOT%love-11.5-win64.zip"
set "URL=https://github.com/love2d/love/releases/download/11.5/love-11.5-win64.zip"

if exist "%DEST%\love.exe" (
  echo Found %DEST%\love.exe already, nothing to download.
  exit /b 0
)

where curl >nul 2>nul
if not %errorlevel%==0 (
  echo curl not found - bundled with Windows 10 1803+. Please download and
  echo unzip manually: %URL%  -^>  %DEST%
  exit /b 1
)

echo Downloading LOVE 11.5 (~40MB from github.com/love2d)...
curl -L --fail -o "%ZIP%" "%URL%"
if not %errorlevel%==0 (
  echo Download failed: check your network/proxy, or download manually
  echo from https://love2d.org
  if exist "%ZIP%" del "%ZIP%"
  exit /b 1
)

echo Extracting...
if exist "%ROOT%_love_tmp" rmdir /s /q "%ROOT%_love_tmp"
mkdir "%ROOT%_love_tmp"
tar -xf "%ZIP%" -C "%ROOT%_love_tmp" 2>nul
if not %errorlevel%==0 (
  echo tar not available, falling back to PowerShell Expand-Archive...
  powershell -NoProfile -Command "Expand-Archive -LiteralPath '%ZIP%' -DestinationPath '%ROOT%_love_tmp'"
)
rem the zip contains an inner love-11.5-win64\ folder; move it into place
move "%ROOT%_love_tmp\love-11.5-win64" "%DEST%" >nul 2>nul
if not exist "%DEST%\love.exe" move "%ROOT%_love_tmp\love-11.5.0-win64" "%DEST%" >nul 2>nul
rmdir /s /q "%ROOT%_love_tmp"
del "%ZIP%"

if exist "%DEST%\love.exe" (
  echo Done: %DEST%\love.exe
  echo You can now run run-game.bat / run-tests.bat
  exit /b 0
)
echo Extraction failed: love.exe not found under %DEST% - please download
echo %URL% manually and unzip it into %DEST%
exit /b 1
