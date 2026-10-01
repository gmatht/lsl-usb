#!/bin/bash
# check-toolkit-freshness.sh - detect a STALE embedded firstboot toolkit.
#
# WHY THIS EXISTS (WHYFAIL13 follow-up, 2026-10-01)
# -------------------------------------------------
# rust9x/lslsetup/src/lslfiles.rs embeds 36 repo files with include_str! into
# FIRSTBOOT_TOOLKIT, and the nofmt installer writes the stick's /cdrom/bin,
# /cdrom/fuse and /cdrom/systemd from that array ALONE:
#
#     ("bin\\lsl-pin-favorites", include_str!("../../../bin/lsl-pin-favorites")),
#     ...
#
# include_str! gives cargo a dependency edge, so a fresh `cargo build` embeds
# the current source. What it does NOT do is notice a *committed* binary that
# was built earlier: the exe keeps whatever was in the file when it was
# compiled, and nothing compared the two. On 2026-10-01 every shipped
# lslsetup.exe (target/debug, target/i586-.../{debug,release} and
# dist/lslsetup-win95.exe) embedded the OLD bin/lsl-pin-favorites while the fix
# sat in bin/ unshipped. The symptom was subtle and looked like a different bug
# entirely: the pin script split `gsettings get` string-array output on
# newlines, which collapsed the whole favorites list into one unresolvable
# element, so every pinned app - kitty included - disappeared from the panel on
# a freshly built stick.
#
# This script is a FRESHNESS check, in the spirit of check-z0-freshness.sh:
#   * it verifies assets/toolkit_sources.sha256 covers every embedded source
#     (so a newly embedded file cannot skip the guard), and
#   * it reports which sources have drifted since the manifest was generated.
#
# rust9x/lslsetup/build.rs enforces the same invariant at build time (no
# external tools needed); this script is the by-hand/CI guard.
#
# USAGE
#   bash check-toolkit-freshness.sh [REPO_ROOT]        # check
#   bash check-toolkit-freshness.sh --fix [REPO_ROOT]  # regenerate manifest
#
# Exit codes: 0 fresh, 1 stale/incomplete, 2 cannot locate the repo.

set -uo pipefail

FIX=0
if [ "${1:-}" = "--fix" ]; then FIX=1; shift; fi

find_root() {
    local d
    if [ -n "${1:-}" ]; then printf '%s' "$1"; return; fi
    d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    while [ "$d" != "/" ]; do
        [ -f "$d/rust9x/lslsetup/src/lslfiles.rs" ] && { printf '%s' "$d"; return; }
        d="$(dirname "$d")"
    done
    for d in /mnt/c/GitHub/lsl-usb /cdrom /root/lsl-usb "$HOME/lsl-usb"; do
        [ -f "$d/rust9x/lslsetup/src/lslfiles.rs" ] && { printf '%s' "$d"; return; }
    done
    return 1
}

ROOT="$(find_root "${1:-}")" || {
    echo "check-toolkit-freshness: cannot find repo root (no rust9x/lslsetup/src/lslfiles.rs)." >&2
    echo "  pass it explicitly: bash check-toolkit-freshness.sh /path/to/lsl-usb" >&2
    exit 2
}
echo "repo root: $ROOT"

LSLFILES="$ROOT/rust9x/lslsetup/src/lslfiles.rs"
MANIFEST="$ROOT/rust9x/lslsetup/assets/toolkit_sources.sha256"

if [ "$FIX" = "1" ]; then
    bash "$ROOT/misc/build-toolkit-manifest.sh"
    exit $?
fi

[ -f "$MANIFEST" ] || {
    echo "STALE: $MANIFEST is missing - run: bash misc/build-toolkit-manifest.sh" >&2
    exit 1
}

# Embedded sources, repo-relative, from the include_str! literals.
mapfile -t EMBEDDED < <(
    awk '/^static FIRSTBOOT_TOOLKIT/,/^\];/' "$LSLFILES" \
        | grep -o 'include_str!("[^"]*")' \
        | sed 's/include_str!("//; s/")//' \
        | sed 's|^\.\./\.\./\.\./||' \
        | sort
)

rc=0
# 1) completeness: every embedded source must be listed.
while IFS= read -r rel; do
    if ! grep -qF "  $rel" "$MANIFEST"; then
        echo "INCOMPLETE: $rel is embedded but not in $MANIFEST" >&2
        rc=1
    fi
done < <(printf '%s\n' "${EMBEDDED[@]}")

# 2) drift: every listed hash must still match the working tree.
stale=0
while read -r want rel; do
    [ -n "${rel:-}" ] || continue
    f="$ROOT/$rel"
    if [ ! -f "$f" ]; then
        echo "MISSING:   $rel" >&2
        stale=$((stale + 1))
        continue
    fi
    got="$(sha256sum "$f" | cut -d' ' -f1)"
    if [ "$got" != "$want" ]; then
        echo "DRIFTED:   $rel" >&2
        stale=$((stale + 1))
    fi
done < "$MANIFEST"

if [ "$stale" -gt 0 ]; then
    echo "STALE embedded firstboot toolkit: $stale source(s) differ from the manifest." >&2
    echo "  Regenerate: bash misc/build-toolkit-manifest.sh" >&2
    echo "  Then REBUILD the exe - a stale exe writes the old content to the stick." >&2
    rc=1
fi

[ "$rc" -eq 0 ] && echo "OK: embedded firstboot toolkit is fresh ($(grep -c . "$MANIFEST") sources verified)"
exit "$rc"
