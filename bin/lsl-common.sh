#!/bin/bash
# Shared LSL-USB config and USB vs HDD mode detection.
# shellcheck disable=SC1090,SC1091

LSL_ENV_FILE="${LSL_ENV_FILE:-/cdrom/lsl-usb.env}"

# Read LSL_ENV_FILE defensively.
#
# The env file lives on the FAT stick, which users edit from Windows, so it can
# arrive with CRLF line endings. Sourcing that raw gives values with a trailing
# CR: `LSL_DATA_DIR=/mnt/c/Users/lsl-usb\r` matches neither the /cdrom nor the
# /persist prefix in lsl_is_usb_mode, and findmnt cannot resolve the path, so
# onboot.sh concluded the data dir was not persistent and fell back to a
# volatile tmpfs /home ("persistent home not mounted"). Normalise CRLF (and a
# leading BOM) before sourcing, and never let a stale copy shadow the stick:
# prefer /cdrom/lsl-usb.env when it exists, then $HOME/lsl-usb.env.
lsl_env_file() {
    local f
    # An explicit LSL_ENV_FILE always wins - the caller asked for that file, and
    # re-probing after a load would let another candidate clobber it.
    f="${LSL_ENV_FILE:-}"
    if [ -n "$f" ] && [ -f "$f" ]; then
        printf '%s\n' "$f"
        return 0
    fi
    # Otherwise prefer the stick's file over any stale copy in the live $HOME,
    # which used to shadow it (a $HOME copy then silently supplied the wrong
    # data dir). LSL_CDROM override (same convention as config.sh) keeps this
    # testable off-stick; default is the live /cdrom mount.
    for f in "${LSL_CDROM:-/cdrom}/lsl-usb.env" "${HOME:-}/lsl-usb.env"; do
        [ -n "$f" ] && [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
    done
    return 1
}

lsl_load_config() {
    local f tmp rc
    # Remember a data dir the caller set explicitly: sourcing the env file must
    # not clobber it. Without this, every call to lsl_resolve_data_dir (which
    # calls us) would reload LSL_DATA_DIR from the env file and silently discard
    # a value the caller had just set - the tests and any script that overrides
    # LSL_DATA_DIR for one call depend on it sticking.
    local preset="${LSL_DATA_DIR:-}"
    if f="$(lsl_env_file)"; then
        # Source in THIS shell: a process substitution (`. <(sed ...)`) runs in
        # a subshell and would discard every assignment. Normalise a
        # Windows-edited file (CRLF, BOM) into a private temp copy first.
        tmp="$(mktemp 2>/dev/null || echo /tmp/lsl-env.$$)"
        if sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' "$f" >"$tmp" 2>/dev/null; then
            # shellcheck source=/dev/null
            . "$tmp"
            rc=$?
        else
            rc=1
        fi
        rm -f "$tmp"
        if [ "$rc" -ne 0 ]; then
            echo "lsl: WARNING: could not read env file $f" >&2
        fi
        LSL_ENV_FILE="$f"
        export LSL_ENV_FILE
        [ -n "$preset" ] && LSL_DATA_DIR="$preset"
    fi
    # Belt and braces: trim any stray CR that survived. The env file is already
    # normalised above, but an export inherited from the environment can still
    # carry one. NOTE: do not write this as "${VAR%$'\r'}" - verified that such
    # an expansion inside this function silently matches the empty string and
    # leaves the value untouched (the same expression at top level works). tr is
    # unambiguous.
    LSL_DATA_DIR="$(printf '%s' "${LSL_DATA_DIR:-}" | tr -d '\r')"
    : "${LSL_DATA_DIR:=/mnt/c/Users/lsl-usb}"
    : "${LSL_HOME_IDLE_SEC:=300}"
    : "${LSL_HOME_BTRFS_MIB:=4096}"
    : "${LSL_CACHE_BTRFS_MIB:=2048}"
    : "${LSL_BTRFS_GROW_CHUNK_MIB:=1024}"
    : "${LSL_BTRFS_MIN_FREE_PCT:=10}"
    : "${LSL_BTRFS_GROW_INTERVAL_SEC:=60}"
    : "${LSL_HOME_TMPFS_MIB:=2048}"
    : "${LSL_RECLAIM_WIN_SWAP:=0}"
    export LSL_DATA_DIR LSL_HOME_IDLE_SEC LSL_HOME_BTRFS_MIB LSL_CACHE_BTRFS_MIB
    export LSL_BTRFS_GROW_CHUNK_MIB LSL_BTRFS_MIN_FREE_PCT LSL_BTRFS_GROW_INTERVAL_SEC LSL_HOME_TMPFS_MIB LSL_RECLAIM_WIN_SWAP
}

lsl_desktop_user() {
    # The live-session desktop user (mint on Mint, zorin on Zorin, ubuntu on
    # Ubuntu, ...). UID 1000 is the standard first desktop user on
    # Ubuntu-family live systems; fall back to the first /home entry.
    #
    # NEVER invent a username. This used to end with `[ -n "$u" ] || u="mint"`,
    # which turned "there is no desktop user in this context" into "write to
    # /home/mint". That is exactly what happened when config.sh ran INSIDE
    # uproot's chroot (WHYFAIL13): the chroot has no uid 1000 and an empty
    # /home, so the fallback fired, every $HOME-targeted install silently
    # targeted a nonexistent user, and the terminal pin was never written. An
    # empty result is the honest answer - callers must skip (and say so) rather
    # than write into a guessed home.
    local u=""
    u="$(getent passwd 1000 2>/dev/null | cut -d: -f1 || true)"
    [ -n "$u" ] || u="$(ls -1 /home 2>/dev/null | head -n1 || true)"
    printf '%s\n' "$u"
}

# The desktop user, but consulted in the HOST context: loginctl first (the
# authoritative "who is actually logged into a graphical session"), then the
# uid-1000 / /home heuristics. This is the resolver for anything that must
# write into a real user's $HOME from a root script - and it works from a
# chroot-side caller too only if loginctl can reach the host's /run, which it
# normally cannot; hence lsl-firstboot.sh (host, as root) is the intended user.
# Prints nothing when no desktop user can be found.
lsl_desktop_user_for_session() {
    local s u dtype
    if command -v loginctl >/dev/null 2>&1; then
        for s in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
            dtype="$(loginctl show-session -p Type --value "$s" 2>/dev/null || true)"
            case "$dtype" in x11|wayland) ;; *) continue ;; esac
            u="$(loginctl show-session -p Name --value "$s" 2>/dev/null || true)"
            [ -n "$u" ] && [ "$u" != root ] || continue
            printf '%s\n' "$u"
            return 0
        done
    fi
    lsl_desktop_user
}

# Ensure the desktop user's home exists under HOME_ROOT, seeded from skel when
# missing or empty, and owned by the user. A persistent /home is keyed to
# LSL_DATA_DIR, not to the live distro, so an image seeded by a different live
# user (e.g. an Ubuntu stick's home.btrfs holding /home/ubuntu, reused on a Mint
# stick whose user is /home/mint) leaves LIGHTDM's autologin user without a home
# - the session dies and drops back to the greeter. The RAM-home branch rebuilds
# the user's home every boot; every persistent-home path must guarantee it too.
# $1 = home root (default /home), $2 = user (default $LSL_DESKTOP_USER),
# $3 = skel dir (default /etc/skel; overridable for tests).
lsl_ensure_user_home() {
    local root="${1:-/home}" user="${2:-${LSL_DESKTOP_USER:-}}" skel="${3:-/etc/skel}"
    [ -n "$user" ] || return 0
    local h="$root/$user"
    local created=0
    if [ ! -d "$h" ]; then
        mkdir -p "$h" 2>/dev/null || return 0
        created=1
    fi
    if [ "$created" = "1" ] || [ -z "$(ls -A "$h" 2>/dev/null)" ]; then
        if [ -d "$skel" ]; then
            cp -a "$skel/." "$h/" 2>/dev/null || true
        fi
        echo "lsl: created $h for the live user $user" >&2
    fi
    chown -R "$user:$user" "$h" 2>/dev/null || chown -R "$user" "$h" 2>/dev/null || true
    return 0
}

lsl_prepare_bash_log() {
    local f="$1"
    mkdir -p "$(dirname "$f")" 2>/dev/null || true
    touch "$f" 2>/dev/null || true
    chmod a+rw "$f" 2>/dev/null || true
    printf '%s\n' "$f" >/run/lsl-bash-log.path
}


lsl_resolve_data_dir() {
    lsl_load_config
    local d
    d="${LSL_DATA_DIR:-/mnt/c/Users/lsl-usb}"
    # Trim CR/whitespace: a CRLF env file would otherwise put the trailing CR
    # into the path and send lsl_is_usb_mode down the wrong branch. (tr, not
    # "${d%$'\r'}": see the note in lsl_load_config.)
    d="$(printf '%s' "$d" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -n "$d" ] || d=/mnt/c/Users/lsl-usb
    mkdir -p "$d" 2>/dev/null || true
    if [ -d "$d" ]; then
        readlink -f "$d" 2>/dev/null || echo "$d"
    else
        echo "$d"
    fi
}

lsl_is_usb_mode() {
    local p
    p="$(lsl_resolve_data_dir)"
    case "$p" in
        /cdrom|/cdrom/*|/persist|/persist/*) return 0 ;;
        *) return 1 ;;
    esac
}

# The mode that /home was ACTUALLY mounted with this boot, read from the state
# file lsl-mount-home.sh wrote. This is authoritative and must be preferred over
# a fresh lsl_is_usb_mode resolve by anything that persists /home.
#
# Why: when the HDD data dir is not on a persistent volume yet (first boot,
# before hivex-tools mount /mnt/c), lsl-mount-home.sh falls back to a tmpfs
# overlay and records LSL_MODE=usb. Later in that same boot the data dir can
# resolve as persistent again (the mounts catch up), so lsl_is_usb_mode returns
# false while /home is in fact a tmpfs-overlay whose upper layer is RAM. uphome
# then took the HDD branch, ran a no-op btrfs sync, and the first-boot home
# changes were lost on reboot.
#
# Prints one of: ram | usb | usb-fallback | hdd | (empty when unknown).
lsl_effective_home_mode() {
    local f mode
    f="$(lsl_state_file)"
    if [ -r "$f" ]; then
        # tr -d '\r': the state file is written under /run on the live system,
        # but a stick-restored copy can carry CRLF (same class of bug as the
        # CRLF env file that once broke mode detection - see lsl_load_config).
        mode="$(sed -n 's/^LSL_MODE=//p' "$f" 2>/dev/null | tr -d '\r' | tail -n1)"
    fi
    # Fall back to the live mount when there is no state file: a /home that is
    # literally tmpfs can only be the RAM-only ("no persistence") branch.
    if [ -z "${mode:-}" ]; then
        if [ "$(findmnt -n -o FSTYPE --target /home 2>/dev/null || true)" = "tmpfs" ]; then
            mode=ram
        fi
    fi
    printf '%s\n' "${mode:-}"
}

# True when /home is a REAL USB-stick overlay (persistable to home.sfs). A
# usb-fallback tmpfs overlay has the same layout but its upper layer is RAM, so
# it is NOT a stick. With no state file, fall back to the old prediction so
# pre-fix sticks keep working.
lsl_effective_home_is_usb() {
    local m
    m="$(lsl_effective_home_mode)"
    if [ -n "$m" ]; then [ "$m" = usb ]; else lsl_is_usb_mode; fi
}

# True when /home is a loop-backed btrfs on the data dir (HDD mode) - the only
# mode with home.btrfs/cache.btrfs to grow or sync. ram/usb/usb-fallback are not.
lsl_effective_home_is_hdd() {
    local m
    m="$(lsl_effective_home_mode)"
    if [ -n "$m" ]; then [ "$m" = hdd ]; else ! lsl_is_usb_mode; fi
}

# Refresh EVERY loop device currently attached to the image $1 so the kernel
# picks up a grown file size. No-op when nothing is attached. Never fails the
# caller.
#
# The kernel caches a loop device's capacity at attach time: extending the
# backing file leaves attached loops stale, and a later `btrfs filesystem resize
# max` then silently no-ops (exit 0, no growth). Tested: partprobe does NOT fix
# this (it only re-reads partition tables); `losetup -c` does.
#
# Iterates all attached loops, not just the first: a stale loop left over from a
# crashed boot keeps the old size cached, and refreshing only one device misses
# it. readlink first, because a symlinked backing path is exactly what makes a
# bare `losetup -j` match nothing.
#
# A kernel that silently ignores `losetup -c` leaves no exit-status clue, so
# stderr is surfaced rather than discarded - otherwise the failure only shows up
# much later as "the filesystem did not grow".
lsl_refresh_image_loops() {
    local img="$1" devs dev err
    command -v losetup >/dev/null 2>&1 || return 0
    devs="$(losetup -j "$(readlink -f "$img" 2>/dev/null || printf '%s' "$img")" 2>/dev/null | cut -d: -f1)"
    [ -n "$devs" ] || return 0
    for dev in $devs; do
        [ -b "$dev" ] || continue
        if ! err="$(losetup -c "$dev" 2>&1)"; then
            echo "lsl: losetup -c $dev failed: ${err:-no output}" >&2
        fi
    done
    return 0
}

# Install the staged hivex .debs from /cdrom/pkgs when hivexregedit is absent.
# mount_all.sh needs it to map Windows drive letters; on a stock first boot it is
# not in the base image, and the same firstboot run installs it ~23 minutes later,
# so /mnt/c never mounts in time and /home falls back to a tmpfs overlay (the
# WHYFAIL9 data loss). Installing the pre-staged .debs HERE, before /home mounts,
# removes that trigger with no network. Best-effort: returns 0 when hivexregedit
# is (or becomes) available, 1 otherwise - never callers' failure.
lsl_ensure_hivex_tools() {
    command -v hivexregedit >/dev/null 2>&1 && return 0
    local d="${LSL_CDROM:-/cdrom}/pkgs"
    ls "$d"/*.deb >/dev/null 2>&1 || return 1
    echo "lsl: hivexregedit missing; installing staged .debs from $d ..." >&2
    dpkg -i "$d"/*.deb >/dev/null 2>&1 || true
    command -v hivexregedit >/dev/null 2>&1
}

lsl_data_dir_is_persistent() {
    # True when the resolved LSL_DATA_DIR sits on a persistent volume (a real
    # disk / loop / USB partition), not the live overlay/tmpfs root. Used by
    # onboot.sh to avoid silently writing HDD-mode images into volatile RAM on
    # the first boot (before firstboot has installed the tools that mount /mnt/c).
    local d mp fst
    d="$(lsl_resolve_data_dir 2>/dev/null || true)"
    [ -n "$d" ] || return 1
    mp="$(findmnt -n -o TARGET -T "$d" 2>/dev/null || true)"
    [ -n "$mp" ] || return 1
    fst="$(findmnt -n -o FSTYPE -- "$mp" 2>/dev/null || true)"
    case "$fst" in
        overlay|aufs|tmpfs|ramfs|"") return 1 ;;
        *) return 0 ;;
    esac
}

lsl_data_dir_is_writable() {
    # True when the data dir is persistent AND currently mounted read-write.
    #
    # Why this is separate from lsl_data_dir_is_persistent: the btrfs home
    # image needs a writable volume, and a READ-ONLY ntfs mount satisfies the
    # persistence check while being useless for writing it. On boot the data
    # dir routinely lands `ro` first - the kernel refuses the rw mount with
    # "Can't mount, would change RO state" and onboot's rw attempt succeeds
    # about a second later. Branching on persistence alone accepted that ro
    # landing and declared usb-fallback, losing the whole session's /home.
    #
    # Deliberately does NOT mutate the mount: remounting rw on a volume the
    # kernel considers dirty is how NTFS gets corrupted. It only reports, so
    # the caller can keep retrying and still fall back honestly.
    local d mp opts
    lsl_data_dir_is_persistent || return 1
    d="$(lsl_resolve_data_dir 2>/dev/null || true)"
    [ -n "$d" ] || return 1
    mp="$(findmnt -n -o TARGET -T "$d" 2>/dev/null || true)"
    [ -n "$mp" ] || return 1
    # Ask findmnt about the mount point, not the data dir: -T on the data dir
    # can resolve to a different (parent) mount than the one we validated.
    opts="$(findmnt -n -o OPTIONS --target "$mp" 2>/dev/null || true)"
    [ -n "$opts" ] || return 1
    # Options are comma-separated; "ro" appears only on a read-only mount,
    # and rw mounts list "rw" explicitly.
    case ",$opts," in
        *,ro,*) return 1 ;;
        *,rw,*) return 0 ;;
        *) return 1 ;;
    esac
}

lsl_cdrom_free_mib() {
    # Available MiB on /cdrom, or 0 if it cannot be determined.
    local av
    av="$(df -m --output=avail /cdrom 2>/dev/null | tail -1 | tr -d ' ')"
    case "$av" in
        ''|*[!0-9]*) echo 0 ;;
        *) echo "$av" ;;
    esac
}

lsl_ensure_cdrom_space() {
    # $1 = required MiB on /cdrom. Returns 0 if at least that much is free (or
    # if free space is unknown - we let the write fail naturally rather than
    # blocking a persist that might still fit, avoiding a cryptic mksquashfs
    # "No space left on device" mid-write).
    local need="${1:-0}"
    local av; av="$(lsl_cdrom_free_mib)"
    [ "$av" -gt 0 ] 2>/dev/null || return 0
    [ "$av" -ge "$need" ] 2>/dev/null
}

lsl_cdrom_fstype() {
    # Filesystem type of the mounted /cdrom, or empty if it cannot be determined.
    findmnt -n -o FSTYPE /cdrom 2>/dev/null || true
}

lsl_cdrom_is_vfat() {
    # True when /cdrom is a FAT32 volume, which imposes a ~4 GiB single-file
    # ceiling that mksquashfs cannot exceed (a layer written past it fails
    # cryptically mid-write).
    [ "$(lsl_cdrom_fstype)" = "vfat" ]
}

lsl_fat32_max_bytes() {
    # FAT32 maximum single file size is 4 GiB minus one cluster; use 4 GiB - 64 KiB
    # as a conservative, always-safe ceiling for pre-write size checks.
    echo 4294901760
}

# zstd level for every mksquashfs call in the tree. 15 is the knee of the
# measured ratio/time curve on real layer content: -5.7% size versus level 9 for
# 6x the write time, where 19 reaches -6.4% only for 14x. The tree previously
# passed 22, which buys nothing over 19, did not finish inside the measurement
# window, and is past libzstd's regular range (>=20 is --ultra) as well as past
# mksquashfs' own documented 1..9. See FINDINGS-COMPRESSION.md.
#
# Boot-time DECOMPRESSION was never measured and favours lower levels - every
# layer is read back on every boot. Lower this if boot time matters more than
# layer size.
LSL_SQUASHFS_COMPRESSION_LEVEL="${LSL_SQUASHFS_COMPRESSION_LEVEL:-15}"

LSL_HOME_LOWER="${LSL_HOME_LOWER:-/run/lsl-home-lower}"
LSL_HOME_UPPER="${LSL_HOME_UPPER:-/run/lsl-home-overlay/upper}"
LSL_HOME_WORK="${LSL_HOME_WORK:-/run/lsl-home-overlay/work}"
LSL_HOME_TMPFS="${LSL_HOME_TMPFS:-/run/lsl-home-overlay}"
LSL_CACHE_MOUNT="${LSL_CACHE_MOUNT:-/mnt/lsl-cache}"

# Distro key for per-distro home/cache images. The home image is keyed to
# LSL_DATA_DIR, so without this a stick re-imaged with another distro would
# reuse the previous one's /home (only the missing user home is recreated).
# LSL_DISTRO_KEY overrides the autodetection (tests).
lsl_distro_key() {
    local id="${LSL_DISTRO_KEY:-}"
    if [ -z "$id" ] && [ -r /etc/os-release ]; then
        id="$(sed -n 's/^ID=//p' /etc/os-release | head -n1 | tr -d '"')"
    fi
    [ -n "$id" ] || id="${LSL_DESKTOP_USER:-}"
    [ -n "$id" ] || id=default
    id="$(printf '%s' "$id" | tr -c 'A-Za-z0-9._-' '_' | sed -e 's/^_*//' -e 's/_*$//')"
    [ -n "$id" ] || id=default
    printf '%s\n' "$id"
}

lsl_home_btrfs_path() {
    lsl_load_config
    printf '%s/home-%s.btrfs' "$(lsl_resolve_data_dir)" "$(lsl_distro_key)"
}

lsl_cache_btrfs_path() {
    lsl_load_config
    printf '%s/cache-%s.btrfs' "$(lsl_resolve_data_dir)" "$(lsl_distro_key)"
}

# USB-mode home snapshot, also per-distro.
lsl_home_sfs_path() {
    printf '%s/home-%s.sfs' "${LSL_CDROM:-/cdrom}" "$(lsl_distro_key)"
}

# Adopt a pre-per-distro image so switching distros does not silently start from
# scratch: the FIRST distro to boot claims the legacy file. Idempotent, and it
# never fails the caller (a read-only data dir or /cdrom just skips).
lsl_home_migrate_legacy() {
    local d old new
    d="$(lsl_resolve_data_dir)"
    for old in "$d/home.btrfs" "$d/cache.btrfs"; do
        [ -f "$old" ] || continue
        new="$d/$(basename "$old" .btrfs)-$(lsl_distro_key).btrfs"
        if [ ! -e "$new" ]; then
            mv "$old" "$new" 2>/dev/null && echo "lsl: adopted legacy $(basename "$old") as $(basename "$new")" >&2
        fi
    done
    old="${LSL_CDROM:-/cdrom}/home.sfs"
    new="$(lsl_home_sfs_path)"
    if [ -f "$old" ] && [ ! -e "$new" ]; then
        if mount "${LSL_CDROM:-/cdrom}" -o remount,rw 2>/dev/null; then
            mv "$old" "$new" 2>/dev/null && echo "lsl: adopted legacy home.sfs as $(basename "$new")" >&2
            mount "${LSL_CDROM:-/cdrom}" -o remount,ro 2>/dev/null || true
        fi
    fi
    return 0
}

lsl_state_file() {
    echo /run/lsl-usb.state
}

lsl_runtime_dir() {
    local d fallback
    d="${LSL_RUNTIME_DIR:-/run/lsl-usb}"
    mkdir -p "$d" 2>/dev/null || true
    if [ ! -d "$d" ]; then
        fallback="/tmp/lsl-usb"
        mkdir -p "$fallback" 2>/dev/null || true
        d="$fallback"
    fi
    if [ -d "$d" ]; then
        readlink -f "$d" 2>/dev/null || echo "$d"
    else
        echo "$d"
    fi
}

lsl_mount_state_base() {
    printf '%s/mounts\n' "$(lsl_runtime_dir)"
}

lsl_source_state() {
    local f
    f="$(lsl_state_file)"
    if [ -f "$f" ]; then
        # shellcheck source=/dev/null
        . "$f"
    fi
}

# Persisted VHDX paths (from lsl-gui browse); not auto-scanned.
lsl_vhdx_state_file() {
    if [ -n "${LSL_VHDX_LIST_FILE:-}" ]; then
        printf '%s\n' "$LSL_VHDX_LIST_FILE"
        return
    fi
    local base=""
    lsl_load_config 2>/dev/null || true
    base="$(lsl_resolve_data_dir 2>/dev/null || true)"
    if [ -n "$base" ]; then
        printf '%s/vhdx.list\n' "$base"
        return
    fi
    base="${XDG_STATE_HOME:-${HOME:-.}/.local/state}/lsl"
    mkdir -p "$base" 2>/dev/null || base="/tmp"
    printf '%s/vhdx.list\n' "$base"
}

lsl_vhdx_paths_stdout() {
    local f
    f="$(lsl_vhdx_state_file)"
    [ -f "$f" ] || return 0
    grep -v '^[[:space:]]*$' "$f" 2>/dev/null | sort -u
}

lsl_vhdx_append() {
    local path="$1" f canon
    [ -n "$path" ] && [ -f "$path" ] || return 1
    canon="$(readlink -f "$path" 2>/dev/null || echo "$path")"
    f="$(lsl_vhdx_state_file)"
    mkdir -p "$(dirname "$f")" 2>/dev/null || true
    touch "$f" 2>/dev/null || true
    if grep -qxF "$canon" "$f" 2>/dev/null; then
        return 0
    fi
    printf '%s\n' "$canon" >> "$f"
}

# Lines: name|vhdx_path| (third field empty) for merge with parse_wsl_report.
lsl_vhdx_saved_distro_lines() {
    local p
    # `|| [ -n "$p" ]`: vhdx.list is written by the Windows installer and has NO
    # trailing newline, so a plain `while read` drops its LAST entry (that is
    # how the Ubuntu 22.04 image vanished from every list on this stick).
    while IFS= read -r p || [ -n "$p" ]; do
        [ -z "$p" ] && continue
        printf '%s|%s|\n' "$(basename "$p" .vhdx)" "$p"
    done < <(lsl_vhdx_paths_stdout)
}

lsl_dedupe_distro_lines() {
    awk -F'|' 'NF>=2 { key=($2 != "" ? $2 : $3); if (key != "" && !seen[key]++) print }'
}
