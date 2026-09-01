# resolve-powershell.ps1 - print a PowerShell >= 5.1 executable path.
#
# Runs under ANY PowerShell (even 2.0 on Windows 7), so it can bootstrap before
# install.ps1 itself runs. Resolution order:
#   1. pwsh on PATH, if its version is >= 5.1
#   2. the host Windows PowerShell, if >= 5.1
#   3. otherwise download the PORTABLE PowerShell 7.1 zip (the last release that
#      still runs on Windows 7 SP1) and use that - no install, no reboot.
$ErrorActionPreference = 'Stop'

function Resolve-Existing {
    # A broken pwsh install must not abort detection; fall through to the host.
    try {
        $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
        if ($pwsh) {
            $v = & $pwsh.Path -NoProfile -Command '$PSVersionTable.PSVersion' 2>$null
            if ($v -and ([version]$v -ge [version]'5.1')) { return $pwsh.Path }
        }
    } catch {}
    if ($PSVersionTable.PSVersion -ge [version]'5.1') { return 'powershell' }
    return $null
}

$exe = Resolve-Existing
if ($exe) { Write-Output $exe; exit 0 }

# --- fetch portable PowerShell 7.1 (Windows 7 SP1 compatible) ---------------
$arch = if ($env:PROCESSOR_ARCHITEW6432 -eq 'AMD64' -or $env:PROCESSOR_ARCHITECTURE -eq 'AMD64') { 'x64' } else { 'x86' }
$ver = '7.1.5'
$url = "https://github.com/PowerShell/PowerShell/releases/download/v$ver/PowerShell-$ver-win-$arch.zip"
$cache = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'lsl-usb\pwsh'
if (!(Test-Path $cache)) { New-Item -ItemType Directory -Force -Path $cache | Out-Null }
$zip = Join-Path $cache 'pwsh.zip'
$pwshExe = Join-Path $cache 'pwsh.exe'
if (!(Test-Path $pwshExe)) {
    (New-Object System.Net.WebClient).DownloadFile($url, $zip)
    # Unzip via Shell.Application so this works on old PowerShell without Expand-Archive.
    $shell = New-Object -ComObject Shell.Application
    $src = $shell.NameSpace($zip)
    $dst = $shell.NameSpace($cache)
    $dst.CopyHere($src.Items(), 0x10)   # 0x10 = respond "yes to all"
    for ($i = 0; $i -lt 60; $i++) { if (Test-Path $pwshExe) { break }; Start-Sleep -Seconds 2 }
}
if (!(Test-Path $pwshExe)) { Write-Error "Failed to fetch portable PowerShell 7.1 from $url"; exit 1 }
Write-Output $pwshExe
