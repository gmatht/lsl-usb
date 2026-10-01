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
    # ntfsfix -n refuses to run on a device that is ALREADY mounted rw, printing
    # "Refusing to operate on read-write mounted device" and exiting 0. That is
    # not a clean bill of health, and grepping it for dirty/hibernat gives a
    # false "clean" -> we would then attempt an rw mount on a possibly dirty
    # volume. Treat "already mounted rw" as NOT dirty (the kernel has accepted
    # it, so the decision was already made) and never let the probe's own error
    # text be read as a verdict.
    local out
    out="$(ntfsfix -n "$dev" 2>&1)" || true
    printf '%s' "$out" | grep -qiE "refusing to operate" && return 1
    printf '%s' "$out" | grep -qiE "dirty|hibernat|corrupt" || return 1
    return 0
}

# Mount an NTFS partition at $2, degrading safely instead of failing outright.
#
# WHY THIS EXISTS (WHYFAIL11)
# --------------------------
# The kernel ntfs3 driver can refuse a volume that is in a state it will not
# take rw: the journal records `nvme0n1p4: Can't mount, would change RO state`
# (Windows Fast Startup / a dirty volume). The old code mounted with the single
# form `mount "$dev" -t ntfs3 /mnt/c` and, when that returned non-zero, simply
# carried on - leaving /mnt/c NOT mounted. lsl-mount-home.sh then re-checked
# lsl_data_dir_is_persistent, found the data dir resolving onto the live
# overlay, and fell back to a transient tmpfs /home (WHYFAIL9/10 symptom, new
# cause). The FUSE driver (ntfs-3g) mounts the same volume happily, which is why
# onboot.sh later succeeds where this path did not.
#
# So: try ntfs3 rw, then ntfs-3g rw, then the same pair read-only, and finally
# report whether the mount ACTUALLY landed. A non-zero return here is meaningful
# - callers can tell "mounted" from "gave up" - and the read-only rungs mean a
# dirty volume still yields a persistent-enough data dir rather than nothing.
#
# Ordering note: rw before ro, because a ro data dir cannot host the btrfs home
# image; but ro is strictly better than an unmounted /mnt/c, which is what the
# old code left behind.
mount_ntfs() {
    local dev="$1" mnt="$2"
    mkdir -p "$mnt" 2>/dev/null || true

    # A volume the kernel considers dirty/hibernated is not mounted rw: that is
    # how Windows fast-startup volumes get corrupted. Go straight to ro for it.
    local want_ro=0
    if ntfs_is_dirty "$dev"; then
        echo "    WARNING: $dev looks dirty/hibernated; mounting READ-ONLY to avoid corruption." >&2
        want_ro=1
    fi

    local drivers=()
    if [ "$want_ro" = "1" ]; then
        drivers=(ntfs3 ntfs-3g)
    else
        drivers=(ntfs3 ntfs-3g)
    fi

    local drv opts
    for opts in $([ "$want_ro" = "1" ] && echo "ro" || echo "rw ro") ; do
        for drv in "${drivers[@]}"; do
            # Already mounted (by an earlier onboot/mount_all pass, or by the
            # scan loop having found it live)? Do not attempt a second mount -
            # it would fail with EBUSY and be misreported as "could not mount".
            if mountpoint -q "$mnt" 2>/dev/null; then
                return 0
            fi
            if mount "$dev" -t "$drv" -o "$opts" "$mnt" 2>/dev/null; then
                # Verify: mount(8) can return 0 while the kernel logged a
                # refusal for the other driver; trust only a real mountpoint.
                if mountpoint -q "$mnt" 2>/dev/null; then
                    [ "$opts" = "ro" ] && echo "    mounted $dev at $mnt (READ-ONLY; $drv)" >&2 \
                                       || echo "    mounted $dev at $mnt ($drv)" >&2
                    return 0
                fi
            fi
        done
    done

    echo "    ERROR: could not mount $dev at $mnt (tried ntfs3/ntfs-3g, rw/ro)." >&2
    return 1
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
        if [ "$cmd" = "hivexregedit" ]; then
            # Not just a missing dependency: this is the first-boot ORDERING gap.
            # /mnt/c cannot be mapped without hivexregedit, and on a stock first
            # boot the same firstboot run is what installs it (~23 min later),
            # so /home falls back to a tmpfs overlay and that boot's /home is
            # lost (WHYFAIL9 / FRAGILE_HOME.md). The installer stages the .debs
            # in /cdrom/pkgs and lsl_ensure_hivex_tools installs them before
            # /home mounts; reaching here means that did not happen.
            echo "Error: 'hivexregedit' is required but not installed." >&2
            echo "       First-boot ordering defect: the base image lacks hivex-tools and" >&2
            echo "       the same firstboot run installs it only after /mnt/c is needed." >&2
            echo "       Fix: stage the .debs under /cdrom/pkgs so they install before /home." >&2
            : > /run/lsl-usb.mount-missing-hivex 2>/dev/null || true
            exit 1
        fi
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
    # No readable Windows volume. Distinguish "no Windows at all" from "Windows is
    # BitLocker/LUKS encrypted" so the operator isn't left guessing why mount failed.
    enc="$(lsblk -lno NAME,FSTYPE 2>/dev/null | awk '$2 ~ /BitLocker|crypto_LUKS|crypto/ {print "/dev/"$1}')"
    if [ -n "$enc" ]; then
        echo "Error: no readable Windows volume found. The following partition(s) appear encrypted:" >&2
        echo "$enc" >&2
        echo "       Decrypt them in Windows (or suspend BitLocker) before using this tool." >&2
    else
        echo "Error: No Windows installation found."
    fi
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
# Mount C: with a driver/read-only fallback chain, and require that it actually
# landed. The old single `mount -t ntfs3 /mnt/c` could fail (`Can't mount, would
# change RO state`) and be ignored: /mnt/c stayed unmounted, so the data dir was
# not persistent and /home fell back to a RAM overlay. See mount_ntfs().
if ! mount_ntfs "$best_part" /mnt/c; then
    echo "Error: could not mount $best_part at /mnt/c; /home will not be persistent." >&2
    exit 1
fi

cleanup() {
    # Only ever remove the throwaway PROBE dir. $best_mount is normally a
    # mktemp dir from the scan loop, but it can also be /mnt/c when the volume
    # was already mounted at scan time - and unmounting /mnt/c here would undo
    # the mount this script exists to establish. Guard on the path explicitly
    # rather than trusting needs_unmount alone.
    if [ "$needs_unmount" = true ] && [ -n "$best_mount" ] \
        && [ "$best_mount" != "/mnt/c" ]; then
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

# Exit status must reflect the ONE thing this script exists to guarantee:
# /mnt/c is mounted. parse_drive returns non-zero for every drive letter Windows
# never mapped (the loop above normally ends on Z:, so the script used to exit 1
# despite having mounted C: successfully). WHYFAIL10 §5a documented "exits 0
# whenever /mnt/c is mounted" but that was never implemented; lsl-mount-home.sh
# masks it with `|| true`, so the only cost was a misleading status. Make the
# contract real: a mounted /mnt/c is success, whatever the drive-letter mapping
# did, because the data dir lives on C:.
if mountpoint -q /mnt/c 2>/dev/null; then
    exit 0
fi
exit 1
