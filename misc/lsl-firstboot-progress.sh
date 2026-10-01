#!/bin/bash
# lsl-usb first-boot progress window (user session).
#
# Started from /etc/xdg/autostart once the desktop comes up. Shows a progress
# dialog fed from the structured status file that lsl-firstboot.sh maintains,
# and closes itself when the setup stamp appears (or exits loudly-logged when
# there is nothing to show).
#
# Backend: the bundled GTK dialog (misc/lsl-progress-gtk.py) is preferred - it
# renders the whole task list. zenity is only a last-resort fallback (single
# bar, and it does not close itself; see the zenity branch below).
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

# Dialog errors go to THREE places: /tmp (writable in every session), the
# journal, and the persistent trace file. /tmp and the journal are RAM-only
# and already cost two post-mortems ("was the progress dialog even shown?"
# - 2026-09-15/16 and 2026-09-21): the root firstboot service pre-creates
# the trace world-writable in /run/lsl-firstboot and flushes it to
# /cdrom/casper/dialog-trace.log at the finale; lsl-diag.sh captures it in
# every tarball. vfat /cdrom is root-owned, so the session user cannot
# write the stick directly - the flush is root's job.
DIALOG_LOG="${LSL_DIALOG_LOG:-/tmp/lsl-firstboot-dialog.log}"
TRACE="${LSL_DIALOG_TRACE:-/run/lsl-firstboot/dialog-trace.log}"
dialog_log() {
    local ts
    ts="$(date '+%F %T' 2>/dev/null || printf '?')"
    printf '%s %s\n' "$ts" "$*" >>"$DIALOG_LOG" 2>/dev/null || true
    printf '%s %s\n' "$ts" "$*" >>"$TRACE" 2>/dev/null || true
    logger -t lsl-firstboot-progress "$*" 2>/dev/null || true
}

# Nothing to do if the stamp exists (setup already completed).
# The service mounts the stick at /isodevice when /cdrom is the ISO loop;
# accept the stamp at either place (or an explicit override).
stamp_present() {
    [ -n "${LSL_FIRSTBOOT_STAMP:-}" ] && [ -e "$STAMP" ] && return 0
    [ -e /isodevice/casper/lsl-firstboot.done ] && return 0
    [ -e /cdrom/casper/lsl-firstboot.done ] && return 0
    return 1
}
# Reboot approval may still be pending (the finale stamps first, then waits
# indefinitely for the user to approve the reboot): a fresh login with no
# decision recorded yet should see the approval dialog instead of nothing.
# Returns 0 when a dialog is due: the flag dir exists and neither
# reboot-now nor reboot-cancel is recorded. There is no deadline and no
# timer - a stale deadline file from an older layer is ignored.
reboot_approval_pending() {
    local dir="${LSL_FIRSTBOOT_FLAG_DIR:-/run/lsl-firstboot}"
    [ -d "$dir" ] || return 1
    [ -e "$dir/reboot-cancel" ] && return 1
    [ -e "$dir/reboot-now" ] && return 1
    return 0
}
if stamp_present; then
    if reboot_approval_pending; then
        dialog_log "stamp present, reboot approval still pending - showing the reboot dialog"
        exec bash "${LSL_FIRSTBOOT_REBOOT_SH:-/usr/local/bin/lsl-firstboot-reboot.sh}" \
            --flag-dir "${LSL_FIRSTBOOT_FLAG_DIR:-/run/lsl-firstboot}"
    fi
    # The one exit that used to be completely silent: if the desktop came
    # up after setup finished, this is exactly what happened - and no log
    # anywhere recorded it.
    dialog_log "stamp present at dialog start - nothing to show (setup already complete)"
    exit 0
fi

# Dialog backend. GTK is PREFERRED over zenity; the order used to be the
# opposite and that was the bug (observed 2026-09-30):
#
#   * zenity only shows ONE bar and one text line, and it never lists the
#     tasks. The bundled GTK dialog (misc/lsl-progress-gtk.py) renders the
#     full task list - done / current / pending - which is what an operator
#     needs to see that first boot is actually progressing.
#   * zenity survived for 2h03m AFTER the run finished (12:26 stamp, window
#     still on screen as the reboot dialog appeared): its feeding shell sat
#     in do_wait on the pipeline and the window was never reaped, so a
#     finished progress dialog lingered on top of the reboot dialog. The GTK
#     dialog exits by itself when the stamp appears.
#   * zenity is not even present at first-boot start - it arrives MID-boot
#     via the firstboot apt step - so preferring it produced two different
#     dialogs across a single boot (zenity if the desktop started late, GTK
#     if early), which is why the stage list was seen "sometimes, never".
#
# python3-gi ships with the Cinnamon desktop itself, so GTK is the backend
# that is actually available when the dialog is needed. zenity stays as a
# last-resort fallback for a session without it.
LSL_PROGRESS_GTK="${LSL_PROGRESS_GTK:-/usr/local/bin/lsl-progress-gtk.py}"
gtk_available() {
    command -v python3 >/dev/null 2>&1 && [ -f "$LSL_PROGRESS_GTK" ] \
        && python3 -c 'import gi' 2>/dev/null
}
DIALOG_PROG=""
if gtk_available; then
    DIALOG_PROG=gtk
elif command -v zenity >/dev/null 2>&1; then
    DIALOG_PROG=zenity
fi
if [ -z "$DIALOG_PROG" ]; then
    dialog_log "no dialog backend (need python3-gi + $LSL_PROGRESS_GTK, or zenity); progress invisible"
    exit 0
fi
dialog_log "progress dialog starting via $DIALOG_PROG (user=$(id -un 2>/dev/null || echo '?') display=${DISPLAY:-none}${WAYLAND_DISPLAY:+ wayland=$WAYLAND_DISPLAY})"

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

# Is the finished firstboot actually clean? The stamp only means "the root
# service returned" - lsl-firstboot.sh stamps on the success path but also on
# the give-up/FAILED path and on "nothing to install", and it can finish with
# LSL_HOME_FAILED=1 (phase='failed - ...'). Returns 0 only when every task
# in the list is marked done and phase does not start with "failed".
firstboot_finished_clean() {
    local tasks done phase t i id
    tasks="$(status_get tasks)"
    done="$(status_get done)"
    phase="$(status_get phase)"
    case "$phase" in failed*) return 1 ;; esac
    [ -n "$tasks" ] || return 1
    n="$(task_count)"
    i=1
    while [ "$i" -le "$n" ]; do
        id="$(task_entry "$i")"; id="${id%%:*}"
        [ -n "$id" ] || { i=$((i + 1)); continue; }
        case ",$done," in *",$id,"*) ;; *) return 1 ;; esac
        i=$((i + 1))
    done
    return 0
}

feed_zenity() {
    # Same "PCT # text" protocol as before, but PCT is now REAL overall
    # progress (was a fake 5–95% oscillation; 1000 ≥ 100 used to close the
    # window instantly). Clamp to 1..99 while running; 100 only at the end.
    #
    # NEVER run this as the left side of a pipe into a zenity that was given
    # --auto-close. Reproduced 2026-09-28: zenity 3.44 reads its stdin in a
    # way that closes the read end after the first couple of lines, so the
    # next `echo` here dies of SIGPIPE -- silently, without ever reaching the
    # kill -0 guard below. The pipe then hits EOF and zenity exits 0, which the
    # caller logged as "shown to completion". Net effect on a real boot: the
    # window flashed for ~1s at 02:42:47 while firstboot kept running for
    # another 23 minutes (WHYFAIL8.md). Measured: with --auto-close the writer
    # managed 1 line; with it removed the same writer kept going for the whole
    # test window, and the caller closes the dialog itself by sending 100
    # (which it already does below).
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
    # 100 closes the zenity window; it must only be sent when the boot really
    # finished cleanly. On a failed/partial finish, hold at 99 with the failure
    # in the label (zenity shows it while the window stays up) so the operator
    # is not told "100% done" about a first boot that lost /home or gave up.
    if firstboot_finished_clean; then
        echo "100 # Done - waiting for reboot approval"
    else
        echo "99 # Finished with problems: $(status_get phase) - $(status_get detail)"
    fi
    sleep 1
}

if [ "$DIALOG_PROG" = zenity ]; then
    # --auto-close is deliberately absent: it kills the writer with SIGPIPE
    # (see feed_zenity). But nothing else closes the window either - the old
    # comment claimed "the writer emits 100 to close the window", and that is
    # NOT true of zenity 3.44. Measured 2026-09-30 on a real first boot: the
    # writer exited after its 100, yet zenity stayed on screen for 2h03m with
    # no writer at all (its fd/0 gone, its shell parked in do_wait), and the
    # stale window ended up sitting on top of the reboot dialog. So we run
    # zenity as its own process, wait for it, and KILL it if it is still there
    # once the boot has finished - closing by PID, never by sentinel.
    feed_zenity | zenity --progress --auto-kill \
        --title="lsl-usb first boot" \
        --text="Preparing your USB system (first boot)..." \
        --width=480 2>>"$DIALOG_LOG" &
    # NOTE: for `a | b &` this is the PID of b (zenity) alone. We never `wait`
    # on it while the writer may still be alive - wait would block until BOTH
    # pipeline ends exit. We poll instead, then close by PID.
    ZENITY_PID=$!

    # Wait for the boot to finish (stamp) or the window to disappear (Cancel).
    while ! stamp_present; do
        kill -0 "$ZENITY_PID" 2>/dev/null || break
        sleep 1
    done

    # Close the window by PID. Measured: zenity does NOT exit on the 100 the
    # feeder emits, and with the writer still holding the pipe it never sees
    # EOF either - this is the only reliable close, and without it the window
    # outlives the boot (2h03m observed).
    if kill -0 "$ZENITY_PID" 2>/dev/null; then
        if firstboot_finished_clean; then
            dialog_log "boot finished cleanly - closing the progress window for the reboot dialog"
        else
            dialog_log "boot finished with problems - closing the progress window"
        fi
        kill "$ZENITY_PID" 2>/dev/null
    fi
    wait "$ZENITY_PID" 2>/dev/null
    _rc=$?
    # The writer must not outlive its window either (Cancel path).
    pkill -P $$ feed_zenity 2>/dev/null || true
    dialog_log "progress dialog finished via zenity (zenity rc=${_rc:-?})"
else
    # GTK (the PREFERRED backend): polls the status file itself and renders
    # the full task list - done / current / pending - so the operator can see
    # which step is running, which is exactly what the single zenity bar could
    # never show. No stdin pipe is needed, and it exits on its own shortly
    # after the stamp appears, so there is no window to close by PID and no
    # stale dialog left over the reboot approval.
    python3 "$LSL_PROGRESS_GTK" \
        --status-file="$STATUS" \
        --stamp="$STAMP" \
        --title="lsl-usb first boot" \
        --text="Preparing your USB system (first boot)..." \
        --width=480 2>>"$DIALOG_LOG"
    dialog_log "progress dialog finished via gtk (consumer rc=$?)"
fi
exit 0
