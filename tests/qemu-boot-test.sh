#!/bin/bash
# QEMU/KVM boot smoke test for lsl-usb.
#
# Builds a bootable USB-style image from a Linux Mint 22.x ISO plus the built
# dist bundle, boots it under KVM, and asserts the first-boot service reaches
# completion (it writes /cdrom/casper/lsl-firstboot.done). This catches
# boot-time regressions (missing firstboot unit, broken layer, bad fstab) without
# physical hardware.
#
# Requirements (all optional -> clean SKIP if missing):
#   - LSL_ISO (or $1): path/URL to a Mint 22.x ISO
#   - qemu-system-x86_64 + /dev/kvm
#   - guestfish (libguestfs) to inject the bundle
#   - the bundle built by build.sh (dist/filesystem_z0_firstboot.squashfs + zip)
#
# Usage: sudo tests/qemu-boot-test.sh [ISO_PATH]
set -uo pipefail

ISO="${1:-${LSL_ISO:-}}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="$REPO_ROOT/dist"
MARKER=/cdrom/casper/lsl-firstboot.done

skip() { echo "SKIP: $1"; exit 0; }

[ -n "$ISO" ]      || skip "LSL_ISO not set (pass the ISO path as \$1 or \$LSL_ISO)"
[ -f "$ISO" ]      || skip "ISO not found: $ISO"
command -v qemu-system-x86_64 >/dev/null 2>&1 || skip "qemu-system-x86_64 not installed"
[ -c /dev/kvm ]    || skip "/dev/kvm unavailable (need hardware virtualization)"
command -v guestfish >/dev/null 2>&1 || skip "guestfish (libguestfs) not installed"
[ -f "$BUNDLE/filesystem_z0_firstboot.squashfs" ] || skip "bundle not built (run build.sh)"
[ -f "$BUNDLE/lsl-usb-win.zip" ] || skip "bundle zip not built (run build.sh)"

command -v mksquashfs >/dev/null 2>&1 || skip "mksquashfs not installed"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
DISK="$WORK/usb.qcow2"
echo "Building bootable image from $ISO ..."
qemu-img create -f qcow2 -b "$ISO" -F raw "$DISK" 8G 2>/dev/null \
  || qemu-img convert -f raw -O qcow2 "$ISO" "$DISK"

echo "Injecting bundle into the live medium (guestfish)..."
if ! guestfish --rw -a "$DISK" -m /dev/sda1 <<EOF 2>"$WORK/guestfish.log"
mkdir /cdrom 2>/dev/null || true
mkdir /cdrom/casper 2>/dev/null || true
copy-in $BUNDLE/bin /cdrom
copy-in $BUNDLE/onboot.sh /cdrom
copy-in $BUNDLE/lsl-usb.env /cdrom
copy-in $BUNDLE/systemd /cdrom
copy-in $BUNDLE/filesystem_z0_firstboot.squashfs /cdrom/casper
EOF
then
  echo "guestfish injection failed (is the ISO partition writable?); see $WORK/guestfish.log"
  skip "cannot inject bundle into this ISO image"
fi

echo "Booting under KVM (console only) - this can take several minutes..."
qemu-system-x86_64 -enable-kvm -m 4096 \
  -drive file="$DISK",format=qcow2 \
  -netdev user,id=n -device e1000,netdev=n \
  -nographic -serial mon:stdio >"$WORK/boot.log" 2>&1 &
QEMU_PID=$!
# Wait up to 20 min for the first-boot service to finish (it writes the marker
# to the disk). Poll the console log for the completion line; fall back to a
# fixed timeout.
RC=1
for i in $(seq 1 120); do
  if grep -q "lsl-firstboot setup complete" "$WORK/boot.log" 2>/dev/null; then
    RC=0; break
  fi
  if ! kill -0 $QEMU_PID 2>/dev/null; then break; fi
  sleep 10
done
kill $QEMU_PID 2>/dev/null || true
wait $QEMU_PID 2>/dev/null || true

if [ "$RC" -eq 0 ]; then
  echo "PASS: first boot completed (saw completion marker on console)."
else
  echo "FAIL: first-boot completion not observed within timeout."
  echo "---- boot.log tail ----"; tail -40 "$WORK/boot.log"
fi
exit $RC
