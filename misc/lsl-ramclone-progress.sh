#!/bin/bash
# lsl-ramclone-progress.sh - Boot-to-RAM progress + "safe to remove" dialog.
#
# Started from /etc/xdg/autostart once the desktop comes up, but ONLY does
# anything on a `ramclone` boot with an active dm-clone device (gated below),
# so it is a no-op on every normal boot. It shows the background hydration of
# the live system into RAM and - when complete - offers a "Detach USB" button
# that runs lsl-ramclone-eject and then reports that the stick can be removed.
#
# Backends mirror lsl-firstboot-progress.sh: zenity when present, else the
# bundled GTK fallback (misc/lsl-progress-gtk.py --ramclone); no backend just
# logs and exits instead of vanishing silently.
set -u

CMDLINE="${LSL_CMDLINE_FILE:-/proc/cmdline}"
RAMDIR="${LSL_RAMCLONE_DIR:-/run/ramclone}"
STATUS_BIN="${LSL_RAMCLONE_STATUS_BIN:-/cdrom/bin/lsl-ramclone-status}"
EJECT_BIN="${LSL_RAMCLONE_EJECT_BIN:-/cdrom/bin/lsl-ramclone-eject}"
GTK="${LSL_PROGRESS_GTK:-/usr/local/bin/lsl-progress-gtk.py}"
DIALOG_LOG="${LSL_DIALOG_LOG:-/tmp/lsl-ramclone-dialog.log}"
TRACE="${LSL_DIALOG_TRACE:-/run/lsl-firstboot/dialog-trace.log}"

dialog_log() {
    local ts
    ts="$(date '+%F %T' 2>/dev/null || printf '?')"
    printf '%s %s\n' "$ts" "$*" >>"$DIALOG_LOG" 2>/dev/null || true
    printf '%s %s\n' "$ts" "$*" >>"$TRACE" 2>/dev/null || true
    logger -t lsl-ramclone-progress "$*" 2>/dev/null || true
}

# Only on a Boot-to-RAM boot whose dm-clone device is actually active.
grep -qw ramclone "$CMDLINE" 2>/dev/null || exit 0
[ -e "$RAMDIR/ready" ] || exit 0
if [ ! -e "$STATUS_BIN" ]; then
    dialog_log "ramclone active but $STATUS_BIN missing; progress invisible"
    exit 0
fi

# Run the eject with the same privilege ladder as lsl-shutdown-gui.
run_privileged() {
    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
        "$@"
        return $?
    fi
    if command -v pkexec >/dev/null 2>&1; then
        pkexec "$@"
        return $?
    fi
    if command -v sudo >/dev/null 2>&1; then
        sudo "$@"
        return $?
    fi
    return 1
}

# Some chain layer could not be RAM-backed: the stick cannot be detached safely.
if [ -e "$RAMDIR/all_ram" ]; then
    DETACH_OK=1
else
    DETACH_OK=0
fi

# Feed zenity "PCT # text" lines until lsl-ramclone-status reports completion
# (exit 0) or the device disappears.
feed_zenity() {
    local p rc
    while :; do
        "$STATUS_BIN" >/dev/null 2>&1
        rc=$?
        [ "$rc" -eq 0 ] && break
        [ -e "$RAMDIR/status" ] || break
        p="$("$STATUS_BIN" 2>/dev/null | head -n1)"
        case "$p" in ''|*[!0-9]*) p=1 ;; esac
        [ "$p" -lt 1 ] && p=1
        [ "$p" -gt 99 ] && p=99
        echo "$p # Copying the live system into RAM… ($p%)"
        sleep 2
    done
    echo "100 # Copy complete."
}

zenity_detach() {
    if [ "$DETACH_OK" != "1" ]; then
        zenity --info --title="lsl-usb — Boot to RAM" --width=480 \
            --text="The live system has been copied into RAM.
Some layers are still read from the USB stick, so it cannot be detached
automatically here — close the session before unplugging it." 2>/dev/null || true
        dialog_log "hydration complete but not all layers are RAM-backed; advised against unplugging"
        return 0
    fi
    if zenity --question --title="lsl-usb — Boot to RAM" --width=480 \
        --ok-label="Detach USB" --cancel-label="Later" \
        --text="The live system has been copied into RAM.
You can now detach the USB stick." 2>/dev/null; then
        if run_privileged "$EJECT_BIN"; then
            zenity --info --title="lsl-usb — Boot to RAM" --width=480 \
                --text="It is now safe to remove your stick." 2>/dev/null || true
            dialog_log "USB detached; safe-to-remove shown"
        else
            zenity --error --title="lsl-usb — Boot to RAM" --width=480 \
                --text="Could not detach the USB automatically.
Run 'sudo $EJECT_BIN' when you are ready." 2>/dev/null || true
            dialog_log "eject failed"
        fi
    else
        dialog_log "user chose Later; USB left attached"
    fi
}

DIALOG_PROG=""
if command -v zenity >/dev/null 2>&1; then
    DIALOG_PROG=zenity
elif command -v python3 >/dev/null 2>&1 && [ -f "$GTK" ] && python3 -c 'import gi' 2>/dev/null; then
    DIALOG_PROG=gtk
else
    dialog_log "no dialog backend (need zenity or python3-gi + $GTK); progress invisible"
    exit 0
fi
dialog_log "Boot-to-RAM dialog starting via $DIALOG_PROG (user=$(id -un 2>/dev/null || echo '?') display=${DISPLAY:-none})"

if [ "$DIALOG_PROG" = zenity ]; then
    feed_zenity | zenity --progress --auto-close --no-cancel \
        --title="lsl-usb — Boot to RAM" \
        --text="Copying the live system into RAM…" \
        --width=480 2>>"$DIALOG_LOG"
    dialog_log "hydration progress dialog finished via zenity (consumer rc=${PIPESTATUS[1]:-?})"
    # Only offer detach once hydration really completed.
    if "$STATUS_BIN" >/dev/null 2>&1 && [ -e "$RAMDIR/status" ]; then
        zenity_detach
    else
        dialog_log "clone no longer active after the progress dialog; not offering detach"
    fi
else
    python3 "$GTK" --ramclone \
        --status-bin="$STATUS_BIN" \
        --eject-bin="$EJECT_BIN" \
        --detach-allowed="$DETACH_OK" \
        --title="lsl-usb — Boot to RAM" \
        --text="Copying the live system into RAM…" \
        --width=480 2>>"$DIALOG_LOG"
    dialog_log "Boot-to-RAM dialog finished via gtk fallback (rc=$?)"
fi
exit 0
