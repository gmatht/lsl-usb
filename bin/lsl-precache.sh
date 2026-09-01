#!/bin/bash
# lsl-precache.sh - warm the kernel page cache so reads hit RAM, not the USB.
#
# Order of operations, every boot:
#   1) HOT files first: the startup-critical set recorded by
#      lsl-precache-profile.sh (/cdrom/lsl-precache.list). These are what the
#      desktop needs in its first minute - warm them before anything else.
#   2) FULL image only AFTER the hot files finish, and only if the whole image
#      (squashfs layers + home.sfs) is under half of total RAM: warm everything
#      so later reads never touch the USB. The hot blocks are already cached,
#      so this pass only tops up the rest.
# Both passes run at idle-low priority; the full pass stops early if unused RAM
# drops below PRECACHE_MIN_FREE_PCT (default 10) so we never aggravate memory
# pressure. A no-op when there is nothing to warm.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lsl-common.sh" 2>/dev/null || true
lsl_load_config 2>/dev/null || true

LIST="${PRECACHE_LIST:-/cdrom/lsl-precache.list}"
FULL_TARGETS="${PRECACHE_TARGETS:-}"
MIN_FREE_PCT="${PRECACHE_MIN_FREE_PCT:-10}"
# USB mass storage (BOT) executes one command at a time, so parallel warmers
# do not add throughput - they only churn the queue. Sequential (1) is both
# fastest and gentlest for a typical stick; raise only for UAS/SSD sticks.
MAXP="${PRECACHE_MAX:-1}"

# Low priority for the whole process tree.
renice -n 15 $$ >/dev/null 2>&1 || true
command -v ionice >/dev/null 2>&1 && ionice -c 3 -p $$ >/dev/null 2>&1 || true

# ionice classes are only honored by bfq/cfq; mq-deadline ignores them.
# Best-effort: switch the /cdrom block device to bfq so idle-class yields.
cdrom_dev="$(findmnt -no SOURCE /cdrom 2>/dev/null || true)"
if [[ "$cdrom_dev" == /dev/* ]]; then
    blk="$(lsblk -no PKNAME "$cdrom_dev" 2>/dev/null | head -n 1)"
    [ -n "$blk" ] || blk="${cdrom_dev##*/}"
    blk="${blk%p[0-9]*}"
    blk="${blk%%[0-9]*}"
    sched="/sys/block/${blk}/queue/scheduler"
    if [ -w "$sched" ] && grep -qw bfq "$sched" 2>/dev/null; then
        echo bfq > "$sched" 2>/dev/null || true
    fi
fi

mem_free_pct() {
    awk '/MemAvailable/{a=$2} /MemTotal/{t=$2} END{if (t>0) printf "%d", a*100/t}' /proc/meminfo
}

total_ram_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo)"

# Gather the full-image targets and decide whether a FULL pass is affordable.
if [ -z "$FULL_TARGETS" ]; then
    for f in /cdrom/casper/filesystem.squashfs /cdrom/casper/filesystem_*.squashfs /cdrom/home.sfs; do
        [ -f "$f" ] || continue
        FULL_TARGETS="$FULL_TARGETS $f"
    done
fi

# Optional speed-up: if the user copied the squashfs layers to the internal HDD
# (lsl-copy-sfs-hdd.sh, or the Windows installer wizard), warm the page cache
# from those copies instead of the slow USB stick. Only trust a copy whose size
# matches the live USB layer, so a stale copy (e.g. after `uproot` appended a
# layer) is ignored and we fall back to reading the USB.
if [ "${LSL_SFS_HDD_CACHE:-0}" = "1" ]; then
    hdd_targets=""
    for f in /cdrom/casper/filesystem.squashfs /cdrom/casper/filesystem_*.squashfs /cdrom/home.sfs; do
        [ -f "$f" ] || continue
        hdd="${LSL_DATA_DIR:-/mnt/c/Users/lsl-usb}/sfs/$(basename "$f")"
        if [ -f "$hdd" ] && [ "$(stat -c %s "$hdd" 2>/dev/null || echo 0)" = "$(stat -c %s "$f" 2>/dev/null || echo 0)" ]; then
            hdd_targets="$hdd_targets $hdd"
        fi
    done
    if [ -n "$hdd_targets" ]; then
        echo "lsl-precache: using HDD copies for FULL warm (LSL_SFS_HDD_CACHE=1)."
        FULL_TARGETS="$hdd_targets"
    fi
fi
targets_kb=0
for f in $FULL_TARGETS; do
    sz="$(stat -c %s "$f" 2>/dev/null || echo 0)"
    targets_kb=$(( targets_kb + sz / 1024 ))
done

full_ok=0
[ "$targets_kb" -gt 0 ] && [ $(( targets_kb * 2 )) -lt "$total_ram_kb" ] && full_ok=1

warm_cmd='f="$1"; [ -r "$f" ] || exit 0; if command -v vmtouch >/dev/null 2>&1; then vmtouch -t -m 512M -q "$f" >/dev/null 2>&1; else dd if="$f" of=/dev/null bs=4M 2>/dev/null; fi'

# --- 1) hot files first (startup-critical; always before the full pass) ----
if [ -f "$LIST" ]; then
    echo "lsl-precache: warming hot files (startup list)..."
    grep -vE '^[[:space:]]*(#|$)' "$LIST" 2>/dev/null |
        xargs -r -d '\n' -P "$MAXP" -n 1 bash -c "$warm_cmd" _ || true
    echo "lsl-precache: hot files done."
fi

# --- 2) full image, only after the hot files finished ----------------------
if [ "$full_ok" -eq 1 ]; then
    echo "lsl-precache: FULL image warm - ${targets_kb} KB < 50% RAM, starting after hot files."
    for f in $FULL_TARGETS; do
        echo "  warming $(basename "$f")"
        sz_bytes="$(stat -c %s "$f" 2>/dev/null || echo 0)"
        chunks=$(( (sz_bytes + 16777215) / 16777216 ))   # ceil(size/16M)
        off=0
        while [ "$off" -lt "$chunks" ] && [ "$(mem_free_pct)" -ge "$MIN_FREE_PCT" ]; do
            dd if="$f" of=/dev/null bs=16M skip="$off" count=1 2>/dev/null
            off=$(( off + 1 ))
        done
    done
    echo "lsl-precache: full image warm finished (memory floor ${MIN_FREE_PCT}%)."
fi

exit 0
