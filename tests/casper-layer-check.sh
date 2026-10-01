#!/bin/bash
# tests/casper-layer-check.sh - verify the squashfs layer filenames lsl-usb
# produces are matched by the casper initramfs glob on the target live image,
# AND that they sort into the right STACK order. casper globs the layer
# directory and stacks the matches lexically with the greatest on top, so the
# filenames themselves are the only thing expressing layer order (see
# WHYFAIL14). If our names don't match the glob, or don't sort base < stub <
# appends, the first-boot unit or the appended packages will not appear.
#
# How to find the real glob on the built USB / ISO:
#   unmkinitramfs /cdrom/casper/initrd . && grep -nE '\*\.squashfs' ./main/scripts/casper
# Then run: Casper_GLOB='...' bash tests/casper-layer-check.sh
#
# Run: bash tests/casper-layer-check.sh
set -u
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

# Default: casper's real glob is *.squashfs (ANY file, not just filesystem*).
# Override once you've inspected the target initrd.
GLOB="${Casper_GLOB:-*.squashfs}"
echo "Checking layer names against casper glob: $GLOB"
echo "(Override with Casper_GLOB='...' if your Mint initrd uses something narrower.)"

# The names lsl-usb produces, in the order they must STACK.
BASE_NAME="filesystem.squashfs"
STUB_NAME="filesystem_z0_firstboot.squashfs"
layers=( "$BASE_NAME" "$STUB_NAME" filesystem_z20250827000000.squashfs )

for n in "${layers[@]}"; do
    # case patterns are glob-matched, so $GLOB is treated as a casper-style glob.
    # shellcheck disable=SC2254  # intentional: $GLOB is a casper glob, not a literal
    case "$n" in
        $GLOB) pass "casper would stack: $n" ;;
        *)    fail "casper would SKIP: $n  (glob '$GLOB' does not match)" ;;
    esac
done

# Layer ORDER is the load-bearing invariant now that layerfs-path= is gone:
# casper sorts the glob matches, so a name that sorts into the wrong slot
# silently shadows (or is shadowed by) the wrong layer. Compare the sorted
# result against the ORDER WE REQUIRE (base, stub, appends) - not against
# another sort, which would assert nothing.
appended=filesystem_z20250827000000.squashfs
actual_order="$(printf '%s\n' "${layers[@]}" | sort | tr '\n' ' ')"
required_order="$BASE_NAME $STUB_NAME $appended "
if [ "$actual_order" = "$required_order" ]; then
    pass "stack order is base < stub < appended (computed by sort, as casper does)"
else
    fail "stack order WRONG - casper would stack these in the wrong order"
    echo "      required: $required_order"
    echo "      actual  : $actual_order"
fi

# The appended layer must sort ABOVE the stub, and the stub above the base.
if [[ "$appended" > "$STUB_NAME" ]]; then
    pass "appended layer sorts above the firstboot stub (newest wins)"
else
    fail "appended layer sorts BELOW the stub - it would be shadowed"
fi
if [[ "$STUB_NAME" > "$BASE_NAME" ]]; then
    pass "stub sorts above the base image"
else
    fail "stub sorts BELOW the base image - the stub would never be read"
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
