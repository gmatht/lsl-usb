#!/bin/bash
# lsl-usb first-boot reboot timer (user session).
#
# Shown once at the end of firstboot instead of an instant reboot: a live
# countdown (default 10 minutes) with "Reboot now" / "Cancel automatic
# reboot". Records the choice as $FLAG_DIR/reboot-now or reboot-cancel; the
# root firstboot service owns the actual reboot and fires on timeout, so a
# timeout (or a dialog that never appears) simply proceeds.
#
# Backends: the bundled GTK fallback first (python3-gi ships with Cinnamon;
# zenity only arrives via firstboot apt, so it may still be missing), then
# zenity --question --timeout. No backend: log loudly and exit 0 (proceed).
set -u

TIMEOUT=600
FLAG_DIR=/run/lsl-firstboot
while [ $# -gt 0 ]; do
    case "$1" in
        --timeout) TIMEOUT="${2:-600}"; shift 2 ;;
        --timeout=*) TIMEOUT="${1#--timeout=}"; shift ;;
        --flag-dir) FLAG_DIR="${2:-/run/lsl-firstboot}"; shift 2 ;;
        --flag-dir=*) FLAG_DIR="${1#--flag-dir=}"; shift ;;
        *) shift ;;
    esac
done
case "$TIMEOUT" in ''|*[!0-9]*|0) TIMEOUT=600 ;; esac

NOW="$FLAG_DIR/reboot-now"
CANCEL="$FLAG_DIR/reboot-cancel"
GTK_PY="${LSL_PROGRESS_GTK:-/usr/local/bin/lsl-progress-gtk.py}"
DIALOG_LOG="${LSL_DIALOG_LOG:-/tmp/lsl-firstboot-dialog.log}"
dialog_log() {
    printf '%s %s\n' "$(date '+%F %T' 2>/dev/null || printf '?')" "$*" >>"$DIALOG_LOG" 2>/dev/null || true
    logger -t lsl-firstboot-reboot "$*" 2>/dev/null || true
}

if command -v python3 >/dev/null 2>&1 && [ -f "$GTK_PY" ] \
    && python3 -c 'import gi' 2>/dev/null; then
    dialog_log "reboot timer starting via gtk fallback (${TIMEOUT}s)"
    python3 "$GTK_PY" --reboot-countdown "$TIMEOUT" --flag-dir "$FLAG_DIR" \
        --title="lsl-usb first boot complete" \
        --text="Setup finished and your home folder is backed up. The system reboots automatically when the timer ends - sooner if you like, or not at all." \
        2>>"$DIALOG_LOG"
    # The python dialog writes the flags itself; the exit code is only for
    # the log (root polls the flags, so a crash here still reboots on time).
    dialog_log "reboot timer finished via gtk fallback (rc=$?)"
    exit 0
fi

if command -v zenity >/dev/null 2>&1; then
    mins=$((TIMEOUT / 60))
    dialog_log "reboot timer starting via zenity (${TIMEOUT}s)"
    zenity --question --title="lsl-usb first boot complete" \
        --text="Setup finished and your home folder is backed up.\n\nThe system will reboot automatically in about $mins minutes.\nReboot now, or cancel the automatic reboot (the new setup still applies on your next boot)." \
        --ok-label="Reboot now" --cancel-label="Cancel automatic reboot" \
        --timeout="$TIMEOUT" 2>>"$DIALOG_LOG"
    rc=$?
    case "$rc" in
        0) touch "$NOW" 2>/dev/null || true; dialog_log "user chose Reboot now" ;;
        1) touch "$CANCEL" 2>/dev/null || true; dialog_log "user cancelled the automatic reboot" ;;
        *) dialog_log "zenity dismissed without a choice (rc=$rc) - automatic reboot proceeds" ;;
    esac
    exit 0
fi

dialog_log "no dialog backend for the reboot timer (need python3-gi or zenity); automatic reboot proceeds"
exit 0
