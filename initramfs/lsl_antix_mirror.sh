#!/bin/sh
# lsl_antix_mirror.sh - antiX live-init (32-bit x86) HDD-mirror auto-detect hook.
#
# antiX is a Debian-family, 32-bit (i386) live distro that ships a "live-init"
# fork - NOT stock Debian live-boot. Its monolithic /init locates the root
# squashfs via the SQFILE_FILE variable (default /antiX/linuxfs) and scans block
# devices in find_linuxfs_file(). We reuse the SAME mirror layout as
# casper/live-boot (sfs/filesystem.squashfs + sfs/manifest.txt carrying our
# beacon) and, if verified, set SQFILE_FILE=/sfs/filesystem.squashfs so antiX's
# own scanner adopts the internal-disk mirror. No patching of antiX internals
# beyond exporting that one variable.
#
# Injection: build.sh inserts ". /lsl_antix_mirror.sh" immediately before the
# find_linuxfs_file call in antiX's /init. The hook is then SOURCED in the same
# shell, so `export SQFILE_FILE=...` reaches find_linuxfs_file. Because it is
# sourced inside main_wrapper, this hook must NOT use `return`/`exit` (that would
# abort main_wrapper and stop the boot) - it falls through to EOF and /init
# continues to find_linuxfs_file.
#
# Safety: never panics, never changes the root. If the mirror is missing,
# unreadable, or fails verification, it simply does nothing and antiX falls back
# to /antiX/linuxfs on the USB. `lsl_no_hdd_mirror` disables the hook entirely.
set +e

lsl_dbg() {
    if grep -qw lsl_hdd_mirror_debug /proc/cmdline 2>/dev/null; then
        echo "lsl-antix-mirror: $*" > /dev/console 2>/dev/null || echo "lsl-antix-mirror: $*" >&2
    fi
}

if grep -qw lsl_no_hdd_mirror /proc/cmdline 2>/dev/null; then
    lsl_dbg "DISABLED via lsl_no_hdd_mirror"
else
    BEACON="LSL squashfs layers copied to HDD for faster boot"
    LSLL_MNT="/mnt/lsl-mirror-scan"

    # Echo the "sfs" dir that holds a verified LSL mirror manifest, else nothing.
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
        [ -f "$man/filesystem.squashfs" ] || return 1
        return 0
    }

    mkdir -p "$LSLL_MNT" 2>/dev/null
    adopted=""
    for dev in $(find /dev -type b 2>/dev/null); do
        case "$dev" in
            */loop*|*/ram*|*/dm-*|*/sr*|*/fd*|*/zram*) continue ;;
        esac
        mnt="$LSLL_MNT/$(basename "$dev")"
        mkdir -p "$mnt" 2>/dev/null || continue
        if ntfs-3g -o ro,force "$dev" "$mnt" >/dev/null 2>&1 || mount -o ro "$dev" "$mnt" >/dev/null 2>&1; then
            sfs=$(lsl_find_sfs "$mnt")
            if [ -n "$sfs" ] && lsl_verify "$sfs"; then
                # Point antiX's own scanner at the mirror layout. antiX does the
                # actual mounting/looping; we just verify + redirect. Export
                # FROM_BOOT so antiX scans hard disks (and USB disks) - by
                # default it only scans usb,cd and would miss the internal HDD.
                export SQFILE_FILE="/sfs/filesystem.squashfs"
                export FROM_BOOT="hd,usb"
                adopted=1
                echo "LSL: adopting antiX HDD mirror from $sfs (SQFILE_FILE=/sfs/filesystem.squashfs FROM_BOOT=hd,usb)" >&2
                lsl_dbg "ADOPTED $sfs"
                umount "$mnt" >/dev/null 2>&1 || true
                rmdir "$mnt" >/dev/null 2>&1 || true
                break
            else
                umount "$mnt" >/dev/null 2>&1 || true
            fi
        fi
        rmdir "$mnt" >/dev/null 2>&1 || true
    done
    rmdir "$LSLL_MNT" >/dev/null 2>&1 || true
    [ -z "$adopted" ] && lsl_dbg "NO MIRROR FOUND (falling back to USB)"
fi
# NOTE: intentionally no `return`/`exit` - this file is sourced inside antiX
# main_wrapper, and returning would abort the boot.
