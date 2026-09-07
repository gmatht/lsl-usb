#!/usr/bin/env bash
# Build nwg-test and run it inside Windows 95 under QEMU.
#
#   ./test.sh               # headless (VNC :5 = host port 5905), full cycle
#   ./test.sh --show        # open a visible QEMU window (needs a working X display)
#   ./test.sh --release     # pass through to build.sh
#
# What it does:
#   1. ./build.sh  (always, incremental)
#   2. stops any running Win95 QEMU (guestfish needs the disk exclusively)
#   3. uploads dist/nwg-test-win95.exe to C:\NWGTEST.EXE, verifies md5,
#      and deletes the stale copy in the StartUp folder
#   4. boots the VM, waits until the desktop has settled
#   5. launches C:\NWGTEST.EXE via Start > Run (QMP keyboard)
#   6. waits for the window, then screenshots:
#        dist/qemu-boot.png    desktop before launch
#        dist/qemu-window.png  the app window
#
# While it runs you can watch the VM:
#   - --show mode: the QEMU window itself
#   - headless:    vncviewer localhost:5905   (or :5 in older viewers)
#
# Env overrides:
#   WIN95_DISK=/root/vm/win95-flat.qcow2   scratch disk (recreated from source if missing)
#   WIN95_SOURCE=/root/vm/Win95.vmdk       pristine source image (never written)
# (Note: /tmp is volatile on this host — keep VM images under /root/vm.)
#   QMP_PORT=4445
set -euo pipefail
cd "$(dirname "$0")"

DISK=${WIN95_DISK:-/root/vm/win95-flat.qcow2}
SOURCE=${WIN95_SOURCE:-/root/vm/Win95.vmdk}
QMP_PORT=${QMP_PORT:-4445}
VNC_DISPLAY=:5                       # = TCP port 5905
MODE=headless
BUILD_ARGS=()
for a in "$@"; do
  case "$a" in
    --show) MODE=show ;;
    --release) BUILD_ARGS+=(--release) ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------- 1. build
echo "== 1/6 building"
./build.sh "${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}"

# ------------------------------------------------------- 2. stop running VM
echo "== 2/6 stopping any running VM"
pids=$(ps aux | awk '/qemu-system-i386/ && !/awk/ {print $2}')
if [ -n "$pids" ]; then
  kill $pids 2>/dev/null || true
  sleep 3
  kill -9 $pids 2>/dev/null || true
  sleep 1
fi

# ------------------------------------------------------------ 3. upload exe
echo "== 3/6 uploading to $DISK"
if [ ! -f "$DISK" ]; then
  echo "   scratch disk missing; converting from $SOURCE"
  qemu-img convert -O qcow2 "$SOURCE" "$DISK"
fi
export LIBGUESTFS_BACKEND=direct
guestfish -a "$DISK" -m /dev/sda1 upload dist/nwg-test-win95.exe /NWGTEST.EXE
# the StartUp folder holds a stale exe from earlier experiments; remove it
guestfish -a "$DISK" -m /dev/sda1 rm-f "/WINDOWS/Start Menu/Programs/StartUp/NWGTEST.EXE" 2>/dev/null || true
# verify the upload byte-for-byte (uploads have silently failed before)
guestfish --ro -a "$DISK" -m /dev/sda1 download /NWGTEST.EXE /tmp/_nwg_verify.exe
disk_md5=$(md5sum /tmp/_nwg_verify.exe | cut -d' ' -f1)
want_md5=$(md5sum dist/nwg-test-win95.exe | cut -d' ' -f1)
if [ "$disk_md5" != "$want_md5" ]; then
  echo "ERROR: upload md5 mismatch ($disk_md5 != $want_md5)" >&2
  exit 1
fi
rm -f /tmp/_nwg_verify.exe
echo "   upload verified (md5 $want_md5)"

# ------------------------------------------------------------- 4. boot VM
echo "== 4/6 booting VM (this takes a few minutes)"
ACCEL=kvm
[ -w /dev/kvm ] || ACCEL=tcg
DISP_ARGS=(-display none -vnc "$VNC_DISPLAY")
if [ "$MODE" = show ]; then
  DISP_ARGS=(-display gtk)
fi
setsid qemu-system-i386 -machine pc -cpu pentium -m 256 -accel "$ACCEL" \
  -drive file="$DISK",if=ide,index=0,media=disk -vga cirrus \
  "${DISP_ARGS[@]}" \
  -qmp tcp:127.0.0.1:$QMP_PORT,server,nowait -rtc base=localtime -net none \
  > /tmp/qemu-win95.log 2>&1 &
echo $! > /tmp/qemu-win95.pid
sleep 5
if ! kill -0 "$(cat /tmp/qemu-win95.pid)" 2>/dev/null; then
  echo "ERROR: QEMU died at startup; see /tmp/qemu-win95.log" >&2
  exit 1
fi

python3 scripts/qmp.py wait-desktop --min 140 --timeout 720 --verbose || \
  echo "   WARNING: desktop detection timed out; continuing anyway"
# dismiss any boot-time dialogs (e.g. Display Properties in Safe Mode)
python3 scripts/qmp.py key esc esc
sleep 12                       # let Explorer finish drawing
python3 scripts/qmp.py shot dist/qemu-boot.png

# --------------------------------------------------------- 5. launch the app
echo "== 5/6 launching C:\\NWGTEST.EXE"
python3 scripts/qmp.py run-dialog 'c:\nwgtest.exe'

# -------------------------------------------------------- 6. verify + shoot
echo "== 6/6 waiting for the app window"
if python3 scripts/qmp.py wait-change dist/qemu-boot.png --timeout 60; then
  sleep 5                      # let the window fully paint
  python3 scripts/qmp.py shot dist/qemu-window.png
  echo
  echo "OK: app is running under Windows 95."
  echo "    screenshots: dist/qemu-boot.png (desktop), dist/qemu-window.png (app)"
else
  python3 scripts/qmp.py shot dist/qemu-window.png
  echo
  echo "WARNING: screen did not change after launch; eyeball dist/qemu-window.png"
fi

if [ "$MODE" = show ]; then
  echo
  echo "The QEMU window is open. Interact with it directly."
else
  echo
  echo "The VM keeps running headless. Watch it with:"
  echo "    vncviewer localhost:5905      # (VNC display :5)"
  echo "QMP is on port $QMP_PORT; e.g.:  python3 scripts/qmp.py shot out.png"
fi

# ------------------------------------------------- optional: clean shutdown
# A clean shutdown clears the Windows dirty-shutdown flag, so the NEXT boot
# is normal instead of Safe Mode (Safe Mode boots a 'Display Properties'
# error dialog that delays the desktop). Skipped with --no-shutdown.
if [ "${1:-}" != "--no-shutdown" ] && [ "${2:-}" != "--no-shutdown" ]; then
  echo "== shutting the guest down cleanly (Start > Shut Down)"
  python3 scripts/qmp.py combo ctrl+esc
  sleep 4
  python3 scripts/qmp.py key u          # 'u' = Shut Down... hotkey
  sleep 4
  python3 scripts/qmp.py key ret        # confirm
  if python3 scripts/qmp.py wait-halt; then
    echo "   guest halted; stopping QEMU"
    pids=$(ps aux | awk '/qemu-system-i386/ && !/awk/ {print $2}')
    [ -n "$pids" ] && kill $pids 2>/dev/null || true
  else
    echo "   WARNING: guest did not halt; leaving QEMU running"
  fi
fi
