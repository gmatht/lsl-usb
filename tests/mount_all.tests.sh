#!/bin/bash
# tests/mount_all.tests.sh - unit tests for bin/mount_all.sh drive-letter
# resolution (GPT + MBR). Mocks hivexget/lsblk/mount/mountpoint so no root or
# real devices are needed. Exercises the exact bug from the hardware review:
# the partition GUID (not the disk GUID) must match PARTUUID.
#
# Run: bash tests/mount_all.tests.sh
set -u
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT/bin/mount_all.sh"

# --- mocks -----------------------------------------------------------------
# hivexget: synthetic MountedDevices dump. Each GUID is 16 bytes (32 hex chars),
# comma-separated; no separator between the disk GUID and the partition GUID.
#   C: GPT, partition GUID 11111111-1111-1111-1111-111111111111
#   D: GPT, partition GUID 22222222-2222-2222-2222-222222222222
hivexget() {
    cat <<'EOF'
"\DosDevices\C:"=hex(3):44,4d,49,4f,3a,49,44,3a,aa,aa,aa,aa,aa,aa,aa,aa,aa,aa,aa,aa,aa,aa,aa,aa,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11
"\DosDevices\D:"=hex(3):44,4d,49,4f,3a,49,44,3a,bb,bb,bb,bb,bb,bb,bb,bb,bb,bb,bb,bb,bb,bb,bb,bb,22,22,22,22,22,22,22,22,22,22,22,22,22,22,22,22
EOF
}
lsblk() {
    case "$*" in
        *PARTUUID*) printf 'sda1 11111111-1111-1111-1111-111111111111\n'; printf 'sda2 22222222-2222-2222-2222-222222222222\n';;
        *) : ;;
    esac
}
MOUNTS=()
mount() { MOUNTS+=("$*"); }
# Simulate C: already mounted (onboot mounted it above); others not.
mountpoint() { case "$*" in *"/mnt/c"*) return 0 ;; *) return 1 ;; esac; }

# shellcheck disable=SC2034  # INPUT is consumed by the sourced parse_drive()
INPUT="$(hivexget /mnt/c/Windows/System32/config/SYSTEM 'MountedDevices' | tr -d '\r')"

# --- cases -----------------------------------------------------------------
# C: already mounted -> parse_drive must be a no-op (no new mount call).
parse_drive C /mnt/c
if [ ${#MOUNTS[@]} -eq 0 ]; then
    pass "C: skipped (already mounted)"
else
    fail "C: attempted a mount: ${MOUNTS[*]}"
fi

# D: must resolve to /dev/sda2 via the PARTITION GUID (was the disk GUID before).
parse_drive D /mnt/d
found=0
for m in "${MOUNTS[@]}"; do
    case "$m" in *"/dev/sda2"*" /mnt/d"*) found=1 ;; esac
done
if [ "$found" -eq 1 ]; then
    pass "D: resolved to /dev/sda2 via PARTUUID (partition GUID)"
else
    fail "D: wrong device mounted: ${MOUNTS[*]:-none}"
fi

# A letter with no registry entry returns 1 and mounts nothing.
if parse_drive Z /mnt/z; then
    fail "Z: returned 0 with no registry entry"
else
    pass "Z: no entry -> return 1"
fi

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
