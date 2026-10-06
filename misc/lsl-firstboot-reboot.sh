#!/bin/bash
# lsl-usb first-boot reboot approval (user session).
#
# Shown once at the end of firstboot instead of an instant reboot: waits
# for the user to pick WHERE the reboot should land. There is NO timer and
# NO automatic reboot - this script only records the decision; the root
# firstboot service does the actual reboot once $FLAG_DIR/reboot-now exists,
# and exits quietly after $FLAG_DIR/reboot-cancel (the stamped layer
# activates on the next manual boot either way).
#
# The Windows installer already offers a reboot *target* choice
# (lslsetup.exe's boot dialog: USB / firmware menu / don't reboot), and a
# bare "reboot" here is the one case where it cannot: a plain reboot falls
# through to whatever the firmware boot order picks first, which on a
# dual-boot machine is usually Windows. So this mirrors that offer, minus
# "Advanced startup menu" - a Windows-only concept (WinRE "Use a device")
# with no Linux counterpart.
#
#   Reboot to lsl-usb   -> efibootmgr -n <BootCurrent>, then reboot.
#                          Same trick bin/lsl-shutdown-gui already uses for
#                          its "Reboot to USB" option.
#   Firmware boot menu  -> systemctl reboot --firmware-setup=auto. Only
#                          OFFERED when the running systemd knows the flag,
#                          so the button is never rendered dead.
#   Later               -> nothing; root stops waiting.
#
# Backends: the bundled GTK fallback first (python3-gi ships with Cinnamon;
# zenity only arrives via firstboot apt, so it may still be missing), then
# zenity --list --radiolist (no --timeout: it must not auto-answer). Both go
# through the generic --choice mode of the same lsl-progress-gtk.py that
# the merge suggestion already uses. No backend: log loudly and exit 0
# without flags (root keeps waiting for approval).
#
# Sourceable: the decision logic lives in plain functions below so it can be
# unit-tested without a GUI (main() only runs when executed directly).
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
TARGET="$FLAG_DIR/reboot-target"
GTK_PY="${LSL_PROGRESS_GTK:-/usr/local/bin/lsl-progress-gtk.py}"
DIALOG_LOG="${LSL_DIALOG_LOG:-/tmp/lsl-firstboot-dialog.log}"
# Same three-sink logging as lsl-firstboot-progress.sh: /tmp + journal are
# RAM-only; the trace file is pre-created world-writable by the root
# service and flushed to /cdrom/casper/dialog-trace.log (vfat /cdrom is
# root-owned, so this session cannot write the stick directly). Like the
# flag paths it is resolved at call time, so the unit test can repoint
# FLAG_DIR without every log line going to the live /run path (and failing).
lsl_dialog_trace() {
    printf '%s' "${LSL_DIALOG_TRACE:-$FLAG_DIR/dialog-trace.log}"
}
dialog_log() {
    local ts trace
    ts="$(date '+%F %T' 2>/dev/null || printf '?')"
    trace="$(lsl_dialog_trace)"
    printf '%s %s\n' "$ts" "$*" >>"$DIALOG_LOG" 2>/dev/null || true
    printf '%s %s\n' "$ts" "$*" >>"$trace" 2>/dev/null || true
    logger -t lsl-firstboot-reboot "$*" 2>/dev/null || true
}

# --- decision logic (sourceable, side-effect free until called) -------------
OPT_USB="Reboot to lsl-usb"
OPT_FW="Firmware boot menu"
OPT_LATER="Later"

# Resolve the three flag paths at CALL time, not at source time. Sourcing this
# file (the unit test does) must not freeze the paths against whatever
# FLAG_DIR happened to be set to by the caller's argument parsing, or a test
# that repoints FLAG_DIR would write into the live /run/lsl-firstboot.
lsl_reboot_flag_paths() {
    NOW="$FLAG_DIR/reboot-now"
    CANCEL="$FLAG_DIR/reboot-cancel"
    TARGET="$FLAG_DIR/reboot-target"
}

# `systemctl reboot --firmware-setup=` landed in systemd 254. Probing the
# help text is the only reliable check: the flag is absent (not merely
# refused) on older systemd, and a one-time boot into setup that then does
# nothing is a much worse outcome than not offering the button.
lsl_firmware_setup_supported() {
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl --help 2>/dev/null | grep -q -- '--firmware-setup' || return 1
    return 0
}

# The "|"-separated option list, in display order. Firmware menu is dropped
# when unsupported rather than greyed out: a greyed GTK radio button still
# reads as clickable, and the user cannot tell why it does nothing.
lsl_reboot_options() {
    if lsl_firmware_setup_supported; then
        printf '%s|%s|%s' "$OPT_USB" "$OPT_FW" "$OPT_LATER"
    else
        printf '%s|%s' "$OPT_USB" "$OPT_LATER"
    fi
}

# Translate a chosen label into flag files. Always returns 0. An empty or
# unrecognised label (dialog dismissed, Escape, window closed, backend
# crashed) means "Later": a surprise reboot is worse than a deferred one,
# and the stamped layer activates on the next boot anyway.
lsl_reboot_handle_choice() {
    local choice="${1:-}"
    lsl_reboot_flag_paths
    case "$choice" in
        "$OPT_USB")
            printf 'usb\n' >"$TARGET" 2>/dev/null || true
            touch "$NOW" 2>/dev/null || true
            dialog_log "user chose $OPT_USB (reboot target: usb)"
            ;;
        "$OPT_FW")
            printf 'fw\n' >"$TARGET" 2>/dev/null || true
            touch "$NOW" 2>/dev/null || true
            dialog_log "user chose $OPT_FW (reboot target: fw)"
            ;;
        *)
            touch "$CANCEL" 2>/dev/null || true
            dialog_log "user deferred the reboot (choice='${choice}') - no automatic reboot"
            ;;
    esac
    return 0
}

# No Linux-side boot-menu key map exists (the Windows installer has one in
# src/boot.rs, but this runs on the stick), so the hint is generic - the same
# "F12/Del/Esc during POST" wording install.ps1 and boot.rs fall back to.
dialog_body() {
    printf '%s\n' \
        "Setup finished and your home folder is backed up." \
        "" \
        "The system will NOT reboot until you choose." \
        "" \
        "A plain reboot starts whatever your firmware boots first - usually Windows." \
        "If it boots Windows instead, power off and press the boot-menu key" \
        "(often F12, F9, F8 or Esc) during POST to pick the lsl-usb stick."
}

ask_gtk() {
    local opts body
    opts="$(lsl_reboot_options)"
    body="$(dialog_body)"
    python3 "$GTK_PY" --choice \
        --title="lsl-usb first boot complete" \
        --text="$body" \
        --options "$opts" \
        --preselect 1 2>>"$DIALOG_LOG"
}

ask_zenity() {
    local body opts fw
    body="$(dialog_body)"
    opts="$(lsl_reboot_options)"
    # zenity --list --radiolist takes alternating state/label ARGUMENTS, so
    # the firmware row must be emitted as two separate words. Passing it as
    # one quoted string ("TRUE Firmware boot menu") silently collapses the
    # row into a single field and the dialog comes back malformed.
    fw=""
    case "$opts" in *"$OPT_FW"*) fw=1 ;; esac
    local -a rows=(TRUE "$OPT_USB")
    local height=280
    if [ -n "$fw" ]; then
        rows+=(TRUE "$OPT_FW")
        height=340
    fi
    rows+=(FALSE "$OPT_LATER")
    zenity --list --radiolist \
        --title="lsl-usb first boot complete" \
        --text="$body" \
        --column "" --column="What should happen?" \
        "${rows[@]}" \
        --width=620 --height="$height" 2>>"$DIALOG_LOG"
}

main() {
    mkdir -p "$FLAG_DIR" 2>/dev/null || true

    local choice="" backend=""
    if command -v python3 >/dev/null 2>&1 && [ -f "$GTK_PY" ] \
        && python3 -c 'import gi' 2>/dev/null; then
        backend=gtk
        dialog_log "reboot approval starting via gtk fallback (waits for user); options: $(lsl_reboot_options)"
        choice="$(ask_gtk || true)"
    elif command -v zenity >/dev/null 2>&1; then
        backend=zenity
        dialog_log "reboot approval starting via zenity (waits for user); options: $(lsl_reboot_options)"
        choice="$(ask_zenity || true)"
    else
        dialog_log "no dialog backend for reboot approval (need python3-gi or zenity); waiting for manual reboot approval"
        exit 0
    fi

    # Both backends print the chosen label; dismissal prints nothing and
    # exits non-zero, which lands in the "Later" branch of the translation.
    choice="${choice%$'\r'}"
    [ -n "$choice" ] || dialog_log "$backend dialog closed without a choice"
    lsl_reboot_handle_choice "$choice"
    exit 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi