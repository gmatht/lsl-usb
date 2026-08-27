#!/bin/bash
# QEMU/KVM boot smoke test for lsl-usb.
#
# Builds a bootable USB-style image from a Linux Mint 22.x ISO (a Rufus
# "ISO-mode" equivalent: a FAT32 volume holding the casper tree plus the lsl-usb
# bundle) together with the bundle built by build.sh, boots it under KVM, and
# asserts the first-boot service reaches completion. Completion is proven by the
# first-boot service writing /cdrom/casper/lsl-firstboot.done and appending a new
# squashfs layer to /cdrom/casper. This catches boot-time regressions (missing
# firstboot unit, broken layer, unwriteable /cdrom, bad fstab, network gating)
# without physical hardware.
#
# Why not inject into the raw ISO with guestfish (the old approach)?
#   - A raw .iso's partition is ISO9660, which is read-only, so the bundle cannot
#     be written into it.
#   - The bundle lives inside dist/lsl-usb-win.zip (it is not unpacked in dist/),
#     so copy-in of $BUNDLE/bin etc. could never succeed.
# Instead we replicate what install.ps1 + Rufus produce: a FAT32 "USB" whose
# /cdrom is writable, and we boot it directly via -kernel/-initrd (no bootloader
# install needed). The firstboot layer (filesystem_z0_firstboot.squashfs) is
# stacked over the base casper squashfs, exactly as on real media.
#
# Requirements (all optional -> clean SKIP if missing):
#   - LSL_ISO (or $1): path to a Mint 22.x ISO
#   - qemu-system-x86_64 + /dev/kvm
#   - sfdisk, mkfs.vfat (dosfstools), losetup, mksquashfs, unzip
#   - root (for losetup/mount)
#   - the bundle built by build.sh (dist/lsl-usb-win.zip + dist/filesystem_z0_firstboot.squashfs)
#
# Usage: sudo tests/qemu-boot-test.sh [ISO_PATH]
set -uo pipefail

ISO="${1:-${LSL_ISO:-}}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="$REPO_ROOT/dist"

skip() { echo "SKIP: $1"; exit 0; }

[ -n "$ISO" ]      || skip "LSL_ISO not set (pass the ISO path as \$1 or \$LSL_ISO)"
[ -f "$ISO" ]      || skip "ISO not found: $ISO"
command -v qemu-system-x86_64 >/dev/null 2>&1 || skip "qemu-system-x86_64 not installed"
[ -c /dev/kvm ]    || skip "/dev/kvm unavailable (need hardware virtualization)"
command -v sfdisk  >/dev/null 2>&1 || skip "sfdisk not installed"
command -v mkfs.vfat >/dev/null 2>&1 || skip "mkfs.vfat (dosfstools) not installed"
command -v losetup >/dev/null 2>&1 || skip "losetup not installed"
command -v mksquashfs >/dev/null 2>&1 || skip "mksquashfs not installed"
command -v unzip   >/dev/null 2>&1 || skip "unzip not installed"
[ -f "$BUNDLE/lsl-usb-win.zip" ] || skip "bundle zip not built (run build.sh)"
[ -f "$BUNDLE/filesystem_z0_firstboot.squashfs" ] || skip "firstboot layer not built (run build.sh)"
[ "$(id -u)" -eq 0 ] || skip "must run as root (needs losetup/mount)"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
DISK="$WORK/usb.img"

echo "Unpacking bundle from dist/lsl-usb-win.zip ..."
unzip -q "$BUNDLE/lsl-usb-win.zip" -d "$WORK/bundle" || skip "could not unpack bundle zip"

echo "Building bootable FAT32 image (Rufus ISO-mode equivalent) from $ISO ..."
# FAT32 (vfat) so /cdrom is writable; large enough for the base squashfs (~2.6 GiB)
# plus headroom. FAT32 caps individual files at 4 GiB; the base squashfs is under
# that, so this layout matches a real Rufus-written stick.
truncate -s 5G "$DISK"
printf 'label: dos\n,,c,*\n' | sfdisk "$DISK" >/dev/null
LOOP="$(losetup -f --show -P "$DISK")" || skip "no free loop device available"
PART="${LOOP}p1"
mkfs.vfat -F 32 -n MINT "$PART" >/dev/null || skip "mkfs.vfat failed"
MNT="$WORK/mnt"; mkdir -p "$MNT"
mount "$PART" "$MNT"
ISO_MNT="$WORK/iso"; mkdir -p "$ISO_MNT"
if ! mount -o loop,ro "$ISO" "$ISO_MNT" 2>/dev/null; then
  umount "$MNT" 2>/dev/null; losetup -d "$LOOP" 2>/dev/null
  skip "could not mount ISO (need loop/iso9660 support)"
fi
cp -r "$ISO_MNT/casper" "$MNT/casper" || { umount "$ISO_MNT" "$MNT" 2>/dev/null; losetup -d "$LOOP" 2>/dev/null; skip "copying casper tree failed"; }
cp -r "$WORK/bundle/bin" "$MNT/bin"
cp "$WORK/bundle/onboot.sh" "$MNT/onboot.sh"
cp "$WORK/bundle/lsl-usb.env" "$MNT/lsl-usb.env"
cp -r "$WORK/bundle/systemd" "$MNT/systemd"
cp "$BUNDLE/filesystem_z0_firstboot.squashfs" "$MNT/casper/filesystem_z0_firstboot.squashfs"
cp "$ISO_MNT/casper/vmlinuz" "$WORK/vmlinuz"
cp "$ISO_MNT/casper/initrd.lz" "$WORK/initrd.lz"
umount "$ISO_MNT"; umount "$MNT"; losetup -d "$LOOP"
# Force the FAT32 writes out of the page cache into usb.img before QEMU opens
# it - without this, a freshly-built disk can be read with stale/truncated
# blocks at boot (casper then fails to mount filesystem.squashfs).
sync

echo "Booting under KVM (console only) - first boot can take 30-50 min (apt + layer pack)..."
echo "  (waiting for 'First-boot setup complete' on the console, up to ~60 min)"
# virtio-net-pci is used (not e1000) because NetworkManager reaches
# network-online.target reliably with it, which lsl-firstboot.service waits on.
# forward_to_console lets us detect the completion line without mounting the live
# disk (mounting a disk another OS is writing would risk corruption).
qemu-system-x86_64 -enable-kvm -m 8192 -smp 4 \
  -drive file="$DISK",format=raw \
  -kernel "$WORK/vmlinuz" -initrd "$WORK/initrd.lz" \
  -append "boot=casper username=mint hostname=mint console=ttyS0 noprompt systemd.journald.forward_to_console=1 --" \
  -netdev user,id=n -device virtio-net-pci,netdev=n \
  -nographic -serial mon:stdio >"$WORK/boot.log" 2>&1 &
QEMU_PID=$!

RC=1
for i in $(seq 1 360); do   # up to 60 min
  if grep -q "First-boot setup complete" "$WORK/boot.log" 2>/dev/null; then
    echo "Saw first-boot completion on console."; break
  fi
  if ! kill -0 $QEMU_PID 2>/dev/null; then echo "QEMU exited."; break; fi
  sleep 10
done
kill $QEMU_PID 2>/dev/null || true
wait $QEMU_PID 2>/dev/null || true

echo "Inspecting disk for first-boot completion artifacts..."
LOOP="$(losetup -f --show -P "$DISK")" || { echo "FAIL: cannot re-open disk to inspect"; exit 1; }
PART="${LOOP}p1"
MNT="$WORK/chk"; mkdir -p "$MNT"
if ! mount "$PART" "$MNT" 2>/dev/null; then
  losetup -d "$LOOP" 2>/dev/null
  echo "FAIL: cannot mount disk to inspect for completion marker."
  exit 1
fi
if [ -f "$MNT/casper/lsl-firstboot.done" ]; then
  echo "PASS: /cdrom/casper/lsl-firstboot.done present (first boot completed)."
  RC=0
else
  echo "FAIL: /cdrom/casper/lsl-firstboot.done not found after boot window."
fi
# Report any appended layer (filesystem_z.<ts>.squashfs) as extra evidence.
appended="$(ls "$MNT/casper"/filesystem_z.*.squashfs 2>/dev/null | grep -v filesystem_z0_firstboot || true)"
if [ -n "$appended" ]; then
  echo "Appended layer(s) written by uproot:"
  for f in $appended; do echo "  - $(basename "$f") ($(du -h "$f" | cut -f1))"; done
fi
umount "$MNT"; losetup -d "$LOOP"
exit $RC
