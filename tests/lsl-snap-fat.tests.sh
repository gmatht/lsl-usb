#!/bin/bash
# tests/lsl-snap-fat.tests.sh - mock-based tests for lsl-snap-fat.sh.
#
# Run: bash tests/lsl-snap-fat.tests.sh
#
# The script's whole job is deciding, per snap: already installed / cached on
# the stick / download it. `snap` is stubbed on PATH so every branch is testable
# without snapd, a network, or a real stick.
set -u

PASS=0; FAIL=0
assert() { # $1 = condition (eval'd), $2 = name
    if eval "$1"; then
        PASS=$((PASS + 1)); echo "  PASS: $2"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: $2"
    fi
}

SCRIPT="$(dirname "$0")/../bin/lsl-snap-fat.sh"
[ -r "$SCRIPT" ] || { echo "missing $SCRIPT" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"
mkdir -p "$BIN"
STICK="$WORK/cdrom"
mkdir -p "$STICK/casper"
LIST="$STICK/snaps.txt"
CACHE="$STICK/casper/snapcache"
STATE="$WORK/snapd-snaps"
mkdir -p "$STATE"

# Record every snap invocation so we can assert on the CALL SEQUENCE, not just
# the exit code - "installed from cache" vs "downloaded" are different calls.
# `refresh` is deliberately NOT logged here: cmd_ensure calls hold_refresh on
# every snap in the list every run (installed or not), so a refresh line proves
# nothing about idempotency and would break the no-op assertions below.
CALLS="$WORK/calls.log"
INSTALLED="$WORK/installed"

# A PATH shim is more reliable than exporting a shell function through
# `bash script`, so `snap` below is a real executable. Behaviour is driven by
# files in $WORK:
#   $INSTALLED         one installed snap name per line (what `snap list` shows)
#   $WORK/fail_<name>  if present, installing that name fails (store or file)
#   $WORK/dled_<name>  if present, the store never delivered bytes for that name
#   $WORK/badfile_<name> if present, `--dangerous` on a FILE for that name fails,
#                      while a store install of the same name succeeds
cat >"$BIN/snap" <<'STUB'
#!/bin/bash
CALLS="$WORK/calls.log"
INSTALLED="$WORK/installed"
STATE="$WORK/snapd-snaps"
# Key on the first NON-FLAG argument, not $1: the script calls
# `snap install --dangerous <file>` and `snap download --revision=N <name>`, so
# $1 is a flag. Deriving the subcommand this way is what snap effectively does.
sub=""
for a in "$@"; do
    case "$a" in
        -*) ;;
        *) sub="$a"; break ;;
    esac
done
case "$sub" in
    list)
        if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then
            # `snap list <name>`: Name Version Rev Tracking Publisher Notes
            grep -qx -- "$2" "$INSTALLED" 2>/dev/null || exit 1
            echo "Name  Version  Rev  Tracking  Publisher  Notes"
            echo "$2  1.0  100  latest  test  -"
        else
            echo "Name  Version  Rev  Tracking  Publisher  Notes"
            [ -f "$INSTALLED" ] || exit 0
            while read -r n; do
                [ -n "$n" ] && echo "$n  1.0  100  latest  test  -"
            done <"$INSTALLED"
        fi
        ;;
    install)
        shift
        name=""
        for a in "$@"; do
            case "$a" in
                -*) ;;
                install) ;;
                *) [ -z "$name" ] && name="$a" ;;
            esac
        done
        echo "install $*" >>"$CALLS"
        # A cached-file install names a FILE, not a snap: if its basename is
        # <snap>_rev.snap, the target snap is <snap>.
        name="$(basename "$name")"; name="${name%%_*}"
        [ -f "$WORK/fail_$name" ] && exit 1
        # badfile_<name>: reject the cached-file paths but accept the store
        # path, which is how we exercise install_one's cache -> store fallback.
        case " $* " in
            *" --dangerous "* | *" --offline "*)
                [ -f "$WORK/badfile_$name" ] && exit 1 ;;
        esac
        # noassert_<name>: an --offline install with no acked assertion fails,
        # which is what a stale/mismatched cache looks like to snapd.
        case " $* " in
            *" --offline "*)
                grep -qx -- "$name" "$WORK/acked" 2>/dev/null || exit 1 ;;
        esac
        # dled_<name> present => the store never delivered bytes.
        if [ ! -f "$WORK/dled_$name" ]; then
            printf 'payload %s' "$name" >"$STATE/${name}_100.snap"
        fi
        printf '%s\n' "$name" >>"$INSTALLED"
        ;;
    ack)
        # `snap ack <file>` registers an assertion. Record the snap name so a
        # later --offline install can be told whether it was verified.
        a="${2:-}"; a="$(basename "$a")"; a="${a%%_*}"
        printf '%s\n' "$a" >>"$WORK/acked"
        echo "ack $*" >>"$CALLS"
        ;;
    download)
        # `snap download [--revision=N] <name>` writes <name>_<rev>.snap AND
        # <name>_<rev>.snap.assert into the CWD. noassert_<name> omits the
        # assertion so we can test the degraded path.
        rev=100
        name=""
        for a in "$@"; do
            case "$a" in
                --revision=*) rev="${a#--revision=}" ;;
                download) ;;
                -*) ;;
                *) [ -z "$name" ] && name="$a" ;;
            esac
        done
        echo "download $*" >>"$CALLS"
        [ -f "$WORK/dl_fail_$name" ] && exit 1
        printf 'downloaded %s' "$name" >"${name}_${rev}.snap"
        [ -f "$WORK/noassert_$name" ] || \
            printf 'assertion for %s rev %s' "$name" "$rev" >"${name}_${rev}.snap.assert"
        ;;
    refresh) : ;;
    *)
        echo "snap $*" >>"$CALLS"
        ;;
esac
exit 0
STUB
chmod +x "$BIN/snap"

# `uname` must report x86_64 or snap_available() correctly declines.
cat >"$BIN/uname" <<'STUB'
#!/bin/bash
echo x86_64
STUB
chmod +x "$BIN/uname"

run() { # run the real script with our stubbed environment
    PATH="$BIN:$PATH" \
    WORK="$WORK" \
    LSL_SNAP_LIST="$LIST" \
    LSL_SNAP_CACHE="$CACHE" \
    LSL_LOG="$WORK/lsl.log" \
    SNAP_STATE_DIR="$STATE" \
    bash "$SCRIPT" "$@" 2>&1
}

reset() {
    rm -f "$CALLS" "$INSTALLED"
    rm -rf "$CACHE"
    # Per-test behavioural markers (fail_/dled_/badfile_/noassert_/dl_fail_) must
    # not leak between cases, or one test's stub setting silently becomes the
    # next test's premise. `acked` is snapd's assertion DB, which likewise must
    # start empty or every --offline install looks already-verified.
    rm -f "$WORK"/fail_* "$WORK"/dled_* "$WORK"/badfile_* "$WORK"/noassert_* \
        "$WORK"/dl_fail_* "$WORK/acked"
    touch "$CALLS" "$INSTALLED"
}

# # --- no list on the stick: nothing happens, and it is not an error -----------
reset; rm -f "$LIST"
run ensure >/dev/null
assert '[ "$?" = 0 ]' 'ensure: missing snaps.txt exits 0 (never fatal)'
assert '! grep -q "^install " "$CALLS"' 'ensure: missing snaps.txt installs nothing'

# # --- empty list --------------------------------------------------------------
reset; : >"$LIST"
run ensure >/dev/null
assert '! grep -q "^install " "$CALLS"' 'ensure: empty list installs nothing'

# # --- a listed snap gets downloaded -------------------------------------------
reset; printf 'spotify\n' >"$LIST"
run ensure >/dev/null
assert 'grep -q "^install spotify$" "$CALLS"' 'ensure: listed snap is installed'
assert '[ -s "$CACHE/spotify_100.snap" ]' 'ensure: downloaded snap is cached on the stick'

# # --- second run is a NO-OP: this is the whole point of the feature -----------
before="$(cat "$CALLS")"
run ensure >/dev/null
after="$(cat "$CALLS")"
assert '[ "$before" = "$after" ]' 'ensure: re-run does not re-install an already-installed snap'

# # --- a removed snap is NOT resurrected ---------------------------------------
reset; printf 'code\n' >"$LIST"; printf 'code\n' >"$INSTALLED"
run ensure >/dev/null
assert '! grep -q "^install code$" "$CALLS"' 'ensure: a snap the user removed stays removed'

# # --- cache hit with an assertion: VERIFIED offline install, no store -------
reset; printf 'firefox\n' >"$LIST"; mkdir -p "$CACHE"
printf 'cached payload' >"$CACHE/firefox_99.snap"
printf 'the assertion' >"$CACHE/firefox_99.snap.assert"
run ensure >/dev/null
assert 'grep -q "^ack .*firefox_99.snap.assert" "$CALLS"' 'cache: the assertion is registered with snap ack before installing'
assert 'grep -q "^install --offline .*firefox_99.snap" "$CALLS"' 'cache: cached snap installs VERIFIED via --offline'
assert '! grep -q "dangerous" "$CALLS"' 'cache: the verified path never uses --dangerous'
assert '! grep -q "^install firefox$" "$CALLS"' 'cache: verified cache hit does not touch the store'

# # --- cache hit with NO assertion: falls back to --dangerous, and says so ----
reset; printf 'firefox\n' >"$LIST"; mkdir -p "$CACHE"
printf 'cached payload' >"$CACHE/firefox_99.snap"
out="$(run ensure)"
assert 'grep -q "^install --dangerous .*firefox_99.snap" "$CALLS"' 'cache: an assertion-less cache still installs (degraded)'
assert 'echo "$out" | grep -qi "UNVERIFIED"' 'cache: the unverified install is stated in the output, not silent'

# # --- a broken cache entry falls back to the store, once ---------------------
reset; printf 'steam\n' >"$LIST"; mkdir -p "$CACHE"
printf 'truncated' >"$CACHE/steam_1.snap"
printf 'assert' >"$CACHE/steam_1.snap.assert"
: >"$WORK/badfile_steam"
run ensure >/dev/null
assert 'grep -q "^install --offline .*steam_1.snap" "$CALLS"' 'cache: a broken cache entry is tried first'
assert 'grep -q "^install steam$" "$CALLS"' 'cache: a broken cache entry then falls back to the store'
assert '[ ! -e "$CACHE/steam_1.snap" ]' 'cache: the bad entry is dropped so it cannot poison every boot'
assert '[ ! -e "$CACHE/steam_1.snap.assert" ]' 'cache: its assertion is dropped with it (never orphan one)'
assert '[ -s "$CACHE/steam_100.snap" ]' 'cache: the good download replaces the bad entry'
assert '[ -s "$CACHE/steam_100.snap.assert" ]' 'cache: the replacement ships WITH its assertion'

# # --- a failed store download is not fatal; the snap still works -------------
reset; printf 'ghost\n' >"$LIST"; : >"$WORK/dl_fail_ghost"
out="$(run ensure)"
assert 'grep -q "^install ghost$" "$CALLS"' 'cache: the snap is installed even if caching it fails'
assert '[ ! -e "$CACHE/ghost_100.snap" ]' 'cache: a failed download leaves no half-written cache entry'
assert 'echo "$out" | grep -qi "re-download\|WARNING"' 'cache: the failure to cache is reported'

# # --- revision ordering: newest cached revision wins --------------------------
reset; printf 'vlc\n' >"$LIST"; mkdir -p "$CACHE"
printf 'old' >"$CACHE/vlc_9.snap"; printf 'old assert' >"$CACHE/vlc_9.snap.assert"
printf 'new' >"$CACHE/vlc_10.snap"; printf 'new assert' >"$CACHE/vlc_10.snap.assert"
run ensure >/dev/null
assert 'grep -q "^install --offline .*vlc_10.snap" "$CALLS"' 'cache: newest cached revision wins (10 > 9, not string-compare)'

# # --- pruning keeps .snap and .assert paired ---------------------------------
reset; printf 'gimp\n' >"$LIST"; mkdir -p "$CACHE"
for r in 1 2 3; do
    printf 'p%s' "$r" >"$CACHE/gimp_$r.snap"
    printf 'a%s' "$r" >"$CACHE/gimp_$r.snap.assert"
done
run install gimp >/dev/null 2>&1 || true
leftover_assert="$(ls -1 "$CACHE"/gimp_*.snap.assert 2>/dev/null | wc -l)"
leftover_snap="$(ls -1 "$CACHE"/gimp_*.snap 2>/dev/null | wc -l)"
assert '[ "$leftover_snap" -le 3 ]' 'cache: pruning bounds the number of cached revisions'
assert '[ "$leftover_assert" -eq "$leftover_snap" ]' 'cache: every cached .assert still has its .snap (never an orphan)'

# # --- comments and blank lines in the list are ignored ------------------------
reset; printf '# my snaps\n\n  spotify  \n\n#trailing\n' >"$LIST"
run ensure >/dev/null
assert 'grep -q "^install spotify$" "$CALLS"' 'ensure: comments/whitespace are stripped from list entries'
assert '! grep -q "^install #" "$CALLS"' 'ensure: comment lines are not treated as snap names'

# # --- ONE failure must not abandon the rest ----------------------------------
reset; printf 'goodone\n' >"$LIST"; : >"$WORK/fail_badone"; printf 'badone\n' >>"$LIST"
printf 'alsogood\n' >>"$LIST"
run ensure >/dev/null
assert 'grep -q "^install badone$" "$CALLS"' 'ensure: the failing snap is attempted'
assert 'grep -q "^install alsogood$" "$CALLS"' 'ensure: a mid-list failure does not abandon later snaps'

# # --- caching no longer trusts the state dir for the payload -----------------
# It used to copy /var/lib/snapd/snaps/<f>.snap. It now re-fetches a matched
# .snap + .assert pair with `snap download`, because the assertion is not
# recoverable from snapd's content-hashed assertion DB. So "snapd's state dir
# has no payload" is no longer a reason to skip caching - what matters is
# whether `snap download` succeeded.
reset; printf 'ghost\n' >"$LIST"; : >"$WORK/dled_ghost"
run ensure >/dev/null
assert '[ -s "$CACHE/ghost_100.snap" ]' 'cache: payload is fetched fresh, not taken from the state dir'
assert '[ -s "$CACHE/ghost_100.snap.assert" ]' 'cache: and it arrives with its assertion'
assert '! grep -q "^download --revision=1000000000" "$CALLS"' 'cache: the revision is the one actually installed'

# # --- non-amd64 declines cleanly --------------------------------------------
reset; printf 'spotify\n' >"$LIST"
cat >"$BIN/uname" <<'STUB'
#!/bin/bash
echo i686
STUB
chmod +x "$BIN/uname"
out="$(run ensure)"
assert 'echo "$out" | grep -qi "snapd unavailable"' 'ensure: on i386 it reports snapd unavailable'
assert '! grep -q "^install " "$CALLS"' 'ensure: on i386 nothing is installed'
cat >"$BIN/uname" <<'STUB'
#!/bin/bash
echo x86_64
STUB
chmod +x "$BIN/uname"

# # --- LSL_SNAP_FAT=0 opt-out --------------------------------------------------
reset; printf 'spotify\n' >"$LIST"
out="$(PATH="$BIN:$PATH" WORK="$WORK" LSL_SNAP_LIST="$LIST" LSL_SNAP_CACHE="$CACHE" \
    LSL_LOG="$WORK/lsl.log" SNAP_STATE_DIR="$STATE" LSL_SNAP_SUPPORT=0 \
    bash "$SCRIPT" ensure 2>&1)"
assert '! grep -q "^install " "$CALLS"' 'ensure: LSL_SNAP_SUPPORT=0 disables the whole step'

# # --- prune keeps only the newest revision ----------------------------------
reset; mkdir -p "$CACHE"
printf a >"$CACHE/foo_1.snap"; printf b >"$CACHE/foo_2.snap"; printf c >"$CACHE/foo_3.snap"
printf 'foo\n' >"$LIST"
run install foo >/dev/null 2>&1 || true
# install_one sees nothing installed, tries the newest cached rev (foo_3).
ls -1 "$CACHE"/foo_*.snap 2>/dev/null | sort -V >"$WORK/after"
assert '[ "$(wc -l <"$WORK/after")" -le 3 ]' 'cache: pruning never grows the cache without bound'

# # --- list / cleancache are non-destructive ----------------------------------
reset; printf 'spotify\n' >"$LIST"; mkdir -p "$CACHE"; printf x >"$CACHE/spotify_1.snap"
run list >/dev/null
assert '[ -s "$CACHE/spotify_1.snap" ]' 'list: does not delete anything'
run cleancache >/dev/null
assert '[ ! -e "$CACHE/spotify_1.snap" ]' 'cleancache: drops the cached payloads'

# # --- usage with no args exits 1 and prints help -----------------------------
reset
run >/dev/null 2>&1
assert '[ "$?" = 1 ]' 'no subcommand: exits 1'

echo
echo "lsl-snap-fat: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]