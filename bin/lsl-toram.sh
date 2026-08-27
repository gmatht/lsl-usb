#!/bin/bash
# lsl-toram.sh - move the running live session into RAM so the USB stick can be
# removed. A lazy, run-whenever-you-want "toram": boot normally, then run this
# in the background; when it finishes, unplug the USB.
#
# Why this shape: a running overlayfs cannot have its lowerdirs (the squashfs
# files on the USB) re-based, so the whole merged root is copied into a tmpfs
# and pivot_root() switches into it; the old root (squashfs + cow) is then
# unmounted along with /cdrom.
#
# Caveats (please read):
#  - Needs free RAM roughly >= current root size (plus working space).
#  - After the swap, persistence writes to the USB (uphome / lsl-home-flushd /
#    uproot / persist-wifi) are unavailable until the stick is re-inserted.
#  - Processes holding open files keep writing to the pre-copy descriptors;
#    restart long-lived apps after the swap for full consistency.
#
# Usage: sudo bin/lsl-toram.sh
#   LSL_TORAM_TEST=1  stop after the RAM copy (no pivot) - dry run.
set -euo pipefail

[ "$EUID" -eq 0 ] || { echo "Please run as root." >&2; exit 1; }
[ -e /run/lsl-toram.done ] && { echo "Session is already running from RAM."; exit 0; }
mountpoint -q /cdrom || { echo "/cdrom is not mounted; this does not look like a live session." >&2; exit 1; }

NEW=/lsl-toram-root
OLD=/lsl-toram-old

# du gets absolute paths (/proc); tar gets ./-relative (when archiving '.').
DU_EXCLUDES=(--exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run --exclude=/tmp \
             --exclude=/mnt --exclude=/media --exclude=/cdrom \
             --exclude=/lsl-toram-root --exclude=/lsl-toram-old)
TAR_EXCLUDES=(--exclude=./proc --exclude=./sys --exclude=./dev --exclude=./run --exclude=./tmp \
              --exclude=./mnt --exclude=./media --exclude=./cdrom \
              --exclude=./lsl-toram-root --exclude=./lsl-toram-old)

echo "Measuring the running root..."
root_mb="$(du -sm "${DU_EXCLUDES[@]}" / 2>/dev/null | awk '{print $1}')"
root_mb="${root_mb:-0}"
# headroom: extra 50% (cow growth, cache working set)
need_mb=$(( root_mb * 15 / 10 + 512 ))
free_mb="$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)"
echo "Root to copy: ~${root_mb} MB  |  RAM needed: ~${need_mb} MB  |  free: ${free_mb} MB"
if [ "$need_mb" -gt "$free_mb" ]; then
    echo "ERROR: not enough free RAM (need ~${need_mb} MB)." >&2
    exit 1
fi

# Stop all LSL persistence helpers; left running they hold files in the old
# root and prevent it from being unmounted (so the USB could not be removed).
systemctl stop lsl-home-flushd.service lsl-btrfs-growd.service lsl-precache.service 2>/dev/null || true

# Detach the persistence loop devices (home/cache btrfs) so the old root can be
# fully unmounted after the pivot. Source the helpers to resolve the image paths.
if [ -x /cdrom/bin/lsl-common.sh ]; then
    # shellcheck source=/dev/null
    . /cdrom/bin/lsl-common.sh 2>/dev/null || true
    lsl_load_config 2>/dev/null || true
    for img in "$(lsl_home_btrfs_path 2>/dev/null)" "$(lsl_cache_btrfs_path 2>/dev/null)"; do
        [ -f "$img" ] || continue
        for ld in $(losetup -j "$img" 2>/dev/null | awk -F: '{print $1}'); do
            [ -b "$ld" ] && losetup -d "$ld" 2>/dev/null || true
        done
    done
fi

mkdir -p "$NEW" "$OLD"
mount -t tmpfs -o "size=${need_mb}M" tmpfs "$NEW"
mount -t tmpfs -o size=64M tmpfs "$OLD"

echo "Copying the live root into RAM (${root_mb} MB)..."
tar -C / -cf - "${TAR_EXCLUDES[@]}" . | tar -C "$NEW" -xf -

# Carry the runtime mounts into the new root before the swap.
for d in proc sys dev run; do
    [ -e "$NEW/$d" ] || mkdir -p "$NEW/$d"
    mount --bind "/$d" "$NEW/$d"
done

sync

if [ "${LSL_TORAM_TEST:-0}" = "1" ]; then
    echo "TEST MODE: root copied to $NEW; swap skipped."
    du -sh "$NEW" 2>/dev/null | sed 's/^/Copied: /'
    exit 0
fi

echo "Switching the session root to RAM..."
# Best-effort snapshot in case the pivot wedges the session (the USB is still
# mounted here, so the tarball survives a hard reset).
if [ -x /cdrom/bin/lsl-diag.sh ]; then
    bash /cdrom/bin/lsl-diag.sh toram-pre >/dev/null 2>&1 || true
fi
echo "NOTE: after the swap, persistence writes (uphome / lsl-home-flushd /"
echo "      uproot / persist-wifi) are unavailable until the USB is re-inserted."
mount --make-rprivate /
cd "$NEW"
pivot_root . "$OLD"
cd /

# Unmount the old root (squashfs + cow) and the USB itself.
umount -R "$OLD" 2>/dev/null || true
umount /cdrom 2>/dev/null || true
umount /mnt/* 2>/dev/null || true

# Lazy-unmount the old root and the USB so we don't block on busy files held by
# long-lived processes; the kernel releases them once those processes exit.
umount -l -R "$OLD" 2>/dev/null || umount -l "$OLD" 2>/dev/null || true
umount -l /cdrom 2>/dev/null || true
for m in /mnt/*; do
    mountpoint -q "$m" 2>/dev/null && umount -l "$m" 2>/dev/null || true
done

touch /run/lsl-toram.done
if mountpoint -q /cdrom 2>/dev/null; then
    echo "WARNING: /cdrom is still mounted (lazy unmount pending); wait a moment before removing the USB."
else
    echo "Done. The USB stick can now be removed."
fi
