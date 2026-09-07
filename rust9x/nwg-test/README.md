# nwg-test

Tiny GUI test app for [rust9x](https://github.com/rust9x) using
[native-windows-gui](https://crates.io/crates/native-windows-gui) (nwg).

A 300x150 window with a label, a "Say hello" button (updates the label with a
click counter) and an "About" button (modal message box). Win9x-era APIs only.

## Toolchain (installed on this machine)

- rust9x 1.99.0-dev at `/opt/rust9x`, linked into rustup as toolchain `rust9x`
  (from [rust9x-1.99-beta-v2](https://github.com/rust9x/rust/releases) Linux
  release; bundles std for `i586/i686/x86_64-rust9x-windows-msvc`).

## Libraries: vintage toolset for rust9x targets only

Per the [rust9x docs](https://github.com/rust9x/docs), the Platform SDK import
libs can be any version, but the **MSVC runtime decides OS support**. Instead
of VS2022 (Win7+), the rust9x targets link the vintage toolset:

- `/opt/msvc-toolchains/sdk71a/Lib` — Windows SDK **v7.1A** import libraries
  (incl. `unicows.lib`, `ws2_32.lib`). Mirror:
  [huangqinjin/Windows-SDK-v7.1A](https://github.com/huangqinjin/Windows-SDK-v7.1A).
  Lowercase symlinks were added for every `*.Lib` because `rust-lld` looks up
  e.g. `kernel32.lib` verbatim on a case-sensitive filesystem.
  `cfgmgr32.lib` (not in v7.1A) is an empty stub archive — nothing imports it.
- `/opt/msvc-toolchains/vc6/VC98Lib` — **VC6 (MSVC 6.0) static CRT**
  (`libcmt.lib`). Mirror: [itsmattkc/MSVC600](https://github.com/itsmattkc/MSVC600).
  Supports Win95+/NT3.5+; no unwinding (`panic = "abort"` in Cargo.toml) and
  no SAFESEH (`/SAFESEH:NO` is passed).

All of this is scoped in `.cargo/config.toml` to
`[target.'cfg(all(target_family = "rust9x", target_env = "msvc"))']`, so
regular msvc targets are unaffected (modern VS2022/Win10-SDK LIBPATHs are
listed commented-out there).

### C99 float shims

On MSVC targets `compiler_builtins` delegates float routines to the CRT, and
the VC6 CRT predates C99. `src/float_shim.rs` provides `round`/`roundf`
(needed by nwg's `stretch` layout engine) implemented without calling any
libm function that would itself lower to a CRT float call.

## Building

```
./build.sh                # → dist/nwg-test-win95.exe
./build.sh --release
```

Runs the i586 rust9x build, zeroes `DllCharacteristics` in the PE (Win95
rejects rust9x's `0x8140`), and drops a ready-to-run exe in `dist/`.
Equivalent to:

```
cargo +rust9x build --offline --target i586-rust9x-windows-msvc
```

## Running on Windows 95 (QEMU)

```
./test.sh                # build + upload + boot Win95 + launch + screenshot
./test.sh --show         # same, but with a visible QEMU window (X display)
./test.sh --release      # optimized build
./test.sh --no-shutdown  # leave the VM running afterwards
```

One command does the whole cycle: builds, uploads `dist/nwg-test-win95.exe`
to `C:\NWGTEST.EXE` on the scratch disk (md5-verified; also removes the
stale copy in the StartUp folder), boots the VM, waits for the desktop
(Start-button/clock detection — it also Esc-dismisses the "Display
Properties" dialog that Safe-Mode boots show), launches the app via
Start > Run, waits for the window and saves:

- `dist/qemu-boot.png` — desktop before launch
- `dist/qemu-window.png` — the running app

At the end the guest is shut down via Start > Shut Down (clears the
dirty-shutdown flag so the next boot is normal, not Safe Mode).

While the VM runs you can watch it with `vncviewer localhost:5905`
(headless default) or look at the QEMU window (`--show`). QMP is on port
4445; `scripts/qmp.py` drives it (`shot`, `key`, `combo`, `type`,
`run-dialog`, `wait-desktop`, `wait-change`, `wait-halt`).

Env overrides: `WIN95_DISK` (default `/root/vm/win95-flat.qcow2`, recreated
from `WIN95_SOURCE` = `/root/vm/Win95.vmdk` if missing), `QMP_PORT` (4445).
Keep the VM images under `/root/vm` — /tmp is volatile on this host.

The disk upload needs QEMU stopped — the script stops it for you; run
`guestfish --ro` commands for read-only peeking while it runs.

### Manual cycle (what test.sh automates)

```bash
./build.sh
qemu-img convert -O qcow2 /root/vm/Win95.vmdk /root/vm/win95-flat.qcow2   # if needed
# stop QEMU, then:
guestfish -a /root/vm/win95-flat.qcow2 -m /dev/sda1 upload dist/nwg-test-win95.exe /NWGTEST.EXE
qemu-system-i386 -machine pc -cpu pentium -m 256 -accel kvm \
  -drive file=/root/vm/win95-flat.qcow2,if=ide,index=0,media=disk -vga cirrus \
  -display none -vnc :5 -qmp tcp:127.0.0.1:4445,server,nowait -rtc base=localtime -net none
# wait for the desktop (~3-5 min), then via QMP: Start>Run → c:\nwgtest.exe
```

## Running on Windows 95 (QEMU)

Build with the **i586** target (`i586-rust9x-windows-msvc`): Windows 95
never enables CR4.OSFXSR, so any SSE instruction faults regardless of the
virtual CPU model. Two more Win95 requirements are handled in source/vendor:

- `#![no_main]` + own `main` in `src/main.rs`: the normal `std::rt`
  initialization hangs inside KERNEL32 on Win95 (DBCS conversion loop);
  the CRT startup calls `main` directly, skipping it entirely.
- Zeroed `DllCharacteristics`: rust9x emits `0x8140` which the Win95 loader
  dislikes. Patch bytes at PE optional-header offset **70** to 0. NOTE the
  layout: optional-header offset 68 = **Subsystem** (2=GUI, 3=console — must
  keep!), 70 = DllCharacteristics. Zeroing 68 instead corrupts the
  subsystem: a GUI app happens to still load, a console app falls back to
  the DOS stub (`"This program cannot be run in DOS mode"`):
  ```python
  import struct
  d = bytearray(open('target/i586-rust9x-windows-msvc/debug/nwg-test.exe','rb').read())
  pe = struct.unpack('<I', d[0x3c:0x40])[0]
  struct.pack_into('<H', d, pe+24+70, 0)   # DllCharacteristics = 0
  ```
- The vendored `native-windows-gui` is patched for Win95; see
  `vendor/native-windows-gui/README-WIN95.md` (missing Win98+ APIs and the
  W→A conversion — Win95 exports many `*W` stubs that silently no-op).

Tested end-to-end in QEMU (`-machine pc -cpu pentium -m 256 -vga cirrus`):
window appears, buttons dispatch events (label counter increments, modal
About box shows), closing the window exits the process cleanly.
Screenshots in `screenshots/`.

### Driving the GUI from the host (QMP recipes)

`scripts/qmp.py` covers keyboard/startup (`shot`, `key`, `combo`, `type`,
`run-dialog`, `wait-desktop`, `wait-halt`). Mouse input needs HMP via
`human-monitor-command` (QMP `input-send-event` only supports *relative*
PS/2 mouse; `abs` events fail with "Input handler not found"):

```python
import sys, time
sys.path.insert(0, 'scripts')
from qmp import Qmp, screendump_png
q = Qmp()
def hmp(c): return q.cmd("human-monitor-command", {"command-line": c})
hmp("mouse_move -3000 -3000")   # clamp to top-left corner, then wait ~2.5s
# ... then calibrated relative moves (≈1.4 px/unit on Win95, nonlinear
# acceleration). SCREENSHOT after every step: TCG event-queue lag makes
# blind sequences land on stale positions.
hmp("mouse_move 0 10"); time.sleep(1.0)
hmp("mouse_button 1"); time.sleep(0.5); hmp("mouse_button 0")  # 0 = RELEASE
```

Gotchas learned the hard way:

- **Screenshot lag**: under TCG clicks/redraws land seconds late — always
  re-shoot after a few seconds before concluding a click failed.
- **The cursor hides what it points at**: a radio's filled dot is painted
  under the arrow; move the pointer away before deciding a check state.
- **Keyboard keys get dropped** under TCG load; verify each key landed
  with a screenshot (focus rect) before pressing Enter.

Notes:

- `#![windows_subsystem = "windows"]` in `main.rs` is required: with
  `/SUBSYSTEM:WINDOWS` the MSVC CRT startup would otherwise look for
  `_WinMain@16` and the link fails.
- Running on Windows 9x/ME needs `unicows.dll` next to the executable.
- `build-std` is off (the tarball doesn't bundle `rust-src`); the precompiled
  std for the rust9x targets is used instead.

## Sanity check without the rust9x toolchain

```
cargo check --target i686-pc-windows-msvc
```
