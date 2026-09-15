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

# Destination: first writable, reboot-surviving location we can find.
# /cdrom (the USB stick itself) goes FIRST: on a live boot the /persist and
# /tmp candidates are RAM-backed tmpfs, so a tarball there is lost on reboot
# (we once lost 22 consecutive failure tarballs that way). /tmp stays the
# last resort; anything there must be copied off before rebooting.
DEST=""
LSL_DIAG_CDROM_RW=0
for cand in /cdrom/lsl-diag /mnt/c/lsl-diag /mnt/c/Users/lsl-usb/lsl-diag /persist/casper/lsl-diag /tmp/lsl-diag; do
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

# Hardware / boot-context for a remote post-mortem (distinguishes DD-mode vs
# ISO-mode / casper-glob / space failures without physical access).
{
    echo "=== /cdrom mount ==="; findmnt -n -o SOURCE,FSTYPE,OPTIONS,TARGET /cdrom 2>/dev/null
    echo "=== /proc/cmdline ==="; cat /proc/cmdline 2>/dev/null; echo
    echo "=== lsblk -f ==="; lsblk -f 2>/dev/null
    echo "=== blkid ==="; blkid 2>/dev/null
    echo "=== casper layers ==="; ls -l /cdrom/casper/filesystem*.squashfs 2>/dev/null
    echo "=== /etc/fstab ==="; cat /etc/fstab 2>/dev/null
} > "$WORK/hardware.txt" 2>/dev/null || true

# Network snapshot: firstboot usually dies on "no network" with no trace of
# WHY (missing firmware? no device? out of range? wrong password?). Capture
# the full L2/L3 picture plus the wifi attempt log every time.
{
    echo "=== ip link ==="; ip link 2>/dev/null; echo
    echo "=== ip addr ==="; ip addr 2>/dev/null; echo
    echo "=== ip route ==="; ip route 2>/dev/null; echo
    echo "=== /sys/class/net ==="; ls -l /sys/class/net 2>/dev/null; echo
    echo "=== /sys/class/ieee80211 (wifi phys) ==="; ls -l /sys/class/ieee80211 2>/dev/null; echo
    echo "=== rfkill ==="; rfkill list 2>/dev/null; echo
    echo "=== nmcli dev status ==="; nmcli dev status 2>/dev/null; echo
    echo "=== nmcli radio ==="; nmcli radio all 2>/dev/null; echo
    echo "=== nmcli con show ==="; nmcli -t -f NAME,UUID,TYPE,DEVICE con show 2>/dev/null; echo
    echo "=== nmcli wifi list (cached scan) ==="; nmcli -t -f SSID,SIGNAL,SECURITY dev wifi list --rescan no 2>/dev/null; echo
    echo "=== /etc/NetworkManager/system-connections ==="; ls -l /etc/NetworkManager/system-connections/ 2>/dev/null
} > "$WORK/network.txt" 2>/dev/null || true
if command -v dmesg >/dev/null 2>&1; then
    dmesg > "$WORK/dmesg.txt" 2>/dev/null || true
    dmesg | grep -iE 'firmware|wlan[0-9]|iwlwifi|brcm|brcmfmac|ath10k|ath11k|rtw_|rtw88|rtw89|mt76|rtl8|rtl9|Direct firmware load' | tail -n 60 > "$WORK/dmesg-net.txt" 2>/dev/null || true
fi
# Staged wifi recipe + onboot's attempt trace (proves wifi.sh ran or not).
cp -a /cdrom/wifi.sh "$WORK/wifi.sh" 2>/dev/null || true
if command -v journalctl >/dev/null 2>&1; then
    journalctl -u NetworkManager --no-pager -n 300 > "$WORK/journal-NetworkManager.txt" 2>/dev/null || true
fi
# Secure Boot state (relevant if the USB fails to boot on UEFI firmware).
if command -v mokutil >/dev/null 2>&1; then
    mokutil --sb-state > "$WORK/mokutil-sb-state.txt" 2>/dev/null || true
fi
if command -v journalctl >/dev/null 2>&1; then
    journalctl -u lsl-firstboot.service -u onboot.service --no-pager -n 500 \
        > "$WORK/journal-lsl.txt" 2>/dev/null || true
fi

# Optional setup-health probes (Nix / Steam overlays). Best-effort: the scripts
# may be absent on older bundles; only run them when present so the diag tarball
# still captures what it can on a wedged first boot.
if [ -x /cdrom/bin/lsl-nix-doctor.sh ]; then
    bash /cdrom/bin/lsl-nix-doctor.sh > "$WORK/nix-doctor.txt" 2>&1 || true
fi
if [ -x /cdrom/bin/lsl-steam-doctor.sh ]; then
    bash /cdrom/bin/lsl-steam-doctor.sh > "$WORK/steam-doctor.txt" 2>&1 || true
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

# Flush to the stick before anyone reboots: FAT + sudden reboot can lose the
# tail of the tarball otherwise (firstboot exits 1 and systemd restarts it).
sync 2>/dev/null || true

if [ "${LSL_DIAG_CDROM_RW:-0}" = "1" ]; then
    mount -o remount,ro /cdrom 2>/dev/null || true
fi

echo "lsl-diag: wrote $ARCHIVE"
if [ "${LSL_DIAG_CDROM_RW:-0}" = "1" ]; then
    echo "lsl-diag: written to the USB (/cdrom) - it survives a reboot; copy it off when convenient."
else
    echo "lsl-diag: copy this off the USB / Windows volume before rebooting."
fi
