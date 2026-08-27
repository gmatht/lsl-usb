#!/bin/bash
# tests/btrfs-growd.tests.sh - validate the ONLINE btrfs-grow mechanism used by
# bin/lsl-btrfs-growd (try_grow). We exercise the exact PRIMARY path the daemon
# uses on real hardware/loop-backed /home:
#
#   1. grow the backing image file             (truncate -s +N)
#   2. make the live loop device pick up the   (losetup -c, no unmount)
#      new size online
#   3. grow the btrfs filesystem to fill it    (btrfs filesystem resize max)
#
# ...and confirm the mounted filesystem actually grew, and that findmnt discovers
# the /dev/loop device the way the daemon expects. Uses a real loop device so this
# is a genuine integration check (not a mock), and it runs in CI (needs root +
# btrfs-progs + losetup; skips cleanly otherwise).
#
# Usage: sudo tests/btrfs-growd.tests.sh
set -u

ROOT="$(mktemp -d)"
cleanup() { cd /; umount "$ROOT/mnt" 2>/dev/null; losetup -d "$ROOT/loop" 2>/dev/null; rm -rf "$ROOT"; }
trap cleanup EXIT

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }
skip() { echo "SKIP: $1 (btrfs online-grow not validated - non-fatal)"; exit 0; }

[ "$(id -u)" -eq 0 ] || skip "not root (need losetup)"
command -v losetup     >/dev/null 2>&1 || skip "losetup missing"
command -v mkfs.btrfs  >/dev/null 2>&1 || skip "btrfs-progs (mkfs.btrfs) missing"
command -v btrfs       >/dev/null 2>&1 || skip "btrfs-progs (btrfs) missing"
modprobe loop 2>/dev/null || true

IMG="$ROOT/home.btrfs"; MP="$ROOT/mnt"; mkdir -p "$MP"
truncate -s 256M "$IMG"
LOOP="$(losetup -f --show "$IMG")" || skip "no free loop device available"
mkfs.btrfs -f "$LOOP" >/dev/null 2>&1 || skip "mkfs.btrfs failed (image too small? min ~114MiB)"
# Mount the loop device DIRECTLY (no -o loop): the daemon mounts a *file* with
# -o loop, yielding one loop device backed by the file; mimicking that here
# avoids nesting a second loop (which would defeat losetup -c below).
mount -t btrfs -o compress=zstd:3 "$LOOP" "$MP" || skip "could not mount btrfs loop"

size_of() {
  local s
  s="$(blockdev --getsize64 "$1" 2>/dev/null)"
  if [ -z "$s" ]; then
    s="$(btrfs filesystem usage -b "$1" 2>/dev/null | awk '/Device size:/{print $3}')"
  fi
  echo "$s"
}

sz0="$(size_of "$MP")"
echo "size before grow: ${sz0:-unknown} bytes"

# --- replicate bin/lsl-btrfs-growd try_grow PRIMARY (online) path exactly ---
truncate -s +256M "$IMG"                      # 1. grow backing file
loop_dev="$(findmnt -n -o SOURCE "$MP" 2>/dev/null | grep -E '^/dev/loop' | head -1)"
if [ -n "$loop_dev" ] && [ -b "$loop_dev" ]; then
  losetup -c "$loop_dev" 2>/dev/null || true   # 2. online re-read size
fi
btrfs filesystem resize max "$MP" 2>/dev/null || bad "btrfs filesystem resize max failed"
# --- end replication ---

sz1="$(size_of "$MP")"
echo "size after  grow: ${sz1:-unknown} bytes"

if [ -n "$sz0" ] && [ -n "$sz1" ] && [ "$sz1" -gt "$sz0" ]; then
  ok "mounted btrfs grew online by $((sz1 - sz0)) bytes"
else
  bad "btrfs did not grow ($sz0 -> $sz1)"
fi

if [ -n "$loop_dev" ]; then
  ok "findmnt discovered loop device backing /home: $loop_dev"
else
  bad "findmnt did not find a /dev/loop device (daemon's PRIMARY path would miss it)"
fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
