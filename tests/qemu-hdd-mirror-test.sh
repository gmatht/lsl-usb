#!/bin/bash
# QEMU/KVM boot test for the HDD-mirror auto-detect hook (initramfs/lsl_hdd_mirror.sh).
#
# Builds a bootable FAT32 "USB" (Rufus ISO-mode equivalent) from a Linux Mint 22.x
# ISO plus the lsl-usb bundle, builds a SECOND disk holding the squashfs-layer
# mirror (as bin/lsl-copy-sfs-hdd.sh would write it), repacks the initrd to inject
# the auto-detect hook, boots the lot under KVM, and asserts the hook ADOPTS the
# mirror (via the gated "lsl_hdd_mirror_debug" console line) before casper mounts
# the live root. This proves the hook's device scan + manifest verify + LAYERFS_PATH
# export work in a real kernel/initramfs, not just in mocked unit tests.
#
# A second run with "lsl_no_hdd_mirror" appended to the cmdline documents the safe
# fallback (the hook should report NO MIRROR and casper falls back to USB).
#
# Requirements (clean SKIP if missing):
#   - LSL_ISO (or $1): path to a Mint 22.x ISO
#   - a QEMU binary (QEMU_BIN, default qemu-system-x86_64) + acceleration
#     (--accel kvm|whpx|tcg|auto, or LSL_ACCEL; auto takes /dev/kvm else WHPX
#     when the binary offers it - run the whole script in WSL2 as root with
#     QEMU_BIN pointing at Windows QEMU for WHPX; no nested virtualization,
#     QEMU runs on the host. See tests/qemu-boot-test.sh --help.)
#   - sfdisk, mkfs.vfat (dosfstools), losetup, mksquashfs, unzip, cpio
#   - root (for losetup/mount)
#   - a source initrd (LSL_BASE_INITRD or /cdrom/casper/initrd.lz or the ISO initrd)
set -uo pipefail

ACCEL="${LSL_ACCEL:-auto}"
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
POS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --accel) ACCEL="${2:-}"; [ -n "$ACCEL" ] || { echo "--accel needs a value" >&2; exit 2; }; shift 2 ;;
        --help|-h) echo "Usage: $0 [--accel kvm|whpx|tcg|auto] [ISO_PATH] [EXTRA_KERNEL_ARGS]"; exit 0 ;;
        --) shift; while [ $# -gt 0 ]; do POS+=("$1"); shift; done; break ;;
        -*) echo "Unknown option: $1" >&2; exit 2 ;;
        *) POS+=("$1"); shift ;;
    esac
done
ISO="${POS[0]:-${LSL_ISO:-}}"
LSL_ACCEL="$ACCEL"
EXTRA="${POS[1]:-lsl_hdd_mirror_debug}"   # extra kernel args for the boot
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$REPO_ROOT/dist"
HOOK="$REPO_ROOT/initramfs/lsl_hdd_mirror.sh"

skip() { echo "SKIP: $1"; exit 0; }
# shellcheck disable=SC1091
. "$REPO_ROOT/tests/qemu-accel.sh"
[ -n "$ISO" ]      || skip "LSL_ISO not set (pass the ISO path as \$1 or \$LSL_ISO)"
[ -f "$ISO" ]      || skip "ISO not found: $ISO"
command -v "$QEMU_BIN" >/dev/null 2>&1 || skip "$QEMU_BIN not installed"
echo "ARCH: qemu = $(command -v "$QEMU_BIN") (x86_64)"
command -v sfdisk  >/dev/null 2>&1 || skip "sfdisk not installed"
command -v mkfs.vfat >/dev/null 2>&1 || skip "mkfs.vfat (dosfstools) not installed"
command -v losetup >/dev/null 2>&1 || skip "losetup not installed"
command -v mksquashfs >/dev/null 2>&1 || skip "mksquashfs not installed"
command -v unzip   >/dev/null 2>&1 || skip "unzip not installed"
command -v unmkinitramfs >/dev/null 2>&1 || skip "unmkinitramfs not installed"
[ -f "$HOOK" ]     || skip "hook missing: $HOOK"
[ "$(id -u)" -eq 0 ] || skip "must run as root (needs losetup/mount)"

# --- locate a base initrd to repack (inject the hook) ----------------------
BASE_INITRD="${LSL_BASE_INITRD:-}"
for cand in "$BASE_INITRD" /cdrom/casper/initrd.lz; do
    [ -n "$cand" ] && [ -f "$cand" ] && { BASE_INITRD="$cand"; break; }
done
[ -f "$BASE_INITRD" ] || skip "no base initrd found (set LSL_BASE_INITRD)"

WORK="/tmp/qemu-hdd-test"; rm -rf "$WORK"; mkdir -p "$WORK"

# --- repack the initrd with the hook (gzip; lz4 may be absent in test env) ---
echo "Repacking initrd from $BASE_INITRD with the HDD-mirror hook ..."
IRX="$WORK/irx"; unmkinitramfs "$BASE_INITRD" "$IRX" || skip "unmkinitramfs failed"
injected=0
for d in "$IRX"/*/; do
    if [ -d "${d}scripts/casper-premount" ]; then
        cp "$HOOK" "${d}scripts/casper-premount/zz_lsl_hdd_mirror"
        chmod +x "${d}scripts/casper-premount/zz_lsl_hdd_mirror"
        # casper's run_scripts *sources* ORDER; each line runs the script as a
        # subprocess, so export wouldn't reach casper. Source it instead.
        order="${d}scripts/casper-premount/ORDER"
        if [ -f "$order" ] && ! grep -q 'zz_lsl_hdd_mirror' "$order"; then
            printf '. /scripts/casper-premount/zz_lsl_hdd_mirror "$@"\n' >> "$order"
        fi
        injected=1
    fi
done
[ "$injected" = 1 ] || skip "no casper-premount dir in initrd"
( for dd in "$IRX"/*/; do ( cd "$dd" && find . -print0 | cpio -0 -H newc -o ); done ) | gzip -9 -c > "$WORK/initrd.lz"
echo "Repacked initrd -> $WORK/initrd.lz (hook injected)"

# --- build the FAT32 "USB" image from the ISO -------------------------------
echo "Building FAT32 USB image from $ISO ..."
DISK="$WORK/usb.img"
truncate -s 5G "$DISK"
printf 'label: dos\n,,c,*\n' | sfdisk "$DISK" >/dev/null
LOOP="$(losetup -f --show -P "$DISK")" || skip "no free loop device"
PART="${LOOP}p1"
mkfs.vfat -F 32 -n MINT "$PART" >/dev/null || skip "mkfs.vfat failed"
MNT="$WORK/mnt"; mkdir -p "$MNT"; mount "$PART" "$MNT"
ISO_MNT="$WORK/iso"; mkdir -p "$ISO_MNT"
mount -o loop,ro "$ISO" "$ISO_MNT" 2>/dev/null || { umount "$MNT" 2>/dev/null; losetup -d "$LOOP" 2>/dev/null; skip "could not mount ISO"; }
echo "ARCH: ISO boot kernel = $(file -b "$ISO_MNT/casper/vmlinuz" 2>/dev/null | cut -c1-90)"
cp -r "$ISO_MNT/casper" "$MNT/casper" || { umount "$ISO_MNT" "$MNT"; losetup -d "$LOOP"; skip "copying casper failed"; }
# Stash the ISO's base root squashfs so the mirror's base matches the boot
# kernel (a version-mismatched mirror root would fail a full boot).
cp "$ISO_MNT/casper/filesystem.squashfs" "$WORK/base-root.squashfs"
# firstboot layer (so the boot is a valid lsl-usb boot); not strictly needed for
# the mirror test, but keeps the image representative.
[ -f "$DIST/filesystem_z0_firstboot.squashfs" ] && cp "$DIST/filesystem_z0_firstboot.squashfs" "$MNT/casper/"
cp "$ISO_MNT/casper/vmlinuz" "$WORK/vmlinuz"
umount "$ISO_MNT"; umount "$MNT"; losetup -d "$LOOP"; sync

# --- build the HDD "mirror" disk (ext4; the hook's native-mount fallback) -----
echo "Building HDD mirror disk ..."
HDD="$WORK/hdd.raw"
truncate -s 6G "$HDD"
LOOP2="$(losetup -f --show -P "$HDD")" || skip "no free loop device for HDD"
printf 'label: dos\n,,L\n' | sfdisk "$HDD" >/dev/null
partprobe "$LOOP2" 2>/dev/null; sleep 1
HP="${LOOP2}p1"
mkfs.ntfs -f -q "$HP" >/dev/null || { losetup -d "$LOOP2"; skip "mkfs.ntfs failed"; }
HMNT="$WORK/hdd"; mkdir -p "$HMNT"
ntfs-3g "$HP" "$HMNT" 2>/dev/null || mount -t ntfs-3g "$HP" "$HMNT" 2>/dev/null || { losetup -d "$LOOP2"; skip "could not mount NTFS to populate"; }
mkdir -p "$HMNT/sfs"
# Mirror base = the SAME release as the boot kernel (stashed above); the z0
# firstboot layer is renamed to filesystem.z0.squashfs. home.sfs is optional.
SRC_ROOT="$WORK/base-root.squashfs"
SRC_Z0="$DIST/filesystem_z0_firstboot.squashfs"
echo "  copying base root squashfs -> mirror ..."
cp "$SRC_ROOT" "$HMNT/sfs/filesystem.squashfs"
echo "  copying z0 firstboot layer -> mirror/filesystem.z0.squashfs ..."
cp "$SRC_Z0"  "$HMNT/sfs/filesystem.z0.squashfs"
echo "  writing manifest ..."
{
    echo "# LSL squashfs layers copied to HDD for faster boot"
    echo "SourceUSB=/cdrom"
    echo "Date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for n in filesystem.squashfs filesystem.z0.squashfs; do
        sz=$(stat -c %s "$HMNT/sfs/$n")
        sh=$(sha256sum "$HMNT/sfs/$n" | awk '{print $1}')
        echo "$n=$sz sha256:$sh"
    done
} > "$HMNT/sfs/manifest.txt"
cat "$HMNT/sfs/manifest.txt"
umount "$HMNT"; losetup -d "$LOOP2"; sync

# --- boot -------------------------------------------------------------------
EXTRA="${EXTRA:-lsl_hdd_mirror_debug}"   # pass "lsl_no_hdd_mirror lsl_hdd_mirror_debug" to test fallback
accel="$(qemu_resolve_accel)" || { echo "No hardware acceleration available - refusing (pass --accel tcg to run unaccelerated)." >&2; exit 1; }
if [ "$accel" = kvm ] && [ ! -c /dev/kvm ]; then
    skip "/dev/kvm unavailable for explicit --accel kvm"
fi
[ "$accel" = tcg ] && echo "WARNING: unaccelerated TCG boot - expect hours, not minutes." >&2
echo "Booting with $accel (console) - waiting up to ~6 min for the hook message ..."
accel_argv=(); qemu_accel_argv accel_argv "$accel" || exit 1
qdisk="$(qemu_host_path "$DISK")"; qhdd="$(qemu_host_path "$HDD")"
qkern="$(qemu_host_path "$WORK/vmlinuz")"; qinitrd="$(qemu_host_path "$WORK/initrd.lz")"
timeout 600 "$QEMU_BIN" "${accel_argv[@]}" -m 4096 -smp 4 \
  -drive file="$qdisk",format=raw,if=virtio \
  -drive file="$qhdd",format=raw,if=virtio \
  -kernel "$qkern" -initrd "$qinitrd" \
  -append "boot=casper username=mint hostname=mint console=ttyS0 noprompt systemd.journald.forward_to_console=1 $EXTRA --" \
  -netdev user,id=n -device virtio-net-pci,netdev=n \
  -nographic -serial mon:stdio >"$WORK/boot.log" 2>&1 &
QEMU_PID=$!

RC=1
for ((i = 0; i < 36; i++)); do   # up to 6 min
  if grep -q "lsl-hdd-mirror: ADOPTED" "$WORK/boot.log" 2>/dev/null; then
    echo "PASS: hook ADOPTED the HDD mirror (LAYERFS_PATH set)."
    RC=0; break
  fi
  if grep -q "lsl-hdd-mirror: DISABLED" "$WORK/boot.log" 2>/dev/null; then
    if [ "$EXTRA" != "${EXTRA/lsl_no_hdd_mirror/}" ]; then
      echo "PASS: lsl_no_hdd_mirror disabled the hook (safe USB boot)."
      RC=0
    else
      echo "FAIL: hook disabled but lsl_no_hdd_mirror was not requested."
      RC=1
    fi
    break
  fi
  if grep -q "lsl-hdd-mirror: NO MIRROR FOUND" "$WORK/boot.log" 2>/dev/null; then
    if [ "$EXTRA" != "${EXTRA/lsl_no_hdd_mirror/}" ]; then
      echo "PASS: with lsl_no_hdd_mirror, hook correctly reported NO MIRROR (USB fallback)."
      RC=0
    else
      echo "FAIL: hook reported NO MIRROR with a valid mirror present."
      RC=1
    fi
    break
  fi
  if ! kill -0 $QEMU_PID 2>/dev/null; then echo "QEMU exited before the hook ran."; break; fi
  sleep 10
done
kill $QEMU_PID 2>/dev/null || true; wait $QEMU_PID 2>/dev/null || true
echo "--- last console lines ---"
tail -15 "$WORK/boot.log" 2>/dev/null
exit $RC
