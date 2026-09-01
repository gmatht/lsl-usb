#!/bin/bash
#
# bench-f2fs.sh - Benchmark random writes on an F2FS filesystem.
#
# Creates a sparse 1 GB image, formats it as F2FS, loop-mounts it, and runs an
# fio random-write workload *inside* the mounted F2FS volume. Reports IOPS,
# bandwidth and latency.
#
# Meant to run on a REAL Linux machine - e.g. booted from the lsl-usb LiveUSB,
# which uses a stock kernel (Linux Mint 22.x / Ubuntu 24.04, 6.8) with F2FS
# support. It will NOT work under WSL2's Microsoft kernel, which omits
# CONFIG_F2FS_FS (modprobe f2fs -> "Module f2fs not found").
#
# Usage:
#   sudo ./bench-f2fs.sh [IMAGE_PATH] [SIZE_GB]
#     IMAGE_PATH  where to put the image (default /var/tmp/f2fs.img)
#     SIZE_GB     image size in GiB        (default 1)
#
# Env overrides:
#   FIO_JOBS=4     number of concurrent fio jobs
#   FIO_BS=4k       block size
#   RUNTIME=60      seconds per run (time_based)
#   DIRECT=1        use O_DIRECT (1) or buffered IO (0)
#   LEAVE_IMG=0     if 1, keep the image file after exit (mount is still cleaned)
#
# Requires: f2fs-tools (mkfs.f2fs), fio, util-linux (losetup), coreutils.
#
set -euo pipefail

IMG="${1:-/var/tmp/f2fs.img}"
SIZE_GB="${2:-1}"
FIO_JOBS="${FIO_JOBS:-4}"
FIO_BS="${FIO_BS:-4k}"
RUNTIME="${RUNTIME:-60}"
DIRECT="${DIRECT:-1}"
LEAVE_IMG="${LEAVE_IMG:-0}"

MNT="$(mktemp -d /tmp/f2fs-bench.XXXXXX)"
LOOP=""

cleanup() {
    local rc=$?
    if [ -n "$LOOP" ] && mountpoint -q "$MNT" 2>/dev/null; then
        umount "$MNT" 2>/dev/null || umount -f "$MNT" 2>/dev/null || true
    fi
    if [ -n "$LOOP" ]; then losetup -d "$LOOP" 2>/dev/null || true; fi
    rmdir "$MNT" 2>/dev/null || true
    [ "${LEAVE_IMG:-0}" = "1" ] || rm -f "$IMG" 2>/dev/null || true
    exit $rc
}
trap cleanup EXIT INT TERM

need() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: required tool '$1' not found. Install: $2" >&2
        exit 1
    }
}

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (loop mount needs it)." >&2; exit 1; }

need mkfs.f2fs "apt-get install -y f2fs-tools"
need fio      "apt-get install -y fio"
need losetup  "(part of util-linux)"
need truncate "(part of coreutils)"

# F2FS kernel support?
if ! grep -qw f2fs /proc/filesystems; then
    if ! modprobe f2fs 2>/dev/null; then
        echo "ERROR: F2FS is not supported by this kernel." >&2
        echo "       Boot a kernel with CONFIG_F2FS_FS (stock Ubuntu/Mint), not the WSL2 Microsoft kernel." >&2
        exit 1
    fi
fi

echo "==> Creating ${SIZE_GB}G F2FS image at $IMG"
rm -f "$IMG"
truncate -s "${SIZE_GB}G" "$IMG"

echo "==> mkfs.f2fs"
mkfs.f2fs -f "$IMG" >/dev/null

echo "==> loop-mount (f2fs)"
LOOP="$(losetup -f --show "$IMG")"
mount -t f2fs "$LOOP" "$MNT"
echo "    $LOOP -> $MNT ($(findmnt -n -o FSTYPE "$MNT"))"

SIZE_MB=$(( SIZE_GB * 1024 ))
PER_JOB_MB=$(( SIZE_MB * 90 / 100 / FIO_JOBS ))
[ "$PER_JOB_MB" -lt 1 ] && PER_JOB_MB=1

echo "==> fio random-write: bs=$FIO_BS jobs=$FIO_JOBS runtime=${RUNTIME}s direct=$DIRECT"
fio --name=randwrite \
    --directory="$MNT" \
    --size="${PER_JOB_MB}m" \
    --ioengine=libaio --direct="$DIRECT" --gtod_reduce=1 \
    --rw=randwrite --bs="$FIO_BS" \
    --numjobs="$FIO_JOBS" --runtime="$RUNTIME" --time_based \
    --group_reporting

echo "==> done (mount cleaned up${LEAVE_IMG:+; image kept at $IMG})"
