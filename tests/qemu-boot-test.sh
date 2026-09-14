#!/bin/bash
# QEMU boot smoke test for lsl-usb (KVM *or* WHPX).
#
# Builds a bootable USB-style image from a Linux Mint 22.x ISO (a Rufus
# "ISO-mode" equivalent: a FAT32 volume holding the casper tree plus the lsl-usb
# bundle) together with the bundle built by build.sh, boots it with hardware
# acceleration, and asserts the first-boot service reaches completion.
# Completion is proven by the first-boot service writing
# /cdrom/casper/lsl-firstboot.done and appending a new squashfs layer to
# /cdrom/casper. This catches boot-time regressions (missing firstboot unit,
# broken layer, unwriteable /cdrom, bad fstab, network gating) without
# physical hardware.
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
# Hypervisor: KVM on Linux, WHPX on Windows - the acceleration itself is
# interchangeable (both near-native; unaccelerated TCG turns the 30-50 min
# first boot into many hours, so auto mode refuses to run without accel).
# Only the *assembly* (partitioning, loop mounts, vfat) and the *inspect*
# (loop-mount re-check) need Linux: split the run with --phase so Windows
# hosts assemble in WSL2 (as root) and boot with Windows QEMU:
#   WSL2:      sudo ./tests/qemu-boot-test.sh --phase assemble --out /mnt/c/lsl-qemu /path/to.iso
#   Windows:   bash tests/qemu-boot-test.sh --phase boot --accel whpx --out C:\lsl-qemu
#              (same for inspect, where loop mounts exist; otherwise 7z is tried)
#
# Requirements (all optional -> clean SKIP if missing):
#   - LSL_ISO (or $1): path to a Mint 22.x ISO
#   - assemble: qemu not needed; sfdisk, mkfs.vfat (dosfstools), losetup,
#     mksquashfs, unzip + root (for losetup/mount) + the bundle built by
#     build.sh (dist/lsl-usb-win.zip + dist/filesystem_z0_firstboot.squashfs)
#   - boot: a qemu-system-x86_64(-ish) binary (QEMU_BIN override); kvm needs
#     /dev/kvm, whpx needs Windows QEMU + the Hypervisor Platform feature
#   - inspect: loop mounts (Linux) or 7z (FAT listing fallback)
#
# Usage: sudo tests/qemu-boot-test.sh [--accel kvm|whpx|tcg|auto] [--phase assemble|boot|inspect|all] [--out DIR] [ISO_PATH]
# Env:   LSL_ISO, LSL_ACCEL, LSL_PHASE, LSL_OUTDIR, QEMU_BIN.
set -uo pipefail

ACCEL="${LSL_ACCEL:-auto}"
PHASE="${LSL_PHASE:-all}"
OUTDIR="${LSL_OUTDIR:-}"
ISO="${LSL_ISO:-}"
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
while [ $# -gt 0 ]; do
    case "$1" in
        --accel) ACCEL="${2:-auto}"; shift 2 ;;
        --phase) PHASE="${2:-all}"; shift 2 ;;
        --out) OUTDIR="${2:-}"; shift 2 ;;
        --help|-h) sed -n '1,40p' "$0"; exit 0 ;;
        --) shift; break ;;
        -*) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
        *) ISO="$1"; shift ;;
    esac
done
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="$REPO_ROOT/dist"

skip() { echo "SKIP: $1"; exit 0; }

case "$PHASE" in
    assemble|boot|inspect|all) ;;
    *) echo "Unknown --phase: $PHASE (assemble|boot|inspect|all)" >&2; exit 2 ;;
esac
case "$ACCEL" in
    auto|kvm|whpx|tcg) ;;
    *) echo "Unknown --accel: $ACCEL (auto|kvm|whpx|tcg)" >&2; exit 2 ;;
esac

# --- accelerator -----------------------------------------------------------
# Shared selection/translation (tests/qemu-accel.sh): auto takes /dev/kvm,
# else whpx when the qemu binary offers it, else refuses unless tcg is
# explicit (TCG turns the 30-50 min first boot into many hours).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qemu-accel.sh"
# This script's --accel flag feeds the lib via LSL_ACCEL.
LSL_ACCEL="$ACCEL"

# --- assemble: build the FAT32 USB image + extract kernel/initrd ------------
phase_assemble() {
    [ -n "$ISO" ]      || skip "LSL_ISO not set (pass the ISO path as \$1 or \$LSL_ISO)"
    [ -f "$ISO" ]      || skip "ISO not found: $ISO"
    command -v sfdisk  >/dev/null 2>&1 || skip "sfdisk not installed"
    command -v mkfs.vfat >/dev/null 2>&1 || skip "mkfs.vfat (dosfstools) not installed"
    command -v losetup >/dev/null 2>&1 || skip "losetup not installed"
    command -v mksquashfs >/dev/null 2>&1 || skip "mksquashfs not installed"
    command -v unzip   >/dev/null 2>&1 || skip "unzip not installed"
    [ -f "$BUNDLE/lsl-usb-win.zip" ] || skip "bundle zip not built (run build.sh)"
    [ -f "$BUNDLE/filesystem_z0_firstboot.squashfs" ] || skip "firstboot layer not built (run build.sh)"
    [ "$(id -u)" -eq 0 ] || skip "assemble must run as root (needs losetup/mount)"

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
    printf 'DISK=%s\nKERNEL=%s\nINITRD=%s\n' "$WORK/usb.img" "$WORK/vmlinuz" "$WORK/initrd.lz" > "$WORK/manifest.env"
    echo "Assembled: $WORK/usb.img (+ vmlinuz, initrd.lz, manifest.env)"
}

# --- boot: run the VM with the resolved accelerator -------------------------
phase_boot() {
    command -v "$QEMU_BIN" >/dev/null 2>&1 || skip "$QEMU_BIN not installed"
    [ -f "$DISK" ]   || { echo "disk image not found: $DISK (run --phase assemble, or set USB_IMG)" >&2; exit 1; }
    [ -f "$KERNEL" ] || { echo "kernel not found: $KERNEL (run --phase assemble)" >&2; exit 1; }
    [ -f "$INITRD" ] || { echo "initrd not found: $INITRD (run --phase assemble)" >&2; exit 1; }
    local accel
    accel="$(qemu_resolve_accel)" || {
        echo "No hardware acceleration available (/dev/kvm missing, no whpx in \`$QEMU_BIN -accel help\`)." >&2
        echo "TCG would turn this 30-50 min boot into many hours - refusing. Pass --accel tcg to run unaccelerated anyway." >&2
        exit 1
    }
    if [ "$accel" = "tcg" ]; then
        echo "WARNING: unaccelerated TCG boot - expect many hours, not minutes." >&2
    fi
    echo "Booting with $accel (console only) - first boot can take 30-50 min (apt + layer pack)..."
    echo "  (waiting for 'First-boot setup complete' on the console, up to ~60 min)"
    # virtio-net-pci is used (not e1000) because NetworkManager reaches
    # network-online.target reliably with it, which lsl-firstboot.service waits on.
    # forward_to_console lets us detect the completion line without mounting the live
    # disk (mounting a disk another OS is writing would risk corruption).
    # timeout (not bare &) fronts QEMU so the run always ends: it forwards
    # TERM to QEMU, which matters for .exe children whose PIDs kill -0
    # cannot reliably track.
    local qdisk qkern qinitrd
    qdisk="$(qemu_host_path "$DISK")"; qkern="$(qemu_host_path "$KERNEL")"; qinitrd="$(qemu_host_path "$INITRD")"
    local -a accel_args=()
    qemu_accel_argv accel_args "$accel" || exit 1
    timeout 3600 "$QEMU_BIN" "${accel_args[@]}" -m 8192 -smp 4 \
      -drive file="$qdisk",format=raw \
      -kernel "$qkern" -initrd "$qinitrd" \
      -append "boot=casper username=mint hostname=mint console=ttyS0 noprompt systemd.journald.forward_to_console=1 --" \
      -netdev user,id=n -device virtio-net-pci,netdev=n \
      -nographic -serial mon:stdio >"$WORK/boot.log" 2>&1 &
    QEMU_PID=$!

    for ((i = 0; i < 360; i++)); do   # up to 60 min
      if grep -q "First-boot setup complete" "$WORK/boot.log" 2>/dev/null; then
        echo "Saw first-boot completion on console."; break
      fi
      if ! kill -0 $QEMU_PID 2>/dev/null; then echo "QEMU exited."; break; fi
      sleep 10
    done
    kill $QEMU_PID 2>/dev/null || true
    wait $QEMU_PID 2>/dev/null || true
}

# --- inspect: re-open the image, check the completion marker ----------------
phase_inspect() {
    [ -f "$DISK" ] || { echo "disk image not found: $DISK (run --phase assemble)" >&2; exit 1; }
    RC=1
    echo "Inspecting disk for first-boot completion artifacts..."
    if command -v losetup >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
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
        # Glob loop, not ls|grep (SC2010: breaks on odd filenames).
        first=1
        for f in "$MNT/casper"/filesystem_z.*.squashfs; do
            [ -e "$f" ] || continue
            case "$(basename "$f")" in filesystem_z0_firstboot*) continue ;; esac
            if [ "$first" -eq 1 ]; then
                echo "Appended layer(s) written by uproot:"
                first=0
            fi
            echo "  - $(basename "$f") ($(du -h "$f" | cut -f1))"
        done
        umount "$MNT"; losetup -d "$LOOP"
    elif command -v 7z >/dev/null 2>&1; then
        # Best-effort FAT fallback (no loop mounts, e.g. plain Windows):
        # 7-Zip reads MBR + FAT, partitions appear as numbered entries.
        if 7z l "$DISK" 2>/dev/null | grep -q "casper.lsl-firstboot.done\|lsl-firstboot.done"; then
          echo "PASS: /cdrom/casper/lsl-firstboot.done present (first boot completed)."
          RC=0
        else
          echo "FAIL: /cdrom/casper/lsl-firstboot.done not found after boot window (7z listing)."
        fi
    else
        echo "SKIP: inspect needs loop mounts (root) or 7z - neither available."
        exit 0
    fi
    exit $RC
}

# --- driver ------------------------------------------------------------------
if [ -z "$OUTDIR" ]; then
    WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
else
    WORK="$OUTDIR"; mkdir -p "$WORK"
fi
# Split phases share artifacts via OUTDIR (or explicit env overrides).
if [ -f "$WORK/manifest.env" ] && [ -z "${USB_IMG:-}" ]; then
    # shellcheck disable=SC1091
    . "$WORK/manifest.env"
fi
DISK="${USB_IMG:-$WORK/usb.img}"
KERNEL="${USB_KERNEL:-$WORK/vmlinuz}"
INITRD="${USB_INITRD:-$WORK/initrd.lz}"

case "$PHASE" in
    assemble) phase_assemble ;;
    boot) phase_boot ;;
    inspect) phase_inspect ;;
    all) phase_assemble; phase_boot; phase_inspect ;;
esac
