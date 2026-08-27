#!/bin/bash

### mount C: drive as /mnt/c (and D:..Z: by their Windows drive letter) ###

# --- helper function definitions (safe: no side effects, no root) ----------
# These are defined first so the file can be sourced by tests (see the
# sourceable guard below) without running any scanning or mounting.

# Reverse the byte order of a hex string (Windows mixed-endian GUID fields).
reverse_bytes() {
    local str="$1"
    local rev=""
    for (( i=0; i<${#str}; i+=2 )); do
        rev="${str:$i:2}$rev"
    done
    echo "$rev"
}

# Convert 16 comma-separated hex bytes to a standard UUID string.
hex_to_uuid() {
    local hex="$1"
    hex="${hex//,/}"            # Remove commas -> 32 hex chars (16 bytes)
    [ ${#hex} -eq 32 ] || return 1
    local p1; p1=$(reverse_bytes "${hex:0:8}")
    local p2; p2=$(reverse_bytes "${hex:8:4}")
    local p3; p3=$(reverse_bytes "${hex:12:4}")
    local p4="${hex:16:4}"
    local p5="${hex:20:12}"
    echo "${p1}-${p2}-${p3}-${p4}-${p5}"
}

# lsblk helper: device name whose PARTUUID matches $1 (case-insensitive).
dev_for_uuid() {
    local u="$1"
    lsblk -ln -o NAME,PARTUUID 2>/dev/null | awk -v u="$u" 'tolower($2)==tolower(u){print $1; exit}'
}

# Read-only dirty/hibernation check. Returns 0 (dirty) when ntfsfix reports a
# problem; if ntfsfix is unavailable we conservatively report clean (rw mount).
ntfs_is_dirty() {
    local dev="$1"
    command -v ntfsfix >/dev/null 2>&1 || return 1
    ntfsfix -n "$dev" 2>&1 | grep -qiE "dirty|hibernat|corrupt" || return 1
    return 0
}

# Mount a Windows drive letter at /mnt/<lower>. Maps the letter to the correct
# partition using the MountedDevices registry value:
#   GPT: \DosDevices\X: = DMIO:ID:<disk GUID><partition GUID>  -> match PARTUUID
#   MBR: \DosDevices\X: = <4-byte disk sig><8-byte part offset> -> match PTUUID+START
parse_drive() {
    local drive="$1"
    local mount_point="$2"

    local line=""
    while IFS= read -r line_check; do
        # hivexget emits the key as "\DosDevices\X:" (single backslashes); strip
        # backslashes before matching so we don't fight pattern escaping.
        if [[ "${line_check//\\/}" == *"DosDevices${drive}:"* ]]; then
            line="$line_check"
            break
        fi
    done <<< "$INPUT"

    [ -n "$line" ] || return 1

    # Already mounted (e.g. C: was mounted above)? nothing to do.
    if mountpoint -q "$mount_point" 2>/dev/null; then
        return 0
    fi

    local hex_str="${line#*=hex(3):}"
    hex_str="${hex_str// /}"

    # --- GPT path ---
    local dmio_prefix="44,4d,49,4f,3a,49,44,3a,"
    if [[ "$hex_str" == "$dmio_prefix"* ]]; then
        local body="${hex_str#$dmio_prefix}"
        body="${body//,/}"                       # 64 hex chars: disk(32)+part(32), no separator
        [ ${#body} -ge 64 ] || return 1
        local part_hex="${body:32:32}"           # partition GUID bytes
        [ ${#part_hex} -eq 32 ] || return 1
        local uuid
        uuid="$(hex_to_uuid "$part_hex")" || return 1
        local device
        device="$(dev_for_uuid "$uuid")"
        [ -n "$device" ] || return 1
        if ntfs_is_dirty "/dev/$device"; then
            echo "    mounting /dev/$device at $mount_point (READ-ONLY; dirty NTFS)" >&2
            mount "/dev/$device" -t ntfs3 -o ro "$mount_point" || return 1
        else
            echo "    mounting /dev/$device at $mount_point"
            mount "/dev/$device" -t ntfs3 "$mount_point" || return 1
        fi
        return 0
    fi

    # --- MBR path (best-effort) ---
    local mbr="${hex_str//,/}"
    if [ ${#mbr} -ge 16 ]; then
        local sig="${mbr:0:8}"                   # 4-byte disk signature
        local device
        device="$(lsblk -ln -o NAME,PTUUID 2>/dev/null | awk -v s="$sig" 'tolower($2)==tolower(s){print $1; exit}')"
        [ -n "$device" ] || return 1
        # 8-byte starting LBA (little-endian) identifies the partition.
        local off_hex="${mbr:8:16}"
        local off=$(( 16#${off_hex:14:2}${off_hex:12:2}${off_hex:10:2}${off_hex:8:2}${off_hex:6:2}${off_hex:4:2}${off_hex:2:2}${off_hex:0:2} ))
        local part
        part="$(lsblk -ln -o NAME,START 2>/dev/null | awk -v o="$off" '$2==o{print $1; exit}')"
        [ -n "$part" ] || return 1
        if ntfs_is_dirty "/dev/$part"; then
            echo "    mounting /dev/$part at $mount_point (READ-ONLY; dirty NTFS)" >&2
            mount "/dev/$part" -t ntfs3 -o ro "$mount_point" || return 1
        else
            echo "    mounting /dev/$part at $mount_point"
            mount "/dev/$part" -t ntfs3 "$mount_point" || return 1
        fi
        return 0
    fi

    return 1
}

# When sourced for unit tests, stop here: the functions above are available but
# no root check, command check, scanning, or mounting runs.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0 2>/dev/null || true
fi

# --- real execution path (requires root) -----------------------------------
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (e.g., sudo $0)"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lsl-common.sh"
lsl_load_config

for cmd in blkid mount umount mktemp hivexregedit fdisk xxd awk; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: '$cmd' is required but not installed."
        echo "On Debian/Ubuntu/Mint, try: sudo apt install hivex-tools fdisk xxd"
        exit 1
    fi
done

echo "[1/3] Scanning for Windows installations..."
best_part=""
best_time=0
best_mount=""
needs_unmount=false

while read -r device mountpoint fstype rest; do
    if [[ "$fstype" == ntfs* ]]; then
        sys_file="$mountpoint/Windows/System32/config/SYSTEM"
        if [ -f "$sys_file" ]; then
            mod_time=$(stat -c %Y "$sys_file")
            if [ "$mod_time" -gt "$best_time" ]; then
                best_time=$mod_time
                best_part="$device"
                best_mount="$mountpoint"
            fi
        fi
    fi
done < <(grep -E ' ntfs[3]? ' /proc/mounts)

if [ -z "$best_part" ]; then
    while read -r name fstype; do
        device="/dev/$name"
        tmp_dir=$(mktemp -d)
        if mount -t ntfs3 -o ro "$device" "$tmp_dir" 2>/dev/null || mount -t ntfs-3g -o ro "$device" "$tmp_dir" 2>/dev/null; then
            sys_file="$tmp_dir/Windows/System32/config/SYSTEM"
            if [ -f "$sys_file" ]; then
                mod_time=$(stat -c %Y "$sys_file")
                if [ "$mod_time" -gt "$best_time" ]; then
                    best_time=$mod_time
                    best_part="$device"
                    best_mount="$tmp_dir"
                    needs_unmount=true
                fi
            fi
            umount "$tmp_dir" 2>/dev/null
        fi
        rmdir "$tmp_dir" 2>/dev/null
    done < <(lsblk -lno NAME,FSTYPE | awk '$2 ~ /^ntfs/ {print $1, $2}')
fi

if [ -z "$best_part" ]; then
    echo "Error: No Windows installation found."
    exit 1
fi

echo "    Found most recently booted Windows on: $best_part"
echo "    Using path: $best_mount"

# safe_ntfsfix.sh is not yet battle-tested; only run it when explicitly
# enabled (LSL_NTFSFIX=1 in lsl-usb.env). Default: skip the repair.
if [ "${LSL_NTFSFIX:-0}" = "1" ]; then
    /cdrom/bin/safe_ntfsfix.sh "$best_part"
else
    echo "    Skipping safe_ntfsfix.sh (set LSL_NTFSFIX=1 in lsl-usb.env to enable)."
fi
mkdir -p /mnt/c
# Refuse to mount a dirty/hibernated NTFS read-write: that risks corrupting the
# Windows volume. ntfsfix -n is a read-only check; if it's unavailable we proceed
# rw but the README warns the user to shut Windows down cleanly first.
if ntfs_is_dirty "$best_part"; then
    echo "    WARNING: $best_part looks dirty/hibernated; mounting READ-ONLY to avoid corruption." >&2
    mount "$best_part" -t ntfs3 -o ro /mnt/c || mount "$best_part" -t ntfs-3g -o ro /mnt/c
else
    mount "$best_part" -t ntfs3 /mnt/c
fi

cleanup() {
    if [ "$needs_unmount" = true ] && [ -n "$best_mount" ]; then
        umount "$best_mount" 2>/dev/null
        rmdir "$best_mount" 2>/dev/null
    fi
}
trap cleanup EXIT

### mount D: E: ... etc. ###

# hivexget reads the binary registry; strip Windows carriage returns.
INPUT=$(hivexget /mnt/c/Windows/System32/config/SYSTEM 'MountedDevices' | tr -d '\r')

# Output the clean mount commands
for i in {C..Z}
do
	parse_drive "$i" "/mnt/${i,,}"
done
