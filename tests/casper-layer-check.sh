#!/bin/bash
# tests/casper-layer-check.sh - verify the squashfs layer filenames lsl-usb
# produces are actually matched by the casper initramfs glob on the target live
# image. This is the single biggest unknown before a real-hardware boot: casper
# stacks /cdrom/casper/filesystem*.squashfs in lexical order, but different
# Mint/Ubuntu releases use different globs (older ones require a fixed 4-char
# suffix, e.g. filesystem[0-9a-z][0-9a-z][0-9a-z][0-9a-z].squashfs). If our
# filesystem_z*.squashfs names don't match, the appended layer (and the
# lsl-firstboot unit) will NOT appear on the second boot.
#
# How to find the real glob on the built USB / ISO:
#   unmkinitramfs /cdrom/casper/initrd . && grep -nE 'filesystem.*squashfs' ./main/scripts/casper
# Then run: Casper_GLOB='...' bash tests/casper-layer-check.sh
#
# Run: bash tests/casper-layer-check.sh
set -u
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

# Default: permissive modern casper glob. Override once you've inspected the
# target initrd (older casper uses the fixed 4-char-suffix glob).
GLOB="${Casper_GLOB:-filesystem*.squashfs}"
echo "Checking layer names against casper glob: $GLOB"
echo "(Override with Casper_GLOB='...' if your Mint initrd uses a fixed-width suffix.)"

# The names lsl-usb produces: base + firstboot layer + a sample appended layer.
layers=( filesystem.squashfs filesystem_z0_firstboot.squashfs filesystem_z20250827000000.squashfs )

for n in "${layers[@]}"; do
    # case patterns are glob-matched, so $GLOB is treated as a casper-style glob.
    # shellcheck disable=SC2254  # intentional: $GLOB is a casper glob, not a literal
    case "$n" in
        $GLOB) pass "casper would stack: $n" ;;
        *)    fail "casper would SKIP: $n  (glob '$GLOB' does not match)" ;;
    esac
done

# The appended layer must sort AFTER the firstboot layer (newest wins).
appended=filesystem_z20250827000000.squashfs
firstboot=filesystem_z0_firstboot.squashfs
if [[ "$appended" > "$firstboot" ]]; then
    pass "appended layer sorts after firstboot layer"
else
    fail "appended layer does NOT sort after firstboot layer"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "RESULT: $PASS passed, $FAIL failed"
else
    echo "RESULT: $PASS passed, $FAIL failed"
    echo "ACTION: a layer was skipped by the glob. Either rename the layers to match"
    echo "        the target casper glob, or patch the initrd. See comment at top of"
    echo "        this file for how to extract and inspect the real glob."
fi
[ "$FAIL" -eq 0 ]
