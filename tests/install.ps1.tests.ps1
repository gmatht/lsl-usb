# tests/install.ps1.tests.ps1 - mock-based tests for install.ps1.
#
# Catches the recurring bug classes: the @() array-wrap (5 instances), the
# StrictMode property crashes, and the unset-variable bugs. Runs on Windows or
# Linux pwsh (Windows-only cmdlets are mocked).
#
# Run: pwsh -NoProfile -File tests/install.ps1.tests.ps1
$ErrorActionPreference = 'Stop'
$script:pass = 0; $script:fail = 0

# Ensure a usable temp root (Linux pwsh can leave $env:TEMP empty, which breaks
# the temp-bundle tests below; Windows always has a valid $env:TEMP).
if (-not $env:TEMP -or -not (Test-Path -PathType Container $env:TEMP)) {
    $env:TEMP = [System.IO.Path]::GetTempPath()
    if (-not $env:TEMP) { $env:TEMP = '/tmp' }
}

function Assert-True {
    param([bool]$Cond, [string]$Name)
    if ($Cond) { $script:pass++; Write-Host "  PASS: $Name" }
    else { $script:fail++; Write-Host "  FAIL: $Name" }
}
function Assert-False {
    param([bool]$Cond, [string]$Name)
    if (-not $Cond) { $script:pass++; Write-Host "  PASS: $Name" }
    else { $script:fail++; Write-Host "  FAIL: $Name" }
}


# --- load install.ps1 functions (everything before the main flow) ----------
# AST parse check - fail fast on syntax errors before anything else.
$tokens = $null; $parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\install.ps1'), [ref]$tokens, [ref]$parseErrors) | Out-Null
if ($parseErrors.Count -gt 0) { throw "install.ps1 parse errors: $($parseErrors[0].Message)" }
# The shared detection module (install.ps1's own dot-source is guarded and
# skipped in the harness context, so load it here from the repo root).
. (Join-Path $PSScriptRoot '..\bin\lsl-win-detect.ps1')
$src = Get-Content (Join-Path $PSScriptRoot '..\install.ps1') -Raw
$mainIdx = $src.IndexOf("`nShow-CompatNotes")
if ($mainIdx -lt 0) { throw "main-flow marker not found" }
# Define the script's switch parameters as harness-scope variables so the
# Invoke-Expression of the main flow can read them (the param block is excluded
# from the eval'd substring, so they would otherwise be uninitialized under
# Set-StrictMode). Defaults match the no-flag run.
$SkipIsoDownload = $false
$SkipRufus = $false
$PreloadRustTools = $false
$NoGui = $true
$DryRun = $false
$RateHardware = $false
$NoElevation = $true
$IsoPath = ''
$MintVersion = '22.3'
$DownloadDir = ''
$BundleDir = ''
$RufusPath = ''
$VolumeLabel = ''
$WslVhdx = @()
$FlatpakApps = @()
Invoke-Expression $src.Substring(0, $mainIdx)

# --- mocks ----------------------------------------------------------------
$script:mockVolumes = @()
function global:Get-Volume {
    param([string]$DriveLetter, [string]$ErrorAction)
    if ($DriveLetter) { return $script:mockVolumes | Where-Object { $_.DriveLetter -eq $DriveLetter } }
    return $script:mockVolumes
}
function global:Join-Path { param($Path, $ChildPath) "$(($Path -replace '\\','/') -replace '/+$','')/$($ChildPath -replace '\\','/')" }
function global:Test-Path { param($Path, [string]$PathType) ($script:mockPaths -contains $Path) -or ($Path -like 'HKCU:*') -or ($Path -like 'HKLM:*') }
$script:mockPaths = @()
function global:Get-Item { param($Path) [pscustomobject]@{ Length = 3GB } }
function global:Get-Command { param([string]$Name, [string]$ErrorAction) if ($Name -eq 'netsh') { return [pscustomobject]@{ Name = 'netsh' } }; return $null }
function global:Get-ItemProperty { param([string]$Path, [string]$ErrorAction) $script:mockRegProps[$Path] }
$script:mockRegProps = @{}
function global:Get-ChildItem { param([string]$Path, [string]$Recurse, [string]$Filter, [string]$ErrorAction) if ($script:mockChildren.ContainsKey($Path)) { $script:mockChildren[$Path] } else { @() } }
$script:mockChildren = @{}
function global:Get-FileHash { param([string]$Algorithm, [string]$Path) [pscustomobject]@{ Hash = $script:mockHash } }
$script:mockHash = 'a' * 64
function global:Read-Host { param([string]$Prompt) $script:mockReadHost }
$script:mockReadHost = ''
function global:Get-Process { param([string]$Name, [string]$ErrorAction) @() }
function global:Start-Process { param([string]$FilePath, [string]$Verb, [switch]$PassThru, [string[]]$ArgumentList) [pscustomobject]@{ Id = 1 } }
function global:Get-Disk { param([string]$ErrorAction) @() }
function global:Mount-DiskImage { param([string]$ImagePath, [switch]$PassThru) [pscustomobject]@{ } }
function global:Dismount-DiskImage { param([string]$ImagePath, [string]$ErrorAction) }
function global:Get-DiskImage { param([string]$ImagePath) @() }
function global:Get-Partition { param() @() }
function global:Get-CimInstance { param([string]$ClassName, [string]$Filter) @() }
function global:Get-Command2 { }  # placeholder

# netsh mock: profile list + per-profile details
$script:mockNetshProfiles = @('HomeNet', "Bob's Bar")
$script:mockNetshKeys = @{ 'HomeNet' = 'secret1'; "Bob's Bar" = "it's-secret" }
function global:netsh {
    param([string[]]$args)
    if ($args -contains 'profiles') {
        return @('User profiles', '------------', '    All User Profile     : HomeNet', "    All User Profile     : Bob's Bar")
    }
    if ($args -contains 'key=clear') {
        $name = ($args | Where-Object { $_ -like 'name=*' }) -replace '^name=', ''
        $key = $script:mockNetshKeys[$name]
        if ($key) { return @("    Key Content            : $key") }
        return @('    Key Content            : ')
    }
    return @()
}

# --- 1. Find-UsbVolumes: flat array, CD-ROM exclusion, casper/label match ---
Write-Host '== Find-UsbVolumes =='
$script:mockVolumes = @(
    [pscustomobject]@{ DriveLetter = 'G'; FileSystemLabel = 'LINUX MINT'; DriveType = 'Removable'; Size = 59GB; DiskNumber = 1 },
    [pscustomobject]@{ DriveLetter = 'E'; FileSystemLabel = 'Linux Mint 22.2'; DriveType = 'CD-ROM'; Size = 3GB; DiskNumber = $null },
    [pscustomobject]@{ DriveLetter = 'C'; FileSystemLabel = 'Windows'; DriveType = 'Fixed'; Size = 500GB; DiskNumber = 0 }
)
$script:mockPaths = @('G:/casper/filesystem.squashfs')
$vols = @(Find-UsbVolumes -Label '')
Assert-True ($vols.Count -eq 1 -and $vols[0].DriveLetter -eq 'G') 'flat array, CD-ROM excluded, casper matched'
Assert-True ($vols[0].GetType().Name -eq 'PSCustomObject') 'element is a volume, not an array'
# StrictMode: volume without DiskNumber must not throw (the original bug)
Set-StrictMode -Version 2.0
$script:mockVolumes = @([pscustomobject]@{ DriveLetter = 'G'; FileSystemLabel = 'LINUX MINT'; DriveType = 'Removable'; Size = 59GB })
$script:mockPaths = @('G:/casper/filesystem.squashfs')
$ok = $true
try { $null = @(Find-UsbVolumes -Label '') } catch { $ok = $false }
Assert-True $ok 'no throw when a volume lacks DiskNumber'
Set-StrictMode -Off

# --- 2. Get-FlatpakSuggestions: flat, all entries, Matched flags -----------
Write-Host '== Get-FlatpakSuggestions =='
$script:mockRegProps = @{
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' = @(
        [pscustomobject]@{ DisplayName = 'Discord' },
        [pscustomobject]@{ DisplayName = 'Visual Studio Code' }
    )
}
$sugg = Get-FlatpakSuggestions
Assert-True ($sugg.Count -eq 16) 'all 16 map entries returned (flat)'
Assert-True ($sugg[0].App -eq 'Slack' -and $sugg[1].App -eq 'Discord') 'entries in order'
Assert-True ($sugg[1].Matched -eq $true -and $sugg[0].Matched -eq $false) 'Matched flags correct'
# StrictMode: registry key without DisplayName must not throw
Set-StrictMode -Version 2.0
$script:mockRegProps = @{
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' = @(
        [pscustomobject]@{ DisplayName = 'Discord' },
        [pscustomobject]@{ SomeOther = 'x' }   # no DisplayName
    )
}
$ok = $true
try { $null = Get-FlatpakSuggestions } catch { $ok = $false }
Assert-True $ok 'no throw when a registry key lacks DisplayName'
Set-StrictMode -Off

# --- 3. Get-WslVhdxPaths: flat, \\?\ prefix, missing BasePath --------------
Write-Host '== Get-WslVhdxPaths =='
$script:mockRegProps = @{
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' = $null
}
$script:mockChildren = @{
    'HKCU:/Software/Microsoft/Windows/CurrentVersion/Lxss' = @(
        [pscustomobject]@{ PSPath = 'HKCU:\...\Lxss\{guid1}'; PSChildName = '{guid1}' },
        [pscustomobject]@{ PSPath = 'HKCU:\...\Lxss\Notifications'; PSChildName = 'Notifications' }
    )
}
$script:mockRegProps['HKCU:\...\Lxss\{guid1}'] = [pscustomobject]@{ BasePath = '\\?\D:\WSL\Ubuntu2404'; Version = 2 }
$script:mockRegProps['HKCU:\...\Lxss\Notifications'] = [pscustomobject]@{ }   # no BasePath
$script:mockPaths = @('D:/WSL/Ubuntu2404/ext4.vhdx')
$vhdx = Get-WslVhdxPaths -Extra @()
Assert-True ($vhdx.Count -eq 1 -and $vhdx[0] -eq 'D:/WSL/Ubuntu2404/ext4.vhdx') 'flat array, \\?\ prefix stripped'
# StrictMode: subkey without BasePath must not throw
Set-StrictMode -Version 2.0
$ok = $true
try { $null = Get-WslVhdxPaths -Extra @() } catch { $ok = $false }
Assert-True $ok 'no throw when a Lxss subkey lacks BasePath'
Set-StrictMode -Off

# --- 4. Find-EverythingIsos: no Everything -> empty, no error --------------
Write-Host '== Find-EverythingIsos =='
$isos = Find-EverythingIsos   # plain assignment, like the real callers
Assert-True (@($isos).Count -eq 0) 'no Everything -> empty (no error)'

# --- 5. ConvertFrom-Json flat (the wizard checkbox collapse) ---------------
Write-Host '== ConvertFrom-Json flat =='
$raw = '[{"App":"Discord","FlatpakId":"com.discordapp.Discord","Matched":true},{"App":"Visual Studio Code","FlatpakId":"com.visualstudio.code","Matched":true}]'
$sugg2 = $raw | ConvertFrom-Json
Assert-True ($sugg2.Count -eq 2 -and $sugg2[1].App -eq 'Visual Studio Code') 'plain assignment keeps the array flat'

# --- 6. Get-WifiLines: quoting + profile filtering -------------------------
Write-Host '== Get-WifiLines =='
$lines = Get-WifiLines -Profiles @('HomeNet', "Bob's Bar")
Assert-True ($lines.Count -eq 2) 'two networks'
Assert-True ($lines[0] -eq "nmcli device wifi connect 'HomeNet' password 'secret1'") 'simple quoting'
Assert-True ($lines[1] -eq "nmcli device wifi connect 'Bob'\''s Bar' password 'it'\''s-secret'") 'apostrophe quoting'

# --- 7. Resolve-Iso: ISO already present (the $base bug) --------------------
Write-Host '== Resolve-Iso (ISO present) =='
$dlDir = Join-Path $env:TEMP 'lsl-test-dl'
New-Item -ItemType Directory -Force -Path $dlDir | Out-Null
$isoPath = Join-Path $dlDir 'linuxmint-22.3-cinnamon-64bit.iso'
$script:mockPaths = @($isoPath -replace '\\', '/')
$script:mockHash = 'a' * 64
# expected checksum line: hash + name; make the mock hash match
$expectedHash = 'a' * 64
$script:mockDownload = "$expectedHash  linuxmint-22.3-cinnamon-64bit.iso"
function global:Download { param([string]$Url, [string]$Destination) New-Item -ItemType Directory -Force -Path (Split-Path $Destination) | Out-Null; Set-Content -Path $Destination -Value $script:mockDownload }
$resolved = Resolve-Iso -Path '' -MintVersion '22.3' -DownloadDir $dlDir -AutoDownload
Assert-True ($resolved -eq $isoPath) 'ISO present -> verified and returned (no $base crash)'

# --- 8. runspace: chosen-ISO path + cancel path ----------------------------
Write-Host '== runspace =='
$m = [regex]::Match($src, "\$runspaceScript = @'(.*?)'@", 'Singleline')
if ($m.Success) {
    $rs = $m.Groups[1].Value
    $s1 = [hashtable]::Synchronized(@{ Phase='iso'; Percent=0; Message=''; Done=$false; Error=''; IsoPath=''; EtaSec=-1; CancelDownload=$false; ChosenIso='D:\x\other.iso'; ReuseUsb='' })
    & ([scriptblock]::Create($rs)) $s1 '' '22.3' '/tmp'
    Assert-True ($s1.Done -and $s1.IsoPath -eq 'D:\x\other.iso' -and -not $s1.Error) 'chosen ISO used directly (no download)'
    $s2 = [hashtable]::Synchronized(@{ Phase='iso'; Percent=0; Message=''; Done=$false; Error=''; IsoPath=''; EtaSec=-1; CancelDownload=$false; ChosenIso=''; ReuseUsb='G:' })
    & ([scriptblock]::Create($rs)) $s2 '' '22.3' '/tmp'
    Assert-True ($s2.Done -and -not $s2.Error) 'reuse-USB path completes immediately'
} else {
    Assert-True $false 'runspace script found'
}

# --- 9. -NoGui console flow: Select-ExistingUsb / Select-ExistingIso ---------
Write-Host '== -NoGui console flow =='
$script:mockVolumes = @(
    [pscustomobject]@{ DriveLetter = 'G'; FileSystemLabel = 'LINUX MINT'; DriveType = 'Removable'; Size = 59GB },
    [pscustomobject]@{ DriveLetter = 'C'; FileSystemLabel = 'Windows'; DriveType = 'Fixed'; Size = 500GB }
)
$script:mockPaths = @('G:/casper/filesystem.squashfs')
$script:mockReadHost = '1'
$chosen = Select-ExistingUsb -Label ''
Assert-True ($chosen -and $chosen.DriveLetter -eq 'G') 'Select-ExistingUsb picks the chosen volume'

# Select-ExistingIso: Everything present -> prompt -> pick
function global:Find-EverythingIsos { return ,@('D:\iso\a.iso', 'D:\iso\b.iso') }
$script:mockReadHost = '2'
$picked = Select-ExistingIso
Assert-True ($picked -eq 'D:\iso\b.iso') 'Select-ExistingIso picks the chosen ISO'
Remove-Item function:global:Find-EverythingIsos -ErrorAction SilentlyContinue

# Resolve-Iso download path: ISO missing -> download + verify
function global:Find-EverythingIsos { return ,@() }   # no Everything offer
$dlDir2 = Join-Path $env:TEMP 'lsl-test-dl2'
New-Item -ItemType Directory -Force -Path $dlDir2 | Out-Null
$script:mockPaths = @()   # ISO not present -> download path
$script:mockHash = 'a' * 64
$script:mockDownload = "$('a' * 64)  linuxmint-22.3-cinnamon-64bit.iso"
$resolved2 = Resolve-Iso -Path '' -MintVersion '22.3' -DownloadDir $dlDir2 -AutoDownload
Assert-True ($resolved2 -eq (Join-Path $dlDir2 'linuxmint-22.3-cinnamon-64bit.iso')) 'Resolve-Iso download path downloads + verifies'

# --- 10. Wait-UsbReady flow (the -NoGui Rufus wait) ---
Write-Host '== Wait-UsbReady flow =='
function global:Start-Sleep { param($Seconds) }   # no-op so the wait loops run fast
function global:Get-Process { param([string]$Name, [string]$ErrorAction) @() }   # rufus gone
$script:mockVolumes = @(
    [pscustomobject]@{ DriveLetter = 'G'; FileSystemLabel = 'LINUX MINT'; DriveType = 'Removable'; Size = 59GB }
)
$script:mockPaths = @('G:/casper/filesystem.squashfs')
$script:mockReadHost = ''
# RufusProc = $null exercises the backup signal (volume detectable) - the
# KnownVolumes preference lives in both the primary and backup paths.
$vol = Wait-UsbReady -RufusProc $null -Label '' -KnownVolumes @('C')
Assert-True ($vol -and $vol.DriveLetter -eq 'G') 'Wait-UsbReady returns the volume (backup signal)'

# KnownVolumes preference: a pre-existing Mint USB (E:) must lose to the new one (G:)
$script:mockVolumes = @(
    [pscustomobject]@{ DriveLetter = 'E'; FileSystemLabel = 'LINUX MINT'; DriveType = 'Removable'; Size = 32GB },
    [pscustomobject]@{ DriveLetter = 'G'; FileSystemLabel = 'LINUX MINT'; DriveType = 'Removable'; Size = 59GB }
)
$script:mockPaths = @('E:/casper/filesystem.squashfs', 'G:/casper/filesystem.squashfs')
$vol2 = Wait-UsbReady -RufusProc $null -Label '' -KnownVolumes @('E')
Assert-True ($vol2 -and $vol2.DriveLetter -eq 'G') 'Wait-UsbReady prefers the freshly-written volume over a known one'
Remove-Item function:global:Start-Sleep -ErrorAction SilentlyContinue

# --- 11. GUI layout bounds (static check: controls fit the 640x760 ClientSize) ---
Write-Host '== GUI layout bounds =='
$layoutOk = $true
$layoutBad = @()
foreach ($m in [regex]::Matches($src, 'System\.Drawing\.Point\((\d+), (\d+)\)')) {
    $x = [int]$m.Groups[1].Value; $y = [int]$m.Groups[2].Value
    if ($x -gt 640 -or $y -gt 760) { $layoutOk = $false; $layoutBad += "Point($x,$y)" }
}
foreach ($m in [regex]::Matches($src, 'System\.Drawing\.Size\((\d+), (\d+)\)')) {
    $w = [int]$m.Groups[1].Value; $h = [int]$m.Groups[2].Value
    if ($w -gt 640 -or $h -gt 760) { $layoutOk = $false; $layoutBad += "Size($w,$h)" }
}
Assert-True $layoutOk "all GUI control positions/sizes within the 640x760 ClientSize$(if ($layoutBad) { ' - ' + ($layoutBad -join ', ') })"

# --- 12. Install-LslFiles (the drop-in) ---
Write-Host '== Install-LslFiles =='
$script:mockCopied = @()
function global:New-Item { param([string]$ItemType, [switch]$Force, [string]$Path) }
function global:Copy-Item { param([string]$Path, [string]$Destination, [switch]$Recurse, [switch]$Force) $script:mockCopied += $Path }
$bundle = '/bundle'
$script:mockPaths = @(
    "$bundle/filesystem_z0_firstboot.squashfs",
    "$bundle/bin", "$bundle/systemd", "$bundle/onboot.sh", "$bundle/lsl-usb.env"
)
$vol3 = [pscustomobject]@{ DriveLetter = 'G' }
Install-LslFiles -Vol $vol3 -BundleDir $bundle
Assert-True ($script:mockCopied.Count -eq 5) 'Install-LslFiles copies the layer + 4 FAT-side items'
Remove-Item function:global:New-Item -ErrorAction SilentlyContinue

# --- 12b. Install-RustTools (direct GitHub download of i686-musl prebuilts) ---
Write-Host '== Install-RustTools =='
$script:mockPaths = @()
function global:New-Item { param([string]$ItemType, [switch]$Force, [string]$Path) }
function global:Copy-Item { param([string]$Path, [string]$Destination, [switch]$Force) $script:mockCopied += $Destination }
function global:Get-ChildItem {
    param([string]$Path, [string]$Recurse, [string]$Filter, [string]$ErrorAction)
    if ($Filter -eq 'fd' -or $Filter -eq 'bat' -or $Filter -eq 'zoxide') {
        return @([pscustomobject]@{ FullName = ($Path + '\' + $Filter); PSIsContainer = $false })
    }
    return @()
}
function global:Invoke-RestMethod {
    param([string]$Uri, [hashtable]$Headers)
    if ($Uri -match 'repos/([^/]+/[^/]+)/releases/latest') {
        $repo = $Matches[1]
        $asset = $repo -replace '/', '_'
        return [pscustomobject]@{
            tag_name = 'v1.0'
            assets = @([pscustomobject]@{
                name = "$asset-i686-unknown-linux-musl.tar.gz"
                browser_download_url = "https://github.com/$repo/releases/download/v1.0/$asset-i686-unknown-linux-musl.tar.gz"
                size = 1234567
            })
        }
    }
    return $null
}
$script:mockDownloaded = @()
function global:Download { param([string]$Url, [string]$Destination) $script:mockDownloaded += $Url; Set-Content -Path $Destination -Value 'fake-tarball' }
$script:mockCopied = @()
$vol5 = [pscustomobject]@{ DriveLetter = 'G' }
Install-RustTools -Vol $vol5
Assert-True ($script:mockDownloaded.Count -eq 3) 'Install-RustTools downloads fd/bat/zoxide (3 assets)'
Assert-True ($script:mockCopied -contains 'G:/bin/fd' -and $script:mockCopied -contains 'G:/bin/bat' -and $script:mockCopied -contains 'G:/bin/zoxide') 'Install-RustTools stages each binary into <USB>:\bin'
function global:Invoke-RestMethod { param([string]$Uri, [hashtable]$Headers) return [pscustomobject]@{ tag_name = 'v1.0'; assets = @() } }
$script:mockDownloaded = @(); $script:mockCopied = @()
$vol6 = [pscustomobject]@{ DriveLetter = 'G' }
$ok = $true
try { Install-RustTools -Vol $vol6 } catch { $ok = $false }
Assert-True $ok 'Install-RustTools does not throw when no asset is found (logs a warning)'
Remove-Item function:global:New-Item -ErrorAction SilentlyContinue
Remove-Item function:global:Copy-Item -ErrorAction SilentlyContinue
Remove-Item function:global:Get-ChildItem -ErrorAction SilentlyContinue
Remove-Item function:global:Invoke-RestMethod -ErrorAction SilentlyContinue
Remove-Item function:global:Download -ErrorAction SilentlyContinue

Remove-Item function:Copy-Item -ErrorAction SilentlyContinue   # NB: 'function:global:Copy-Item' does NOT remove a global function

# --- 13. Network driver detection + staging ---
Write-Host '== Network driver detection =='
function New-FakePackagesGz {
    param([string]$Path, [string]$Content)
    $fs = [System.IO.File]::Create($Path)
    $gz = New-Object System.IO.Compression.GZipStream($fs, [System.IO.Compression.CompressionMode]::Compress)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
    $gz.Write($bytes, 0, $bytes.Length)
    $gz.Close(); $fs.Close()
}

# Get-PnpHardware / Get-NetworkHardware: PCI + USB ID extraction, class filter,
# empty-ID skip, flat array
function global:Get-CimInstance {
    param([string]$ClassName, [string]$Filter)
    if ($ClassName -eq 'Win32_PnPEntity') {
        $devs = @(
            [pscustomobject]@{ Name = 'Realtek RTL8812AU Wireless Adapter'; PNPDeviceID = 'USB\VID_0BDA&PID_8812&REV_02'; PNPClass = 'Net' },
            [pscustomobject]@{ Name = 'Broadcom BCM43142'; PNPDeviceID = 'PCI\VEN_14E4&DEV_4365&SUBSYS_0000'; PNPClass = 'Net' },
            [pscustomobject]@{ Name = 'NVIDIA GeForce GPU'; PNPDeviceID = 'PCI\VEN_10DE&DEV_1C82&SUBSYS_0000'; PNPClass = 'Display' },
            [pscustomobject]@{ Name = 'Intel Ethernet Connection'; PNPDeviceID = 'PCI\VEN_8086&DEV_15B8&SUBSYS_0000'; PNPClass = 'Net' },
            [pscustomobject]@{ Name = 'No ID device'; PNPDeviceID = ''; PNPClass = 'Net' }
        )
        if ($Filter -match 'Net') { return @($devs | Where-Object { $_.PNPClass -eq 'Net' }) }
        return $devs
    }
    return @()
}
$all = Get-PnpHardware
Assert-True ($all.Count -eq 4) 'Get-PnpHardware extracts PCI+USB, skips empty IDs'
Assert-True ($all[0].Id -eq '0BDA:8812' -and $all[0].Kind -eq 'USB') 'USB ID parsed (VID:PID)'
Assert-True ($all[1].Id -eq '14E4:4365' -and $all[1].Kind -eq 'PCI') 'PCI ID parsed (VEN:DEV)'
$nets = Get-PnpHardware -Class 'Net'
Assert-True ($nets.Count -eq 3) 'Get-PnpHardware -Class Net filters by class'
$compat = Get-CompatHardware
Assert-True ($compat.Count -eq 4) 'Get-CompatHardware includes Net + Display classes'

# Resolve-DriverNeeds: matches only known-problem chips (RTL8812AU + BCM43142)
$hw = Get-NetworkHardware
$needs = Resolve-DriverNeeds -Hardware $hw
Assert-True ($needs.Count -eq 2) 'Resolve-DriverNeeds matches RTL8812AU + BCM43142 only'
Assert-True ($needs[0].Table.Chip -eq 'Realtek RTL8812AU') 'first match is RTL8812AU'
Assert-True ($needs[1].Table.Source -eq 'ubuntu') 'BCM43142 source is ubuntu (broadcom-sta-dkms)'
Remove-Item function:global:Get-CimInstance -ErrorAction SilentlyContinue

# Get-UbuntuPackageUrl: parse a fake Packages index (gz)
$fakeIndex = @'
Package: rtl8812au-dkms
Version: 4.3.8.12175.20140902+dfsg-0ubuntu23.1
Filename: pool/universe/r/rtl8812au/rtl8812au-dkms_4.3.8.12175.20140902+dfsg-0ubuntu23.1_all.deb

Package: broadcom-sta-dkms
Version: 6.30.223.271-23ubuntu1.2
Filename: pool/restricted/b/broadcom-sta/broadcom-sta-dkms_6.30.223.271-23ubuntu1.2_all.deb

Package: other-pkg
Version: 1.0
Filename: pool/universe/o/other/other-pkg_1.0_all.deb
'@
$fakeGz = Join-Path $env:TEMP ('lsl-test-packages-' + [guid]::NewGuid().ToString('N') + '.gz')
New-FakePackagesGz -Path $fakeGz -Content $fakeIndex
# Clear any stale index cache from previous runs (a locked file would make the
# mock Copy-Item fail and the parse return empty).
Remove-Item (Join-Path $env:TEMP 'lsl-apt-noble-updates-universe-Packages.gz') -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:TEMP 'lsl-apt-noble-updates-restricted-Packages.gz') -Force -ErrorAction SilentlyContinue
$script:mockPaths = @()
function global:Download {
    param([string]$Url, [string]$Destination)
    # .NET copy: the harness's Copy-Item mock may still be active (its removal
    # syntax is wrong), so do not depend on the Copy-Item cmdlet here.
    [System.IO.File]::Copy($fakeGz, $Destination, $true)
    $script:mockPaths += $Destination
}
$debUrl = Get-UbuntuPackageUrl -Package 'rtl8812au-dkms' -Suite 'noble-updates' -Component 'universe'
Assert-True ($debUrl -eq 'http://archive.ubuntu.com/ubuntu/pool/universe/r/rtl8812au/rtl8812au-dkms_4.3.8.12175.20140902+dfsg-0ubuntu23.1_all.deb') 'Get-UbuntuPackageUrl resolves the exact .deb URL'
$debUrl2 = Get-UbuntuPackageUrl -Package 'missing-pkg' -Suite 'noble-updates' -Component 'universe'
Assert-True ($debUrl2 -eq '') 'Get-UbuntuPackageUrl returns empty for unknown package'

# Get-DriverDownloadUrl: github tarball + ubuntu deb (uses the index cache above)
$table = Get-DriverTable
$dl1 = Get-DriverDownloadUrl -Entry ($needs | Where-Object { $_.Table.Chip -eq 'Realtek RTL8812AU' }).Table
Assert-True ($dl1.FileName -match '^rtl8812au-dkms_.*\.deb$') 'ubuntu deb filename for RTL8812AU'
$dl2 = Get-DriverDownloadUrl -Entry ($needs | Where-Object { $_.Table.Chip -eq 'Broadcom BCM43142' }).Table
Assert-True ($dl2.FileName -match '^broadcom-sta-dkms_.*\.deb$') 'ubuntu deb filename for BCM43142'
$dl3 = Get-DriverDownloadUrl -Entry ($table | Where-Object { $_.Chip -eq 'Realtek RTL8814AU' })
Assert-True ($dl3.Url -eq 'https://github.com/morrownr/8814au/archive/refs/heads/main.tar.gz') 'github tarball URL for RTL8814AU'
Assert-True ($dl3.FileName -eq 'rtl8814au.tar.gz') 'github tarball filename'
Remove-Item function:global:Download -ErrorAction SilentlyContinue
Remove-Item $fakeGz -Force -ErrorAction SilentlyContinue

# Install-DriverPackages: stages the matched driver + writes the report
function global:Get-CimInstance {
    param([string]$ClassName, [string]$Filter)
    if ($ClassName -eq 'Win32_PnPEntity') {
        return @(
            [pscustomobject]@{ Name = 'Realtek RTL8814AU Wireless Adapter'; PNPDeviceID = 'USB\VID_0BDA&PID_881A&REV_02'; PNPClass = 'Net' }
        )
    }
    return @()
}
function global:New-Item { param([string]$ItemType, [switch]$Force, [string]$Path) }
function global:Download {
    param([string]$Url, [string]$Destination)
    # Simulate a successful download: record the destination (the G:\ path does
    # not exist on the Linux test host, so do not touch the filesystem).
    $script:mockPaths += $Destination
}
$script:mockPaths = @()
$vol4 = [pscustomobject]@{ DriveLetter = 'G' }
$rep = Install-DriverPackages -Vol $vol4
Assert-True ($rep.Count -eq 1) 'Install-DriverPackages returns one report line'
Assert-True ($rep[0] -match '^STAGE Realtek RTL8814AU') 'report line says STAGE RTL8814AU'
Assert-True ($script:mockPaths -contains 'G:/drivers/rtl8814au.tar.gz') 'tarball staged to <USB>:\drivers\'
Remove-Item function:global:Get-CimInstance -ErrorAction SilentlyContinue
Remove-Item function:New-Item -ErrorAction SilentlyContinue   # NB: 'function:global:New-Item' does NOT remove a global function
Remove-Item function:global:Download -ErrorAction SilentlyContinue

# --- 14. Linux compatibility rating (linux-hardware.org LKDDb) ---
Write-Host '== Linux compatibility rating =='
$script:lhwDelaySec = 0
$script:lhwLastRequest = $null
# Drop any stale real LKDDb pages left in %TEMP% by a prior DryRun, so the
# mock-based rating tests below read the mock pages and not a cached real one.
foreach ($id in @('pci:8086-2723','usb:0bda-9999','pci:14e4-43ec','usb:0bda-9998','pci:14e4-4365')) {
    Remove-Item (Join-Path $env:TEMP ("lsl-lhw-" + ($id -replace '[:]', '-') + '.html')) -Force -ErrorAction SilentlyContinue
}
$fakeInKernel = @'
<html><body>
<h2 class='top'>Device 'Intel Wi-Fi 6 AX1650'</h2>
<p>The device is supported by kernel versions <a href="https://www.kernel.org/">5.2 and newer</a> according to the LKDDb:</p>
<table><tbody><tr><td>5.2&nbsp;-&nbsp;7.1</td><td>drivers/net/wireless/intel/iwlwifi/iwl-drv.c</td></tr></tbody></table>
</body></html>
'@
$fakeNewKernel = @'
<html><body>
<h2 class='top'>Device 'Realtek RTL8812AU'</h2>
<p>The device is supported by kernel versions <a href="https://www.kernel.org/">6.14 and newer</a> according to the LKDDb:</p>
<table><tbody><tr><td>6.14&nbsp;-&nbsp;7.1</td><td>drivers/net/wireless/realtek/rtw88/rtw8812au.c</td></tr></tbody></table>
</body></html>
'@
$fakeBridge = @'
<html><body>
<h2 class='top'>Device 'Broadcom BCM4356'</h2>
<p>The device is supported by kernel versions <a href="https://www.kernel.org/">4.17 and newer</a> according to the LKDDb:</p>
<table><tbody><tr><td>4.17&nbsp;-&nbsp;7.1</td><td>drivers/bcma/host_pci.c</td></tr></tbody></table>
</body></html>
'@
$fakeNoEntry = @'
<html><body>
<h2 class='top'>Device 'Unknown chip'</h2>
<p>No kernel driver information.</p>
</body></html>
'@
$script:mockLhwPages = @{
    'https://linux-hardware.org/?id=pci:8086-2723' = $fakeInKernel
    'https://linux-hardware.org/?id=usb:0bda-9999' = $fakeNewKernel
    'https://linux-hardware.org/?id=pci:14e4-43ec' = $fakeBridge
    'https://linux-hardware.org/?id=usb:0bda-9998' = $fakeNoEntry
}
function global:Get-LhwPage {
    param([string]$Url)
    if ($script:mockLhwPages.ContainsKey($Url)) { return $script:mockLhwPages[$Url] }
    return ''
}
# The rating flow writes cache files and re-checks them with Test-Path; the
# harness mock only knows mockPaths, so extend it to see the real filesystem.
function global:Test-Path {
    param($Path, [string]$PathType)
    ($script:mockPaths -contains $Path) -or [System.IO.File]::Exists($Path) -or ($Path -like 'HKCU:*') -or ($Path -like 'HKLM:*')
}
$script:mockPaths = @()
$devA = [pscustomobject]@{ Name = 'Intel Wi-Fi 6 AX1650'; Kind = 'PCI'; Vendor = '8086'; Device = '2723'; Id = '8086:2723'; Class = 'Net' }
$rA = Get-LinuxCompatRating -Device $devA
Assert-True ($rA.Rating -eq 'A') 'rating A for in-kernel device'
Assert-True ($rA.Reason -match 'in-kernel since 5.2') 'A reason mentions the kernel range'
$devC = [pscustomobject]@{ Name = 'Fake new chip'; Kind = 'USB'; Vendor = '0BDA'; Device = '9999'; Id = '0BDA:9999'; Class = 'Net' }
$rC = Get-LinuxCompatRating -Device $devC
Assert-True ($rC.Rating -eq 'C') 'rating C for newer-kernel-only device'
Assert-True ($rC.Reason -match 'needs kernel 6.14') 'C reason mentions the required kernel'
$devD = [pscustomobject]@{ Name = 'Broadcom BCM4356'; Kind = 'PCI'; Vendor = '14E4'; Device = '43EC'; Id = '14E4:43EC'; Class = 'Net' }
$rD = Get-LinuxCompatRating -Device $devD
Assert-True ($rD.Rating -eq 'D') 'rating D for bridge-only LKDDb entry'
$devU = [pscustomobject]@{ Name = 'Unknown chip'; Kind = 'USB'; Vendor = '0BDA'; Device = '9998'; Id = '0BDA:9998'; Class = 'Net' }
$rU = Get-LinuxCompatRating -Device $devU
Assert-True ($rU.Rating -eq 'U') 'rating U for no LKDDb entry'
$devT = [pscustomobject]@{ Name = 'Broadcom BCM43142'; Kind = 'PCI'; Vendor = '14E4'; Device = '4365'; Id = '14E4:4365'; Class = 'Net' }
$rT = Get-LinuxCompatRating -Device $devT
Assert-True ($rT.Rating -eq 'C' -and $rT.Staged) 'rating C + staged for table chip (BCM43142)'
$rep2 = Get-HardwareCompatReport -Devices @($devA, $devT)
Assert-True ($rep2.Count -eq 2) 'Get-HardwareCompatReport returns one line per device'
Assert-True ($rep2[0] -match '^\[A\]') 'report line starts with [A]'
Remove-Item function:global:Get-LhwPage -ErrorAction SilentlyContinue
# Clean up the cache files the rating tests wrote (they share %TEMP% with the
# real installer - a fake page must not leak into a real run).
Remove-Item (Join-Path $env:TEMP 'lsl-lhw-pci-8086-2723.html') -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:TEMP 'lsl-lhw-usb-0bda-9999.html') -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:TEMP 'lsl-lhw-pci-14e4-43ec.html') -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:TEMP 'lsl-lhw-usb-0bda-9998.html') -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:TEMP 'lsl-lhw-pci-14e4-4365.html') -Force -ErrorAction SilentlyContinue

# --- Bundled cache hit path: common hardware must rate with NO network ---
$fakeBundle = Join-Path $env:TEMP ('lsl-bundle-' + [guid]::NewGuid().ToString('N'))
$bundleHwDir = Join-Path $fakeBundle 'lsl-hw-cache'
New-Item -ItemType Directory -Path $bundleHwDir -Force | Out-Null
$bundlePage = Join-Path $bundleHwDir 'lsl-lhw-pci-8086-2723.html'
Set-Content -Path $bundlePage -Value $fakeInKernel
$script:BundleDir = $fakeBundle
$script:lhwLastRequest = $null
# If the network were used, this mock would fire and return a sentinel.
$global:sentinel = $false
function global:Get-LhwPage { param([string]$Url) $global:sentinel = $true; return 'NETWORK-WAS-USED' }
$rB = Get-LinuxCompatRating -Device $devA
Assert-True ($rB.Rating -eq 'A') 'bundled cache: rating A served from the bundle'
Assert-True (-not $global:sentinel) 'bundled cache: network (Get-LhwPage) is NOT used'
Remove-Item function:global:Get-LhwPage -ErrorAction SilentlyContinue
Remove-Item $fakeBundle -Recurse -Force -ErrorAction SilentlyContinue
$script:BundleDir = $null

Write-Host ''
Write-Host "RESULT: $($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
