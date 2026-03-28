#!/bin/bash
# Flush merged /home to /cdrom/home.sfs (USB mode). Linear mksquashfs write.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lsl-common.sh"

lsl_load_config
lsl_source_state

if ! lsl_is_usb_mode; then
    echo "lsl-flush-home.sh: not USB mode; use btrfs sync on HDD." >&2
    exit 1
fi

if ! mountpoint -q /home 2>/dev/null; then
    echo "lsl-flush-home.sh: /home is not mounted." >&2
    exit 1
fi

LOWER="${LSL_HOME_LOWER:-/run/lsl-home-lower}"
UPPER="${LSL_HOME_UPPER:-/run/lsl-home-overlay/upper}"
WORK="${LSL_HOME_WORK:-/run/lsl-home-overlay/work}"

mount /cdrom -o remount,rw

ts="$(date +%Y%m%d%H%M%S)"
tmp_sfs="/cdrom/home_new_${ts}.sfs"

echo "Writing merged /home to ${tmp_sfs}..."
mksquashfs /home "$tmp_sfs" -comp zstd -b 512K -one-file-system -noappend

if [ -f /cdrom/home.sfs ]; then
    mv /cdrom/home.sfs "/cdrom/home_${ts}.sfs"
fi
mv "$tmp_sfs" /cdrom/home.sfs

echo "Remounting home overlay with fresh upper..."
umount /home
umount "$LOWER" 2>/dev/null || true

mkdir -p "$LOWER"
mount /cdrom/home.sfs "$LOWER"

find "${UPPER}" -mindepth 1 -delete 2>/dev/null || true
find "${WORK}" -mindepth 1 -delete 2>/dev/null || true
mkdir -p "$UPPER" "$WORK"
chmod 0755 "$UPPER" "$WORK"

mount -t overlay overlay -o "lowerdir=${LOWER}/,upperdir=${UPPER},workdir=${WORK}" /home

echo "home.sfs flush complete."
df -h /cdrom 2>/dev/null || true
