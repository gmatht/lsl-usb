#!/bin/bash
# Mount the live user's /home: RAM-only (Boot to RAM, no persistence, or the
# persistence pane's "None"), a tmpfs-overlay over the per-distro home.sfs
# (squashfs backend), a loop-mounted home.btrfs/cache.btrfs pair (btrfs backend),
# or a F2FS partition holding the overlay upper (f2fs backend).
#
# The backend is chosen by LSL_PERSIST in lsl-usb.env; see
# DESIGN-PERSISTENCE-PANE.md s1.2 and lsl_persist_backend(). Default is
# squashfs, which is exactly what this script did before the knob existed.
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

# Which persistence backend the user chose (persistence pane / lsl-usb.env).
# Read BEFORE the branch below: `none` means the RAM-only path, `btrfs` and
# `f2fs` mean the data-dir path even when that dir is on the stick, and only
# `squashfs` keeps the old "is the data dir on the stick?" question.
LSL_PERSIST_BACKEND="$(lsl_persist_backend)"

# Adopt a pre-per-distro home/cache image (first boot after this change).
lsl_home_migrate_legacy
HOME_SFS="$(lsl_home_sfs_path)"

# HDD mode's data dir lives on a Windows volume (/mnt/c/...); mount the drives
# here (idempotent) so this unit can run before onboot.sh does its own mount.
# Install any staged hivex .debs first: mount_all.sh needs hivexregedit, the
# base image lacks it, and this early install is what stops a stock first boot
# from falling back to a tmpfs overlay (WHYFAIL9 / FRAGILE_HOME.md).
if [ -r /cdrom/bin/mount_all.sh ]; then
    lsl_ensure_hivex_tools || true
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
if ! lsl_is_usb_mode && ! lsl_data_dir_is_writable; then
    echo "lsl: HDD data dir $DATA_DIR not yet writable; retrying drive mount..." >&2
    bash /cdrom/bin/mount_all.sh 2>/dev/null || true
    DATA_DIR="$(lsl_resolve_data_dir)"
    mkdir -p "$DATA_DIR" 2>/dev/null || true
    # Wait for a WRITABLE mount, not merely a persistent one. The ntfs3 rw
    # refusal ("Can't mount, would change RO state") clears about a second
    # later, and the boot journal shows mount_all landing the volume READ-ONLY
    # first; accepting that ro landing declared usb-fallback and threw the
    # whole session's /home away, even though the rw mount succeeded moments
    # later. Bounded so a genuinely unwritable store still falls back honestly.
    _lsl_rw_waits="${LSL_RW_WAIT_STEPS:-15}"
    _lsl_rw_delay="${LSL_RW_WAIT_DELAY:-1}"
    _lsl_rw_i=0
    while [ "$_lsl_rw_i" -lt "$_lsl_rw_waits" ] && ! lsl_data_dir_is_writable; do
        sleep "$_lsl_rw_delay"
        _lsl_rw_i=$((_lsl_rw_i + 1))
        # Re-drive the mount every few tries: the journal replay that unblocks
        # the rw mount needs the volume to be retried, not just waited on.
        if [ $((_lsl_rw_i % 3)) -eq 0 ]; then
            bash /cdrom/bin/mount_all.sh 2>/dev/null || true
        fi
        DATA_DIR="$(lsl_resolve_data_dir)"
    done
    if lsl_data_dir_is_writable; then
        echo "lsl: data dir now writable on a persistent volume: $DATA_DIR" >&2
    else
        echo "lsl: WARNING: data dir still not writable after ${_lsl_rw_waits} tries; using a temporary tmpfs-overlay /home for this boot (changes lost on reboot)." >&2
        LSL_FALLBACK_USB_HOME=1
    fi
fi

# Boot-to-RAM "(no persistence)" entry passes lsl_home=tmpfs: give the live
# user a RAM-only home and touch no persistence at all. Building a valid
# /home/<user> (owned by the user, seeded from /etc/skel) is required -
# LightDM's autologin session dies without it and drops back to the greeter.
#
# LSL_PERSIST=none reaches the SAME branch from the persistence pane: both mean
# "nothing survives a reboot", and keeping them on one code path means the RAM
# home cannot drift between the two entry points.
LSL_EPHEMERAL_HOME=0
grep -q 'lsl_home=tmpfs' "${LSL_CMDLINE_FILE:-/proc/cmdline}" 2>/dev/null && LSL_EPHEMERAL_HOME=1
[ "$LSL_PERSIST_BACKEND" = "none" ] && LSL_EPHEMERAL_HOME=1

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
        if [ "$LSL_PERSIST_BACKEND" = "none" ]; then
            echo "lsl: RAM-only home (persistence = none); changes are lost on reboot." >&2
        else
            echo "lsl: RAM-only home (Boot to RAM, no persistence); changes are lost on reboot." >&2
        fi
    else
        echo "lsl: could not mount tmpfs on /home; keeping the live home." >&2
    fi
    umount /run/lsl-live-home 2>/dev/null || true
    rmdir /run/lsl-live-home 2>/dev/null || true
    echo "LSL_MODE=ram" > /run/lsl-usb.state
elif lsl_uses_overlay_backend; then
    mkdir -p "$LSL_HOME_TMPFS" "$LSL_HOME_UPPER" "$LSL_HOME_WORK" "$LSL_HOME_LOWER"
    if ! mountpoint -q "$LSL_HOME_TMPFS" 2>/dev/null; then
        mount -t tmpfs -o "size=${LSL_HOME_TMPFS_MIB:-2048}M" tmpfs "$LSL_HOME_TMPFS"
    fi
    mkdir -p "$LSL_HOME_UPPER" "$LSL_HOME_WORK" "$LSL_HOME_LOWER"

    # ---- f2fs backend: the overlay upper lives on the F2FS partition --------
    # Everything above this point is identical to the squashfs backend - same
    # tmpfs for work/, same home.sfs lower. Only the upper differs: instead of a
    # directory that vanishes at reboot, it is bind-mounted from the persistent
    # partition. That single change is what makes /home survive a reboot.
    #
    # Every failure here degrades to the tmpfs upper rather than to no /home:
    # a missing partition must not mean a missing home.
    _lsl_f2fs_ok=0
    if [ "$LSL_PERSIST_BACKEND" = "f2fs" ]; then
        _lsl_f2fs_dev=""
        if [ -b "/dev/disk/by-label/$LSL_PERSIST_LABEL" ]; then
            _lsl_f2fs_dev="/dev/disk/by-label/$LSL_PERSIST_LABEL"
        elif command -v blkid >/dev/null 2>&1; then
            _lsl_f2fs_dev="$(blkid -L "$LSL_PERSIST_LABEL" 2>/dev/null || true)"
        fi
        if [ -z "$_lsl_f2fs_dev" ] || [ ! -b "$_lsl_f2fs_dev" ]; then
            echo "lsl: WARNING: persistence=f2fs but no '$LSL_PERSIST_LABEL' partition found;" >&2
            echo "       falling back to a RAM upper (/home will NOT persist)." >&2
            echo "       Create and format one with bin/lsl-f2fs-provision." >&2
        elif ! grep -qw f2fs /proc/filesystems 2>/dev/null; then
            echo "lsl: WARNING: this kernel has no f2fs driver; using a RAM upper." >&2
        elif ! mount -t f2fs "$_lsl_f2fs_dev" "$LSL_PERSIST_MNT" 2>/dev/null; then
            echo "lsl: WARNING: could not mount $_lsl_f2fs_dev at $LSL_PERSIST_MNT;" >&2
            echo "       using a RAM upper (/home will NOT persist this boot)." >&2
        else
            mkdir -p "$LSL_PERSIST_MNT/upper" 2>/dev/null || true
            # Bind the persistent upper over the tmpfs one. work/ stays on tmpfs
            # deliberately: overlayfs requires upper and work on the same
            # filesystem, so the bind gives us that.
            if mount --bind "$LSL_PERSIST_MNT/upper" "$LSL_HOME_UPPER" 2>/dev/null; then
                _lsl_f2fs_ok=1
                echo "lsl: persistent home upper on $_lsl_f2fs_dev ($LSL_PERSIST_MNT/upper)." >&2
            else
                echo "lsl: WARNING: could not bind the f2fs upper; using a RAM upper." >&2
                umount "$LSL_PERSIST_MNT" 2>/dev/null || true
            fi
        fi
    fi

    if [ ! -f $HOME_SFS ]; then
        # First boot of a Windows-installed image: seed home.sfs from the live
        # /home (keeps the mint user's login home) so the USB-mode overlay works.
        mount /cdrom -o remount,rw 2>/dev/null || true
        echo "Creating $HOME_SFS from live /home (first boot)..."
        if command -v mksquashfs >/dev/null 2>&1; then
            sz="$(du -sm /home 2>/dev/null | awk '{print $1}')"; sz="${sz:-0}"
            need_mib="$(( sz + 64 ))"
            if lsl_ensure_cdrom_space "$need_mib"; then
                if mksquashfs /home $HOME_SFS -comp zstd >/dev/null 2>&1; then
                    echo "Created $HOME_SFS ($(du -h $HOME_SFS 2>/dev/null | cut -f1))."
                else
                    echo "ERROR: mksquashfs failed while creating $HOME_SFS - /home will NOT persist." >&2
                    echo "       Check that /cdrom is writable and has ~${need_mib} MiB free; reboot and retry." >&2
                fi
            else
                echo "ERROR: only $(lsl_cdrom_free_mib) MiB free on /cdrom; need ~${need_mib} MiB - /home.sfs NOT created." >&2
                echo "       USB-mode home persistence will not work until space is freed (or a larger stick is used)." >&2
            fi
        else
            echo "ERROR: mksquashfs not found - $HOME_SFS NOT created; USB-mode home will not persist." >&2
        fi
        mount /cdrom -o remount,ro 2>/dev/null || true
    fi
    # Only stack the overlay when the home.sfs lower really mounted: a failed
    # mount leaves $LSL_HOME_LOWER an empty dir, and the overlay would then
    # expose an EMPTY /home (the live user's home disappears; autologin falls
    # back to the greeter).
    if mount $HOME_SFS "$LSL_HOME_LOWER"; then
        mount -t overlay overlay -o "lowerdir=${LSL_HOME_LOWER}/,upperdir=${LSL_HOME_UPPER},workdir=${LSL_HOME_WORK}" /home
    else
        echo "lsl: could not mount $HOME_SFS; keeping the live /home (no persistence this boot)." >&2
    fi
    # Even a per-distro home image can lack THIS boot's user home (a legacy
    # image adopted from another distro, or one created before the user
    # existed); autologin dies without it, so guarantee it like the RAM branch.
    lsl_ensure_user_home /home
    # A fallback tmpfs overlay (HDD data dir not persistent yet) records its own
    # mode so downstream consumers can tell it apart from a real USB stick: both
    # have a RAM upper layer, but only the fallback is a transient accident.
    #
    # `f2fs` is recorded separately from `usb` even though the overlay shape is
    # identical, because they differ in the property that matters to every
    # consumer: a usb upper is RAM (changes die at reboot) and an f2fs upper is
    # NOT (they survive). lsl_effective_home_is_usb() must therefore NOT claim an
    # f2fs home is stick-persistable in the same way - a caller that flushes the
    # upper back to home.sfs would fight the real persistence.
    _lsl_state_mode=usb
    if [ "${LSL_FALLBACK_USB_HOME:-0}" = "1" ]; then
        _lsl_state_mode=usb-fallback
    fi
    if [ "$_lsl_f2fs_ok" = "1" ]; then
        _lsl_state_mode=f2fs
    fi
    {
        echo "LSL_HOME_LOWER=$LSL_HOME_LOWER"
        echo "LSL_HOME_UPPER=$LSL_HOME_UPPER"
        echo "LSL_HOME_WORK=$LSL_HOME_WORK"
        echo "LSL_MODE=$_lsl_state_mode"
        [ "$_lsl_f2fs_ok" = "1" ] && echo "LSL_PERSIST_MOUNT=$LSL_PERSIST_MNT"
        true
    } > /run/lsl-usb.state
else
    # HDD path: loop-backed home.btrfs + cache.btrfs on the data dir. Reached
    # when the data dir is not stick-resident (the original trigger) OR when the
    # pane chose the btrfs backend explicitly - btrfs on a stick is the same
    # machinery pointed at a different directory, so there is nothing to branch
    # on beyond which directory lsl_*_btrfs_path resolves to.
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

    # As in the USB branch: even a per-distro home.btrfs can lack this boot's
    # user home (legacy adoption, or a home created before the user). Autologin
    # dies without it, so guarantee it on every persistent-home path.
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

