#!/bin/bash
# check-stick-drift.sh - detect repo/stick SCRIPT drift.
#
# WHY THIS EXISTS
# ---------------
# Most fixes land twice: once in the repo, once by hand in the LIVE stick under
# /cdrom (because the repo is on the developer's Windows box and the stick is
# booted on the machine where the bug was observed). Every fix session in
# WHYFAIL5..13 ended with "synced to /cdrom/bin/...", and each time the sync was
# a manual copy in one direction. Nothing verified the result, so the two
# directions fail independently and silently:
#
#   * repo fixed, stick stale   -> the bug is still on the device that shows it
#   * stick fixed, repo stale   -> the next build.sh / lslsetup re-ships the bug
#
# The z0 layer had exactly this failure mode and it is what motivated
# check-z0-freshness.sh (a STALE-BLOB check). This script is the sibling guard
# for the hand-written shell that is NOT embedded in a blob: bin/, misc/,
# onboot.sh, install.ps1.
#
# It compares the repo against a mounted stick, and normalises CRLF before
# comparing - the same CRLF class of bug that has broken LSL_DATA_DIR detection
# and the bash-log hook more than once (see lsl-common.sh lsl_load_config).
#
# USAGE
#   bash check-stick-drift.sh [REPO_ROOT] [STICK_MOUNT]
#   bash check-stick-drift.sh            # autodetect repo; STICK=/cdrom
#
# Exit 0 = no drift (or no stick reachable). Exit 1 = drift found. Exit 2 = bad
# usage. A missing stick is NOT drift: this guard must stay runnable on the
# Windows dev box, where there is no stick at all.

set -uo pipefail

find_root() {
    local d
    if [ -n "${1:-}" ]; then printf '%s' "$1"; return; fi
    d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    while [ "$d" != "/" ]; do
        [ -f "$d/misc/build-z0.sh" ] && { printf '%s' "$d"; return; }
        d="$(dirname "$d")"
    done
    return 1
}

ROOT="$(find_root "${1:-}")" || {
    echo "check-stick-drift: cannot find repo root (no misc/build-z0.sh)." >&2
    exit 2
}
STICK="${2:-${LSL_CDROM:-/cdrom}}"

echo "repo:  $ROOT"
echo "stick: $STICK"

# A stick is only a stick if it carries the LSL layout.
if [ ! -d "$STICK/bin" ] || [ ! -d "$STICK/misc" ]; then
    echo "No stick at $STICK (no bin/ and misc/). Nothing to compare - OK."
    echo "Run this on the booted stick, or pass the mount: bash check-stick-drift.sh $ROOT /cdrom"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Compare content only: CR is stripped so a Windows checkout (autocrlf) does not
# read as drift, and trailing whitespace on the last line is ignored.
norm() { tr -d '\r' < "$1" 2>/dev/null | sed -e 's/[[:space:]]*$//'; }

drift=0
compared=0
same=0
missing=0

# The files that a fix session actually edits on the stick.
FILES="
bin/config.sh
bin/lsl-common.sh
bin/lsl-flush-home.sh
bin/lsl-mount-home.sh
bin/mount_all.sh
bin/uphome
bin/squashfs_config.sh
misc/lsl-firstboot.sh
misc/lsl-firstboot-progress.sh
misc/kitty.conf
onboot.sh
install.ps1
"

for rel in $FILES; do
    r="$ROOT/$rel"
    s="$STICK/$rel"
    [ -f "$r" ] || continue          # not in the repo layout; skip quietly
    if [ ! -f "$s" ]; then
        echo "  MISSING on stick: $rel"
        missing=$((missing + 1))
        drift=1
        continue
    fi
    # Always normalise and compare. Do NOT try to short-circuit with a raw
    # cmp of a previous iteration's scratch files: those are stale by
    # definition and would make every file after the first silently "match".
    norm "$r" > "$TMP/r"; norm "$s" > "$TMP/s"
    if cmp -s "$TMP/r" "$TMP/s"; then
        same=$((same + 1))
        continue
    fi
    compared=$((compared + 1))
    echo "  DRIFT: $rel"
    echo "    repo:  $(wc -c < "$r" | tr -d ' ') bytes"
    echo "    stick: $(wc -c < "$s" | tr -d ' ') bytes"
    echo "    diff:  diff -u $s $r | head -40"
    drift=1
done

echo "compared $compared drifting file(s); $same identical; $missing missing on stick"

if [ "$drift" -eq 0 ]; then
    echo "OK: repo and stick agree on every checked script."
    exit 0
fi

cat >&2 <<EOF

DRIFT DETECTED between the repo and $STICK.

Fix the direction you intended:
  stick -> repo :  cp $STICK/<path> $ROOT/<path>     # keep the live fix, adopt it
  repo  -> stick:  cp $ROOT/<path>  $STICK/<path>    # ship the repo's fix

Remember the ONE-WAY hazards:
  * the repo is the source of truth for the next build; a stick-only fix is
    re-shipped-over by the next lslsetup/build.sh run.
  * a repo-only fix stays on the developer's machine; the stick boots the old
    script until it is copied across.
EOF
exit 1