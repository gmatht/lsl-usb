#!/bin/bash
# lsl-firstboot-failed.sh - user-session notifier for a wedged first boot.
#
# Runs at login (XDG autostart). If a previous first boot gave up (it left
# /cdrom/casper/lsl-firstboot.FAILED), show a non-fatal warning that points
# at the diagnostics and how to recover - so the user is not left silently
# booting a base image without the configured packages.
# Backend: zenity when present, else the bundled GTK fallback (python3-gi
# ships with the desktop; zenity may never have been installed). Neither:
# log loudly instead of vanishing.
set -u

FAILED=/cdrom/casper/lsl-firstboot.FAILED
[ -e "$FAILED" ] || exit 0

msg="The lsl-usb first-boot setup did not complete."
REASON=/cdrom/casper/lsl-firstboot.FAILED.reason
if [ -f "$REASON" ]; then
    msg="$msg"$'\n\n'"$(cat "$REASON")"
fi
msg="$msg"$'\n\n'"Collect diagnostics:  bash /cdrom/bin/lsl-diag.sh"$'\n'"Retry manually:      sudo bash /cdrom/bin/uproot --auto-append"

LSL_PROGRESS_GTK="${LSL_PROGRESS_GTK:-/usr/local/bin/lsl-progress-gtk.py}"
DIALOG_PROG=""
if command -v zenity >/dev/null 2>&1; then
    DIALOG_PROG=zenity
elif command -v python3 >/dev/null 2>&1 && [ -f "$LSL_PROGRESS_GTK" ] \
    && python3 -c 'import gi' 2>/dev/null; then
    DIALOG_PROG=gtk
fi

if [ "$DIALOG_PROG" = zenity ]; then
    zenity --warning --no-wrap --title "lsl-usb: first boot incomplete" --text "$msg" 2>/dev/null || true
elif [ "$DIALOG_PROG" = gtk ]; then
    python3 "$LSL_PROGRESS_GTK" --warn --title "lsl-usb: first boot incomplete" --text "$msg" || true
else
    logger -t lsl-firstboot-failed "no dialog backend; $msg" 2>/dev/null || true
fi
exit 0
