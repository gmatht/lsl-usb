#!/bin/sh
# lsl_liveboot_mirror.sh - initramfs (live-boot live-premount) auto-detect hook.
#
# Goal: if the user copied the Linux squashfs layers to a local disk (NTFS or
# otherwise) with bin/lsl-copy-sfs-hdd.sh (or the Windows wizard), boot the live
# root FROM that mirror instead of the USB. The internal disk is faster, so boot
# is quicker and USB wear drops.
#
# How: live-boot discovers its layers via find_livefs(), which scans block
# devices and - for each - calls is_live_path(): it just globs
# "${mountpoint}/${LIVE_MEDIA_PATH}/*.squashfs". The default LIVE_MEDIA_PATH is
# "live", so a stock ISO keeps "live/filesystem.squashfs". Our mirror is laid out
# as "sfs/filesystem.squashfs" (+ "sfs/filesystem.z0.squashfs" for the first-boot
# layer) carrying a beacon header in "sfs/manifest.txt". If we verify a mirror we
# simply `export LIVE_MEDIA_PATH=sfs`; live-boot's OWN scanner then finds
# "sfs/*.squashfs" on the internal disk and assembles the root from it. No
# LAYERFS_PATH / patching of live-boot internals required, and the same mirror
# layout works for casper (see lsl_hdd_mirror.sh).
#
# Timing: /usr/bin/live-boot sources all 9990-* helpers (incl. 0001-init-vars,
# which sets LIVE_MEDIA_PATH=live) at parse time - BEFORE scripts/live-premount
# runs. So a live-premount hook that exports LIVE_MEDIA_PATH=sfs wins, and
# find_livefs (called later from Live()) honours it. If we do NOT export sfs
# (no mirror / verify failed), the default "live" stays and live-boot falls back
# to the USB. Auto-detect, never panic.
#
# Safety: this script NEVER panics and NEVER changes the root. If anything is
# missing, unreadable, or fails verification, it simply returns and live-boot
# falls back to the USB - which just boots a little slower. A cmdline flag
# "lsl_no_hdd_mirror" disables the hook entirely.
#
# Runs as a live-boot live-premount script (sourced by run_scripts into the
# live-boot shell), so an exported LIVE_MEDIA_PATH propagates into Live()/find_livefs.
# Keep it POSIX-sh; avoid `exit` (use `return 0 2>/dev/null || exit 0` so it is
# safe whether sourced or executed).
set +e

lsl_dbg() {
    if grep -qw lsl_hdd_mirror_debug /proc/cmdline 2>/dev/null; then
        echo "lsl-liveboot-mirror: $*" > /dev/console 2>/dev/null || echo "lsl-liveboot-mirror: $*" >&2
    fi
}

if grep -qw lsl_no_hdd_mirror /proc/cmdline 2>/dev/null; then
    lsl_dbg "DISABLED via lsl_no_hdd_mirror"
    return 0 2>/dev/null || exit 0
fi

BEACON="LSL squashfs layers copied to HDD for faster boot"
LSLL_MNT="/mnt/lsl-mirror-scan"

# Echo the "sfs" dir that holds a verified LSL mirror manifest, else nothing.
# Avoids head|grep pipelines (fragile under busybox ash in the initramfs); uses
# `read` + `case` instead.
lsl_find_sfs() {
    for mf in $(find "$1" -maxdepth 4 -type f -name manifest.txt 2>/dev/null); do
        d=$(dirname "$mf")
        case "$d" in */sfs) : ;; *) continue ;; esac
        read -r first < "$mf" 2>/dev/null || continue
        case "$first" in *"$BEACON"*) echo "$d"; return 0 ;; esac
    done
}

lsl_verify() {
    man="$1"
    [ -f "$man/manifest.txt" ] || return 1
    while IFS='=' read -r name rest || [ -n "$name" ]; do
        case "$name" in ''|\#*|SourceUSB|Date) continue ;; esac
        size=$(printf '%s' "$rest" | awk '{print $1}')
        want=$(printf '%s' "$rest" | sed -n 's/.*sha256:\([0-9a-fA-F]*\).*/\1/p')
        f="$man/$name"
        [ -s "$f" ] || return 1
        s=$(busybox stat -c %s "$f" 2>/dev/null || stat -c %s "$f" 2>/dev/null || echo "")
        [ "$s" = "$size" ] || return 1
        if [ -n "$want" ] && command -v sha256sum >/dev/null 2>&1; then
            got=$(sha256sum "$f" 2>/dev/null | awk '{print $1}')
            [ "$got" = "$want" ] || return 1
        fi
    done < "$man/manifest.txt"
    # live-boot globs sfs/*.squashfs; at minimum the base layer must exist.
    [ -f "$man/filesystem.squashfs" ] || return 1
    return 0
}

mkdir -p "$LSLL_MNT" 2>/dev/null
for dev in $(find /dev -type b 2>/dev/null); do
    case "$dev" in
        */loop*|*/ram*|*/dm-*|*/sr*|*/fd*|*/zram*) continue ;;
    esac
    mnt="$LSLL_MNT/$(basename "$dev")"
    mkdir -p "$mnt" 2>/dev/null || continue
    if ntfs-3g -o ro,force "$dev" "$mnt" >/dev/null 2>&1 || mount -o ro "$dev" "$mnt" >/dev/null 2>&1; then
        sfs=$(lsl_find_sfs "$mnt")
        if [ -n "$sfs" ] && lsl_verify "$sfs"; then
            # Point live-boot's own find_livefs at the mirror layout. live-boot
            # does the actual mounting/looping; we just verify + redirect.
            export LIVE_MEDIA_PATH="sfs"
            echo "LSL: adopting live-boot HDD mirror from $sfs (LIVE_MEDIA_PATH=sfs)" >&2
            lsl_dbg "ADOPTED $sfs"
            umount "$mnt" >/dev/null 2>&1 || true
            rmdir "$mnt" >/dev/null 2>&1 || true
            return 0 2>/dev/null || exit 0
        fi
        umount "$mnt" >/dev/null 2>&1 || true
    fi
    rmdir "$mnt" >/dev/null 2>&1 || true
done
rmdir "$LSLL_MNT" >/dev/null 2>&1 || true
lsl_dbg "NO MIRROR FOUND (falling back to USB)"
return 0 2>/dev/null || exit 0
