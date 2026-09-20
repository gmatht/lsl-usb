#!/bin/bash
# lsl-merge-suggest.sh - at login, suggest collapsing the stacked casper
# squashfs layers (/cdrom/casper/filesystem*.squashfs) into a single layer.
#
# Pops a zenity dialog when EITHER:
#   * merging would reduce the layer count by at least 3, AND the merged image
#     fits the FAT32 4 GiB single-file ceiling on /cdrom; OR
#   * we have been able to reduce the layer count for at least a week (a
#     persistent "worth merging" streak tracked in $STATE/merge-streak).
#
# The dialog offers all four choices at once - Merge now (yes, this time),
# Always merge when suggested, Later (no, ask again), Never ask again -
# with the sticky answers persisted in $STATE/merge-choice.
#
# The actual merge is delegated to bin/uproot (the tested live-overlay merge),
# which is launched in a terminal so the user keeps control and sees progress.
#
# Sourceable (guarded) so the trigger logic can be unit-tested.
set -u

CASPER="/cdrom/casper"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/lsl"
STREAK="$STATE/merge-streak"
WEEK_SECONDS=$((7 * 24 * 3600))

# --- filesystem helpers (self-contained; no dependency on /cdrom/bin) --------
lsl_cdrom_fstype() {
    findmnt -no FSTYPE /cdrom 2>/dev/null || echo unknown
}
lsl_cdrom_is_vfat() {
    [ "$(lsl_cdrom_fstype)" = "vfat" ]
}
lsl_fat32_max_bytes() {
    # FAT32 maximum single file size is 4 GiB minus one cluster; use 4 GiB - 64 KiB
    # as a conservative, always-safe ceiling.
    echo 4294901760
}

# Echo the casper squashfs layers, lowest priority first (base, then z-layers).
lsl_merge_layers() {
    local f
    for f in "$CASPER"/filesystem*.squashfs; do
        [ -e "$f" ] && echo "$f"
    done | sort
}

# Decide whether to suggest a merge. Sets globals LSL_MERGE_N / _REDUCTION /
# _FEASIBLE / _REASON and returns 0 if a dialog should be shown, 1 otherwise.
# Maintains the "worth merging" streak (feasible AND reduces the count by >=1).
lsl_merge_should_suggest() {
    STREAK="$STATE/merge-streak"   # track against the (possibly overridden) STATE
    LSL_MERGE_N=0; LSL_MERGE_REDUCTION=0; LSL_MERGE_FEASIBLE=0; LSL_MERGE_REASON=""
    local -a layers
    mapfile -t layers < <(lsl_merge_layers)
    LSL_MERGE_N=${#layers[@]}
    [ "$LSL_MERGE_N" -ge 2 ] || { rm -f "$STREAK" 2>/dev/null || true; return 1; }

    # Upper-bound merged size = sum of layer sizes (dedup can only shrink it).
    local total=0 f sz
    for f in "${layers[@]}"; do
        sz="$(stat -c %s "$f" 2>/dev/null || echo 0)"
        total=$((total + sz))
    done
    LSL_MERGE_FEASIBLE=1
    if lsl_cdrom_is_vfat; then
        local cap; cap="$(lsl_fat32_max_bytes)"
        if [ "$total" -gt "$cap" ] 2>/dev/null; then
            LSL_MERGE_FEASIBLE=0
        fi
    fi
    LSL_MERGE_REDUCTION=$((LSL_MERGE_N - 1))

    # Maintain the "worth merging" streak.
    local now; now="$(date +%s)"
    if [ "$LSL_MERGE_FEASIBLE" -eq 1 ] && [ "$LSL_MERGE_REDUCTION" -ge 1 ]; then
        if [ ! -f "$STREAK" ] && mkdir -p "$STATE" 2>/dev/null; then
            echo "$now" > "$STREAK" 2>/dev/null || true
        fi
    else
        rm -f "$STREAK" 2>/dev/null || true
    fi

    local streak_start="$now"
    [ -f "$STREAK" ] && streak_start="$(cat "$STREAK" 2>/dev/null || echo "$now")"
    local age=$((now - streak_start))
    local week_old=0
    [ "$age" -ge "$WEEK_SECONDS" ] && week_old=1

    local by3=0
    [ "$LSL_MERGE_FEASIBLE" -eq 1 ] && [ "$LSL_MERGE_REDUCTION" -ge 3 ] && by3=1

    if [ "$by3" -eq 1 ]; then
        LSL_MERGE_REASON="Merging would reduce the layer count by $LSL_MERGE_REDUCTION (>= 3)."
        return 0
    fi
    if [ "$week_old" -eq 1 ]; then
        LSL_MERGE_REASON="Layers have been mergeable for at least a week ($(($age / 86400)) days)."
        return 0
    fi
    return 1
}

# Launch the existing live-overlay merge (bin/uproot) in a terminal so the user
# keeps control. uproot elevates itself (sudo); we just open the door.
lsl_merge_do() {
    local up="/cdrom/bin/uproot"
    command -v uproot >/dev/null 2>&1 && up="uproot"
    local term
    term="$(command -v x-terminal-emulator || command -v gnome-terminal || command -v xterm || true)"
    if [ -n "$term" ]; then
        "$term" -e "bash -c 'sudo \"$up\"; echo; echo Press Enter to close.; read'" >/dev/null 2>&1 &
    else
        sudo "$up" >/dev/null 2>&1 &
    fi
}

# Persistent remember-choice for the suggestion dialog ("Always" / "Never"):
# $STATE/merge-choice holds one word. Derived from $STATE on every call so
# tests (and XDG overrides) can point STATE at scratch dirs.
lsl_merge_choice_file() {
    printf '%s/merge-choice' "${STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/lsl}"
}
lsl_merge_choice() {
    # Prints: always | never | "" (undecided or corrupt content).
    local f choice
    f="$(lsl_merge_choice_file)"
    choice="$(cat "$f" 2>/dev/null || true)"
    case "$choice" in
        always|never) printf '%s' "$choice" ;;
        *) printf '' ;;
    esac
}
lsl_merge_record_choice() {
    # lsl_merge_record_choice always|never
    local f
    f="$(lsl_merge_choice_file)"
    mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
    printf '%s\n' "$1" > "$f" 2>/dev/null || return 1
}
lsl_merge_handle_choice() {
    # Act on one dialog selection. Always returns 0 (a declined merge is
    # not an error); unknown, empty, or dismissed selections mean "Later".
    case "${1:-}" in
        "Merge now")
            lsl_merge_do ;;
        "Always merge when suggested")
            lsl_merge_record_choice always || true
            lsl_merge_do ;;
        "Never ask again")
            lsl_merge_record_choice never || true ;;
        *) : ;;  # "Later", dismiss, empty
    esac
    return 0
}

main() {
    # Only meaningful in a graphical session with some dialog backend.
    # Stock Mint ships no zenity (it arrives via firstboot apt, if online),
    # so prefer the bundled GTK fallback and keep zenity as the fallback.
    [ -n "${DISPLAY:-}" ] || exit 0
    local have_gtk=0 have_zenity=0
    if command -v python3 >/dev/null 2>&1 && [ -f "${LSL_PROGRESS_GTK:-/usr/local/bin/lsl-progress-gtk.py}" ] \
        && python3 -c 'import gi' 2>/dev/null; then
        have_gtk=1
    fi
    if command -v zenity >/dev/null 2>&1; then
        have_zenity=1
    fi
    [ "$have_gtk" = 1 ] || [ "$have_zenity" = 1 ] || exit 0

    # A remembered choice short-circuits the dialog entirely.
    case "$(lsl_merge_choice)" in
        never) exit 0 ;;
        always)
            if lsl_merge_should_suggest; then
                lsl_merge_do
            fi
            exit 0 ;;
    esac

    lsl_merge_should_suggest || exit 0

    local msg
    msg="You have $LSL_MERGE_N squashfs layers on this live USB."$'\n'
    msg="$msg Merging them into a single layer would reduce the count by $LSL_MERGE_REDUCTION and keep dpkg's package database consistent."$'\n\n'
    msg="$msg$LSL_MERGE_REASON"
    local choice=""
    if [ "$have_gtk" = 1 ]; then
        choice="$(python3 "${LSL_PROGRESS_GTK:-/usr/local/bin/lsl-progress-gtk.py}" \
            --choice --title "lsl-usb: consider merging filesystem layers" \
            --text "$msg" \
            --options "Merge now|Always merge when suggested|Later|Never ask again" \
            --preselect 1 2>/dev/null || true)"
    else
        choice="$(zenity --list --radiolist \
            --title "lsl-usb: consider merging filesystem layers" \
            --text "$msg" \
            --column "" --column "What should happen?" \
            TRUE "Merge now" \
            FALSE "Always merge when suggested" \
            FALSE "Later" \
            FALSE "Never ask again" \
            --width=620 --height=400 2>/dev/null || true)"
    fi
    lsl_merge_handle_choice "$choice"
    exit 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
