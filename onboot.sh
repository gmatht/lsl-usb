#!/bin/bash

# Compressed swap in RAM (zram). Uses LSL_ZRAM_MIB from lsl-usb.env (see lsl_load_config).
# 0 = off; unset = 80% of MemTotal (minimum 128 MiB).
lsl_setup_zram() {
    modprobe zram 2>/dev/null || return 0
    swapon --show 2>/dev/null | grep -q zram && return 0

    local mem_kb zram_mib zdev b
    mem_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    case "${LSL_ZRAM_MIB-}" in
        "") zram_mib=$((mem_kb * 80 / 100 / 1024)) ;;
        0) return 0 ;;
        *) zram_mib=$LSL_ZRAM_MIB ;;
    esac
    [ "${zram_mib:-0}" -eq 0 ] 2>/dev/null && return 0
    [ "$zram_mib" -lt 128 ] 2>/dev/null && zram_mib=128

    zdev=
    if command -v zramctl >/dev/null 2>&1; then
        zdev=$(zramctl --find --size "${zram_mib}M" 2>/dev/null) || true
    fi
    if [ -z "$zdev" ] || [ ! -b "$zdev" ]; then
        b=zram0
        zdev=/dev/$b
        [ -b "$zdev" ] || return 0
        echo 1 >"/sys/block/$b/reset" 2>/dev/null || true
        echo $((zram_mib * 1024 * 1024)) >"/sys/block/$b/disksize" 2>/dev/null || return 0
    fi

    mkswap "$zdev" >/dev/null 2>&1 || return 0
    swapon -p 100 "$zdev" 2>/dev/null || true
}

# Keep /cdrom read-only by default; only remount rw when explicitly persisting images.
mount /cdrom/ -o remount,ro 2>/dev/null || true

# Ensure systemd units and PATH tweaks match the tree under /cdrom (not the live ISO alone).
if [ -x /cdrom/bin/config.sh ]; then
    /cdrom/bin/config.sh --from-onboot || true
fi

mount / -o remount

# Remove legacy /etc hooks that append to /cdrom/bash.log (permission denied when /cdrom is ro).
if [ -x /cdrom/bin/clean-old-system-patches.sh ]; then
    /cdrom/bin/clean-old-system-patches.sh || true
fi

sudo touch /run/casper-no-prompt

if [ -f /cdrom/persist.btrfs ]; then
    mkdir -p /persist
    if ! mountpoint -q /persist 2>/dev/null; then
        mount -t btrfs -o loop,compress=zstd:3 /cdrom/persist.btrfs /persist || true
    fi
fi

if mountpoint -q /persist 2>/dev/null; then
    mkdir -p /persist/var-log
    mkdir -p /persist/casper/uproot-logs
    if [ -d /var/log ] && ! mountpoint -q /var/log 2>/dev/null; then
        mount --bind /persist/var-log /var/log || true
    fi
fi

modprobe ntfs3 2>/dev/null || true
mkdir -p /mnt/c /mnt/d
#TODO: Should automatically detect which device has C: and D:
if ! mountpoint -q /mnt/c 2>/dev/null; then
    bash /cdrom/bin/safe_ntfsfix.sh /dev/nvme0n1p3 
    mount -t ntfs3 /dev/nvme0n1p3 /mnt/c 2>/dev/null || true
fi
if ! mountpoint -q /mnt/d 2>/dev/null; then
    #Don't autofix D: until we have tested on C:...
    #bash /cdrom/bin/safe_ntfsfix.sh /dev/nvme1n1p2 
    mount -t ntfs3 /dev/nvme1n1p2 /mnt/d 2>/dev/null || true
fi

if [ -x /cdrom/bin/wsl-boot-setup ]; then
    /cdrom/bin/wsl-boot-setup
fi

# --- LSL data dir / home / cache ---
LSL_ENV_FILE=/cdrom/lsl-usb.env
# shellcheck source=/dev/null
. /cdrom/bin/lsl-common.sh
lsl_load_config

lsl_setup_zram

DATA_DIR="$(lsl_resolve_data_dir)"
mkdir -p "$DATA_DIR" 2>/dev/null || true

lsl_prepare_bash_log() {
    local f="$1"
    mkdir -p "$(dirname "$f")" 2>/dev/null || true
    touch "$f" 2>/dev/null || true
    chmod a+rw "$f" 2>/dev/null || true
    printf '%s\n' "$f" >/run/lsl-bash-log.path
}

# Command log: USB → /persist or tmpfs; HDD → on home.btrfs (not NTFS data dir; not /cdrom).
if lsl_is_usb_mode; then
    if mountpoint -q /persist 2>/dev/null; then
        LSL_BASH_LOG=/persist/var-log/bash.log
    else
        LSL_BASH_LOG=/run/lsl-bash.log
    fi
    lsl_prepare_bash_log "$LSL_BASH_LOG"
else
    LSL_BASH_LOG=/home/mint/.local/state/lsl/bash.log
fi

if ! grep -q "LSL_BASH_LOG_HOOK" /etc/bash.bashrc 2>/dev/null; then
cat >> /etc/bash.bashrc <<'EOF'
# LSL_BASH_LOG_HOOK
__lsl_log_cmd() {
    local ec="$?"
    local cmd logf
    logf="$(cat /run/lsl-bash-log.path 2>/dev/null)"
    [ -z "$logf" ] && logf=/tmp/lsl-bash.log
    cmd="$(history 1 | sed 's/^ *[0-9]\+ *//')"
    printf '%s\t%s\t%s\t%s\n' "$BASHPID" "$USER" "$PWD" "$cmd" >> "$logf" 2>/dev/null || true
    return "$ec"
}
case ";${PROMPT_COMMAND:-};" in
    *";__lsl_log_cmd;"*) ;;
    *) PROMPT_COMMAND="__lsl_log_cmd${PROMPT_COMMAND:+;${PROMPT_COMMAND}}";;
esac
EOF
fi

export LSL_HOME_LOWER=/run/lsl-home-lower
export LSL_HOME_UPPER=/run/lsl-home-overlay/upper
export LSL_HOME_WORK=/run/lsl-home-overlay/work
export LSL_HOME_TMPFS=/run/lsl-home-overlay
export LSL_CACHE_MOUNT=/mnt/lsl-cache

if lsl_is_usb_mode; then
    mkdir -p "$LSL_HOME_TMPFS" "$LSL_HOME_UPPER" "$LSL_HOME_WORK" "$LSL_HOME_LOWER"
    if ! mountpoint -q "$LSL_HOME_TMPFS" 2>/dev/null; then
        mount -t tmpfs -o "size=${LSL_HOME_TMPFS_MIB:-2048}M" tmpfs "$LSL_HOME_TMPFS"
    fi
    mkdir -p "$LSL_HOME_UPPER" "$LSL_HOME_WORK" "$LSL_HOME_LOWER"
    mount /cdrom/home.sfs "$LSL_HOME_LOWER"
    mount -t overlay overlay -o "lowerdir=${LSL_HOME_LOWER}/,upperdir=${LSL_HOME_UPPER},workdir=${LSL_HOME_WORK}" /home
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
    if [ ! -f "$HOME_IMG" ]; then
        truncate -s "${LSL_HOME_BTRFS_MIB:-4096}M" "$HOME_IMG"
        mkfs.btrfs -f "$HOME_IMG" >/dev/null
    fi
    if [ ! -f "$CACHE_IMG" ]; then
        truncate -s "${LSL_CACHE_BTRFS_MIB:-2048}M" "$CACHE_IMG"
        mkfs.btrfs -f "$CACHE_IMG" >/dev/null
    fi
    mount -o loop,compress=zstd:3,relatime "$HOME_IMG" /home
    sudo usermod -aG nix-users mint ||
	sudo usermod -aG nix-users ubuntu

    lsl_prepare_bash_log "$LSL_BASH_LOG"
    mkdir -p "$LSL_CACHE_MOUNT"
    mount -o loop,compress=zstd:3,relatime "$CACHE_IMG" "$LSL_CACHE_MOUNT"
    mkdir -p "$LSL_CACHE_MOUNT/var-cache" "$LSL_CACHE_MOUNT/user-cache"
    if [ -d /var/cache ] && [ "$(ls -A /var/cache 2>/dev/null)" ]; then
        cp -a /var/cache/. "$LSL_CACHE_MOUNT/var-cache/" 2>/dev/null || true
    fi
    mount --bind "$LSL_CACHE_MOUNT/var-cache" /var/cache
    mkdir -p /home/mint/.cache
    if [ -d /home/mint/.cache ] && [ "$(ls -A /home/mint/.cache 2>/dev/null)" ]; then
        cp -a /home/mint/.cache/. "$LSL_CACHE_MOUNT/user-cache/" 2>/dev/null || true
    fi
    mount --bind "$LSL_CACHE_MOUNT/user-cache" /home/mint/.cache
    chown -R mint:mint /home/mint/.cache 2>/dev/null || true

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

    mkdir -p /home/mint/.config/nix
    if [ ! -f /home/mint/.config/nix/nix.conf ]; then
        cat <<'EOF' >/home/mint/.config/nix/nix.conf
# LSL-USB: /nix/store and /nix/var live on cache.btrfs (bind-mounted from /mnt/lsl-cache).
# Edit substituters, experimental-features, trusted-users, etc. here.
EOF
        chown mint:mint /home/mint/.config/nix/nix.conf 2>/dev/null || true
    fi
    chown -R mint:mint /home/mint/.config/nix 2>/dev/null || true

    {
        echo "LSL_HOME_LOWER=$LSL_HOME_LOWER"
        echo "LSL_HOME_UPPER=$LSL_HOME_UPPER"
        echo "LSL_HOME_WORK=$LSL_HOME_WORK"
        echo "LSL_MODE=hdd"
        echo "LSL_CACHE_MOUNT=$LSL_CACHE_MOUNT"
    } > /run/lsl-usb.state
fi

# After /home is mounted (config.sh --from-onboot runs earlier, before home setup).
if [ -x /cdrom/bin/config.sh ]; then
    /cdrom/bin/config.sh --install-autostart-warning-only || true
fi

mkdir -p /tmp/steam /tmp/steam2
cd /tmp/steam/ && mkdir -p upper work root
cd /tmp/steam2/ && mkdir -p upper work root

mount -t overlay overlay -olowerdir=/mnt/d/SteamLibrary/,upperdir=/tmp/steam/upper,workdir=/tmp/steam/work /tmp/steam/root || true
mount -t overlay overlay -olowerdir='/mnt/c/Program Files (x86)/Steam',upperdir=/tmp/steam2/upper,workdir=/tmp/steam2/work /tmp/steam2/root || true

chown mint /tmp/steam/root
chown mint /tmp/steam2/root

until bash /cdrom/wifi.sh
do
    sleep 1
done
echo FINISHED

while true; do sleep 99999; done
