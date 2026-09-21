#!/bin/bash
# lsl-usb first-boot reboot approval (user session).
#
# Shown once at the end of firstboot instead of an instant reboot: waits
# for the user to approve the reboot with "Reboot now" / "Reboot later".
# There is NO timer and NO automatic reboot - the root firstboot service
# only reboots after the user touches $FLAG_DIR/reboot-now, and exits
# quietly after $FLAG_DIR/reboot-cancel (the stamped layer activates on
# the next manual boot either way).
#
# Backends: the bundled GTK fallback first (python3-gi ships with Cinnamon;
# zenity only arrives via firstboot apt, so it may still be missing), then
# zenity --question (no --timeout: it must not auto-answer). No backend:
# log loudly and exit 0 without flags (root keeps waiting for approval).
set -u

FLAG_DIR=/run/lsl-firstboot
while [ $# -gt 0 ]; do
    case "$1" in
        --timeout|--timeout=*) # compat: ignored, there is no timer any more
            case "$1" in --timeout) shift 2 ;; *) shift ;; esac
            ;;
        --flag-dir) FLAG_DIR="${2:-/run/lsl-firstboot}"; shift 2 ;;
        --flag-dir=*) FLAG_DIR="${1#--flag-dir=}"; shift ;;
        *) shift ;;
    esac
done

NOW="$FLAG_DIR/reboot-now"
CANCEL="$FLAG_DIR/reboot-cancel"
GTK_PY="${LSL_PROGRESS_GTK:-/usr/local/bin/lsl-progress-gtk.py}"
DIALOG_LOG="${LSL_DIALOG_LOG:-/tmp/lsl-firstboot-dialog.log}"
# Same three-sink logging as lsl-firstboot-progress.sh: /tmp + journal are
# RAM-only; the trace file is pre-created world-writable by the root
# service and flushed to /cdrom/casper/dialog-trace.log (vfat /cdrom is
# root-owned, so this session cannot write the stick directly).
TRACE="${LSL_DIALOG_TRACE:-$FLAG_DIR/dialog-trace.log}"
dialog_log() {
    local ts
    ts="$(date '+%F %T' 2>/dev/null || printf '?')"
    printf '%s %s\n' "$ts" "$*" >>"$DIALOG_LOG" 2>/dev/null || true
    printf '%s %s\n' "$ts" "$*" >>"$TRACE" 2>/dev/null || true
    logger -t lsl-firstboot-reboot "$*" 2>/dev/null || true
}

if command -v python3 >/dev/null 2>&1 && [ -f "$GTK_PY" ] \
    && python3 -c 'import gi' 2>/dev/null; then
    dialog_log "reboot approval starting via gtk fallback (waits for user)"
    python3 "$GTK_PY" --reboot-countdown 0 --flag-dir "$FLAG_DIR" \
        --title="lsl-usb first boot complete" \
        --text="Setup finished and your home folder is backed up. The system will NOT reboot until you say so - reboot now, or later by hand (the new setup still applies on your next boot)." \
        2>>"$DIALOG_LOG"
    # The python dialog writes the flags itself; the exit code is only for
    # the log (root waits for the flags, so a crash here just keeps waiting
    # for a fresh login to re-show the approval dialog).
    dialog_log "reboot approval finished via gtk fallback (rc=$?)"
    exit 0
fi

if command -v zenity >/dev/null 2>&1; then
    dialog_log "reboot approval starting via zenity (waits for user)"
    zenity --question --title="lsl-usb first boot complete" \
        --text="Setup finished and your home folder is backed up.\n\nThe system will NOT reboot until you say so.\nReboot now, or later by hand (the new setup still applies on your next boot)." \
        --ok-label="Reboot now" --cancel-label="Reboot later" \
        2>>"$DIALOG_LOG"
    rc=$?
    case "$rc" in
        0) touch "$NOW" 2>/dev/null || true; dialog_log "user chose Reboot now" ;;
        *) touch "$CANCEL" 2>/dev/null || true; dialog_log "user deferred the reboot (rc=$rc) - no automatic reboot" ;;
    esac
    exit 0
fi

dialog_log "no dialog backend for reboot approval (need python3-gi or zenity); waiting for manual reboot approval"
exit 0
