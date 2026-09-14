#!/bin/bash
# QEMU/KVM boot test for the HDD-mirror auto-detect hook on antiX live-init
# (initramfs/lsl_antix_mirror.sh) - the 32-bit (i386) x86 path.
#
# antiX is a Debian-family, 32-bit live distro that ships a "live-init" fork (not
# stock live-boot). Its /init locates the root squashfs via SQFILE_FILE (default
# /antiX/linuxfs). Our hook, sourced just before find_linuxfs_file(), verifies a
# mirror laid out as "sfs/filesystem.squashfs" + "sfs/manifest.txt" (the SAME
# layout casper/live-boot use) and exports SQFILE_FILE=/sfs/filesystem.squashfs so
# antiX's own scanner adopts the internal-disk mirror.
#
# This boots under qemu-system-i386 (real 32-bit x86) to prove the 32-bit path.
#
# Requirements (clean SKIP if missing): a QEMU i386 binary (QEMU_BIN, default
# qemu-system-i386) + acceleration (--accel kvm|whpx|tcg|auto, LSL_ACCEL;
# whole script runs in WSL2 as root for WHPX, QEMU on host Windows),
# root, unmkinitramfs, cpio, mkfs.ext4, losetup, and an antiX live ISO.
set -uo pipefail

ACCEL="${LSL_ACCEL:-auto}"
QEMU_BIN="${QEMU_BIN:-qemu-system-i386}"
POS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --accel) ACCEL="${2:-}"; [ -n "$ACCEL" ] || { echo "--accel needs a value" >&2; exit 2; }; shift 2 ;;
        --help|-h) echo "Usage: $0 [--accel kvm|whpx|tcg|auto] [ISO_PATH] [EXTRA_KERNEL_ARGS] [adopt|fallback]"; exit 0 ;;
        --) shift; while [ $# -gt 0 ]; do POS+=("$1"); shift; done; break ;;
        -*) echo "Unknown option: $1" >&2; exit 2 ;;
        *) POS+=("$1"); shift ;;
    esac
done
ISO="${POS[0]:-${LSL_ISO:-/root/Downloads/antiX-26_386-full.iso}}"
LSL_ACCEL="$ACCEL"
EXTRA="${POS[1]:-lsl_hdd_mirror_debug}"
MODE="${POS[2]:-adopt}"   # "adopt" or "fallback"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO_ROOT/initramfs/lsl_antix_mirror.sh"

skip() { echo "SKIP: $1"; exit 0; }
# shellcheck disable=SC1091
. "$REPO_ROOT/tests/qemu-accel.sh"
[ -n "$ISO" ]      || skip "LSL_ISO not set (pass the antiX ISO path as \$1 or \$LSL_ISO)"
[ -f "$ISO" ]      || skip "ISO not found: $ISO"
command -v "$QEMU_BIN" >/dev/null 2>&1 || skip "$QEMU_BIN not installed"
echo "ARCH: qemu = $(command -v "$QEMU_BIN") (i386 / 32-bit x86)"
command -v unmkinitramfs >/dev/null 2>&1 || skip "unmkinitramfs not installed"
command -v cpio   >/dev/null 2>&1 || skip "cpio not installed"
command -v losetup >/dev/null 2>&1 || skip "losetup not installed"
command -v mkfs.ext4 >/dev/null 2>&1 || skip "mkfs.ext4 not installed"
[ -f "$HOOK" ]     || skip "hook missing: $HOOK"
[ "$(id -u)" -eq 0 ] || skip "must run as root (needs losetup/mount)"

WORK="/tmp/qemu-antix-test"; rm -rf "$WORK"; mkdir -p "$WORK"
ISO_MNT="$WORK/iso"; mkdir -p "$ISO_MNT"
mount -o loop,ro "$ISO" "$ISO_MNT" 2>/dev/null || skip "could not mount ISO"
# antiX puts the boot bits under /antiX
KERNEL="$ISO_MNT/antiX/vmlinuz"; INITRD="$ISO_MNT/antiX/initrd.gz"; ROOTFS="$ISO_MNT/antiX/linuxfs"
echo "ARCH: ISO boot kernel = $(file -b "$KERNEL" 2>/dev/null | cut -c1-90)"
[ -f "$KERNEL" ] && [ -f "$INITRD" ] && [ -f "$ROOTFS" ] || { umount "$ISO_MNT"; skip "ISO is not an antiX live image (no /antiX/{vmlinuz,initrd.gz,linuxfs})"; }
cp "$KERNEL" "$WORK/vmlinuz"
cp "$ROOTFS" "$WORK/base-root.squashfs"

# --- repack the initrd with the antiX hook (sed /init + drop hook at root) ---
echo "Repacking initrd from $INITRD with the antiX mirror hook ..."
IRX="$WORK/irx"; unmkinitramfs "$INITRD" "$IRX" 2>&1 | head -2 || { umount "$ISO_MNT"; skip "unmkinitramfs failed"; }
injected=0
for d in "$IRX"/*/; do
    if [ -f "${d}init" ] && grep -q 'DEFAULT_SQFILE=/antiX/linuxfs' "${d}init" 2>/dev/null; then
        cp "$HOOK" "${d}lsl_antix_mirror.sh"
        chmod +x "${d}lsl_antix_mirror.sh"
        if ! grep -q 'lsl_antix_mirror' "${d}init"; then
            sed -i 's#^[[:space:]]*find_linuxfs_file[[:space:]]*$#. /lsl_antix_mirror.sh\n        find_linuxfs_file#' "${d}init"
        fi
        injected=1
    fi
done
[ "$injected" = 1 ] || { umount "$ISO_MNT"; skip "no antiX /init (DEFAULT_SQFILE=/antiX/linuxfs) in initrd"; }
( for dd in "$IRX"/*/; do ( cd "$dd" && find . -print0 | cpio -0 -H newc -o ); done ) | gzip -9 -c > "$WORK/initrd.lz"
echo "Repacked initrd -> $WORK/initrd.lz (antiX hook injected)"

# --- build the HDD "mirror" disk (ext4; hook's native-mount fallback) -------
echo "Building HDD mirror disk ..."
HDD="$WORK/hdd.raw"
truncate -s 8G "$HDD"
LOOP="$(losetup -f --show -P "$HDD")" || { umount "$ISO_MNT"; skip "no free loop device for HDD"; }
printf 'label: dos\n,,L\n' | sfdisk "$HDD" >/dev/null
partprobe "$LOOP" 2>/dev/null; sleep 1
HP="${LOOP}p1"
mkfs.ext4 -q -F -L LSLMIRROR "$HP" >/dev/null || { losetup -d "$LOOP"; umount "$ISO_MNT"; skip "mkfs.ext4 failed"; }
HMNT="$WORK/hdd"; mkdir -p "$HMNT"; mount "$HP" "$HMNT"
mkdir -p "$HMNT/sfs"
echo "  base root squashfs (antiX linuxfs) -> mirror/sfs/filesystem.squashfs"
cp "$WORK/base-root.squashfs" "$HMNT/sfs/filesystem.squashfs"
echo "  writing manifest ..."
{
    echo "# LSL squashfs layers copied to HDD for faster boot"
    echo "SourceUSB=/cdrom"
    echo "Date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for n in "$HMNT"/sfs/*.squashfs; do
        bn="$(basename "$n")"
        sz=$(stat -c %s "$n")
        echo "$bn=$sz"
    done
} > "$HMNT/sfs/manifest.txt"
cat "$HMNT/sfs/manifest.txt"
umount "$HMNT"; losetup -d "$LOOP"; sync

# --- boot ----------------------------------------------------------------
# EXTRA/MODE already resolved from positionals above.
iso_args=()
if [ "$MODE" = "fallback" ]; then
    iso_args=(-cdrom "$(qemu_host_path "$ISO")")
    EXPECT="NO ADOPT"
else
    EXPECT="ADOPT"
fi
accel="$(qemu_resolve_accel)" || { echo "No hardware acceleration available - refusing (pass --accel tcg to run unaccelerated)." >&2; exit 1; }
if [ "$accel" = kvm ] && [ ! -c /dev/kvm ]; then
    skip "/dev/kvm unavailable for explicit --accel kvm"
fi
[ "$accel" = tcg ] && echo "WARNING: unaccelerated TCG boot - expect hours, not minutes." >&2
echo "Booting with $accel (i386, $MODE) - waiting up to ~6 min ..."
accel_argv=(); qemu_accel_argv accel_argv "$accel" || exit 1
qhdd="$(qemu_host_path "$HDD")"; qkern="$(qemu_host_path "$WORK/vmlinuz")"; qinitrd="$(qemu_host_path "$WORK/initrd.lz")"
timeout 600 "$QEMU_BIN" "${accel_argv[@]}" -m 2048 -smp 2 \
  -drive file="$qhdd",format=raw,if=ide \
  "${iso_args[@]}" \
  -kernel "$qkern" -initrd "$qinitrd" \
  -append "console=ttyS0 $EXTRA --" \
  -netdev user,id=n -device virtio-net-pci,netdev=n \
  -nographic -serial mon:stdio >"$WORK/boot.log" 2>&1 &
QP=$!

RC=1
for ((i = 0; i < 36; i++)); do   # up to 6 min
  if grep -q "lsl-antix-mirror: ADOPTED" "$WORK/boot.log" 2>/dev/null; then
    if [ "$EXPECT" = "ADOPT" ]; then echo "PASS: antiX hook ADOPTED the HDD mirror (SQFILE_FILE=/sfs/filesystem.squashfs)."; RC=0; fi
    break
  fi
  if grep -q "lsl-antix-mirror: DISABLED" "$WORK/boot.log" 2>/dev/null; then
    if [ "$EXPECT" = "NO ADOPT" ]; then echo "PASS: lsl_no_hdd_mirror disabled the hook (safe USB fallback)."; RC=0; fi
    break
  fi
  if grep -q "lsl-antix-mirror: NO MIRROR FOUND" "$WORK/boot.log" 2>/dev/null; then
    if [ "$EXPECT" = "NO ADOPT" ]; then echo "PASS: with lsl_no_hdd_mirror, hook reported NO MIRROR (USB fallback)."; RC=0; fi
    break
  fi
  if grep -qi "Could not find file\|Could not find the file" "$WORK/boot.log" 2>/dev/null; then
    echo "FAIL: antiX could not find the mirror file (SQFILE_FILE redirect failed or mirror broken)."; RC=1; break
  fi
  if ! kill -0 $QP 2>/dev/null; then echo "QEMU exited before the hook ran."; break; fi
  sleep 10
done
kill $QP 2>/dev/null || true; wait $QP 2>/dev/null || true
echo "--- last console lines ---"
tail -12 "$WORK/boot.log" 2>/dev/null
umount "$ISO_MNT" 2>/dev/null || true
exit $RC
