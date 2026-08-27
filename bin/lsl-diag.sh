#!/bin/bash
# lsl-diag.sh - collect boot/runtime diagnostics into a tarball that survives
# on a Windows-readable volume (so a wedged first boot or onboot failure can be
# inspected without the USB). Wired into lsl-firstboot.sh / onboot.sh on failure.
#
# Usage: bash /cdrom/bin/lsl-diag.sh [tag]
#   tag   optional label recorded in the archive name (e.g. "firstboot-failed").
set -u

TAG="${1:-diag}"
TS="$(date +%Y%m%d%H%M%S)"

# Destination: first writable, reboot-surviving location we can find. /tmp is RAM
# and is lost on reboot, so it is the last resort; /cdrom (the USB itself) is
# preferred when no Windows volume is mounted (e.g. first boot, hivex missing).
DEST=""
LSL_DIAG_CDROM_RW=0
for cand in /mnt/c/lsl-diag /mnt/c/Users/lsl-usb/lsl-diag /persist/casper/lsl-diag /cdrom/lsl-diag /tmp/lsl-diag; do
    mkdir -p "$cand" 2>/dev/null || continue
    if [ -w "$cand" ]; then
        DEST="$cand"
        break
    fi
    # /cdrom is normally read-only; try a temporary rw remount so the
    # diagnostics survive a reboot on the USB itself instead of in RAM.
    if [ "${cand#/cdrom}" != "$cand" ]; then
        mount -o remount,rw /cdrom 2>/dev/null || true
        if [ -w "$cand" ]; then
            DEST="$cand"
            LSL_DIAG_CDROM_RW=1
            break
        fi
    fi
done
[ -n "$DEST" ] || DEST=/tmp/lsl-diag
mkdir -p "$DEST" 2>/dev/null || true

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- gather sources --------------------------------------------------------
cp -a /run/lsl-usb.state        "$WORK/lsl-usb.state"        2>/dev/null || true
cp -a /run/lsl-firstboot-status "$WORK/lsl-firstboot-status" 2>/dev/null || true
cp -a /cdrom/lsl-usb.env        "$WORK/lsl-usb.env"          2>/dev/null || true
cp -a /cdrom/VERSION        "$WORK/VERSION"          2>/dev/null || true
cp -a /cdrom/lsl-build.txt  "$WORK/lsl-build.txt"    2>/dev/null || true
cp -a /cdrom/casper/lsl-firstboot.attempts "$WORK/lsl-firstboot.attempts" 2>/dev/null || true
cp -a /cdrom/casper/lsl-firstboot.FAILED     "$WORK/lsl-firstboot.FAILED"     2>/dev/null || true
cp -a /cdrom/casper/boot-times.log "$WORK/boot-times.log"     2>/dev/null || true

mkdir -p "$WORK/firstboot-logs"
cp -a /cdrom/casper/lsl-firstboot-logs/. "$WORK/firstboot-logs/" 2>/dev/null || true
mkdir -p "$WORK/uproot-logs"
cp -a /cdrom/casper/uproot-logs/.   "$WORK/uproot-logs/"       2>/dev/null || true

# Live system state (best-effort; these tools may not all be present).
{
    echo "=== mount ==="; mount 2>/dev/null
    echo "=== findmnt ==="; findmnt 2>/dev/null
    echo "=== df -h ==="; df -h 2>/dev/null
    echo "=== losetup ==="; losetup -a 2>/dev/null
    echo "=== lsl-data-dir ==="; ls -ld /mnt/c/Users/lsl-usb 2>/dev/null
    echo "=== lsl-build ==="; cat /cdrom/lsl-build.txt 2>/dev/null; echo; cat /cdrom/VERSION 2>/dev/null
    echo "=== systemctl lsl-* ==="; systemctl list-units 'lsl-*' 2>/dev/null
} > "$WORK/system-state.txt" 2>/dev/null || true

if command -v dmesg >/dev/null 2>&1; then
    dmesg > "$WORK/dmesg.txt" 2>/dev/null || true
fi
# Secure Boot state (relevant if the USB fails to boot on UEFI firmware).
if command -v mokutil >/dev/null 2>&1; then
    mokutil --sb-state > "$WORK/mokutil-sb-state.txt" 2>/dev/null || true
fi
if command -v journalctl >/dev/null 2>&1; then
    journalctl -u lsl-firstboot.service -u onboot.service --no-pager -n 500 \
        > "$WORK/journal-lsl.txt" 2>/dev/null || true
fi

# --- package it ------------------------------------------------------------
ARCHIVE="$DEST/lsl-${TAG}-${TS}.tar.gz"
if command -v tar >/dev/null 2>&1; then
    tar -C "$WORK" -czf "$ARCHIVE" . 2>/dev/null || ARCHIVE=""
fi
if [ -z "$ARCHIVE" ] || [ ! -f "$ARCHIVE" ]; then
    # Fallback: just leave the exploded dir if tar is unavailable.
    ARCHIVE="$DEST/lsl-${TAG}-${TS}"
    cp -a "$WORK/." "$ARCHIVE/" 2>/dev/null || true
fi

if [ "${LSL_DIAG_CDROM_RW:-0}" = "1" ]; then
    mount -o remount,ro /cdrom 2>/dev/null || true
fi

echo "lsl-diag: wrote $ARCHIVE"
if [ "${LSL_DIAG_CDROM_RW:-0}" = "1" ]; then
    echo "lsl-diag: written to the USB (/cdrom) - it survives a reboot; copy it off when convenient."
else
    echo "lsl-diag: copy this off the USB / Windows volume before rebooting."
fi
