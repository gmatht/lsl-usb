#!/bin/bash
# QEMU/KVM boot test for the F2FS partition-CREATION hook
# (initramfs/lsl_f2fs_provision.sh, P1b of DESIGN-F2FS-PERSISTENCE.md).
#
# WHY THIS TEST EXISTS
# --------------------
# The loopback test (tests/f2fs-provision-hook.tests.sh) proves the hook's
# GEOMETRY: it carves a real disk, shrinks the FAT, writes a second partition,
# formats it f2fs, mounts it, and is idempotent. It proves nothing about WHERE
# the hook runs. The open question the design names as the last unmeasured
# assumption is the TIMING:
#
#   At casper:926 (run_scripts /scripts/casper-premount), is the boot medium
#   still UNMOUNTED and unheld - so the hook may repartition it?
#
# This boots a real casper initramfs under KVM with the hook injected and reads
# the answer off the serial console. Four outcomes are asserted, and each is a
# real result rather than a guess:
#
#   PROVISIONED  the hook carved the stick -> the premise holds, f2fs works
#   REFUSED-*    the hook declined and said why -> also a pass, because the
#                contract is "never corrupt the stick, never break the boot".
#                The reason string tells us WHICH gate fired, which is the
#                information this test exists to produce.
#   NO FLAG      the cmdline flag never reached the hook -> harness bug
#   NO BOOT      casper died -> the hook broke the boot (a genuine failure)
#
# Requirements (clean SKIP if missing):
#   - LSL_ISO (or $1): path to a Mint 22.x ISO
#   - qemu-system-x86_64 + acceleration (see tests/qemu-accel.sh)
#   - sfdisk, mkfs.vfat, losetup, mksquashfs, unmkinitramfs, cpio, mkfs.f2fs,
#     fatresize (f2fs-tools), root
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
# The hook is silent unless asked; the flag below is what makes it act.
EXTRA="${POS[1]:-lsl_f2fs_provision_debug}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO_ROOT/initramfs/lsl_f2fs_provision.sh"
TOOLS="$REPO_ROOT/initramfs/lsl-f2fs-tools.sh"
SCRUB="$REPO_ROOT/initramfs/lsl_f2fs_scrub.sh"
ASSETS="$REPO_ROOT/rust9x/lslsetup/assets"

skip() { echo "SKIP: $1"; exit 0; }
# shellcheck disable=SC1091
. "$REPO_ROOT/tests/qemu-accel.sh"

[ -n "$ISO" ] || skip "LSL_ISO not set (pass the ISO path as \$1 or \$LSL_ISO)"
[ -f "$ISO" ] || skip "ISO not found: $ISO"
command -v "$QEMU_BIN" >/dev/null 2>&1 || skip "$QEMU_BIN not installed"
for t in sfdisk mkfs.vfat losetup mksquashfs unsquashfs unmkinitramfs cpio; do
    command -v "$t" >/dev/null 2>&1 || skip "$t not installed"
done
[ -f "$HOOK" ] || skip "hook missing: $HOOK"
[ "$(id -u)" -eq 0 ] || skip "must run as root (needs losetup/mount)"
# The tools the hook shells out to. Without them the hook refuses by design,
# which would make this test pass for the wrong reason.
command -v sfdisk     >/dev/null 2>&1 || skip "sfdisk not installed (hook would refuse)"
command -v mkfs.f2fs  >/dev/null 2>&1 || skip "mkfs.f2fs not installed (hook would refuse)"
command -v fatresize  >/dev/null 2>&1 || skip "fatresize not installed (hook would refuse)"
if ! grep -qw f2fs /proc/filesystems 2>/dev/null; then
    modprobe f2fs 2>/dev/null || true
    grep -qw f2fs /proc/filesystems 2>/dev/null || skip "kernel has no f2fs driver"
fi

WORK="${LSL_WORK_DIR:-/tmp/qemu-f2fs-test}"
# Keep the serial log somewhere that survives a WSL session teardown when the
# caller has to poll from another shell - otherwise every check after the run
# finds an empty /tmp and the evidence is simply gone.
BOOT_LOG="${LSL_BOOT_LOG:-$WORK/boot.log}"
rm -rf "$WORK"; mkdir -p "$WORK"

# --- locate a base initrd to repack -----------------------------------------
BASE_INITRD="${LSL_BASE_INITRD:-}"
if [ -z "$BASE_INITRD" ]; then
    # Take it straight out of the ISO rather than requiring a mounted stick.
    # The member is `casper/initrd.lz` at the ISO root - no `*/` prefix - so a
    # wildcard like `*/casper/initrd.lz` matches nothing and 7z reports
    # "Files: 0" while still exiting 0, which reads as a silent success.
    ISOPROBE="$WORK/isoprobe"; mkdir -p "$ISOPROBE"
    if 7z e -y -o"$ISOPROBE" "$ISO" "casper/initrd.lz" >/dev/null 2>&1; then
        BASE_INITRD="$(find "$ISOPROBE" -name 'initrd.lz' -type f | head -1)"
    fi
    if [ -z "$BASE_INITRD" ] && command -v xorriso >/dev/null 2>&1; then
        xorriso -osirrox on -indev "$ISO" -extract /casper/initrd.lz "$WORK/initrd.lz" >/dev/null 2>&1 \
            && [ -s "$WORK/initrd.lz" ] && BASE_INITRD="$WORK/initrd.lz"
    fi
fi
[ -n "$BASE_INITRD" ] && [ -f "$BASE_INITRD" ] || skip "no base initrd found (set LSL_BASE_INITRD)"

# --- fetch the F2FS tools -----------------------------------------------------
# casper's initrd carries none of fatresize/mkfs.f2fs (measured: they are in
# neither the Mint ISO's rootfs nor its package manifest), so the hook skips
# without them. The installer sources them from the Ubuntu archive - this harness
# reproduces that so the QEMU run has something to use.
#
# They go into the initrd as ordinary files at their loader paths, NOT as a
# tarball: casper's initrd has gzip and cpio but no tar, and its busybox has no
# untar applet, so a run that shipped a tarball logged "tar: not found".
echo "Fetching the F2FS tools from the Ubuntu noble archive ..."
STAGE="$WORK/stage"; rm -rf "$STAGE"; mkdir -p "$STAGE/usr/sbin" "$STAGE/lib"
SUITE=noble
for comp in main universe; do
    curl -sS -o "$WORK/$comp.gz" "http://archive.ubuntu.com/ubuntu/dists/$SUITE/$comp/binary-amd64/Packages.gz" \
        || echo "  could not fetch the $comp index"
done
poolpath() {
    for c in main universe; do
        [ -f "$WORK/$c.gz" ] || continue
        fn=$(zcat "$WORK/$c.gz" 2>/dev/null | awk -v pk="$1" '$0=="Package: " pk {f=1} f && /^Filename:/ {print $2; exit}')
        [ -n "$fn" ] && { printf '%s' "$fn"; return 0; }
    done
    return 1
}
grab() {
    fn=$(poolpath "$1") || { echo "  !! $1 unresolvable"; return 1; }
    curl -sS -o "$WORK/$1.deb" "http://archive.ubuntu.com/ubuntu/$fn" || return 1
    rm -rf "$WORK/x"; mkdir -p "$WORK/x"
    dpkg-deb -x "$WORK/$1.deb" "$WORK/x" || return 1
}
# One deb per tool. The soname is a symlink in the deb, so `cp -L`
# dereferences it - the same resolution pick_by_soname does in f2fstools.rs.
grab f2fs-tools || true
src=$(find "$WORK/x" -type f -name mkfs.f2fs 2>/dev/null | head -1)
[ -n "$src" ] && cp -L "$src" "$STAGE/usr/sbin/mkfs.f2fs" && echo "  staged mkfs.f2fs"
grab fatresize || true
src=$(find "$WORK/x" -type f -name fatresize 2>/dev/null | head -1)
[ -n "$src" ] && cp -L "$src" "$STAGE/usr/sbin/fatresize" && echo "  staged fatresize"
# coreutils: only `od`, which the initrd has NEITHER as a binary NOR as a busybox
# applet. Without it the hook cannot read the FAT BPB, so its corruption guard
# never runs and every run stops at "could not read the FAT BPB".
grab coreutils || true
src=$(find "$WORK/x" -type f -name od -perm -u+x 2>/dev/null | head -1)
if [ -n "$src" ]; then
    mkdir -p "$STAGE/usr/bin"; cp -L "$src" "$STAGE/usr/bin/od"; echo "  staged od (coreutils)"
else
    echo "  !! od NOT found in coreutils - the BPB guard cannot run"
fi
# The closure casper's initrd lacks (ldd on the noble fatresize: 12 sonames, of
# which the initrd has libc/libm/libselinux/libdevmapper/ld-linux).
for pair in libparted.so.2:libparted2t64 libparted-fs-resize.so.0:libparted-fs-resize0t64 \
            libblkid.so.1:libblkid1 libcap.so.2:libcap2 libpcre2-8.so.0:libpcre2-8-0 libuuid.so.1:libuuid1; do
    so="${pair%%:*}"; pkg="${pair##*:}"
    grab "$pkg" || continue
    real=$(find "$WORK/x" -type f -name "$so.*" 2>/dev/null | sort | tail -1)
    [ -z "$real" ] && real=$(find "$WORK/x" -type f -name "$so" 2>/dev/null | head -1)
    [ -n "$real" ] && cp -L "$real" "$STAGE/lib/$so" && echo "  staged $so"
done

# --- repack the initrd with BOTH f2fs hooks + the tools ----------------------
echo "Repacking initrd from $BASE_INITRD with the F2FS hooks ..."
IRX="$WORK/irx"; unmkinitramfs "$BASE_INITRD" "$IRX" || skip "unmkinitramfs failed"
injected=0
for d in "$IRX"/*/; do
    [ -d "${d}scripts/casper-premount" ] || continue
    cp "$HOOK"  "${d}scripts/casper-premount/zz_lsl_f2fs_provision"
    chmod +x "${d}scripts/casper-premount/zz_lsl_f2fs_provision"
    cp "$SCRUB" "${d}scripts/casper-premount/zz_lsl_f2fs_scrub"
    chmod +x "${d}scripts/casper-premount/zz_lsl_f2fs_scrub"
    mkdir -p "${d}bin"; cp "$TOOLS" "${d}bin/lsl-f2fs-tools.sh"; chmod +x "${d}bin/lsl-f2fs-tools.sh"
    # The tools go in as ordinary files at their LOADER paths, exactly as
    # lslfiles.rs stage_f2fs_initrd_members does. Not a tarball: casper's initrd
    # has no tar and its busybox has no untar applet, so a QEMU boot that shipped
    # one logged "tar: not found" and skipped the whole feature.
    if [ -d "$STAGE" ]; then
        mkdir -p "${d}usr/sbin" "${d}usr/bin" "${d}usr/lib/x86_64-linux-gnu"
        for t in mkfs.f2fs fatresize; do
            [ -f "$STAGE/usr/sbin/$t" ] && cp -L "$STAGE/usr/sbin/$t" "${d}usr/sbin/$t" && chmod +x "${d}usr/sbin/$t"
        done
        # od lives in usr/bin so the hook's PATH finds it.
        [ -f "$STAGE/usr/bin/od" ] && cp -L "$STAGE/usr/bin/od" "${d}usr/bin/od" && chmod +x "${d}usr/bin/od"
        for so in libparted.so.2 libparted-fs-resize.so.0 libblkid.so.1 libcap.so.2 libpcre2-8.so.0 libuuid.so.1; do
            if [ -f "$STAGE/lib/$so" ]; then
                # Both the generic and multiarch dirs: the loader searches both.
                cp -L "$STAGE/lib/$so" "${d}usr/lib/$so"
                cp -L "$STAGE/lib/$so" "${d}usr/lib/x86_64-linux-gnu/$so"
            fi
        done
        echo "  tools placed at usr/sbin + usr/bin + usr/lib in the initrd"
    fi

    order="${d}scripts/casper-premount/ORDER"
    # Same shape as lslfiles.rs CASPER_PREMOUNT_ORDER: re-run casper's own
    # scripts, skip ours in the loop, then source provision BEFORE scrub.
    if [ -f "$order" ]; then
        {
            echo 'for f in /scripts/casper-premount/*; do'
            echo 'case "$f" in'
            echo '*/ORDER|*/zz_lsl_f2fs_provision|*/zz_lsl_f2fs_scrub) continue ;;'
            echo 'esac'
            echo '[ -x "$f" ] && "$f" "$@" 2>/dev/null || true'
            echo 'done'
            echo '. /scripts/casper-premount/zz_lsl_f2fs_provision "$@" 2>/dev/null || true'
            echo '. /scripts/casper-premount/zz_lsl_f2fs_scrub "$@" 2>/dev/null || true'
        } > "$order"
    else
        {
            echo '. /scripts/casper-premount/zz_lsl_f2fs_provision "$@" 2>/dev/null || true'
            echo '. /scripts/casper-premount/zz_lsl_f2fs_scrub "$@" 2>/dev/null || true'
        } > "$order"
    fi
    injected=1
done
[ "$injected" = 1 ] || skip "no casper-premount dir in initrd"
( for dd in "$IRX"/*/; do ( cd "$dd" && find . -print0 | cpio -0 -H newc -o ); done ) | gzip -9 -c > "$WORK/initrd.lz"
echo "Repacked initrd -> $WORK/initrd.lz (hooks injected)"

# --- build the FAT32 "USB" image from the ISO --------------------------------
echo "Building FAT32 USB image from $ISO ..."
DISK="$WORK/usb.img"
# One partition filling the WHOLE disk: exactly the state a nofmt stick is in
# before first boot, i.e. the case where the hook must find free space INSIDE
# the FAT filesystem and shrink it.
truncate -s 6G "$DISK"
printf 'label: dos\n,,c,*\n' | sfdisk "$DISK" >/dev/null
LOOP="$(losetup -f --show -P "$DISK")" || skip "no free loop device"
PART="${LOOP}p1"
mkfs.vfat -F 32 -n MINT "$PART" >/dev/null || skip "mkfs.vfat failed"
MNT="$WORK/mnt"; mkdir -p "$MNT"; mount "$PART" "$MNT"
ISO_MNT="$WORK/iso"; mkdir -p "$ISO_MNT"
mount -o loop,ro "$ISO" "$ISO_MNT" 2>/dev/null || { umount "$MNT"; losetup -d "$LOOP"; skip "could not mount ISO"; }
cp -r "$ISO_MNT/casper" "$MNT/casper" || { umount "$ISO_MNT" "$MNT"; losetup -d "$LOOP"; skip "copying casper failed"; }
cp "$ISO_MNT/casper/vmlinuz" "$WORK/vmlinuz"
# The hook identifies the boot medium BY CONTENT, probing for these markers.
echo "image built for content-probe: casper/filesystem.squashfs"
umount "$ISO_MNT"; umount "$MNT"; losetup -d "$LOOP"; sync

# --- boot --------------------------------------------------------------------
# The size is what the installer would have put on the cmdline. 2 GiB leaves
# ~3.9 GiB of FAT, comfortably over the hook's own FAT_MIN_MIB floor.
WANT_GIB="${WANT_GIB:-2}"
accel="$(qemu_resolve_accel)" || { echo "No hardware acceleration available - refusing (pass --accel tcg)." >&2; exit 1; }
[ "$accel" = tcg ] && echo "WARNING: unaccelerated TCG boot - expect hours, not minutes." >&2
echo "Booting with $accel (console), asking for ${WANT_GIB} GiB ..."
accel_argv=(); qemu_accel_argv accel_argv "$accel" || exit 1
qdisk="$(qemu_host_path "$DISK")"; qkern="$(qemu_host_path "$WORK/vmlinuz")"; qinitrd="$(qemu_host_path "$WORK/initrd.lz")"
timeout 900 "$QEMU_BIN" "${accel_argv[@]}" -m 4096 -smp 4 \
  -drive file="$qdisk",format=raw,if=virtio \
  -kernel "$qkern" -initrd "$qinitrd" \
  -append "boot=casper username=mint hostname=mint console=ttyS0 noprompt systemd.journald.forward_to_console=1 lsl_f2fs_provision=${WANT_GIB} $EXTRA --" \
  -netdev user,id=n -device virtio-net-pci,netdev=n \
  -nographic -serial mon:stdio >"$BOOT_LOG" 2>&1 &
QEMU_PID=$!

RC=1
for ((i = 0; i < 60; i++)); do   # up to ~10 min
  if grep -q "lsl-f2fs-provision: done:" "$BOOT_LOG" 2>/dev/null; then
    echo "PASS: the hook PROVISIONED the stick inside casper:"
    grep "lsl-f2fs-provision:" "$BOOT_LOG" | sed 's/^/  /'
    RC=0; break
  fi
  if grep -q "lsl-f2fs-provision: REFUSING:" "$BOOT_LOG" 2>/dev/null; then
    # A refusal is the SAFE outcome and still answers the question - the
    # reason tells us which gate fired.
    echo "PASS (safe): the hook REFUSED rather than touching a busy/held medium."
    grep "lsl-f2fs-provision: REFUSING:" "$BOOT_LOG" | sed 's/^/  /'
    RC=0; break
  fi
  if grep -q "lsl-f2fs-provision: asked for" "$BOOT_LOG" 2>/dev/null; then
    # The flag arrived; keep waiting for the outcome.
    :
  fi
  if grep -q "lsl-f2fs-provision: boot medium:" "$BOOT_LOG" 2>/dev/null; then
    echo "  (hook reached the geometry stage; still waiting)"
  fi
  if ! kill -0 $QEMU_PID 2>/dev/null; then
    echo "QEMU exited before the hook finished. Tail:"; tail -25 "$BOOT_LOG" | sed 's/^/  /'
    break
  fi
  sleep 10
done

echo
echo "--- hook output ---"
grep -E "lsl-f2fs-(provision|tools):" "$BOOT_LOG" | sed 's/^/  /' || echo "  (none)"
echo
echo "--- did casper survive? ---"
if grep -qE "Begin live-media|Starting casper|Live medium|Casper" "$BOOT_LOG" 2>/dev/null; then
    echo "  yes: casper proceeded past the hook"
else
    echo "  unknown (log may have been cut short); full log at $WORK/boot.log"
fi

# Stop QEMU if still running.
kill $QEMU_PID 2>/dev/null; wait $QEMU_PID 2>/dev/null
echo
echo "RC=$RC  (log: $WORK/boot.log)"
exit "$RC"