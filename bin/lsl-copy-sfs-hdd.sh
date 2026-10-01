#!/bin/bash
# lsl-copy-sfs-hdd.sh - offer to copy the Linux "usr-ish" squashfs layers
# (the casper root layers + home.sfs) from the USB stick to the internal NTFS
# HDD, for faster reads (and so the page-cache warm-up / toram-style copy reads
# from the HDD instead of the slow USB).
#
# The first-run offer lives in the Windows installer wizard (install.ps1), which
# copies the layers into $LSL_DATA_DIR/sfs/ and sets LSL_SFS_HDD_CACHE=1. This
# Linux-side script is the ad-hoc / re-sync counterpart: run it any time (e.g.
# after `uproot` appends a new layer) to (re)copy the layers, check status, or
# toggle the speed optimization.
#
# Usage:
#   lsl-copy-sfs-hdd.sh            # interactive offer: list layers, ask per file
#   lsl-copy-sfs-hdd.sh --yes      # copy all layers without prompting
#   lsl-copy-sfs-hdd.sh --status   # show copies vs USB (present/stale/missing)
#   lsl-copy-sfs-hdd.sh --verify   # re-check copied layers vs the USB (size+sha)
#   lsl-copy-sfs-hdd.sh --use      # enable the HDD-cache speed-up (sets env flag)
#   lsl-copy-sfs-hdd.sh --no-use   # disable it
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lsl-common.sh"
lsl_load_config

CDROM="${LSL_CDROM:-/cdrom}"
DEST="${LSL_SFS_HDD_CACHE_DIR:-${LSL_DATA_DIR:-/mnt/c/Users/lsl-usb}/sfs}"
ENV_FILE="$CDROM/lsl-usb.env"
MANIFEST="$DEST/manifest.txt"

MODE="offer"
for a in "$@"; do
    case "$a" in
        --yes|-y) MODE=yes ;;
        --status) MODE=status ;;
        --verify) MODE=verify ;;
        --use|-u) MODE=use ;;
        --no-use) MODE=nouse ;;
        -h|--help) MODE=help ;;
        *) echo "Unknown option: $a" >&2; MODE=help ;;
    esac
done

human() {
    awk -v b="$1" 'BEGIN{
        if (b>=1073741824) printf "%.1f GiB", b/1073741824;
        else if (b>=1048576) printf "%.1f MiB", b/1048576;
        else if (b>=1024) printf "%.1f KiB", b/1024;
        else printf "%d B", b+0;
    }'
}

# Emit one source sfs path per line (only files that exist on the USB).
# Order matters: the merge below overlays them in exactly this sequence, so
# the base must come first and the newest append last. Alphabetical order is
# that order (see WHYFAIL14), but it is spelled out explicitly here so a new
# name cannot silently change which layer wins.
source_layers() {
    local f
    for f in "$CDROM/casper/filesystem.squashfs" \
             "$CDROM/casper/filesystem_z0_firstboot.squashfs" \
             "$CDROM"/casper/filesystem_z[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]*.squashfs \
             "$CDROM/home"*.sfs; do
        [ -f "$f" ] && printf '%s\n' "$f"
    done
}

# The single layer the initrd hook points LAYERFS_PATH at. With the dot-chain
# gone, a flat name has NO dot-parents, so casper's LAYERFS_PATH walk resolves
# exactly this one file - it must therefore be self-contained (a real rootfs
# with /sbin/init), not a delta over the USB's base layer. Hence the pre-merge.
MERGED_NAME="filesystem_zmerged.squashfs"

layer_size() { stat -c %s "$1" 2>/dev/null || echo 0; }

env_set() {
    # env_set 1|0 : set LSL_SFS_HDD_CACHE in /cdrom/lsl-usb.env (remount rw best-effort)
    local val="$1"
    [ -f "$ENV_FILE" ] || { echo "error: $ENV_FILE not found." >&2; return 1; }
    mount "$CDROM" -o remount,rw 2>/dev/null || true
    local tmp; tmp="$(mktemp)"
    local found=0
    while IFS= read -r ln; do
        case "$ln" in
            LSL_SFS_HDD_CACHE=*) printf 'LSL_SFS_HDD_CACHE=%s\n' "$val"; found=1 ;;
            *) printf '%s\n' "$ln" ;;
        esac
    done < "$ENV_FILE" > "$tmp"
    [ "$found" -eq 0 ] && printf 'LSL_SFS_HDD_CACHE=%s\n' "$val" >> "$tmp"
    cat "$tmp" > "$ENV_FILE" 2>/dev/null && mv "$tmp" "$ENV_FILE" 2>/dev/null || cp "$tmp" "$ENV_FILE" 2>/dev/null
    rm -f "$tmp" 2>/dev/null || true
    mount "$CDROM" -o remount,ro 2>/dev/null || true
    echo "Set LSL_SFS_HDD_CACHE=$val in $ENV_FILE"
}

# Overlay every source layer into one self-contained squashfs at $STAGE_DIR.
# Layer order comes from source_layers(): base first, newest append last, so
# the newest content wins - the same precedence casper's lexical stack gives.
# Exclusions mirror uproot's append (never bake apt caches or flatpak's
# content-addressed store).
build_merged_layer() {
    local out="$1"; shift
    local mnt="/tmp/lsl-merge.$$" f n=0
    mkdir -p "$mnt" || return 1
    # Build an overlay dir by applying each layer in order. unsquashfs cannot
    # write over an existing tree, so unpack each layer to its own dir and
    # copy it in with later layers overwriting earlier files.
    local acc="$mnt/acc"
    mkdir -p "$acc"
    for f in "$@"; do
        local one="$mnt/l.$n"
        mkdir -p "$one"
        if ! unsquashfs -f -d "$one" "$f" >/dev/null 2>&1; then
            echo "  FAILED to unpack $f" >&2
            rm -rf "$mnt"
            return 1
        fi
        # Later layers must win: copy over, do not merge-only.
        cp -a "$one/." "$acc/" 2>/dev/null
        rm -rf "$one"
        n=$((n + 1))
    done
    # A rootfs without /sbin/init would drop the boot to an initramfs shell.
    if [ ! -e "$acc/sbin/init" ]; then
        echo "  ERROR: merged tree has no /sbin/init; refusing to publish it." >&2
        rm -rf "$mnt"
        return 1
    fi
    if ! mksquashfs "$acc" "$out" -comp zstd -Xcompression-level "$LSL_SQUASHFS_COMPRESSION_LEVEL" \
        -wildcards -e "var/cache/apt/archives/*" "var/lib/apt/lists/*" \
                   "var/lib/flatpak/*" >/dev/null 2>&1; then
        echo "  FAILED to build merged layer $out" >&2
        rm -f "$out"
        rm -rf "$mnt"
        return 1
    fi
    rm -rf "$mnt"
    return 0
}

do_offer() {
    local files; files="$(source_layers)"
    [ -n "$files" ] || { echo "No squashfs layers found on $CDROM." >&2; exit 1; }
    mkdir -p "$DEST" 2>/dev/null || { echo "error: cannot create $DEST" >&2; exit 1; }
    echo "Linux squashfs layers found on the USB ($CDROM), in stack order:"
    local total=0 f sz
    while IFS= read -r f; do
        sz="$(layer_size "$f")"; total=$(( total + sz ))
        echo "  $(basename "$f")  $(human "$sz")"
    done <<< "$files"
    echo "Total: $(human "$total"). These are overlaid (in this order) into a single"
    echo "self-contained layer $MERGED_NAME at $DEST - casper boots that one file."
    echo "Current mirror:"
    if [ -f "$DEST/$MERGED_NAME" ]; then
        echo "  $MERGED_NAME  $(human "$(layer_size "$DEST/$MERGED_NAME")")  [present]"
    else
        echo "  $MERGED_NAME  -  [missing]"
    fi
    local ans
    read -r -p "Build the merged layer on the HDD now? [y/N] " ans
    case "${ans:-}" in
        y|Y|yes|YES) do_yes ;;
        *) echo "Aborted. Nothing copied." ;;
    esac
}

do_yes() {
    local files; files="$(source_layers | tr '\n' ' ')"
    [ -n "${files// /}" ] || { echo "No squashfs layers found on $CDROM." >&2; exit 1; }
    mkdir -p "$DEST" 2>/dev/null || { echo "error: cannot create $DEST" >&2; exit 1; }
    # Build the merged layer FIRST. If it cannot be built there is no point
    # copying anything: without it the mirror cannot boot.
    local tmp="$DEST/.$MERGED_NAME.part"
    rm -f "$tmp"
    echo "Building merged layer $MERGED_NAME from $(echo "$files" | wc -w) layer(s) ..."
    if ! build_merged_layer "$tmp" $files; then
        echo "ERROR: could not build the merged layer; mirror not updated." >&2
        exit 1
    fi
    : > "$MANIFEST" 2>/dev/null || true
    {
        echo "# LSL squashfs layers copied to HDD for faster boot"
        echo "SourceUSB=$CDROM"
        echo "Date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >> "$MANIFEST"
    # Publish atomically: casper must never see a half-written layer.
    mv -f "$tmp" "$DEST/$MERGED_NAME" || { echo "ERROR: could not publish merged layer." >&2; exit 1; }
    local sz sha
    sz="$(layer_size "$DEST/$MERGED_NAME")"
    sha="$(sha256sum "$DEST/$MERGED_NAME" | awk '{print $1}')"
    printf '%s=%s sha256:%s\n' "$MERGED_NAME" "$sz" "$sha" >> "$MANIFEST"
    echo "Merged layer ready: $DEST/$MERGED_NAME ($(human "$sz"))"
    # Drop stale per-layer copies from a pre-merge mirror so the hook cannot
    # pick an old layout.
    rm -f "$DEST/filesystem.squashfs" "$DEST/filesystem_z0_firstboot.squashfs" \
          "$DEST"/filesystem_z[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]*.squashfs \
          "$DEST/home"*.sfs 2>/dev/null || true
    env_set 1
    echo "Done. On next boot the initrd will auto-detect this mirror and use it;"
    echo "lsl-precache.sh also warms the page cache from it."
}

do_status() {
    echo "Mirror status (USB $CDROM -> HDD $DEST):"
    local d="$DEST/$MERGED_NAME"
    if [ -f "$d" ]; then
        echo "  $MERGED_NAME: present ($(human "$(layer_size "$d")"))"
        echo "  (built $(date -u -r "$d" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown))"
    else
        echo "  $MERGED_NAME: MISSING - run --yes to build it"
    fi
    echo "  source layers on USB:"
    local f
    while IFS= read -r f; do
        echo "    $(basename "$f")  $(human "$(layer_size "$f")")"
    done < <(source_layers)
    local flag=""
    [ -f "$ENV_FILE" ] && flag="$(grep -E '^LSL_SFS_HDD_CACHE=' "$ENV_FILE" | tail -1 | cut -d= -f2)"
    echo "LSL_SFS_HDD_CACHE=$flag (in $ENV_FILE)"
}

do_verify() {
    [ -f "$MANIFEST" ] || { echo "No manifest at $MANIFEST; run --yes first." >&2; exit 1; }
    echo "Verifying copied layers against the recorded manifest (size + sha256):"
    local ok=1 name rest size want dest dsz dsha
    while IFS='=' read -r name rest || [ -n "$name" ]; do
        case "$name" in ''|\#*|SourceUSB|Date) continue ;; esac
        size="$(printf '%s' "$rest" | awk '{print $1}')"
        want="$(printf '%s' "$rest" | sed -n 's/.*sha256:\([0-9a-fA-F]*\).*/\1/p')"
        dest="$DEST/$name"
        if [ ! -f "$dest" ]; then echo "  MISSING: $dest"; ok=0; continue; fi
        dsz="$(layer_size "$dest")"
        if [ "$dsz" != "$size" ]; then echo "  SIZE MISMATCH: $dest ($dsz != $size)"; ok=0; continue; fi
        if [ -n "$want" ] && command -v sha256sum >/dev/null 2>&1; then
            dsha="$(sha256sum "$dest" | awk '{print $1}')"
            if [ "$dsha" = "$want" ]; then echo "  ok: $name"; else echo "  SHA MISMATCH: $name"; ok=0; fi
        else
            echo "  ok (size): $name"
        fi
    done < "$MANIFEST"
    [ "$ok" -eq 1 ] && echo "All verified." || exit 1
}

case "$MODE" in
    offer) do_offer ;;
    yes) do_yes ;;
    status) do_status ;;
    verify) do_verify ;;
    use) env_set 1 ;;
    nouse) env_set 0 ;;
    help|*)
        grep -E '^#' "$0" | sed 's/^# \{0,1\}//' | sed -n '1,20p'
        echo "DEST (HDD copy location): $DEST"
        ;;
esac
