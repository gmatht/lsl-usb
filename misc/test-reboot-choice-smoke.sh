#!/bin/bash
# Smoke test for the end-of-firstboot reboot-target decision logic.
#
# Usage: test-reboot-choice-smoke.sh [REPO_ROOT]
#
# Two halves, both needing no GUI and no root:
#
#   1. lsl_reboot_handle_choice (misc/lsl-firstboot-reboot.sh) - a chosen
#      label becomes flag files, and NOTHING else ever sets reboot-now.
#      This is the safety-critical property: a mis-translated or dismissed
#      dialog must never reboot the machine behind the user's back.
#   2. lsl_firstboot_reboot_now (misc/lsl-firstboot.sh) - each target
#      dispatches the right reboot command, with the efibootmgr and
#      firmware-setup failures both degrading to a plain reboot instead of
#      stranding a user who already approved the reboot.
#
# lsl-firstboot-reboot.sh is safe to source (it ends with a BASH_SOURCE
# guard). lsl-firstboot.sh is NOT - it runs the entire first boot at the
# bottom, so only the single function is extracted, the same way
# test-grow-smoke.sh does it. The flags themselves are the contract with
# root, so every case asserts on the files left in a scratch flag dir.
set -u

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
FAIL=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; FAIL=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=/dev/null
. "$ROOT/misc/lsl-firstboot-reboot.sh"
sed -n '/^lsl_firstboot_reboot_now()/,/^}/p' "$ROOT/misc/lsl-firstboot.sh" >"$TMP/reboot_fn.sh"
if ! grep -q 'LSL_REBOOT_CMD' "$TMP/reboot_fn.sh"; then
    echo "FAIL - could not extract lsl_firstboot_reboot_now from lsl-firstboot.sh" >&2
    exit 1
fi
# shellcheck source=/dev/null
. "$TMP/reboot_fn.sh"
# Quiet the script's own logging; it tees to stdout.
log() { :; }

# Redirect the dialog log away from the live /tmp trace so a test run cannot
# clobber the real firstboot diagnostics.
export LSL_DIALOG_LOG="$TMP/dialog.log"
export LSL_DIALOG_TRACE="$TMP/trace.log"

check_flags() { # <label> <expect-now> <expect-cancel> <expect-target>
    local label="$1" want_now="$2" want_cancel="$3" want_target="$4"
    local got_now=0 got_cancel=0 got_target=""
    [ -e "$FLAG_DIR/reboot-now" ] && got_now=1
    [ -e "$FLAG_DIR/reboot-cancel" ] && got_cancel=1
    [ -r "$FLAG_DIR/reboot-target" ] && got_target="$(head -n1 "$FLAG_DIR/reboot-target")"
    if [ "$got_now" = "$want_now" ] && [ "$got_cancel" = "$want_cancel" ] \
        && [ "$got_target" = "$want_target" ]; then
        pass "$label"
    else
        fail "$label (now=$got_now want=$want_now, cancel=$got_cancel want=$want_cancel, target='$got_target' want='$want_target')"
    fi
}

# --- 1. dialog choice -> flag files -----------------------------------------
# FLAG_DIR is what lsl_reboot_flag_paths() reads at call time, so
# repointing it per case redirects NOW/CANCEL/TARGET too.
FLAG_DIR="$TMP/case1"; mkdir -p "$FLAG_DIR"
lsl_reboot_handle_choice "Reboot to lsl-usb"
check_flags "'Reboot to lsl-usb' approves the reboot and targets usb" 1 0 "usb"

FLAG_DIR="$TMP/case2"; mkdir -p "$FLAG_DIR"
lsl_reboot_handle_choice "Firmware boot menu"
check_flags "'Firmware boot menu' approves the reboot and targets fw" 1 0 "fw"

FLAG_DIR="$TMP/case3"; mkdir -p "$FLAG_DIR"
lsl_reboot_handle_choice "Later"
check_flags "'Later' defers without approving" 0 1 ""

# The safety-critical case: a dismissed dialog prints nothing and exits
# non-zero, so the translation sees an empty label. It must defer.
FLAG_DIR="$TMP/case4"; mkdir -p "$FLAG_DIR"
lsl_reboot_handle_choice ""
check_flags "dismissed dialog (empty choice) defers, never reboots" 0 1 ""

# A label that nearly matches must not fall through to a reboot either.
FLAG_DIR="$TMP/case5"; mkdir -p "$FLAG_DIR"
lsl_reboot_handle_choice "Reboot to lsl-u$'\x01'"
check_flags "corrupt label defers rather than defaulting to a reboot" 0 1 ""

# --- 2. target -> reboot command --------------------------------------------
# LSL_REBOOT_CMD / LSL_EFIBOOTMGR_CMD are the test hooks, so no privileged
# command is ever executed here: the stub just records its argv.
# expect_calls <label> <efibootmgr stub|none|reject-fw> <target> <expected>
expect_calls() {
    local label="$1" mode="$2" target="$3" want="$4"
    local dir="$TMP/dispatch-$mode-$target"
    rm -rf "$dir"; mkdir -p "$dir"
    : >"$dir/calls"
    cat >"$dir/reboot" <<'STUB'
#!/bin/bash
# Stands in for `systemctl reboot [extra]`. $LSL_REBOOT_CMD holds a command
# WITH WORDS in it, which is why the call sites leave it unquoted: for
# `bash <stub> reboot`, the stub's $1 is "reboot" and the extra flag is $2
# (the script path is $0, so it never appears in "$*").
printf 'reboot' >>"${LSL_TEST_CALLS:?}"
for a in "$@"; do printf ' %s' "$a" >>"${LSL_TEST_CALLS:?}"; done
printf '\n' >>"${LSL_TEST_CALLS:?}"
if [ "${LSL_STUB_REJECT_FW:-0}" = 1 ] && printf '%s\n' "$*" | grep -q -- '--firmware-setup=auto'; then
    exit 1
fi
exit 0
STUB
    chmod +x "$dir/reboot"
    local path_prefix=""
    if [ "$mode" = "efi" ]; then
        cat >"$dir/efibootmgr" <<'STUB'
#!/bin/bash
if [ "${1:-}" = "-n" ]; then
    printf 'efi -n %s\n' "${2:-}" >>"${LSL_TEST_CALLS:?}"
    exit 0
fi
printf 'BootCurrent: 0007\nBootOrder: 0007,0001\n'
STUB
        chmod +x "$dir/efibootmgr"
        path_prefix="$dir:"
    fi
    (
        export LSL_TEST_CALLS="$dir/calls"
        export LSL_STUB_REJECT_FW=0
        [ "$mode" = "reject-fw" ] && export LSL_STUB_REJECT_FW=1
        LSL_REBOOT_CMD="bash $dir/reboot"
        LSL_EFIBOOTMGR_CMD="efibootmgr"
        PATH="$path_prefix$PATH"
        export PATH
        lsl_firstboot_reboot_now "$target"
    ) >/dev/null 2>&1
    local got
    got="$(tr '\n' ' ' <"$dir/calls")"
    if [ "$got" = "$want" ]; then
        pass "$label"
    else
        fail "$label (got: '$got' want: '$want')"
    fi
}

# 'usb' sets BootNext to the entry we booted from, then reboots.
expect_calls "target usb sets BootNext to BootCurrent, then reboots" efi usb \
    "efi -n 0007 reboot "

# Legacy BIOS/CSM: no efibootmgr on PATH, but the approved reboot still
# happens rather than leaving the user in a session that waits forever.
expect_calls "target usb without efibootmgr falls back to a plain reboot" none usb \
    "reboot "

expect_calls "target fw reboots into the firmware boot menu" none fw \
    "reboot --firmware-setup=auto "

# Old systemd refuses the flag: degrade, never strand an approved reboot.
expect_calls "target fw falls back to a plain reboot when systemd refuses" reject-fw fw \
    "reboot --firmware-setup=auto reboot "

# No target is the pre-existing behaviour, unchanged.
expect_calls "no target keeps the original plain reboot" none "" \
    "reboot "

# --- 3. the option list only offers a firmware button that can actually work --
# A host whose systemctl does not know --firmware-setup must not be shown
# that row at all (greyed-out still reads as clickable).
mkdir -p "$TMP/empty-path"
no_fw="$(PATH="$TMP/empty-path" lsl_reboot_options 2>/dev/null)"
case "$no_fw" in
    *Firmware*) fail "firmware row offered without systemctl" ;;
    *Reboot\ to\ lsl-usb*Later*) pass "firmware row dropped when systemctl is absent" ;;
    *) fail "unexpected option list without systemctl: '$no_fw'" ;;
esac

# --- 4. the zenity radiolist argv --------------------------------------------
# zenity takes alternating state/label ARGUMENTS. Quoting a row as one word
# ("TRUE Firmware boot menu") collapses it into a single field and the dialog
# comes back malformed. Assert the row FIELDS, which is the part that
# matters; the multi-line --text body is separately checked below.
zenity_rows() { # zenity_rows <label> <fw-present 0|1> <expected row fields>
    local label="$1" want_fw="$2" want="$3"
    local dir="$TMP/zenity-$want_fw"
    rm -rf "$dir"; mkdir -p "$dir"
    cat >"$dir/zenity" <<'STUB'
#!/bin/bash
printf '%s\0' "$@" >>"${LSL_TEST_CALLS:?}"
STUB
    chmod +x "$dir/zenity"
    # A stub systemctl so lsl_reboot_options() takes the branch we want.
    cat >"$dir/systemctl" <<'STUB'
#!/bin/bash
if [ "${1:-}" = "--help" ] && [ "${LSL_STUB_FW:-0}" = 1 ]; then
    printf '  --firmware-setup=MODE\n'
fi
exit 0
STUB
    chmod +x "$dir/systemctl"
    (
        export LSL_TEST_CALLS="$dir/argv"
        export LSL_STUB_FW="$want_fw"
        export LSL_DIALOG_LOG="$TMP/zenity.log"
        : >"$dir/argv"
        PATH="$dir:$PATH"; export PATH
        ask_zenity >/dev/null 2>&1
    )
    # Pull the alternating radiolist fields out of the recorded argv: they
    # start at the first TRUE and run to the last field before --width.
    local got
    got="$(tr '\0' '\n' <"$dir/argv" | sed -n '/^TRUE$/,$p' | sed '/^--width=/,$d' | paste -sd'|' -)"
    if [ "$got" = "$want" ]; then
        pass "$label"
    else
        fail "$label (got: '$got' want: '$want')"
    fi
}

zenity_rows "zenity radiolist passes each row as two separate fields (with fw)" 1 \
    "TRUE|Reboot to lsl-usb|TRUE|Firmware boot menu|FALSE|Later"
zenity_rows "zenity radiolist omits the firmware row when unsupported" 0 \
    "TRUE|Reboot to lsl-usb|FALSE|Later"

# --- 5. the GTK fallback gets the same options ------------------------------
# run_choice() splits its --options on "|", so the GTK argv must carry the
# identical list the zenity path renders.
gtk_options() { # gtk_options <label> <fw-present 0|1> <expected --options value>
    local label="$1" want_fw="$2" want="$3"
    local dir="$TMP/gtk-$want_fw"
    rm -rf "$dir"; mkdir -p "$dir"
    cat >"$dir/python3" <<'STUB'
#!/bin/bash
# Record --options and emit the chosen label on stdout, as the real
# lsl-progress-gtk.py does on success.
while [ $# -gt 0 ]; do
    if [ "$1" = "--options" ]; then printf '%s' "$2" >"${LSL_TEST_CALLS:?}"; fi
    shift
done
printf 'Later\n'
STUB
    cat >"$dir/systemctl" <<'STUB'
#!/bin/bash
if [ "${1:-}" = "--help" ] && [ "${LSL_STUB_FW:-0}" = 1 ]; then
    printf '  --firmware-setup=MODE\n'
fi
exit 0
STUB
    chmod +x "$dir/python3" "$dir/systemctl"
    (
        export LSL_TEST_CALLS="$dir/opts"
        export LSL_STUB_FW="$want_fw"
        export LSL_DIALOG_LOG="$TMP/gtk.log"
        : >"$dir/opts"
        GTK_PY="$dir/lsl-progress-gtk.py"
        : >"$GTK_PY"
        PATH="$dir:$PATH"; export PATH
        ask_gtk >/dev/null 2>&1
    )
    local got
    got="$(cat "$dir/opts")"
    if [ "$got" = "$want" ]; then
        pass "$label"
    else
        fail "$label (got: '$got' want: '$want')"
    fi
}

gtk_options "gtk fallback receives the same three options (with fw)" 1 \
    "Reboot to lsl-usb|Firmware boot menu|Later"
gtk_options "gtk fallback omits the firmware row when unsupported" 0 \
    "Reboot to lsl-usb|Later"

if [ "$FAIL" -eq 0 ]; then
    echo "REBOOT_CHOICE_SMOKE_OK"
    exit 0
fi
echo "REBOOT_CHOICE_SMOKE_FAIL"
exit 1