#!/usr/bin/env bash
# Probe: which EDIT control styles accept keyboard input on Win95?
# Boots the VM, launches nwg-test, tabs through the P1..P4 edit matrix and
# types one marker into each, screenshotting after every step.
set -euo pipefail
cd "$(dirname "$0")"

DISK=${WIN95_DISK:-/root/vm/win95-flat.qcow2}
QMP_PORT=${QMP_PORT:-4445}
export LIBGUESTFS_BACKEND=direct
qmp() { python3 scripts/qmp.py "$@"; }

# 0. stop any running VM (guestfish needs the disk exclusively)
pids=$(ps aux | awk '/qemu-system-i386/ && !/awk/ {print $2}')
if [ -n "$pids" ]; then kill $pids 2>/dev/null || true; sleep 3; kill -9 $pids 2>/dev/null || true; sleep 1; fi

# 1. upload
guestfish -a "$DISK" -m /dev/sda1 upload dist/nwg-test-win95.exe /NWGTEST.EXE
guestfish -a "$DISK" -m /dev/sda1 rm-f "/WINDOWS/Start Menu/Programs/StartUp/NWGTEST.EXE" 2>/dev/null || true

# 2. boot
ACCEL=kvm; [ -w /dev/kvm ] || ACCEL=tcg
setsid qemu-system-i386 -machine pc -cpu pentium -m 256 -accel "$ACCEL" \
  -drive file="$DISK",if=ide,index=0,media=disk -vga cirrus \
  -display none -vnc :5 \
  -qmp tcp:127.0.0.1:$QMP_PORT,server,nowait -rtc base=localtime -net none \
  > /tmp/qemu-win95.log 2>&1 &
echo $! > /tmp/qemu-win95.pid
sleep 5
kill -0 "$(cat /tmp/qemu-win95.pid)"

qmp wait-desktop --min 140 --timeout 720 --verbose || echo "WARN: desktop timeout"
qmp key esc esc
sleep 12
qmp shot dist/probe-00-desktop.png

# 3. launch
qmp run-dialog 'c:\nwgtest.exe'
qmp wait-change dist/probe-00-desktop.png --timeout 90 || echo "WARN: no change"
sleep 5
qmp shot dist/probe-01-window.png

# 4. tab through the edit matrix, typing one marker per stop.
# Tab order of tabstops: Say hello, About, P1, P2, P3, P4.
# Initial focus is on the first tabstop; walk 2..5 tabs and type at each.
declare -a MARKS=(s0 s1 s2 s3 s4 s5 s6)
for i in 0 1 2 3 4 5 6; do
  qmp key tab
  sleep 1
  qmp type "${MARKS[$i]}"
  sleep 1
  qmp shot "dist/probe-tab$((i+1)).png"
done

echo "DONE - shots: dist/probe-*.png (VM left running; QMP port $QMP_PORT)"
