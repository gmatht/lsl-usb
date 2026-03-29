#!/bin/bash

#NOTE: I NEED TO TEST THAT EACH STEP WORKS CORRECTLY!!!!
#DO NOT TRUST THAT THIS VERSION REALLY IS SAFE.

# -----------------------------------------------------------------------------
# Script: safe-ntfsfix.sh
# Description: Safely repairs an NTFS partition only if it passes strict safety checks.
# -----------------------------------------------------------------------------

# 1. Root Check
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root." 
   exit 1
fi

# 2. Argument Check
DEVICE="$1"
if [[ -z "$DEVICE" ]]; then
    echo "Usage: $0 /dev/sdXn"
    exit 1
fi

# 3. Device Existence Check
if [[ ! -b "$DEVICE" ]]; then
    echo "Error: Device $DEVICE not found."
    exit 1
fi

# 4. Dependency Check
for cmd in ntfsfix ntfs-3g.probe blkid findmnt; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: Required command '$cmd' not found."
        exit 1
    fi
done

# -----------------------------------------------------------------------------
# SAFETY CHECKS
# -----------------------------------------------------------------------------

echo "Performing safety checks on $DEVICE..."

# A. Check if mounted
if findmnt -rno SOURCE "$DEVICE" > /dev/null; then
    echo "Error: Device is mounted. Unmount it first."
    exit 1
fi

# B. Check for BitLocker / Encryption
FS_TYPE=$(blkid -o value -s TYPE "$DEVICE" 2>/dev/null)
if [[ "$FS_TYPE" == "BitLocker" ]]; then
    echo "------------------------------------------------"
    echo "CRITICAL: Device is BitLocker Encrypted."
    echo "Action: Aborted. Decrypt the drive in Windows first."
    echo "------------------------------------------------"
    exit 1
fi

# C. Check for I/O Errors in kernel ring buffer (last 100 lines)
# This checks if the kernel recently complained about this device.
if dmesg | tail -n 100 | grep -i "$DEVICE" | grep -qi "I/O error\|buffer I/O error"; then
    echo "------------------------------------------------"
    echo "CRITICAL: The kernel reported recent I/O Errors on this device."
    echo "Reason: The drive might be physically failing."
    echo "Action: Aborted. Do NOT write to this drive. Clone it first (ddrescue)."
    echo "------------------------------------------------"
    exit 1
fi

# D. Check if device is Read-Only (hardware switch or FS error)
BLOCK_BASENAME=$(basename "$DEVICE")
RO_STATUS=$(cat /sys/block/${BLOCK_BASENAME%[0-9]*}/${BLOCK_BASENAME}/ro 2>/dev/null || cat /sys/block/$BLOCK_BASENAME/ro 2>/dev/null)
if [[ "$RO_STATUS" == "1" ]]; then
    echo "------------------------------------------------"
    echo "CRITICAL: Device is flagged as Read-Only."
    echo "Action: Aborted. Check hardware write-protect or drive health."
    echo "------------------------------------------------"
    exit 1
fi

# -----------------------------------------------------------------------------
# STATE ANALYSIS
# -----------------------------------------------------------------------------

echo "Analyzing filesystem state..."
PROBE_OUTPUT=$(ntfs-3g.probe --readwrite "$DEVICE" 2>&1)
PROBE_EXIT_CODE=$?

# Check Hibernation
if echo "$PROBE_OUTPUT" | grep -qi "hibernated\|hibernation"; then
    echo "------------------------------------------------"
    echo "CRITICAL: Partition is HIBERNATED."
    echo "Action: Aborted. Boot Windows and perform a full shutdown."
    echo "------------------------------------------------"
    exit 1
fi

# Check for unclean/dirty state
# If probe failed (exit != 0) and output contains 'unclean', we try to fix.
if echo "$PROBE_OUTPUT" | grep -qi "unclean\|not clean\|volume is dirty"; then
    echo "------------------------------------------------"
    echo "State: Volume is unclean."
    echo "Warning: ntfsfix will clear the journal."
    echo "Data written during the crash will be lost."
    echo "------------------------------------------------"
    
    read -p "Proceed with ntfsfix? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi

    # Run ntfsfix
    if ntfsfix -d "$DEVICE"; then
        echo "Success: $DEVICE has been repaired."
        exit 0
    else
        echo "Error: ntfsfix failed. Filesystem might be corrupt."
        echo "Recommendation: Run 'chkdsk /f' from Windows."
        exit 1
    fi
fi

# If probe succeeded, volume is clean
if [[ $PROBE_EXIT_CODE -eq 0 ]]; then
    echo "State: Volume is clean. Nothing to do."
    exit 0
fi

# Fallback
echo "Warning: Unknown state."
echo "Probe Output: $PROBE_OUTPUT"
exit 1
