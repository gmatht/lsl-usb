#!/bin/bash
# lsl-usb first-boot progress window (user session).
#
# Started from /etc/xdg/autostart once the desktop comes up. Shows a progress
# dialog (zenity, else the bundled GTK fallback) fed from the structured
# status file that lsl-firstboot.sh maintains, and closes itself when the
# setup stamp appears (or exits loudly-logged when there is nothing to show).
# The root-side setup runs concurrently; this is display only.
#
# Status file ($STATUS) is key=value lines written atomically by the service:
#   phase=  human-readable phase (legacy, always present)
#   tasks=  id:label|id:label|... (full ordered task list)
#   task=   current task id
#   done=   comma-separated completed task ids
#   pct=    0..100 progress through the CURRENT task
#   detail= human-readable detail for the current task
# Overall progress = (index_of_current_task * 100 + pct) / num_tasks.
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

status_get() {
    # status_get KEY [DEFAULT] — single-line value, newline-stripped.
    local v
    v="$(sed -n "s/^$1=//p" "$STATUS" 2>/dev/null | tail -n 1 | tr -d '\n\r')"
    if [ -z "$v" ] && [ $# -ge 2 ]; then v="$2"; fi
    printf '%s' "$v"
}

# Split the tasks= line into positional "id:label" entries.
# Sets: TASK_N (count), TASK_IDS, and TASK_LABEL_<id> via dynamic vars is
# overkill for POSIX-less bash — callers use task_field instead.
task_count() {
    local t n
    t="$(status_get tasks)"
    [ -n "$t" ] || { echo 0; return; }
    # Count '|' separators + 1. awk is always present on live ISOs.
    n="$(printf '%s' "$t" | awk -F'|' '{print NF}')"
    printf '%s' "${n:-0}"
}
task_entry() {
    # task_entry INDEX (1-based) -> "id:label" or empty.
    local t
    t="$(status_get tasks)"
    [ -n "$t" ] || return 1
    printf '%s' "$t" | cut -d'|' -f"$1" 2>/dev/null
}
task_index() {
    # task_index ID -> 0-based position, or -1 if unknown.
    local want="$1" i n e id
    n="$(task_count)"
    i=1
    while [ "$i" -le "$n" ]; do
        e="$(task_entry "$i")"
        id="${e%%:*}"
        if [ "$id" = "$want" ]; then
            echo $((i - 1))
            return 0
        fi
        i=$((i + 1))
    done
    echo -1
}
task_label() {
    # task_label ID -> human label (falls back to the id itself).
    local want="$1" i n e id label
    n="$(task_count)"
    i=1
    while [ "$i" -le "$n" ]; do
        e="$(task_entry "$i")"
        id="${e%%:*}"
        if [ "$id" = "$want" ]; then
            label="${e#*:}"
            [ -n "$label" ] && [ "$label" != "$e" ] && { printf '%s' "$label"; return 0; }
            printf '%s' "$id"
            return 0
        fi
        i=$((i + 1))
    done
    printf '%s' "$want"
}

# Overall percent + one-line summary for the zenity text label.
# Prints "OVERALL|SUMMARY" (summary has no newlines).
overall_and_summary() {
    local task done pct detail phase n idx label step overall summary
    task="$(status_get task)"
    done="$(status_get done)"
    pct="$(status_get pct 0)"
    detail="$(status_get detail)"
    phase="$(status_get phase starting)"
    case "$pct" in ''|*[!0-9]*) pct=0 ;; esac
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100
    n="$(task_count)"
    if [ -z "$task" ] || [ "$n" -le 0 ]; then
        # Legacy status (phase= only): caller falls back to phase text.
        echo "0|$phase"
        return 0
    fi
    idx="$(task_index "$task")"
    [ "$idx" -ge 0 ] 2>/dev/null || idx=0
    label="$(task_label "$task")"
    step=$((idx + 1))
    overall=$(((idx * 100 + pct) / n))
    [ "$overall" -lt 1 ] && overall=1
    [ "$overall" -gt 99 ] && overall=99
    [ -n "$detail" ] || detail="$phase"
    # Keep it one line: strip anything the service may have embedded.
    detail="$(printf '%s' "$detail" | tr '\n\r' ' ' | cut -c1-160)"
    summary="Step $step/$n: $label ($pct%) — $detail"
    echo "$overall|$summary"
}

feed_zenity() {
    # Same "PCT # text" protocol as before, but PCT is now REAL overall
    # progress (was a fake 5–95% oscillation; 1000 ≥ 100 used to close the
    # window instantly). Clamp to 1..99 while running; 100 only at the end.
    local line overall summary
    while ! stamp_present; do
        line="$(overall_and_summary)"
        overall="${line%%|*}"
        summary="${line#*|}"
        if [ -z "$(status_get tasks)" ]; then
            # Legacy fallback: phase text only.
            summary="$(status_get phase starting)"
            overall=50
        fi
        echo "$overall # $summary"
        sleep 1
        if ! kill -0 "$PPID" 2>/dev/null; then break; fi
    done
    echo "100 # Done - rebooting"
    sleep 1
}

if [ "$DIALOG_PROG" = zenity ]; then
    feed_zenity | zenity --progress --auto-close --auto-kill \
        --title="lsl-usb first boot" \
        --text="Preparing your USB system (first boot)..." \
        --width=480 2>>"$DIALOG_LOG"
    # PIPESTATUS right away: rc 0 = shown to completion, 1 = dismissed early.
    dialog_log "progress dialog finished via zenity (consumer rc=${PIPESTATUS[1]:-?})"
else
    # GTK fallback polls the status file itself (rich task list), so no
    # stdin pipe is needed. It exits on its own when the stamp appears.
    python3 "$LSL_PROGRESS_GTK" \
        --status-file="$STATUS" \
        --stamp="$STAMP" \
        --title="lsl-usb first boot" \
        --text="Preparing your USB system (first boot)..." \
        --width=480 2>>"$DIALOG_LOG"
    dialog_log "progress dialog finished via gtk fallback (consumer rc=$?)"
fi
exit 0
