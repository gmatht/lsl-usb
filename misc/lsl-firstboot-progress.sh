#!/bin/bash
# lsl-usb first-boot progress window (user session).
#
# Started from /etc/xdg/autostart once the desktop comes up. Shows a pulsing
# progress dialog (zenity, else the bundled GTK fallback) fed from the status
# file that lsl-firstboot.sh maintains, and closes itself when the setup
# stamp appears (or exits loudly-logged when there is nothing to show with).
# The root-side setup runs concurrently; this is display only.
set -u

STAMP="${LSL_FIRSTBOOT_STAMP:-/cdrom/casper/lsl-firstboot.done}"
STATUS="${LSL_FIRSTBOOT_STATUS:-/run/lsl-firstboot-status}"

# Nothing to do if the stamp exists (setup already completed).
# The service mounts the stick at /isodevice when /cdrom is the ISO loop;
# accept the stamp at either place (or an explicit override).
stamp_present() {
    [ -n "${LSL_FIRSTBOOT_STAMP:-}" ] && [ -e "$STAMP" ] && return 0
    [ -e /isodevice/casper/lsl-firstboot.done ] && return 0
    [ -e /cdrom/casper/lsl-firstboot.done ] && return 0
    return 1
}
stamp_present && exit 0

# Dialog backend: zenity when present (unchanged behavior), else the
# bundled GTK fallback (misc/lsl-progress-gtk.py). python3-gi ships with
# the Cinnamon desktop itself; zenity only arrives via firstboot apt -
# after (or, offline, never) the dialog is needed. No backend: log loudly
# and exit instead of vanishing silently (the old `|| exit 0` behavior
# that hid this exact failure).
LSL_PROGRESS_GTK="${LSL_PROGRESS_GTK:-/usr/local/bin/lsl-progress-gtk.py}"
# Dialog errors go here AND to the journal: autostart stdout/stderr may go
# nowhere visible (/dev/null hid every past failure), and /tmp is writable
# in every session (unlike /cdrom, which may be the read-only ISO loop).
DIALOG_LOG="${LSL_DIALOG_LOG:-/tmp/lsl-firstboot-dialog.log}"
dialog_log() {
    printf '%s %s\n' "$(date '+%F %T' 2>/dev/null || printf '?')" "$*" >>"$DIALOG_LOG" 2>/dev/null || true
    logger -t lsl-firstboot-progress "$*" 2>/dev/null || true
}
DIALOG_PROG=""
if command -v zenity >/dev/null 2>&1; then
    DIALOG_PROG=zenity
elif command -v python3 >/dev/null 2>&1 && [ -f "$LSL_PROGRESS_GTK" ] \
    && python3 -c 'import gi' 2>/dev/null; then
    DIALOG_PROG=gtk
else
    dialog_log "no dialog backend (need zenity or python3-gi + $LSL_PROGRESS_GTK); progress invisible"
    exit 0
fi
dialog_log "progress dialog starting via $DIALOG_PROG"

current_phase() {
    if [ -r "$STATUS" ]; then
        sed -n 's/^phase=//p' "$STATUS" | tail -n 1
    else
        echo "starting"
    fi
}

feed_phases() {
    # Keep feeding the dialog while the service is still working.
    # Same "PCT # text" protocol for zenity and the GTK fallback.
    while ! stamp_present; do
        echo "1000 # $(current_phase)"
        sleep 1
        if ! kill -0 "$PPID" 2>/dev/null; then break; fi
    done
    echo "1000 # Done - rebooting"
    sleep 1
    echo "100"
}

if [ "$DIALOG_PROG" = zenity ]; then
    feed_phases | zenity --progress --pulsate --auto-close --auto-kill \
        --title="lsl-usb first boot" \
        --text="Preparing your USB system (first boot)..." \
        --width=480 2>>"$DIALOG_LOG"
    # PIPESTATUS right away: rc 0 = shown to completion, 1 = dismissed early.
    dialog_log "progress dialog finished via zenity (consumer rc=${PIPESTATUS[1]:-?})"
else
    feed_phases | python3 "$LSL_PROGRESS_GTK" \
        --title="lsl-usb first boot" \
        --text="Preparing your USB system (first boot)..." \
        --width=480 2>>"$DIALOG_LOG"
    dialog_log "progress dialog finished via gtk fallback (consumer rc=${PIPESTATUS[1]:-?})"
fi
exit 0
