#!/bin/sh
# lsl_hdd_mirror.sh - initramfs (casper-premount) auto-detect hook.
#
# Goal: if the user copied the Linux squashfs layers to a local disk (NTFS or
# otherwise) with bin/lsl-copy-sfs-hdd.sh (or the Windows wizard), boot the live
# root FROM that mirror instead of /cdrom (the USB). The internal disk is faster,
# so boot is quicker and USB wear drops.
#
# How: casper's layer discovery reads LAYERFS_PATH (an absolute dir holding the
# layers). We scan local block devices, mount each read-only, look for a mirror
# "sfs/manifest.txt" carrying our beacon header, and - if every recorded layer
# exists with the expected size (+ sha256, when recorded) - point LAYERFS_PATH
# at the multi-layer entry (filesystem.z0.squashfs, which casper stacks over
# filesystem.squashfs). /cdrom (bin/, onboot.sh, lsl-usb.env) stays on the USB.
#
# Safety: this script NEVER panics and NEVER changes the root. If anything is
# missing, unreadable, or fails verification, it simply does nothing and casper
# falls back to /cdrom (USB) - which just boots a little slower. A cmdline flag
# "lsl_no_hdd_mirror" disables the hook entirely (handy if the mirror is suspect).
#
# Runs as a casper-premount script (sourced by casper before live-media
# discovery), so an exported LAYERFS_PATH propagates into casper.
#
# NOTE: this file is injected into casper-premount and listed in that dir's ORDER
# file (casper's run_scripts *sources* ORDER, and each ORDER line runs the script
# as a subprocess - so we are SOURCED, which is what lets our exported
# LAYERFS_PATH reach casper). Keep it POSIX-sh and avoid `exit` (use
# `return 0 2>/dev/null || exit 0` so it is safe whether sourced or executed).
set +e

# Debug logging to the console, gated by the "lsl_hdd_mirror_debug" cmdline flag.
lsl_dbg() {
    if grep -qw lsl_hdd_mirror_debug /proc/cmdline 2>/dev/null; then
        echo "lsl-hdd-mirror: $*" > /dev/console 2>/dev/null || echo "lsl-hdd-mirror: $*" >&2
    fi
}

# Disable on explicit request.
if grep -qw lsl_no_hdd_mirror /proc/cmdline 2>/dev/null; then
    lsl_dbg "DISABLED via lsl_no_hdd_mirror"
    return 0 2>/dev/null || exit 0
fi

BEACON="LSL squashfs layers copied to HDD for faster boot"
LSLL_MNT="/mnt/lsl-mirror-scan"
ADOPT=""

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
    # casper's multi-layer chain needs the z0 entry point.
    [ -f "$man/filesystem.z0.squashfs" ] || return 1
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
            # Keep this volume mounted: casper loop-mounts the layer file through it.
            ADOPT="$sfs/filesystem.z0.squashfs"
            export LAYERFS_PATH="$ADOPT"
            echo "LSL: adopting HDD mirror layers from $sfs (LAYERFS_PATH=$LAYERFS_PATH)" >&2
            lsl_dbg "ADOPTED $ADOPT from $sfs"
            return 0 2>/dev/null || exit 0
        fi
        umount "$mnt" >/dev/null 2>&1 || true
    fi
    rmdir "$mnt" >/dev/null 2>&1 || true
done
rmdir "$LSLL_MNT" >/dev/null 2>&1 || true
lsl_dbg "NO MIRROR FOUND (falling back to USB)"
return 0 2>/dev/null || exit 0
