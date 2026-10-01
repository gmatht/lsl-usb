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

# --- mount_ntfs: driver/RO fallback + "did it actually land?" ----------------
# WHYFAIL11: the kernel ntfs3 driver refuses some volumes ("Can't mount, would
# change RO state"); the old code tried `mount -t ntfs3` once and ignored the
# failure, leaving /mnt/c unmounted, so the data dir was never persistent and
# /home fell back to a RAM overlay. mount_ntfs must keep trying and must verify.

# (a) ntfs3 rw fails, ntfs-3g rw succeeds -> returns 0, uses ntfs-3g.
MOUNTS=()
ntfs_is_dirty() { return 1; }                       # clean
mountpoint() { return 1; }                          # not mounted yet
mount() {
    MOUNTS+=("$*")
    case "$*" in
        *"-t ntfs3"*) return 1 ;;                   # kernel driver refuses
        *"-t ntfs-3g"*) return 0 ;;                 # FUSE fallback works
        *) return 1 ;;
    esac
}
# mount_ntfs re-checks mountpoint after mounting; make the successful rung land.
mountpoint() {
    case "${MOUNTS[*]:-}" in *ntfs-3g*) return 0 ;; *) return 1 ;; esac
}
mount_ntfs /dev/sda2 /mnt/c >/dev/null 2>&1
rc=$?
used_fuse=0
for m in "${MOUNTS[@]}"; do case "$m" in *ntfs-3g*) used_fuse=1 ;; esac; done
if [ "$rc" -eq 0 ] && [ "$used_fuse" -eq 1 ]; then
    pass "mount_ntfs: ntfs3 rw fails -> ntfs-3g rw used, rc=0"
else
    fail "mount_ntfs: no ntfs-3g fallback (rc=$rc, calls=${MOUNTS[*]:-none})"
fi

# (b) every rw attempt fails but ro succeeds -> must still mount (ro), rc=0.
MOUNTS=()
mount() {
    MOUNTS+=("$*")
    case "$*" in
        *"-o ro"*) return 0 ;;
        *) return 1 ;;
    esac
}
mountpoint() {
    case "${MOUNTS[*]:-}" in *"-o ro"*) return 0 ;; *) return 1 ;; esac
}
mount_ntfs /dev/sda2 /mnt/c >/dev/null 2>&1
rc=$?
used_ro=0
for m in "${MOUNTS[@]}"; do case "$m" in *"-o ro"*) used_ro=1 ;; esac; done
if [ "$rc" -eq 0 ] && [ "$used_ro" -eq 1 ]; then
    pass "mount_ntfs: rw fails -> read-only rung used, rc=0"
else
    fail "mount_ntfs: did not fall back to ro (rc=$rc, calls=${MOUNTS[*]:-none})"
fi

# (c) mount(8) returns 0 but nothing is mounted -> must NOT report success.
#     (This is the exact shape of the kernel refusal: exit status lies.)
MOUNTS=()
mount() { MOUNTS+=("$*"); return 0; }
mountpoint() { return 1; }                          # never actually mounted
if mount_ntfs /dev/sda2 /mnt/c >/dev/null 2>&1; then
    fail "mount_ntfs: reported success without a real mountpoint"
else
    pass "mount_ntfs: unmounted despite rc=0 -> fails loudly"
fi

# (d) already mounted -> no redundant mount attempt (EBUSY would be misread).
MOUNTS=()
mount() { MOUNTS+=("$*"); return 1; }
mountpoint() { return 0; }                          # already mounted
if mount_ntfs /dev/sda2 /mnt/c >/dev/null 2>&1 && [ ${#MOUNTS[@]} -eq 0 ]; then
    pass "mount_ntfs: already-mounted is a no-op success"
else
    fail "mount_ntfs: re-mounted an already-mounted target (${MOUNTS[*]:-none})"
fi

# (e) ntfs_is_dirty must not read ntfsfix's "already mounted rw" refusal as dirt.
real_ntfsfix="$(command -v ntfsfix || true)"
unset -f ntfs_is_dirty 2>/dev/null || true
# Re-source to get the real ntfs_is_dirty back for this case.
. "$REPO_ROOT/bin/mount_all.sh"
ntfsfix() { printf 'Refusing to operate on read-write mounted device /dev/sda2.\n'; return 0; }
if ntfs_is_dirty /dev/sda2; then
    fail "ntfs_is_dirty: 'refusing to operate' misread as dirty"
else
    pass "ntfs_is_dirty: refusing-to-operate is not evidence of dirt"
fi
ntfsfix() { printf 'NTFS volume is dirty.\n'; return 0; }
if ntfs_is_dirty /dev/sda2; then
    pass "ntfs_is_dirty: genuine dirty report still detected"
else
    fail "ntfs_is_dirty: missed a genuine dirty report"
fi

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
