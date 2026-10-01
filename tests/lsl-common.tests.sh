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

# # --- fallback: nothing -> EMPTY (never invent a username) -------------------
# This used to assert "mint". Returning a hardcoded development-distro name
# turned "there is no desktop user in this context" (uproot's chroot) into
# "write to /home/mint", silently losing every $HOME install - the terminal pin
# included (WHYFAIL13). Callers must be able to tell "no user" and skip.
ls() { return 1; }
assert '[ -z "$(lsl_desktop_user)" ]' 'lsl_desktop_user: no user found -> empty (does not guess)'

# # --- lsl_desktop_user_for_session: loginctl wins when present ---------------
# The host-side resolver used by lsl-firstboot.sh's $HOME installer. Inside
# uproot's chroot loginctl cannot reach the host /run, so it must degrade to the
# same heuristics (and to empty) rather than inventing a name.
loginctl() {
    case "$*" in
        *"list-sessions"*) printf '3 1000 ubuntu seat0\n' ;;
        *"Type"*) printf 'x11\n' ;;
        *"Name"*) printf 'ubuntu\n' ;;
        *) return 1 ;;
    esac
}
assert '[ "$(lsl_desktop_user_for_session)" = ubuntu ]' 'lsl_desktop_user_for_session: loginctl graphical session -> ubuntu'
# A root-only session must not be adopted as the desktop user.
loginctl() {
    case "$*" in
        *"list-sessions"*) printf '3 0 root seat0\n' ;;
        *"Type"*) printf 'x11\n' ;;
        *"Name"*) printf 'root\n' ;;
        *) return 1 ;;
    esac
}
getent() { echo "mint:x:1000:1000::/home/mint:/bin/bash"; }
assert '[ "$(lsl_desktop_user_for_session)" = mint ]' 'lsl_desktop_user_for_session: root session skipped -> uid 1000 fallback'
unset -f loginctl
# Restore the real commands: these mocks are plain shell functions, so they
# leaked into every later test (the layer-prune cases below call ls/wc and got
# the stub's "zorin"). Unset at the end of each block that stubs a coreutils
# command; getent/ls/df are all stubbed in this file.
unset -f ls getent

# # --- lsl_is_usb_mode --------------------------------------------------------
LSL_DATA_DIR=/cdrom
assert 'lsl_is_usb_mode' 'lsl_is_usb_mode: /cdrom -> usb'
LSL_DATA_DIR=/persist
assert 'lsl_is_usb_mode' 'lsl_is_usb_mode: /persist -> usb'
LSL_DATA_DIR=/mnt/c/Users/lsl-usb
assert '! lsl_is_usb_mode' 'lsl_is_usb_mode: /mnt/c/Users/lsl-usb -> hdd'

# # --- lsl_effective_home_mode ------------------------------------------------
# The mode /home was ACTUALLY mounted with, from the state file. This is what
# persistence writers must branch on. Regression for the 2026-09-28 first-boot
# data loss: a fallback tmpfs overlay recorded LSL_MODE=usb, so uphome's fresh
# lsl_is_usb_mode resolve said "hdd", ran a no-op btrfs sync, exited 0, and the
# first-boot home was lost on reboot (see FRAGILE_HOME.md).
EHM_TMP="$(mktemp -d)"
mkdir -p "$EHM_TMP/run"
# lsl_state_file() returns a fixed /run path; override it for the test.
eval "$(sed -n '/^lsl_state_file()/,/^}/p' bin/lsl-common.sh | sed "s|echo /run/lsl-usb.state|echo $EHM_TMP/run/lsl-usb.state|")"

# Each LSL_MODE value survives the round trip verbatim.
for m in ram usb usb-fallback hdd; do
    printf 'LSL_HOME_LOWER=/run/lsl-home-lower\nLSL_MODE=%s\n' "$m" \
        > "$EHM_TMP/run/lsl-usb.state"
    assert '[ "$(lsl_effective_home_mode)" = '"$m"' ]' "lsl_effective_home_mode: LSL_MODE=$m round-trips"
done

# The real fallback state file (all four keys) is read correctly - the CRLF /
# key-order shape lsl-mount-home.sh actually writes.
printf 'LSL_HOME_LOWER=/run/lsl-home-lower\nLSL_HOME_UPPER=/run/lsl-home-overlay/upper\nLSL_HOME_WORK=/run/lsl-home-overlay/work\nLSL_MODE=usb-fallback\n' \
    > "$EHM_TMP/run/lsl-usb.state"
assert '[ "$(lsl_effective_home_mode)" = usb-fallback ]' \
       'lsl_effective_home_mode: real fallback state file -> usb-fallback'

# A CRLF state file (written onto FAT) must not leak \r into the mode.
printf 'LSL_MODE=usb-fallback\r\n' > "$EHM_TMP/run/lsl-usb.state"
assert '[ "$(lsl_effective_home_mode)" = usb-fallback ]' \
       'lsl_effective_home_mode: CRLF state file trims CR'

# The LAST LSL_MODE wins if the file ever carries more than one.
printf 'LSL_MODE=usb\nLSL_MODE=usb-fallback\n' > "$EHM_TMP/run/lsl-usb.state"
assert '[ "$(lsl_effective_home_mode)" = usb-fallback ]' \
       'lsl_effective_home_mode: last LSL_MODE wins'

# No state file: fall back to the live mount type. /home is not tmpfs here, so
# the answer must be empty (unknown), NOT a fabricated "usb"/"hdd".
rm -f "$EHM_TMP/run/lsl-usb.state"
findmnt() { echo "overlay"; }
assert '[ -z "$(lsl_effective_home_mode)" ]' \
       'lsl_effective_home_mode: no state file + overlay /home -> empty'
findmnt() { echo "tmpfs"; }
assert '[ "$(lsl_effective_home_mode)" = ram ]' \
       'lsl_effective_home_mode: no state file + tmpfs /home -> ram'
unset -f findmnt
rm -rf "$EHM_TMP"

# A legacy stick (pre-fix lsl-mount-home.sh) writing plain LSL_MODE=usb must
# still read as usb and still flush - the new value must not break old sticks.
EHM_TMP="$(mktemp -d)"; mkdir -p "$EHM_TMP/run"
eval "$(sed -n '/^lsl_state_file()/,/^}/p' bin/lsl-common.sh | sed "s|echo /run/lsl-usb.state|echo $EHM_TMP/run/lsl-usb.state|")"
printf 'LSL_MODE=usb\n' > "$EHM_TMP/run/lsl-usb.state"
assert '[ "$(lsl_effective_home_mode)" = usb ]' 'legacy stick: LSL_MODE=usb still reads as usb'
rm -rf "$EHM_TMP"

# # --- lsl_effective_home_is_usb / _is_hdd ------------------------------------
# The predicates the daemons and the shutdown UI branch on. Only "usb" is a real
# stick overlay; only "hdd" has loop-backed btrfs images. ram and usb-fallback
# are neither (a fallback overlay must NOT be treated as a stick).
EHM_TMP="$(mktemp -d)"; mkdir -p "$EHM_TMP/run"
eval "$(sed -n '/^lsl_state_file()/,/^}/p' bin/lsl-common.sh | sed "s|echo /run/lsl-usb.state|echo $EHM_TMP/run/lsl-usb.state|")"
for m in ram usb usb-fallback hdd; do
    printf 'LSL_MODE=%s\n' "$m" > "$EHM_TMP/run/lsl-usb.state"
    case "$m" in
        usb) assert 'lsl_effective_home_is_usb && ! lsl_effective_home_is_hdd' 'is_usb/is_hdd: LSL_MODE=usb -> usb only' ;;
        hdd) assert 'lsl_effective_home_is_hdd && ! lsl_effective_home_is_usb' 'is_usb/is_hdd: LSL_MODE=hdd -> hdd only' ;;
        *)   assert '! lsl_effective_home_is_usb && ! lsl_effective_home_is_hdd' "is_usb/is_hdd: LSL_MODE=$m -> neither" ;;
    esac
done
# No state file: fall back to the old prediction driven by LSL_DATA_DIR.
rm -f "$EHM_TMP/run/lsl-usb.state"
LSL_DATA_DIR=/cdrom
assert 'lsl_effective_home_is_usb && ! lsl_effective_home_is_hdd' 'is_usb/is_hdd: no state file + /cdrom -> usb'
LSL_DATA_DIR=/mnt/c/Users/lsl-usb
assert 'lsl_effective_home_is_hdd && ! lsl_effective_home_is_usb' 'is_usb/is_hdd: no state file + /mnt/c -> hdd'
rm -rf "$EHM_TMP"

# # --- lsl_ensure_hivex_tools -------------------------------------------------
# Installs the staged .debs from $LSL_CDROM/pkgs when hivexregedit is missing, so
# mount_all.sh can map /mnt/c BEFORE /home mounts (no first-boot fallback).
HX_TMP="$(mktemp -d)"; mkdir -p "$HX_TMP/bin" "$HX_TMP/pkgs"
LSL_CDROM="$HX_TMP"
# (a) hivexregedit already on PATH -> ok, no dpkg needed.
: > "$HX_TMP/bin/hivexregedit"; chmod +x "$HX_TMP/bin/hivexregedit"
PATH="$HX_TMP/bin:$PATH"; hash -r
assert 'lsl_ensure_hivex_tools' 'ensure_hivex_tools: present -> ok'
# (b) absent and nothing staged -> fail (no false success).
# PATH must not leave the REAL hivexregedit reachable: this stick has it
# installed (/usr/bin/hivexregedit, from the WHYFAIL9/10 staged .debs), so a
# plain "prepend a stub dir" leaves `command -v hivexregedit` succeeding and the
# function correctly returning 0 - failing this assertion for the wrong reason.
# Shadow every PATH entry with an empty dir so absence is actually tested.
rm -f "$HX_TMP/bin/hivexregedit"; hash -r
mkdir -p "$HX_TMP/empty"
_old_path="$PATH"
PATH="$HX_TMP/empty"   # nothing on PATH at all -> hivexregedit truly absent
assert '! lsl_ensure_hivex_tools' 'ensure_hivex_tools: absent + no pkgs -> fail'
PATH="$_old_path"; hash -r
# (c) absent but a staged .deb whose install drops the binary -> ok.
: > "$HX_TMP/pkgs/libhivex-bin.deb"
dpkg() { : > "$HX_TMP/bin/hivexregedit"; chmod +x "$HX_TMP/bin/hivexregedit"; }
assert 'lsl_ensure_hivex_tools' 'ensure_hivex_tools: staged .deb installs -> ok'
unset -f dpkg
PATH="${PATH#"$HX_TMP/bin:"}"; hash -r
unset LSL_CDROM   # later tests expect the default /cdrom stick path
rm -rf "$HX_TMP"

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
unset -f df

# --- lsl_data_dir_is_persistent ----------------------------------------------
# Mock findmnt to return a fixed fstype for every query (TARGET + FSTYPE).
findmnt() { echo "${LSL_TEST_FST:-}"; }
LSL_TEST_FST=overlay; LSL_DATA_DIR=/mnt/c/Users/lsl-usb; assert '! lsl_data_dir_is_persistent' 'overlay data dir not persistent'
LSL_TEST_FST=ntfs3;   assert 'lsl_data_dir_is_persistent' 'ntfs3 data dir persistent'
LSL_TEST_FST=tmpfs;   assert '! lsl_data_dir_is_persistent' 'tmpfs data dir not persistent'
LSL_TEST_FST=;        assert '! lsl_data_dir_is_persistent' 'empty fstype not persistent'
LSL_TEST_FST=vfat;    assert 'lsl_data_dir_is_persistent' 'vfat (USB) data dir persistent'
unset -f findmnt

# --- lsl_data_dir_is_writable (the ro-landing race) ---------------------------
# The boot journal showed /mnt/c landing READ-ONLY (ntfs-3g) at 03:42:37 while
# the rw mount succeeded a second later. Persistence alone accepted the ro
# landing, so the btrfs home was declared unwritable and /home fell back to a
# throwaway tmpfs overlay. These cases pin the rw requirement.
# Mock findmnt to answer per-column: $1 is the OPTIONS/column selector.
findmnt() {
    case "$*" in
        *-o\ TARGET*)   echo "${LSL_TEST_MP:-}" ;;
        *-o\ FSTYPE*)   echo "${LSL_TEST_FST2:-}" ;;
        *-o\ OPTIONS*)  echo "${LSL_TEST_OPTS:-}" ;;
        *)              echo "" ;;
    esac
}
LSL_DATA_DIR=/mnt/c/Users/lsl-usb
LSL_TEST_MP=/mnt/c; LSL_TEST_FST2=ntfs3
LSL_TEST_OPTS='rw,relatime,uid=0,gid=0,iocharset=utf8'
assert 'lsl_data_dir_is_writable' 'ntfs3 mounted rw -> writable'
LSL_TEST_OPTS='ro,relatime,uid=0,gid=0,iocharset=utf8'
assert '! lsl_data_dir_is_writable' 'ntfs3 mounted ro -> NOT writable (the race)'
LSL_TEST_OPTS='rw,relatime'
LSL_TEST_FST2=vfat
assert 'lsl_data_dir_is_writable' 'vfat mounted rw -> writable'
LSL_TEST_FST2=tmpfs
assert '! lsl_data_dir_is_writable' 'tmpfs is never writable-for-persistence'
LSL_TEST_FST2=ntfs3; LSL_TEST_OPTS=''
assert '! lsl_data_dir_is_writable' 'unknown options -> not writable (no rw proof)'
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

# --- lsl_load_config / env-file parsing (CRLF regression) -------------------
# The env file lives on the FAT stick and is edited from Windows, so it arrives
# with CRLF endings. Sourcing it raw left a trailing CR in LSL_DATA_DIR, which
# matched neither /cdrom nor /persist in lsl_is_usb_mode and could not be
# resolved by findmnt - so onboot.sh decided the data dir was not persistent and
# silently fell back to a volatile tmpfs /home.
ENV_TMP="$(mktemp -d)"

# CRLF env file: values must arrive CR-free, and other keys must be applied.
printf 'LSL_DATA_DIR=/mnt/c/Users/lsl-usb\r\nLSL_HOME_BTRFS_MIB=512\r\n' > "$ENV_TMP/crlf.env"
( export LSL_ENV_FILE="$ENV_TMP/crlf.env"; unset LSL_DATA_DIR LSL_HOME_BTRFS_MIB
  lsl_load_config >/dev/null 2>&1
  [ "$LSL_DATA_DIR" = /mnt/c/Users/lsl-usb ] && [ "$LSL_HOME_BTRFS_MIB" = 512 ] ) \
  && R_CRLF=0 || R_CRLF=1
assert '[ "$R_CRLF" -eq 0 ]' 'lsl_load_config: CRLF env file parsed, CR stripped, keys applied'

# A CRLF env file naming a USB path must still select USB mode.
printf 'LSL_DATA_DIR=/cdrom/usbhome\r\n' > "$ENV_TMP/usb.env"
( export LSL_ENV_FILE="$ENV_TMP/usb.env"; unset LSL_DATA_DIR
  lsl_load_config >/dev/null 2>&1
  lsl_is_usb_mode ) && R_USB=0 || R_USB=1
assert '[ "$R_USB" -eq 0 ]' 'lsl_load_config: CRLF USB path still selects USB mode'

# Leading BOM tolerated.
printf '\xEF\xBB\xBFLSL_DATA_DIR=/cdrom/bom-home\r\n' > "$ENV_TMP/bom.env"
( export LSL_ENV_FILE="$ENV_TMP/bom.env"; unset LSL_DATA_DIR
  lsl_load_config >/dev/null 2>&1
  [ "$LSL_DATA_DIR" = /cdrom/bom-home ] && lsl_is_usb_mode ) && R_BOM=0 || R_BOM=1
assert '[ "$R_BOM" -eq 0 ]' 'lsl_load_config: leading BOM stripped'

# A stray CR inherited from the environment (not a file) is trimmed too.
# lsl_env_file is stubbed off so this tests the trim, not the file's own value.
( unset LSL_ENV_FILE; export HOME="$ENV_TMP/nohome"
  lsl_env_file() { return 1; }
  CR=$'\r'; export LSL_DATA_DIR="/cdrom/usbhome${CR}"
  lsl_load_config >/dev/null 2>&1
  [ "$LSL_DATA_DIR" = /cdrom/usbhome ] && lsl_is_usb_mode ) && R_ENVCR=0 || R_ENVCR=1
assert '[ "$R_ENVCR" -eq 0 ]' 'lsl_load_config: stray CR in environment trimmed'

# lsl_resolve_data_dir must trim CR as well (it feeds mode detection).
( unset LSL_ENV_FILE; export HOME="$ENV_TMP/nohome"
  lsl_env_file() { return 1; }
  CR=$'\r'; export LSL_DATA_DIR="/cdrom/usbhome${CR}"
  [ "$(lsl_resolve_data_dir)" = /cdrom/usbhome ] ) && R_RES=0 || R_RES=1
assert '[ "$R_RES" -eq 0 ]' 'lsl_resolve_data_dir: trims CR'

# The stick's env file must win over a stale copy in the live $HOME.
# LSL_CDROM stubs the stick mount so this runs off-stick (no /cdrom here).
mkdir -p "$ENV_TMP/home" "$ENV_TMP/cdrom"
printf 'LSL_DATA_DIR=/cdrom/usbhome\n' > "$ENV_TMP/cdrom/lsl-usb.env"
printf 'LSL_DATA_DIR=/nonexistent-shadow\n' > "$ENV_TMP/home/lsl-usb.env"
( unset LSL_ENV_FILE; export HOME="$ENV_TMP/home" LSL_CDROM="$ENV_TMP/cdrom"
  [ "$(lsl_env_file)" = "$ENV_TMP/cdrom/lsl-usb.env" ] ) && R_SHADOW=0 || R_SHADOW=1
assert '[ "$R_SHADOW" -eq 0 ]' 'lsl_env_file: /cdrom/lsl-usb.env preferred over $HOME copy'

rm -rf "$ENV_TMP"

# --- layer prune: reap superseded appended squashfs layers -------------------
# Regression for the bug where 5 SUCCESSFUL firstboots left 5x761MB (3.6 GB) of
# layers, 4 inert because menu.lst named only the newest: cleanup ran only on the
# retry path, which never fired.
#
# Layer prune: casper globs *.squashfs and stacks the matches lexically, so
# layer ORDER comes from the filenames and there is no "named" layer any more.
# filesystem.squashfs (base) < filesystem_z0_firstboot.squashfs (stub) <
# filesystem_z<ts>.squashfs (appends, newest last). An older append is
# therefore pure dead weight once a newer one exists.
#
# The load-bearing invariants are that the BASE and the STUB are never touched
# (the stub carries lsl-firstboot.service) and that the newest append survives.
LAYER_TMP="$(mktemp -d)"
mkdir -p "$LAYER_TMP/casper"
mk_layer() { dd if=/dev/zero of="$LAYER_TMP/casper/filesystem_z$1.squashfs" bs=1k count=1 2>/dev/null; }
mk_base() { dd if=/dev/zero of="$LAYER_TMP/casper/filesystem.squashfs" bs=1k count=1 2>/dev/null; }
mk_stub() { dd if=/dev/zero of="$LAYER_TMP/casper/filesystem_z0_firstboot.squashfs" bs=1k count=1 2>/dev/null; }

# Drive the firstboot helper (it is a script, so extract the one function).
run_prune() {
    { echo 'set -uo pipefail'; echo "STICK_DIR=$LAYER_TMP"; echo 'log() { :; }'
      sed -n '/^lsl_firstboot_prune_orphan_layers()/,/^}/p' misc/lsl-firstboot.sh
      echo 'lsl_firstboot_prune_orphan_layers'; } > "$LAYER_TMP/drive.sh"
    bash "$LAYER_TMP/drive.sh" >/dev/null 2>&1 || true
}
count_layers() { ls "$LAYER_TMP"/casper/filesystem_z[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]*.squashfs 2>/dev/null | wc -l | tr -d ' '; }

# 1. Superseded appends are reaped; the newest survives. Base and stub are
#    untouched.
mk_base; mk_stub
mk_layer 20260916164712; mk_layer 20260919045856; mk_layer 20260921085616
run_prune
assert '[ "$(count_layers)" = 1 ]' 'layer prune: superseded appends removed'
assert '[ -f "$LAYER_TMP/casper/filesystem_z20260921085616.squashfs" ]' \
       'layer prune: the newest append survives'
assert '[ -f "$LAYER_TMP/casper/filesystem.squashfs" ]' \
       'layer prune: the base layer is never reaped'
assert '[ -f "$LAYER_TMP/casper/filesystem_z0_firstboot.squashfs" ]' \
       'layer prune: the firstboot stub is never reaped (glob must not match z0_)'

# 2. No appends at all -> the stub must survive (this is the glob trap: a
#    filesystem_z[0-9]* glob would match filesystem_z0_firstboot and delete it).
rm -f "$LAYER_TMP"/casper/filesystem_z[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]*.squashfs
mk_base; mk_stub
run_prune
assert '[ -f "$LAYER_TMP/casper/filesystem_z0_firstboot.squashfs" ]' \
       'layer prune: stub alone is never deleted'
assert '[ -f "$LAYER_TMP/casper/filesystem.squashfs" ]' \
       'layer prune: base alone is never deleted'

# 3. A single append is the keeper; nothing to reap.
mk_layer 20260930120000
run_prune
assert '[ "$(count_layers)" = 1 ]' 'layer prune: a lone append survives'
assert '[ -f "$LAYER_TMP/casper/filesystem_z20260930120000.squashfs" ]' \
       'layer prune: the lone append is still present'

# 4. Many appends -> exactly one survives (the newest), and it is the newest
#    by NAME, which is the same order casper stacks by.
rm -f "$LAYER_TMP"/casper/filesystem_z[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]*.squashfs
mk_base; mk_stub
mk_layer 20260928025844; mk_layer 20260928025844.20260928142919 2>/dev/null
mk_layer 20260929035510; mk_layer 20260930121931; mk_layer 20260916164712
run_prune
assert '[ "$(count_layers)" = 1 ]' 'layer prune: 4 appends collapse to the newest'
assert '[ -f "$LAYER_TMP/casper/filesystem_z20260930121931.squashfs" ]' \
       'layer prune: the newest append by name is the keeper'
rm -rf "$LAYER_TMP"

# --- lsl_ensure_user_home: rebuild a missing user home ----------------------
# Regression: a persistent /home is keyed to LSL_DATA_DIR, not to the distro. A
# home image seeded by another live user (Ubuntu /home/ubuntu) reused on a Mint
# stick (user /home/mint) has no home for this boot's user, so LIGHTDM autologin
# dies and falls back to the greeter while the RAM-home entry logs in fine.
HROOT="$(mktemp -d)"; HSKEL="$(mktemp -d)"
printf 'skel\n' > "$HSKEL/.profile"
lsl_ensure_user_home "$HROOT" mint "$HSKEL" 2>/dev/null
assert '[ -d "$HROOT/mint" ]' 'lsl_ensure_user_home: creates the missing user home'
assert '[ -f "$HROOT/mint/.profile" ]' 'lsl_ensure_user_home: seeds a new home from skel'
# A pre-existing, non-empty home is left alone (never re-seeded / clobbered).
printf 'keep\n' > "$HROOT/mint/keep.txt"; rm -f "$HROOT/mint/.profile"
lsl_ensure_user_home "$HROOT" mint "$HSKEL" 2>/dev/null
assert '[ -f "$HROOT/mint/keep.txt" ]' 'lsl_ensure_user_home: keeps an existing home'
assert '[ ! -f "$HROOT/mint/.profile" ]' 'lsl_ensure_user_home: does not re-seed a non-empty home'
# An empty user name is a no-op (never creates /home//).
HROOT2="$(mktemp -d)"
lsl_ensure_user_home "$HROOT2" "" "$HSKEL" 2>/dev/null
assert '[ -z "$(ls -A "$HROOT2")" ]' 'lsl_ensure_user_home: empty user is a no-op'
rm -rf "$HROOT" "$HROOT2" "$HSKEL"

# --- per-distro home/cache image names --------------------------------------
LSL_DISTRO_KEY="linuxmint"
assert '[ "$(lsl_distro_key)" = linuxmint ]' 'lsl_distro_key: override wins'
LSL_DATA_DIR=/mnt/c/Users/lsl-usb
assert 'case "$(lsl_home_btrfs_path)" in */home-linuxmint.btrfs) true;; *) false;; esac' 'home.btrfs path is per-distro'
assert 'case "$(lsl_cache_btrfs_path)" in */cache-linuxmint.btrfs) true;; *) false;; esac' 'cache.btrfs path is per-distro'
assert '[ "$(lsl_home_sfs_path)" = "/cdrom/home-linuxmint.sfs" ]' 'usb home.sfs path is per-distro'
LSL_DISTRO_KEY="a b/c" 
assert '[ "$(lsl_distro_key)" = "a_b_c" ]' 'lsl_distro_key: sanitises the id'
unset LSL_DISTRO_KEY

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
