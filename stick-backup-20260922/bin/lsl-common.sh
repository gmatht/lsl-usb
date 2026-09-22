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
    # data dir).
    for f in /cdrom/lsl-usb.env "${HOME:-}/lsl-usb.env"; do
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
    local u=""
    u="$(getent passwd 1000 2>/dev/null | cut -d: -f1 || true)"
    [ -n "$u" ] || u="$(ls -1 /home 2>/dev/null | head -n1 || true)"
    [ -n "$u" ] || u="mint"
    printf '%s\n' "$u"
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

LSL_HOME_LOWER="${LSL_HOME_LOWER:-/run/lsl-home-lower}"
LSL_HOME_UPPER="${LSL_HOME_UPPER:-/run/lsl-home-overlay/upper}"
LSL_HOME_WORK="${LSL_HOME_WORK:-/run/lsl-home-overlay/work}"
LSL_HOME_TMPFS="${LSL_HOME_TMPFS:-/run/lsl-home-overlay}"
LSL_CACHE_MOUNT="${LSL_CACHE_MOUNT:-/mnt/lsl-cache}"

lsl_home_btrfs_path() {
    lsl_load_config
    printf '%s/home.btrfs' "$(lsl_resolve_data_dir)"
}

lsl_cache_btrfs_path() {
    lsl_load_config
    printf '%s/cache.btrfs' "$(lsl_resolve_data_dir)"
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
