<#requires -Version 5.1
#
.SYNOPSIS
    lsl-usb Windows installer: creates the Ubuntu-24.04-based live USB (via Rufus)
    and drops the lsl-usb layer + config + wifi script onto it.

.DESCRIPTION
    Steps:
      1. Resolve an Ubuntu-24.04-based live ISO (Linux Mint 22.x, Zorin 18.x, ...).
         If none is given, offer to download the latest Mint 22.x Cinnamon ISO
         (linuxmint-<ver>-cinnamon-64bit.iso) and verify it against the official
         sha256sum.txt.
      2. Ensure Rufus is present (auto-download from GitHub releases if missing,
         Authenticode-verified against "Akeo Consulting").
      3. Launch Rufus with the ISO pre-selected. The user clicks START (safety gate),
         then the script waits for the write to complete.
      4. Drop the lsl-usb files onto the USB (layer squashfs, bin/, onboot.sh,
         lsl-usb.env, systemd/).
      5. Generate /wifi.sh from Windows' saved wifi profiles (netsh) so the live
         boot can rejoin the same network.

.COMPATIBILITY
    Supported  : Ubuntu 24.04 based distros - Linux Mint 22.x (22.0 - 22.3),
                 Zorin OS 18.x, etc.
    NOT supported: Ubuntu 26.04+ - it still uses NetworkManager, but its
                 nmcli is broken, so the nmcli-based tooling in onboot.sh /
                 wifi.sh / persist-wifi.sh breaks. The installer refuses these.

.PARAMETER IsoPath
    Path to an existing live ISO. If omitted and -SkipIsoDownload is not set, the
    script offers to download linuxmint-<MintVersion>-cinnamon-64bit.iso.

.PARAMETER MintVersion
    Mint 22.x point release to download (default: latest known, e.g. 22.3).

.PARAMETER DownloadDir
    Folder for the downloaded ISO (default: %USERPROFILE%\Downloads).

.PARAMETER BundleDir
    Folder containing the lsl files to drop onto the USB: filesystem_z0_firstboot.squashfs,
    bin/, onboot.sh, lsl-usb.env, systemd/ (default: this script's folder).

.PARAMETER RufusPath
    Path to rufus.exe; auto-downloaded to %LOCALAPPDATA%\lsl-usb\tools if missing.

.PARAMETER VolumeLabel
    Optional USB volume label to target (default: auto-detect the volume that ends
    up containing casper\filesystem.squashfs).

.PARAMETER WslVhdx
    Extra WSL VHDX paths to pass to Linux (beyond those found via the Lxss
    registry key and the default Packages scan). Written to
    <USB>\lsl-wsl-vhdx.conf; Linux converts them to /mnt/<letter>/... at boot
    and lsl/lsl-gui can mount them via guestmount.

.PARAMETER SkipRufus
    Do not launch Rufus; wait for a Mint live USB to appear (e.g. you write the
    image yourself) and continue with the lsl-usb file drop.

.PARAMETER DryRun
    Detection-only mode: prints everything that would be detected and passed to
    the Linux install (ISO, Rufus, USB target, WSL VHDX paths, wifi profiles,
    bundle contents) without downloading, launching Rufus, or writing anything.

.EXAMPLE
    .\install.ps1                          # full flow, downloads Mint 22.x ISO
    .\install.ps1 -IsoPath C:\ISO\zorin-18.1.iso
    .\install.ps1 -IsoPath ... -SkipIsoDownload
#>

[CmdletBinding()]
param(
    [string]$IsoPath,
    [string]$MintVersion = '22.3',
    [string]$DownloadDir = '',
    [string]$BundleDir = '',
    [string]$RufusPath = '',
    [string]$VolumeLabel = '',
    [string[]]$WslVhdx = @(),
    [string[]]$FlatpakApps = @(),
    [switch]$SkipIsoDownload,
    [switch]$SkipRufus,
    [switch]$NoGui,
    [switch]$DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
# PS 5.1 defaults to TLS 1.0/1.1, which modern mirrors reject. Prefer 1.2+1.3;
# fall back to 1.2 alone on .NET Framework builds without the Tls13 enum.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
} catch {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

# $PSScriptRoot is not reliably available inside the param block (PS 5.1 quirk),
# so resolve the bundle dir here.
if (-not $BundleDir) { $BundleDir = $PSScriptRoot }

function WriteStep([string]$msg) {
    Write-Host ''
    Write-Host "==> $msg" -ForegroundColor Cyan
}

function Write-Info([string]$msg) { Write-Host "    $msg" -ForegroundColor Gray }
function Write-Warn2([string]$msg) { Write-Host "    WARNING: $msg" -ForegroundColor Yellow }
function Write-Err2([string]$msg) { Write-Host "    ERROR: $msg" -ForegroundColor Red }

# ---------------------------------------------------------------------------
# Compatibility note shown to the user at the start.
# ---------------------------------------------------------------------------
function Show-CompatNotes {
    WriteStep 'Compatibility:'
    Write-Info '  Supported   : Ubuntu 24.04 based live distros - Linux Mint 22.x, Zorin OS 18.x.'
    Write-Info '  NOT supported: Ubuntu 26.04+ (still uses NetworkManager, but its nmcli is broken,'
    Write-Info '                so the nmcli-based wifi tooling in onboot.sh / wifi.sh breaks).'
}

function Get-UserDownloadsDir {
    $profileDir = [Environment]::GetFolderPath('UserProfile')
    if (-not $profileDir) { $profileDir = $env:USERPROFILE }
    if (-not $profileDir) { throw 'Cannot determine user profile directory.' }
    return (Join-Path $profileDir 'Downloads')
}


# ---------------------------------------------------------------------------
# Rufus: locate, download (GitHub releases), Authenticode-verify.
# ---------------------------------------------------------------------------
function Get-Rufus {
    param([string]$Path = '')
    if ($Path) { return $Path }                                       # caller supplied

    $cacheDir = Join-Path (Get-LocalAppData) 'lsl-usb\tools'
    $exe = Join-Path $cacheDir 'rufus.exe'
    if (Test-Path $exe) { Write-Info "Using cached Rufus: $exe"; return $exe }

    New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
    $headers = @{ 'User-Agent' = 'lsl-usb-installer/1.0' }            # GitHub API requires this
    Write-Info 'Looking up the latest Rufus release on GitHub...'
    $rel = Invoke-RestMethod -Headers $headers `
        -Uri 'https://api.github.com/repos/pbatard/rufus/releases/latest'
    $asset = $rel.assets | Where-Object { $_.name -match '^rufus-\d+\.\d+\.exe$' } | Select-Object -First 1
    if (-not $asset) { throw "No rufus.exe asset found in release $($rel.tag_name)" }

    $tmp = Join-Path $env:TEMP $asset.name
    Write-Info "Downloading $($asset.name) ($([math]::Round($asset.size/1MB,1)) MB)..."
    Invoke-WebRequest -UseBasicParsing -Uri $asset.browser_download_url -OutFile $tmp

    $sig = Get-AuthenticodeSignature $tmp
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Akeo Consulting') {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        throw "Rufus download failed Authenticode verification (publisher: $($sig.SignerCertificate.Subject))."
    }
    Move-Item -Force $tmp $exe
    Write-Info "Verified (Authenticode, Akeo Consulting). Saved: $exe"
    return $exe
}

function Download {
    param([string]$Url, [string]$Destination)
    if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
        Start-BitsTransfer -Source $Url -Destination $Destination
    } else {
        Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Destination
    }
}

function Get-EverythingPath {
    # Locate voidtools Everything CLI (es.exe): PATH, or next to Everything.exe
    # in the common install locations.
    $cands = @()
    $cands += Get-Command es.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, (Get-LocalAppData))) {
        if ($base) { $cands += Join-Path $base 'Everything\es.exe' }
    }
    foreach ($c in ($cands | Select-Object -Unique)) {
        if (Test-Path $c -PathType Leaf) { return $c }
    }
    return ''
}

function Install-Everything {
    # Download the Everything portable (voidtools), extract it, and launch it so
    # the index builds - then es.exe works for ISO discovery and EFU export.
    # Returns the es.exe path, or '' on failure.
    $dir = Join-Path (Get-LocalAppData) 'lsl-usb\tools\Everything'
    $es = Join-Path $dir 'es.exe'
    if (Test-Path $es) { return $es }
    $zip = Join-Path $env:TEMP 'Everything-portable.zip'
    $url = 'https://www.voidtools.com/Everything-1.4.1.1026.x64.zip'
    Write-Info 'Downloading Everything (voidtools) portable...'
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip -ErrorAction Stop
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Expand-Archive -Path $zip -DestinationPath $dir -Force
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Warn2 "Everything download failed: $($_.Exception.Message)"
        return ''
    }
    if (-not (Test-Path $es)) { Write-Warn2 'Everything portable did not contain es.exe.'; return '' }
    # Verify the extracted Everything.exe is Authenticode-signed by voidtools
    # (voidtools publishes no checksum for the zip, so the signature is the
    # trust anchor - same approach as the Rufus download).
    $exe = Join-Path $dir 'Everything.exe'
    if (Test-Path $exe) {
        $sig = Get-AuthenticodeSignature $exe
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'voidtools') {
            Write-Warn2 "Everything.exe failed Authenticode verification (publisher: $($sig.SignerCertificate.Subject))."
            return ''
        }
    }
    # Launch it so the index builds (it runs in the background; es.exe works once
    # the index is ready).
    if (Test-Path $exe) { Start-Process -FilePath $exe | Out-Null }
    Write-Info "Everything installed to $dir - its index is building in the background (it will index your drives; es.exe works once ready)."
    return $es
}

function Find-EverythingIsos {
    # Use Everything's index (fast, whole-disk) to find .iso files, newest first.
    # Returns an empty array when Everything is absent or its index is not running.
    $es = Get-EverythingPath
    if (-not $es) { return ,@() }
    $raw = & $es -sort date-modified-descending *.iso 2>&1
    if ($LASTEXITCODE -ne 0) { return ,@() }   # Everything index not available
    $paths = @($raw | Where-Object { $_ -match '^[A-Za-z]:\\' -and $_ -match '\.iso$' } |
        Select-Object -First 20)
    return ,$paths
}

function Select-ExistingIso {
    # Offer the ISOs Everything found; returns the chosen path or '' to download.
    $isos = Find-EverythingIsos
    if (-not $isos) { return '' }
    WriteStep "Found $($isos.Count) existing ISO image(s) via Everything (voidtools):"
    for ($i = 0; $i -lt $isos.Count; $i++) {
        $sz = ''
        if (Test-Path $isos[$i] -PathType Leaf) {
            $sz = '  ' + [math]::Round((Get-Item $isos[$i]).Length / 1GB, 2) + ' GB'
        }
        Write-Info ('  {0,2}. {1}{2}' -f ($i + 1), $isos[$i], $sz)
    }
    try {
        $ans = Read-Host 'Use an existing ISO? Enter its number, or press Enter to download a fresh Mint ISO'
        $n = 0
        if ($ans -and [int]::TryParse($ans, [ref]$n) -and $n -ge 1 -and $n -le $isos.Count) {
            return $isos[$n - 1]
        }
    } catch { }
    return ''
}

# ---------------------------------------------------------------------------
# ISO: resolve an existing one, or offer to download Mint 22.x.
# ---------------------------------------------------------------------------
function Resolve-Iso {
    param(
        [string]$Path,
        [string]$MintVersion,
        [string]$DownloadDir,
        [switch]$AutoDownload
    )
    if ($Path) {
        if (-not (Test-Path $Path -PathType Leaf)) { throw "ISO not found: $Path" }
        Write-Info "Using provided ISO: $Path"
        return (Resolve-Path $Path).Path
    }

    # Offer an existing ISO found via Everything before downloading anything.
    $existing = Select-ExistingIso
    if ($existing) {
        Write-Info "Using existing ISO: $existing"
        return (Resolve-Path $existing).Path
    }

    if (-not $AutoDownload) { throw 'No ISO given and download disabled (-SkipIsoDownload).' }
    if (-not $DownloadDir) { $DownloadDir = Get-UserDownloadsDir }

    $isoName = "linuxmint-$MintVersion-cinnamon-64bit.iso"
    $dest = Join-Path $DownloadDir $isoName
    $base = "https://mirrors.kernel.org/linuxmint/stable/$MintVersion"
    if (-not (Test-Path $dest)) {
        New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null
        WriteStep "Downloading $isoName (~3 GB) from $base ..."
        Download "$base/$isoName" $dest
    } else {
        Write-Info "ISO already present: $dest"
    }
    Write-Info 'Verifying SHA-256 against the official sha256sum.txt...'
    # Self-contained (no dependency on $base) so this can never be unset.
    $sumUrl = "https://mirrors.kernel.org/linuxmint/stable/$MintVersion/sha256sum.txt"
    # Route through the same BITS-first Download as the ISO: plain
    # Invoke-WebRequest (.NET TLS stack) fails against mirrors.kernel.org on
    # some PowerShell 5.1 builds with "connection closed on send".
    $sumFile = Join-Path $DownloadDir 'sha256sum.txt'
    Download $sumUrl $sumFile
    $sum = Get-Content $sumFile -Raw -ErrorAction Stop
    Remove-Item $sumFile -Force -ErrorAction SilentlyContinue
    $expected = ($sum -split "`n" | Where-Object { $_ -match [regex]::Escape($isoName) }) -split '\s+' | Select-Object -First 1
    if (-not $expected) { throw "No checksum entry for $isoName in $sumUrl" }
    $actual = (Get-FileHash -Algorithm SHA256 $dest).Hash.ToLowerInvariant()
    if ($expected.ToLowerInvariant() -ne $actual) {
        Remove-Item $dest -Force -ErrorAction SilentlyContinue
        throw "SHA256 mismatch for $isoName. Download deleted; try again or fetch manually."
    }
    Write-Info 'SHA256 verified.'
    return $dest
}

# ---------------------------------------------------------------------------
# ISO validation: mount, check casper layout + os-release version.
# ---------------------------------------------------------------------------
function Test-LiveIso {
    param([string]$Iso)
    WriteStep "Validating $Iso ..."
    $img = Mount-DiskImage -ImagePath $Iso -PassThru
    try {
        $vol = $img | Get-Volume
        $root = "$($vol.DriveLetter):\"
        if (-not (Test-Path (Join-Path $root 'casper\filesystem.squashfs'))) {
            throw "Not a casper/Ubuntu-family live image (no casper\filesystem.squashfs)."
        }
        # os-release is inside casper/filesystem.squashfs, not on the ISO root.
        # The reliable ISO-root markers are the apt suite codenames in dists\
        # (noble = Ubuntu 24.04) and the human-readable .disk\info.
        $dists = @()
        $distsDir = Join-Path $root 'dists'
        if (Test-Path $distsDir) {
            $dists = @(Get-ChildItem $distsDir -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { $_.Name })
        }
        $diskInfo = ''
        $diskInfoFile = Join-Path $root '.disk\info'
        if (Test-Path $diskInfoFile) {
            $diskInfo = (Get-Content $diskInfoFile -Raw -ErrorAction SilentlyContinue).Trim()
        }
        Write-Info "Image info: $diskInfo"
        Write-Info "dists codenames: $($dists -join ', ')"

        # Ubuntu 26.04+ still uses NetworkManager, but its nmcli is broken,
        # so the nmcli-based wifi tooling in onboot.sh / wifi.sh breaks -> refuse.
        if ($diskInfo -match '26\.04') {
            throw "Ubuntu 26.04+ detected ($diskInfo). Not supported: it still uses NetworkManager, but its nmcli is broken, so the nmcli-based wifi tooling breaks. Use an Ubuntu 24.04 based image (Mint 22.x, Zorin 18.x)."
        }
        if (($dists | Where-Object { $_ -ieq 'noble' })) {
            Write-Info 'Confirmed Ubuntu 24.04 base (dists/noble) - supported.'
        } elseif ($dists.Count -gt 0) {
            throw "Not an Ubuntu 24.04 based image (dists codenames: $($dists -join ', ')). Only Ubuntu 24.04 based images (Mint 22.x, Zorin 18.x) are supported."
        } else {
            Write-Warn2 "No dists codenames found; cannot confirm the Ubuntu 24.04 base."
        }
        Write-Info "ISO validation passed."
    } finally {
        Dismount-DiskImage -ImagePath $Iso -ErrorAction SilentlyContinue | Out-Null
    }
}

# ---------------------------------------------------------------------------
# USB volume detection + wait for the Rufus write to land.
# ---------------------------------------------------------------------------
function Find-UsbVolumes {
    param([string]$Label = '', [string[]]$ExcludeLetters = @())
    # The definitive signals are the casper layout and the volume label, not
    # the bus type - USB SSDs often enumerate as DriveType=Fixed and some
    # sticks report a non-USB bus, so a bus-type filter can miss the stick we
    # just wrote. Checking every lettered volume is cheap (one stat each).
    # Exclude CD-ROM: mounted Mint ISOs look identical (same casper layout,
    # same label) but are not the USB we wrote.
    $found = @()
    foreach ($v in @(Get-Volume -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveLetter -and $_.DriveType -ne 'CD-ROM' -and $ExcludeLetters -notcontains $_.DriveLetter } | Sort-Object DriveLetter)) {
        $root = "$($v.DriveLetter):\"
        if ($Label -and $v.FileSystemLabel -match $Label) { $found += $v; continue }
        if (Test-Path (Join-Path $root 'casper\filesystem.squashfs')) { $found += $v }
    }
    # No comma here: callers use @(Find-UsbVolumes ...), and @() does NOT
    # unwrap a comma-wrapped return (it would leave $found[0] as the inner
    # array). Plain return + @() at the call site is the correct pattern.
    return $found
}

function Find-UsbVolume {
    param([string]$Label = '', [string[]]$ExcludeLetters = @())
    $found = @(Find-UsbVolumes -Label $Label -ExcludeLetters $ExcludeLetters)
    if ($found.Count -gt 0) { return $found[0] }
    return $null
}

# Offer to reuse an existing Mint live USB instead of re-writing it via Rufus.
function Select-ExistingUsb {
    param([string]$Label = '')
    $found = @(Find-UsbVolumes -Label $Label)
    if ($found.Count -eq 0) { return $null }

    WriteStep 'Existing Mint live USB detected'
    for ($i = 0; $i -lt $found.Count; $i++) {
        $v = $found[$i]
        $root = "$($v.DriveLetter):\"
        $lsl = (Test-Path (Join-Path $root 'bin\uproot')) -or (Test-Path (Join-Path $root 'lsl-usb.env'))
        $kind = if ($lsl) { 'lsl-usb (update)' } else { 'plain Mint live (first install)' }
        $sfs = Join-Path $root 'casper\filesystem.squashfs'
        $img = if (Test-Path $sfs) { '  ' + [math]::Round((Get-Item $sfs).Length/1GB, 2) + ' GB image' } else { '' }
        $desc = '{0,2}. {1}:  {2}  {3} GB  {4}{5}' -f ($i + 1), $v.DriveLetter, $v.FileSystemLabel, [math]::Round($v.Size/1GB, 1), $kind, $img
        Write-Info $desc
    }
    Write-Info 'Reusing skips the ISO download and the Rufus re-write; the lsl-usb files are dropped in place.'
    $ans = Read-Host "Choose a USB [1..$($found.Count)] to install lsl-usb onto now, or 0 to write fresh via Rufus"
    $n = 0
    if ([int]::TryParse($ans, [ref]$n) -and $n -ge 1 -and $n -le $found.Count) {
        return $found[$n - 1]
    }
    return $null
}

function Wait-UsbReady {
    param([string]$Label = '', [System.Diagnostics.Process]$RufusProc = $null, [int]$TimeoutSec = 0, [string[]]$KnownVolumes = @())
    # KnownVolumes = drive letters present before Rufus launched. Prefer a
    # volume that appeared since (the freshly-written stick), falling back to
    # any match - with several Mint USBs attached, the first by letter may not
    # be the one we just wrote.
    # TimeoutSec is opt-in (for automation). The default (0) waits as long as
    # the user needs - this is an interactive flow and a spurious timeout on a
    # slow write is worse than the console sitting open. Ctrl+C aborts.
    WriteStep 'Waiting for Rufus to finish writing the USB...'
    Write-Info 'Rufus shows DONE when the write completes. Close it and this step continues;'
    Write-Info 'it also continues automatically once the written USB becomes visible.'
    Write-Info 'No timeout - take your time (Ctrl+C to abort).'
    $deadline = if ($TimeoutSec -gt 0) { (Get-Date).AddSeconds($TimeoutSec) } else { $null }
    $lastSize = -1; $stable = 0; $ticks = 0
    while ($true) {
        if ($deadline -and (Get-Date) -ge $deadline) {
            throw 'Timed out waiting for the USB write to complete.'
        }
        # Primary signal: the user closed Rufus. Then wait for the fresh volume
        # to show up (Windows may take a moment to assign a drive letter), with
        # a periodic nudge instead of a hard deadline.
        $rufusGone = @(Get-Process -Name 'rufus' -ErrorAction SilentlyContinue).Count -eq 0
        if ($rufusGone -and $RufusProc) {
            Write-Info 'Rufus was closed - confirming the written USB is visible...'
            for ($i = 0; ; $i++) {
                if ($deadline -and (Get-Date) -ge $deadline) {
                    throw 'Timed out waiting for the USB write to complete.'
                }
                $vol = Find-UsbVolume -Label $Label -ExcludeLetters $KnownVolumes
                if (-not $vol) { $vol = Find-UsbVolume -Label $Label }
                if ($vol) { return $vol }
                if (($i % 30) -eq 29) {
                    Write-Info '  still waiting for a Mint live volume - plug the USB in if needed, or press Ctrl+C to abort.'
                }
                Start-Sleep -Seconds 2
            }
        }
        # Backup signal: volume already detectable with a stable squashfs
        # (user left Rufus open). Prefer a volume that appeared since launch.
        $vol = Find-UsbVolume -Label $Label -ExcludeLetters $KnownVolumes
        if (-not $vol) { $vol = Find-UsbVolume -Label $Label }
        if ($vol) {
            $sfs = Join-Path "$($vol.DriveLetter):\" 'casper\filesystem.squashfs'
            if (Test-Path $sfs) {
                $size = (Get-Item $sfs).Length
                if ($size -eq $lastSize) { $stable++ } else { $stable = 0 }
                $lastSize = $size
                Write-Info "  filesystem.squashfs present ($([math]::Round($size/1GB,2)) GB), sample $stable/3"
                if ($stable -ge 3) { return $vol }
            }
        }
        Start-Sleep -Seconds 2
        if (($ticks++ % 30) -eq 29) {
            Write-Info '  still waiting for the Rufus write (close Rufus when it shows DONE, or wait for the USB to appear)...'
        }
    }
}

# ---------------------------------------------------------------------------
# Wifi: extract Windows' saved profiles via netsh, emit wifi.sh lines.
# ---------------------------------------------------------------------------
function Get-WifiProfileNames {
    # Windows' saved wifi profile names (for the GUI picker).
    if (-not (Get-Command netsh -ErrorAction SilentlyContinue)) { return ,@() }
    $names = netsh wlan show profiles |
        Select-String -Pattern ':\s*([^:\r\n]+)$' |
        ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() } |
        Where-Object { $_ }
    return ,@($names | Select-Object -Unique)
}

function Get-WifiLines {
    param([string[]]$Profiles)   # pre-supplied list (for testing); empty = read from netsh
    $lines = @()
    if (-not (Get-Command netsh -ErrorAction SilentlyContinue)) { return ,$lines }
    if (-not $Profiles) {
        $Profiles = netsh wlan show profiles |
            Select-String -Pattern ':\s*([^:\r\n]+)$' |
            ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() } |
            Where-Object { $_ }
    }
    foreach ($n in $Profiles) {
        $detail = netsh wlan show profile name="$n" key=clear
        $m = $detail | Select-String -Pattern 'Key Content\s*:\s*(.+)$'
        if (-not $m) { continue }   # open network or password not saved
        $psk = $m[0].Matches[0].Groups[1].Value.Trim()
        $ssid = $n -replace "'", "'\''"
        $pass = $psk -replace "'", "'\''"
        $lines += "nmcli device wifi connect '$ssid' password '$pass'"
    }
    return ,$lines
}

# ---------------------------------------------------------------------------
# WSL VHDX: locate Windows-side WSL disk images and write them to the USB so
# Linux (detect-wsl) can mount them via guestmount. One Windows path per line
# in /cdrom/lsl-wsl-vhdx.conf; Linux converts C:\... to /mnt/c/... at boot.
# ---------------------------------------------------------------------------


function Get-FlatpakSuggestions {
    # Curated map: Windows app name fragment -> flathub app id.
    $map = @(
        @{ match = 'Slack';              id = 'com.slack.Slack' },
        @{ match = 'Discord';            id = 'com.discordapp.Discord' },
        @{ match = 'Spotify';            id = 'com.spotify.Client' },
        @{ match = 'Visual Studio Code'; id = 'com.visualstudio.code' },
        @{ match = 'Telegram';           id = 'org.telegram.desktop' },
        @{ match = 'Zoom';               id = 'us.zoom.Zoom' },
        @{ match = 'Obsidian';           id = 'md.obsidian.Obsidian' },
        @{ match = 'GIMP';               id = 'org.gimp.GIMP' },
        @{ match = 'Inkscape';           id = 'org.inkscape.Inkscape' },
        @{ match = 'Blender';            id = 'org.blender.Blender' },
        @{ match = 'OBS';                id = 'com.obsproject.Studio' },
        @{ match = 'Steam';              id = 'com.valvesoftware.Steam' },
        @{ match = 'VLC';                id = 'org.videolan.VLC' },
        @{ match = 'Firefox';            id = 'org.mozilla.firefox' },
        @{ match = 'Docker';             id = 'com.docker.Desktop' },
        @{ match = 'VirtualBox';         id = 'org.virtualbox.VirtualBox' }
    )
    $installed = Get-InstalledWindowsApps
    $found = @()
    foreach ($m in $map) {
        $matched = [bool]($installed | Where-Object { $_ -match [regex]::Escape($m.match) })
        $found += [pscustomobject]@{ App = $m.match; FlatpakId = $m.id; Matched = $matched }
    }
    return ,$found
}

function Write-EverythingEfu {
    # Export Everything's index (EFU = CSV file list) to the USB so Linux can
    # browse the Windows drives without scanning them. Can be large (millions
    # of rows) - that is the point: it is the whole index.
    param($Vol)
    $es = Get-EverythingPath
    if (-not $es) { Write-Warn2 'Everything not found; skipping EFU export.'; return }
    # The full index can be large (millions of rows) - check the USB has room
    # before writing, so we do not fail mid-export.
    $volInfo = Get-Volume -DriveLetter $Vol.DriveLetter -ErrorAction SilentlyContinue
    if ($volInfo -and $volInfo.SizeRemaining -lt 1GB) {
        Write-Warn2 "USB has only $([math]::Round($volInfo.SizeRemaining/1MB,0)) MB free - skipping the EFU export (it can be hundreds of MB)."
        return
    }
    $dest = "$($Vol.DriveLetter):\find_everything.efu"
    Write-Info 'Exporting the Everything index - this may take a minute for large indexes...'
    try {
        & $es -export-efu $dest 2>$null
        if (Test-Path $dest) {
            $mb = [math]::Round((Get-Item $dest).Length / 1MB, 1)
            Write-Info "Exported Everything index to find_everything.efu ($mb MB)"
        } else {
            Write-Warn2 'Everything export produced no file.'
        }
    } catch {
        Write-Warn2 "Everything export failed: $($_.Exception.Message)"
    }
}

function Write-FlatpakRefs {
    # Write tiny .flatpakref files (deterministic flathub URLs) to the USB so
    # first boot can 'flatpak install --from' them. The app payload itself is
    # fetched at first boot (network); the selection is preconfigured here.
    param($Vol, [string[]]$Extra = @())
    $sugg = Get-FlatpakSuggestions
    $ids = @($sugg | Where-Object { $_.Matched } | ForEach-Object { $_.FlatpakId }) + @($Extra | Where-Object { $_ })
    $ids = @($ids | Select-Object -Unique)
    if (-not $ids) { Write-Warn2 'No flatpak suggestions (no matching installed Windows apps).'; return }
    $dir = "$($Vol.DriveLetter):\flatpaks"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    foreach ($id in $ids) {
        $ref = Join-Path $dir "$id.flatpakref"
        try {
            # BITS-first Download (same as the ISO/checksum): plain
            # Invoke-WebRequest (.NET TLS stack) fails on some systems.
            Download "https://dl.flathub.org/repo/appstream/$id.flatpakref" $ref
            if (-not (Test-Path $ref) -or (Get-Item $ref).Length -eq 0) {
                throw 'empty download'
            }
            Write-Info "  wrote $id.flatpakref"
        } catch {
            Remove-Item $ref -Force -ErrorAction SilentlyContinue
            Write-Warn2 "  could not fetch $id.flatpakref: $($_.Exception.Message)"
        }
    }
    Write-Info "Flatpak refs in $dir - first boot runs 'flatpak install --from' on each."
}

# ---------------------------------------------------------------------------
# lsl files: drop the layer + config onto the USB.
# ---------------------------------------------------------------------------
function Install-LslFiles {
    param($Vol, [string]$BundleDir)
    $root = "$($Vol.DriveLetter):\"
    $casper = Join-Path $root 'casper'
    New-Item -ItemType Directory -Force -Path $casper | Out-Null

    $copied = @()
    # 1) the (minimal) root layer - casper stacks it over the base image
    $layer = Join-Path $BundleDir 'filesystem_z0_firstboot.squashfs'
    if (Test-Path $layer) {
        Copy-Item $layer (Join-Path $casper 'filesystem_z0_firstboot.squashfs') -Force
        $copied += 'filesystem_z0_firstboot.squashfs'
    } else {
        Write-Warn2 'filesystem_z0_firstboot.squashfs not found in bundle; layer not copied.'
    }

    # 2) the FAT-side lsl scripts (same set as bin/config.sh --sync-only)
    foreach ($d in @('bin', 'systemd')) {
        $src = Join-Path $BundleDir $d
        if (Test-Path $src) {
            Copy-Item $src (Join-Path $root $d) -Recurse -Force
            $copied += "$d\"
        }
    }
    foreach ($f in @('onboot.sh', 'lsl-usb.env')) {
        $src = Join-Path $BundleDir $f
        if (Test-Path $src) {
            Copy-Item $src (Join-Path $root $f) -Force
            $copied += $f
        }
    }
    # Stamp the build for traceability (captured by lsl-diag.sh on failure) so a
    # wedged hardware test can be tied back to the exact bundle that was written.
    $buildVer = ''
    $bvPath = Join-Path $BundleDir 'VERSION'
    if (Test-Path $bvPath) { $buildVer = (Get-Content $bvPath -Raw).Trim() }
    # Best-effort: a missing/readonly target (or an unusual volume) must not abort
    # the whole install. Matches the try/catch pattern used for other optional writes.
    try { "$buildVer`nBuilt: $(Get-Date -Format u)" | Set-Content -Path (Join-Path $root 'lsl-build.txt') -ErrorAction Stop } catch { }
    $copied += 'lsl-build.txt'
    if (-not $copied) { throw 'No lsl files found in bundle; nothing was copied.' }
    Write-Info "Copied to $root : $($copied -join ', ')"
}

# ---------------------------------------------------------------------------
# Dry run: report everything that would be detected/passed, write nothing.
# ---------------------------------------------------------------------------
function Show-DryRunReport {
    param(
        [string]$IsoPath, [string]$MintVersion, [string]$DownloadDir,
        [string]$BundleDir, [string]$RufusPath, [string[]]$WslVhdx, [string]$VolumeLabel
    )
    WriteStep 'DRY RUN - detection report (nothing downloaded, launched, or written)'

    WriteStep 'ISO'
    if ($IsoPath) {
        if (Test-Path $IsoPath -PathType Leaf) {
            Write-Info "Provided: $IsoPath ($([math]::Round((Get-Item $IsoPath).Length/1GB,2)) GB)"
            try { Test-LiveIso -Iso $IsoPath } catch { Write-Warn2 "Validation skipped: $($_.Exception.Message)" }
        } else {
            Write-Warn2 "Provided ISO not found: $IsoPath"
        }
    } else {
        $esIsos = Find-EverythingIsos
        if ($esIsos) {
            Write-Info 'Everything (voidtools) available - would offer these existing ISOs:'
            $esIsos | ForEach-Object { Write-Info "  $_" }
        } else {
            Write-Info 'Everything (voidtools) not available; would download a fresh ISO.'
        }
        $dir = if ($DownloadDir) { $DownloadDir } else { Get-UserDownloadsDir }
        Write-Info "Would download: linuxmint-$MintVersion-cinnamon-64bit.iso (~3 GB) to $dir"
        Write-Info '  (SHA-256 verified against mirrors.kernel.org sha256sum.txt)'
    }

    WriteStep 'Rufus'
    if ($RufusPath) {
        Write-Info "Provided: $RufusPath"
    } else {
        $exe = Join-Path (Join-Path (Get-LocalAppData) 'lsl-usb\tools') 'rufus.exe'
        if (Test-Path $exe) { Write-Info "Cached: $exe" }
        else { Write-Info "Would download latest rufus.exe from GitHub releases (Authenticode-verified) to $exe" }
    }

    WriteStep 'USB target'
    if (Get-Command Get-Volume -ErrorAction SilentlyContinue) {
        $vols = Get-Volume | Where-Object { $_.DriveType -eq 'Removable' -and $_.DriveLetter } | Sort-Object DriveLetter
        if ($vols) {
            foreach ($v in $vols) {
                $hasCasper = Test-Path (Join-Path "$($v.DriveLetter):\" 'casper\filesystem.squashfs')
                Write-Info "$($v.DriveLetter):  $($v.FileSystemLabel)  $([math]::Round($v.Size/1GB,1)) GB  casper=$hasCasper"
            }
            Write-Info "Target selection: $(if ($VolumeLabel) { "label match '$VolumeLabel'" } else { 'volume that ends up containing casper\filesystem.squashfs after Rufus writes' })"
            Write-Info '  A plugged-in USB already containing casper\filesystem.squashfs is offered for reuse (skips Rufus).'
        } else {
            Write-Warn2 'No removable volumes detected.'
        }
    } else {
        Write-Warn2 'Get-Volume not available (non-Windows?).'
    }

    WriteStep 'WSL VHDX (would be written to <USB>:\lsl-wsl-vhdx.conf)'
    $vhdx = Get-WslVhdxPaths -Extra $WslVhdx
    if ($vhdx) { $vhdx | ForEach-Object { Write-Info "  $_" } }
    else { Write-Warn2 'None found (registry Lxss + Packages scan + -WslVhdx).' }

    WriteStep 'Flatpak suggestions (installed Windows apps -> flathub refs)'
    $sugg = Get-FlatpakSuggestions
    if ($sugg) { $sugg | ForEach-Object { Write-Info "  $($_.App) -> $($_.FlatpakId)$(if ($_.Matched) { '  (installed)' } else { '' })" } }
    else { Write-Warn2 'None.' }

    WriteStep 'WiFi (would be written to <USB>:\wifi.sh)'
    $wifiNames = @(Get-WifiProfileNames)
    if ($wifiNames) { $wifiNames | ForEach-Object { Write-Info "  $_" } }
    else { Write-Warn2 'No saved wifi profiles found.' }

    WriteStep 'Reuse an existing Mint live USB (skip Rufus)'
    $usbs = @(Find-UsbVolumes -Label '')
    if ($usbs) { $usbs | ForEach-Object { Write-Info "  $($_.DriveLetter):  $($_.FileSystemLabel)  ($([math]::Round($_.Size/1GB,1)) GB)" } }
    else { Write-Info '  None detected.' }

    WriteStep 'LSL_DATA_DIR (pre-filled default)'
    if ($env:USERNAME) { Write-Info "  /mnt/c/Users/$($env:USERNAME)/lsl-usb" }
    else { Write-Info '  (no Windows username detected)' }

    WriteStep 'lsl bundle (would be copied to <USB>:\, layer to <USB>:\casper\)'
    foreach ($item in @('filesystem_z0_firstboot.squashfs', 'onboot.sh', 'lsl-usb.env', 'bin', 'systemd')) {
        $p = Join-Path $BundleDir $item
        if (Test-Path $p) { Write-Info "  OK       $item" } else { Write-Warn2 "  MISSING  $item" }
    }
    Write-Info "Bundle dir: $BundleDir"
}

# ---------------------------------------------------------------------------
# WinForms installer GUI: starts FIRST, runs the ISO download/verify in a
# background runspace, and collects configuration while the user waits.
# ---------------------------------------------------------------------------
function Show-InstallerGui {
    param(
        [string]$IsoPath,
        [string]$MintVersion,
        [string]$DownloadDir,
        [string[]]$WslVhdx,
        [string[]]$FlatpakApps
    )
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # --- ISO discovery (fast, ~200 ms) - needed for page 1 ---
    $foundIsos = Find-EverythingIsos
    if ($foundIsos.Count -eq 0) {
        $dir = if ($DownloadDir) { $DownloadDir } else { Get-UserDownloadsDir }
        $foundIsos = @(Get-ChildItem $dir -Filter *.iso -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 10 |
            ForEach-Object { $_.FullName })
    }
    $foundIsos = @($foundIsos | Select-Object -First 10)
    $exactName = "linuxmint-$MintVersion-cinnamon-64bit.iso"
    $defaultIso = $foundIsos | Where-Object { [System.IO.Path]::GetFileName($_) -eq $exactName } | Select-Object -First 1
    if (-not $defaultIso) {
        $defaultIso = $foundIsos | Where-Object { [System.IO.Path]::GetFileName($_) -match "linuxmint-$MintVersion" } | Select-Object -First 1
    }

    $state = [hashtable]::Synchronized(@{
        Phase = 'iso'; Percent = 0; Message = 'Starting...'
        Done = $false; Error = ''; IsoPath = ''; EtaSec = -1
        CancelDownload = $false; ChosenIso = $defaultIso; ReuseUsb = ''
    })

    # --- runspace: ISO download/verify (starts immediately) ---
    $runspaceScript = @'
param($state, $IsoPath, $MintVersion, $DownloadDir)
$ErrorActionPreference = 'Stop'
# The runspace is a separate PowerShell instance: it does not inherit the
# script's TLS 1.2 setting, and mirrors.kernel.org rejects older TLS.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
function Get-UserDownloadsDir {
    $profileDir = [Environment]::GetFolderPath('UserProfile')
    if (-not $profileDir) { $profileDir = $env:USERPROFILE }
    if (-not $profileDir) { throw 'Cannot determine user profile directory.' }
    return (Join-Path $profileDir 'Downloads')
}
# Incremental SHA-256 with real progress + ETA (Get-FileHash gives none).
function Verify-Sha256 {
    param($path, $expected, $state)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::OpenRead($path)
    $buf = New-Object byte[] (1048576)
    $total = $fs.Length
    $read = 0
    $t0 = [DateTime]::UtcNow
    while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
        $null = $sha.TransformBlock($buf, 0, $n, $null, 0)
        $read += $n
        if ($total -gt 0) { $state.Percent = [int]($read * 100 / $total) }
        $el = ([DateTime]::UtcNow - $t0).TotalSeconds
        if ($el -gt 1 -and $read -gt 0) {
            $rate = $read / $el
            $state.EtaSec = [int](($total - $read) / $rate)
        }
        $state.Message = "Verifying SHA-256: $([math]::Round($read/1GB,2)) / $([math]::Round($total/1GB,2)) GB"
    }
    $null = $sha.TransformFinalBlock([byte[]]::new(0), 0, 0)
    $fs.Close()
    $actual = ([BitConverter]::ToString($sha.Hash)).Replace('-', '').ToLowerInvariant()
    if ($expected.ToLowerInvariant() -ne $actual) { throw "SHA256 mismatch for $([System.IO.Path]::GetFileName($path))" }
}
# Fetch the official checksum, cached next to the ISO (stable per ISO; avoids
# a slow network round-trip on every verify, across sessions).
function Get-ExpectedChecksum {
    param($base, $isoName, $state, $cacheDir)
    $cacheFile = Join-Path $cacheDir "sha256sum-$isoName.txt"
    $sum = ''
    if (Test-Path $cacheFile) { $sum = Get-Content $cacheFile -Raw -ErrorAction SilentlyContinue }
    if (-not $sum) {
        $state.Message = 'Fetching SHA-256 checksum ...'
        $sum = (New-Object System.Net.WebClient).DownloadString("$base/sha256sum.txt")
        try { Set-Content -Path $cacheFile -Value $sum -ErrorAction SilentlyContinue } catch { }
    }
    return (($sum -split "`n" | Where-Object { $_ -match [regex]::Escape($isoName) }) -split '\s+' | Select-Object -First 1)
}
try {
    # The user chose to reuse an existing Mint live USB: no ISO work needed.
    if ($state.ReuseUsb) {
        $state.Message = "Using existing USB: $($state.ReuseUsb.DriveLetter): ($($state.ReuseUsb.FileSystemLabel)) - no Rufus write."
        $state.Percent = 100
        $state.Done = $true
        return
    }
    # An existing ISO was chosen in the GUI: use it as-is (no download). If it
    # is the exact Mint ISO, still verify its SHA-256 to catch corruption.
    if ($state.ChosenIso) {
        $state.IsoPath = $state.ChosenIso
        $state.Message = "Using selected ISO: $($state.ChosenIso)"
        if ([System.IO.Path]::GetFileName($state.ChosenIso) -eq "linuxmint-$MintVersion-cinnamon-64bit.iso") {
            $state.Percent = 0
            $state.Message = 'Verifying SHA-256 of the existing ISO ...'
            $base = "https://mirrors.kernel.org/linuxmint/stable/$MintVersion"
            $expected = Get-ExpectedChecksum -base $base -isoName ([System.IO.Path]::GetFileName($state.ChosenIso)) -state $state -cacheDir ([System.IO.Path]::GetDirectoryName($state.ChosenIso))
            if ($expected) {
                Verify-Sha256 -path $state.ChosenIso -expected $expected -state $state
                $state.Message = 'SHA-256 verified (existing ISO).'
            }
        }
        $state.Percent = 100
        $state.Done = $true
        return
    }
    $isoName = "linuxmint-$MintVersion-cinnamon-64bit.iso"
    if (-not $DownloadDir) { $DownloadDir = Get-UserDownloadsDir }
    $dest = Join-Path $DownloadDir $isoName
    $base = "https://mirrors.kernel.org/linuxmint/stable/$MintVersion"
    if (-not (Test-Path $dest)) {
        New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null
        $state.Message = "Downloading $isoName ..."
        $wc = New-Object System.Net.WebClient
        $resp = $wc.OpenRead("$base/$isoName")
        $fs = [System.IO.File]::Create($dest)
        $buf = New-Object byte[] (1048576)
        $total = $resp.ContentLength
        $read = 0
        $t0 = [DateTime]::UtcNow
        while (($n = $resp.Read($buf, 0, $buf.Length)) -gt 0) {
            if ($state.CancelDownload) {
                $fs.Close(); $resp.Close()
                Remove-Item $dest -Force -ErrorAction SilentlyContinue
                $state.IsoPath = $state.ChosenIso
                $state.Message = "Using selected ISO: $($state.ChosenIso)"
                $state.Percent = 100
                $state.Done = $true
                return
            }
            $fs.Write($buf, 0, $n)
            $read += $n
            if ($total -gt 0) { $state.Percent = [int]($read * 100 / $total) }
            $state.Message = "Downloading: $([math]::Round($read/1GB,2)) / $([math]::Round($total/1GB,2)) GB"
            $el = ([DateTime]::UtcNow - $t0).TotalSeconds
            if ($el -gt 1 -and $read -gt 0) {
                $rate = $read / $el
                $state.EtaSec = [int](($total - $read) / $rate)
            }
        }
        $fs.Close(); $resp.Close()
    } else {
        $state.Message = "ISO already present: $dest"
    }
    $state.IsoPath = $dest
    $state.Percent = 0
    $state.Message = 'Verifying SHA-256 ...'
    $expected = Get-ExpectedChecksum -base $base -isoName $isoName -state $state -cacheDir $DownloadDir
    if (-not $expected) { throw "No checksum entry for $isoName" }
    Verify-Sha256 -path $dest -expected $expected -state $state
    $state.Message = 'SHA-256 verified.'
    $state.Percent = 100
    $state.Done = $true
} catch {
    $state.Error = $_.Exception.Message
    $state.Done = $true
}
'@

    $ps = [powershell]::Create()
    [void]$ps.AddScript($runspaceScript)
    [void]$ps.AddArgument($state).AddArgument($IsoPath).AddArgument($MintVersion).AddArgument($DownloadDir)
    $handle = $ps.BeginInvoke()

    # --- background runspaces for the slow discovery (form appears fast) ---
    $flatpakScript = {
        param($extra, $modulePath)
        . $modulePath
        $installed = Get-InstalledWindowsApps
        $map = @(
            @{ match = 'Slack'; id = 'com.slack.Slack' },
            @{ match = 'Discord'; id = 'com.discordapp.Discord' },
            @{ match = 'Spotify'; id = 'com.spotify.Client' },
            @{ match = 'Visual Studio Code'; id = 'com.visualstudio.code' },
            @{ match = 'Telegram'; id = 'org.telegram.desktop' },
            @{ match = 'Zoom'; id = 'us.zoom.Zoom' },
            @{ match = 'Obsidian'; id = 'md.obsidian.Obsidian' },
            @{ match = 'GIMP'; id = 'org.gimp.GIMP' },
            @{ match = 'Inkscape'; id = 'org.inkscape.Inkscape' },
            @{ match = 'Blender'; id = 'org.blender.Blender' },
            @{ match = 'OBS'; id = 'com.obsproject.Studio' },
            @{ match = 'Steam'; id = 'com.valvesoftware.Steam' },
            @{ match = 'VLC'; id = 'org.videolan.VLC' },
            @{ match = 'Firefox'; id = 'org.mozilla.firefox' },
            @{ match = 'Docker'; id = 'com.docker.Desktop' },
            @{ match = 'VirtualBox'; id = 'org.virtualbox.VirtualBox' }
        )
        $out = @()
        foreach ($m in $map) {
            $matched = [bool]($installed | Where-Object { $_ -match [regex]::Escape($m.match) })
            $out += [pscustomobject]@{ App = $m.match; FlatpakId = $m.id; Matched = $matched }
        }
        $out | ConvertTo-Json -Compress
    }

    $vhdxScript = {
        param($extra, $modulePath)
        . $modulePath
        (Get-WslVhdxPaths -Extra $extra) -join "`r`n"
    }
    $flatpakPs = [powershell]::Create()
    [void]$flatpakPs.AddScript($flatpakScript).AddArgument($FlatpakApps).AddArgument($detectModule)
    $flatpakHandle = $flatpakPs.BeginInvoke()
    $vhdxPs = [powershell]::Create()
    [void]$vhdxPs.AddScript($vhdxScript).AddArgument($WslVhdx).AddArgument($detectModule)
    $vhdxHandle = $vhdxPs.BeginInvoke()

    # --- form ---
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'lsl-usb installer'
    $verFile = Join-Path $PSScriptRoot 'VERSION'
    if (Test-Path $verFile) {
        $ver = (Get-Content $verFile -Raw).Trim()
        if ($ver) { $form.Text = "lsl-usb installer $ver" }
    }
    $form.ClientSize = New-Object System.Drawing.Size(640, 760)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false

    $status = New-Object System.Windows.Forms.Label
    $status.Location = New-Object System.Drawing.Point(12, 12)
    $status.Size = New-Object System.Drawing.Size(600, 20)
    $status.Text = 'Starting...'
    $form.Controls.Add($status)

    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Location = New-Object System.Drawing.Point(12, 38)
    $progress.Size = New-Object System.Drawing.Size(600, 22)
    $progress.Minimum = 0; $progress.Maximum = 100
    $form.Controls.Add($progress)

    $lblEta = New-Object System.Windows.Forms.Label
    $lblEta.Location = New-Object System.Drawing.Point(12, 64)
    $lblEta.Size = New-Object System.Drawing.Size(600, 18)
    $lblEta.Text = ''
    $form.Controls.Add($lblEta)

    # --- page 1: ISO selection ---
    $page1 = New-Object System.Windows.Forms.Panel
    $page1.Location = New-Object System.Drawing.Point(12, 88)
    $page1.Size = New-Object System.Drawing.Size(600, 630)
    $form.Controls.Add($page1)

    $lblIso = New-Object System.Windows.Forms.Label
    $lblIso.Text = 'ISO image:'
    $lblIso.Location = New-Object System.Drawing.Point(10, 10)
    $lblIso.Size = New-Object System.Drawing.Size(560, 18)
    $page1.Controls.Add($lblIso)

    $lblRec = New-Object System.Windows.Forms.Label
    $lblRec.Text = 'Linux Mint Cinnamon is the recommended option.'
    $lblRec.Location = New-Object System.Drawing.Point(10, 30)
    $lblRec.Size = New-Object System.Drawing.Size(560, 18)
    $lblRec.Font = New-Object System.Drawing.Font($lblRec.Font, [System.Drawing.FontStyle]::Bold)
    $page1.Controls.Add($lblRec)

    $isoPanel = New-Object System.Windows.Forms.Panel
    $isoPanel.Location = New-Object System.Drawing.Point(0, 55)
    $isoPanel.Size = New-Object System.Drawing.Size(600, 560)
    $isoPanel.AutoScroll = $true
    $page1.Controls.Add($isoPanel)

    $y = 5
    $isoRadios = @()
    $rbDownload = New-Object System.Windows.Forms.RadioButton
    $rbDownload.Text = "Download linuxmint-$MintVersion Cinnamon (fresh)"
    $rbDownload.Location = New-Object System.Drawing.Point(10, $y)
    $rbDownload.Size = New-Object System.Drawing.Size(560, 20)
    $rbDownload.Checked = -not $defaultIso
    $rbDownload.Tag = ''
    $isoPanel.Controls.Add($rbDownload)
    $isoRadios += $rbDownload
    $y += 24

    foreach ($iso in $foundIsos) {
        $sz = ''
        if (Test-Path $iso -PathType Leaf) {
            $sz = '  ' + [math]::Round((Get-Item $iso).Length / 1GB, 2) + ' GB'
        }
        $rb = New-Object System.Windows.Forms.RadioButton
        $rb.Text = ([System.IO.Path]::GetFileName($iso)) + $sz
        $rb.Location = New-Object System.Drawing.Point(10, $y)
        $rb.Size = New-Object System.Drawing.Size(560, 20)
        $rb.Tag = $iso
        $rb.Checked = ($iso -eq $defaultIso)
        $rb.Add_CheckedChanged({
            if ($this.Checked) {
                $state.CancelDownload = $true
                $state.ChosenIso = $this.Tag
            }
        })
        $isoPanel.Controls.Add($rb)
        $isoRadios += $rb
        $y += 24
    }

    # --- reuse an existing Mint live USB (skip Rufus) ---
    $y += 10
    $lblReuse = New-Object System.Windows.Forms.Label
    $lblReuse.Text = 'Or use an existing Mint live USB (skip Rufus):'
    $lblReuse.Location = New-Object System.Drawing.Point(10, $y)
    $lblReuse.Size = New-Object System.Drawing.Size(560, 18)
    $isoPanel.Controls.Add($lblReuse)
    $y += 20

    $rbFresh = New-Object System.Windows.Forms.RadioButton
    $rbFresh.Text = 'Write fresh via Rufus'
    $rbFresh.Location = New-Object System.Drawing.Point(10, $y)
    $rbFresh.Size = New-Object System.Drawing.Size(560, 20)
    $rbFresh.Checked = $true
    $rbFresh.Tag = ''
    $rbFresh.Add_CheckedChanged({
        if ($this.Checked) {
            $state.ReuseUsb = ''
            foreach ($r in $isoRadios) { $r.Visible = $true }
        }
    })
    $isoPanel.Controls.Add($rbFresh)
    $y += 24

    $existingUsbs = @(Find-UsbVolumes -Label '')
    foreach ($u in $existingUsbs) {
        $rb = New-Object System.Windows.Forms.RadioButton
        $rb.Text = "$($u.DriveLetter):  $($u.FileSystemLabel)  ($([math]::Round($u.Size/1GB,1)) GB)"
        $rb.Location = New-Object System.Drawing.Point(10, $y)
        $rb.Size = New-Object System.Drawing.Size(560, 20)
        $rb.Tag = $u
        $rb.Add_CheckedChanged({
            if ($this.Checked -and $this.Tag) {
                $state.ReuseUsb = $this.Tag
                $state.CancelDownload = $true
                # Reusing a USB: the ISO selection is irrelevant - hide it.
                foreach ($r in $isoRadios) { $r.Visible = $false }
            }
        })
        $isoPanel.Controls.Add($rb)
        $y += 24
    }

    # --- page 2: flatpaks (populated when the background job completes) ---
    $page2 = New-Object System.Windows.Forms.Panel
    $page2.Location = New-Object System.Drawing.Point(12, 88)
    $page2.Size = New-Object System.Drawing.Size(600, 630)
    $page2.Visible = $false
    $form.Controls.Add($page2)

    $lblFp = New-Object System.Windows.Forms.Label
    $lblFp.Text = 'Flatpak apps to preload (checked = installed from Windows):'
    $lblFp.Location = New-Object System.Drawing.Point(10, 10)
    $lblFp.Size = New-Object System.Drawing.Size(560, 18)
    $page2.Controls.Add($lblFp)

    $fpHost = New-Object System.Windows.Forms.Panel
    $fpHost.Location = New-Object System.Drawing.Point(0, 35)
    $fpHost.Size = New-Object System.Drawing.Size(600, 300)
    $fpHost.AutoScroll = $true
    $page2.Controls.Add($fpHost)
    $lblFpLoading = New-Object System.Windows.Forms.Label
    $lblFpLoading.Text = 'Loading flatpak apps...'
    $lblFpLoading.Location = New-Object System.Drawing.Point(10, 5)
    $lblFpLoading.Size = New-Object System.Drawing.Size(560, 20)
    $fpHost.Controls.Add($lblFpLoading)

    # Recommended Linux apps (not tied to Windows installs).
    $lblRec = New-Object System.Windows.Forms.Label
    $lblRec.Text = 'Recommended Linux apps:'
    $lblRec.Location = New-Object System.Drawing.Point(10, 320)
    $lblRec.Size = New-Object System.Drawing.Size(560, 18)
    $page2.Controls.Add($lblRec)
    $recChecks = @()
    $chkFSearch = New-Object System.Windows.Forms.CheckBox
    $chkFSearch.Text = 'FSearch (Everything-style file search)'
    $chkFSearch.Location = New-Object System.Drawing.Point(10, 340)
    $chkFSearch.Size = New-Object System.Drawing.Size(560, 20)
    $chkFSearch.Tag = 'io.github.cboxdoerfer.FSearch'
    $chkFSearch.Checked = $true
    $page2.Controls.Add($chkFSearch)
    $recChecks += $chkFSearch

    $lblExtra = New-Object System.Windows.Forms.Label
    $lblExtra.Text = 'Extra flatpak IDs (comma-separated):'
    $lblExtra.Location = New-Object System.Drawing.Point(10, 370)
    $lblExtra.Size = New-Object System.Drawing.Size(560, 18)
    $page2.Controls.Add($lblExtra)
    $txtExtra = New-Object System.Windows.Forms.TextBox
    $txtExtra.Location = New-Object System.Drawing.Point(10, 390)
    $txtExtra.Size = New-Object System.Drawing.Size(560, 22)
    $txtExtra.Text = ($FlatpakApps -join ', ')
    $page2.Controls.Add($txtExtra)

    # --- page 3: vhdx + data dir + wifi ---
    $page3 = New-Object System.Windows.Forms.Panel
    $page3.Location = New-Object System.Drawing.Point(12, 88)
    $page3.Size = New-Object System.Drawing.Size(600, 630)
    $page3.Visible = $false
    $form.Controls.Add($page3)

    $lblVhdx = New-Object System.Windows.Forms.Label
    $lblVhdx.Text = 'WSL VHDX paths (one per line):'
    $lblVhdx.Location = New-Object System.Drawing.Point(10, 10)
    $lblVhdx.Size = New-Object System.Drawing.Size(560, 18)
    $page3.Controls.Add($lblVhdx)
    $txtVhdx = New-Object System.Windows.Forms.TextBox
    $txtVhdx.Multiline = $true
    $txtVhdx.Location = New-Object System.Drawing.Point(10, 30)
    $txtVhdx.Size = New-Object System.Drawing.Size(560, 120)
    $txtVhdx.ScrollBars = 'Vertical'
    $txtVhdx.Text = 'Detecting WSL VHDX paths...'
    $page3.Controls.Add($txtVhdx)

    $lblData = New-Object System.Windows.Forms.Label
    $lblData.Text = 'LSL_DATA_DIR (default /mnt/c/Users/lsl-usb):'
    $lblData.Location = New-Object System.Drawing.Point(10, 170)
    $lblData.Size = New-Object System.Drawing.Size(560, 18)
    $page3.Controls.Add($lblData)
    $txtData = New-Object System.Windows.Forms.TextBox
    $txtData.Location = New-Object System.Drawing.Point(10, 190)
    $txtData.Size = New-Object System.Drawing.Size(460, 22)
    if ($env:USERNAME) { $txtData.Text = "/mnt/c/Users/$($env:USERNAME)/lsl-usb" }
    $page3.Controls.Add($txtData)
    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = 'Browse...'
    $btnBrowse.Location = New-Object System.Drawing.Point(480, 189)
    $btnBrowse.Size = New-Object System.Drawing.Size(90, 24)
    $btnBrowse.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Choose the LSL_DATA_DIR folder (a Windows path, e.g. C:\Users\you\lsl-usb)'
        if ($txtData.Text) { $dlg.SelectedPath = $txtData.Text }
        if ($dlg.ShowDialog() -eq 'OK') { $txtData.Text = $dlg.SelectedPath }
    })
    $page3.Controls.Add($btnBrowse)

    $chkWifi = New-Object System.Windows.Forms.CheckBox
    $chkWifi.Text = 'Copy Wifi Settings to LSL'
    $chkWifi.Location = New-Object System.Drawing.Point(10, 230)
    $chkWifi.Size = New-Object System.Drawing.Size(560, 20)
    $chkWifi.Checked = $true
    $page3.Controls.Add($chkWifi)

    $chkEfu = New-Object System.Windows.Forms.CheckBox
    $chkEfu.Text = 'Export Everything index for Linux file browsing (can be large)'
    $chkEfu.Location = New-Object System.Drawing.Point(10, 252)
    $chkEfu.Size = New-Object System.Drawing.Size(560, 20)
    $chkEfu.Checked = $true
    $page3.Controls.Add($chkEfu)

    $chkEverything = New-Object System.Windows.Forms.CheckBox
    $chkEverything.Text = 'Install Everything (voidtools) if missing - enables full-disk search'
    $chkEverything.Location = New-Object System.Drawing.Point(10, 274)
    $chkEverything.Size = New-Object System.Drawing.Size(560, 20)
    $chkEverything.Checked = $true
    $page3.Controls.Add($chkEverything)

    # Per-network picker (pre-checked; netsh is fast so this is synchronous).
    $lblWifi = New-Object System.Windows.Forms.Label
    $lblWifi.Text = 'Networks to copy (checked = include in wifi.sh):'
    $lblWifi.Location = New-Object System.Drawing.Point(10, 260)
    $lblWifi.Size = New-Object System.Drawing.Size(560, 18)
    $page3.Controls.Add($lblWifi)
    $wifiHost = New-Object System.Windows.Forms.Panel
    $wifiHost.Location = New-Object System.Drawing.Point(0, 280)
    $wifiHost.Size = New-Object System.Drawing.Size(600, 200)
    $wifiHost.AutoScroll = $true
    $page3.Controls.Add($wifiHost)
    $wifiChecks = @()
    $wifiNames = @(Get-WifiProfileNames)
    $wy = 5
    foreach ($wn in $wifiNames) {
        $cb = New-Object System.Windows.Forms.CheckBox
        $cb.Text = $wn
        $cb.Location = New-Object System.Drawing.Point(10, $wy)
        $cb.Size = New-Object System.Drawing.Size(560, 20)
        $cb.Checked = $true
        $wifiHost.Controls.Add($cb)
        $wifiChecks += $cb
        $wy += 24
    }
    if ($wifiNames.Count -eq 0) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = 'No saved wifi profiles found.'
        $lbl.Location = New-Object System.Drawing.Point(10, 5)
        $lbl.Size = New-Object System.Drawing.Size(560, 20)
        $wifiHost.Controls.Add($lbl)
    }

    # --- buttons ---
    $btnBack = New-Object System.Windows.Forms.Button
    $btnBack.Text = '< Back'
    $btnBack.Enabled = $false
    $btnBack.Location = New-Object System.Drawing.Point(340, 720)
    $btnBack.Size = New-Object System.Drawing.Size(90, 28)
    $form.Controls.Add($btnBack)

    $btnNext = New-Object System.Windows.Forms.Button
    $btnNext.Text = 'Next >'
    $btnNext.Location = New-Object System.Drawing.Point(440, 720)
    $btnNext.Size = New-Object System.Drawing.Size(90, 28)
    $form.Controls.Add($btnNext)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Cancel'
    $btnCancel.Location = New-Object System.Drawing.Point(536, 720)
    $btnCancel.Size = New-Object System.Drawing.Size(90, 28)
    $form.Controls.Add($btnCancel)

    # --- shared UI state (hashtable so event handlers can mutate it) ---
    $ui = @{ Page = 1; FlatpakDone = $false; VhdxDone = $false; Checks = @() }

    $btnNext.Add_Click({
        if ($ui.Page -lt 3) {
            $ui.Page++
            $page1.Visible = ($ui.Page -eq 1)
            $page2.Visible = ($ui.Page -eq 2)
            $page3.Visible = ($ui.Page -eq 3)
            $btnBack.Enabled = ($ui.Page -gt 1)
            if ($ui.Page -eq 3) { $btnNext.Text = 'Install' }
        } else {
            if ($state.Done -and -not $state.Error) {
                $timer.Stop()
                $form.DialogResult = 'OK'
                $form.Close()
            }
        }
    })
    $btnBack.Add_Click({
        if ($ui.Page -gt 1) {
            $ui.Page--
            $page1.Visible = ($ui.Page -eq 1)
            $page2.Visible = ($ui.Page -eq 2)
            $page3.Visible = ($ui.Page -eq 3)
            $btnBack.Enabled = ($ui.Page -gt 1)
            $btnNext.Text = 'Next >'
        }
    })
    $btnCancel.Add_Click({
        $timer.Stop()
        $form.DialogResult = 'Cancel'
        $form.Close()
    })

    # --- tooltips ---
    $tip = New-Object System.Windows.Forms.ToolTip
    $tip.SetToolTip($status, 'Status of the ISO download/verification running in the background.')
    $tip.SetToolTip($progress, 'ISO download progress; marquee = verifying SHA-256.')
    $tip.SetToolTip($rbDownload, 'Download the latest Mint Cinnamon ISO and verify its SHA-256.')
    foreach ($rb in $isoRadios) { if ($rb.Tag) { $tip.SetToolTip($rb, "Use existing ISO: $($rb.Tag)") } }
    $tip.SetToolTip($txtExtra, 'Extra flathub app IDs, comma-separated (e.g. org.mozilla.firefox).')
    $tip.SetToolTip($txtVhdx, 'WSL2 disk images to pass to Linux (detected automatically; add or remove).')
    $tip.SetToolTip($txtData, 'Where Linux stores persistent data (default /mnt/c/Users/lsl-usb).')
    $tip.SetToolTip($btnBack, 'Previous step.')
    $tip.SetToolTip($btnNext, 'Next step; on the last page, installs once the ISO is ready.')
    $tip.ShowAlways = $true   # show tooltips even on disabled controls
    $tip.SetToolTip($btnCancel, 'Abort the install.')

    # --- timer: status/progress, page-3 gate, background-job polling ---
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 100
    $timer.Add_Tick({
        try {
            $status.Text = $state.Message
            if ($state.Percent -lt 0) {
                $progress.Style = 'Marquee'
            } else {
                $progress.Style = 'Blocks'
                if ($state.Percent -gt 0) { $progress.Value = $state.Percent }
            }
            if ($ui.Page -eq 3) {
                $ready = ($state.Done -and -not $state.Error)
                $btnNext.Enabled = $ready
                if ($ready) {
                    $tip.SetToolTip($btnNext, 'Install lsl-usb onto the USB.')
                } else {
                    $tip.SetToolTip($btnNext, "Waiting: $($state.Message)")
                }
            }
            # ETA label
            if ($state.EtaSec -ge 0) {
                $lblEta.Text = "~$($state.EtaSec) s remaining"
            } else {
                $lblEta.Text = ''
            }
            # flatpak suggestions arrived?
            if (-not $ui.FlatpakDone -and $flatpakHandle.IsCompleted) {
                $sugg = @()
                try { $sugg = $flatpakPs.EndInvoke($flatpakHandle) | ConvertFrom-Json } catch {
                    $lbl = New-Object System.Windows.Forms.Label
                    $lbl.Text = "Could not detect flatpak apps: $($_.Exception.Message)"
                    $lbl.Location = New-Object System.Drawing.Point(10, 5)
                    $lbl.Size = New-Object System.Drawing.Size(560, 20)
                    $fpHost.Controls.Add($lbl)
                }
                $flatpakPs.Dispose()
                $ui.FlatpakDone = $true
                $fpHost.Controls.Remove($lblFpLoading)
                if ($sugg.Count -gt 0) {
                    $colW = 275
                    $perCol = [math]::Ceiling($sugg.Count / 2)
                    for ($i = 0; $i -lt $sugg.Count; $i++) {
                        $s = $sugg[$i]
                        $col = [math]::Floor($i / $perCol)
                        $row = $i % $perCol
                        $cb = New-Object System.Windows.Forms.CheckBox
                        $cb.Text = $s.App
                        $cb.Location = New-Object System.Drawing.Point((10 + $col * $colW), (5 + $row * 24))
                        $cb.Size = New-Object System.Drawing.Size(($colW - 10), 20)
                        $cb.Tag = $s.FlatpakId
                        $cb.Checked = $s.Matched
                        $fpHost.Controls.Add($cb)
                        $ui.Checks += $cb
                        $tip.SetToolTip($cb, "Flathub app ID: $($cb.Tag)")
                    }
                } else {
                    $lbl = New-Object System.Windows.Forms.Label
                    $lbl.Text = 'No flatpak suggestions available.'
                    $lbl.Location = New-Object System.Drawing.Point(10, 5)
                    $lbl.Size = New-Object System.Drawing.Size(540, 20)
                    $fpHost.Controls.Add($lbl)
                }
            }
            # vhdx paths arrived?
            if (-not $ui.VhdxDone -and $vhdxHandle.IsCompleted) {
                try { $txtVhdx.Text = $vhdxPs.EndInvoke($vhdxHandle) } catch {
                    $txtVhdx.Text = "Could not detect WSL VHDX paths: $($_.Exception.Message)"
                }
                $vhdxPs.Dispose()
                $ui.VhdxDone = $true
            }
        } catch {
            # Ctrl-C / pipeline stopped: stop the timer, close the form, and
            # leave a marker so install.bat knows to quit without pausing.
            $timer.Stop()
            try { Set-Content -Path (Join-Path $env:TEMP 'lsl-cancelled') -Value 'cancelled' -ErrorAction SilentlyContinue } catch { }
            try { $form.Close() } catch { }
        }
    })
    $timer.Start()

    # Ctrl-C stops the pipeline, and the PipelineStoppedException is thrown by
    # the script-block invocation itself - a try/catch inside the tick cannot
    # see it. Catch it at the WinForms message-pump level instead: this also
    # suppresses the default JIT dialog. Leave the cancel marker for install.bat.
    [System.Windows.Forms.Application]::add_ThreadException({
        param($sender, $e)
        if ($e.Exception -is [System.Management.Automation.PipelineStoppedException]) {
            $timer.Stop()
            try { Set-Content -Path (Join-Path $env:TEMP 'lsl-cancelled') -Value 'cancelled' -ErrorAction SilentlyContinue } catch { }
            try { $form.Close() } catch { }
        } else {
            # Show the error once, then quit - never loop.
            [System.Windows.Forms.MessageBox]::Show("Unexpected error: $($e.Exception.Message)", 'lsl-usb installer')
            $timer.Stop()
            try { $form.Close() } catch { }
            [Environment]::Exit(1)
        }
    })
    $form.Add_Shown({ $form.Activate() })
    # Safety net: stop the background job whenever the form closes (Ctrl-C, X,
    # Cancel) so the ISO download does not keep running orphaned.
    $form.Add_FormClosing({
        $timer.Stop()
        try { $ps.Stop() } catch { }
        try { $flatpakPs.Stop() } catch { }
        try { $flatpakPs.Dispose() } catch { }
        try { $vhdxPs.Stop() } catch { }
        try { $vhdxPs.Dispose() } catch { }
    })

    $result = $form.ShowDialog()
    if ($result -ne 'OK') {
        $ps.Dispose()
        return $null
    }
    try { $null = $ps.EndInvoke($handle) } catch { }
    $ps.Dispose()

    return @{
        IsoPath       = $state.IsoPath
        FlatpakApps   = @($ui.Checks | Where-Object { $_.Checked } | ForEach-Object { $_.Tag }) + @($recChecks | Where-Object { $_.Checked } | ForEach-Object { $_.Tag })
        ExtraFlatpaks = @($txtExtra.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        WslVhdx       = @($txtVhdx.Text -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        DataDir       = $txtData.Text.Trim()
        Wifi          = $chkWifi.Checked
        WifiNetworks  = @($wifiChecks | Where-Object { $_.Checked } | ForEach-Object { $_.Text })
        Efu           = $chkEfu.Checked
        InstallEverything = $chkEverything.Checked
        UseExistingUsb = $state.ReuseUsb
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Show-CompatNotes

if ($DryRun) {
    Show-DryRunReport -IsoPath $IsoPath -MintVersion $MintVersion -DownloadDir $DownloadDir `
        -BundleDir $BundleDir -RufusPath $RufusPath -WslVhdx $WslVhdx -VolumeLabel $VolumeLabel
    exit 0
}

# GUI first: starts before the ISO download/verify, runs them in the
# background, and collects configuration while the user waits.
$guiDataDir = ''
$copyWifi = $true
$wifiNetworks = @()
$doEfu = $true
$installEverything = $true
if (-not $NoGui) {
    $gui = Show-InstallerGui -IsoPath $IsoPath -MintVersion $MintVersion -DownloadDir $DownloadDir `
        -WslVhdx $WslVhdx -FlatpakApps $FlatpakApps
    if (-not $gui) { Write-Warn2 'Cancelled.'; exit 2 }   # 2 = user cancel (bat skips pause)
    $IsoPath = $gui.IsoPath
    $FlatpakApps = @($gui.FlatpakApps) + @($gui.ExtraFlatpaks)
    $WslVhdx = $gui.WslVhdx
    $guiDataDir = $gui.DataDir
    $copyWifi = $gui.Wifi
    $wifiNetworks = $gui.WifiNetworks
    $doEfu = $gui.Efu
    $installEverything = $gui.InstallEverything
    if ($gui.UseExistingUsb) {
        $vol = $gui.UseExistingUsb
        WriteStep "Using existing Mint live USB: $($vol.DriveLetter): ($($vol.FileSystemLabel)) - no Rufus write."
    }
}

# If no specific ISO was requested, offer to reuse a Mint live USB that is
# already plugged in (skips the ~3 GB download and the Rufus re-write).
$vol = $null
if (-not $IsoPath) {
    $existing = Select-ExistingUsb -Label $VolumeLabel
    if ($existing) {
        $vol = $existing
        WriteStep 'Using existing Mint live USB - no ISO download, no Rufus write.'
        Write-Info "Target: $($vol.DriveLetter):  $($vol.FileSystemLabel)"
    }
}

if (-not $vol) {
    $iso = Resolve-Iso -Path $IsoPath -MintVersion $MintVersion -DownloadDir $DownloadDir -AutoDownload:(-not $SkipIsoDownload)
    Test-LiveIso -Iso $iso

    if ($SkipRufus) {
        WriteStep 'Skipping Rufus (-SkipRufus).'
        Write-Info 'Write the image yourself (e.g. with Rufus), then this step picks up the USB.'
        $vol = Wait-UsbReady -Label $VolumeLabel
    } else {
        $rufus = Get-Rufus -Path $RufusPath
        WriteStep 'Launching Rufus with the ISO pre-selected.'
        Write-Info 'In Rufus: pick the target USB stick, then click START (this is the one destructive confirmation).'
        $proc = Start-Process -FilePath $rufus -Verb RunAs -PassThru -ArgumentList @('-i', "`"$iso`"", '-f', 'FAT32')

        # Snapshot the volumes present before the write, so the wait can prefer
        # the freshly-written stick over any other Mint USB that was already there.
        $knownVols = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } | ForEach-Object { $_.DriveLetter })
        $vol = Wait-UsbReady -RufusProc $proc -Label $VolumeLabel -KnownVolumes $knownVols
    }
}

WriteStep 'Dropping lsl-usb files onto the USB...'
Install-LslFiles -Vol $vol -BundleDir $BundleDir

if ($guiDataDir) {
    $envFile = "$($vol.DriveLetter):\lsl-usb.env"
    if (Test-Path $envFile) {
        $content = Get-Content $envFile -Raw
        if ($content -match '(?m)^LSL_DATA_DIR=') {
            $content = $content -replace '(?m)^LSL_DATA_DIR=.*$', "LSL_DATA_DIR=$guiDataDir"
        } else {
            $content += "`nLSL_DATA_DIR=$guiDataDir`n"
        }
        Set-Content -Encoding ascii -Path $envFile -Value $content
        Write-Info "Set LSL_DATA_DIR=$guiDataDir in lsl-usb.env"
    }
}

WriteStep 'Locating WSL VHDX files...'
$vhdx = Get-WslVhdxPaths -Extra $WslVhdx
if ($vhdx) {
    $conf = "$($vol.DriveLetter):\lsl-wsl-vhdx.conf"
    $vhdx | Set-Content -Encoding ascii -Path $conf
    Write-Info "Wrote $($vhdx.Count) VHDX path(s) to $conf (Linux mounts them via detect-wsl/guestmount)."
} else {
    Write-Warn2 'No WSL VHDX files found; Linux will still auto-detect WSL rootfs dirs at boot.'
}

WriteStep 'Preloading flatpak refs for apps you have on Windows...'
Write-FlatpakRefs -Vol $vol -Extra $FlatpakApps

if ($installEverything -and -not (Get-EverythingPath)) {
    WriteStep 'Everything (voidtools) not found - installing the portable version...'
    $null = Install-Everything
    # The GUI's ISO discovery ran before the install; re-run it now that the
    # index is available (the picker will be full-disk on the next run).
    $nowIsos = Find-EverythingIsos
    if ($nowIsos.Count -gt 0) {
        Write-Info "Everything index now available - $($nowIsos.Count) ISO(s) found full-disk (re-run the installer to use them in the picker)."
    }
}

if ($doEfu) {
    WriteStep 'Exporting Everything index (EFU) for Linux browsing...'
    Write-EverythingEfu -Vol $vol
} else {
    Write-Info 'Skipping Everything index export (unchecked).'
}

if ($copyWifi) {
    WriteStep 'Generating wifi.sh from Windows saved wifi profiles (netsh)...'
    $wifiLines = Get-WifiLines -Profiles $wifiNetworks
    if ($wifiLines) {
        $wifiSh = "$($vol.DriveLetter):\wifi.sh"
        @('#!/bin/bash', '# Generated by lsl-usb install.ps1 from Windows saved profiles (netsh).') +
            $wifiLines | Set-Content -Encoding ascii -Path $wifiSh
        Write-Info "wifi.sh written ($($wifiLines.Count) network(s))."
    } else {
        Write-Warn2 'No saved wifi profile with a retrievable key found; wifi.sh not written.'
    }
} else {
    Write-Info 'Skipping wifi.sh (Copy Wifi Settings to LSL unchecked).'
}

WriteStep 'Done.'
Write-Info 'Boot the USB. First boot runs the minimal layer script (installs packages, then persists a new layer).'
Write-Info 'Set LSL_DATA_DIR in /cdrom/lsl-usb.env if you do not want the default (/mnt/c/Users/lsl-usb).'
