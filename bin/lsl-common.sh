#!/bin/bash
# Shared LSL-USB config and USB vs HDD mode detection.
# shellcheck disable=SC1091

LSL_ENV_FILE="${LSL_ENV_FILE:-/cdrom/lsl-usb.env}"

lsl_load_config() {
    if [ -f "$LSL_ENV_FILE" ]; then
        . "$LSL_ENV_FILE"
    fi
    : "${LSL_DATA_DIR:=/mnt/c/Users/lsl-usb}"
    : "${LSL_HOME_IDLE_SEC:=300}"
    : "${LSL_HOME_BTRFS_MIB:=4096}"
    : "${LSL_CACHE_BTRFS_MIB:=2048}"
    : "${LSL_BTRFS_GROW_CHUNK_MIB:=1024}"
    : "${LSL_BTRFS_MIN_FREE_PCT:=10}"
    : "${LSL_HOME_TMPFS_MIB:=2048}"
    export LSL_DATA_DIR LSL_HOME_IDLE_SEC LSL_HOME_BTRFS_MIB LSL_CACHE_BTRFS_MIB
    export LSL_BTRFS_GROW_CHUNK_MIB LSL_BTRFS_MIN_FREE_PCT LSL_HOME_TMPFS_MIB
}

lsl_resolve_data_dir() {
    local d
    d="${LSL_DATA_DIR:-/mnt/c/Users/lsl-usb}"
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
    while IFS= read -r p; do
        [ -z "$p" ] && continue
        printf '%s|%s|\n' "$(basename "$p" .vhdx)" "$p"
    done < <(lsl_vhdx_paths_stdout)
}

lsl_dedupe_distro_lines() {
    awk -F'|' 'NF>=2 { key=($2 != "" ? $2 : $3); if (key != "" && !seen[key]++) print }'
}
