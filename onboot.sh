#!/bin/bash
# Keep /cdrom read-only by default; only remount rw when explicitly persisting images.
mount /cdrom/ -o remount,ro 2>/dev/null || true

mount / -o remount

sudo touch /run/casper-no-prompt

# Enable global command logging to /cdrom/bash.log once.
if ! grep -q "LSL_BASH_LOG_HOOK" /etc/bash.bashrc 2>/dev/null; then
cat >> /etc/bash.bashrc <<'EOF'
# LSL_BASH_LOG_HOOK
__lsl_log_cmd() {
    local ec="$?"
    local cmd
    cmd="$(history 1 | sed 's/^ *[0-9]\+ *//')"
    printf '%s\t%s\t%s\t%s\n' "$BASHPID" "$USER" "$PWD" "$cmd" >> /cdrom/bash.log 2>/dev/null || true
    return "$ec"
}
case ";${PROMPT_COMMAND:-};" in
    *";__lsl_log_cmd;"*) ;;
    *) PROMPT_COMMAND="__lsl_log_cmd${PROMPT_COMMAND:+;${PROMPT_COMMAND}}";;
esac
EOF
fi

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
if ! mountpoint -q /mnt/c 2>/dev/null; then
    mount -t ntfs3 /dev/nvme0n1p3 /mnt/c 2>/dev/null || true
fi
if ! mountpoint -q /mnt/d 2>/dev/null; then
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

DATA_DIR="$(lsl_resolve_data_dir)"
mkdir -p "$DATA_DIR" 2>/dev/null || true

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
    {
        echo "LSL_HOME_LOWER=$LSL_HOME_LOWER"
        echo "LSL_HOME_UPPER=$LSL_HOME_UPPER"
        echo "LSL_HOME_WORK=$LSL_HOME_WORK"
        echo "LSL_MODE=hdd"
        echo "LSL_CACHE_MOUNT=$LSL_CACHE_MOUNT"
    } > /run/lsl-usb.state
fi

mkdir -p /tmp/steam /tmp/steam2
cd /tmp/steam/ && mkdir -p upper work root
cd /tmp/steam2/ && mkdir -p upper work root

mount -t overlay overlay -olowerdir=/mnt/d/SteamLibrary/,upperdir=/tmp/steam/upper,workdir=/tmp/steam/work /tmp/steam/root || true
mount -t overlay overlay -olowerdir='/mnt/c/Program Files (x86)/Steam',upperdir=/tmp/steam2/upper,workdir=/tmp/steam2/work /tmp/steam2/root || true

chown mint /tmp/steam/root
chown mint /tmp/steam2/root

# Expose writable POSIX metadata view of /cdrom/posix at /x.
# Quick permissive mode: allow_other + broad permissions for mint write access.
mount /cdrom/ -o remount,rw 2>/dev/null || true
mkdir -p /cdrom/posix /x
umount /x 2>/dev/null || true
if [ -x /cdrom/bin/fat-linux-meta-fs ]; then
    /cdrom/bin/fat-linux-meta-fs /cdrom/posix /x --allow-other || true
fi
chmod 0777 /cdrom/posix /x 2>/dev/null || true

until bash /cdrom/wifi.sh
do
    sleep 1
done
echo FINISHED

while true; do sleep 99999; done
