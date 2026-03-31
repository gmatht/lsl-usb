#!/bin/bash

### mount C: drive as /mnt/c ###

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (e.g., sudo $0)"
  exit 1
fi

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

/cdrom/bin/safe_ntfsfix.sh "$best_part"
mount "$best_part" -t ntfs3 /mnt/c

cleanup() {
    if [ "$needs_unmount" = true ] && [ -n "$best_mount" ]; then
        umount "$best_mount" 2>/dev/null
        rmdir "$best_mount" 2>/dev/null
    fi
}
trap cleanup EXIT

### mount D: E: ... etc. ###

# Run hivexget and strip Windows carriage returns (\r)
INPUT=$(hivexget /mnt/c/Windows/System32/config/SYSTEM 'MountedDevices' | tr -d '\r')

# Function to reverse the byte order of a hex string
reverse_bytes() {
    local str="$1"
    local rev=""
    for (( i=0; i<${#str}; i+=2 )); do
        rev="${str:$i:2}$rev"
    done
    echo "$rev"
}

# Function to convert 16 comma-separated hex bytes to a standard UUID string
hex_to_uuid() {
    local hex="$1"
    hex="${hex//,/}" # Remove commas
    
    # Split and reverse the first 3 parts (Windows mixed-endian GUID format)
    local p1=$(reverse_bytes "${hex:0:8}")
    local p2=$(reverse_bytes "${hex:8:4}")
    local p3=$(reverse_bytes "${hex:12:4}")
    local p4="${hex:16:4}"
    local p5="${hex:20:12}"
    
    echo "${p1}-${p2}-${p3}-${p4}-${p5}"
}

# Function to parse a specific drive letter
parse_drive() {
    local drive="$1"
    local mount_point="$2"
    
    local line=""
    while IFS= read -r line_check; do
        if [[ "$line_check" == "\"\\\\DosDevices\\\\${drive}:\""* ]]; then
            line="$line_check"
            break
        fi
    done <<< "$INPUT"
    
    if [[ -z "$line" ]]; then
        return 1 
    fi
    
    # Strip everything before and including =hex(3):
    local hex_str="${line#*=hex(3):}"
    hex_str="${hex_str// /}" 
    
    # Strip the DMIO:ID: prefix to isolate the 16-byte Disk GUID
    local dmio_prefix="44,4d,49,4f,3a,49,44,3a,"
    
    if [[ "$hex_str" == "$dmio_prefix"* ]]; then
        local guid_hex="${hex_str#$dmio_prefix}"
        local uuid=$(hex_to_uuid "$guid_hex")

	echo "$uuid"
        
        # Use lsblk to cleanly find the device path without any extra garbage
        local device=$(lsblk -n -o NAME,PARTUUID | grep -i "$uuid" | awk '{print $1}' | sed s/[├└]─//)
        
        if [[ -n "$device" ]]; then
            echo "mount $device $mount_point"
            mount "/dev/$device" -t ntfs3 "$mount_point"
	    #TODO: double check this is REALLY safe and then fix all NTFS drives bash /cdrom/bin/safe_ntfsfix.sh $devicetfsfix.sh "$best_part"
	    #mount "$best_part" -t ntfs3 /mnt/c
        fi
    fi
}

# Output the clean mount commands
for i in {C..Z}
do
	parse_drive "$i" "/mnt/${i,,}"
done 
