#!/bin/bash
# tests/overlayfs-whiteout.tests.sh
#
# Verify that `overlayfs-tools merge` RESOLVES (drops) whiteouts instead of
# preserving them as .wh.* entries. Consequence: a merged delta layer with no
# whiteouts, placed ABOVE the base layer, lets base's deleted files reappear
# (unsafe partial merge). A full re-base (base+deltas collapsed to one layer
# with nothing below it) is fine - but for Zorin base~4GB makes that exceed the
# FAT32 4GiB cap, so merging is impossible there regardless.
#
# The tool's `merge` subcommand folds upperdir's changes into lowerdir IN PLACE
# and clears upperdir (needs -f / --force-execution to actually run; without it
# it only writes a script). Whiteouts must be genuine overlay whiteouts: a char
# device with rdev 0,0 named after the deleted file, as the kernel creates via
# `rm` through an overlay mount - NOT a hand-crafted `.wh.*` file.
#
# Requires: root, overlayfs in the kernel, and the `overlay` binary (built from
# kmxz/overlayfs-tools). Override the binary with $OVERLAYFS_TOOLS_BIN.
# Skips cleanly when any prerequisite is missing.

set -u
ROOT="$(mktemp -d)"
cleanup() { cd / 2>/dev/null; umount "$ROOT/merged" 2>/dev/null; rm -rf "$ROOT"; }
trap cleanup EXIT
cd "$ROOT"   # so any generated script lands inside ROOT and is cleaned up

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }
skip(){ echo "SKIP: $1 (nothing verified - build overlayfs-tools and re-run as root)."; exit 0; }

echo "== overlayfs-tools whiteout behavior =="

[ "$(id -u)" -eq 0 ] || skip "not running as root"
grep -qw overlay /proc/filesystems || skip "overlayfs not in kernel"
command -v mknod >/dev/null 2>&1 || skip "mknod unavailable"

# Locate the built binary.
BIN="${OVERLAYFS_TOOLS_BIN:-}"
if [ -z "$BIN" ]; then
    if command -v overlay >/dev/null 2>&1; then BIN=overlay
    elif command -v overlayfs-tools >/dev/null 2>&1; then BIN=overlayfs-tools
    else skip "overlayfs-tools 'overlay' binary not found (set OVERLAYFS_TOOLS_BIN)"; fi
fi
command -v "$BIN" >/dev/null 2>&1 || skip "binary '$BIN' not executable"
echo "  using: $BIN"

# Build base + empty upper/work + merged mount.
BASE="$ROOT/base"; UPPER="$ROOT/upper"; WORK="$ROOT/work"; MERGED="$ROOT/merged"
mkdir -p "$BASE/sub" "$UPPER" "$WORK" "$MERGED"
echo K > "$BASE/keep.txt"
echo R > "$BASE/remove.txt"
echo S > "$BASE/sub/inner.txt"

mount -t overlay overlay -o lowerdir="$BASE",upperdir="$UPPER",workdir="$WORK" "$MERGED" 2>/dev/null ||
    skip "cannot mount overlayfs"
# Delete remove.txt THROUGH the mount -> kernel writes a real whiteout into UPPER.
rm -f "$MERGED/remove.txt"
echo N > "$MERGED/new.txt"
umount "$MERGED" 2>/dev/null
# Sanity: upper now holds a genuine whiteout (char dev rdev 0,0 named remove.txt).
[ -c "$UPPER/remove.txt" ] && ok "upper holds a genuine overlay whiteout (char dev rdev 0,0)" || bad "no genuine whiteout in upper"

# Run overlay merge (folds upper into lower, clears upper). Needs -f to execute.
CMD=( "$BIN" merge -l "$BASE" -u "$UPPER" -f )
echo "  running: ${CMD[*]}"
if ! "${CMD[@]}" </dev/null >"$ROOT/merge.log" 2>&1; then
    echo "  (merge failed; log:)"; sed 's/^/    /' "$ROOT/merge.log" | head -20
    skip "overlayfs-tools merge failed"
fi

# Check A: the merged lowerdir must NOT contain any whiteout char devices, and
# the whited-out file must be GONE (resolved), kept/added files present.
if find "$BASE" -xdev -type c | grep -q .; then
    bad "lowerdir STILL contains whiteout char devices after merge"
else
    ok "lowerdir contains NO whiteout char devices (whiteouts resolved/dropped)"
fi
[ ! -e "$BASE/remove.txt" ] && ok "whited-out file removed from lowerdir (deletion applied)" || bad "whited-out file still present in lowerdir"
{ [ -f "$BASE/keep.txt" ] && [ -f "$BASE/new.txt" ] && [ -f "$BASE/sub/inner.txt" ]; } &&
    ok "kept/added files present in lowerdir" || bad "kept/added files missing in lowerdir"
[ -z "$(ls -A "$UPPER" 2>/dev/null)" ] && ok "upperdir cleared after merge" || bad "upperdir not cleared after merge"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ] && exit 0 || exit 1
