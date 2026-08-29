@echo off
rem lsl-usb installer launcher (self-bootstrapping + PowerShell-resolution).
rem   - Resolves a PowerShell >= 5.1 to run install.ps1: uses pwsh if present,
rem     else Windows PowerShell 5.1+, else auto-fetches PORTABLE PowerShell 7.1
rem     (the last release that runs on Windows 7 SP1) - so Win7 works without WMF.
rem   - If install.ps1 is not beside this .bat, unzips lsl-usb-win.zip, or
rem     downloads LSL_RELEASE_URL, then runs.
rem cmd itself is not subject to the PS execution policy, so we pass
rem -ExecutionPolicy Bypass to the resolved PowerShell.
setlocal
cd /d "%~dp0"
rem --- distro recommendation (semi-support for WinXP+) -----------------------
rem We can't probe RAM reliably from a .bat on WinXP, so we only gate on CPU
rem architecture. A 64-bit CPU gets Mint Cinnamon 22.x (64-bit, ~2GB RAM); a
rem 32-bit CPU gets antiX 26 (i386 / antix26_386) for legacy hardware.
set "LSL_64BIT="
if "%PROCESSOR_ARCHITECTURE%"=="AMD64" set "LSL_64BIT=1"
if "%PROCESSOR_ARCHITECTURE%"=="IA64" set "LSL_64BIT=1"
if DEFINED PROCESSOR_ARCHITEW6432 set "LSL_64BIT=1"

echo.
echo lsl-usb - recommended distro for this PC:
if defined LSL_64BIT (
    echo   64-bit CPU detected  ->  Mint Cinnamon 22.x (64-bit, ~2GB RAM)
) else (
    echo   32-bit CPU detected  ->  antiX 26 (i386 / antix26_386)
)
echo   (confirm or change your choice in the installer)
echo.

rem Repo slug used to auto-fetch the latest release of lsl-usb-win.zip via the
rem direct latest-release download URL (no API token, no REST-API rate limit -
rem GitHub 302-redirects it to the asset). Override here (or via env LSL_REPO)
rem with your GitHub owner/name, or set LSL_RELEASE_URL to bypass auto-fetch.
if not defined LSL_REPO set "LSL_REPO=gmatht/lsl-usb"

rem --- resolve a PowerShell >= 5.1 to drive the installer --------------------
set "PS_EXE="

rem 1) Prefer resolve-powershell.ps1: handles pwsh + portable-pwsh auto-fetch.
if exist "%~dp0resolve-powershell.ps1" (
    for /f "delims=" %%e in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0resolve-powershell.ps1" 2^>nul') do set "PS_EXE=%%e"
)
if defined PS_EXE goto have_ps

rem 2) Fallback: a missing/old resolve-powershell.ps1 must never hide a working
rem    PowerShell. Prefer pwsh (PowerShell 7), else host Windows PowerShell 5.1.
rem    (Covers only-install.bat+install.ps1 copies, or running from PowerShell 7.)
rem    NOTE: keep these for/f loops OUT of any `if (...) (...)` block - cmd is not
rem    quote-aware for single quotes, so the `)` in the -Command string below
rem    would otherwise prematurely close a parenthesised `if` block.
for /f "delims=" %%r in ('pwsh -NoProfile -ExecutionPolicy Bypass -Command "if($PSVersionTable.PSVersion -ge [version]'5.1'){'OK'}" 2^>nul') do (
    if "%%r"=="OK" set "PS_EXE=pwsh"
)
if defined PS_EXE goto have_ps

for /f "delims=" %%r in ('powershell -NoProfile -ExecutionPolicy Bypass -Command "if($PSVersionTable.PSVersion -ge [version]'5.1'){'OK'}" 2^>nul') do (
    if "%%r"=="OK" set "PS_EXE=powershell"
)
if defined PS_EXE goto have_ps

echo ERROR: no PowerShell 5.1+ available and it could not be auto-fetched.
echo        Install Windows Management Framework 5.1 or PowerShell 7, then re-run.
pause
exit /b 1
:have_ps

if not exist "%~dp0install.ps1" (
    set "BUNDLE_URL="
    if defined LSL_RELEASE_URL ( set "BUNDLE_URL=%LSL_RELEASE_URL%" )
    if not defined BUNDLE_URL if not "%LSL_REPO%"=="OWNER/REPO" (
        echo Downloading the latest %LSL_REPO% release of lsl-usb-win.zip ...
        rem Direct latest-release download URL: no API token, no REST-API rate limit.
        rem Invoke-WebRequest follows GitHub's 302 redirect to the actual asset.
        set "BUNDLE_URL=https://github.com/%LSL_REPO%/releases/latest/download/lsl-usb-win.zip"
    )
    if not defined BUNDLE_URL (
        echo ERROR: install.ps1 not found next to this launcher and no download source.
        echo Set LSL_RELEASE_URL, or LSL_REPO, to auto-fetch the latest GitHub release of lsl-usb-win.zip.
        echo the latest GitHub release of lsl-usb-win.zip.
        pause
        exit /b 1
    )
    echo Downloading bundle from %BUNDLE_URL% ...
    %PS_EXE% -NoProfile -ExecutionPolicy Bypass -Command "$z='%TEMP%\lsl-usb-win.zip'; $x='%TEMP%\lsl-usb-win-x'; Invoke-WebRequest -Uri '%BUNDLE_URL%' -OutFile $z -UseBasicParsing; if(Test-Path $x){Remove-Item $x -Recurse -Force}; Expand-Archive $z $x -Force; $src=(Get-ChildItem $x -Recurse -Filter install.ps1 | Select-Object -First 1).DirectoryName; Copy-Item -Path (Join-Path $src '*') -Destination '%~dp0' -Recurse -Force"
)

rem Remove Mark-of-the-Web (Zone.Identifier) from the script if present.
%PS_EXE% -NoProfile -ExecutionPolicy Bypass -Command "Unblock-File -Path '%~dp0install.ps1' -ErrorAction SilentlyContinue" >nul 2>&1

%PS_EXE% -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
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
