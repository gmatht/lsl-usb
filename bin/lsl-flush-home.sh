#!/bin/bash
# Flush merged /home to the per-distro home.sfs (USB mode). Linear mksquashfs write.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lsl-common.sh"

lsl_load_config
lsl_source_state

HOME_SFS="$(lsl_home_sfs_path)"

# RAM-only home (Boot to RAM, no persistence): /home is a tmpfs, so there is
# nothing to persist - and squashing it to home.sfs would defeat the point.
if [ "$(findmnt -n -o FSTYPE --target /home 2>/dev/null || true)" = "tmpfs" ]; then
    echo "lsl-flush-home.sh: /home is RAM (tmpfs); nothing to flush." >&2
    exit 0
fi

if ! lsl_is_usb_mode; then
    echo "lsl-flush-home.sh: not USB mode; use btrfs sync on HDD." >&2
    exit 1
fi

# Only a real USB-mode overlay may be squashed to home.sfs. A fallback tmpfs
# overlay (HDD data dir not persistent at mount time) has the same layout but
# was mounted transiently and by design must not be written to the stick's
# per-distro home image: doing so overwrites a good image with a near-empty
# one. See lsl_effective_home_mode in lsl-common.sh.
_ehm="$(lsl_effective_home_mode)"
if [ "$_ehm" = "usb-fallback" ]; then
    echo "lsl-flush-home.sh: /home is a FALLBACK tmpfs overlay; refusing to overwrite" >&2
    echo "  $HOME_SFS with it. Reboot with the data dir mounted and retry." >&2
    exit 1
fi

if ! mountpoint -q /home 2>/dev/null; then
    echo "lsl-flush-home.sh: /home is not mounted." >&2
    exit 1
fi

LOWER="${LSL_HOME_LOWER:-/run/lsl-home-lower}"
UPPER="${LSL_HOME_UPPER:-/run/lsl-home-overlay/upper}"
WORK="${LSL_HOME_WORK:-/run/lsl-home-overlay/work}"

mount /cdrom -o remount,rw 2>/dev/null || {
    echo "lsl-flush-home.sh: could not remount /cdrom read-write; aborting." >&2
    exit 1
}

ts="$(date +%Y%m%d%H%M%S)"
tmp_sfs="/cdrom/home_new_${ts}.sfs"

echo "Writing merged /home to ${tmp_sfs}..."
# Free-space guard: a full FAT partition makes mksquashfs fail cryptically.
# `|| true`: du exits nonzero (with stderr already suppressed) if ANY entry
# under /home is unreadable - without this, pipefail + set -e abort the
# flush silently right here. An unknown size falls back to 0 and the df
# check below still guards the write.
sz="$(du -sm /home 2>/dev/null | awk '{print $1}' || true)"; sz="${sz:-0}"
need_mib="$(( sz + 64 ))"
if ! lsl_ensure_cdrom_space "$need_mib"; then
    echo "lsl-flush-home.sh: only $(lsl_cdrom_free_mib) MiB free on /cdrom; need ~${need_mib} MiB to flush /home. Aborting." >&2
    mount /cdrom -o remount,ro 2>/dev/null || true
    exit 1
fi
mksquashfs /home "$tmp_sfs" -comp zstd -b 512K -one-file-system -noappend

if [ -f "$HOME_SFS" ]; then
    mv "$HOME_SFS" "/cdrom/home_${ts}.sfs"
fi
mv "$tmp_sfs" "$HOME_SFS"

echo "Remounting home overlay with fresh upper..."
umount /home
umount "$LOWER" 2>/dev/null || true

mkdir -p "$LOWER"
mount "$HOME_SFS" "$LOWER"

find "${UPPER}" -mindepth 1 -delete 2>/dev/null || true
find "${WORK}" -mindepth 1 -delete 2>/dev/null || true
mkdir -p "$UPPER" "$WORK"
chmod 0755 "$UPPER" "$WORK"

mount -t overlay overlay -o "lowerdir=${LOWER}/,upperdir=${UPPER},workdir=${WORK}" /home

echo "home.sfs flush complete."
df -h /cdrom 2>/dev/null || true
