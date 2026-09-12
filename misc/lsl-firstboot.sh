#!/bin/bash
# lsl-usb first-boot setup.
#
# Lives inside filesystem_z0_firstboot.squashfs (a ~4 KB layer that contains
# nothing distro-specific - only this script and a systemd unit). It runs once
# via lsl-firstboot.service and:
#   1) waits for the network (wifi.sh from the Windows installer runs first via
#      onboot.service; this loop is the safety net)
#   2) runs /cdrom/bin/uproot --auto-append, which installs the packages listed
#      in /cdrom/bin/squashfs_config.sh inside an overlay chroot and appends a
#      new squashfs layer capturing ONLY the changes - so the installed packages
#      are persisted while nothing in the shipped layer is distro-specific
#   3) stamps /cdrom/casper/lsl-firstboot.done and reboots
#
# The recipe on the FAT partition (/cdrom/bin/squashfs_config.sh) is editable
# from Windows before first boot to change what gets installed.
set -euo pipefail

STAMP="${LSL_FIRSTBOOT_STAMP:-/cdrom/casper/lsl-firstboot.done}"
LOG_DIR="${LSL_FIRSTBOOT_LOG_DIR:-/cdrom/casper/lsl-firstboot-logs}"
STATUS="${LSL_FIRSTBOOT_STATUS:-/run/lsl-firstboot-status}"
UPROOT="${LSL_FIRSTBOOT_UPROOT:-/cdrom/bin/uproot}"
# After this many failed attempts, give up (avoid a boot loop) and leave a
# marker so the failure is visible instead of retrying forever.
MAX_ATTEMPTS="${LSL_FIRSTBOOT_MAX_ATTEMPTS:-5}"
ATTEMPT_FILE="${LSL_FIRSTBOOT_ATTEMPT:-/cdrom/casper/lsl-firstboot.attempts}"
NET_TRIES="${LSL_FIRSTBOOT_NET_TRIES:-60}"
TS="$(date +%Y%m%d%H%M%S)"

set_phase() {
    echo "phase=$*" > "$STATUS"
    # Surface progress to the console (if one is attached) and the journal so a
    # long, unattended first boot can be seen alive without the GUI dialog.
    echo "lsl-firstboot: phase=$*" > /dev/tty1 2>/dev/null || true
    logger -t lsl-firstboot "phase=$*" 2>/dev/null || true
}

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

# Collect diagnostics to a Windows-readable volume on failure so the hardware
# test can inspect a wedged first boot without the USB.
diag() { [ -x /cdrom/bin/lsl-diag.sh ] && bash /cdrom/bin/lsl-diag.sh "${1:-firstboot}" 2>/dev/null || true; }

# Remove any appended layer that fails to list (partial/corrupt from an
# interrupted mksquashfs) so we never boot a broken layer.
lsl_firstboot_cleanup_partial_layers() {
    for l in ${STICK_DIR:-/cdrom}/casper/filesystem.z0.[0-9]*.squashfs ${STICK_DIR:-/cdrom}/casper/filesystem_z[0-9][0-9][0-9][0-9]*.squashfs; do
        [ -e "$l" ] || continue
        if ! unsquashfs -l "$l" >/dev/null 2>&1; then
            echo "Removing corrupt/partial layer: $l" >&2
            rm -f "$l" "${l%.squashfs}.sh"
        fi
    done
}

if [ -e "$STAMP" ]; then
    exit 0
fi

# --- locate the install stick -------------------------------------------
# In iso-scan boots /cdrom is the ISO loop (read-only); the FAT partition
# holding the ISO and our toolkit is usually NOT mounted post-boot. Find it
# by content (the ISO path from the kernel cmdline) and mount it rw at
# /isodevice. Falls back to /cdrom for direct-partition layouts.
STICK_DIR=""
iso_rel="$(sed -n 's/.*iso-scan\/filename=\([^ ]*\).*/\1/p' /proc/cmdline 2>/dev/null | head -n 1)"
try_mount_stick() {
    [ -n "$iso_rel" ] || return 1
    mkdir -p /isodevice 2>/dev/null || true
    if mountpoint -q /isodevice 2>/dev/null; then
        if [ -e "/isodevice$iso_rel" ]; then STICK_DIR=/isodevice; return 0; fi
        umount /isodevice 2>/dev/null || true
    fi
    # Best-effort partition-table re-read (slow/flaky media may not have
    # partition nodes yet). Fails harmlessly when the disk is busy.
    for disk in /dev/sd[a-z] /dev/vd[a-z] /dev/hd[a-z] /dev/nvme[0-9]n[0-9] /dev/mmcblk[0-9]; do
        [ -b "$disk" ] || continue
        blockdev --rereadpt "$disk" 2>/dev/null || true
    done
    for dev in /dev/sd*[0-9] /dev/vd*[0-9] /dev/nvme*n*p* /dev/mmcblk*p* /dev/hd*[0-9]; do
        [ -b "$dev" ] || continue
        mount | grep -q "^$dev " 2>/dev/null && continue
        if mount -o ro "$dev" /isodevice 2>/dev/null; then
            if [ -e "/isodevice$iso_rel" ]; then
                mount -o remount,rw /isodevice 2>/dev/null || true
                STICK_DIR=/isodevice
                return 0
            fi
            umount /isodevice 2>/dev/null || true
        fi
    done
    # Fallback: map each MBR partition via a loop device at its byte offset.
    # In iso-scan boots the live media holds the stick partition open (the
    # ISO loop pins it), so the partition node may be missing and the device
    # busy - a loop mapping sidesteps both without needing /dev/sd*N.
    for disk in /dev/sd[a-z] /dev/vd[a-z] /dev/hd[a-z] /dev/nvme[0-9]n[0-9] /dev/mmcblk[0-9]; do
        [ -b "$disk" ] || continue
        d="${disk##*/}"
        for pdir in /sys/block/$d/$d*; do
            [ -f "$pdir/start" ] || continue
            start="$(cat "$pdir/start" 2>/dev/null || echo 0)"
            [ "$start" -gt 0 ] 2>/dev/null || continue
            loop="$(losetup -f --show -o $((start * 512)) "$disk" 2>/dev/null || true)"
            [ -n "$loop" ] && [ -b "$loop" ] || continue
            if mount -o ro "$loop" /isodevice 2>/dev/null; then
                if [ -e "/isodevice$iso_rel" ]; then
                    mount -o remount,rw /isodevice 2>/dev/null || true
                    STICK_DIR=/isodevice
                    return 0
                fi
                umount /isodevice 2>/dev/null || true
            fi
            losetup -d "$loop" 2>/dev/null || true
        done
    done
    return 1
}
if ! try_mount_stick; then
    # Direct-partition layout? /cdrom itself is the writable stick.
    if mkdir -p /cdrom/casper 2>/dev/null && touch /cdrom/casper/.write-test 2>/dev/null; then
        rm -f /cdrom/casper/.write-test 2>/dev/null || true
        STICK_DIR=/cdrom
    fi
fi
if [ -z "$STICK_DIR" ]; then
    strikes="$(cat /run/lsl-firstboot.strikes 2>/dev/null || echo 0)"
    strikes=$((strikes + 1))
    echo "$strikes" > /run/lsl-firstboot.strikes 2>/dev/null || true
    set_phase "failed - install stick not found (attempt $strikes/3)"
    logger -t lsl-firstboot "FATAL: install stick (ISO $iso_rel) not found on any partition." 2>/dev/null || true
    [ "$strikes" -ge 3 ] && exit 0
    exit 1
fi
rm -f /run/lsl-firstboot.strikes 2>/dev/null || true
# Bring the stick's toolkit into the /cdrom view every script expects:
# bind the stick's casper/ and bin/ over the ISO loop's (the ISO has no
# bin/, and its casper/ holds the same base squashfs we extracted). Writes
# to /cdrom/casper/* and /cdrom/bin/* then land on the stick, while pool/
# and .disk/ stay visible for apt-cdrom. The running overlay already holds
# its lower layers open, so hiding their source paths is safe.
if [ "$STICK_DIR" != /cdrom ]; then
    if mount --bind "$STICK_DIR/casper" /cdrom/casper 2>/dev/null; then
        logger -t lsl-firstboot "Bound stick casper/ over /cdrom/casper." 2>/dev/null || true
    else
        logger -t lsl-firstboot "WARNING: could not bind $STICK_DIR/casper over /cdrom/casper." 2>/dev/null || true
    fi
    # NOTE: bin/ cannot be bound over /cdrom/bin - the ISO loop is
    # read-only, so the target dir cannot be created. UPROOT is re-pointed
    # at the stick below instead (uproot finds squashfs_config.sh beside
    # itself via SCRIPT_DIR, and all its /cdrom/casper paths use the bind).
fi
# Run the toolkit from the stick (the ISO loop has no bin/). Export the
# config path too - uproot prefers $UPROOT_SQUASHFS_CONFIG when set.
[ -z "${LSL_FIRSTBOOT_UPROOT:-}" ] && UPROOT="$STICK_DIR/bin/uproot"
[ -z "${LSL_FIRSTBOOT_SQUASHFS_CONFIG:-}" ] && export UPROOT_SQUASHFS_CONFIG="$STICK_DIR/bin/squashfs_config.sh"
# A previous run may have stamped while bound; the default early check
# above ran before the binds.
if [ -e "$STAMP" ]; then
    exit 0
fi

mount /cdrom -o remount,rw 2>/dev/null || true
# mkdir -p alone is not enough: on a read-only filesystem it succeeds when the
# directory already exists, and tee -a then fails. Verify we can actually write.
if ! mkdir -p "$LOG_DIR" 2>/dev/null || ! touch "$LOG_DIR/.write-test" 2>/dev/null; then
    LOG_DIR=/tmp
fi
rm -f "$LOG_DIR/.write-test" 2>/dev/null || true
LOG="$LOG_DIR/firstboot-${TS}.log"

set_phase starting
log "lsl-firstboot starting."

wait_for_network() {
    local tries=0
    while [ "$tries" -lt "$NET_TRIES" ]; do
        local state
        state="$(nmcli -t -f connectivity g 2>/dev/null || true)"
        case "$state" in
            full) return 0 ;;
            limited)
                # 'limited' usually means a captive portal (or an offline network).
                # apt will fail until the portal is accepted, so warn and probe.
                log "Network is 'limited' (captive portal or no Internet)."
                if captive_portal_detected; then
                    log "CAPTIVE PORTAL detected - open a browser, log in to the portal,"
                    log "then the first boot can proceed. A wired Ethernet connection"
                    log "avoids captive portals; prefer it for first boot."
                else
                    log "Network 'limited' but no portal page found; apt may still fail - prefer wired Ethernet."
                fi
                return 0 ;;
        esac
        sleep 5
        tries=$((tries + 1))
    done
    return 1
}

# Best-effort captive-portal probe. A connectivity check that returns 204 means
# we are truly online; anything else (redirect, login page, or no response)
# suggests a portal (or being offline). Non-fatal either way.
captive_portal_detected() {
    command -v curl >/dev/null 2>&1 || return 1
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' -m 8 'http://connectivitycheck.gstatic.com/generate_204' 2>/dev/null || echo 000)"
    [ "$code" != "204" ]
}

if ! wait_for_network; then
    set_phase 'failed - no network after ~5 minutes, will retry on next boot'
    log "No network after ~5 minutes; will retry on next boot (Restart=on-failure)."
    log "TIP: connect via WIRED Ethernet for first boot; some wireless cards need"
    log "firmware not present in the base image (preload it via /cdrom/firmware)."
    diag "firstboot-no-network"
    exit 1
fi
log "Network up."
mem_kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
if [ "${mem_kb:-0}" -lt 3145728 ] 2>/dev/null; then
    log "WARNING: low RAM ($((mem_kb / 1024)) MiB); first-boot apt + guestmount appliance may OOM. >=4 GiB recommended."
fi
log "Tooling: btrfs-progs=$(command -v mkfs.btrfs >/dev/null 2>&1 && echo yes || echo MISSING), hivex=$(command -v hivexget >/dev/null 2>&1 && echo yes || echo MISSING)"
set_phase 'installing packages and packing layer (first boot)...'

if [ ! -x "$UPROOT" ]; then
    log "$UPROOT missing - nothing to install/persist. Stamping anyway."
    touch "$STAMP"
    sync
    exit 0
fi

log "Running $UPROOT --auto-append (log: $(basename "$LOG"))..."
# Keep the desktop responsive: CPU-low priority, idle I/O class.
rc=0
if command -v ionice >/dev/null 2>&1; then
    nice -n 10 ionice -c 3 bash "$UPROOT" --auto-append >>"$LOG" 2>&1 || rc=$?
else
    nice -n 10 bash "$UPROOT" --auto-append >>"$LOG" 2>&1 || rc=$?
fi
if [ "$rc" -ne 0 ]; then
    attempts="$(cat "$ATTEMPT_FILE" 2>/dev/null || echo 0)"
    attempts=$((attempts + 1))
    echo "$attempts" > "$ATTEMPT_FILE" 2>/dev/null || true
    if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
        set_phase "setup failed after $attempts attempts - see $LOG"
        log "uproot --auto-append FAILED $attempts times; giving up (see $LOG)."
        # Leave a visible marker so the failure isn't silent after reboot.
        touch /cdrom/casper/lsl-firstboot.FAILED 2>/dev/null || true
        {
            echo "lsl-firstboot gave up after $attempts attempts ($(date))."
            echo "See $LOG and the diagnostics tarball (bash /cdrom/bin/lsl-diag.sh)."
            echo "To retry: boot, open a terminal, run: sudo bash /cdrom/bin/uproot --auto-append"
        } > /cdrom/casper/lsl-firstboot.FAILED.reason 2>/dev/null || true
        lsl_firstboot_cleanup_partial_layers
        diag "firstboot-failed"
        touch "$STAMP"   # stop the retry loop; the failure is visible in the log
        sync
        exit 0
    fi
    set_phase "setup failed (attempt $attempts/$MAX_ATTEMPTS) - will retry on next boot"
    log "uproot --auto-append FAILED (see $LOG); will retry on next boot (attempt $attempts/$MAX_ATTEMPTS)."
    diag "firstboot-retry"
    exit 1
fi
rm -f "$ATTEMPT_FILE" 2>/dev/null || true

set_phase 'done - rebooting'
rm -f "$STATUS"
touch "$STAMP"
sync
log "First-boot setup complete; new layer persisted. Rebooting to use it."
diag "firstboot-ok"   # baseline diagnostics for every successful first boot

if [ "${LSL_FIRSTBOOT_REBOOT:-1}" = "1" ]; then
    sleep 5
    sync
    systemctl reboot
else
    log "LSL_FIRSTBOOT_REBOOT=0: reboot manually when ready."
fi
exit 0
