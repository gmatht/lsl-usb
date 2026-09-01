# lsl-win-detect.ps1 - Windows-side detection shared by install.ps1 and its
# GUI runspaces (kept in one place so fixes apply everywhere).
function Get-LocalAppData {
    $d = $env:LOCALAPPDATA
    if (-not $d) { $d = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'AppData\Local' }
    return $d
}
function Get-WslVhdxPaths {
    param([string[]]$Extra = @())
    $found = @()

    # 1) Registry: HKCU + HKLM \Software\Microsoft\Windows\CurrentVersion\Lxss.
    #    Each distro is a GUID subkey with BasePath (the directory the distro
    #    lives in - handles custom locations like D:\WSL\Ubuntu2404) and
    #    Version (1 = WSL1, 2 = WSL2). For WSL2 the disk image is
    #    BasePath\ext4.vhdx. WSL1 has no vhdx (plain rootfs dir), so skip.
    foreach ($root in @('HKCU:', 'HKLM:')) {
        if (-not (Test-Path $root)) { continue }   # registry PSDrive absent (e.g. non-Windows)
        $lxss = Join-Path $root 'Software\Microsoft\Windows\CurrentVersion\Lxss'
        if (-not (Test-Path $lxss)) { continue }
        foreach ($key in Get-ChildItem $lxss -ErrorAction SilentlyContinue) {
            try {
                # Some Lxss subkeys (e.g. Notifications) are not distros; read
                # properties defensively (StrictMode-safe, no throw on missing).
                $props = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
                if (-not $props) { continue }
                $bpProp = $props.PSObject.Properties['BasePath']
                if (-not $bpProp) { continue }
                $bp = $bpProp.Value
                if (-not $bp) { continue }
                # Strip the Win32 extended-length prefix (\\?\C:\...) which
                # breaks Join-Path drive parsing (e.g. Docker's WSL distro).
                $bp = $bp -replace '^\\\\\?\\', ''
                if (-not $bp) { continue }
                $verProp = $props.PSObject.Properties['Version']
                $ver = if ($verProp) { $verProp.Value } else { $null }
                if ($ver -eq 2) {
                    $vhdx = Join-Path $bp 'ext4.vhdx'
                    if (Test-Path $vhdx) { $found += $vhdx }
                }
            } catch {
                Write-Warn2 "Skipping Lxss subkey $($key.PSChildName): $($_.Exception.Message)"
            }
        }
    }

    # 2) Fallback scan: default Store locations (covers stale/missing registry).
    $pkgRoot = Join-Path (Get-LocalAppData) 'Packages'
    if (Test-Path $pkgRoot) {
        $found += Get-ChildItem -Path $pkgRoot -Recurse -Filter 'ext4.vhdx' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\LocalState\\ext4\.vhdx$' } |
            ForEach-Object { $_.FullName }
    }
    $lxssLegacy = Join-Path (Get-LocalAppData) 'lxss\ext4.vhdx'
    if (Test-Path $lxssLegacy) { $found += $lxssLegacy }

    $found += @($Extra | Where-Object { $_ })
    return ,@($found | Select-Object -Unique)
}
function Get-InstalledWindowsApps {
    # DisplayName from the standard Uninstall registry keys (HKCU + HKLM, 32/64-bit).
    $names = @()
    $roots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($r in $roots) {
        if (-not (Test-Path (Split-Path $r -Parent))) { continue }
        $names += Get-ItemProperty $r -ErrorAction SilentlyContinue |
            Where-Object { $_ -and $_.PSObject.Properties['DisplayName'] -and $_.PSObject.Properties['DisplayName'].Value } |
            ForEach-Object { $_.PSObject.Properties['DisplayName'].Value }
    }
    return ,@($names | Select-Object -Unique | Sort-Object)
}
