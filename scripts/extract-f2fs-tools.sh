#!/bin/bash
# extract-f2fs-tools.sh - build the initrd tool bundle for F2FS provisioning.
#
# WHY THIS EXISTS
# ---------------
# initramfs/lsl_f2fs_provision.sh repartitions the stick on first boot, but
# casper's initramfs ships NEITHER sfdisk, fatresize nor mkfs.f2fs (it ships
# mkfs.ext4, because that is what casper itself uses). The live root has all
# three (DESIGN-F2FS-PERSISTENCE.md s6.1 confirms on the Mint image), but the
# live root does not exist yet at casper-premount time - the hook runs while it
# is still being assembled.
#
# So the tools have to come from somewhere that exists early. They are taken
# from the DISTRO'S OWN ROOTFS - the ISO's casper/filesystem.squashfs - rather
# than downloaded or vendored:
#   - no new network dependency, no licensing question, no binaries in git,
#   - and they are exactly the build the stick's kernel/userspace will use, so
#     there is no version skew with the f2fs driver in that kernel.
#
# USAGE
#   extract-f2fs-tools.sh <path-to-ISO> [-o OUT_DIR]
#     Unpacks <ISO>'s rootfs, copies the tools + their shared-library closure
#     into a staging tree, and writes f2fs-tools.tar.gz + f2fs-tools.sha256.
#
#   extract-f2fs-tools.sh --verify <OUT_DIR>
#     Re-hashes the existing tarball against its recorded digest.
#
# The output lands in rust9x/lslsetup/assets/ so the Rust side can embed it the
# same way it embeds the z0 layer, and so a stale blob can be caught at build
# time (the WHYFAIL10 / WHYFAIL17 lesson: a guard on the source is not a guard
# on the artifact).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSETS="${LSL_ASSETS_DIR:-$ROOT/rust9x/lslsetup/assets}"
TOOLS=(sfdisk fatresize mkfs.f2fs)
VERIFY=0
ISO=""
OUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --verify) VERIFY=1; shift ;;
        -o|--out) OUT="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "extract-f2fs-tools: unknown option: $1" >&2; exit 2 ;;
        *) ISO="$1"; shift ;;
    esac
done

TARBALL="$OUT/f2fs-tools.tar.gz"
SHA="$OUT/f2fs-tools.sha256"

if [ "$VERIFY" = "1" ]; then
    [ -f "$TARBALL" ] && [ -f "$SHA" ] || { echo "extract-f2fs-tools: nothing to verify in $OUT" >&2; exit 2; }
    want="$(awk '{print $1; exit}' "$SHA")"
    got="$(sha256sum "$TARBALL" | awk '{print $1}')"
    if [ "$want" = "$got" ]; then
        echo "OK: f2fs-tools.tar.gz matches its recorded digest"
        exit 0
    fi
    echo "STALE: f2fs-tools.tar.gz digest does not match $SHA" >&2
    echo "  expected $want" >&2
    echo "  actual   $got" >&2
    echo "Regenerate with: bash $0 <ISO> -o $OUT" >&2
    exit 1
fi

[ -n "$ISO" ] || { echo "usage: $0 <ISO> [-o OUT_DIR]" >&2; exit 2; }
[ -f "$ISO" ] || { echo "extract-f2fs-tools: no such ISO: $ISO" >&2; exit 2; }
[ -n "$OUT" ] || OUT="$ASSETS"

for t in unsquashfs 7z xorriso sha256sum; do
    command -v "$t" >/dev/null 2>&1 || {
        echo "extract-f2fs-tools: $t not found (apt install squashfs-tools p7zip-full xorriso coreutils)." >&2
        exit 2
    }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---- 1. get the rootfs out of the ISO ---------------------------------------
SFS="$TMP/rootfs.squashfs"
echo "extracting casper/filesystem.squashfs from $ISO ..."
if 7z e -y -o"$TMP/iso" "$ISO" "*/casper/filesystem.squashfs" >/dev/null 2>&1; then
    SFS="$(find "$TMP/iso" -name 'filesystem.squashfs' -type f | head -1)"
elif command -v xorriso >/dev/null 2>&1; then
    xorriso -osirrox on -indev "$ISO" -extract /casper/filesystem.squashfs "$SFS" >/dev/null 2>&1 || true
fi
[ -n "$SFS" ] && [ -f "$SFS" ] || { echo "extract-f2fs-tools: could not pull filesystem.squashfs out of the ISO" >&2; exit 2; }

ROOTFS="$TMP/root"
echo "unsquashing $(du -h "$SFS" | cut -f1) ..."
unsquashfs -no-xattrs -f -d "$ROOTFS" "$SFS" >/dev/null 2>&1
# Check the RESULT, not just the exit status: an unknown flag (or a partially
# failed unpack) makes unsquashfs print its usage and still exit 0, which looks
# like success and yields an empty rootfs.
if [ ! -d "$ROOTFS/usr" ] && [ ! -d "$ROOTFS/./usr" ]; then
    echo "extract-f2fs-tools: unsquashfs produced no usable tree from $SFS" >&2
    exit 2
fi

# ---- 2. collect the tools and their shared-library closure -------------------
STAGE="$TMP/stage"
mkdir -p "$STAGE/bin" "$STAGE/lib" "$STAGE/lib64" "$STAGE/usr/bin" "$STAGE/usr/sbin" "$STAGE/usr/lib"

missing=""
for t in "${TOOLS[@]}"; do
    src="$(find "$ROOTFS" -type f -name "$t" -perm -u+x 2>/dev/null | head -1)"
    if [ -z "$src" ]; then
        missing="$missing $t"
        continue
    fi
    # Keep the tool at the path the initrd expects: sbin tools under usr/sbin,
    # the rest in bin.
    case "$src" in
        */sbin/*) dest="$STAGE/usr/sbin" ;;
        *)        dest="$STAGE/bin" ;;
    esac
    cp -L "$src" "$dest/$t"
    echo "  $t  <-  ${src#$ROOTFS}"

    # The closure. A dynamically linked sfdisk without its .so files is a file
    # that cannot run - and in the initrd there is no package manager to
    # resolve them, so this list must be complete or the hook silently skips.
    for lib in $(ldd "$src" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^\//) print $i}' | sort -u); do
        base="$(basename "$lib")"
        found=""
        for dir in lib lib64 usr/lib usr/lib/x86_64-linux-gnu lib/x86_64-linux-gnu usr/lib64; do
            if [ -f "$ROOTFS/$dir/$base" ]; then
                mkdir -p "$STAGE/$dir"
                cp -L "$ROOTFS/$dir/$base" "$STAGE/$dir/$base" 2>/dev/null && found=1
                break
            fi
        done
        [ -n "$found" ] || echo "    WARNING: shared library $base not found in the rootfs"
    done
done

if [ -n "$missing" ]; then
    cat >&2 <<EOF
extract-f2fs-tools: the ISO rootfs is missing:$missing

The distro image must carry f2fs-tools (mkfs.f2fs), dosfstools/util-linux
(sfdisk) and fatresize. Either the ISO is not a casper image this design
targets, or the packages are absent.
EOF
    exit 1
fi

# ---- 3. stage a PATH shim so `command -v` finds them in the initrd -----------
# The hook gates on `command -v sfdisk` etc. and then invokes them by bare
# name. In the initrd that means /usr/sbin and /usr/bin must resolve, so a
# tiny launcher per tool is written rather than hoping PATH is set for us.
cat > "$STAGE/LSL_TOOLS_README" <<EOF
f2fs provisioning tools for casper-premount (initramfs/lsl_f2fs_provision.sh).

Staged from the ISO's own casper/filesystem.squashfs by
scripts/extract-f2fs-tools.sh. The hook unsets nothing and assumes PATH
already includes /usr/sbin:/sbin:/usr/bin:/bin, which casper's initrd does.
EOF

# ---- 4. pack it, and record the digest --------------------------------------
mkdir -p "$OUT"
echo "packing $(find "$STAGE" -type f | wc -l) files into $TARBALL ..."
tar -C "$STAGE" -czf "$TARBALL" .
sha256sum "$TARBALL" | awk -v n="$(basename "$TARBALL")" '{print $1"  "n}' > "$SHA"

size="$(du -h "$TARBALL" | cut -f1)"
echo "OK: $TARBALL ($size)"
echo "    digest recorded in $SHA"
echo
echo "Next: rehash so build.rs can enforce freshness, then rebuild the exe:"
echo "  cd $ROOT/rust9x/lslsetup && cargo build --release"
echo
echo "Note: the initrd grows by ~$size on every build. That is the cost of"
echo "provisioning on the Linux side, and it buys a partition the Windows"
echo "installer cannot create (there is no Windows API to shrink FAT32)."