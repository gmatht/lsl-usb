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
    for l in /cdrom/casper/filesystem_z[0-9][0-9][0-9][0-9]*.squashfs; do
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
            full|limited) return 0 ;;   # limited = captive portal; apt may still work
        esac
        sleep 5
        tries=$((tries + 1))
    done
    return 1
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
    log "WARNING: low RAM ($( (mem_kb / 1024) ) MiB); first-boot apt + guestmount appliance may OOM. >=4 GiB recommended."
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
