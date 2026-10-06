#!/bin/bash
# qemu-panic-repro.sh - deterministic reproduction of the
# "Kernel panic - not syncing: Attempted to kill init" that
# initramfs/lsl_f2fs_provision.sh caused when a disk node
# exists without partition nodes. See WHYFAIL18.md.
#
# THE BUG (lsl_f2fs_provision.sh, lsl_wait_for_boot_disk):
#   for _lsl_p in "${_lsl_d}"?* "${_lsl_d}"p?*; do
#       [ -b "$_lsl_p" ] && return 0 2>/dev/null || exit 0
#   done
# `&&`/`||` are left-associative, so this parses as
# `( [ -b "$_lsl_p" ] && return 0 ) || exit 0`. When the partition
# node is ABSENT - the normal case while a USB stick enumerates (the
# disk node appears before its partitions; measured 50ms apart under
# virtio, far wider on real USB) and the permanent case for a disk
# with no partition table - the || fires `exit 0`. The hook is
# SOURCED into casper's shell, which is PID 1, so that exit IS the
# kernel panic. The park guard cannot help: it is armed (read-layout)
# AFTER this wait function runs.
#
# THE REPRO: no ISO needed. A minimal initramfs is built from the
# Ubuntu archive (kernel, f2fs module + its dependency closure,
# busybox) plus the partitioning tools already installed in this
# rootfs. /init sources the hook the way casper's run_scripts sources
# ORDER, then parks. The victim disk is BLANK (no partition table),
# so the kernel registers /dev/vda but never creates /dev/vda1, and
# the wait loop hits the fatal line on its first poll of the disk.
# Deterministic - no race required.
#
# Usage: bash qemu-panic-repro.sh [--accel kvm|tcg|auto] [HOOK_SRC]
# The hook under test defaults to the working tree (the fixed hook:
# it waits out its 60 polls, then refuses safely and the boot
# continues - exit 0). To reproduce the panic, point HOOK_SRC at the
# pre-fix hook, e.g.:
#   git show <pre-fix-commit>:initramfs/lsl_f2fs_provision.sh >/tmp/buggy.sh
#   bash qemu-panic-repro.sh /tmp/buggy.sh            # exit 1 = panic
#
# Needs: WSL2 or Linux with qemu-system-x86_64 and /dev/kvm (falls
# back to TCG), plus curl, dpkg-deb, cpio, and the sfdisk/fatresize/
# mkfs.f2fs/modprobe toolchain. Downloads ~150 MB from
# archive.ubuntu.com once per run into /tmp/lsl-panic-qemu.
set -uo pipefail

ACCEL="${LSL_ACCEL:-auto}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SRC="$REPO_ROOT/initramfs/lsl_f2fs_provision.sh"
while [ $# -gt 0 ]; do
    case "$1" in
        --accel) ACCEL="${2:-}"; [ -n "$ACCEL" ] || { echo "--accel needs a value" >&2; exit 2; }; shift 2 ;;
        -h|--help) echo "usage: $0 [--accel kvm|tcg|auto] [HOOK_SRC]"; exit 0 ;;
        *) HOOK_SRC="$1"; shift ;;
    esac
done

W=/tmp/lsl-panic-qemu
mkdir -p "$W"
SUITE=noble

log() { echo "== $*"; }
fatal() { echo "FATAL: $*" >&2; exit 1; }

for t in curl zcat dpkg-deb cpio gzip find modinfo truncate \
         depmod modprobe qemu-system-x86_64; do
    command -v "$t" >/dev/null 2>&1 || fatal "$t missing"
done
[ -f "$HOOK_SRC" ] || fatal "hook not found: $HOOK_SRC"

# ---- 1. resolve the current noble kernel from the package index ------
log "resolving the noble kernel from archive.ubuntu.com"
for comp in main universe; do
    curl -sS -o "$W/$comp.gz" "http://archive.ubuntu.com/ubuntu/dists/$SUITE/$comp/binary-amd64/Packages.gz" \
        || fatal "could not fetch the $comp index"
done
filename_of() {  # $1 = package name -> prints pool path
    for comp in main universe; do
        [ -f "$W/$comp.gz" ] || continue
        zcat "$W/$comp.gz" | awk -v pkg="$1" '
            $0 == "Package: " pkg { inf = 1 }
            inf && /^Filename:/ { print $2; exit }
        '
    done
}
depends_of() {   # $1 = package name -> prints its Depends line
    for comp in main universe; do
        [ -f "$W/$comp.gz" ] || continue
        zcat "$W/$comp.gz" | awk -v pkg="$1" '
            $0 == "Package: " pkg { inf = 1 }
            inf && /^Depends:/ { print; exit }
        '
    done
}

IMG_VER="$(depends_of linux-image-generic | grep -o 'linux-image-6\.[0-9.]*-[0-9]*-generic' | head -1)"
[ -n "$IMG_VER" ] || fatal "could not resolve linux-image-generic's kernel version"
KVER="${IMG_VER#linux-image-}"
log "kernel: $IMG_VER"

grab() {  # $1 = package name; extracts into $W/x/$1
    local fn; fn="$(filename_of "$1")"
    [ -n "$fn" ] || { echo "  !! $1 unresolvable"; return 1; }
    curl -sS -o "$W/$1.deb" "http://archive.ubuntu.com/ubuntu/$fn" || return 1
    mkdir -p "$W/x/$1"
    dpkg-deb -x "$W/$1.deb" "$W/x/$1" || return 1
}

log "downloading kernel + modules + busybox"
grab "$IMG_VER"                    || fatal "kernel image package"
grab busybox-static                || fatal "busybox-static"
MOD_PKGS="$(depends_of "$IMG_VER" | grep -o 'linux-modules[a-z-]*-6\.[0-9.]*-[0-9]*-generic' | sort -u)"
[ -n "$MOD_PKGS" ] || fatal "no linux-modules dependency in $IMG_VER"
# f2fs/vfat live in linux-modules-extra, which is NOT in the Depends
# line - derive it from the base modules package and fetch it too.
EXTRA_PKGS="$(printf '%s\n' "$MOD_PKGS" | sed 's/^linux-modules-/linux-modules-extra-/')"
for mp in $MOD_PKGS $EXTRA_PKGS; do
    grab "$mp" || echo "  !! $mp unavailable (continuing)"
done

VMLINUZ="$(find "$W/x/$IMG_VER" -name 'vmlinuz-*' -type f | head -1)"
[ -n "$VMLINUZ" ] || fatal "no vmlinuz in $IMG_VER"
KCONFIG="$(find "$W/x/$IMG_VER" -name 'config-*' -type f | head -1)"
log "vmlinuz: $VMLINUZ"

log "kernel config (the bits this repro depends on):"
if [ -n "$KCONFIG" ]; then
    for cfg in CONFIG_DEVTMPFS_MOUNT CONFIG_VIRTIO_BLK CONFIG_SERIAL_8250_CONSOLE \
               CONFIG_F2FS_FS CONFIG_VFAT_FS; do
        echo "  $(grep -h "^$cfg=" "$KCONFIG" 2>/dev/null | head -1 || echo "$cfg not listed")"
    done
else
    echo "  (no config-* in the image package; carrying modules by name instead)"
fi

# ---- 2. assemble the initramfs ---------------------------------------
TREE="$W/tree"
rm -rf "$TREE"
mkdir -p "$TREE"/{bin,sbin,usr/bin,usr/sbin,usr/lib,lib,lib64,scripts/casper-premount,proc,sys,dev,run}

# busybox + the applet symlinks the hook and /init rely on
BB="$(find "$W/x/busybox-static" -name busybox -type f | head -1)"
[ -n "$BB" ] || fatal "no busybox binary in busybox-static"
cp "$BB" "$TREE/bin/busybox"
chmod +x "$TREE/bin/busybox"
(cd "$TREE/bin" && ln -sf busybox sh)
for app in mount cat grep sed ls sleep date mkdir dd od sync basename tr printf echo head tail mountpoint; do
    (cd "$TREE/bin" && ln -sf busybox "$app" 2>/dev/null) || true
done

# the partitioning tools, from THIS rootfs (same suite, noble)
for t in sfdisk blockdev fatresize mkfs.f2fs modprobe depmod; do
    src="$(command -v "$t")" || fatal "$t not installed in this rootfs"
    cp -L "$src" "$TREE/usr/sbin/$t"
    chmod +x "$TREE/usr/sbin/$t"
    ldd "$src" 2>/dev/null | grep -o '/[^ ]*\.so[^ ]*' | while read -r so; do
        rel="${so#/}"
        mkdir -p "$TREE/$(dirname "$rel")"
        cp -L "$so" "$TREE/$rel" 2>/dev/null || true
    done
done

# carry the kernel modules the repro needs, BY NAME, from whatever
# modules packages were fetched: virtio_blk/virtio/virtio_pci/
# vfat/fat when they are not builtin. A module that is builtin
# simply has no .ko.zst to carry.
copy_mods() {
    for name in "$@"; do
        local found=0
        for src in $(find "$W/x"/linux-modules* -name "$name.ko.zst" -type f 2>/dev/null); do
            rel="${src#*/lib/modules/$KVER/}"
            mkdir -p "$TREE/lib/modules/$KVER/$(dirname "$rel")"
            cp -L "$src" "$TREE/lib/modules/$KVER/$rel"
            echo "  carried $rel"
            found=1
        done
        [ "$found" = 0 ] && echo "  $name: not a module here (builtin, or absent)"
    done
}
# ---- the f2fs module, with its REAL dependency closure -------
# f2fs needs lz4's LZ4_compress_default/HC symbols, which
# are NOT builtin in the Ubuntu kernel - they live in a
# module. WHICH module exports them is only knowable from
# a full depmod over every module in the packages (the
# crypto/lz4 module does NOT export the raw library
# symbols - a hand-picked module list gets this wrong and
# the load dies with "unknown symbol"). So extract all
# modules, depmod them, and carry f2fs's transitive
# closure from the generated modules.dep.
FULL="$W/fulltree"
mkdir -p "$FULL"
for mp in $MOD_PKGS $EXTRA_PKGS; do
    [ -f "$W/$mp.deb" ] && dpkg-deb -x "$W/$mp.deb" "$FULL" 2>/dev/null
done
depmod -b "$FULL" "$KVER" 2>/dev/null || log "depmod over the full tree warned"
F2FS_REL="kernel/fs/f2fs/f2fs.ko.zst"
log "the real f2fs dependency line (full-tree depmod):"
grep -h "^$F2FS_REL" "$FULL/lib/modules/$KVER/modules.dep" 2>/dev/null | sed 's/^/  /'

resolve_deps() {  # $1 = module path; prints its transitive closure
    _r_seen=" "
    _r_queue="$1"
    while [ -n "$_r_queue" ]; do
        _r_cur="${_r_queue%% *}"
        _r_queue="${_r_queue#$_r_cur}"
        _r_queue="${_r_queue# }"
        case "$_r_seen" in *" $_r_cur "*) continue ;; esac
        _r_seen="$_r_seen$_r_cur "
        printf '%s\n' "$_r_cur"
        _r_deps="$(awk -v m="${_r_cur}:" 'index($0, m) == 1 {sub(/^[^:]*: */, ""); print; exit}' \
            "$FULL/lib/modules/$KVER/modules.dep" 2>/dev/null)"
        [ -n "$_r_deps" ] && _r_queue="$_r_queue $_r_deps"
    done
}
log "carrying the f2fs dependency closure:"
for _r_rel in $(resolve_deps "$F2FS_REL"); do
    _r_src="$FULL/lib/modules/$KVER/$_r_rel"
    [ -f "$_r_src" ] || continue
    mkdir -p "$TREE/lib/modules/$KVER/$(dirname "$_r_rel")"
    cp -L "$_r_src" "$TREE/lib/modules/$KVER/$_r_rel"
    echo "  carried $_r_rel"
done
[ -f "$TREE/lib/modules/$KVER/$F2FS_REL" ] \
    || fatal "f2fs.ko.zst not carried - the hook would no-op, not panic"

# carry the other modules the repro might want, by name
# (virtio/vfat are builtin in the generic kernel - nothing
# to carry - but keep the attempt so a config change shows)
copy_mods virtio_blk virtio virtio_pci vfat fat

log "depmod (initramfs tree, verbose):"
depmod -b "$TREE" "$KVER" 2>&1 | sed 's/^/  /' || log "depmod returned non-zero"

# staging diagnostics: which packages, which vermagic
log "staging diagnostics:"
for p in "$IMG_VER" $MOD_PKGS $EXTRA_PKGS; do
    [ -f "$W/$p.deb" ] && echo "  $p -> $(dpkg-deb -f "$W/$p.deb" Version 2>/dev/null)"
done
echo "  f2fs vermagic: $(modinfo -F vermagic "$TREE/lib/modules/$KVER/$F2FS_REL" 2>&1 | head -1)"

# If kmod in the tree cannot decompress the .ko.zst
# container (and the kernel declines to), the load fails
# with "invalid module format". Carry the modules
# DECOMPRESSED as plain .ko files - those load everywhere.
if command -v unzstd >/dev/null 2>&1; then
    _lsl_dec=0
    for z in $(find "$TREE/lib/modules" -name '*.ko.zst' 2>/dev/null); do
        ko="${z%.zst}"
        if unzstd -q -f -o "$ko" "$z" 2>/dev/null; then
            rm -f "$z"; _lsl_dec=$((_lsl_dec + 1))
        fi
    done
    if [ "$_lsl_dec" -gt 0 ]; then
        depmod -b "$TREE" "$KVER" 2>/dev/null || true
        log "decompressed $_lsl_dec module(s) to plain .ko"
    fi
fi
log "final modules.dep (what modprobe will read):"
sed 's/^/  /' "$TREE/lib/modules/$KVER/modules.dep" 2>&1

# the hook, exactly as the installer ships it (sourced by ORDER)
cp "$HOOK_SRC" "$TREE/scripts/casper-premount/zz_lsl_f2fs_provision"
chmod +x "$TREE/scripts/casper-premount/zz_lsl_f2fs_provision"

# /init: PID 1. Sources the hook the way casper's run_scripts sources
# ORDER, then parks. If the hook exits the shell, PID 1 is gone and
# the kernel panics - which is the repro.
cat > "$TREE/init" <<'INIT'
#!/bin/sh
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
echo "=== lsl-panic-repro /init (PID $$) ==="
echo "=== uname -r: $(uname -r) ==="
echo "=== /proc/version: $(cat /proc/version 2>/dev/null) ==="
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
echo "=== modprobe f2fs -v (diagnostic) ==="
modprobe -v f2fs 2>&1 || echo "=== modprobe rc=$? ==="
echo "=== f2fs in /proc/filesystems: [$(grep f2fs /proc/filesystems)] ==="
echo "=== sourcing zz_lsl_f2fs_provision (as casper's ORDER does) ==="
. /scripts/casper-premount/zz_lsl_f2fs_provision
echo "=== HOOK RETURNED (rc=$?) - PID 1 still alive ==="
echo "=== parking forever: this is a healthy boot ==="
while true; do sleep 3600; done
INIT
chmod +x "$TREE/init"

( cd "$TREE" && find . -print0 | cpio -0 -H newc -o 2>/dev/null | gzip -9 -c > "$W/initrd.gz" )
log "initramfs: $(du -h "$W/initrd.gz" | cut -f1)"
log "archive carries (module sanity):"
zcat "$W/initrd.gz" | cpio -t 2>/dev/null | grep -E 'f2fs|modules.dep|sbin/modprobe' | sed 's/^/  /' || log "  !! none of the expected files are in the archive"
log "chroot modprobe dry-run (resolution, no insert):"
chroot "$TREE" /usr/sbin/modprobe -n -v f2fs 2>&1 | sed 's/^/  /' || true

# ---- 3. the victim disk: BLANK, no partition table ------------------
# The kernel registers /dev/vda but never creates /dev/vda1 - the
# deterministic form of the enumeration race.
truncate -s 2G "$W/blank.img"

# ---- 4. boot ---------------------------------------------------------
qemu_accel=()
case "$ACCEL" in
    auto)
        if [ -w /dev/kvm ]; then qemu_accel=(-enable-kvm); ACCEL=kvm
        else qemu_accel=(-accel tcg); ACCEL=tcg; fi ;;
    kvm) qemu_accel=(-enable-kvm) ;;
    tcg) qemu_accel=(-accel tcg) ;;
    *) fatal "unknown accel $ACCEL" ;;
esac
[ "$ACCEL" = tcg ] && log "WARNING: unaccelerated TCG - slow boot, be patient"
log "booting with $ACCEL, asking for 2 GiB of lsl-persist on a BLANK disk"

timeout 180 qemu-system-x86_64 "${qemu_accel[@]}" -m 1024 -smp 2 \
    -drive file="$W/blank.img",format=raw,if=virtio \
    -kernel "$VMLINUZ" -initrd "$W/initrd.gz" \
    -append "console=ttyS0 lsl_f2fs_provision=2 panic=-1" \
    -nographic -no-reboot > "$W/boot.log" 2>&1 || true

log "--- boot log (the interesting lines) ---"
grep -E 'lsl-f2fs-provision|panic-repro|===|modprobe|f2fs|panic' "$W/boot.log" | sed 's/^/  /' || true
log "--- verdict ---"
if grep -q 'Attempted to kill init' "$W/boot.log"; then
    echo "REPRODUCED: PID 1 exited - the kernel panicked with 'Attempted to kill init'"
    grep -m1 -B2 -A2 'Attempted to kill init' "$W/boot.log" | sed 's/^/  /'
    echo "BOOT_LOG=$W/boot.log"
    exit 1
elif grep -q 'HOOK RETURNED' "$W/boot.log"; then
    echo "NO PANIC: the hook returned to /init and the boot continued"
    grep -E 'REFUSING|could not identify|HOOK RETURNED' "$W/boot.log" | sed 's/^/  /'
    echo "BOOT_LOG=$W/boot.log"
    exit 0
else
    echo "INCONCLUSIVE: neither the panic nor the hook's return appeared"
    tail -40 "$W/boot.log" | sed 's/^/  /'
    echo "BOOT_LOG=$W/boot.log"
    exit 2
fi
