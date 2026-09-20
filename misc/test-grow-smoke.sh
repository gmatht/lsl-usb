#!/bin/bash
# Smoke test for lsl_grow_btrfs_image + lsl_refresh_image_loops.
# Usage: test-grow-smoke.sh /path/to/funcs.sh
#   where funcs.sh holds the REAL functions extracted from onboot.sh.
# Grows a live-attached loopback image (the stale-loop scenario partprobe
# cannot fix) and checks the filesystem actually grows. Not shipped in z0.
set -u
FUNCS="${1:?usage: test-grow-smoke.sh /path/to/funcs.sh}"
WORK=/root/lsl-grow-work
IMG="$WORK/t.img"
MNT="$WORK/m"
rm -rf "$WORK"
mkdir -p "$WORK"
truncate -s 256M "$IMG"
mkfs.btrfs -f -q "$IMG" >/dev/null 2>&1
mkdir -p "$MNT"
losetup /dev/loop3 "$IMG"
mount /dev/loop3 "$MNT"
echo "before: $(df -m "$MNT" | tail -1)"

# shellcheck source=/dev/null
. "$FUNCS"

# Grow WHILE attached (the stale-loop scenario partprobe cannot fix).
lsl_grow_btrfs_image "$IMG" 512
LOOPSIZE="$(blockdev --getsize64 /dev/loop3 2>/dev/null || echo 0)"
echo "loopdev bytes after grow (want 536870912): $LOOPSIZE"
btrfs filesystem resize max "$MNT" 2>&1
AFTER="$(df -m "$MNT" | tail -1)"
echo "after: $AFTER"
case "$AFTER" in
    *" 512 "*) echo "GROW_SMOKE_OK" ;;
    *) echo "GROW_SMOKE_FAIL" ;;
esac
umount "$MNT" 2>/dev/null || true
losetup -d /dev/loop3 2>/dev/null || true
rm -rf "$WORK"
