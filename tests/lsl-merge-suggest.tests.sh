#!/bin/bash
# tests/lsl-merge-suggest.tests.sh - unit test for the merge-suggestion trigger
# logic in misc/lsl-merge-suggest.sh (the two "pop the GUI" conditions).
#
# Conditions under test:
#   1) suggest when merging would reduce the layer count by >= 3, AND the merge
#      fits the FAT32 4 GiB ceiling on /cdrom;
#   2) suggest when we have been able to reduce (feasible AND >= 1 layer to drop)
#      for at least a week (tracked via a persistent streak file).
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/misc/lsl-merge-suggest.sh"
[ -f "$SCRIPT" ] || { echo "SKIP: $SCRIPT missing"; exit 0; }
# shellcheck source=/dev/null
source "$SCRIPT"

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }
eq()  { [ "$1" = "$2" ] && ok "$3" || bad "$3 (got '$1' want '$2')"; }

# Build a fake casper dir: 1 base layer + $2 z-layers, each $3 bytes.
mkcasper() {
    local d="$1" n="$2" sz="$3" i
    rm -rf "$d"; mkdir -p "$d"
    truncate -s "$sz" "$d/filesystem.squashfs"
    for i in $(seq 1 "$n"); do
        truncate -s "$sz" "$d/filesystem_z$(printf '%03d' "$i").squashfs"
    done
}

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# S1: a single layer -> never suggest (nothing to merge).
CASPER="$ROOT/c1"; STATE="$ROOT/s1"; rm -f "$STATE/merge-streak" 2>/dev/null
mkdir -p "$CASPER"; truncate -s 1M "$CASPER/filesystem.squashfs"
lsl_cdrom_is_vfat() { return 1; }
lsl_merge_should_suggest; eq "$?" 1 "S1 single layer -> no suggest"
[ ! -e "$STATE/merge-streak" ] && ok "S1 streak cleared" || bad "S1 streak should be cleared"

# S2: 4 layers, not vfat, small -> suggest by >=3 reduction.
CASPER="$ROOT/c2"; STATE="$ROOT/s2"; rm -f "$STATE/merge-streak" 2>/dev/null
mkcasper "$CASPER" 3 1M
lsl_merge_should_suggest; eq "$?" 0 "S2 4 layers -> suggest (by3)"
eq "$LSL_MERGE_REDUCTION" 3 "S2 reduction=3"
eq "$LSL_MERGE_FEASIBLE" 1 "S2 feasible"

# S3: 4 layers, vfat, total comfortably under cap -> suggest.
CASPER="$ROOT/c3"; STATE="$ROOT/s3"; rm -f "$STATE/merge-streak" 2>/dev/null
mkcasper "$CASPER" 3 500K
lsl_cdrom_is_vfat() { return 0; }
lsl_merge_should_suggest; eq "$?" 0 "S3 vfat under cap -> suggest"
eq "$LSL_MERGE_FEASIBLE" 1 "S3 feasible"

# S4: 4 layers, vfat, total over the 4 GiB cap -> do NOT suggest (Zorin case),
#     and the streak must be cleared (merging is not currently possible).
CASPER="$ROOT/c4"; STATE="$ROOT/s4"; rm -f "$STATE/merge-streak" 2>/dev/null
mkcasper "$CASPER" 3 2G
lsl_cdrom_is_vfat() { return 0; }
lsl_merge_should_suggest; eq "$?" 1 "S4 vfat over cap -> no suggest"
[ ! -e "$STATE/merge-streak" ] && ok "S4 streak cleared" || bad "S4 streak should be cleared"

# S5: a week-old "worth merging" streak with only 2 layers (reduction 1) -> suggest.
CASPER="$ROOT/c5"; STATE="$ROOT/s5"; mkdir -p "$STATE"
lsl_cdrom_is_vfat() { return 1; }
echo "$(( $(date +%s) - 8*86400 ))" > "$STATE/merge-streak"
mkcasper "$CASPER" 1 1M
lsl_merge_should_suggest; eq "$?" 0 "S5 week-old streak (2 layers) -> suggest"

# S6: a fresh streak with only 2 layers -> not yet a week, no suggest (but streak starts).
CASPER="$ROOT/c6"; STATE="$ROOT/s6"; rm -f "$STATE/merge-streak" 2>/dev/null
lsl_cdrom_is_vfat() { return 1; }
mkcasper "$CASPER" 1 1M
lsl_merge_should_suggest; eq "$?" 1 "S6 fresh streak (2 layers) -> no suggest yet"
[ -e "$STATE/merge-streak" ] && ok "S6 streak started" || bad "S6 streak should start"

# --- remember-choice: Always / Yes / No / Never on the same dialog -------
# The dialog offers all four; the sticky answers persist in merge-choice.
STATE="$ROOT/choice"; mkdir -p "$STATE"
eq "$(lsl_merge_choice)" "" "C0 no file -> undecided"
lsl_merge_record_choice never
eq "$(lsl_merge_choice)" "never" "C1 record never"
lsl_merge_record_choice always
eq "$(lsl_merge_choice)" "always" "C2 record always"
printf 'bogus\n' > "$STATE/merge-choice"
eq "$(lsl_merge_choice)" "" "C3 corrupt content -> undecided"
rm -f "$STATE/merge-choice"

# Each selection dispatches correctly (mock the merge launcher).
MERGED=0
lsl_merge_do() { MERGED=$((MERGED + 1)); }
lsl_merge_handle_choice "Merge now"; eq "$MERGED" 1 "C4 Merge now merges once"
[ ! -e "$STATE/merge-choice" ] && ok "C4 Merge now records nothing" || bad "C4 Merge now must not persist"
lsl_merge_handle_choice "Always merge when suggested"; eq "$MERGED" 2 "C5 Always merges now"
eq "$(lsl_merge_choice)" "always" "C5 Always persists"
lsl_merge_handle_choice "Later"; eq "$MERGED" 2 "C6 Later merges nothing"
eq "$(lsl_merge_choice)" "always" "C6 Later keeps the stored choice"
lsl_merge_handle_choice "Never ask again"; eq "$MERGED" 2 "C7 Never merges nothing"
eq "$(lsl_merge_choice)" "never" "C7 Never persists"
lsl_merge_handle_choice ""; eq "$MERGED" 2 "C8 dismiss merges nothing"

# A remembered choice skips the dialog: run main() in a subshell (it calls
# exit) with a zenity mock that fails the test if ever invoked.
MOCKBIN="$ROOT/mockbin"; mkdir -p "$MOCKBIN"
printf '#!/bin/bash\necho CALLED >> "%s/zen.log"\nexit 1\n' "$ROOT" > "$MOCKBIN/zenity"
chmod +x "$MOCKBIN/zenity"
STATE="$ROOT/c9"; mkdir -p "$STATE"
printf 'never\n' > "$STATE/merge-choice"
( DISPLAY=:0 PATH="$MOCKBIN:/usr/bin:/bin" main ); eq "$?" 0 "C9 never-choice exits 0"
[ ! -e "$ROOT/zen.log" ] && ok "C9 never-choice shows no dialog" || bad "C9 dialog must not appear for never-choice"
STATE="$ROOT/c10"; mkdir -p "$STATE"
printf 'always\n' > "$STATE/merge-choice"
CASPER="$ROOT/c10casper"; mkcasper "$CASPER" 3 1M
lsl_cdrom_is_vfat() { return 1; }
rm -f "$ROOT/merged"
( export DISPLAY=:0 PATH="$MOCKBIN:/usr/bin:/bin"; lsl_merge_do() { touch "$ROOT/merged"; }; main ); eq "$?" 0 "C10 always-choice exits 0"
[ -e "$ROOT/merged" ] && ok "C10 always-choice merges without dialog" || bad "C10 always-choice must merge"
[ ! -e "$ROOT/zen.log" ] && ok "C10 always-choice shows no dialog" || bad "C10 dialog must not appear for always-choice"

# GTK choice backend is preferred when available (stock Mint ships no
# zenity, so zenity-only would silently never ask there).
GTK_BIN="$ROOT/gtkbin"; mkdir -p "$GTK_BIN"
printf '#!/bin/bash\nif [ "$1" = "-c" ]; then exit 0; fi\necho "GTK-CALLED $*" >> "%s/gtk.log"\ncat "%s/gtk-out"\n' "$ROOT" "$ROOT" > "$GTK_BIN/python3"
chmod +x "$GTK_BIN/python3"
touch "$ROOT/fake-gtk.py"
rm -f "$ROOT/zen.log" "$ROOT/merged2"
STATE="$ROOT/c11"; mkdir -p "$STATE"
CASPER="$ROOT/c11casper"; mkcasper "$CASPER" 3 1M
lsl_cdrom_is_vfat() { return 1; }
printf 'Merge now\n' > "$ROOT/gtk-out"
( export DISPLAY=:0 PATH="$GTK_BIN:/usr/bin:/bin" LSL_PROGRESS_GTK="$ROOT/fake-gtk.py"; lsl_merge_do() { touch "$ROOT/merged2"; }; main ); eq "$?" 0 "C11 gtk choice exits 0"
[ -e "$ROOT/merged2" ] && ok "C11 gtk Merge now merges" || bad "C11 gtk Merge now must merge"
[ ! -e "$ROOT/zen.log" ] && ok "C11 gtk preferred over zenity" || bad "C11 zenity must not run when gtk available"
grep -q -- "--choice" "$ROOT/gtk.log" && ok "C11 gtk gets --choice" || bad "C11 gtk missing --choice"
printf 'Later\n' > "$ROOT/gtk-out"
rm -f "$ROOT/merged2"
( export DISPLAY=:0 PATH="$GTK_BIN:/usr/bin:/bin" LSL_PROGRESS_GTK="$ROOT/fake-gtk.py"; lsl_merge_do() { touch "$ROOT/merged2"; }; main ); eq "$?" 0 "C12 gtk choice exits 0"
[ ! -e "$ROOT/merged2" ] && ok "C12 gtk Later merges nothing" || bad "C12 gtk Later must not merge"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ] && exit 0 || exit 1
