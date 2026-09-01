#!/bin/bash
# lsl-nix-doctor.sh - assert the Nix on cache.btrfs setup is sound.
#
# The first-boot recipe binds /nix/store and /nix/var from cache.btrfs and adds
# the desktop user to nix-users. This checks each link in that chain and prints
# actionable fixes. Non-fatal: exits non-zero only when something is broken so it
# can be wired into lsl-diag.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lsl-common.sh"
lsl_load_config

ok=0; bad=0
report() { echo "  [$([ "$2" = ok ] && echo OK || echo FAIL)] $1"; }
fail()   { bad=$((bad+1)); report "$1" fail; }
pass()   { ok=$((ok+1));  report "$1" ok; }

echo "Nix setup check:"

# 1) cache.btrfs + loop mount present
CACHE_IMG="$(lsl_cache_btrfs_path)"
if [ -f "$CACHE_IMG" ]; then
    pass "cache.btrfs exists ($CACHE_IMG)"
else
    fail "cache.btrfs missing ($CACHE_IMG) - first boot may not have run in HDD mode"
fi

if mountpoint -q "${LSL_CACHE_MOUNT:-/mnt/lsl-cache}"; then
    pass "${LSL_CACHE_MOUNT:-/mnt/lsl-cache} mounted"
else
    fail "${LSL_CACHE_MOUNT:-/mnt/lsl-cache} NOT mounted - Nix cache bind mounts missing"
fi

# 2) /nix/store and /nix/var are the bound (cache) trees, not the live overlay
for m in /nix/store /nix/var; do
    if mountpoint -q "$m" 2>/dev/null; then
        pass "$m is a bind mount"
    else
        fail "$m is NOT a bind mount (expect from cache.btrfs)"
    fi
done

# 3) nix-users group exists and the desktop user is a member
if getent group nix-users >/dev/null 2>&1; then
    pass "nix-users group exists"
else
    fail "nix-users group missing - desktop user cannot use multi-user Nix"
fi
U="$(lsl_desktop_user)"
if id -nG "$U" 2>/dev/null | tr ' ' '\n' | grep -qx nix-users; then
    pass "$U is in nix-users"
else
    fail "$U is NOT in nix-users - add with: sudo usermod -aG nix-users $U"
fi

# 4) nix daemon socket/service
if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet nix-daemon.service 2>/dev/null || \
       systemctl is-active --quiet nix-daemon.socket 2>/dev/null; then
        pass "nix-daemon active"
    else
        fail "nix-daemon not active - start with: sudo systemctl restart nix-daemon.socket"
    fi
fi

# 5) nix itself resolvable
if command -v nix >/dev/null 2>&1; then
    pass "nix on PATH"
else
    fail "nix not on PATH - install nix-bin via the first-boot recipe"
fi

echo ""
echo "Nix check: $ok ok, $bad failed."
[ "$bad" -eq 0 ]
