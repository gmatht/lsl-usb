#!/bin/bash
# QEMU/KVM boot test for the HDD-mirror auto-detect hook on Debian live-boot
# (initramfs/lsl_liveboot_mirror.sh).
#
# live-boot discovers its root layers via find_livefs(), which globs
# "${mountpoint}/${LIVE_MEDIA_PATH}/*.squashfs". Our mirror is laid out as
# "sfs/filesystem*.squashfs" + "sfs/manifest.txt" (the SAME layout the casper
# hook uses). The hook verifies a mirror and exports LIVE_MEDIA_PATH=sfs so
# live-boot's own scanner adopts the internal-disk mirror instead of the USB.
#
# This validates the live-boot code path on x86_64. The hook is POSIX-sh and
# architecture-agnostic, so the identical code runs on a 32-bit (i386) Debian
# live image; only the kernel/initrd binaries differ. (antiX uses a different
# live-init fork - see README - and needs its own layout/hook.)
#
# Requirements (clean SKIP if missing): qemu-system-x86_64, /dev/kvm, root,
# unmkinitramfs, cpio, mkfs.ext4, losetup, and a Debian live-boot ISO.
set -uo pipefail

ISO="${1:-${LSL_ISO:-/mnt/g/OtherIsos/debian-live-13.6.0-amd64-xfce.iso}}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$REPO_ROOT/dist"
HOOK="$REPO_ROOT/initramfs/lsl_liveboot_mirror.sh"

skip() { echo "SKIP: $1"; exit 0; }
[ -n "$ISO" ]      || skip "LSL_ISO not set (pass the Debian live ISO path as \$1 or \$LSL_ISO)"
[ -f "$ISO" ]      || skip "ISO not found: $ISO"
command -v qemu-system-x86_64 >/dev/null 2>&1 || skip "qemu-system-x86_64 not installed"
echo "ARCH: qemu = $(command -v qemu-system-x86_64) (x86_64)"
[ -c /dev/kvm ]    || skip "/dev/kvm unavailable (need hardware virtualization)"
command -v unmkinitramfs >/dev/null 2>&1 || skip "unmkinitramfs not installed"
command -v cpio   >/dev/null 2>&1 || skip "cpio not installed"
command -v losetup >/dev/null 2>&1 || skip "losetup not installed"
command -v mkfs.ext4 >/dev/null 2>&1 || skip "mkfs.ext4 not installed"
[ -f "$HOOK" ]     || skip "hook missing: $HOOK"
[ "$(id -u)" -eq 0 ] || skip "must run as root (needs losetup/mount)"

WORK="/tmp/qemu-liveboot-test"; rm -rf "$WORK"; mkdir -p "$WORK"
ISO_MNT="$WORK/iso"; mkdir -p "$ISO_MNT"
mount -o loop,ro "$ISO" "$ISO_MNT" 2>/dev/null || skip "could not mount ISO"
# Debian live puts the boot bits under /live
KERNEL="$ISO_MNT/live/vmlinuz"; INITRD="$ISO_MNT/live/initrd.img"; ROOTFS="$ISO_MNT/live/filesystem.squashfs"
echo "ARCH: ISO boot kernel = $(file -b "$KERNEL" 2>/dev/null | cut -c1-90)"
[ -f "$KERNEL" ] && [ -f "$INITRD" ] && [ -f "$ROOTFS" ] || { umount "$ISO_MNT"; skip "ISO is not a Debian live-boot image (no /live/{vmlinuz,initrd.img,filesystem.squashfs})"; }
cp "$KERNEL" "$WORK/vmlinuz"
cp "$ROOTFS" "$WORK/base-root.squashfs"

# --- repack the initrd with the live-boot hook ------------------------------
echo "Repacking initrd from $INITRD with the live-boot mirror hook ..."
IRX="$WORK/irx"; unmkinitramfs "$INITRD" "$IRX" || { umount "$ISO_MNT"; skip "unmkinitramfs failed"; }
injected=0
for d in "$IRX"/*/; do
    if [ -d "${d}usr/lib/live/boot" ]; then
        mkdir -p "${d}scripts/live-premount"
        cp "$HOOK" "${d}scripts/live-premount/00lsl_liveboot_mirror"
        chmod +x "${d}scripts/live-premount/00lsl_liveboot_mirror"
        # live-boot's run_scripts *sources* the ORDER file, so it MUST exist
        # (otherwise `. "${initdir}/ORDER"` fails and /init aborts under set -e).
        # Dot-source so `export LIVE_MEDIA_PATH=sfs` reaches Live()/find_livefs.
        order="${d}scripts/live-premount/ORDER"
        if [ ! -f "$order" ]; then
            printf '. /scripts/live-premount/00lsl_liveboot_mirror "$@"\n' > "$order"
        elif ! grep -q '00lsl_liveboot_mirror' "$order"; then
            printf '. /scripts/live-premount/00lsl_liveboot_mirror "$@"\n' >> "$order"
        fi
        injected=1
    fi
done
[ "$injected" = 1 ] || { umount "$ISO_MNT"; skip "no live-boot marker (usr/lib/live/boot) in initrd"; }
( for dd in "$IRX"/*/; do ( cd "$dd" && find . -print0 | cpio -0 -H newc -o ); done ) | gzip -9 -c > "$WORK/initrd.lz"
echo "Repacked initrd -> $WORK/initrd.lz (live-boot hook injected)"

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
echo "  base root squashfs -> mirror/sfs/filesystem.squashfs"
cp "$WORK/base-root.squashfs" "$HMNT/sfs/filesystem.squashfs"
if [ -f "$DIST/filesystem_z0_firstboot.squashfs" ]; then
    echo "  z0 firstboot layer -> mirror/sfs/filesystem.z0.squashfs"
    cp "$DIST/filesystem_z0_firstboot.squashfs" "$HMNT/sfs/filesystem.z0.squashfs"
fi
echo "  writing manifest ..."
{
    echo "# LSL squashfs layers copied to HDD for faster boot"
    echo "SourceUSB=/cdrom"
    echo "Date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for n in "$HMNT"/sfs/*.squashfs; do
        bn="$(basename "$n")"
        sz=$(stat -c %s "$n")
        # size-only in the test manifest (sha optional); the hook tolerates it.
        echo "$bn=$sz"
    done
} > "$HMNT/sfs/manifest.txt"
cat "$HMNT/sfs/manifest.txt"
umount "$HMNT"; losetup -d "$LOOP"; sync

# --- boot (adopt) -----------------------------------------------------------
EXTRA="${2:-lsl_hdd_mirror_debug}"
MODE="${3:-adopt}"   # "adopt" or "fallback"
if [ "$MODE" = "fallback" ]; then
    # Attach the ISO so live-boot can fall back to it (live/filesystem.squashfs).
    ISO_ARG="-cdrom $ISO"
    EXPECT="NO ADOPT"
else
    ISO_ARG=""
    EXPECT="ADOPT"
fi
echo "Booting under KVM ($MODE) - waiting up to ~6 min ..."
qemu-system-x86_64 -enable-kvm -m 4096 -smp 4 \
  -drive file="$HDD",format=raw,if=virtio \
  $ISO_ARG \
  -kernel "$WORK/vmlinuz" -initrd "$WORK/initrd.lz" \
  -append "boot=live console=ttyS0 systemd.journald.forward_to_console=1 $EXTRA --" \
  -netdev user,id=n -device virtio-net-pci,netdev=n \
  -nographic -serial mon:stdio >"$WORK/boot.log" 2>&1 &
QEMU_PID=$!

RC=1
for i in $(seq 1 36); do   # up to 6 min
  if grep -q "lsl-liveboot-mirror: ADOPTED" "$WORK/boot.log" 2>/dev/null; then
    if [ "$EXPECT" = "ADOPT" ]; then echo "PASS: live-boot hook ADOPTED the HDD mirror (LIVE_MEDIA_PATH=sfs)."; RC=0; fi
    break
  fi
  if grep -q "lsl-liveboot-mirror: DISABLED" "$WORK/boot.log" 2>/dev/null; then
    if [ "$EXPECT" = "NO ADOPT" ]; then echo "PASS: lsl_no_hdd_mirror disabled the hook (safe USB fallback)."; RC=0; fi
    break
  fi
  if grep -q "lsl-liveboot-mirror: NO MIRROR FOUND" "$WORK/boot.log" 2>/dev/null; then
    if [ "$EXPECT" = "NO ADOPT" ]; then echo "PASS: with lsl_no_hdd_mirror, hook reported NO MIRROR (USB fallback)."; RC=0; fi
    break
  fi
  if grep -q "Unable to find a medium containing a live file system" "$WORK/boot.log" 2>/dev/null; then
    echo "FAIL: live-boot PANICKED (find_livefs did not adopt the mirror)."; RC=1; break
  fi
  if ! kill -0 $QEMU_PID 2>/dev/null; then echo "QEMU exited before the hook ran."; break; fi
  sleep 10
done
kill $QEMU_PID 2>/dev/null || true; wait $QEMU_PID 2>/dev/null || true
echo "--- last console lines ---"
tail -15 "$WORK/boot.log" 2>/dev/null
umount "$ISO_MNT" 2>/dev/null || true
exit $RC
