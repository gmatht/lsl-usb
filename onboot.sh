#!/bin/bash
# Keep /cdrom read-only by default; only remount rw when explicitly persisting images.
mount /cdrom/ -o remount,ro 2>/dev/null || true
#mount /cdrom/home.btrfs /home/ -t btrfs -o relatime,compress=zstd:3
#mount -t btrfs -o loop,relatime,compress=zstd:3 /cdrom/home.btrfs /rofs/home

mount / -o remount

#mkdir /tmp/cache; sudo mount --bind /tmp/cache /home/mint/.cache
#cd /cdrom
#cp 90-NM* /etc/netplan

#Stop remove boot installation hardware prompt.
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

# Mount persistence image only if it already exists.
if [ -f /cdrom/persist.btrfs ]; then
    mkdir -p /persist
    if ! mountpoint -q /persist 2>/dev/null; then
        mount -t btrfs -o loop,compress=zstd:3 /cdrom/persist.btrfs /persist || true
    fi
fi

# If persistence is mounted, redirect high-churn logs off VFAT.
if mountpoint -q /persist 2>/dev/null; then
    mkdir -p /persist/var-log
    mkdir -p /persist/casper/uproot-logs

    # Persist system logs (reduces VFAT writes).
    if [ -d /var/log ] && ! mountpoint -q /var/log 2>/dev/null; then
        mount --bind /persist/var-log /var/log || true
    fi
fi

# Mount Windows partitions WSL-style (/mnt/c, /mnt/d) and detect WSL distros
modprobe ntfs3 2>/dev/null || true
mkdir -p /mnt/c
if ! mountpoint -q /mnt/c 2>/dev/null; then
    mount -t ntfs3 /dev/nvme0n1p3 /mnt/c 2>/dev/null || true
fi

if [ -x /cdrom/bin/wsl-boot-setup ]; then
    /cdrom/bin/wsl-boot-setup
fi

mkdir -p /tmp/steam ; cd /tmp/steam/ && mkdir upper && mkdir work && mkdir root
mkdir -p /tmp/steam2 ; cd /tmp/steam2/ && mkdir upper && mkdir work && mkdir root
mkdir -p /tmp/home/lower ; cd /tmp/home && mkdir upper && mkdir work && mkdir root

mount /cdrom/home.sfs /tmp/home/lower
mount -t overlay overlay -olowerdir=/tmp/home/lower/,upperdir=/tmp/home/upper,workdir=/tmp/home/work /home
mount -t overlay overlay -olowerdir=/mnt/d/SteamLibrary/,upperdir=/tmp/steam/upper,workdir=/tmp/steam/work /tmp/steam/root
mount -t overlay overlay -olowerdir='/mnt/c/Program Files (x86)/Steam',upperdir=/tmp/steam2/upper,workdir=/tmp/steam2/work /tmp/steam2/root

chown mint /tmp/steam/root
chown mint /tmp/steam2/root

until bash /cdrom/wifi.sh
do
	sleep 1
done
echo FINISHED

#Stop Systemd breaking mounts.
while true; do sleep 99999; done



