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
#   3) backs up /home to its permanent location (USB: /cdrom/home.sfs via
#      uphome; HDD: btrfs sync), stamps /cdrom/casper/lsl-firstboot.done,
#      and waits for the user to approve the reboot (desktop dialog with
#      Reboot now / Reboot later - no timer, never reboots on its own)
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
case "$NET_TRIES" in ''|*[!0-9]*|0) NET_TRIES=60 ;; esac
TS="$(date +%Y%m%d%H%M%S)"

# --- structured progress -------------------------------------------------
# The desktop progress dialog shows: the full task list, which tasks are
# done, and how far through the current task we are. Single source of truth
# is $STATUS (a small key=value file in /run, world-readable so the user
# session can poll it). KEEP IN SYNC with misc/lsl-progress-gtk.py TASK_ORDER.
LSL_TASKS="stick:Find USB stick|wifi:Stage Wi-Fi|network:Wait for network|flatpak:Install Flatpaks|packages:Install packages|layer:Pack USB layer|home:Back up home|done:Finish & reboot"
LSL_PHASE="starting"
LSL_TASK="stick"
LSL_DONE=""
LSL_PCT=0
LSL_DETAIL=""

# Atomic rewrite of the whole status file (tmp + mv avoids torn reads).
status_write() {
    local tmp="${STATUS}.tmp.$$"
    {
        echo "phase=$LSL_PHASE"
        echo "tasks=$LSL_TASKS"
        echo "task=$LSL_TASK"
        echo "done=$LSL_DONE"
        echo "pct=$LSL_PCT"
        echo "detail=$LSL_DETAIL"
    } > "$tmp" 2>/dev/null && mv -f "$tmp" "$STATUS" 2>/dev/null
    chmod 644 "$STATUS" 2>/dev/null || true
    rm -f "$tmp" 2>/dev/null || true
}

# Read one key from the status file (used by the background uproot monitor
# and after it stops, to re-sync in-memory state).
status_get() {
    sed -n "s/^$1=//p" "$STATUS" 2>/dev/null | tail -n 1
}
status_load() {
    LSL_PHASE="$(status_get phase)"; [ -n "$LSL_PHASE" ] || LSL_PHASE="starting"
    LSL_TASK="$(status_get task)"; [ -n "$LSL_TASK" ] || LSL_TASK="stick"
    LSL_DONE="$(status_get done)"
    LSL_PCT="$(status_get pct)"; [ -n "$LSL_PCT" ] || LSL_PCT=0
    LSL_DETAIL="$(status_get detail)"
}

task_begin() {
    LSL_TASK="$1"
    LSL_PCT=0
    [ $# -ge 2 ] && LSL_DETAIL="$2"
    status_write
}
task_progress() {
    # task_progress PCT [DETAIL] — clamp 0..100, keep current task.
    local p="$1"
    case "$p" in ''|*[!0-9]*) p=0 ;; esac
    [ "$p" -gt 100 ] 2>/dev/null && p=100
    [ "$p" -lt 0 ] 2>/dev/null && p=0
    LSL_PCT="$p"
    [ $# -ge 2 ] && LSL_DETAIL="$2"
    status_write
}
task_done() {
    # Mark a task id done (idempotent) and snap its bar to 100 if current.
    local id="$1"
    case ",$LSL_DONE," in
        *",$id,"*) ;;
        *) LSL_DONE="${LSL_DONE:+$LSL_DONE,}$id" ;;
    esac
    [ "$LSL_TASK" = "$id" ] && LSL_PCT=100
    status_write
}
tasks_init() {
    LSL_PHASE="starting"
    LSL_TASK="stick"
    LSL_DONE=""
    LSL_PCT=0
    LSL_DETAIL="Locating USB stick…"
    status_write
}

set_phase() {
    LSL_PHASE="$*"
    status_write
    # Surface progress to the console (if one is attached) and the journal so a
    # long, unattended first boot can be seen alive without the GUI dialog.
    echo "lsl-firstboot: phase=$*" > /dev/tty1 2>/dev/null || true
    logger -t lsl-firstboot "phase=$*" 2>/dev/null || true
}

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

# Collect diagnostics to a Windows-readable volume on failure so the hardware
# test can inspect a wedged first boot without the USB.
# Gate on -r, not -x: casper mounts the FAT stick without exec bits, so -x
# is false (and direct exec fails) even though `bash script` works fine.
# Without this, no diagnostics tarball is ever written on FAT sticks.
diag() {
    # Tee the "wrote <path>" line into our own log: with stderr silenced a
    # lost tarball (RAM fallback, failed remount) is otherwise invisible and
    # undebuggable from Windows after a reboot.
    if [ -r /cdrom/bin/lsl-diag.sh ]; then
        bash /cdrom/bin/lsl-diag.sh "${1:-firstboot}" 2>/dev/null | tee -a "$LOG" 2>/dev/null || true
    fi
}

# Consecutive no-network boots (own counter: being offline is common and
# transient, so it must NOT consume the uproot-failure budget, but it must
# NOT retry silently forever either). The marker + reason drive the desktop
# error dialog (XDG autostart + immediate notify); no stamp is written so a
# later boot with working network resumes automatically.
NET_FAIL_FILE="${LSL_FIRSTBOOT_NET_FAIL:-/cdrom/casper/lsl-firstboot.no-network}"
FAILED_MARKER=/cdrom/casper/lsl-firstboot.FAILED
FAILED_REASON=/cdrom/casper/lsl-firstboot.FAILED.reason

# Best-effort: show the failure dialog in the CURRENT desktop session(s) too
# (the XDG autostart copy only fires at next login). Session truth comes
# from loginctl - never a hardcoded DISPLAY=:0 (wrong on :1, multi-seat,
# and Wayland, which has no XAUTHORITY at all) and never /dev/console
# ownership (root-owned on systemd, so that test silently never fired).
# Every graphical session is notified (deduplicated by user+display, so a
# twice-logged-in user sees one dialog, not two); single-seat behaves
# exactly like first-match. The notifier picks its own dialog backend
# (zenity or the bundled GTK fallback), so this function gates on nothing
# but the presence of a graphical session.
# Never fails the service: every fallible step degrades to silent return.
notify_desktop_now() {
    # Optional: notify_desktop_now SCRIPT [ARGS...] runs SCRIPT (default: the
    # firstboot-failed notifier) instead. The reboot approval reuses this to
    # show its approval dialog; the default keeps every existing caller.
    local script="${1:-/usr/local/bin/lsl-firstboot-failed.sh}"
    if [ $# -gt 0 ]; then shift; fi
    # Re-quote for the nested su -c shell: interpolating "$@" inside the
    # outer "..." would join it into ONE word when su re-parses the -c
    # string, so escape every word up front (MUST stay correct for paths
    # with spaces).
    local inner arg
    printf -v inner 'bash %q' "$script"
    for arg in "$@"; do printf -v inner '%s %q' "$inner" "$arg"; done
    command -v loginctl >/dev/null 2>&1 || return 0
    local s dtype user disp rdir home key seen
    seen=" "
    for s in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
        dtype="$(loginctl show-session -p Type --value "$s" 2>/dev/null || true)"
        case "$dtype" in x11|wayland) ;; *) continue ;; esac
        user="$(loginctl show-session -p Name --value "$s" 2>/dev/null || true)"
        [ -n "$user" ] && [ "$user" != root ] || continue
        home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"
        rdir="/run/user/$(id -u "$user" 2>/dev/null || echo x)"
        if [ "$dtype" = wayland ]; then
            # No XAUTHORITY/DISPLAY on Wayland: socket under the runtime dir
            # (wayland-0 is the compositor default; the callee still decides).
            # DISPLAY is emptied so GTK never tries a stale X11 display first.
            key=" $user|wayland:${WAYLAND_DISPLAY:-wayland-0} "
            case "$seen" in *"$key"*) continue ;; esac
            seen="$seen$key"
            su -s /bin/bash "$user" -c "DISPLAY= XDG_RUNTIME_DIR='$rdir' WAYLAND_DISPLAY='${WAYLAND_DISPLAY:-wayland-0}' $inner" 2>>"${LOG:-/dev/null}" || { log "notify_desktop_now: su to $user failed (wayland); see above"; true; }
        else
            disp="$(loginctl show-session -p Display --value "$s" 2>/dev/null || true)"
            disp="${disp:-:0}"
            key=" $user|x11:$disp "
            case "$seen" in *"$key"*) continue ;; esac
            seen="$seen$key"
            # Live ISO: Xorg runs as root with the cookie under /var/run/lightdm/root/
            xauth="/var/run/lightdm/root/$disp"
            [ -r "$xauth" ] || xauth="$home/.Xauthority"
            log "notify_desktop_now: trying $user on $disp (XAUTHORITY=$xauth)"
            if su -s /bin/bash "$user" -c "DISPLAY='$disp' XDG_RUNTIME_DIR='$rdir' XAUTHORITY='$xauth' $inner" 2>>"${LOG:-/dev/null}"; then
                log "notify_desktop_now: $user on $disp OK"
            else
                log "notify_desktop_now: su to $user failed (x11 $disp); see above"
            fi
        fi
    done
    return 0
}

# Final home backup: persist the merged /home to its permanent location
# before the reboot (USB: bake into /cdrom/home.sfs via the stick's uphome;
# HDD: btrfs sync via the same tool). Best-effort: the new layer is already
# built, so a flush failure only logs loudly (the idle flush daemon retries
# later) instead of failing firstboot. Never fails the service.
flush_home_final() {
    task_begin home "Backing up /home to its permanent location…"
    local uphome="" cand
    for cand in "${STICK_DIR:-/cdrom}/bin/uphome" /cdrom/bin/uphome; do
        # Gate on -r, not -x: casper mounts FAT without exec bits (same as
        # everywhere else in this script); uphome is always run via bash.
        if [ -r "$cand" ]; then uphome="$cand"; break; fi
    done
    if [ -z "$uphome" ]; then
        log "No uphome on the stick - skipping final home flush."
        task_done home
        return 0
    fi
    log "Flushing /home to its permanent location ($uphome)..."
    if bash "$uphome" >>"$LOG" 2>&1; then
        log "Final home flush OK."
    else
        log "WARNING: final home flush failed (continuing - the idle flush daemon retries; see $LOG)."
    fi
    task_done home
    return 0
}

# End-of-firstboot reboot approval: the service NEVER reboots on its own.
# A dialog in each graphical session offers "Reboot now" / "Reboot later"
# and this function waits indefinitely until the user chooses. Reboot later
# is safe - the stamp already exists, so the new layer is picked up on the
# next manual boot anyway.
# Env: LSL_FIRSTBOOT_REBOOT (1/0, default 1),
# LSL_FIRSTBOOT_REBOOT_TIMEOUT (compat only: 0 = reboot immediately without
# asking; any other value waits for approval - there is no timer),
# LSL_FIRSTBOOT_FLAG_DIR (default /run/lsl-firstboot - tmpfs, so flags
# vanish on reboot).
schedule_reboot_on_approval() {
    if [ "${LSL_FIRSTBOOT_REBOOT:-1}" != "1" ]; then
        log "LSL_FIRSTBOOT_REBOOT=0: reboot manually when ready."
        return 0
    fi
    local timeout="${LSL_FIRSTBOOT_REBOOT_TIMEOUT:-x}"
    local flagdir="${LSL_FIRSTBOOT_FLAG_DIR:-/run/lsl-firstboot}"
    if [ "$timeout" = "0" ]; then
        sync
        systemctl reboot
        return $?
    fi
    # World-writable so the unprivileged desktop dialog can record the
    # user's choice; sticky bit so users cannot remove each other's flags.
    mkdir -p "$flagdir" 2>/dev/null || true
    chmod 1777 "$flagdir" 2>/dev/null || true
    rm -f "$flagdir/reboot-cancel" "$flagdir/reboot-now" "$flagdir/deadline" 2>/dev/null || true
    log "Setup complete. Waiting for you to approve the reboot - Reboot now or Reboot later in the desktop dialog…"
    # Dialogs run per-session in the background; this loop is the reboot
    # authority (the user session cannot reboot the machine itself).
    # No deadline and no timeout: a fresh login re-shows the same approval
    # dialog (see the reboot-approval branch in lsl-firstboot-progress.sh).
    notify_desktop_now /usr/local/bin/lsl-firstboot-reboot.sh --flag-dir "$flagdir" </dev/null >/dev/null 2>&1 &
    while true; do
        if [ -e "$flagdir/reboot-cancel" ]; then
            log "Reboot deferred by the user; the new layer activates on the next boot."
            set_phase 'done - reboot deferred by user'
            return 0
        fi
        if [ -e "$flagdir/reboot-now" ]; then
            log "Reboot approved by the user."
            break
        fi
        sleep 2
        task_progress 100 "Waiting for reboot approval — Reboot now or Reboot later in the dialog…"
    done
    set_phase 'done - rebooting'
    sync
    systemctl reboot
}

# Flush the RAM-side dialog/boot telemetry to the stick. /tmp, the journal
# and /run die at reboot; the dialog trace is the only persistent record of
# whether/when the desktop dialog ran (lost on 2026-09-15/16 AND
# 2026-09-21 - nobody could answer "why no progress dialog" because every
# log lived in RAM). Appends, never truncates: boots accumulate.
flush_dialog_telemetry() {
    local stick="${STICK_DIR:-/cdrom}" fd="${LSL_FIRSTBOOT_FLAG_DIR:-/run/lsl-firstboot}" f
    mount "$stick" -o remount,rw 2>/dev/null || true
    for f in dialog-trace.log boot-times.log; do
        if [ -s "$fd/$f" ]; then
            cat "$fd/$f" >>"$stick/casper/$f" 2>/dev/null || true
        fi
    done
    sync 2>/dev/null || true
    return 0
}

# Drop COMPLETE appended layers from previous attempts so the next retry
# boots clean (base+z0 only) and uproot regenerates one self-contained
# layer instead of stacking. Only runs while the stamp is missing, i.e. no
# successful firstboot has ever completed, so there is no working setup
# whose layers we could destroy - the content is regenerated
# deterministically from squashfs_config.sh on the next attempt. Base z0,
# home.sfs and .sh companions of kept files are never touched. (Unlinking
# mid-session is safe: the running overlay already holds the loop mounts
# open; only the next boot's casper glob is affected.)
lsl_firstboot_drop_prior_appended_layers() {
    local stick="${STICK_DIR:-/cdrom}" l n=0
    for l in "$stick"/casper/filesystem.z0.[0-9]*.squashfs "$stick"/casper/filesystem_z[0-9][0-9][0-9][0-9]*.squashfs; do
        [ -e "$l" ] || continue
        case "$(basename "$l")" in
            filesystem.z0.squashfs|filesystem_z0_firstboot.squashfs) continue ;;
        esac
        rm -f "$l" "${l%.squashfs}.sh" 2>/dev/null || true
        n=$((n + 1))
    done
    [ "$n" -gt 0 ] && log "Dropped $n prior-attempt appended layer(s); next boot regenerates a fresh one."
}

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

# --- unconditional: ensure onboot.service is installed ---
# The live ISO's z0 layer may predate onboot.service. Install it from the
# FAT partition so /cdrom/onboot.sh (including wifi.sh) runs every boot.
# Idempotent: harmless if already present.
if [ -r /cdrom/systemd/onboot.service ] && [ ! -f /etc/systemd/system/onboot.service ]; then
    cp /cdrom/systemd/onboot.service /etc/systemd/system/onboot.service 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable onboot.service 2>/dev/null || true
fi

# --- unconditional: stage wifi profiles ---
# If the user re-ran lslsetup.exe to update wifi.sh, we must stage the
# new profiles even when the stamp exists. onboot.service also runs
# wifi.sh, but firstboot may start before onboot finishes on old z0 layers.
if [ -r /cdrom/wifi.sh ]; then
    bash /cdrom/wifi.sh >/dev/null 2>&1 || true
fi

if [ -e "$STAMP" ]; then
    exit 0
fi

# Start clean: a previous run may have left FAILED / .no-network markers.
# Remove them now so a successful run this boot doesn't pop a phantom
# error dialog from stale state.
rm -f "$FAILED_MARKER" "$FAILED_REASON" "$NET_FAIL_FILE" 2>/dev/null || true
rm -f /run/lsl-firstboot.no-network 2>/dev/null || true

# World-writable flag dir + telemetry files, BEFORE the desktop dialog can
# start: the unprivileged XDG-autostart dialog (and lsl-boot-time.sh
# --desktop) record their trace in /run because vfat /cdrom is root-owned
# (fmask applies to every file, pre-created or not). /tmp and the journal
# are RAM-only and already cost two post-mortems. Flushed to the stick at
# the finale by flush_dialog_telemetry; lsl-diag.sh captures them in every
# tarball. onboot.sh does the same on every boot; both are idempotent.
flagdir="${LSL_FIRSTBOOT_FLAG_DIR:-/run/lsl-firstboot}"
mkdir -p "$flagdir" 2>/dev/null || true
chmod 1777 "$flagdir" 2>/dev/null || true
for _tf in dialog-trace.log boot-times.log; do
    : >>"$flagdir/$_tf" 2>/dev/null || true
    chmod 666 "$flagdir/$_tf" 2>/dev/null || true
done

# --- locate the install stick -------------------------------------------
# In iso-scan boots /cdrom is the ISO loop (read-only); the FAT partition
# holding the ISO and our toolkit is usually NOT mounted post-boot. Find it
# by content (the ISO path from the kernel cmdline) and mount it rw at
# /isodevice. Falls back to /cdrom for direct-partition layouts.
STICK_DIR=""
# `|| true`: without /proc/cmdline (MSYS2, unmounted /proc) sed fails and
# `set -euo pipefail` would kill the script here with no log line at all.
iso_rel="$(sed -n 's/.*iso-scan\/filename=\([^ ]*\).*/\1/p' /proc/cmdline 2>/dev/null | head -n 1 || true)"
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
if [ -n "${LSL_FIRSTBOOT_STICK:-}" ]; then
    # Test seam (bats): point the stick at a scratch dir instead of
    # scanning partitions - CI runners are non-root and cannot mount or
    # create /cdrom. Production never sets this; behavior unchanged.
    STICK_DIR="$LSL_FIRSTBOOT_STICK"
elif ! try_mount_stick; then
    # Direct-partition layout? /cdrom itself is the stick - but casper
    # mounts live media read-only (ISO habit), so remount rw first: vfat
    # remounts fine, an ISO loop refuses and we fall through correctly.
    mount /cdrom -o remount,rw 2>/dev/null || true
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
task_done stick
task_begin wifi "Locating USB stick… done"
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

tasks_init
log "lsl-firstboot starting."

wait_for_network() {
    local tries=0
    task_begin network "Waiting for network (attempt 1/$NET_TRIES)…"
    while [ "$tries" -lt "$NET_TRIES" ]; do
        task_progress $((tries * 100 / NET_TRIES)) "Waiting for network (attempt $((tries + 1))/$NET_TRIES)…"
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

# Fallback wifi staging: onboot.service runs wifi.sh every boot, but on
# old z0 layers (or if onboot hasn't started yet) we stage here too so
# NM has profiles before we poll for network.
task_begin wifi "Staging Wi-Fi profiles…"
if [ -r /cdrom/wifi.sh ]; then
    log "Staging wifi profiles from /cdrom/wifi.sh ..."
    bash /cdrom/wifi.sh >>"$LOG" 2>&1 || log "wifi.sh exited non-zero (continuing)"
    task_progress 100 "Wi-Fi profiles staged"
else
    task_progress 100 "No wifi.sh on stick — skipping"
    log "No /cdrom/wifi.sh; skipping wifi staging." 
fi
task_done wifi
task_begin network "Waiting for network…"

if ! wait_for_network; then
    # Bounded-loud, not infinite-silent: count (stick + /run mirror, max, so
    # a stale stick copy cannot rewind it).  No-network is transient, so it
    # is NOT an actionable failure: no FAILED marker, no error dialog, just
    # retry on the next boot.
    n_stick="$(cat "$NET_FAIL_FILE" 2>/dev/null || echo 0)"
    n_run="$(cat /run/lsl-firstboot.no-network 2>/dev/null || echo 0)"
    net_fail="$n_stick"
    [ "$n_run" -gt "$net_fail" ] 2>/dev/null && net_fail="$n_run"
    net_fail=$((net_fail + 1))
    echo "$net_fail" > "$NET_FAIL_FILE" 2>/dev/null || true
    echo "$net_fail" > /run/lsl-firstboot.no-network 2>/dev/null || true
    set_phase "failed - no network (attempt $net_fail), will retry on next boot"
    log "No network after ~5 minutes (attempt $net_fail); will retry on next boot."
    log "TIP: connect via WIRED Ethernet for first boot; some wireless cards need"
    log "firmware not present in the base image (preload it via /cdrom/firmware)."
    sync 2>/dev/null || true
    exit 1
fi
task_progress 100 "Network up"
task_done network
task_begin flatpak "Installing Flatpaks…"
log "Network up."
mem_kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
if [ "${mem_kb:-0}" -lt 3145728 ] 2>/dev/null; then
    log "WARNING: low RAM ($((mem_kb / 1024)) MiB); first-boot apt + guestmount appliance may OOM. >=4 GiB recommended."
fi
log "Tooling: btrfs-progs=$(command -v mkfs.btrfs >/dev/null 2>&1 && echo yes || echo MISSING), hivex=$(command -v hivexget >/dev/null 2>&1 && echo yes || echo MISSING)"
set_phase 'installing packages and packing layer (first boot)...'

# Flatpaks live in a FAT-hosted installation (direct files via the FUSE
# view), NEVER in the squashfs layer: baking multi-GB apps into one file
# would hit the FAT32 4 GiB ceiling and bloat every first boot with
# downloads. Runs host-side (not in the uproot chroot) so the overlay
# upper stays lean. Skips loud (never bakes) when FUSE won't come up.
install_flatpaks_fat() {
    local ids id inst _flat_total _flat_i
    command -v flatpak >/dev/null 2>&1 || { log "flatpak CLI missing - skipping flatpak installs."; return 0; }
    [ -d /cdrom/flatpaks ] || return 0
    ids="$(for ref in /cdrom/flatpaks/*.flatpakref; do [ -e "$ref" ] || continue; basename "$ref" .flatpakref; done)"
    [ -n "$ids" ] || { log "No flatpak refs staged in /cdrom/flatpaks - skipping."; return 0; }
    # Builder pre-installed the apps straight into /cdrom/flatpak (fast
    # builder network, direct files): nothing to install, just publish the
    # installation definition so this boot (and onboot, every boot) sees it.
    if [ -d /cdrom/flatpak/repo ]; then
        log "Flatpaks preinstalled by the builder in /cdrom/flatpak - mount-only, no install."
        mkdir -p /etc/flatpak/installations.d 2>/dev/null || true
        { echo '[Installation "lsl-fat"]'; echo "Path=/run/lsl-fat/flatpak"; echo "DisplayName=LSL USB (FAT)"; } > /etc/flatpak/installations.d/lsl-fat.conf 2>/dev/null || true
        return 0
    fi
    set_phase 'installing flatpaks onto the stick (files, not the layer)...'
    log "Installing flatpaks into the FAT-hosted installation: $ids"
    if [ ! -r /cdrom/bin/lsl-flatpak-fat.sh ] || ! bash /cdrom/bin/lsl-flatpak-fat.sh mount; then
        log "WARNING: FUSE view unavailable - SKIPPING flatpaks (refusing to bake GBs into the 4 GiB-capped layer). Install later with: bash /cdrom/bin/lsl-flatpak-fat.sh install <app>"
        return 0
    fi
    inst=/run/lsl-fat/flatpak
    task_progress 10 "Flatpak view mounted"
    mkdir -p "$inst" 2>/dev/null || true
    # System-wide named installation pointing at the FUSE mount (this file
    # lands in the layer via the overlay upper - tiny; the CONTENT is FAT).
    mkdir -p /etc/flatpak/installations.d 2>/dev/null || true
    { echo '[Installation "lsl-fat"]'; echo "Path=$inst"; echo "DisplayName=LSL USB (FAT)"; } > /etc/flatpak/installations.d/lsl-fat.conf 2>/dev/null || true
    # Per-app progress so the dialog can show how far through this task we are.
    _flat_total=0; for id in $ids; do _flat_total=$((_flat_total + 1)); done
    _flat_i=0
    if [ -d /cdrom/flatpaks/usb ]; then
        for id in $ids; do
            _flat_i=$((_flat_i + 1))
            task_progress $((10 + _flat_i * 80 / (_flat_total + 1))) "Flatpak $_flat_i/$_flat_total: $id"
            log "  sideload $id (offline, from /cdrom/flatpaks/usb)"
            flatpak --installation=lsl-fat install --noninteractive --assumeyes --sideload-repo=/cdrom/flatpaks/usb "$id" >>"$LOG" 2>&1 \
                || log "WARNING: sideload of $id failed (continuing with the rest)"
        done
    else
        log "No /cdrom/flatpaks/usb sideload repo - downloading from flathub (bytes land on FAT, not the layer)."
        flatpak --installation=lsl-fat remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo >>"$LOG" 2>&1 || true
        for id in $ids; do
            _flat_i=$((_flat_i + 1))
            task_progress $((10 + _flat_i * 80 / (_flat_total + 1))) "Flatpak $_flat_i/$_flat_total: $id"
            log "  download $id from flathub"
            flatpak --installation=lsl-fat install --noninteractive --assumeyes flathub "$id" >>"$LOG" 2>&1 \
                || log "WARNING: install of $id failed (continuing with the rest)"
        done
    fi
    task_progress 100 "Flatpaks done"
    log "Flatpak FAT install done (installation 'lsl-fat', backing /cdrom/flatpak)."
}

# Background progress monitor: while uproot runs, the main script is blocked
# waiting, so this is the sole STATUS writer. It tails the firstboot log for
# LSL_STEP n/m + LSL_TASK markers (emitted by uproot / squashfs_config.sh)
# and mksquashfs percentages. Never fails the service.
# $1 is uproot's pid: tail --pid exits by itself when uproot finishes, so
# this monitor (pipe included) can never outlive the install it follows -
# no kill needed, and no orphaned tail can wedge a test runner's capture.
monitor_uproot_progress() {
    tail --pid="$1" -n 0 -F "$LOG" 2>/dev/null | while IFS= read -r line; do
        case "$line" in
            *"LSL_TASK layer"*)
                task_done packages 2>/dev/null || true
                task_begin layer "Packing USB layer…" 2>/dev/null || true
                ;;
            *"LSL_STEP "*)
                _rest="${line##*LSL_STEP }"
                _frac="${_rest%% *}"
                _label="${_rest#* }"
                [ -n "$_label" ] || _label="Installing packages…"
                _n="${_frac%%/*}"; _m="${_frac##*/}"
                case "$_n$_m" in ''|*[!0-9]*) continue ;; esac
                [ "$_m" -gt 0 ] 2>/dev/null || continue
                [ "$LSL_TASK" = "packages" ] || task_begin packages "$_label" 2>/dev/null || true
                task_progress $((_n * 100 / _m)) "$_label" 2>/dev/null || true
                ;;
            *%*)
                case "$line" in
                    *mksquashfs*|*squashfs*|*"Writing new layer"*) ;;
                    *) [ "$LSL_TASK" = "layer" ] || continue ;;
                esac
                _pct="$(printf '%s' "$line" | grep -o '[0-9][0-9]*%' | tail -n 1 | tr -d '%')"
                case "$_pct" in ''|*[!0-9]*) continue ;; esac
                task_progress "$_pct" "Compressing layer (${_pct}%)…" 2>/dev/null || true
                ;;
        esac
    done 2>/dev/null || true
}

if [ ! -r "$UPROOT" ]; then
    log "$UPROOT missing - nothing to install/persist. Stamping anyway."
    task_done flatpak 2>/dev/null || true
    task_done packages 2>/dev/null || true
    task_done layer 2>/dev/null || true
    task_begin done "Nothing to install — finishing…" 2>/dev/null || true
    task_progress 100 "Done" 2>/dev/null || true
    touch "$STAMP"
    sync
    flush_dialog_telemetry
    exit 0
fi

install_flatpaks_fat
task_done flatpak
task_begin packages "Starting package install…"

# Every attempt starts with a sane chain: drop corrupt/partial layers from
# an interrupted mksquashfs BEFORE uproot runs, so casper never stacks a
# broken layer on this boot. (The give-up path also calls this; healthy
# layers are never touched - retries must stack, not replace, because the
# retry boot already sees prior layers' packages as installed and a fresh
# layer is incremental against that view.)
lsl_firstboot_cleanup_partial_layers

log "Running $UPROOT --auto-append (log: $(basename "$LOG"))..."
# Keep the desktop responsive: CPU-low priority, idle I/O class.
# The monitor feeds the dialog while uproot runs; re-sync state after.
# Detached stdio: under test runners that capture via $() (bats < 1.5),
# any background child inheriting stdout would hold the capture pipe open
# forever - and a lingering tail would do exactly that. The monitor only
# ever writes the status file, never the terminal.
rc=0
if command -v ionice >/dev/null 2>&1; then
    nice -n 10 ionice -c 3 bash "$UPROOT" --auto-append >>"$LOG" 2>&1 &
else
    nice -n 10 bash "$UPROOT" --auto-append >>"$LOG" 2>&1 &
fi
uproot_pid=$!
# Detached stdio: under test runners that capture via $() (bats < 1.5),
# any background child inheriting stdout would hold the capture pipe open
# forever - and the monitor only ever writes the status file, never the
# terminal.
monitor_uproot_progress "$uproot_pid" </dev/null >/dev/null 2>&1 &
monitor_pid=$!
wait "$uproot_pid" || rc=$?
wait "$monitor_pid" 2>/dev/null || true
status_load
if [ "$rc" -ne 0 ]; then
    giveup_why=""
    if [ "$rc" -eq 2 ]; then
        # Deterministic refusal (uproot exit 2: over the FAT32 4 GiB limit or
        # out of space). Retrying cannot help, so skip the transient budget
        # and go straight to FAILED + stop.
        giveup_why="refused deterministically (over the FAT32 4 GiB limit or out of space)"
        log "uproot $giveup_why - not retrying (see $LOG)."
        attempts=$MAX_ATTEMPTS
    else
    # The counter must stay bounded even when the stick is unreachable:
    # if its write fails, every retry reads back a stale value and the
    # loop runs forever (observed: endless "attempt 1/5" on read-only
    # /cdrom/casper). Mirror to /run (always writable tmpfs); the stick
    # copy stays the cross-boot store, /run is the within-boot fallback.
    # Take the max so a stale-but-readable stick copy cannot rewind it.
    a_stick="$(cat "$ATTEMPT_FILE" 2>/dev/null || echo 0)"
    a_run="$(cat /run/lsl-firstboot.attempts 2>/dev/null || echo 0)"
    attempts="$a_stick"
    [ "$a_run" -gt "$attempts" ] 2>/dev/null && attempts="$a_run"
    attempts=$((attempts + 1))
    echo "$attempts" > "$ATTEMPT_FILE" 2>/dev/null || true
    echo "$attempts" > /run/lsl-firstboot.attempts 2>/dev/null || true
    fi
    if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
        task_progress "$LSL_PCT" "Setup failed - see $LOG" 2>/dev/null || true
        set_phase "setup failed ${giveup_why:-after $attempts attempts} - see $LOG"
        log "uproot --auto-append ${giveup_why:-FAILED $attempts times}; giving up (see $LOG)."
        # Leave a visible marker so the failure isn't silent after reboot.
        touch /cdrom/casper/lsl-firstboot.FAILED 2>/dev/null || true
        {
            if [ -n "$giveup_why" ]; then
                echo "lsl-firstboot gave up: $giveup_why ($(date))."
            else
                echo "lsl-firstboot gave up after $attempts attempts ($(date))."
            fi
            echo "See $LOG and the diagnostics tarball (bash /cdrom/bin/lsl-diag.sh)."
            echo "To retry: boot, open a terminal, run: sudo bash /cdrom/bin/uproot --auto-append"
        } > /cdrom/casper/lsl-firstboot.FAILED.reason 2>/dev/null || true
        lsl_firstboot_cleanup_partial_layers
        diag "firstboot-failed"
        flush_dialog_telemetry
        touch "$STAMP"   # stop the retry loop; the failure is visible in the log
        sync
        exit 0
    fi
    set_phase "setup failed (attempt $attempts/$MAX_ATTEMPTS) - will retry on next boot"
    log "uproot --auto-append FAILED (see $LOG); will retry on next boot (attempt $attempts/$MAX_ATTEMPTS)."
    # Retry boots clean: uproot writes a layer only on success, so anything
    # stacked now is a leftover - drop it so the next attempt regenerates
    # one complete layer instead of stacking an incremental one on top.
    lsl_firstboot_drop_prior_appended_layers
    diag "firstboot-retry"
    exit 1
fi
rm -f "$ATTEMPT_FILE" 2>/dev/null || true
# Success clears the failure state: no stale Error dialog, no stale
# no-network count (a later offline boot starts its own count).
rm -f "$FAILED_MARKER" "$FAILED_REASON" "$NET_FAIL_FILE" 2>/dev/null || true
rm -f /run/lsl-firstboot.no-network 2>/dev/null || true

# Reap layers earlier SUCCESSFUL firstboots orphaned. uproot already prunes as
# part of writing a layer; this is the belt-and-braces pass for a boot that
# reaches the finale. The retry-path cleanup (lsl_firstboot_drop_prior_appended
# _layers) only fires while the stamp is missing, so on a stick where every
# attempt succeeded nothing ever pruned: this one had 5x761MB (3.6 GB) of
# layers, 4 of them inert because menu.lst named only the newest.
#
# Same fail-safe rules as uproot's prune_superseded_layers: delete nothing
# unless we positively resolve the layer the boot config names, and never
# remove that layer, its dot-progenitors, or the base layers.
lsl_firstboot_prune_orphan_layers() {
    local stick="${STICK_DIR:-/cdrom}" active b l n=0
    active="$(grep -o 'layerfs-path=[^ ]*' "$stick/menu.lst" 2>/dev/null | head -n1)"
    active="${active#layerfs-path=}"
    case "$active" in /cdrom/*) active="$stick/${active#/cdrom/}" ;; esac
    if [ -z "$active" ] || [ ! -f "$active" ]; then
        log "Layer prune skipped: boot config names no resolvable layer."
        return 0
    fi
    for l in "$stick"/casper/filesystem.z0.[0-9]*.squashfs; do
        [ -e "$l" ] || continue
        b="$(basename "$l")"
        case "$b" in
            filesystem.z0.squashfs|filesystem_z0_firstboot.squashfs) continue ;;
        esac
        [ "$b" = "$(basename "$active")" ] && continue
        case "${b%.squashfs}" in
            "$(basename "${active%.squashfs}")".*) continue ;;
        esac
        if rm -f "$l" "${l%.squashfs}.sh" 2>/dev/null; then
            n=$((n + 1)); log "Pruned orphaned layer: $b"
        fi
    done
    # if/then, not `[ ... ] && log`: under `set -e` the && form returns 1 when
    # n=0 and would abort the run.
    if [ "$n" -gt 0 ]; then
        log "Pruned $n orphaned layer(s) left by earlier successful firstboots."
    fi
    return 0
}
lsl_firstboot_prune_orphan_layers

task_done packages
task_done layer
flush_home_final
task_begin done "Setup complete — waiting for reboot approval…"
task_progress 100 "Done — waiting for reboot approval…"
set_phase 'done - waiting for reboot approval'
rm -f "$STATUS"
touch "$STAMP"
sync
log "First-boot setup complete; new layer persisted. Waiting for reboot approval to use it."
flush_dialog_telemetry   # before diag so the flushed files are also in the tarball
diag "firstboot-ok"   # baseline diagnostics for every successful first boot

schedule_reboot_on_approval
exit 0
