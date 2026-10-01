#!/bin/bash
# build-toolkit-manifest.sh - regenerate the embedded firstboot toolkit manifest.
# ============================================================================
# rust9x/lslsetup/src/lslfiles.rs embeds 36 files with include_str! into
# FIRSTBOOT_TOOLKIT; the nofmt installer writes the stick's /cdrom from that
# array and nothing else. include_str! makes cargo depend on the SOURCE FILE,
# so a rebuild picks up an edit - but a prebuilt/committed lslsetup.exe does
# not, and nothing detected that. On 2026-10-01 every shipped .exe embedded a
# broken bin/lsl-pin-favorites (WHYFAIL13 follow-up: gsettings arrays were
# split on newlines, collapsing all favorites into one bogus element), while
# the fixed script sat in bin/ unshipped.
#
# assets/toolkit_sources.sha256 is the hash of every embedded source; build.rs
# re-hashes each one and FAILS the build when any has drifted, exactly like the
# z0 layer guard (WHYFAIL10). Run this whenever a toolkit source changes, and
# commit the manifest alongside it.
#
# Usage: ./misc/build-toolkit-manifest.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LSLFILES="$REPO_ROOT/rust9x/lslsetup/src/lslfiles.rs"
MANIFEST="$REPO_ROOT/rust9x/lslsetup/assets/toolkit_sources.sha256"

[ -f "$LSLFILES" ] || { echo "missing $LSLFILES" >&2; exit 1; }

# Every include_str! path inside the FIRSTBOOT_TOOLKIT array, normalized to a
# repo-relative path (the literals are ../../../<rel> from src/).
mapfile -t SRCS < <(
    awk '/^static FIRSTBOOT_TOOLKIT/,/^\];/' "$LSLFILES" \
        | grep -o 'include_str!("[^"]*")' \
        | sed 's/include_str!("//; s/")//' \
        | sed 's|^\.\./\.\./\.\./||' \
        | sort
)

[ "${#SRCS[@]}" -gt 0 ] || { echo "no include_str! entries found in FIRSTBOOT_TOOLKIT" >&2; exit 1; }

for rel in "${SRCS[@]}"; do
    [ -f "$REPO_ROOT/$rel" ] || { echo "missing $REPO_ROOT/$rel" >&2; exit 1; }
done

: > "$MANIFEST"
for rel in "${SRCS[@]}"; do
    printf '%s  %s\n' "$(sha256sum "$REPO_ROOT/$rel" | cut -d' ' -f1)" "$rel" >> "$MANIFEST"
done

echo "TOOLKIT_MANIFEST_OK $MANIFEST (${#SRCS[@]} sources)"
