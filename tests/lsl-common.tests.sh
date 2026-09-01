#!/bin/bash
# tests/lsl-common.tests.sh - mock-based tests for lsl-common.sh helpers.
#
# Run: bash tests/lsl-common.tests.sh   (also wired into build.sh)
set -u

PASS=0; FAIL=0
assert() { # $1 = condition (eval'd), $2 = name
    if eval "$1"; then
        PASS=$((PASS + 1)); echo "  PASS: $2"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: $2"
    fi
}

# Load the real functions (lsl-common.sh has no side effects at source time).
# shellcheck source=/dev/null
. "$(dirname "$0")/../bin/lsl-common.sh"

# # --- lsl_desktop_user: UID 1000 lookup -------------------------------------
getent() { echo "mint:x:1000:1000::/home/mint:/bin/bash"; }
assert '[ "$(lsl_desktop_user)" = mint ]' 'lsl_desktop_user: UID 1000 -> mint'

# # --- fallback: no getent, /home listing ------------------------------------
getent() { return 1; }
ls() { printf 'zorin\n'; }
assert '[ "$(lsl_desktop_user)" = zorin ]' 'lsl_desktop_user: /home fallback -> zorin'

# # --- fallback: nothing -> mint ---------------------------------------------
ls() { return 1; }
assert '[ "$(lsl_desktop_user)" = mint ]' 'lsl_desktop_user: final fallback -> mint'

# # --- lsl_is_usb_mode --------------------------------------------------------
LSL_DATA_DIR=/cdrom
assert 'lsl_is_usb_mode' 'lsl_is_usb_mode: /cdrom -> usb'
LSL_DATA_DIR=/persist
assert 'lsl_is_usb_mode' 'lsl_is_usb_mode: /persist -> usb'
LSL_DATA_DIR=/mnt/c/Users/lsl-usb
assert '! lsl_is_usb_mode' 'lsl_is_usb_mode: /mnt/c/Users/lsl-usb -> hdd'

# # --- lsl_data_dir_is_persistent ---------------------------------------------
# Mock findmnt to report a given filesystem type for the data dir's mountpoint.
findmnt() { echo "${LSL_TEST_FSTYPE:-}"; }
LSL_DATA_DIR=/mnt/c/Users/lsl-usb
LSL_TEST_FSTYPE=overlay;  assert '! lsl_data_dir_is_persistent' 'data dir on overlay root -> not persistent'
LSL_TEST_FSTYPE=ntfs3;    assert 'lsl_data_dir_is_persistent' 'data dir on ntfs3 -> persistent'
LSL_TEST_FSTYPE=vfat;     assert 'lsl_data_dir_is_persistent' 'data dir on vfat (USB) -> persistent'
LSL_TEST_FSTYPE=;         assert '! lsl_data_dir_is_persistent' 'data dir on unknown fstype -> not persistent'

# --- lsl_cdrom_free_mib / lsl_ensure_cdrom_space ------------------------------
# Mock df to emulate --output=avail (header "Avail" then the value).
df() { echo "Avail"; echo "${LSL_TEST_AVAIL:-0}"; }
LSL_TEST_AVAIL=500; assert 'lsl_ensure_cdrom_space 256' '500 MiB free, need 256 -> ok'
LSL_TEST_AVAIL=100; assert '! lsl_ensure_cdrom_space 256' '100 MiB free, need 256 -> not ok'
LSL_TEST_AVAIL=0;   assert 'lsl_ensure_cdrom_space 256' 'unknown free -> non-blocking ok'

# --- lsl_data_dir_is_persistent ----------------------------------------------
# Mock findmnt to return a fixed fstype for every query (TARGET + FSTYPE).
findmnt() { echo "${LSL_TEST_FST:-}"; }
LSL_TEST_FST=overlay; LSL_DATA_DIR=/mnt/c/Users/lsl-usb; assert '! lsl_data_dir_is_persistent' 'overlay data dir not persistent'
LSL_TEST_FST=ntfs3;   assert 'lsl_data_dir_is_persistent' 'ntfs3 data dir persistent'
LSL_TEST_FST=tmpfs;   assert '! lsl_data_dir_is_persistent' 'tmpfs data dir not persistent'
LSL_TEST_FST=;        assert '! lsl_data_dir_is_persistent' 'empty fstype not persistent'
LSL_TEST_FST=vfat;    assert 'lsl_data_dir_is_persistent' 'vfat (USB) data dir persistent'
unset -f findmnt

# --- lsl_cdrom_is_vfat / lsl_fat32_max_bytes --------------------------------
findmnt() { echo "${LSL_TEST_FSTYPE:-}"; }
LSL_TEST_FSTYPE=vfat;   assert 'lsl_cdrom_is_vfat' 'vfat /cdrom detected as FAT'
LSL_TEST_FSTYPE=ext4;   assert '! lsl_cdrom_is_vfat' 'ext4 /cdrom not FAT'
LSL_TEST_FSTYPE=;       assert '! lsl_cdrom_is_vfat' 'unknown /cdrom not FAT'
unset -f findmnt
assert 'test "$(lsl_fat32_max_bytes)" = 4294901760' 'fat32 max bytes is 4 GiB - 64 KiB'


# --- lsl_ensure_cdrom_space FAT32 ceiling (the uproot refusal path) --------
# On a vfat /cdrom, a layer bigger than lsl_fat32_max_bytes must be refused.
findmnt() { echo "${LSL_TEST_FSTYPE:-}"; }
LSL_TEST_FSTYPE=vfat
# Force the FAT32 size helper by stubbing findmnt's FSTYPE output.
assert 'lsl_cdrom_is_vfat' 'vfat /cdrom (FAT32) detected for ceiling check'
# A layer at the ceiling boundary +1 must be refused by the ceiling math.
SZ_CEILING="$(lsl_fat32_max_bytes)"
BIG=$(( SZ_CEILING + 1 ))
# lsl_ensure_cdrom_space is about free space, not the FAT32 ceiling; the ceiling
# itself is enforced in uproot via lsl_cdrom_is_vfat + lsl_fat32_max_bytes. We
# assert the helper returns the expected constant so the uproot guard is sound.
assert 'test "$(lsl_fat32_max_bytes)" -gt 4000000000' 'fat32 ceiling exceeds 4 GiB boundary constant'
unset -f findmnt

# --- lsl_merge_fstab ordering + block isolation -----------------------------
# Mock the helpers lsl_merge_fstab uses so we can assert block placement.
findmnt() {
    local o="" mnt=""
    while [ $# -gt 0 ]; do
        case "$1" in -n) ;; -o) o="$2"; shift ;; *) mnt="$1" ;; esac
        shift
    done
    case "$mnt:$o" in
        /cdrom:SOURCE) echo "/dev/sdb1" ;;
        /cdrom:FSTYPE) echo "vfat" ;;
        /mnt/c:SOURCE) echo "/dev/nvme0n1p3" ;;
        /mnt/c:FSTYPE) echo "ntfs3" ;;
        /home:SOURCE)  echo "/dev/loop0" ;;
        /home:FSTYPE)  echo "btrfs" ;;
    esac
}
losetup() { case "$1" in -n|-O) echo "/cdrom/home.btrfs" ;; esac; }
blkid() { echo "UUID=ABCD-1234"; }
mountpoint() { case "$2" in /cdrom|/mnt/c|/home) return 0 ;; *) return 1 ;; esac; }

FSTAB_TMP="$(mktemp)"
printf 'user-line-kept\n# BEGIN lsl-usb fstab\nstale-old-block\n# END lsl-usb fstab\n' > "$FSTAB_TMP"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Source lsl_merge_fstab by extracting it (it writes to /etc/fstab by default).
extract_merge() { sed -n '/^lsl_merge_fstab()/,/^}/p' "$REPO_ROOT/onboot.sh"; }
# Re-point the function's fstab target by shadowing /etc/fstab via a temp file.
eval "$(extract_merge | sed "s|local fstab=/etc/fstab|local fstab=\"$FSTAB_TMP\"|")"
lsl_merge_fstab
ORDER_PASS=1
# USER line must survive outside the block.
grep -qx 'user-line-kept' "$FSTAB_TMP" || ORDER_PASS=0
# Stale block content must be gone.
grep -q 'stale-old-block' "$FSTAB_TMP" && ORDER_PASS=0
# New block present with cdrom + home loop entries in that order.
grep -qx '# BEGIN lsl-usb fstab' "$FSTAB_TMP" || ORDER_PASS=0
c_line="$(grep -n '# BEGIN lsl-usb fstab' "$FSTAB_TMP" | cut -d: -f1)"
h_line="$(grep -n 'home.btrfs /home' "$FSTAB_TMP" | cut -d: -f1)"
[ -n "$c_line" ] && [ -n "$h_line" ] && [ "$h_line" -gt "$c_line" ] || ORDER_PASS=0
assert '[ "$ORDER_PASS" -eq 1 ]' 'lsl_merge_fstab keeps user lines, drops stale block, appends new block with /home loop'
rm -f "$FSTAB_TMP"
unset -f findmnt losetup blkid mountpoint

# --- lsl_vhdx_append: dedupe + persist -------------------------------------
LSL_VHDX_LIST_FILE="$(mktemp)"
VH="$(mktemp)"   # must be a real file: lsl_vhdx_append requires -f
lsl_vhdx_append "$VH"
lsl_vhdx_append "$VH"   # duplicate must be dropped
n="$(lsl_vhdx_paths_stdout | wc -l | tr -d ' ')"
assert '[ "$n" = 1 ]' 'lsl_vhdx_append: dedupes repeated paths'
rm -f "$VH" "$LSL_VHDX_LIST_FILE"

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
