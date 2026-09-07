$env:LSL_GUI_DEBUG = '1'
# NOTE (resizable window): the installer window is now resizable and its
# initial size is clamped to the work area, so the client area is NOT always
# 880x760 anymore (on a 1024x768 VM it opens ~872x706). The fixed header
# strip is also dynamic: page frames start at y = 10 + wrapped
# SecureBoot-label height + 14 (~44-45 on wide windows, vs the old fixed 88).
# The hardcoded client coordinates below were tuned for the old fixed
# 880x760 layout and need re-tuning on the VM before they will pass again.
# New anchors (client coords): nav Next center (cw-60, ch-26), Back
# (cw-155, ch-26), Cancel (cw-250, ch-26); page frame top ~45, listview at
# (10+12, 45+30) etc.
$ErrorActionPreference = 'Stop'
$dir = 'C:\Users\Public\lsl-test'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class W {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint data, UIntPtr extra);
    public struct R { public int L, T, Rt, B; }
}
'@
[W]::SetProcessDPIAware() | Out-Null

$p = Start-Process -FilePath "$dir\lsl-install.exe" -ArgumentList '--no-elevation' -PassThru
Start-Sleep -Seconds 7

$proc = $null
for ($i = 0; $i -lt 10 -and -not $proc; $i++) {
    $proc = Get-Process lsl-install -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowTitle -like '*lsl-usb installer*' } | Select-Object -First 1
    if (-not $proc) { Start-Sleep -Seconds 1 }
}
if (-not $proc) { Write-Output 'NO-WINDOW-FOUND'; exit 1 }
$proc.Refresh()
[W]::SetWindowPos($proc.MainWindowHandle, [IntPtr](-1), 0, 0, 0, 0, 0x0001 -bor 0x0002) | Out-Null  # TOPMOST, NOSIZE|NOMOVE
[W]::SetForegroundWindow($proc.MainWindowHandle) | Out-Null
Start-Sleep -Milliseconds 800
Write-Output ('foreground is our window: ' + ([W]::GetForegroundWindow() -eq $proc.MainWindowHandle))

function Snap([string]$name) {
    $proc.Refresh()
    $r = New-Object 'W+R'
    [W]::GetWindowRect($proc.MainWindowHandle, [ref]$r) | Out-Null
    $bmp = New-Object System.Drawing.Bitmap(($r.Rt - $r.L), ($r.B - $r.T))
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size)
    $bmp.Save("$dir\$name.png")
    $g.Dispose(); $bmp.Dispose()
    Write-Output "snapped $name"
}

function ClickAt([int]$cx, [int]$cy) {
    $proc.Refresh()
    $r = New-Object 'W+R'
    [W]::GetWindowRect($proc.MainWindowHandle, [ref]$r) | Out-Null
    $x = $r.L + $cx
    $y = $r.T + $cy
    [W]::SetCursorPos($x, $y) | Out-Null
    Start-Sleep -Milliseconds 150
    [W]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
    [W]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 500
}

# listview header: frame at client (12,88), list at (10,30) in-frame -> client
# (22,118); header row ~20 px tall. Column 1 "Support" center ~ (22+185, 128).
ClickAt 218 177
Start-Sleep -Milliseconds 400
Snap 'sort-support-single'
ClickAt 218 177
Snap 'sort-support-desc'
# click "Device" heading (col 2, spans ~250-500 -> center 22+375=397)
ClickAt 408 177
Snap 'sort-device-asc'
Stop-Process -Id $p.Id -Force
Write-Output 'done'
