@echo off
rem lsl-usb installer launcher (self-bootstrapping).
rem   - If install.ps1 is beside this .bat, just runs it (after clearing the
rem     Mark-of-the-Web so execution policy / SmartScreen don't block it).
rem   - If not, and lsl-usb-win.zip is beside it, unzips that bundle first.
rem   - If LSL_RELEASE_URL is set, downloads + unzips that bundle first.
rem cmd itself is not subject to the PS execution policy, so we pass
rem -ExecutionPolicy Bypass to powershell.
setlocal
cd /d "%~dp0"

if not exist "%~dp0install.ps1" (
    if exist "%~dp0lsl-usb-win.zip" (
        echo Unzipping lsl-usb-win.zip beside this launcher...
        powershell -NoProfile -ExecutionPolicy Bypass -Command ^
          "$z='%~dp0lsl-usb-win.zip'; $x='%TEMP%\lsl-usb-win-x'; if(Test-Path $x){Remove-Item $x -Recurse -Force}; Expand-Archive $z $x -Force; $src=(Get-ChildItem $x -Recurse -Filter install.ps1 | Select-Object -First 1).DirectoryName; Copy-Item -Path (Join-Path $src '*') -Destination '%~dp0' -Recurse -Force"
    ) else if defined LSL_RELEASE_URL (
        echo Downloading bundle from %LSL_RELEASE_URL% ...
        powershell -NoProfile -ExecutionPolicy Bypass -Command ^
          "$z='%TEMP%\lsl-usb-win.zip'; $x='%TEMP%\lsl-usb-win-x'; Invoke-WebRequest -Uri '%LSL_RELEASE_URL%' -OutFile $z -UseBasicParsing; if(Test-Path $x){Remove-Item $x -Recurse -Force}; Expand-Archive $z $x -Force; $src=(Get-ChildItem $x -Recurse -Filter install.ps1 | Select-Object -First 1).DirectoryName; Copy-Item -Path (Join-Path $src '*') -Destination '%~dp0' -Recurse -Force"
    ) else (
        echo ERROR: install.ps1 not found next to this launcher.
        echo Place the lsl-usb bundle (install.ps1, bin\, onboot.sh, ...) here,
        echo OR put lsl-usb-win.zip next to this .bat, OR set LSL_RELEASE_URL.
        pause
        exit /b 1
    )
)

rem Remove Mark-of-the-Web (Zone.Identifier) from the script if present.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Unblock-File -Path '%~dp0install.ps1' -ErrorAction SilentlyContinue" >nul 2>&1

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
set RC=%ERRORLEVEL%

rem Ctrl-C during the GUI leaves a marker: quit immediately, no pause.
if exist "%TEMP%\lsl-cancelled" (
    del "%TEMP%\lsl-cancelled" >nul 2>&1
    exit /b 2
)

rem Exit code 2 = user cancelled in the GUI: quit immediately, no pause.
if "%RC%"=="2" exit /b 2

echo.
if not "%RC%"=="0" (
    echo install.ps1 exited with code %RC%.
    echo Logs also land on the target USB under casper - lsl-firstboot-logs and uproot-logs.
)
pause
exit /b %RC%
