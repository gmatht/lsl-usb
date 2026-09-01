#!/bin/bash
# lsl-steam-doctor.sh - assert the Steam library overlay setup is sound.
#
# onboot.sh builds an overlay-writable view of Windows Steam libraries
# (/mnt/d/SteamLibrary and /mnt/c/Program Files (x86)/Steam) so Linux Steam can
# use them without modifying the Windows volume. This verifies the mounts exist
# and are writable, and that the underlying Windows volume is mounted.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lsl-common.sh"
lsl_load_config

ok=0; bad=0
report() { echo "  [$([ "$2" = ok ] && echo OK || echo FAIL)] $1"; }
fail()   { bad=$((bad+1)); report "$1" fail; }
pass()   { ok=$((ok+1));  report "$1" ok; }

echo "Steam library overlay check:"

# Need the Windows volumes mounted to host the libraries.
for drv in /mnt/c /mnt/d; do
    if mountpoint -q "$drv" 2>/dev/null; then
        pass "$drv mounted"
    else
        echo "  [SKIP] $drv not mounted - no Steam library expected from here"
    fi
done

# The two overlay roots onboot.sh sets up.
for root in /tmp/steam/root /tmp/steam2/root; do
    if mountpoint -q "$root" 2>/dev/null; then
        pass "overlay $root mounted"
        # Writable? touch a temp file and remove it.
        if touch "$root/.lsl-steam-doctor-test" 2>/dev/null; then
            rm -f "$root/.lsl-steam-doctor-test"
            pass "$root is writable (overlay upper works)"
        else
            fail "$root is not writable - overlay upper dir may be missing"
        fi
    elif [ -d "$(dirname "$root")/upper" ]; then
        fail "overlay $root NOT mounted (overlay source exists but mount missing)"
    else
        echo "  [SKIP] $root not set up (no Windows Steam library on this machine)"
    fi
done

# Does the desktop user own the overlay root so Steam (run as that user) can use it?
U="$(lsl_desktop_user)"
for root in /tmp/steam/root /tmp/steam2/root; do
    [ -d "$root" ] || continue
    if [ "$(stat -c '%U' "$root" 2>/dev/null)" = "$U" ] || [ "$(stat -c '%u' "$root" 2>/dev/null)" = "$(id -u "$U" 2>/dev/null)" ]; then
        pass "$root owned by $U"
    else
        fail "$root not owned by $U - chown it: sudo chown $U $root"
    fi
done

echo ""
echo "Steam check: $ok ok, $bad failed."
[ "$bad" -eq 0 ]
