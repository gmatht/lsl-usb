@echo off
rem lsl-usb installer launcher (self-bootstrapping + PowerShell-resolution).
rem   - Resolves a PowerShell >= 5.1 to run install.ps1: uses pwsh if present,
rem     else Windows PowerShell 5.1+, else auto-fetches PORTABLE PowerShell 7.1
rem     (the last release that runs on Windows 7 SP1) - so Win7 works without WMF.
rem   - If install.ps1 is not beside this .bat, unzips lsl-usb-win.zip, or
rem     downloads LSL_RELEASE_URL, then runs.
rem cmd itself is not subject to the PS execution policy, so we pass
rem -ExecutionPolicy Bypass to the resolved PowerShell.
setlocal EnableDelayedExpansion
cd /d "%~dp0"
rem --- distro recommendation (semi-support for WinXP+) -----------------------
rem Probe CPU arch + total RAM (wmic os get TotalVisibleMemorySize, in KB),
rem then recommend: 64-bit CPU + >=2GB RAM -> Mint Cinnamon 22.x; else antiX
rem 26 (i386 / antix26_386). The user confirms or changes the choice later.
set "LSL_64BIT="
if "%PROCESSOR_ARCHITECTURE%"=="AMD64" set "LSL_64BIT=1"
if "%PROCESSOR_ARCHITECTURE%"=="IA64" set "LSL_64BIT=1"
if DEFINED PROCESSOR_ARCHITEW6432 set "LSL_64BIT=1"

set "LSL_RAM_KB="
for /f "skip=1 tokens=*" %%m in ('wmic os get TotalVisibleMemorySize 2^>nul') do (
    if not defined LSL_RAM_KB set /a LSL_RAM_KB=%%m 2>nul
)

set "LSL_RECO=Mint Cinnamon 22.x (64-bit, >=2GB RAM)"
if not defined LSL_64BIT set "LSL_RECO=antiX 26 (i386 / antix26_386)"
if defined LSL_64BIT if defined LSL_RAM_KB if %LSL_RAM_KB% LSS 2097152 set "LSL_RECO=antiX 26 (i386 / antix26_386)"

echo.
echo lsl-usb - recommended distro for this PC:  %LSL_RECO%
if defined LSL_RAM_KB (
    echo   RAM detected: %LSL_RAM_KB% KB   ^(choose what you want via: wmic os get TotalVisibleMemorySize^)
) else (
    echo   RAM detected: unknown ^(wmic unavailable^)   ^(choose what you want via: wmic os get TotalVisibleMemorySize^)
)
echo   Confirm or change your choice in the installer.
echo.

rem --- detect Windows older than XP SP2: text-only fallback -----------------
rem Win2000 / XP SP0-SP1 (and anything the parser can't read) have no usable
rem HTA / PowerShell path, so we do as much as a .bat can with a text UI:
rem recommend a distro, find an ISO, find/launch Rufus, print boot steps.
set "LSL_WIN_VER="
set "LSL_WIN_MAJ=0"
set "LSL_WIN_MIN=0"
for /f "tokens=2 delims=[]" %%v in ('ver') do set "LSL_WIN_VER=%%v"
if defined LSL_WIN_VER for /f "tokens=2,3 delims=.^ " %%a in ("%LSL_WIN_VER%") do set "LSL_WIN_MAJ=%%a" & set "LSL_WIN_MIN=%%b"
set "LSL_XP_SP_OK="
if "%LSL_WIN_MAJ%"=="5" if "%LSL_WIN_MIN%"=="1" (
    rem XP: need SP2+. The SP lives in CSDVersion ("Service Pack 2").
    for /f "tokens=3,4,5" %%a in ('reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CSDVersion 2^>nul') do (
        if "%%a"=="Service" if "%%b"=="Pack" if %%c GEQ 2 set "LSL_XP_SP_OK=1"
        if "%%a"=="SP" if %%c GEQ 2 set "LSL_XP_SP_OK=1"
    )
)
set "LSL_OLDWIN="
if %LSL_WIN_MAJ% LSS 5 set "LSL_OLDWIN=1"
if %LSL_WIN_MAJ% EQU 5 if %LSL_WIN_MIN% LSS 1 set "LSL_OLDWIN=1"
if %LSL_WIN_MAJ% EQU 5 if %LSL_WIN_MIN% EQU 1 if not defined LSL_XP_SP_OK set "LSL_OLDWIN=1"
if defined LSL_OLDWIN goto old_win_text

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

if exist "%~dp0install-xp.hta" (
    echo No PowerShell 5.1+ ^(XP/older?^). Falling back to the legacy HTA GUI:
    echo   %~dp0install-xp.hta
    echo   ^(arch + TotalVisibleMemorySize based recommendation; ISO via BITS or browser,
    echo    then writes the USB with Rufus^)
    start "" "%~dp0install-xp.hta"
    exit /b 0
)
echo ERROR: no PowerShell 5.1+ available and it could not be auto-fetched.
echo        Install Windows Management Framework 5.1 or PowerShell 7, then re-run.
pause
exit /b 1
:have_ps

if not exist "%~dp0install.ps1" (
    set "BUNDLE_URL="
    if defined LSL_RELEASE_URL ( set "BUNDLE_URL=!LSL_RELEASE_URL!" )
    if not defined BUNDLE_URL if not "!LSL_REPO!"=="OWNER/REPO" (
        echo Downloading the latest !LSL_REPO! release of lsl-usb-win.zip ...
        rem Direct latest-release download URL: no API token, no REST-API rate limit.
        rem Invoke-WebRequest follows GitHub's 302 redirect to the actual asset.
        set "BUNDLE_URL=https://github.com/!LSL_REPO!/releases/latest/download/lsl-usb-win.zip"
    )
    if not defined BUNDLE_URL (
        echo ERROR: install.ps1 not found next to this launcher and no download source.
        echo Set LSL_RELEASE_URL, or LSL_REPO, to auto-fetch the latest GitHub release of lsl-usb-win.zip.
        pause
        exit /b 1
    )
    echo Downloading bundle from !BUNDLE_URL! ...
    %PS_EXE% -NoProfile -ExecutionPolicy Bypass -Command "$z='%TEMP%\lsl-usb-win.zip'; $x='%TEMP%\lsl-usb-win-x'; Invoke-WebRequest -Uri '!BUNDLE_URL!' -OutFile $z -UseBasicParsing; if(Test-Path $x){Remove-Item $x -Recurse -Force}; Expand-Archive $z $x -Force; $src=(Get-ChildItem $x -Recurse -Filter install.ps1 | Select-Object -First 1).DirectoryName; Copy-Item -Path (Join-Path $src '*') -Destination '%~dp0' -Recurse -Force"
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

rem ===========================================================================
rem Text-only fallback for Windows older than XP SP2 (no HTA / PowerShell).
rem Does as much as a .bat can: recommends a distro, finds an ISO, finds or
rem prompts for Rufus, launches Rufus, and prints boot instructions.
rem ===========================================================================
:old_win_text
echo.
echo ==========================================================================
echo  Windows older than XP SP2 detected - text-only fallback.
echo  ^(install-xp.hta / PowerShell need XP SP2 or newer^)
echo ==========================================================================
echo  Recommended distro for this PC:  %LSL_RECO%
echo.

rem --- find an ISO in the usual places ---------------------------------------
set "LSL_ISO="
call :oldwin_find_iso "%USERPROFILE%\Downloads"
call :oldwin_find_iso "%USERPROFILE%\Desktop"
call :oldwin_find_iso "%USERPROFILE%\My Documents"
call :oldwin_find_iso "%USERPROFILE%\Documents"
if not defined LSL_ISO call :oldwin_find_iso "%SystemDrive%\"
if defined LSL_ISO (
    echo  Found ISO: %LSL_ISO%
) else (
    echo  No .iso found in the usual folders.
)
set /p "LSL_ISO_IN=  ISO path ^(Enter=keep the one above, type a path, or '.'=none^): "
if defined LSL_ISO_IN if not "%LSL_ISO_IN%"=="." set "LSL_ISO=%LSL_ISO_IN%"
if defined LSL_ISO_IN if "%LSL_ISO_IN%"=="." set "LSL_ISO="

rem --- find or prompt for Rufus ----------------------------------------------
set "LSL_RUFUS="
if exist "%SystemDrive%\rufus.exe" set "LSL_RUFUS=%SystemDrive%\rufus.exe"
if not defined LSL_RUFUS if exist "%USERPROFILE%\Desktop\rufus.exe" set "LSL_RUFUS=%USERPROFILE%\Desktop\rufus.exe"
if not defined LSL_RUFUS if exist "%USERPROFILE%\Downloads\rufus.exe" set "LSL_RUFUS=%USERPROFILE%\Downloads\rufus.exe"
if defined LSL_RUFUS (
    echo  Found Rufus: %LSL_RUFUS%
) else (
    echo  rufus.exe not found. Get it from https://rufus.akeo.ie/
    set /p "LSL_RUFUS_IN=  Path to rufus.exe ^(blank=skip launching^): "
    if defined LSL_RUFUS_IN set "LSL_RUFUS=%LSL_RUFUS_IN%"
)
if not defined LSL_RUFUS goto old_win_info

rem --- launch Rufus ----------------------------------------------------------
echo.
set /p "LSL_GO=  Launch Rufus to write the USB now? [y/N]: "
if /i not "%LSL_GO%"=="y" goto old_win_info
if defined LSL_ISO (
    start "" "%LSL_RUFUS%" -i "%LSL_ISO%"
) else (
    start "" "%LSL_RUFUS%"
)
echo  Rufus launched: %LSL_RUFUS%
goto old_win_info

:oldwin_find_iso
rem %~1 = folder; sets LSL_ISO to the first *.iso if not already set.
if defined LSL_ISO goto :eof
if not exist "%~1\" goto :eof
for %%f in ("%~1\*.iso") do (
    if not defined LSL_ISO (
        if not "%%~f"=="%~1\*.iso" set "LSL_ISO=%%~f"
    )
)
goto :eof

:old_win_info
echo.
echo  After writing, BOOT FROM THE USB.
echo  First boot runs the minimal layer script ^(installs packages, then persists a new layer^).
echo  Set LSL_DATA_DIR in /cdrom/lsl-usb.env if you do not want the default.
pause
exit /b 0
