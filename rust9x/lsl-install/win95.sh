#!/usr/bin/env bash
# Build and run lsl-install on Windows 95 (QEMU).
#
#   ./win95.sh              patch + build + upload + run (debug build)
#   ./win95.sh --release    optimized build (lto=fat, slower to compile)
#   ./win95.sh build        just apply patches and build
#   ./win95.sh upload       stop VM, upload dist exe, md5-verify
#   ./win95.sh run          boot VM, launch, screenshot, clean shutdown
#   ./win95.sh --no-shutdown  leave the VM running when done
#
# Output: dist/lsl-install-win95.exe   (host)  →  C:\LSLSETUP.EXE  (guest)
# Screenshots: dist/lsl-boot.png, dist/lsl-window.png
#
# The Win95 port applies these source patches (idempotent — re-running is
# safe; they are skipped once present):
#   1. Cargo.toml: [patch.crates-io] → the ANSI-converted nwg vendored in
#      ../nwg-test/vendor/native-windows-gui (stock nwg imports Win98+ APIs
#      and calls *W stubs that silently no-op on Win95).
#   2. src/main.rs: #![no_main] + own main — std::rt init hangs inside
#      KERNEL32 on Win95; the VC6 CRT calls main directly instead.
#   3. src/main.rs: std::env::args() → win95_args() — GetCommandLineW is a
#      no-op stub on Win95; read GetCommandLineA and split locally.
#   4. src/sys.rs: GetModuleHandleW/LoadLibraryW → A variants (W stubs
#      return null on Win95, which would silently disable every dynamic
#      capability check).
# Plus the build itself: i586 target (Win95 never enables CR4.OSFXSR, so
# any SSE instruction faults) and a zeroed DllCharacteristics (rust9x emits
# 0x8140, which the Win95 loader rejects).
set -euo pipefail
cd "$(dirname "$0")"

export LIBGUESTFS_BACKEND=direct
DISK=${WIN95_DISK:-/root/vm/win95-flat.qcow2}
SOURCE=${WIN95_SOURCE:-/root/vm/Win95.vmdk}
QMP_PORT=${QMP_PORT:-4445}
VNC_DISPLAY=:5
BUILD_ARGS=()
ACTION=all
NO_SHUTDOWN=0
for a in "$@"; do
  case "$a" in
    --release) BUILD_ARGS+=(--release) ;;
    --no-shutdown) NO_SHUTDOWN=1 ;;
    build|upload|run|patch|all) ACTION=$a ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

QMP_PY=../nwg-test/scripts/qmp.py

# ------------------------------------------------------------- patch phase
apply_patches() {
  python3 - <<'EOF'
import sys

def patch(path, subs, markers):
    src = open(path).read()
    if any(m in src for m in markers):
        print(f"   {path}: already patched")
        return
    for old, new in subs:
        if old not in src:
            print(f"ERROR: {path}: pattern not found:\n{old}", file=sys.stderr)
            sys.exit(1)
        src = src.replace(old, new)
    open(path, "w").write(src)
    print(f"   {path}: patched")

# 1. Cargo.toml — use the Win95 (ANSI) vendored nwg
patch("Cargo.toml", [(
    "[profile.dev]",
    "# Win95-compatible vendored copy of native-windows-gui 1.0.13 (see\n"
    "# ../nwg-test/vendor/native-windows-gui/README-WIN95.md).\n"
    "[patch.crates-io]\n"
    'native-windows-gui = { path = "../nwg-test/vendor/native-windows-gui" }\n\n'
    "[profile.dev]",
)], ["nwg-test/vendor/native-windows-gui"])

# 2. main.rs — no_main + own main (skip std::rt: it hangs on Win95)
patch("src/main.rs", [(
    "fn main() {",
    "/// Overrides the rustc `lang_start` shim (Win95: `std::rt` init hangs\n"
    "/// inside KERNEL32; the VC6 CRT startup calls `main` directly instead).\n"
    "/// (Patch-Win95 applied by win95.sh.)\n"
    "#[unsafe(no_mangle)]\n"
    'pub extern "C" fn main() -> i32 {\n'
    "    run();\n"
    "    0\n"
    "}\n"
    "\n"
    "fn run() {",
)], ["Patch-Win95 applied by win95.sh"])
patch("src/main.rs", [("mod boot;", "#![no_main]\n\nmod boot;")], ["#![no_main]"])

# 3. main.rs — env::args() uses GetCommandLineW (stub on Win95)
src = open("src/main.rs").read()
old = "let args: Vec<String> = std::env::args().skip(1).collect();"
new = "let args: Vec<String> = win95_args().into_iter().skip(1).collect();"
n = src.count(old)
if n == 0 and "fn win95_args" in src:
    print("   src/main.rs: args already patched")
else:
    src = src.replace(old, new)
    if "fn win95_args" not in src:
        src += r'''
// ----------------------------------------------------------------- Win95 ---
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
'''
    open("src/main.rs", "w").write(src)
    print(f"   src/main.rs: args patched ({n} site(s))")

# 4. sys.rs — W-API stubs (GetModuleHandleW / LoadLibraryW) → ANSI variants
patch("src/sys.rs", [
    ("use winapi::um::libloaderapi::{GetModuleHandleW, GetProcAddress, LoadLibraryW};",
     "use winapi::um::libloaderapi::{GetModuleHandleA, GetProcAddress, LoadLibraryA};"),
    ("""        let w = wide(name);
        let h = unsafe { LoadLibraryW(w.as_ptr()) };""",
     """        // Win95: LoadLibraryW is a no-op stub; use the ANSI variant.
        let mut a = Vec::with_capacity(name.len() + 1);
        a.extend_from_slice(name.as_bytes());
        a.push(0);
        let h = unsafe { LoadLibraryA(a.as_ptr() as *const i8) };"""),
    ("""    let w = wide(module);
    let h = unsafe { GetModuleHandleW(w.as_ptr()) };""",
     """    // Win95: GetModuleHandleW is a no-op stub; use the ANSI variant.
    let mut a = Vec::with_capacity(module.len() + 1);
    a.extend_from_slice(module.as_bytes());
    a.push(0);
    let h = unsafe { GetModuleHandleA(a.as_ptr() as *const i8) };"""),
], ["GetModuleHandleA(a.as_ptr() as *const i8)"])
EOF
}

# ------------------------------------------------------------- build phase
do_build() {
  echo "== building (i586-rust9x-windows-msvc)"
  out=$(cargo +rust9x build --offline --target i586-rust9x-windows-msvc "${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}" 2>&1)
  if echo "$out" | grep -qE '^error'; then
    echo "$out" | grep -E "^error" -A6 | head -40
    echo "== build FAILED"
    exit 1
  fi
  SRC=target/i586-rust9x-windows-msvc/debug/lsl-install.exe
  for a in "${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}"; do
    [ "$a" = "--release" ] && SRC=target/i586-rust9x-windows-msvc/release/lsl-install.exe
  done
  [ -f "$SRC" ] || { echo "ERROR: build output missing: $SRC" >&2; exit 1; }
  mkdir -p dist
  python3 - "$SRC" dist/lsl-install-win95.exe <<'PYEOF'
import struct, sys
# Win95 loader: zero DllCharacteristics (rust9x emits 0x8140). NOTE the
# layout: optional-header offset 68 = Subsystem (MUST keep), 70 =
# DllCharacteristics. Zeroing 68 instead makes console apps fall back to
# the DOS stub ("This program cannot be run in DOS mode").
d = bytearray(open(sys.argv[1], "rb").read())
pe = struct.unpack("<I", d[0x3c:0x40])[0]
struct.pack_into("<H", d, pe + 24 + 70, 0)
open(sys.argv[2], "wb").write(d)
PYEOF
  echo "-- built dist/lsl-install-win95.exe ($(stat -c%s dist/lsl-install-win95.exe) bytes)"
  md5sum dist/lsl-install-win95.exe
}

# ------------------------------------------------------------ upload phase
stop_vm() {
  pids=$(ps aux | awk '/qemu-system-i386/ && !/awk/ {print $2}')
  if [ -n "$pids" ]; then
    kill $pids 2>/dev/null || true
    sleep 3
    kill -9 $pids 2>/dev/null || true
    sleep 1
  fi
}

do_upload() {
  echo "== uploading to $DISK"
  stop_vm
  [ -f "$DISK" ] || { echo "   scratch disk missing; converting from $SOURCE"; qemu-img convert -O qcow2 "$SOURCE" "$DISK"; }
  guestfish -a "$DISK" -m /dev/sda1 upload dist/lsl-install-win95.exe /LSLSETUP.EXE
  guestfish --ro -a "$DISK" -m /dev/sda1 download /LSLSETUP.EXE /tmp/_lsl_verify.exe
  a=$(md5sum /tmp/_lsl_verify.exe | cut -d' ' -f1)
  b=$(md5sum dist/lsl-install-win95.exe | cut -d' ' -f1)
  [ "$a" = "$b" ] || { echo "ERROR: upload md5 mismatch ($a != $b)" >&2; exit 1; }
  rm -f /tmp/_lsl_verify.exe
  echo "   upload verified (md5 $a)"
}

# --------------------------------------------------------------- run phase
do_run() {
  echo "== booting VM"
  ACCEL=kvm; [ -w /dev/kvm ] || ACCEL=tcg
  setsid qemu-system-i386 -machine pc -cpu pentium -m 256 -accel "$ACCEL" \
    -drive file="$DISK",if=ide,index=0,media=disk -vga cirrus \
    -display none -vnc "$VNC_DISPLAY" \
    -qmp tcp:127.0.0.1:$QMP_PORT,server,nowait -rtc base=localtime -net none \
    > /tmp/qemu-win95.log 2>&1 &
  echo $! > /tmp/qemu-win95.pid
  sleep 5
  kill -0 "$(cat /tmp/qemu-win95.pid)" 2>/dev/null || { echo "ERROR: QEMU died; see /tmp/qemu-win95.log" >&2; exit 1; }

  python3 "$QMP_PY" wait-desktop --min 140 --timeout 720 --verbose || \
    echo "   WARNING: desktop detection timed out; continuing anyway"
  python3 "$QMP_PY" key esc esc
  sleep 10
  python3 "$QMP_PY" shot dist/lsl-boot.png

  echo "== launching C:\\LSLSETUP.EXE (vnc $VNC_DISPLAY / QMP $QMP_PORT)"
  python3 "$QMP_PY" run-dialog 'c:\lslsetup.exe'
  if python3 "$QMP_PY" wait-change dist/lsl-boot.png --timeout 90; then
    sleep 8
    python3 "$QMP_PY" shot dist/lsl-window.png
    echo "OK: lsl-install is running under Windows 95 — see dist/lsl-window.png"
  else
    python3 "$QMP_PY" shot dist/lsl-window.png
    echo "WARNING: screen did not change after launch; eyeball dist/lsl-window.png"
  fi
  echo "watch live:  vncviewer localhost:5905    (VNC display :5)"

  if [ "$NO_SHUTDOWN" = 0 ]; then
    echo "== clean shutdown (Start > Shut Down)"
    python3 "$QMP_PY" combo ctrl+esc; sleep 4
    python3 "$QMP_PY" key u; sleep 4
    python3 "$QMP_PY" key ret
    if python3 "$QMP_PY" wait-halt; then
      pids=$(ps aux | awk '/qemu-system-i386/ && !/awk/ {print $2}')
      [ -n "$pids" ] && kill $pids 2>/dev/null || true
      echo "   guest halted (next boot will be normal, not Safe Mode)"
    else
      echo "   WARNING: guest did not halt; leaving QEMU running"
    fi
  fi
}

case "$ACTION" in
  patch)  apply_patches ;;
  build)  apply_patches; do_build ;;
  upload) do_upload ;;
  run)    do_run ;;
  all)    apply_patches; do_build; do_upload; do_run ;;
esac
