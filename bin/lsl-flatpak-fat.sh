#!/bin/bash
# lsl-flatpak-fat.sh - host a flatpak installation on the FAT partition.
#
# FAT cannot store the symlinks/perms flatpak needs, so /cdrom is exposed
# through the fat_linux_meta_fs FUSE layer (which emulates them in a sidecar
# metadata file), and flatpak installs into that view. Apps then persist on the
# USB without any squashfs-layer rebuild.
#
# Opt-in: set LSL_FLATPAK_FAT=1 in /cdrom/lsl-usb.env (onboot mounts the view).
# Requires: python3 + fusepy (pip install fusepy) and /dev/fuse.
#
# Usage:
#   lsl-flatpak-fat.sh mount                 # mount the FUSE view of /cdrom
#   lsl-flatpak-fat.sh install <app> ...     # flatpak install into the FAT view
set -euo pipefail

BACKING=/cdrom
MOUNT=/run/lsl-fat
FUSE_SCRIPT=/cdrom/fuse/fat_linux_meta_fs.py

mount_fat_view() {
    [ -d "$MOUNT" ] || mkdir -p "$MOUNT"
    mountpoint -q "$MOUNT" && return 0
    modprobe fuse 2>/dev/null || true
    command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; return 1; }
    # Prefer the fusepy vendored on the stick (offline-safe); fall back to a
    # system fusepy, then pip as a last resort (needs network).
    if [ -f "$BACKING/fuse/fusepy/fuse.py" ]; then
        export PYTHONPATH="$BACKING/fuse/fusepy${PYTHONPATH:+:$PYTHONPATH}"
    fi
    if ! python3 -c 'import fuse' 2>/dev/null; then
        python3 -m pip install --user fusepy 2>/dev/null || true
    fi
    python3 -c 'import fuse' 2>/dev/null || { echo "fusepy required (vendored copy missing at $BACKING/fuse/fusepy and pip unavailable)" >&2; return 1; }
    [ -e /dev/fuse ] || { echo "/dev/fuse not available" >&2; return 1; }
    [ -f "$FUSE_SCRIPT" ] || { echo "missing $FUSE_SCRIPT" >&2; return 1; }
    python3 "$FUSE_SCRIPT" "$BACKING" "$MOUNT" &
    for _ in $(seq 1 20); do
        mountpoint -q "$MOUNT" && return 0
        sleep 0.5
    done
    echo "FUSE mount did not come up" >&2
    return 1
}

flatpak_fat() {
    mount_fat_view || return 1
    mkdir -p "$MOUNT/flatpak"
    exec flatpak --installation="$MOUNT/flatpak" "$@"
}

case "${1:-}" in
    mount) mount_fat_view ;;
    install) shift; flatpak_fat install "$@" ;;
    *) echo "usage: lsl-flatpak-fat.sh {mount|install ...}" >&2; exit 1 ;;
esac
