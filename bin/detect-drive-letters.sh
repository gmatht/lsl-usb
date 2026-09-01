#!/bin/bash

# Ensure the script is run as root (required for mounting)
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (e.g., sudo $0)"
  exit 1
fi

# Check for required tools
for cmd in blkid mount umount mktemp hivexregedit fdisk xxd; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: '$cmd' is required but not installed."
        echo "On Debian/Ubuntu, try: sudo apt install hivex-tools fdisk xxd"
        exit 1
    fi
done

echo "[1/3] Scanning NTFS partitions for Windows installations..."
best_part=""
best_time=0

# Find all NTFS partitions
while IFS= read -r part; do
    tmp_dir=$(mktemp -d)
    # Mount read-only, suppress errors (e.g. hibernated or Bitlocked drives)
    if mount -o ro "$part" "$tmp_dir" 2>/dev/null; then
        sys_file="$tmp_dir/Windows/System32/config/SYSTEM"
        if [ -f "$sys_file" ]; then
            mod_time=$(stat -c %Y "$sys_file")
            if [ "$mod_time" -gt "$best_time" ]; then
                best_time=$mod_time
                best_part=$part
            fi
        fi
        umount "$tmp_dir" 2>/dev/null
    fi
    rmdir "$tmp_dir" 2>/dev/null
done < <(blkid -t TYPE=ntfs -o device)

if [ -z "$best_part" ]; then
    echo "Error: No Windows installation found (or drives are hibernated/Bitlocker locked)."
    exit 1
fi

echo "    Found most recently booted Windows on: $best_part"

# Setup a safe mount point
MOUNT_POINT=$(mktemp -d)
trap "umount '$MOUNT_POINT' 2>/dev/null; rmdir '$MOUNT_POINT' 2>/dev/null" EXIT

echo "[2/3] Mounting $best_part and extracting registry..."
mount -o ro "$best_part" "$MOUNT_POINT" 2>/dev/null || { echo "Error: Failed to mount $best_part."; exit 1; }

HIVE="$MOUNT_POINT/Windows/System32/config/SYSTEM"
if [ ! -f "$HIVE" ]; then
    echo "Error: SYSTEM registry hive not found."
    exit 1
fi

echo "[3/3] Mapping drive letters..."
echo "----------------------------------------"

# Process the registry export
hivexregedit --export "$HIVE" 'HKEY_LOCAL_MACHINE\SYSTEM\MountedDevices' 2>/dev/null | while IFS= read -r line; do
    # Match lines like: ["MountedDevices\DosDevices\C:"]
    if [[ "$line" =~ ^\[.*\\DosDevices\\([A-Z]):\"\]$ ]]; then
        current_letter="${BASH_REMATCH[1]}"
    
    # Match lines like: hex(3):5c,00,00,00...
    elif [[ "$line" =~ ^hex\([0-9a-fA-F]+\):(.*)$ ]] && [[ -n "$current_letter" ]]; then
        hex_data="${BASH_REMATCH[1]}"
        
        # Get first byte to determine mapping type
        byte0=$(echo "$hex_data" | cut -d',' -f1)

        if [ "$byte0" == "05" ]; then
            # Type 05: Volume GUID (Used for GPT drives and modern Windows)
            # GUID is stored as UTF-16LE from byte 16 to byte 71
            guid_hex=$(echo "$hex_data" | tr ',' '\n' | sed -n '17,72p' | tr '\n' ',' | sed 's/,$//')
            guid=$(echo "$guid_hex" | sed 's/,//g' | xxd -r -p | tr -d '\0')
            guid="{${guid}}"
            
            # Linux by-partuuid is lowercase and stripped of dashes
            linux_guid=$(echo "$guid" | tr '[:upper:]' '[:lower:]' | tr -d '{}-')
            device=$(readlink -f "/dev/disk/by-partuuid/$linux_guid" 2>/dev/null)
            
            if [ -n "$device" ]; then
                echo "$current_letter: -> $device (GUID: $guid)"
            else
                echo "$current_letter: -> Not found (GUID: $guid)"
            fi

        elif [ "$byte0" == "00" ] || [ "$byte0" == "03" ] || [ "$byte0" == "04" ]; then
            # Type 00/03/04: MBR Disk Signature + Partition Offset
            # Bytes 8-11: Disk Signature (4 bytes, Little Endian)
            # Bytes 16-23: Offset in bytes (8 bytes, Little Endian)
            
            sig_bytes=$(echo "$hex_data" | tr ',' '\n' | sed -n '9,12p')
            off_bytes=$(echo "$hex_data" | tr ',' '\n' | sed -n '17,24p')

            # Reverse bytes for Little Endian to standard hex string
            sig_hex=$(echo "$sig_bytes" | tr ',' '\n' | tac | tr -d '\n')
            off_hex=$(echo "$off_bytes" | tr ',' '\n' | tac | tr -d '\n')

            # Convert hex offset to decimal, then to 512-byte sectors
            offset_dec=$((16#$off_hex))
            sector=$(( offset_dec / 512 ))

            # Find the disk with this MBR signature (PTUUID)
            disk=""
            for d in /dev/sd[a-z] /dev/nvme[0-9]n[0-9] /dev/vd[a-z]; do
                if [ -b "$d" ]; then
                    ptuuid=$(blkid -s PTUUID -o value "$d" 2>/dev/null)
                    # Case-insensitive comparison
                    if [ "${ptuuid^^}" == "${sig_hex^^}" ]; then
                        disk="$d"
                        break
                    fi
                fi
            done

            if [ -n "$disk" ]; then
                # Find the partition on this disk starting at the calculated sector
                part=$(fdisk -l -o DEVICE,START "$disk" 2>/dev/null | awk -v s="$sector" '$2==s {print $1; exit}')
                if [ -n "$part" ]; then
                    echo "$current_letter: -> $part (Disk: $disk, Sector: $sector)"
                else
                    echo "$current_letter: -> Partition not found (Disk: $disk, Sector: $sector)"
                fi
            else
                echo "$current_letter: -> Disk not found (MBR Signature: $sig_hex)"
            fi
        else
            echo "$current_letter: -> Unknown format (Byte 0: 0x$byte0)"
        fi
        
        # Reset for next drive letter
        current_letter=""
    fi
done

echo "----------------------------------------"
echo "Done."
