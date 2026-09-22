#!/bin/bash
# lsl-restore-stick-from-repo.sh - re-stage the stick's repo-managed files
# from the source checkout (C:/GitHub/lsl-usb) into a copy of the FAT tree.
#
# Why: /cdrom/onboot.sh and /cdrom/lsl-usb.env were zeroed on the live stick
# (a `cp -a X X` same-file error truncated them before it exited 1 - see
# WHYFAIL6.md "collateral damage"). The stick has no pristine copy, but the
# repo does. This script refuses to run on an empty repo so it cannot zero
# anything a second time.
set -euo pipefail

REPO="${1:-/cdrom/pi/repo}"
DEST="${2:-/cdrom}"
[ -f "$REPO/onboot.sh" ] && [ -s "$REPO/onboot.sh" ] || {
    echo "lsl-restore: refusing: $REPO/onboot.sh missing or empty" >&2; exit 1; }

echo "lsl-restore: staging repo files into $DEST"
for f in onboot.sh lsl-usb.env; do
    if [ -s "$REPO/$f" ]; then
        cp -f "$REPO/$f" "$DEST/$f"
        echo "  $f <- $REPO/$f ($(stat -c %s "$DEST/$f") bytes)"
    fi
done
for d in bin systemd fuse misc; do
    [ -d "$REPO/$d" ] || continue
    mkdir -p "$DEST/$d"
    find "$REPO/$d" -maxdepth 1 -type f -print0 2>/dev/null |
        while IFS= read -r -d '' f; do
            cp -f "$f" "$DEST/$d/$(basename "$f")"
            echo "  $d/$(basename "$f")"
        done
done
sync
echo "lsl-restore: done"
