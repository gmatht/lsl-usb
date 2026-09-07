$env:LSL_GUI_DEBUG = '1'
# Structural test for the INSTALL NOW page (pages 0-5: hw, iso, flatpak,
# system, wifi, install). No mouse coordinates: the Next button is pressed
# with BM_CLICK by HWND, and every assertion reads live control text /
# visibility through Win32. Polling waits for state, never fixed sleeps as
# proof (settling sleeps only).
#
# Covers:
#  (a) the button leading to the install page reads "Next >", not "Install"
#  (b) pressing it never crashes the GUI (process alive + window valid)
#  (c) the 5th press shows the INSTALL page - and does NOT launch Rufus
#  (d) no Rufus radio is visible on any page before the INSTALL page
$ErrorActionPreference = 'Stop'
$dir = 'C:\Users\Public\lsl-test'
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class W {
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint u);
    [DllImport("user32.dll")] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern int GetWindowLongW(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
}
'@
$GW_CHILD = 5
$GW_NEXT = 2
$BM_CLICK = 0x00F5
$GWL_STYLE = -16

$script:fails = @()
function Check([bool]$cond, [string]$name, [string]$detail = '') {
    if ($cond) { Write-Output "PASS $name" }
    else { $script:fails += $name; Write-Output "FAIL $name $detail" }
}

function Kids([IntPtr]$root) {
    $out = @()
    $h = [W]::GetWindow($root, $GW_CHILD)
    while ($h -ne [IntPtr]::Zero) {
        $out += $h
        $out += Kids $h
        $h = [W]::GetWindow($h, $GW_NEXT)
    }
    return $out
}
function Txt([IntPtr]$h) {
    $sb = New-Object System.Text.StringBuilder(512)
    [W]::GetWindowTextW($h, $sb, $sb.Capacity) | Out-Null
    return $sb.ToString()
}
function Cls([IntPtr]$h) {
    $sb = New-Object System.Text.StringBuilder(64)
    [W]::GetClassNameW($h, $sb, $sb.Capacity) | Out-Null
    return $sb.ToString()
}
function Vis([IntPtr]$h) { return [W]::IsWindowVisible($h) }
function Style([IntPtr]$h) { return [W]::GetWindowLongW($h, $GWL_STYLE) }
function IsRadio([IntPtr]$h) {
    if ((Cls $h) -ne 'Button') { return $false }
    $t = (Style $h) -band 0xF
    return ($t -eq 4) -or ($t -eq 9)  # BS_RADIOBUTTON / BS_AUTORADIOBUTTON
}
function IsPush([IntPtr]$h) {
    if ((Cls $h) -ne 'Button') { return $false }
    return (((Style $h) -band 0xF) -eq 0)  # BS_PUSHBUTTON
}
function NextBtn([IntPtr]$main) {
    foreach ($h in Kids $main) {
        if ((IsPush $h) -and (Vis $h)) {
            $t = Txt $h
            if ($t -eq 'Next >' -or $t -eq 'Install') { return $h }
        }
    }
    return [IntPtr]::Zero
}
function VisibleRadios([IntPtr]$main) {
    $out = @()
    foreach ($h in Kids $main) {
        if ((IsRadio $h) -and (Vis $h)) { $out += Txt $h }
    }
    return $out
}
function Alive([Diagnostics.Process]$p, [IntPtr]$main) {
    $p.Refresh()
    return ((-not $p.HasExited) -and ([W]::IsWindow($main)))
}
function WaitFor([scriptblock]$cond, [int]$timeoutSec) {
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt $timeoutSec) {
        try { if (& $cond) { return $true } } catch {}
        Start-Sleep -Milliseconds 200
    }
    return $false
}

$p = Start-Process -FilePath "$dir\lsl-install.exe" -ArgumentList '--no-elevation' -PassThru
try {
    $proc = $null
    $ok = WaitFor {
        $proc = Get-Process lsl-install -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowTitle -like '*lsl-usb installer*' } | Select-Object -First 1
        $null -ne $proc
    } 25
    Check $ok 'window-appears'
    if (-not $ok) { throw 'no window' }
    $main = $proc.MainWindowHandle

    # page markers: one visible control that only exists on each page
    $markers = @(
        { foreach ($h in Kids $main) { if (((Cls $h) -eq 'SysListView32') -and (Vis $h)) { return $true } }; return $false },
        { foreach ($h in Kids $main) { if (((Cls $h) -eq 'Static') -and (Vis $h) -and ((Txt $h) -like '*Download Fresh*')) { return $true } }; return $false },
        { foreach ($h in Kids $main) { if (((Cls $h) -eq 'Static') -and (Vis $h) -and ((Txt $h) -like '*Flatpak*')) { return $true } }; return $false },
        { foreach ($h in Kids $main) { if (((Cls $h) -eq 'Static') -and (Vis $h) -and ((Txt $h) -like '*VHDX*')) { return $true } }; return $false },
        { foreach ($h in Kids $main) { if (((Cls $h) -eq 'Button') -and (Vis $h) -and ((Txt $h) -eq 'Copy Wifi Settings to LSL')) { return $true } }; return $false },
        { foreach ($h in Kids $main) { if (((Cls $h) -eq 'Static') -and (Vis $h) -and ((Txt $h) -eq 'INSTALL NOW')) { return $true } }; return $false }
    )
    Check (WaitFor $markers[0] 10) 'page0-shows-hardware-list'

    # walk pages 0..4 with Next: (a) caption, (b) alive, (d) no Rufus radio
    for ($page = 0; $page -lt 5; $page++) {
        $nb = NextBtn $main
        Check (($nb -ne [IntPtr]::Zero) -and ((Txt $nb) -eq 'Next >')) "page${page}-next-says-next" "got '$(Txt $nb)'"
        $rufus = @(VisibleRadios $main | Where-Object { $_ -like '*Rufus*' })
        Check ($rufus.Count -eq 0) "page${page}-no-rufus-radio" "got '$($rufus -join ';')'"
        Check (Alive $proc $main) "page${page}-alive"
        [W]::SendMessageW($nb, $BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        $next = $page + 1
        Check (WaitFor $markers[$next] 10) "page${next}-shows"
        Check (Alive $proc $main) "after-click${next}-alive"
    }

    # (c) page 5 IS the INSTALL page - and Rufus never launched
    $nb = NextBtn $main
    Check (($nb -ne [IntPtr]::Zero) -and ((Txt $nb) -eq 'Install')) 'install-page-button-says-install' "got '$(Txt $nb)'"
    $hasRufusChoice = $false
    foreach ($t in VisibleRadios $main) { if ($t -like '*Rufus*') { $hasRufusChoice = $true } }
    Check $hasRufusChoice 'install-page-offers-rufus'
    $rufusProc = Get-Process rufus -ErrorAction SilentlyContinue | Select-Object -First 1
    Check ($null -eq $rufusProc) 'rufus-not-launched'
    Check (Alive $proc $main) 'install-page-alive'
} finally {
    try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
}
if ($script:fails.Count -gt 0) { Write-Output ("FAILED: " + ($script:fails -join ', ')); exit 1 }
Write-Output 'done'
