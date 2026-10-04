$env:LSL_GUI_DEBUG = '1'
$env:LSL_MULTI_INSTANCE = '1'  # the wizard is single-instance; tests must bypass
# Regression test for the PERSISTENCE page's target picker.
#
# Clicking a target radio used to kill the installer. The unit test
# the_readout_survives_a_reentrant_dispatch covers the borrow itself, but only
# a real click exercises the actual path: BM_CLICK on the radio -> the click
# handler records the letter -> the deferred rebuild at the top of the next
# dispatch -> build_persist_page creates controls -> control creation re-enters
# the handler synchronously (nwg subclasses every child) -> sync_persist_readout
# borrows a page that is already mutably borrowed.
#
# The crash is only observable here. Note WHY it is hard to read: both cargo
# profiles set panic = "abort", so a Rust panic exits as 0xC0000409 - the same
# code a stack buffer overrun produces. A previous fix mistook one for the other
# and "fixed" a non-bug. So this test asserts the process SURVIVES the click and
# then separately asserts the pane re-sized against the picked stick; it never
# infers anything from the exit code.
#
# Also asserts the sizing, because "did not crash" is not the requirement: with a
# 236 GB system disk and a 116 GB stick the pane rendered
# "235 GB FAT / 1 GB persistence" for the 116 GB stick the user had just picked.
#
# Pass an explicit exe path as $args[0]; defaults to the staged test copy.
$ErrorActionPreference = 'Stop'
$dir = 'C:\Users\Public\lsl-test'
$exe = if ($args.Count -ge 1) { $args[0] } else { "$dir\lslsetup.exe" }
if (-not (Test-Path $exe)) { Write-Output "FAIL no-exe $exe"; exit 1 }

Add-Type @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class P {
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    // ANSI, NOT W: these are ANSI windows (the vendored nwg is the Win95
    // patch), so GetWindowTextW returns one garbage char per caption.
    [DllImport("user32.dll", EntryPoint = "GetWindowTextA")] public static extern int GetWindowTextA(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern int GetWindowLongW(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    // EnumChildWindows recurses, so this is every descendant in one call.
    public static IntPtr[] Kids(IntPtr parent) {
        var list = new List<IntPtr>();
        EnumProc cb = null;
        cb = delegate(IntPtr h, IntPtr l) { list.Add(h); return true; };
        EnumChildWindows(parent, cb, IntPtr.Zero);
        return list.ToArray();
    }
}
'@
$BM_CLICK = 0x00F5
$BM_GETCHECK = 0x00F0

$fails = @()
function Check([bool]$cond, [string]$name, [string]$detail = '') {
    if ($cond) { Write-Output "PASS $name" }
    else { $script:fails += $name; Write-Output "FAIL $name $detail" }
}
function Txt([IntPtr]$h) {
    $sb = New-Object System.Text.StringBuilder 512
    [P]::GetWindowTextA($h, $sb, $sb.Capacity) | Out-Null
    return $sb.ToString()
}
function Style([IntPtr]$h) { return [P]::GetWindowLongW($h, -16) }
function Vis([IntPtr]$h) { return [P]::IsWindowVisible($h) }
function IsRadio([IntPtr]$h) {
    $t = (Style $h) -band 0xF
    return ($t -eq 4) -or ($t -eq 9)
}
function IsChecked([IntPtr]$h) {
    return [P]::SendMessageW($h, $BM_GETCHECK, [IntPtr]::Zero, [IntPtr]::Zero).ToInt32() -eq 1
}
function WaitFor([scriptblock]$cond, [int]$timeoutSec) {
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt $timeoutSec) {
        try { if (& $cond) { return $true } } catch {}
        Start-Sleep -Milliseconds 250
    }
    return $false
}
# The visible caption containing $pat (regex), or ''.
function FindLabel([IntPtr]$main, [string]$pat) {
    foreach ($h in [P]::Kids($main)) {
        if (-not (Vis $h)) { continue }
        $t = Txt $h
        if ($t -match $pat) { return $t }
    }
    return ''
}

# stderr is redirected so a panic message is captured rather than lost: with
# panic = "abort" the process dies before anything can report it.
$errFile = Join-Path $env:TEMP 'lsl-persist-pane.err'
Remove-Item $errFile -ErrorAction SilentlyContinue
$p = Start-Process -FilePath $exe -ArgumentList '--no-elevation' -PassThru -RedirectStandardError $errFile
try {
    # MainWindowHandle can be the console, so wait for a window carrying the
    # wizard's full control set rather than any visible window.
    $script:main = [IntPtr]::Zero
    $ok = WaitFor {
        $p.Refresh()
        if ($p.HasExited) { return $false }
        $h = [IntPtr]$p.MainWindowHandle
        if ($h -ne [IntPtr]::Zero -and ([P]::Kids($h)).Count -ge 50) { $script:main = $h; return $true }
        return $false
    } 40
    $main = $script:main
    Check $ok 'wizard-appears' "main=$main"
    if (-not $ok) { throw 'no wizard window' }

    # Walk to the PERSISTENCE page (4 Next presses from page 0).
    for ($i = 0; $i -lt 4; $i++) {
        $nb = [IntPtr]::Zero
        foreach ($h in [P]::Kids($main)) {
            if ((Vis $h) -and (((Style $h) -band 0xF) -eq 0)) {
                $t = Txt $h
                if ($t -eq 'Next >' -or $t -eq 'Install') { $nb = $h; break }
            }
        }
        if ($nb -eq [IntPtr]::Zero) { Check $false "next-at-page$i"; break }
        [P]::SendMessageW($nb, $BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        WaitFor { -not (Vis $nb -and (Txt $nb) -eq 'Next >') -or $true } 2 | Out-Null
        Start-Sleep -Milliseconds 700
    }

    # The target radio: a stick row, caption "<letter>:  <label>  <fs>  (<n> GB)".
    $target = [IntPtr]::Zero
    foreach ($h in [P]::Kids($main)) {
        if ((IsRadio $h) -and (Vis $h) -and (Txt $h) -match '^[A-Z]:\s') { $target = $h; break }
    }
    Check ($target -ne [IntPtr]::Zero) 'persistence-page-shows-a-target'
    if ($target -eq [IntPtr]::Zero) { throw 'no target radio to click' }
    $targetCaption = Txt $target
    # The stick's own advertised size, from its caption.
    $stickGb = 0.0
    if ($targetCaption -match '\(([0-9.]+) GB\)') { $stickGb = [double]$Matches[1] }

    # ---- the click that used to abort the process ----
    [P]::SendMessageW($target, $BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    Start-Sleep -Seconds 3
    $p.Refresh()
    Check (-not $p.HasExited) 'survives-target-click' "exited with $(if ($p.HasExited) { '0x{0:X8}' -f $p.ExitCode })"
    Check ([P]::IsWindow($main)) 'window-still-valid'
    if ($p.HasExited) {
        Write-Output '--- stderr ---'
        if (Test-Path $errFile) { Get-Content $errFile | Select-Object -First 20 | ForEach-Object { Write-Output "  $_" } }
        throw 'installer died on a target click'
    }

    # The pane must now describe the PICKED stick. The rebuild replaces every
    # control, so re-find the radio rather than reusing $target's HWND.
    $after = [IntPtr]::Zero
    foreach ($h in [P]::Kids($main)) {
        if ((IsRadio $h) -and (Vis $h) -and (Txt $h) -match '^[A-Z]:\s') { $after = $h; break }
    }
    Check ($after -ne [IntPtr]::Zero) 'target-radio-survives-rebuild'
    Check ((IsChecked $after)) 'target-still-checked-after-rebuild'

    # Sizing: the split line must divide the picked stick, not the system disk.
    # This is the regression that outlived the crash fix - the pane fell back to
    # "the largest candidate", i.e. C:, while claiming to size against D:.
    if ($stickGb -gt 0) {
        WaitFor { (FindLabel $main 'GB FAT') -ne '' } 10 | Out-Null
        $split = FindLabel $main 'GB FAT'
        Write-Output "  split line: '$split' (picked stick: $stickGb GB)"
        Check ($split -ne '') 'shows-a-split-line'
        if ($split -match '([0-9]+) GB FAT') {
            $fatGb = [double]$Matches[1]
            # The FAT side is the stick minus persistence, so it must be at most
            # the stick's own size (allowing a little slack for the image) and
            # clearly below a much larger system disk.
            Check ($fatGb -le ($stickGb + 1)) 'split-describes-the-picked-stick' "got $fatGb GB FAT for a $stickGb GB stick"
        }
    }
} catch {
    Write-Output "ERROR $($_.Exception.Message)"
    $script:fails += 'exception'
} finally {
    try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
}
if ($fails.Count -gt 0) { Write-Output ("FAILED: " + ($fails -join ', ')); exit 1 }
Write-Output 'done'