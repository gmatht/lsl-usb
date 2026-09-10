# Build and smoke-run lslsetup for Windows 95, from Windows (PowerShell).
#
#   .\win95.ps1              patch + build + run (debug build)
#   .\win95.ps1 -Release     optimized build (lto=fat, slower to compile)
#   .\win95.ps1 -Action build    just apply patches and build
#   .\win95.ps1 -Action run      verify PE + smoke-run the dist exe
#   .\win95.ps1 -Action patch    just apply the Win95 source patches
#   .\win95.ps1 -BuildStd        rebuild std from source with -Oz first
#                                (~75KB smaller; needs rust-src in the
#                                rust9x sysroot, see Ensure-RustSrc)
#
# Output: dist\lslsetup-win95.exe
#
# This is the Windows counterpart of win95.sh (which additionally uploads to
# a QEMU Win95 guest via guestfish and drives screenshots over QMP — Linux
# host tooling with no Windows equivalent here). The "run" step on Windows
# verifies the PE headers (i386, console subsystem, zeroed
# DllCharacteristics) and smoke-runs the exe with --help. The binary links
# the VC6 static CRT and targets Win95->11, so it runs on this host too.
#
# Toolchain: rust9x (i586-rust9x-windows-msvc), linked into rustup as `rust9x`.
# Vintage link toolset expected at C:\opt\msvc-toolchains (SDK v7.1A import
# libs, VC6 static CRT, stub libs) — fetched automatically on first run.
#
# The Win95 port applies these source patches (idempotent — re-running is
# safe; they are skipped once present):
#   1. Cargo.toml: [patch.crates-io] -> the ANSI-converted nwg vendored in
#      ../nwg-test/vendor/native-windows-gui (stock nwg imports Win98+ APIs
#      and calls *W stubs that silently no-op on Win95).
#   2. src/main.rs: #![no_main] + own main — std::rt init hangs inside
#      KERNEL32 on Win95; the VC6 CRT calls main directly instead.
#   3. src/main.rs: std::env::args() -> win95_args() — GetCommandLineW is a
#      no-op stub on Win95; read GetCommandLineA and split locally.
#   4. src/sys.rs: GetModuleHandleW/LoadLibraryW -> A variants (W stubs
#      return null on Win95, which would silently disable every dynamic
#      capability check).
# Plus the build itself: i586 target (Win95 never enables CR4.OSFXSR, so
# any SSE instruction faults) and a zeroed DllCharacteristics (rust9x emits
# 0x8140, which the Win95 loader rejects).

[CmdletBinding()]
param(
    [switch]$Release,
    [switch]$BuildStd,
    [ValidateSet('all', 'patch', 'build', 'run')]
    [string]$Action = 'all'
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

# rustup proxies (cargo +rust9x) live in $HOME/.cargo/bin — ensure on PATH.
$cargoBin = Join-Path $HOME '.cargo\bin'
if ((Test-Path $cargoBin) -and ($env:PATH -notlike "*$cargoBin*")) {
    $env:PATH = "$cargoBin;$env:PATH"
}

$Target = 'i586-rust9x-windows-msvc'
$ToolRoot = 'C:\opt\msvc-toolchains'

# ------------------------------------------------------------- patch phase
function Invoke-PatchFile {
    param([string]$Path, [string]$Old, [string]$New, [string]$Marker)
    $src = [IO.File]::ReadAllText($Path)
    if ($src.Contains($Marker)) { Write-Host "   ${Path}: already patched"; return }
    if (-not $src.Contains($Old)) { throw "ERROR: ${Path}: pattern not found:`n$Old" }
    [IO.File]::WriteAllText($Path, $src.Replace($Old, $New))
    Write-Host "   ${Path}: patched"
}

function Apply-Patches {
    # 1. Cargo.toml — use the Win95 (ANSI) vendored nwg
    Invoke-PatchFile 'Cargo.toml' '[profile.dev]' @"
# Win95-compatible vendored copy of native-windows-gui 1.0.13 (see
# ../nwg-test/vendor/native-windows-gui/README-WIN95.md).
[patch.crates-io]
native-windows-gui = { path = "../nwg-test/vendor/native-windows-gui" }

[profile.dev]
"@ 'nwg-test/vendor/native-windows-gui'

    # 2. main.rs — own main (skip std::rt: it hangs on Win95)
    Invoke-PatchFile 'src/main.rs' 'fn main() {' @"
/// Overrides the rustc ``lang_start`` shim (Win95: ``std::rt`` init hangs
/// inside KERNEL32; the VC6 CRT startup calls ``main`` directly instead).
/// (Patch-Win95 applied by win95.sh.)
#[unsafe(no_mangle)]
pub extern "C" fn main() -> i32 {
    run();
    0
}

fn run() {
"@ 'Patch-Win95 applied by win95.sh'

    # 3. main.rs — env::args() uses GetCommandLineW (stub on Win95)
    $src = [IO.File]::ReadAllText('src/main.rs')
    $oldArgs = 'let args: Vec<String> = std::env::args().skip(1).collect();'
    $newArgs = 'let args: Vec<String> = win95_args().into_iter().skip(1).collect();'
    if (($src.Contains('fn win95_args')) -and (-not $src.Contains($oldArgs))) {
        Write-Host '   src/main.rs: args already patched'
    } else {
        $src = $src.Replace($oldArgs, $newArgs)
        if (-not $src.Contains('fn win95_args')) {
            $src += @'

/// Win95-safe command line: `GetCommandLineW` is a no-op stub on Windows 95
/// (returns NULL), so `std::env::args()` cannot be used. Read the ANSI
/// command line instead. DBCS bytes decode lossily, which is fine for the
/// ASCII-only options this program takes.
#[cfg(windows)]
fn win95_args() -> Vec<String> {
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetCommandLineA() -> *const u8;
    }
    unsafe {
        let p = GetCommandLineA();
        if p.is_null() {
            return Vec::new();
        }
        let mut raw = Vec::new();
        let mut i = 0usize;
        while *p.add(i) != 0 {
            raw.push(*p.add(i));
            i += 1;
        }
        let mut out: Vec<String> = Vec::new();
        let mut cur = String::new();
        let mut in_quotes = false;
        for &b in &raw {
            match b {
                b'"' => in_quotes = !in_quotes,
                b' ' | b'\t' if !in_quotes => {
                    if !cur.is_empty() {
                        out.push(std::mem::take(&mut cur));
                    }
                }
                _ => cur.push(b as char),
            }
        }
        if !cur.is_empty() {
            out.push(cur);
        }
        out
    }
}
'@
        }
        [IO.File]::WriteAllText('src/main.rs', $src)
        Write-Host '   src/main.rs: args patched'
    }

    # 4. sys.rs — W-API stubs (GetModuleHandleW / LoadLibraryW) -> ANSI variants
    $sysMarker = 'GetModuleHandleA(a.as_ptr() as *const i8)'
    $sys = [IO.File]::ReadAllText('src/sys.rs')
    if ($sys.Contains($sysMarker)) {
        Write-Host '   src/sys.rs: already patched'
    } else {
        $sys = $sys.Replace(
            'use winapi::um::libloaderapi::{GetModuleHandleW, GetProcAddress, LoadLibraryW};',
            'use winapi::um::libloaderapi::{GetModuleHandleA, GetProcAddress, LoadLibraryA};')
        $sys = $sys.Replace(
            "        let w = wide(name);`n        let h = unsafe { LoadLibraryW(w.as_ptr()) };",
            "        // Win95: LoadLibraryW is a no-op stub; use the ANSI variant.`n        let mut a = Vec::with_capacity(name.len() + 1);`n        a.extend_from_slice(name.as_bytes());`n        a.push(0);`n        let h = unsafe { LoadLibraryA(a.as_ptr() as *const i8) };")
        $sys = $sys.Replace(
            "    let w = wide(module);`n    let h = unsafe { GetModuleHandleW(w.as_ptr()) };",
            "    // Win95: GetModuleHandleW is a no-op stub; use the ANSI variant.`n    let mut a = Vec::with_capacity(module.len() + 1);`n    a.extend_from_slice(module.as_bytes());`n    a.push(0);`n    let h = unsafe { GetModuleHandleA(a.as_ptr() as *const i8) };")
        if (-not $sys.Contains($sysMarker)) { throw 'ERROR: src/sys.rs: patch did not apply' }
        [IO.File]::WriteAllText('src/sys.rs', $sys)
        Write-Host '   src/sys.rs: patched'
    }
}

# ------------------------------------------------- vintage link toolset
function Ensure-Toolset {
    $sdkLib = Join-Path $ToolRoot 'sdk71a\Lib\kernel32.lib'
    $vc6Lib = Join-Path $ToolRoot 'vc6\VC98\Lib\libcmt.lib'
    if ((Test-Path $sdkLib) -and (Test-Path $vc6Lib)) {
        Write-Host '== toolset present'
        return
    }
    Write-Host '== fetching vintage link toolset (one-time)...'
    New-Item -ItemType Directory -Force -Path $ToolRoot | Out-Null
    Push-Location $ToolRoot
    try {
        if (-not (Test-Path (Join-Path $ToolRoot 'sdk71a'))) {
            git clone --depth 1 https://github.com/huangqinjin/Windows-SDK-v7.1A sdk71a
        }
        if (-not (Test-Path (Join-Path $ToolRoot 'vc6'))) {
            git clone --depth 1 https://github.com/itsmattkc/MSVC600 vc6
        }
    } finally { Pop-Location }
    # Stub libs for modern /DEFAULTLIB markers emitted by rust9x's std
    # (windows_link references synchronization.lib but resolves WaitOnAddress
    # dynamically at runtime - nothing is imported from it; cfgmgr32.lib is
    # absent from v7.1A and nothing imports it). Empty archives suffice.
    $stubs = Join-Path $ToolRoot 'stubs'
    New-Item -ItemType Directory -Force -Path $stubs | Out-Null
    foreach ($lib in @('cfgmgr32.lib', 'synchronization.lib')) {
        $p = Join-Path $stubs $lib
        if (-not (Test-Path $p)) {
            # 8-byte GNU ar signature = valid empty archive for lld-link
            [IO.File]::WriteAllBytes($p, [Text.Encoding]::ASCII.GetBytes("!<arch>`n"))
        }
    }
    if (-not (Test-Path $sdkLib)) { throw "SDK import libs missing after clone: $sdkLib" }
    if (-not (Test-Path $vc6Lib)) { throw "VC6 CRT missing after clone: $vc6Lib" }
    Write-Host '== toolset ready'
}

# ------------------------------------------------- rust-src for build-std
# -Zbuild-std needs the library sources inside the toolchain sysroot
# (rust9x tarballs don't bundle rust-src). Layout:
#   <sysroot>/lib/rustlib/src/rust/{Cargo.toml,Cargo.lock,library/...}
function Ensure-RustSrc {
    # Ask the rust9x toolchain itself for its sysroot (via rustup proxy).
    $sysroot = (& rustup run rust9x rustc --print sysroot).Trim()
    $marker = Join-Path $sysroot 'lib\rustlib\src\rust\library\std\src\lib.rs'
    if (Test-Path $marker) { Write-Host '== rust-src present'; return }
    throw @"
Missing rust-src for the rust9x toolchain (needed by -BuildStd).
Fetch it once with a sparse clone, e.g.:
  git init C:\opt\rust9x-src; cd C:\opt\rust9x-src
  git remote add origin https://github.com/rust9x/rust
  git config core.sparseCheckout true; echo 'library/*' > .git/info/sparse-checkout
  git fetch --depth 1 origin rust9x-1.99-beta-v2; git checkout FETCH_HEAD
  git clone https://github.com/rust9x/backtrace-rs.git library/backtrace_tmp
  (checkout the gitlink commit, move into library/backtrace)
Then mirror library/ (+ its Cargo.toml/Cargo.lock) to:
  $sysroot\lib\rustlib\src\rust\
"@
}

# ------------------------------------------------------------- build phase
function Invoke-Build {
    Ensure-Toolset
    Write-Host "== building ($Target)"
    $manifest = (Resolve-Path 'src\app_manifest.res').Path
    # Cargo *merges* rustflags from every matching config source, so a
    # --config override would ADD Windows paths alongside the Linux ones in
    # .cargo/config.toml (and the link would still fail on the Linux-only
    # app_manifest.res path). Instead, swap the host-specific paths in
    # config.toml for the duration of the build, then restore.
    $cfgPath = '.cargo/config.toml'
    $cfgOrig = [IO.File]::ReadAllText($cfgPath)
    $cfgWin = $cfgOrig.Replace('/opt/msvc-toolchains/sdk71a/Lib', 'C:\\opt\\msvc-toolchains\\sdk71a\\Lib')
    $cfgWin = $cfgWin.Replace('/opt/msvc-toolchains/vc6/VC98Lib', 'C:\\opt\\msvc-toolchains\\vc6\\VC98\\Lib')
    $cfgWin = $cfgWin.Replace('/root/src/lsl-usb/rust9x/lslsetup/src/app_manifest.res', $manifest.Replace('\', '\\'))
    $cfgWin = $cfgWin.Replace('/opt/msvc-toolchains/stubs', 'C:\\opt\\msvc-toolchains\\stubs')
    [IO.File]::WriteAllText($cfgPath, $cfgWin)
    try {
        $buildArgs = @('+rust9x', 'build', '--target', $Target)
        if (-not $BuildStd) { $buildArgs += '--offline' }
        if ($Release) { $buildArgs += '--release' }
        if ($BuildStd) {
            Ensure-RustSrc
            # Rebuild std itself with the active profile (-Oz): the
            # precompiled std ships at generic release opts. panic_abort
            # is required alongside panic="abort".
            $buildArgs += '-Zbuild-std=std,panic_abort'
        }
        & cargo @buildArgs
        if ($LASTEXITCODE -ne 0) { throw '== build FAILED' }
    } finally {
        [IO.File]::WriteAllText($cfgPath, $cfgOrig)
    }

    $profile = 'debug'
    if ($Release) { $profile = 'release' }
    $srcExe = "target\$Target\$profile\lslsetup.exe"
    if (-not (Test-Path $srcExe)) { throw "ERROR: build output missing: $srcExe" }
    New-Item -ItemType Directory -Force -Path dist | Out-Null
    $dstExe = 'dist\lslsetup-win95.exe'

    # Win95 loader: zero DllCharacteristics (rust9x emits 0x8140). NOTE the
    # layout: optional-header offset 68 = Subsystem (MUST keep), 70 =
    # DllCharacteristics. Zeroing 68 instead makes console apps fall back to
    # the DOS stub ("This program cannot be run in DOS mode").
    $d = [IO.File]::ReadAllBytes($srcExe)
    $pe = [BitConverter]::ToUInt32($d, 0x3c)
    $d[$pe + 24 + 70] = 0
    $d[$pe + 24 + 71] = 0
    [IO.File]::WriteAllBytes($dstExe, $d)

    $md5 = (Get-FileHash -Algorithm MD5 $dstExe).Hash
    $size = (Get-Item $dstExe).Length
    Write-Host "-- built $dstExe ($size bytes)"
    Write-Host "   md5 $md5"
}

# --------------------------------------------------------------- run phase
function Invoke-Run {
    $exe = 'dist\lslsetup-win95.exe'
    if (-not (Test-Path $exe)) { throw "ERROR: missing $exe - run with -Action build first" }
    Write-Host '== verifying PE headers'
    $d = [IO.File]::ReadAllBytes($exe)
    if (([BitConverter]::ToUInt16($d, 0) -ne 0x5a4d)) { throw 'not an MZ executable' }
    $pe = [BitConverter]::ToUInt32($d, 0x3c)
    if ([BitConverter]::ToUInt32($d, $pe) -ne 0x00004550) { throw 'bad PE signature' }
    $machine = [BitConverter]::ToUInt16($d, $pe + 4)
    $subsys = [BitConverter]::ToUInt16($d, $pe + 24 + 68)
    $dllChars = [BitConverter]::ToUInt16($d, $pe + 24 + 70)
    $osMaj = [BitConverter]::ToUInt16($d, $pe + 24 + 40)
    $subMaj = [BitConverter]::ToUInt16($d, $pe + 24 + 48)
    Write-Host ("   Machine            : 0x{0:X} (0x14C = i386)" -f $machine)
    Write-Host ("   Subsystem          : $subsys (3 = console)")
    Write-Host ("   DllCharacteristics : 0x{0:X} (must be 0 for Win95)" -f $dllChars)
    Write-Host ("   OS version         : $osMaj.x | Subsystem version: $subMaj.x")
    if ($machine -ne 0x14c) { throw 'ERROR: not an i386 binary' }
    if ($subsys -ne 3) { throw 'ERROR: not a console-subsystem binary' }
    if ($dllChars -ne 0) { throw 'ERROR: DllCharacteristics is not zeroed - Win95 will reject this binary' }

    Write-Host '== smoke-run: lslsetup-win95.exe --help'
    $out = & $exe --help 2>&1 | Out-String
    $lines = ($out -split "`r?`n" | Where-Object { $_ -ne '' } | Select-Object -First 12)
    $lines | ForEach-Object { Write-Host "   $_" }
    Write-Host 'OK: Win95 exe built, PE verified, and --help runs on this host.'
}

switch ($Action) {
    'patch' { Apply-Patches }
    'build' { Apply-Patches; Invoke-Build }
    'run' { Invoke-Run }
    default { Apply-Patches; Invoke-Build; Invoke-Run }
}
