#!/bin/bash
# check-z0-freshness.sh - detect a STALE embedded z0 firstboot layer.
#
# WHY THIS EXISTS (WHYFAIL10)
# --------------------------
# rust9x/lslsetup embeds the firstboot scripts as a PRE-BUILT squashfs blob:
#
#     static Z0_BLOB: &[u8] = include_bytes!("../assets/filesystem.z0.squashfs");
#
# and copies those bytes verbatim to the stick. The blob is generated from
# misc/ by misc/build-z0.sh, but nothing wired that generator into the build:
# cargo tracks the blob but has no dependency edge from misc/*.sh to it, so a
# `cargo build` happily reshipped a blob that predated the source. On
# 2026-09-28 that shipped a firstboot progress dialog which closed after ~1
# second (zenity --auto-close + SIGPIPE) even though the fix had been in misc/
# for ~14 hours.
#
# This script is a FRESHNESS check: it packs misc/ with the same generator and
# byte-compares the DECOMPRESSED CONTENT of the committed blob against it.
# Non-zero exit = stale.
#
# rust9x/lslsetup/build.rs now enforces the same invariant at build time via
# assets/z0_sources.sha256 (cross-platform, no squashfs-tools needed); this
# script is the byte-accurate guard to run in CI and by hand.
#
# USAGE
#   bash check-z0-freshness.sh [REPO_ROOT]        # default: autodetect
#   bash check-z0-freshness.sh --fix [REPO_ROOT]  # regenerate the blob in place
#
# Requires mksquashfs + unsquashfs (squashfs-tools). On the live LSL stick both
# are present; on Windows/WSL: sudo apt install squashfs-tools.

set -uo pipefail

FIX=0
if [ "${1:-}" = "--fix" ]; then FIX=1; shift; fi

# Locate the repo root: explicit arg, else walk up from this script, else the
# conventional mount points. The repo must contain misc/build-z0.sh.
find_root() {
    local d
    if [ -n "${1:-}" ]; then printf '%s' "$1"; return; fi
    d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    while [ "$d" != "/" ]; do
        [ -f "$d/misc/build-z0.sh" ] && { printf '%s' "$d"; return; }
        d="$(dirname "$d")"
    done
    for d in /mnt/c/GitHub/lsl-usb /cdrom /root/lsl-usb "$HOME/lsl-usb"; do
        [ -f "$d/misc/build-z0.sh" ] && { printf '%s' "$d"; return; }
    done
    return 1
}

ROOT="$(find_root "${1:-}")" || {
    echo "check-z0-freshness: cannot find repo root (no misc/build-z0.sh)." >&2
    echo "  pass it explicitly: bash check-z0-freshness.sh /path/to/lsl-usb" >&2
    exit 2
}
echo "repo root: $ROOT"

for t in mksquashfs unsquashfs; do
    command -v "$t" >/dev/null 2>&1 || {
        echo "check-z0-freshness: $t not found (apt install squashfs-tools)." >&2
        exit 2
    }
done

GEN="$ROOT/misc/build-z0.sh"
BLOB="$ROOT/rust9x/lslsetup/assets/filesystem.z0.squashfs"

[ -f "$GEN" ]  || { echo "missing generator: $GEN"  >&2; exit 2; }
[ -f "$BLOB" ] || { echo "missing embedded blob: $BLOB" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FRESH="$TMP/filesystem.z0.fresh.squashfs"

echo "packing misc/ with $GEN ..."
if ! bash "$GEN" "$FRESH" >"$TMP/gen.log" 2>&1; then
    echo "check-z0-freshness: build-z0.sh FAILED:" >&2
    sed -n '1,40p' "$TMP/gen.log" >&2
    exit 2
fi
grep -q '^BUILD_OK ' "$TMP/gen.log" || {
    echo "check-z0-freshness: build-z0.sh did not report BUILD_OK:" >&2
    sed -n '1,40p' "$TMP/gen.log" >&2
    exit 2
}

# mksquashfs output is not guaranteed byte-reproducible across runs/versions,
# so compare the DECOMPRESSED CONTENT of the files the layer carries, not the
# container bytes. That is also exactly what a "stale script shipped" bug looks
# like from the outside.
LIST="$(unsquashfs -l "$FRESH" 2>/dev/null | sed -n 's|^squashfs-root/||p' | grep -v '/$')"
if [ -z "$LIST" ]; then
    echo "check-z0-freshness: fresh layer listed no files." >&2
    exit 2
fi

stale=0
checked=0
while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    # skip symlinks (unsquashfs -cat returns the target path text, not content)
    case "$(unsquashfs -ll "$FRESH" 2>/dev/null | awk -v p="squashfs-root/$rel" '$NF==p{print $1}')" in
        l*) continue ;;
    esac
    a="$TMP/a"; b="$TMP/b"
    unsquashfs -cat "$FRESH" "$rel" >"$a" 2>/dev/null || continue
    unsquashfs -cat "$BLOB"  "$rel" >"$b" 2>/dev/null || { echo "  MISSING in blob: $rel"; stale=1; continue; }
    checked=$((checked + 1))
    if ! cmp -s "$a" "$b"; then
        echo "  STALE: $rel"
        stale=1
    fi
done <<< "$LIST"

echo "compared $checked files"

if [ "$stale" -eq 0 ]; then
    echo "OK: embedded z0 blob matches a fresh pack of misc/"
    exit 0
fi

echo
echo "STALE: $BLOB does not match misc/. The shipped firstboot layer is out of date."
echo "This is WHYFAIL10: include_bytes! depends on the blob, not on misc/."
echo
if [ "$FIX" -eq 1 ]; then
    echo "regenerating $BLOB ..."
    bash "$GEN" "$BLOB" || { echo "regeneration failed" >&2; exit 2; }
    echo "Done. Now rebuild the exe:"
    echo "  cd $ROOT/rust9x/lslsetup && cargo +rust9x build --target i586-rust9x-windows-msvc --release"
    exit 0
fi

echo "Fix with:"
echo "  bash $GEN        # overwrite the embedded blob"
echo "  cd $ROOT/rust9x/lslsetup && cargo +rust9x build --target i586-rust9x-windows-msvc --release"
echo "or re-run this script with --fix to do the first step."
exit 1
