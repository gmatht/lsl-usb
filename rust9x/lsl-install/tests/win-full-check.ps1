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
$dir = 'C:\Users\Public\lsl-test'
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class W {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    public struct R { public int L, T, Rt, B; }
}
'@
[W]::SetProcessDPIAware() | Out-Null
$p = Start-Process -FilePath "$dir\lsl-install.exe" -ArgumentList '--no-elevation' -PassThru
Start-Sleep -Seconds 7
$proc = Get-Process lsl-install -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like '*lsl-usb installer*' } | Select-Object -First 1
if (-not $proc) { Write-Output 'NO-WINDOW'; exit 1 }
$proc.Refresh()
[W]::SetWindowPos($proc.MainWindowHandle, [IntPtr](-1), 0, 0, 0, 0, 3) | Out-Null
Start-Sleep -Seconds 1
function Snap([string]$name) {
    $proc.Refresh()
    $r = New-Object 'W+R'
    [W]::GetWindowRect($proc.MainWindowHandle, [ref]$r) | Out-Null
    if (($r.Rt - $r.L) -le 0) { Write-Output "snap-skip $name"; return }
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
    [W]::SetForegroundWindow($proc.MainWindowHandle) | Out-Null
    Start-Sleep -Milliseconds 150
    [W]::SetCursorPos($r.L + $cx, $r.T + $cy) | Out-Null
    Start-Sleep -Milliseconds 120
    [W]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
    [W]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 400
}
# 1) click the www globe of row 1 (list x 710-790 -> client 782; row 1 y ~160)
ClickAt 833 210
Start-Sleep -Seconds 2
Snap 'chk-www'
# 2) Next -> page 1
ClickAt 849 777
Snap 'chk-p1-top'
# 3) scroll down twice (scrollbar arrows at client (847, ~670))
ClickAt 858 700
ClickAt 858 700
ClickAt 858 700
Snap 'chk-p1-scrolled'
# 4) to page 3
ClickAt 849 777
ClickAt 849 777
ClickAt 849 777
Snap 'chk-p3'
Stop-Process -Id $p.Id -Force
Write-Output 'done'
