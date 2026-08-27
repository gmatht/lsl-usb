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

rem Repo slug used to auto-fetch the latest release of lsl-usb-win.zip via the
rem GitHub API. Override here (or via env LSL_REPO) with your GitHub owner/name.
if not defined LSL_REPO set "LSL_REPO=gmatht/lsl-usb"

rem --- resolve a PowerShell >= 5.1 to drive the installer --------------------
set "PS_EXE="
for /f "delims=" %%e in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0resolve-powershell.ps1" 2^>nul') do set "PS_EXE=%%e"
if not defined PS_EXE (
    echo ERROR: no PowerShell 5.1+ available and it could not be auto-fetched.
    echo        Install Windows Management Framework 5.1 or PowerShell 7, then re-run.
    pause
    exit /b 1
)

if not exist "%~dp0install.ps1" (
    set "BUNDLE_URL="
    if defined LSL_RELEASE_URL ( set "BUNDLE_URL=%LSL_RELEASE_URL%" )
    if not defined BUNDLE_URL if not "%LSL_REPO%"=="OWNER/REPO" (
        echo Querying GitHub for the latest %LSL_REPO% release of lsl-usb-win.zip ...
        for /f "delims=" %%u in ('%PS_EXE% -NoProfile -ExecutionPolicy Bypass -Command "$repo='%LSL_REPO%'; try { $r=Invoke-RestMethod -Uri \"https://api.github.com/repos/$repo/releases/latest\" -Headers @{'User-Agent'='lsl-usb'}; ($r.assets ^| Where-Object { $_.name -eq 'lsl-usb-win.zip' } ^| Select-Object -First 1).browser_download_url } catch { Write-Error $_; exit 1 }"') do set "BUNDLE_URL=%%u"
    )
    if not defined BUNDLE_URL (
        echo ERROR: install.ps1 not found next to this launcher and no download source.
        echo Set LSL_RELEASE_URL, or LSL_REPO (your GitHub owner/name) to auto-fetch
        echo the latest GitHub release of lsl-usb-win.zip.
        pause
        exit /b 1
    )
    echo Downloading bundle from %BUNDLE_URL% ...
    %PS_EXE% -NoProfile -ExecutionPolicy Bypass -Command ^
      "$z='%TEMP%\lsl-usb-win.zip'; $x='%TEMP%\lsl-usb-win-x'; Invoke-WebRequest -Uri '%BUNDLE_URL%' -OutFile $z -UseBasicParsing; if(Test-Path $x){Remove-Item $x -Recurse -Force}; Expand-Archive $z $x -Force; $src=(Get-ChildItem $x -Recurse -Filter install.ps1 | Select-Object -First 1).DirectoryName; Copy-Item -Path (Join-Path $src '*') -Destination '%~dp0' -Recurse -Force"
)

rem Remove Mark-of-the-Web (Zone.Identifier) from the script if present.
%PS_EXE% -NoProfile -ExecutionPolicy Bypass -Command ^
  "Unblock-File -Path '%~dp0install.ps1' -ErrorAction SilentlyContinue" >nul 2>&1

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
