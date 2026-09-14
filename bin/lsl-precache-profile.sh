#!/bin/bash
# lsl-precache-profile.sh - record the files read during a live boot/desktop
# session and write /cdrom/lsl-precache.list, which lsl-precache.service
# replays on future boots to warm the page cache.
#
# Run this once after the system is set up and has been used normally for a
# boot or two (so apt-installed packages are in a stable layer). Use the
# machine normally while it records - desktop apps, browsers, lsl itself.
#
# Usage: sudo bin/lsl-precache-profile.sh [seconds] [output]
#   defaults: 300 seconds -> /cdrom/lsl-precache.list
set -euo pipefail

# Tool check first: only builtins are used here, so this also reports
# cleanly with an empty PATH (and before creating any temp files).
command -v fatrace >/dev/null 2>&1 || { echo "ERROR: fatrace not installed (apt install fatrace)" >&2; exit 1; }

SECS="${1:-300}"
OUT="${2:-/cdrom/lsl-precache.list}"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

mount /cdrom -o remount,rw 2>/dev/null || true

echo "Recording file reads for ${SECS}s. Use the machine normally; the desktop must be up."
fatrace --filter=RO --seconds="$SECS" 2>/dev/null |
    awk '{print $NF}' |                          # fatrace: "<comm>(<pid>): <verb> <path>"
    grep -vE '^/(proc|sys|dev|run|tmp)/' |
    grep -v '^$' |
    awk '!seen[$0]++' > "$TMP"                   # first-seen order = boot-critical first

# Keep only paths that are real regular files (they back squashfs/FAT blocks).
: > "$OUT"
while IFS= read -r f; do
    [ -f "$f" ] && echo "$f" >> "$OUT"
done < "$TMP"
sync
echo "Wrote $(wc -l < "$OUT") paths to $OUT"
