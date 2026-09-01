#!/bin/bash
# lsl-usb first-boot progress window (user session).
#
# Started from /etc/xdg/autostart once the desktop comes up. Shows a pulsing
# zenity dialog fed from the status file that lsl-firstboot.sh maintains, and
# closes itself when the setup stamp appears (or exits silently when there is
# nothing to do). The root-side setup runs concurrently; this is display only.
set -u

STAMP="${LSL_FIRSTBOOT_STAMP:-/cdrom/casper/lsl-firstboot.done}"
STATUS="${LSL_FIRSTBOOT_STATUS:-/run/lsl-firstboot-status}"

# Nothing to do if the stamp exists (setup already completed).
[ -e "$STAMP" ] && exit 0
command -v zenity >/dev/null 2>&1 || exit 0

current_phase() {
    if [ -r "$STATUS" ]; then
        sed -n 's/^phase=//p' "$STATUS" | tail -n 1
    else
        echo "starting"
    fi
}

(
    # Keep feeding zenity while the service is still working.
    while [ ! -e "$STAMP" ]; do
        echo "1000 # $(current_phase)"
        sleep 1
        if ! kill -0 "$PPID" 2>/dev/null; then break; fi
    done
    echo "1000 # Done - rebooting"
    sleep 1
    echo "100"
) | zenity --progress --pulsate --auto-close --auto-kill \
    --title="lsl-usb first boot" \
    --text="Preparing your USB system (first boot)..." \
    --width=480 2>/dev/null
exit 0
