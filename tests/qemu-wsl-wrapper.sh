#!/bin/bash
# Wrapper for qemu-panic-repro.sh that converts WSL paths to Windows
# UNC paths for the Windows QEMU installation.
#
# Usage: bash qemu-wsl-wrapper.sh [--accel tcg] [HOOK_SRC]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK_SRC="$REPO_ROOT/initramfs/lsl_f2fs_provision.sh"
ACCEL="tcg"  # WSL has no /dev/kvm, use TCG

while [ $# -gt 0 ]; do
    case "$1" in
        --accel) ACCEL="${2:-tcg}"; shift 2 ;;
        -h|--help) echo "usage: $0 [--accel tcg] [HOOK_SRC]"; exit 0 ;;
        *) HOOK_SRC="$1"; shift ;;
    esac
done

[ -f "$HOOK_SRC" ] || { echo "FATAL: hook not found: $HOOK_SRC" >&2; exit 1; }

W=/tmp/lsl-panic-qemu
mkdir -p "$W"

log() { echo "== $*"; }
fatal() { echo "FATAL: $*" >&2; exit 1; }

# Check tools (same as original script, minus qemu which is Windows)
for t in curl zcat dpkg-deb cpio gzip find modinfo truncate depmod modprobe; do
    command -v "$t" >/dev/null 2>&1 || fatal "$t missing"
done
command -v qemu-system-x86_64 >/dev/null 2>&1 || fatal "qemu-system-x86_64 missing"

# ---- 1. resolve the current noble kernel from the package index ------
SUITE=noble
log "resolving the noble kernel from archive.ubuntu.com"
for comp in main universe; do
    curl -sS -o "$W/$comp.gz" "http://archive.ubuntu.com/ubuntu/dists/$SUITE/$comp/binary-amd64/Packages.gz" \
        || fatal "could not fetch the $comp index"
done
filename_of() {
    for comp in main universe; do
        [ -f "$W/$comp.gz" ] || continue
        zcat "$W/$comp.gz" | awk -v pkg="$1" '
            $0 == "Package: " pkg { inf = 1 }
            inf && /^Filename:/ { print $2; exit }
        '
    done
}
depends_of() {
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

grab() {
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
EXTRA_PKGS="$(printf '%s\n' "$MOD_PKGS" | sed 's/^linux-modules-/linux-modules-extra-/')"
for mp in $MOD_PKGS $EXTRA_PKGS; do
    grab "$mp" || echo "  !! $mp unavailable (continuing)"
done

VMLINUZ="$(find "$W/x/$IMG_VER" -name 'vmlinuz-*' -type f | head -1)"
[ -n "$VMLINUZ" ] || fatal "no vmlinuz in $IMG_VER"
log "vmlinuz: $VMLINUZ"

# ---- 2. assemble the initramfs ---------------------------------------
TREE="$W/tree"
rm -rf "$TREE"
mkdir -p "$TREE"/{bin,sbin,usr/bin,usr/sbin,usr/lib,lib,lib64,scripts/casper-premount,proc,sys,dev,run}

BB="$(find "$W/x/busybox-static" -name busybox -type f | head -1)"
[ -n "$BB" ] || fatal "no busybox binary in busybox-static"
cp "$BB" "$TREE/bin/busybox"
chmod +x "$TREE/bin/busybox"
(cd "$TREE/bin" && ln -sf busybox sh)
for app in mount cat grep sed ls sleep date mkdir dd od sync basename tr printf echo head tail mountpoint; do
    (cd "$TREE/bin" && ln -sf busybox "$app" 2>/dev/null) || true
done

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

FULL="$W/fulltree"
mkdir -p "$FULL"
for mp in $MOD_PKGS $EXTRA_PKGS; do
    [ -f "$W/$mp.deb" ] && dpkg-deb -x "$W/$mp.deb" "$FULL" 2>/dev/null
done
depmod -b "$FULL" "$KVER" 2>/dev/null || log "depmod over the full tree warned"
F2FS_REL="kernel/fs/f2fs/f2fs.ko.zst"
log "the real f2fs dependency line (full-tree depmod):"
grep -h "^$F2FS_REL" "$FULL/lib/modules/$KVER/modules.dep" 2>/dev/null | sed 's/^/  /'

resolve_deps() {
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

copy_mods virtio_blk virtio virtio_pci vfat fat

log "depmod (initramfs tree):"
depmod -b "$TREE" "$KVER" 2>&1 | sed 's/^/  /' || log "depmod returned non-zero"

# Decompress .ko.zst to .ko (kmod in initrd may not handle zstd)
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

# the hook
cp "$HOOK_SRC" "$TREE/scripts/casper-premount/zz_lsl_f2fs_provision"
chmod +x "$TREE/scripts/casper-premount/zz_lsl_f2fs_provision"

# /init
cat > "$TREE/init" <<'INIT'
#!/bin/sh
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
echo "=== lsl-panic-repro /init (PID $$) ==="
echo "=== uname -r: $(uname -r) ==="
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

# ---- 3. the victim disk: BLANK, no partition table ------------------
truncate -s 2G "$W/blank.img"

# ---- 4. boot with Windows QEMU (convert WSL paths to Windows paths) ----
log "booting with tcg (Windows QEMU via interop), asking for 2 GiB of lsl-persist on a BLANK disk"

# Convert WSL paths to Windows UNC paths for the Windows QEMU
WIN_BLANK=$(wslpath -w "$W/blank.img")
WIN_INITRD=$(wslpath -w "$W/initrd.gz")
WIN_VMLINUZ=$(wslpath -w "$VMLINUZ")
WIN_LOG=$(wslpath -w "$W/boot.log")

log "Windows paths:"
log "  blank.img: $WIN_BLANK"
log "  initrd.gz: $WIN_INITRD"
log "  vmlinuz:   $WIN_VMLINUZ"

timeout 180 qemu-system-x86_64 -accel tcg -m 1024 -smp 2 \
    -drive file="$WIN_BLANK",format=raw,if=virtio \
    -kernel "$WIN_VMLINUZ" -initrd "$WIN_INITRD" \
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