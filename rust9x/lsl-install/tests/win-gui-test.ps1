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
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out R r);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint data, UIntPtr extra);
    public struct R { public int L, T, Rt, B; }
}
'@
[W]::SetProcessDPIAware() | Out-Null

$p = Start-Process -FilePath "$dir\lsl-install.exe" -ArgumentList '--no-elevation' -PassThru
Start-Sleep -Seconds 6

$proc = $null
for ($i = 0; $i -lt 10 -and -not $proc; $i++) {
    $proc = Get-Process lsl-install -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowTitle -like '*lsl-usb installer*' } | Select-Object -First 1
    if (-not $proc) { Start-Sleep -Seconds 1 }
}
if (-not $proc) { Write-Output 'NO-WINDOW-FOUND'; exit 1 }
$proc.Refresh()
[W]::SetForegroundWindow($proc.MainWindowHandle) | Out-Null
Start-Sleep -Milliseconds 800

function Snap([string]$name) {
    $proc.Refresh()
    $r = New-Object 'W+R'
    [W]::GetWindowRect($proc.MainWindowHandle, [ref]$r) | Out-Null
    $w = $r.Rt - $r.L
    $h = $r.B - $r.T
    if ($w -le 0 -or $h -le 0) { Write-Output "SNAP-FAIL $name ($w x $h)"; return }
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size)
    $bmp.Save("$dir\$name.png")
    $g.Dispose(); $bmp.Dispose()
    Write-Output "snapped $name (${w}x${h} at $($r.L),$($r.T))"
}

function ClickNext {
    # The window is resizable and its initial size is clamped to the work
    # area (880x760 only when the screen is big enough), so derive the Next
    # button from the live geometry instead of hardcoded client coords:
    # Next occupies client (cw-108..cw-12, ch-40..ch-12) -> center
    # (cw-60, ch-26) relative to the CLIENT rect. Client origin inside the
    # outer rect = (border, caption + border), with
    # border = (outerW - clientW) / 2 and caption = outerH - clientH - 2*border.
    $proc.Refresh()
    $r = New-Object 'W+R'
    [W]::GetWindowRect($proc.MainWindowHandle, [ref]$r) | Out-Null
    $c = New-Object 'W+R'
    [W]::GetClientRect($proc.MainWindowHandle, [ref]$c) | Out-Null
    $cw = $c.Rt - $c.L
    $ch = $c.B - $c.T
    $border = [int](($r.Rt - $r.L - $cw) / 2)
    if ($border -lt 0) { $border = 0 }
    $caption = $r.B - $r.T - $ch - 2 * $border
    if ($caption -lt 0) { $caption = 0 }
    $x = $r.L + $border + ($cw - 60)
    $y = $r.T + $caption + $border + ($ch - 26)
    Write-Output "click next @ $x,$y (client ${cw}x${ch} border=$border caption=$caption)"
    [W]::SetCursorPos($x, $y) | Out-Null
    Start-Sleep -Milliseconds 150
    [W]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
    [W]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 600
}

Snap 'win-p0'
ClickNext
Snap 'win-p1'
ClickNext
Snap 'win-p2'
ClickNext
Snap 'win-p3'
Stop-Process -Id $p.Id -Force
Write-Output 'done'
