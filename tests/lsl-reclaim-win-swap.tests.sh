#!/bin/bash
# tests/lsl-reclaim-win-swap.tests.sh - unit tests for bin/lsl-reclaim-win-swap.sh
#
# Run: bash tests/lsl-reclaim-win-swap.tests.sh   (also wired into build.sh)
set -u

PASS=0; FAIL=0
assert() { # $1 = condition (eval'd), $2 = name
    if eval "$1"; then
        PASS=$((PASS + 1)); echo "  PASS: $2"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: $2"
    fi
}

# Source the real functions (no side effects at source time; the dispatch is
# guarded by BASH_SOURCE != $0).
SCRIPT_DIR="$(cd "$(dirname "$0")/../bin" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lsl-reclaim-win-swap.sh"

# --- pure helpers ------------------------------------------------------------
assert '[ "$(win_letter_of /mnt/c)" = C ]'            'win_letter_of /mnt/c -> C'
assert '[ "$(win_letter_of /mnt/z)" = Z ]'            'win_letter_of /mnt/z -> Z'
assert '! win_letter_of /mnt/c/foo'                   'win_letter_of rejects deep path'
assert '[ "$(to_win_path /mnt/c/lsl-swap-abc.tmp)" = "C:\lsl-swap-abc.tmp" ]' \
                                                    'to_win_path root file'
assert '[ "$(to_win_path /mnt/d/Users/u/AppData/Local/Packages/p/LocalState/swapfile.vhdx)" = "D:\Users\u\AppData\Local\Packages\p\LocalState\swapfile.vhdx" ]' \
                                                    'to_win_path deep WSL2 swapfile'
assert '[ "$(to_win_path /not/a/drive/path)" = "/not/a/drive/path" ]' \
                                                    'to_win_path non-windows path passes through'

# volume_rw: mock findmnt/mountpoint
mountpoint() { return 0; }
findmnt() { case "$*" in *OPTIONS*) echo "rw,relatime,ntfs3" ;; *) echo ntfs3 ;; esac; }
assert 'volume_rw /mnt/c' 'volume_rw: rw mount'
findmnt() { case "$*" in *OPTIONS*) echo "ro,ntfs3" ;; *) echo ntfs3 ;; esac; }
assert '! volume_rw /mnt/c' 'volume_rw: ro mount'
findmnt() { return 1; }
assert '! volume_rw /mnt/c' 'volume_rw: unmounted'

# --- Windows cleanup artifact generation (real files, temp volume) ----------
T="$(mktemp -d)"; V="$T/mntc"
mkdir -p "$V/lsl" "$V/Windows/System32/config" "$V/Windows/System32/Tasks"
touch "$V/Windows/System32/config/SYSTEM"
STATE_FILE="$T/state"
printf '%s|%s|%s|%s\n' "$V/lsl-swap-aaa.tmp" /dev/loop1 /dev/zram1 "C:\lsl-swap-aaa.tmp" > "$STATE_FILE"
printf '%s|%s|%s|%s\n' "$V/LocalState/lsl-swap-bbb.tmp" /dev/loop2 /dev/zram2 "D:\LocalState\lsl-swap-bbb.tmp" >> "$STATE_FILE"

emit_windows_cleanup_under "$V"

assert '[ -f "$V/lsl/lsl-reclaim-manifest.txt" ]' 'manifest written'
assert '[ -f "$V/lsl/lsl-reclaim-cleanup.ps1" ]'  'powershell cleanup written'
assert '[ -f "$V/Windows/System32/Tasks/LSL-DeleteReclaimedSwap" ]' 'scheduled task written'

manifest="$(cat "$V/lsl/lsl-reclaim-manifest.txt")"
assert 'printf "%s\n" "$manifest" | grep -qF "C:\lsl-swap-aaa.tmp"' 'manifest has C: pagefile temp'
assert 'printf "%s\n" "$manifest" | grep -qF "D:\LocalState\lsl-swap-bbb.tmp"' 'manifest has D: swapfile temp'

# Task must be UTF-16LE with BOM (what Task Scheduler expects).
bom="$(od -An -tx1 -N2 < "$V/Windows/System32/Tasks/LSL-DeleteReclaimedSwap" | tr -d ' ')"
assert '[ "$bom" = "fffe" ]' 'task file is UTF-16LE with BOM'
if command -v iconv >/dev/null 2>&1; then
    assert 'iconv -f UTF-16 -t UTF-8 "$V/Windows/System32/Tasks/LSL-DeleteReclaimedSwap" 2>/dev/null | grep -q BootTrigger' 'task has BootTrigger'
else
    echo '  SKIP: task BootTrigger check (iconv unavailable)'
fi

# drop_windows_cleanup with no reclaimed files is a no-op (no manifest written).
rm -f "$STATE_FILE"; : > "$STATE_FILE"
rm -f "$V/lsl/lsl-reclaim-manifest.txt"
drop_windows_cleanup
assert '[ ! -f "$V/lsl/lsl-reclaim-manifest.txt" ]' 'drop_windows_cleanup no-op when nothing reclaimed'

rm -rf "$T"

echo "lsl-reclaim-win-swap tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
