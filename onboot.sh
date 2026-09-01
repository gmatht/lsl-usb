#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/bin/lsl-common.sh"

# Ensure the desktop user can use multi-user Nix.
# On first boot, the desktop account can appear after this script starts, so retry.
lsl_ensure_nix_users_group_membership() {
    if ! getent group nix-users >/dev/null 2>&1; then
        groupadd --system nix-users 2>/dev/null || true
    fi

    local u
    u="$(lsl_desktop_user)"
    if id -u "$u" >/dev/null 2>&1; then
        usermod -aG nix-users "$u" 2>/dev/null || true
        return 0
    fi
    return 1
}

if ! lsl_ensure_nix_users_group_membership; then
    # Retry in the background: the desktop account can appear after this script
    # starts. onboot.service uses KillMode=process, so this subshell survives
    # the main script exiting (the service is Type=oneshot + RemainAfterExit).
    (
        i=0
        while [ "$i" -lt 180 ]; do # up to ~15 minutes
            sleep 5
            lsl_ensure_nix_users_group_membership && exit 0
            i=$((i + 1))
        done
    ) &
fi

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

# /nix/var can be bind-mounted at runtime; refresh daemon/socket afterwards.
lsl_ensure_nix_daemon() {
    command -v systemctl >/dev/null 2>&1 || return 0

    # Prefer socket activation; start service too for distros without it.
    systemctl enable nix-daemon.socket >/dev/null 2>&1 || true
    systemctl restart nix-daemon.socket >/dev/null 2>&1 || true
    systemctl enable nix-daemon.service >/dev/null 2>&1 || true
    systemctl restart nix-daemon.service >/dev/null 2>&1 || true
}

# Replace the # BEGIN lsl-usb fstab ... # END lsl-usb fstab block in /etc/fstab so
# installers, disk tools, and "mount -a" see stable UUID/path lines for /cdrom,
# Windows drive letters, persist, and (HDD mode) loop-backed /home and cache.
lsl_grow_btrfs_image() {
    # Grow a btrfs image file to $2 MiB if it is currently smaller. Done while the
    # image is unmounted (e.g. at boot), so it always succeeds; online growth of a
    # busy loop-backed FS is unreliable (see bin/lsl-btrfs-growd). The FS itself
    # is resized by the caller after the (re)mount.
    local img="$1" want_mib="$2"
    [ -f "$img" ] || return 0
    local cur want
    cur="$(stat -c %s "$img" 2>/dev/null || echo 0)"
    want="$(( want_mib * 1024 * 1024 ))"
    if [ "$cur" -lt "$want" ] 2>/dev/null; then
        truncate -s "${want_mib}M" "$img" 2>/dev/null || true
    fi
}

lsl_merge_fstab() {
    local fstab=/etc/fstab
    [ -e "$fstab" ] || touch "$fstab"
    local tmp block
    tmp=$(mktemp)
    block=$(mktemp)
    awk '
        /^# BEGIN lsl-usb fstab$/ { skip=1; next }
        /^# END lsl-usb fstab$/ { skip=0; next }
        !skip { print }
    ' "$fstab" > "$tmp"

    lsl_fstab_loop_backing() {
        local src="$1"
        case "$src" in
            /dev/loop*)
                losetup -n -O BACK-FILE "$src" 2>/dev/null || echo ""
                ;;
            *)
                echo ""
                ;;
        esac
    }

    {
        echo "# BEGIN lsl-usb fstab"
        echo "# Maintained by onboot.sh (lsl_merge_fstab); edit only outside this block."

        local src fst uuid mp letter back _lsl_cm
        if mountpoint -q /cdrom 2>/dev/null; then
            src=$(findmnt -n -o SOURCE /cdrom 2>/dev/null)
            fst=$(findmnt -n -o FSTYPE /cdrom 2>/dev/null)
            if [ -n "$src" ] && [ -n "$fst" ]; then
                uuid=$(blkid -s UUID -o value "$src" 2>/dev/null || true)
                if [ -n "$uuid" ]; then
                    echo "UUID=$uuid /cdrom $fst defaults,ro,nofail 0 0"
                else
                    echo "$src /cdrom $fst defaults,ro,nofail 0 0"
                fi
            fi
        fi

        if [ -f /cdrom/persist.btrfs ]; then
            echo "/cdrom/persist.btrfs /persist btrfs loop,compress=zstd:3,nofail 0 0"
        fi

        for letter in {c..z}; do
            mp="/mnt/$letter"
            if mountpoint -q "$mp" 2>/dev/null; then
                src=$(findmnt -n -o SOURCE "$mp" 2>/dev/null)
                fst=$(findmnt -n -o FSTYPE "$mp" 2>/dev/null)
                case "$fst" in
                    ntfs|ntfs3|fuseblk)
                        uuid=$(blkid -s UUID -o value "$src" 2>/dev/null || true)
                        if [ -n "$uuid" ]; then
                            echo "UUID=$uuid $mp ntfs3 defaults,nofail 0 0"
                        else
                            echo "$src $mp ntfs3 defaults,nofail 0 0"
                        fi
                        ;;
                esac
            fi
        done

        if mountpoint -q /home 2>/dev/null; then
            fst=$(findmnt -n -o FSTYPE /home 2>/dev/null)
            src=$(findmnt -n -o SOURCE /home 2>/dev/null)
            if [ "$fst" = "btrfs" ] && [ -n "$src" ]; then
                back=$(lsl_fstab_loop_backing "$src")
                if [ -n "$back" ]; then
                    echo "$back /home btrfs loop,compress=zstd:3,relatime,nofail 0 0"
                fi
            elif [ "$fst" = "overlay" ]; then
                echo "# /home is overlay (LSL USB mode); not expressible as one fstab line."
            fi
        fi

        _lsl_cm="${LSL_CACHE_MOUNT:-/mnt/lsl-cache}"
        if mountpoint -q "$_lsl_cm" 2>/dev/null; then
            fst=$(findmnt -n -o FSTYPE "$_lsl_cm" 2>/dev/null)
            src=$(findmnt -n -o SOURCE "$_lsl_cm" 2>/dev/null)
            if [ "$fst" = "btrfs" ] && [ -n "$src" ]; then
                back=$(lsl_fstab_loop_backing "$src")
                if [ -n "$back" ]; then
                    echo "$back $_lsl_cm btrfs loop,compress=zstd:3,relatime,nofail 0 0"
                fi
            fi
        fi

        echo "# END lsl-usb fstab"
    } > "$block"

    cat "$block" >> "$tmp"
    chmod --reference="$fstab" "$tmp" 2>/dev/null || chmod 644 "$tmp"
    mv -f "$tmp" "$fstab"
    rm -f "$block"
}

# Sourceable for unit tests: define functions but do not run the boot logic
# when sourced (BASH_SOURCE != $0).
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0 2>/dev/null || true
fi

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

touch /run/casper-no-prompt

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
bash /cdrom/bin/mount_all.sh

if [ -x /cdrom/bin/wsl-boot-setup ]; then
    /cdrom/bin/wsl-boot-setup
fi

# --- LSL data dir / home / cache ---
LSL_ENV_FILE=/cdrom/lsl-usb.env
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
    LSL_BASH_LOG=/home/$LSL_DESKTOP_USER/.local/state/lsl/bash.log
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

if lsl_is_usb_mode || [ "${LSL_FALLBACK_USB_HOME:-0}" = "1" ]; then
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
    mount -o loop,compress=zstd:3,relatime "$HOME_IMG" /home
    command -v btrfs >/dev/null 2>&1 && btrfs filesystem resize max /home 2>/dev/null || true

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

# Opt-in: host a flatpak installation on the FAT partition via the
# fat_linux_meta_fs FUSE layer (apps persist without layer rebuilds).
if [ "${LSL_FLATPAK_FAT:-0}" = "1" ] && [ -x /cdrom/bin/lsl-flatpak-fat.sh ]; then
    /cdrom/bin/lsl-flatpak-fat.sh mount || true
fi

lsl_merge_fstab || true
lsl_ensure_nix_daemon || true

# After /home is mounted (config.sh --from-onboot runs earlier, before home setup).
if [ -x /cdrom/bin/config.sh ]; then
    /cdrom/bin/config.sh --install-autostart-warning-only || true
fi

# Optional: overlay-writable view of Windows Steam libraries so Linux Steam can
# use them without modifying the Windows volume. Only set up when the source
# actually exists (otherwise the overlay mount would fail).
mount_steam_overlay() {
    local lower="$1" upper="$2" work="$3" root="$4"
    [ -d "$lower" ] || return 0
    mkdir -p "$upper" "$work" "$root"
    mount -t overlay overlay -olowerdir="$lower",upperdir="$upper",workdir="$work" "$root" 2>/dev/null || true
    chown "$LSL_DESKTOP_USER" "$root" 2>/dev/null || true
}
mkdir -p /tmp/steam /tmp/steam2
mount_steam_overlay "/mnt/d/SteamLibrary" /tmp/steam/upper /tmp/steam/work /tmp/steam/root
mount_steam_overlay "/mnt/c/Program Files (x86)/Steam" /tmp/steam2/upper /tmp/steam2/work /tmp/steam2/root

# Wait for wifi (bounded): wifi.sh may be missing (no saved profiles) or the
# network may be down; don't block boot forever. onboot.service is
# Type=oneshot + RemainAfterExit, so this script should exit when done.
if [ -x /cdrom/wifi.sh ]; then
    tries=0
    until bash /cdrom/wifi.sh; do
        tries=$((tries + 1))
        if [ "$tries" -ge 60 ]; then
            echo "wifi.sh still failing after ~5 minutes; continuing without wifi." >&2
            break
        fi
        sleep 5
    done
else
    echo "No /cdrom/wifi.sh; skipping wifi wait." >&2
fi
echo FINISHED
exit 0
