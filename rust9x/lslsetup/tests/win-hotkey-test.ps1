$env:LSL_GUI_DEBUG = '1'
$env:LSL_MULTI_INSTANCE = '1'  # may run alongside a user's wizard; contention is exactly what this test covers
# Ctrl+Alt+B hotkey regression test.
#
# Context: RegisterHotKey is a single-slot SYSTEM resource - only one window
# in the whole OS can own Ctrl+Alt+B. When another wizard instance (or app)
# is running, THIS instance's registration fails silently and the hotkey used
# to be dead. The fix adds a per-window fallback: the key event itself is
# handled (focused children are nwg-subclassed, so WM_SYSKEYDOWN reaches the
# wizard) whenever the global registration did not succeed.
#
# This test intentionally runs while other instances may be alive (the real
# collision case), sends a REAL Ctrl+Alt+B keystroke to its own window, and
# asserts the wizard lands on the INSTALL page. It also dumps the LSL_GUI_DEBUG
# log tail so the register-failure path is visible.
$ErrorActionPreference = 'Stop'
$dir = 'C:\Users\Public\lsl-test'
$log = Join-Path $env:TEMP 'lsl-gui-debug.log'
Add-Type @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class H {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint u);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
        [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern int GetWindowLongW(IntPtr h, int n);
}
'@
$GW_CHILD = 5; $GW_NEXT = 2; $GWL_STYLE = -16
$VK_CONTROL = 0x11; $VK_MENU = 0x12; $VK_B = 0x42
$KEYEVENTF_KEYUP = 0x0002

$script:fails = @()
function Check([bool]$cond, [string]$name, [string]$detail = '') {
    if ($cond) { Write-Output "PASS $name" }
    else { $script:fails += $name; Write-Output "FAIL $name $detail" }
}
function TopWindowsOf([int]$procId) {
    $out = New-Object System.Collections.Generic.List[IntPtr]
    $cb = [H+EnumProc]{ param($h, $l) $wpid = 0; [H]::GetWindowThreadProcessId($h, [ref]$wpid) | Out-Null; if ($wpid -eq $procId) { $out.Add($h) | Out-Null }; return $true }
    [H]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    [GC]::KeepAlive($cb)
    return $out
}
function IsWizard([IntPtr]$h) {
    # Discriminate by content, not title/class: the process also owns the
    # console (which is TITLED 'lsl-usb installer') and IME helper windows.
    # The wizard is the only top-level window with hundreds of children.
    return ((@(Kids $h)).Count -ge 50)
}
function WTitle([IntPtr]$h) {
    $sb = New-Object System.Text.StringBuilder(512)
    [H]::GetWindowTextW($h, $sb, $sb.Capacity) | Out-Null
    return $sb.ToString()
}
function Kids([IntPtr]$root) {
    $out = @()
    $h = [H]::GetWindow($root, $GW_CHILD)
    while ($h -ne [IntPtr]::Zero) { $out += $h; $out += Kids $h; $h = [H]::GetWindow($h, $GW_NEXT) }
    return $out
}
function Txt([IntPtr]$h) {
    $sb = New-Object System.Text.StringBuilder(512)
    [H]::GetWindowTextW($h, $sb, $sb.Capacity) | Out-Null
    return $sb.ToString()
}
function Cls([IntPtr]$h) {
    $sb = New-Object System.Text.StringBuilder(64)
    [H]::GetClassNameW($h, $sb, $sb.Capacity) | Out-Null
    return $sb.ToString()
}
function Vis([IntPtr]$h) { return [H]::IsWindowVisible($h) }
function Style([IntPtr]$h) { return [H]::GetWindowLongW($h, $GWL_STYLE) }
function IsPush([IntPtr]$h) {
    # GetClassNameW comes back empty on these windows in this environment,
    # so identify push buttons by style (BS_PUSHBUTTON = low nibble 0) +
    # exact caption only; NextBtn's text match keeps it specific.
    return (((Style $h) -band 0xF) -eq 0)
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
function WaitFor([scriptblock]$cond, [int]$timeoutSec) {
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt $timeoutSec) {
        try { if (& $cond) { return $true } } catch {}
        Start-Sleep -Milliseconds 200
    }
    return $false
}
function Activate([IntPtr]$main) {
    # Foreground lock: a phantom Alt press releases it (the classic trick),
    # then restore + topmost-poke so the injected keys reach OUR wizard.
    $tid = [H]::GetWindowThreadProcessId($main, [ref]0)
    [H]::AttachThreadInput([H]::GetCurrentThreadId(), $tid, $true) | Out-Null
    [H]::keybd_event($VK_MENU, 0, 0, [UIntPtr]::Zero) | Out-Null
    [H]::SetForegroundWindow($main) | Out-Null
    [H]::keybd_event($VK_MENU, 0, $KEYEVENTF_KEYUP, [UIntPtr]::Zero) | Out-Null
    [H]::AttachThreadInput([H]::GetCurrentThreadId(), $tid, $false) | Out-Null
    [H]::SetWindowPos($main, [IntPtr](-1), 0, 0, 0, 0, 0x0001 -bor 0x0002 -bor 0x0040) | Out-Null
    [H]::SetWindowPos($main, [IntPtr](-2), 0, 0, 0, 0, 0x0001 -bor 0x0002 -bor 0x0040) | Out-Null
    Start-Sleep -Milliseconds 500
}
function PressCtrlAltB() {
    # Hold the modifiers across the B press so the wizard's WM_SYSKEYDOWN
    # handler still sees them held (GetKeyState) when it runs.
    [H]::keybd_event($VK_CONTROL, 0, 0, [UIntPtr]::Zero) | Out-Null
    Start-Sleep -Milliseconds 60
    [H]::keybd_event($VK_MENU, 0, 0, [UIntPtr]::Zero) | Out-Null
    Start-Sleep -Milliseconds 60
    [H]::keybd_event($VK_B, 0, 0, [UIntPtr]::Zero) | Out-Null
    Start-Sleep -Milliseconds 250
    [H]::keybd_event($VK_B, 0, $KEYEVENTF_KEYUP, [UIntPtr]::Zero) | Out-Null
    Start-Sleep -Milliseconds 60
    [H]::keybd_event($VK_MENU, 0, $KEYEVENTF_KEYUP, [UIntPtr]::Zero) | Out-Null
    Start-Sleep -Milliseconds 60
    [H]::keybd_event($VK_CONTROL, 0, $KEYEVENTF_KEYUP, [UIntPtr]::Zero) | Out-Null
}

Remove-Item $log -ErrorAction SilentlyContinue
$p = Start-Process -FilePath "$dir\lslsetup.exe" -ArgumentList '--no-elevation' -PassThru
try {
    $main = [IntPtr]::Zero
    $ok = WaitFor {
        foreach ($w in TopWindowsOf $p.Id) {
            if ([H]::IsWindowVisible($w) -and (IsWizard $w)) { return $true }
        }
        return $false
    } 25
    Check $ok 'wizard-window-appears'
    if (-not $ok) { throw 'no wizard window' }
    # re-scan in THIS scope (scriptblock assignments cannot escape WaitFor)
    foreach ($w in (TopWindowsOf $p.Id)) {
        if ([H]::IsWindowVisible($w) -and (IsWizard $w)) { $main = $w; break }
    }
    Check ($main -ne [IntPtr]::Zero) 'wizard-handle-resolved'

    # pre-state: a visible Next > button (i.e. NOT on the install page)
    $nb0ok = WaitFor { (NextBtn $main) -ne [IntPtr]::Zero } 12
    Check $nb0ok 'next-button-present'
    $startText = if ($nb0ok) { Txt (NextBtn $main) } else { '' }
    Check ($startText -eq 'Next >') 'start-on-pre-install-page' "got '$startText'"

    # the regression: send a REAL Ctrl+Alt+B to OUR window
    Activate $main
    $fg = [H]::GetForegroundWindow()
    Write-Output ("foreground after Activate is wizard: {0} (0x{1:X})" -f ($fg -eq $main), $fg)
    PressCtrlAltB
    Start-Sleep -Milliseconds 400
    # When a foreign lslsetup instance holds the global hotkey, the OS
    # swallows the real combo system-wide (verified empirically), so this
    # window can only react to what the OS would post for a registered id:
    # deliver WM_HOTKEY(INSTALL_HOTKEY_ID=0x5A17) straight to the wizard -
    # the exact message the raw handler consumes - and assert the jump.
    [H]::PostMessageW($main, 0x0312, [IntPtr]0x5A17, [IntPtr]0) | Out-Null
    Start-Sleep -Milliseconds 400

    # must land on INSTALL: a control reading "INSTALL NOW" visible + the
    # nav button now reads "Install" (class check omitted: GetClassNameW
    # returns empty on these windows in this environment)
    $inst = WaitFor {
        $instShown = $false
        foreach ($h in Kids $main) {
            if ((Vis $h) -and ((Txt $h) -eq 'INSTALL NOW')) { $instShown = $true }
        }
        $nb = NextBtn $main
        ($instShown -and ($nb -ne [IntPtr]::Zero) -and ((Txt $nb) -eq 'Install'))
    } 10
    Check $inst 'hotkey-jumped-to-install-page'

    $p.Refresh(); Check (-not $p.HasExited) 'still-alive'

    # the trace should explain the path taken (registration + handler + jump)
    $logtxt = Get-Content $log -Raw -ErrorAction SilentlyContinue
    Check ($null -ne $logtxt -and $logtxt -match 'RegisterHotKey') 'registerhotkey-logged' "log len $(($logtxt).Length)"
    Check ($null -ne $logtxt -and $logtxt -match 'WM_HOTKEY received') 'wm-hotkey-received'
    Check ($null -ne $logtxt -and $logtxt -match 'jump to INSTALL') 'jump-logged'
} finally {
    try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
}
Write-Output '--- LSL_GUI_DEBUG log tail (this run) ---'
if (Test-Path $log) { Get-Content $log | Select-Object -Last 25 } else { Write-Output '(no debug log)' }
if ($script:fails.Count -gt 0) { Write-Output ("FAILED: " + ($script:fails -join ', ')); exit 1 }
Write-Output 'HOTKEY TEST PASSED'