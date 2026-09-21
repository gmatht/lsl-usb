#!/bin/bash
# lsl-boot-time.sh - measure live-boot startup time and compare boots.
#
# Three ways to use it:
#   lsl-boot-time.sh --mark        early boot service (lsl-boot-stamp.service):
#                                  stamp the boot start time.
#   lsl-boot-time.sh --desktop     desktop autostart (lsl-boot-time.desktop):
#                                  stamp desktop-ready, run the precache workload
#                                  probe, and append this boot's row to the log.
#   lsl-boot-time.sh               print the log + comparison table.
#
# Each boot row: seq | date | label | kernel_s | userspace_s | desktop_ms |
#                probe_ms | precache_entries | session
#   desktop_ms = time from --mark to --desktop (boot -> login desktop usable);
#                approximated from /proc/uptime when no --mark stamp exists
#                (lsl-boot-stamp.service is not installed on live boots)
#   probe_ms  = time to re-read the first N precache entries; LOW means the
#               page-cache warmup is working, HIGH means the reads hit the USB.
#   precache_entries = size of /cdrom/lsl-precache.list (0 = not profiled yet).
#   session    = user@display recording the row (the autostart user).
#
# Persistence from the unprivileged desktop session: vfat /cdrom is
# root-owned (fmask applies to every file, pre-created or not), so --desktop
# cannot write the stick directly. It tries, in order: direct write (root
# or user-writable mounts), passwordless sudo (live ISO autologin user),
# the world-writable RAM mirror /run/lsl-firstboot/boot-times.log (created
# by onboot.sh / lsl-firstboot.sh; flushed to the stick by the firstboot
# finale and captured by lsl-diag.sh), then /tmp. Two post-mortems
# (2026-09-15/16, 2026-09-21) lost "was the desktop up yet?" because every
# copy was RAM-only - this row is the answer to that question.
set -euo pipefail

STATE="${LSL_BOOT_STATE:-/run/lsl-boot.state}"
LOG="${LSL_BOOT_LOG:-/cdrom/casper/boot-times.log}"
PROBE_LIST="${LSL_PRECACHE_LIST:-/cdrom/lsl-precache.list}"
PROBE_N="${LSL_BOOT_PROBE_N:-40}"

now_ms() { date +%s%N; }

ensure_log() {
    if [[ "$LOG" == /cdrom/* ]]; then
        mount /cdrom -o remount,rw 2>/dev/null || true   # root only; harmless as user
    fi
    mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
    if [ ! -w "$(dirname "$LOG")" ] && [ ! -w "$LOG" ] && [ "$(id -u)" -ne 0 ]; then
        # Unprivileged desktop session on a root-owned vfat stick: live
        # ISOs give the autologin user passwordless sudo - keep writing
        # the stick directly via it; else the RAM mirror; else /tmp.
        if sudo -n true 2>/dev/null; then
            SUDO_LOG=1
        elif [ -w /run/lsl-firstboot ]; then
            LOG=/run/lsl-firstboot/boot-times.log
        else
            LOG=/tmp/boot-times.log   # e.g. not a live session / /cdrom unwritable
        fi
    fi
}

log_append() {
    # log_append ROW - append one TSV row to $LOG, via sudo when only root
    # can write it (best-effort: never fail the measurement on log trouble).
    if [ "${SUDO_LOG:-0}" = "1" ]; then
        sudo -n /bin/sh -c 'printf "%s\n" "$1" >> "$2"' boot-time "$1" 2>/dev/null && return 0
    fi
    printf '%s\n' "$1" >>"$LOG" 2>/dev/null || true
}

probe_ms() {
    [ -f "$PROBE_LIST" ] || { echo 0; return; }
    local t0 t1
    t0="$(now_ms)"
    head -n "$PROBE_N" "$PROBE_LIST" | while IFS= read -r f; do
        [ -f "$f" ] || continue
        dd if="$f" of=/dev/null bs=1M count=4 2>/dev/null || true   # up to 4 MB/file
    done
    t1="$(now_ms)"
    echo $(( (t1 - t0) / 1000000 ))
}

record_boot() {
    local label="$1" start_ns boot_ns desktop_ms k u probe_s listn seq
    start_ns="$(now_ms)"
    boot_ns="$(sed -n 's/^boot_start_ms=//p' "$STATE" 2>/dev/null | tail -n 1 || true)"
    if [ -n "$boot_ns" ]; then
        desktop_ms=$(( (start_ns - boot_ns) / 1000000 ))   # ns -> ms
    else
        # No --mark stamp (lsl-boot-stamp.service not installed on live
        # boots): approximate from kernel uptime. Includes firmware+kernel
        # time, but still answers "was the desktop up before firstboot
        # finished?" - the question that lost two post-mortems.
        desktop_ms=$(( $(sed -n 's/^\([0-9]\+\)\..*/\1/p' /proc/uptime 2>/dev/null || echo 0) * 1000 ))
    fi

    k="$(systemd-analyze time 2>/dev/null | sed -nE 's/.*kernel = ([0-9.]+)s.*/\1/p' || true)"
    u="$(systemd-analyze time 2>/dev/null | sed -nE 's/.*userspace = ([0-9.]+)s.*/\1/p' || true)"
    [ -n "$k" ] || k="-"
    [ -n "$u" ] || u="-"

    probe_s="$(probe_ms)"
    listn="$(grep -vcE '^[[:space:]]*(#|$)' "$PROBE_LIST" 2>/dev/null || echo 0)"

    local sess
    sess="$(id -un 2>/dev/null || echo '?')@${DISPLAY:-${WAYLAND_DISPLAY:-no-display}}"
    ensure_log
    seq="$(($(tail -n 1 "$LOG" 2>/dev/null | cut -f1 || echo 0) + 1))"
    log_append "$(printf '%d\t%s\t%s\t%s\t%s\t%d\t%d\t%d\t%s' \
        "$seq" "$(date '+%F %T')" "$label" "$k" "$u" "$desktop_ms" "$probe_s" "$listn" "$sess")"
    echo "boot #$seq ($label): desktop ready in ${desktop_ms}ms | probe ${probe_s}ms | precache entries ${listn} | $sess"
}

case "${1:-}" in
    --mark)
        [ -e "$STATE" ] && exit 0
        mkdir -p "$(dirname "$STATE")" 2>/dev/null || true
        echo "boot_start_ms=$(now_ms)" > "$STATE"
        exit 0
        ;;
    --desktop)
        if [ ! -e "$STATE" ]; then
            mkdir -p "$(dirname "$STATE")" 2>/dev/null || true
            echo "boot_start_ms=$(now_ms)" > "$STATE"
        fi
        record_boot "desktop"
        ;;
    *)
        if [ ! -f "$LOG" ]; then
            echo "No measurements yet (log: $LOG). Run --desktop after boot, or wait for the autostart entry."
            exit 0
        fi
        echo "Boot time log: $LOG"
        printf '%-4s %-19s %-9s %-10s %-9s %-8s %-8s %s\n' \
            "seq" "time" "kernel" "userspace" "desktop_ms" "probe_ms" "precache" "session"
        awk -F'\t' '{
            printf "%-4s %-19s %-9s %-10s %-9s %-8s %-8s %s\n", $1, $2, $4, $5, $6, $7, $8, $9
        }' "$LOG"
        echo ""
        echo "desktop_ms = boot to desktop-ready; probe_ms = re-read of the precache list"
        echo "(low = warm cache). Compare an early boot (no precache) with a later one."
        # Trend: first vs latest probe.
        first_probe="$(head -n 2 "$LOG" 2>/dev/null | tail -n 1 | cut -f7)"
        last_probe="$(tail -n 1 "$LOG" 2>/dev/null | cut -f7)"
        if [ -n "$first_probe" ] && [ -n "$last_probe" ] && [ "$first_probe" -gt 0 ]; then
            if [ "$last_probe" -lt "$first_probe" ]; then
                echo "Trend: probe_ms $first_probe -> $last_probe (improved by $(( first_probe - last_probe )) ms)"
            elif [ "$last_probe" -gt "$first_probe" ]; then
                echo "Trend: probe_ms $first_probe -> $last_probe (worse by $(( last_probe - first_probe )) ms)"
            else
                echo "Trend: probe_ms unchanged at $first_probe ms"
            fi
        fi
        # Auto-suggest: if the latest probe is slow and there is no precache list,
        # point the user at the profiler.
        last_probe="$(tail -n 1 "$LOG" 2>/dev/null | cut -f7)"
        last_list="$(tail -n 1 "$LOG" 2>/dev/null | cut -f8)"
        if [ -n "$last_probe" ] && [ "$last_probe" -gt 200 ] && [ "${last_list:-0}" -eq 0 ]; then
            echo ""
            echo "Suggestion: probe_ms is high and no precache list exists - run"
            echo "  sudo bin/lsl-precache-profile.sh"
            echo "to record the startup-critical files, then reboot to compare."
        fi
        ;;
esac
