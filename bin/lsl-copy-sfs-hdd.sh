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
#   lsl-copy-sfs-hdd.sh --checksum # also verify sha256 (slower) on copy/verify
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
CHECKSUM=0
for a in "$@"; do
    case "$a" in
        --yes|-y) MODE=yes ;;
        --status) MODE=status ;;
        --verify) MODE=verify ;;
        --use|-u) MODE=use ;;
        --no-use) MODE=nouse ;;
        --checksum) CHECKSUM=1 ;;
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
source_layers() {
    local f
    for f in "$CDROM/casper/filesystem_z0_firstboot.squashfs" \
             "$CDROM/casper/filesystem.squashfs" \
             "$CDROM/casper/filesystem_"*.squashfs \
             "$CDROM/home.sfs"; do
        [ -f "$f" ] && printf '%s\n' "$f"
    done
}

# Map a USB layer basename to the name it gets in the HDD mirror. casper's
# multi-layer LAYERFS_PATH chain expects filesystem.z0.squashfs stacked over
# filesystem.squashfs, so the firstboot layer is renamed on copy.
dest_name() {
    case "$1" in
        filesystem_z0_firstboot.squashfs) printf 'filesystem.z0.squashfs' ;;
        *) printf '%s' "$1" ;;
    esac
}

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

copy_one() {
    local src="$1" base dest sz sha
    base="$(basename "$src")"
    dest="$DEST/$(dest_name "$base")"
    sz="$(layer_size "$src")"
    echo "  copying $base -> $(basename "$dest") ($(human "$sz")) ..."
    cp -a "$src" "$dest" 2>/dev/null || cp "$src" "$dest" || { echo "  FAILED to copy $base" >&2; return 1; }
    if [ "$(layer_size "$dest")" != "$sz" ]; then
        echo "  ERROR: size mismatch after copy of $base" >&2; return 1
    fi
    sha="$(sha256sum "$src" | awk '{print $1}')"
    printf '%s=%s sha256:%s\n' "$(basename "$dest")" "$sz" "$sha" >> "$MANIFEST"
    echo "  copied $base -> $(basename "$dest")"
}

do_offer() {
    local files; files="$(source_layers)"
    [ -n "$files" ] || { echo "No squashfs layers found on $CDROM." >&2; exit 1; }
    mkdir -p "$DEST" 2>/dev/null || { echo "error: cannot create $DEST" >&2; exit 1; }
    echo "Linux squashfs layers found on the USB ($CDROM):"
    local total=0 f sz
    while IFS= read -r f; do
        sz="$(layer_size "$f")"; total=$(( total + sz ))
        local st="missing"
        [ -f "$DEST/$(basename "$f")" ] && st="present"
        echo "  $(basename "$f")  $(human "$sz")  [HDD copy: $st]"
    done <<< "$files"
    echo "Total to copy: $(human "$total") -> $DEST"
    local ans
    read -r -p "Copy all layers to the HDD now? [y/N] " ans
    case "${ans:-}" in
        y|Y|yes|YES) do_yes ;;
        *) echo "Aborted. Nothing copied." ;;
    esac
}

do_yes() {
    local files; files="$(source_layers)"
    [ -n "$files" ] || { echo "No squashfs layers found on $CDROM." >&2; exit 1; }
    mkdir -p "$DEST" 2>/dev/null || { echo "error: cannot create $DEST" >&2; exit 1; }
    : > "$MANIFEST" 2>/dev/null || true
    {
        echo "# LSL squashfs layers copied to HDD for faster boot"
        echo "SourceUSB=$CDROM"
        echo "Date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >> "$MANIFEST"
    local f
    while IFS= read -r f; do
        copy_one "$f" || true
    done <<< "$files"
    env_set 1
    echo "Done. On next boot the initrd will auto-detect this mirror and use it;"
    echo "lsl-precache.sh also warms the page cache from it."
}

do_status() {
    local files; files="$(source_layers)"
    echo "Layer status (USB $CDROM vs HDD $DEST):"
    if [ -z "$files" ]; then echo "  no layers on USB."; fi
    local f sz_us sz_hd d
    while IFS= read -r f; do
        sz_us="$(layer_size "$f")"
        d="$DEST/$(dest_name "$(basename "$f")")"
        if [ ! -f "$d" ]; then
            echo "  $(basename "$f"): MISSING on HDD ($(human "$sz_us") on USB)"
        else
            sz_hd="$(layer_size "$d")"
            if [ "$sz_hd" = "$sz_us" ]; then
                echo "  $(basename "$f"): OK ($(human "$sz_hd"), current)"
            else
                echo "  $(basename "$f"): STALE (HDD $(human "$sz_hd") != USB $(human "$sz_us")) - re-run --yes"
            fi
        fi
    done <<< "$files"
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
