#!/bin/bash
# lsl-firstboot-home-failed.sh - user-session warning that first-boot /home was
# NOT persisted.
#
# Runs from the live desktop during firstboot (via notify_desktop_now) so the
# operator is told BEFORE the reboot-approval dialog, and can also be run at
# login. Keyed on /cdrom/casper/lsl-firstboot.home-failed, which
# misc/lsl-firstboot.sh writes when the final home flush finds a usb-fallback
# overlay (the data dir was not persistent when /home was mounted, so /home was
# a tmpfs overlay and its contents are RAM). See FRAGILE_HOME.md / WHYFAIL9.md.
# Backend: zenity when present, else the bundled GTK fallback; neither: log.
set -u

FAILED=/cdrom/casper/lsl-firstboot.home-failed
[ -e "$FAILED" ] || exit 0

msg="First-boot /home was NOT saved."
REASON=/cdrom/casper/lsl-firstboot.home-failed.reason
if [ -f "$REASON" ]; then
    msg="$msg"$'\n\n'"$(cat "$REASON")"
fi
msg="$msg"$'\n\n'"Collect diagnostics:  bash /cdrom/bin/lsl-diag.sh"

LSL_PROGRESS_GTK="${LSL_PROGRESS_GTK:-/usr/local/bin/lsl-progress-gtk.py}"
DIALOG_LOG="${LSL_DIALOG_LOG:-/tmp/lsl-firstboot-dialog.log}"
dialog_log() {
    printf '%s %s\n' "$(date '+%F %T' 2>/dev/null || printf '?')" "$*" >>"$DIALOG_LOG" 2>/dev/null || true
    logger -t lsl-firstboot-home-failed "$*" 2>/dev/null || true
}
DIALOG_PROG=""
if command -v zenity >/dev/null 2>&1; then
    DIALOG_PROG=zenity
elif command -v python3 >/dev/null 2>&1 && [ -f "$LSL_PROGRESS_GTK" ] \
    && python3 -c 'import gi' 2>/dev/null; then
    DIALOG_PROG=gtk
fi

if [ "$DIALOG_PROG" = zenity ]; then
    zenity --warning --no-wrap --title "lsl-usb: first-boot home not saved" --text "$msg" 2>>"$DIALOG_LOG"
    dialog_log "home-not-saved warning via zenity finished (rc=${PIPESTATUS[0]:-?}); $msg"
elif [ "$DIALOG_PROG" = gtk ]; then
    python3 "$LSL_PROGRESS_GTK" --warn --title "lsl-usb: first-boot home not saved" --text "$msg" 2>>"$DIALOG_LOG"
    dialog_log "home-not-saved warning via gtk fallback finished (rc=$?); $msg"
else
    dialog_log "no dialog backend; $msg"
fi
exit 0
