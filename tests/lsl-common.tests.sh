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
