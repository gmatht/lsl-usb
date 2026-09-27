#!/bin/bash
# Mount the live user's /home: RAM-only (Boot to RAM, no persistence), a
# tmpfs-overlay over /cdrom/home.sfs (USB mode), or a loop-mounted
# home.btrfs/cache.btrfs pair on the LSL data dir (HDD mode).
#
# Split out of onboot.sh so the display manager can wait for the /home mount
# ALONE (lsl-home.service is Before=display-manager.service): a session that
# starts before /home is final begins on the live /home, has the persistent one
# mounted underneath it, dies, and drops back to the greeter. Gating the greeter
# on all of onboot.service instead would hold it for that script's whole runtime.
#
# Idempotent: runs first from lsl-home.service, then again from onboot.sh (for
# sticks whose installed units predate lsl-home.service).
set -u   # deliberately NOT -e: partial failures (btrfs-progs absent on the
         # first boot, a missing home.sfs) must fall through to a warning.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Point the config loader at the stick's env file before sourcing it (same as
# onboot.sh): a stale $HOME/lsl-usb.env must not shadow /cdrom/lsl-usb.env.
LSL_ENV_FILE="${LSL_ENV_FILE:-/cdrom/lsl-usb.env}"
export LSL_ENV_FILE
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lsl-common.sh"

lsl_load_config

# HDD mode's data dir lives on a Windows volume (/mnt/c/...); mount the drives
# here (idempotent) so this unit can run before onboot.sh does its own mount.
if [ -r /cdrom/bin/mount_all.sh ]; then
    bash /cdrom/bin/mount_all.sh 2>/dev/null || true
fi

# Already set up this boot? /run is tmpfs, so the state file exists only after a
# completed run - onboot.sh calls us again after lsl-home.service did the work.
if grep -q '^LSL_MODE=' /run/lsl-usb.state 2>/dev/null; then
    lsl_ensure_user_home /home
    echo "lsl: /home already set up this boot ($(grep '^LSL_MODE=' /run/lsl-usb.state)); skipping." >&2
    exit 0
fi

DATA_DIR="$(lsl_resolve_data_dir)"
mkdir -p "$DATA_DIR" 2>/dev/null || true
LSL_DESKTOP_USER="$(lsl_desktop_user)"
export LSL_DESKTOP_USER
echo "lsl: mounting /home: env=${LSL_ENV_FILE:-<none>} data_dir=$DATA_DIR user=${LSL_DESKTOP_USER:-<unset>}"

# HDD mode keeps the command log on home.btrfs (created after the mount below).
# USB mode's log is readied by onboot.sh, which runs after /persist is mounted.
if ! lsl_is_usb_mode; then
    LSL_BASH_LOG="/home/$LSL_DESKTOP_USER/.local/state/lsl/bash.log"
fi

export LSL_HOME_LOWER=/run/lsl-home-lower
export LSL_HOME_UPPER=/run/lsl-home-overlay/upper
export LSL_HOME_WORK=/run/lsl-home-overlay/work
export LSL_HOME_TMPFS=/run/lsl-home-overlay
export LSL_CACHE_MOUNT=/mnt/lsl-cache

# If HDD mode but the data dir isn't on a persistent volume yet (e.g. the first
# boot, before firstboot installed the hivex tools that mount /mnt/c), the path
# would resolve onto the live overlay and we'd silently write home.btrfs into
# volatile RAM. Retry the Windows-drive mount once, and if it's still not on a
# persistent volume, fall back to a temporary tmpfs-overlay /home for this boot
# (so the only consequence is that first-boot home changes are lost on reboot).
LSL_FALLBACK_USB_HOME=0
# HDD mode also needs btrfs-progs to create home.btrfs/cache.btrfs. On the
# first boot that tool may not be in the base image yet (firstboot installs it
# afterwards), so fall back to a temporary tmpfs /home rather than fail.
if ! lsl_is_usb_mode && ! command -v mkfs.btrfs >/dev/null 2>&1; then
    echo "lsl: btrfs-progs not installed; cannot create persistent home.btrfs on the first boot." >&2
    echo "lsl: using a temporary tmpfs-overlay /home instead (changes lost on reboot)." >&2
    LSL_FALLBACK_USB_HOME=1
fi
if ! lsl_is_usb_mode && ! lsl_data_dir_is_persistent; then
    echo "lsl: HDD data dir $DATA_DIR not on a persistent volume yet; retrying drive mount..." >&2
    bash /cdrom/bin/mount_all.sh 2>/dev/null || true
    DATA_DIR="$(lsl_resolve_data_dir)"
    mkdir -p "$DATA_DIR" 2>/dev/null || true
    if lsl_data_dir_is_persistent; then
        echo "lsl: data dir now on a persistent volume: $DATA_DIR" >&2
    else
        echo "lsl: WARNING: data dir still not persistent; using a temporary tmpfs-overlay /home for this boot (changes lost on reboot)." >&2
        LSL_FALLBACK_USB_HOME=1
    fi
fi

# Boot-to-RAM "(no persistence)" entry passes lsl_home=tmpfs: give the live
# user a RAM-only home and touch no persistence at all. Building a valid
# /home/<user> (owned by the user, seeded from /etc/skel) is required -
# LightDM's autologin session dies without it and drops back to the greeter.
LSL_EPHEMERAL_HOME=0
grep -q 'lsl_home=tmpfs' "${LSL_CMDLINE_FILE:-/proc/cmdline}" 2>/dev/null && LSL_EPHEMERAL_HOME=1

if [ "$LSL_EPHEMERAL_HOME" = "1" ]; then
    mkdir -p /run/lsl-live-home
    mount --bind /home /run/lsl-live-home 2>/dev/null || true
    if mount -t tmpfs -o "size=${LSL_HOME_TMPFS_MIB:-2048}M" tmpfs /home; then
        if [ -n "${LSL_DESKTOP_USER:-}" ]; then
            mkdir -p "/home/$LSL_DESKTOP_USER"
            cp -a /etc/skel/. "/home/$LSL_DESKTOP_USER/" 2>/dev/null || true
            cp -a "/run/lsl-live-home/$LSL_DESKTOP_USER/." "/home/$LSL_DESKTOP_USER/" 2>/dev/null || true
            chown -R "$LSL_DESKTOP_USER:$LSL_DESKTOP_USER" "/home/$LSL_DESKTOP_USER" 2>/dev/null || true
        fi
        echo "lsl: RAM-only home (Boot to RAM, no persistence); changes are lost on reboot." >&2
    else
        echo "lsl: could not mount tmpfs on /home; keeping the live home." >&2
    fi
    umount /run/lsl-live-home 2>/dev/null || true
    rmdir /run/lsl-live-home 2>/dev/null || true
    echo "LSL_MODE=ram" > /run/lsl-usb.state
elif lsl_is_usb_mode || [ "${LSL_FALLBACK_USB_HOME:-0}" = "1" ]; then
    mkdir -p "$LSL_HOME_TMPFS" "$LSL_HOME_UPPER" "$LSL_HOME_WORK" "$LSL_HOME_LOWER"
    if ! mountpoint -q "$LSL_HOME_TMPFS" 2>/dev/null; then
        mount -t tmpfs -o "size=${LSL_HOME_TMPFS_MIB:-2048}M" tmpfs "$LSL_HOME_TMPFS"
    fi
    mkdir -p "$LSL_HOME_UPPER" "$LSL_HOME_WORK" "$LSL_HOME_LOWER"
    if [ ! -f /cdrom/home.sfs ]; then
        # First boot of a Windows-installed image: seed home.sfs from the live
        # /home (keeps the mint user's login home) so the USB-mode overlay works.
        mount /cdrom -o remount,rw 2>/dev/null || true
        echo "Creating /cdrom/home.sfs from live /home (first boot)..."
        if command -v mksquashfs >/dev/null 2>&1; then
            sz="$(du -sm /home 2>/dev/null | awk '{print $1}')"; sz="${sz:-0}"
            need_mib="$(( sz + 64 ))"
            if lsl_ensure_cdrom_space "$need_mib"; then
                if mksquashfs /home /cdrom/home.sfs -comp zstd >/dev/null 2>&1; then
                    echo "Created /cdrom/home.sfs ($(du -h /cdrom/home.sfs 2>/dev/null | cut -f1))."
                else
                    echo "ERROR: mksquashfs failed while creating /cdrom/home.sfs - /home will NOT persist." >&2
                    echo "       Check that /cdrom is writable and has ~${need_mib} MiB free; reboot and retry." >&2
                fi
            else
                echo "ERROR: only $(lsl_cdrom_free_mib) MiB free on /cdrom; need ~${need_mib} MiB - /home.sfs NOT created." >&2
                echo "       USB-mode home persistence will not work until space is freed (or a larger stick is used)." >&2
            fi
        else
            echo "ERROR: mksquashfs not found - /cdrom/home.sfs NOT created; USB-mode home will not persist." >&2
        fi
        mount /cdrom -o remount,ro 2>/dev/null || true
    fi
    # Only stack the overlay when the home.sfs lower really mounted: a failed
    # mount leaves $LSL_HOME_LOWER an empty dir, and the overlay would then
    # expose an EMPTY /home (the live user's home disappears; autologin falls
    # back to the greeter).
    if mount /cdrom/home.sfs "$LSL_HOME_LOWER"; then
        mount -t overlay overlay -o "lowerdir=${LSL_HOME_LOWER}/,upperdir=${LSL_HOME_UPPER},workdir=${LSL_HOME_WORK}" /home
    else
        echo "lsl: could not mount /cdrom/home.sfs; keeping the live /home (no persistence this boot)." >&2
    fi
    # The home image is keyed to LSL_DATA_DIR, not to the booted distro: one
    # seeded by another live user (an Ubuntu home.sfs holding /home/ubuntu,
    # reused on this Mint stick) has no /home/<user> here. Guarantee it, exactly
    # as the RAM-home branch does.
    lsl_ensure_user_home /home
    {
        echo "LSL_HOME_LOWER=$LSL_HOME_LOWER"
        echo "LSL_HOME_UPPER=$LSL_HOME_UPPER"
        echo "LSL_HOME_WORK=$LSL_HOME_WORK"
        echo "LSL_MODE=usb"
    } > /run/lsl-usb.state
else
    HOME_IMG="$(lsl_home_btrfs_path)"
    CACHE_IMG="$(lsl_cache_btrfs_path)"
    mkdir -p "$(dirname "$HOME_IMG")"
    home_is_fresh=0
    if [ ! -f "$HOME_IMG" ]; then
        truncate -s "${LSL_HOME_BTRFS_MIB:-4096}M" "$HOME_IMG"
        mkfs.btrfs -f "$HOME_IMG" >/dev/null
        home_is_fresh=1
    else
        # Grow to the configured size at boot (unmounted) - reliable; online
        # growth of a busy /home loop device often fails.
        lsl_grow_btrfs_image "$HOME_IMG" "${LSL_HOME_BTRFS_MIB:-4096}"
    fi
    if [ ! -f "$CACHE_IMG" ]; then
        truncate -s "${LSL_CACHE_BTRFS_MIB:-2048}M" "$CACHE_IMG"
        mkfs.btrfs -f "$CACHE_IMG" >/dev/null
    else
        lsl_grow_btrfs_image "$CACHE_IMG" "${LSL_CACHE_BTRFS_MIB:-2048}"
    fi
    if [ "$home_is_fresh" = "1" ]; then
        # Seed fresh home.btrfs from the live /home so the desktop user's
        # login home, dotfiles, and session config survive first boot.
        mkdir -p /run/lsl-live-home
        mount --bind /home /run/lsl-live-home
        mount -o loop,compress=zstd:3,relatime "$HOME_IMG" /home
        echo "Seeding new home.btrfs from live /home (user=${LSL_DESKTOP_USER:-?})..."
        cp -a /run/lsl-live-home/. /home/ 2>/dev/null || true
        umount /run/lsl-live-home
        rmdir /run/lsl-live-home 2>/dev/null || true
    else
        mount -o loop,compress=zstd:3,relatime "$HOME_IMG" /home
    fi
    command -v btrfs >/dev/null 2>&1 && btrfs filesystem resize max /home 2>/dev/null || true

    # A home.btrfs seeded by a different live user (an Ubuntu /home/ubuntu
    # reused on this Mint stick whose user is /home/mint) has no home for THIS
    # boot's user; autologin then dies and drops back to the greeter. Guarantee
    # the user's home on every persistent-home path (see the USB branch).
    lsl_ensure_user_home /home

    lsl_prepare_bash_log "$LSL_BASH_LOG"
    mkdir -p "$LSL_CACHE_MOUNT"
    mount -o loop,compress=zstd:3,relatime "$CACHE_IMG" "$LSL_CACHE_MOUNT"
    command -v btrfs >/dev/null 2>&1 && btrfs filesystem resize max "$LSL_CACHE_MOUNT" 2>/dev/null || true
    mkdir -p "$LSL_CACHE_MOUNT/var-cache" "$LSL_CACHE_MOUNT/user-cache"
    if [ -d /var/cache ] && [ "$(ls -A /var/cache 2>/dev/null)" ]; then
        cp -a /var/cache/. "$LSL_CACHE_MOUNT/var-cache/" 2>/dev/null || true
    fi
    mount --bind "$LSL_CACHE_MOUNT/var-cache" /var/cache
    mkdir -p /home/$LSL_DESKTOP_USER/.cache
    if [ -d /home/$LSL_DESKTOP_USER/.cache ] && [ "$(ls -A /home/$LSL_DESKTOP_USER/.cache 2>/dev/null)" ]; then
        cp -a /home/$LSL_DESKTOP_USER/.cache/. "$LSL_CACHE_MOUNT/user-cache/" 2>/dev/null || true
    fi
    mount --bind "$LSL_CACHE_MOUNT/user-cache" /home/$LSL_DESKTOP_USER/.cache
    chown -R $LSL_DESKTOP_USER:$LSL_DESKTOP_USER /home/$LSL_DESKTOP_USER/.cache 2>/dev/null || true

    # Nix: ~99% of disk use is /nix/store; keep it on cache.btrfs. State DB stays with the store.
    # User-editable settings: ~/.config/nix/nix.conf (created below if missing).
    mkdir -p /nix/store
    mkdir -p "$LSL_CACHE_MOUNT/nix-store" "$LSL_CACHE_MOUNT/nix-var"
    if [ -d /nix/store ] && [ -z "$(ls -A "$LSL_CACHE_MOUNT/nix-store" 2>/dev/null)" ] && [ "$(ls -A /nix/store 2>/dev/null)" ]; then
        cp -a /nix/store/. "$LSL_CACHE_MOUNT/nix-store/" 2>/dev/null || true
    fi
    mkdir -p /nix/var
    if [ -z "$(ls -A "$LSL_CACHE_MOUNT/nix-var" 2>/dev/null)" ] && [ -d /nix/var ] && [ "$(ls -A /nix/var 2>/dev/null)" ]; then
        cp -a /nix/var/. "$LSL_CACHE_MOUNT/nix-var/" 2>/dev/null || true
    fi
    mount --bind "$LSL_CACHE_MOUNT/nix-store" /nix/store
    mount --bind "$LSL_CACHE_MOUNT/nix-var" /nix/var

    mkdir -p /home/$LSL_DESKTOP_USER/.config/nix
    if [ ! -f /home/$LSL_DESKTOP_USER/.config/nix/nix.conf ]; then
        cat <<'EOF' >/home/$LSL_DESKTOP_USER/.config/nix/nix.conf
# LSL-USB: /nix/store and /nix/var live on cache.btrfs (bind-mounted from /mnt/lsl-cache).
# Edit substituters, experimental-features, trusted-users, etc. here.
EOF
        chown $LSL_DESKTOP_USER:$LSL_DESKTOP_USER /home/$LSL_DESKTOP_USER/.config/nix/nix.conf 2>/dev/null || true
    fi
    chown -R $LSL_DESKTOP_USER:$LSL_DESKTOP_USER /home/$LSL_DESKTOP_USER/.config/nix 2>/dev/null || true

    {
        echo "LSL_HOME_LOWER=$LSL_HOME_LOWER"
        echo "LSL_HOME_UPPER=$LSL_HOME_UPPER"
        echo "LSL_HOME_WORK=$LSL_HOME_WORK"
        echo "LSL_MODE=hdd"
        echo "LSL_CACHE_MOUNT=$LSL_CACHE_MOUNT"
    } > /run/lsl-usb.state
fi

