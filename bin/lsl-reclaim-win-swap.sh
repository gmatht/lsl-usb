#!/usr/bin/env bash
# lsl-reclaim-win-swap - Reclaim dead Windows paging/swap space as compressed swap.
#
# Opt-in: set LSL_RECLAIM_WIN_SWAP=1 in lsl-usb.env (see bin/config.sh sync).
#
# ---------------------------------------------------------------------------
# Why
# ---------------------------------------------------------------------------
# On a dual-boot / WSL-to-Linux setup, C:\pagefile.sys and each WSL2 distro's
# C:\Users\<u>\AppData\Local\Packages\<distro>\LocalState\swapfile.vhdx are large
# files that are pure dead space once Windows is fully off. If Windows shut down
# CLEANLY (no hibernate, no Fast Startup), nothing is using them, so we can
# rename them aside and point compressed swap at that space instead of burning
# RAM or growing our own images.
#
# ---------------------------------------------------------------------------
# What it does (when LSL_RECLAIM_WIN_SWAP=1)
# ---------------------------------------------------------------------------
#   1. For every Windows volume mounted read-write at /mnt/<letter>:
#        - SKIP if hiberfil.sys exists. Its presence means Fast Startup is
#          enabled, i.e. the last "shutdown" was a hibernate-like state and the
#          pagefile is NOT safe to repurpose.                 [clean-shutdown #1]
#        - SKIP if the volume is mounted read-only. mount_all.sh mounts it ro
#          when ntfsfix reports it dirty/hibernated, so ro => not clean.
#                                                            [clean-shutdown #2]
#        - find pagefile.sys (volume root) and WSL2 swapfile.vhdx (under Users)
#        - for each: verify it is a regular file >= LSL_RECLAIM_MIN_MIB MiB
#        - rename it to lsl-swap-<rand>.tmp (same directory, same filesystem)
#        - losetup the temp file and attach it as a zram BACKING device (compressed
#          RAM swap whose idle pages spill to the reclaimed disk file)
#        - swapon it at LSL_RECLAIM_SWAP_PRIO (lower than the RAM zram, so RAM is
#          used first and the reclaimed disk space is the spill/backing tier)
#   2. Drop a Windows-side cleanup (Scheduled Task + PowerShell) that deletes the
#      renamed temp files on the next Windows boot, so the space is returned.
#
# Release (Linux shutdown): `lsl-reclaim-win-swap.sh --release` swapoffs + detaches
# the loops and deletes the temp files, returning the space to Windows BEFORE it
# boots. The Windows task above is a belt-and-suspenders safety net (and the only
# path that runs if Linux did not shut down cleanly).
#
# Nothing mutates unless LSL_RECLAIM_WIN_SWAP=1. Use --dry-run to preview.
#
# ---------------------------------------------------------------------------
# On "configure Windows to delete them on reboot"
# ---------------------------------------------------------------------------
# The reliable delete happens at Linux shutdown (--release). For the explicit
# Windows-side "delete on next boot" we use a file-based Scheduled Task
# (C:\Windows\System32\Tasks + a PowerShell script), NOT a registry write
# (PendingFileRenameOperations): the repo only ever READS the Windows registry
# from Linux, and writing the SYSTEM hive risks bricking Windows if the
# REG_MULTI_SZ is malformed. The dropped task is best-effort; if Task Scheduler
# does not pick it up, --release already freed the space.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lsl-common.sh" 2>/dev/null || true
lsl_load_config 2>/dev/null || true

: "${LSL_RECLAIM_WIN_SWAP:=0}"
: "${LSL_RECLAIM_MIN_MIB:=256}"
: "${LSL_RECLAIM_MAX_MIB:=0}"      # 0 = no cap on the zram size (use full file)
: "${LSL_RECLAIM_SWAP_PRIO:=10}"   # below the RAM zram priority (100)
export LSL_RECLAIM_WIN_SWAP LSL_RECLAIM_MIN_MIB LSL_RECLAIM_MAX_MIB LSL_RECLAIM_SWAP_PRIO

STATE_FILE="${STATE_FILE:-/run/lsl-reclaim-win-swap.state}"
DRYRUN="${DRYRUN:-0}"

log() { echo "lsl-reclaim-win-swap: $*" >&2; }
die() { log "ERROR: $*"; return 1; }

# --- pure helpers (also unit-tested) ----------------------------------------

# Windows drive letter for a /mnt/<letter> mountpoint (uppercase), or fail.
win_letter_of() {
    local mp="$1"
    [[ "$mp" == /mnt/? ]] || return 1
    printf '%s\n' "${mp:5:1}" | tr '[:lower:]' '[:upper:]'
}

# True when $1 is mounted read-write (not ro).
volume_rw() {
    local mp="$1"
    mountpoint -q "$mp" 2>/dev/null || return 1
    findmnt -n -o OPTIONS "$mp" 2>/dev/null | tr ',' '\n' | grep -qx rw
}

# Linux path under /mnt/<letter> -> Windows path (C:\foo\bar).
to_win_path() {
    local p="$1"
    if [[ "$p" == /mnt/?/* ]]; then
        local letter="${p:5:1}" rest="${p:6}"
        printf '%s:%s\n' "${letter^^}" "${rest//\//\\}"
    else
        printf '%s\n' "$p"
    fi
}

random_suffix() {
    # Not security-sensitive; just needs to be unique per boot.
    od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || printf '%s' "$$"
}

# Mountpoint (e.g. /mnt/c) that contains $1, or empty.
mountpoint_of() {
    local f="$1" m
    m="$(findmnt -n -o TARGET -T "$f" 2>/dev/null || true)"
    [ -n "$m" ] && { printf '%s\n' "$m"; return 0; }
    # Fallback: strip path components until we hit a /mnt/<letter>.
    printf '%s\n' "$f" | sed -E 's#^(/mnt/[^/]+)/.*#\1#'
}

# --- mutating steps ----------------------------------------------------------

# $1 = candidate file (pagefile.sys or swapfile.vhdx), $2 = its volume mountpoint.
setup_one() {
    local f="$1" mp="$2" sz_mib
    [ -f "$f" ] || return 0
    sz_mib=$(( $(stat -c %s "$f" 2>/dev/null || echo 0) / 1024 / 1024 ))
    if [ "$sz_mib" -lt "${LSL_RECLAIM_MIN_MIB}" ] 2>/dev/null; then
        log "skip ${f} (${sz_mib} MiB < min ${LSL_RECLAIM_MIN_MIB})"
        return 0
    fi

    local dir tmp loop zdev mib
    dir="$(dirname "$f")"
    tmp="$dir/lsl-swap-$(random_suffix).tmp"
    if [ "${DRYRUN}" = "1" ]; then
        log "[dry-run] would reclaim ${f} (${sz_mib} MiB) -> ${tmp} as compressed swap backing"
        return 0
    fi

    if ! mv "$f" "$tmp" 2>/dev/null; then
        log "skip ${f}: cannot rename (likely still in use) - leaving Windows file alone"
        return 0
    fi
    log "reclaimed ${f} -> ${tmp} (${sz_mib} MiB)"

    loop="$(losetup -f --show "$tmp" 2>/dev/null || true)"
    if [ ! -b "$loop" ]; then
        log "losetup failed for ${tmp}; restoring original"
        mv "$tmp" "$f" 2>/dev/null || true
        return 0
    fi

    mib="$sz_mib"
    if [ "${LSL_RECLAIM_MAX_MIB}" -gt 0 ] 2>/dev/null; then
        [ "$mib" -gt "${LSL_RECLAIM_MAX_MIB}" ] 2>/dev/null && mib="${LSL_RECLAIM_MAX_MIB}"
    fi

    zdev=""
    if command -v zramctl >/dev/null 2>&1; then
        zdev="$(zramctl --find --size "${mib}M" --backing-device "$loop" 2>/dev/null || true)"
    fi
    if [ -z "$zdev" ] || [ ! -b "$zdev" ]; then
        # Fallback: raw sysfs zram + backing_dev poke.
        local b
        b="$(zramctl --find 2>/dev/null || true)"
        [ -b "$b" ] || b="zram0"
        [ -b "/dev/$b" ] || { losetup -d "$loop" 2>/dev/null; mv "$tmp" "$f" 2>/dev/null; return 0; }
        zdev="/dev/$b"
        echo 1 >"/sys/block/$b/reset" 2>/dev/null || true
        echo $((mib * 1024 * 1024)) >"/sys/block/$b/disksize" 2>/dev/null || {
            losetup -d "$loop" 2>/dev/null; mv "$tmp" "$f" 2>/dev/null; return 0; }
        echo "$loop" >"/sys/block/$b/backing_dev" 2>/dev/null \
            || log "warn: could not attach backing device ${loop} to ${zdev}"
    fi

    if ! mkswap "$zdev" >/dev/null 2>&1; then
        losetup -d "$loop" 2>/dev/null; mv "$tmp" "$f" 2>/dev/null; return 0
    fi
    if swapon -p "${LSL_RECLAIM_SWAP_PRIO}" "$zdev" 2>/dev/null; then
        log "swapon ${zdev} (backing ${loop}) prio ${LSL_RECLAIM_SWAP_PRIO}"
        # state line: tempfile|loop|zram|windows-path
        printf '%s|%s|%s|%s\n' "$tmp" "$loop" "$zdev" "$(to_win_path "$tmp")" >> "$STATE_FILE"
    else
        log "swapon failed for ${zdev}; restoring original"
        swapoff "$zdev" 2>/dev/null; losetup -d "$loop" 2>/dev/null; mv "$tmp" "$f" 2>/dev/null
    fi
}

# Write the Windows-side cleanup artifacts (manifest + PowerShell + Scheduled Task)
# under $1 (the booted Windows volume, e.g. /mnt/c). File-based only - never
# touches the registry. See drop_windows_cleanup for the caller.
emit_windows_cleanup_under() {
    local sys_vol="$1"
    local winpaths=()
    [ -f "$STATE_FILE" ] || return 0
    while IFS='|' read -r _tmp _loop _zram winpath; do
        [ -n "$winpath" ] && winpaths+=("$winpath")
    done < "$STATE_FILE"
    [ "${#winpaths[@]}" -gt 0 ] || return 0
    local wdir="$sys_vol/lsl"
    mkdir -p "$wdir" 2>/dev/null || { log "cannot create $wdir; skipping Windows cleanup drop"; return 0; }

    # Manifest: one Windows path per line.
    printf '%s\n' "${winpaths[@]}" > "$wdir/lsl-reclaim-manifest.txt"

    # PowerShell cleanup (deletes manifest entries, then self-removes the manifest).
    cat > "$wdir/lsl-reclaim-cleanup.ps1" <<'PS1'
$manifest = Join-Path $PSScriptRoot 'lsl-reclaim-manifest.txt'
if (Test-Path $manifest) {
    Get-Content $manifest | ForEach-Object {
        $p = $_.Trim()
        if ($p -and (Test-Path $p)) {
            try { Remove-Item $p -Force -ErrorAction Stop; Write-Host "lsl-reclaim: deleted $p" }
            catch { Write-Warning "lsl-reclaim: could not delete $p : $_" }
        }
    }
    Remove-Item $manifest -Force -ErrorAction SilentlyContinue
}
PS1

    # Scheduled Task (boot trigger, runs as SYSTEM). UTF-16LE w/ BOM is what
    # Task Scheduler expects; fall back to UTF-8 if iconv is unavailable.
    local tasksdir="$sys_vol/Windows/System32/Tasks"
    mkdir -p "$tasksdir" 2>/dev/null || true
    local xml="$tasksdir/LSL-DeleteReclaimedSwap"
    if command -v iconv >/dev/null 2>&1; then
        printf '\xff\xfe' > "$xml"
        iconv -f UTF-8 -t UTF-16LE >> "$xml" <<'TASKXML'
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Date>2024-01-01T00:00:00</Date>
    <Author>LSL-USB</Author>
    <Description>Delete reclaimed Windows pagefile / WSL2 swap temp files left by LSL-USB.</Description>
  </RegistrationInfo>
  <Triggers>
    <BootTrigger><Enabled>true</Enabled></BootTrigger>
  </Triggers>
  <Principals>
    <Principal id="System">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="System">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -File C:\lsl\lsl-reclaim-cleanup.ps1</Arguments>
    </Exec>
  </Actions>
</Task>
TASKXML
    else
        cat > "$xml" <<'TASKXML'
<?xml version="1.0" encoding="UTF-8"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Date>2024-01-01T00:00:00</Date>
    <Author>LSL-USB</Author>
    <Description>Delete reclaimed Windows pagefile / WSL2 swap temp files left by LSL-USB.</Description>
  </RegistrationInfo>
  <Triggers>
    <BootTrigger><Enabled>true</Enabled></BootTrigger>
  </Triggers>
  <Principals>
    <Principal id="System">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="System">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -File C:\lsl\lsl-reclaim-cleanup.ps1</Arguments>
    </Exec>
  </Actions>
</Task>
TASKXML
    fi
    log "wrote Windows cleanup (task + manifest + ps1) to ${sys_vol} [best-effort]"
}

# Best-effort Windows-side "delete on next boot": a Scheduled Task that runs a
# PowerShell cleanup script (also dropped) which deletes every reclaimed temp
# file listed in the manifest. File-based only - never touches the registry.
drop_windows_cleanup() {
    [ -f "$STATE_FILE" ] || return 0
    local winpaths=()
    while IFS='|' read -r _tmp _loop _zram winpath; do
        [ -n "$winpath" ] && winpaths+=("$winpath")
    done < "$STATE_FILE"
    [ "${#winpaths[@]}" -gt 0 ] || return 0

    # The task must live on the booted Windows volume (C:) to be loaded by
    # Task Scheduler, so use the volume that holds the SYSTEM hive.
    local sys_vol=""
    for m in /mnt/*; do
        [ -f "$m/Windows/System32/config/SYSTEM" ] && { sys_vol="$m"; break; }
    done
    [ -n "$sys_vol" ] || sys_vol="/mnt/c"
    emit_windows_cleanup_under "$sys_vol"
}

setup() {
    [ "${LSL_RECLAIM_WIN_SWAP:-0}" = "1" ] || { log "disabled (LSL_RECLAIM_WIN_SWAP != 1)"; return 0; }
    mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
    : > "$STATE_FILE" 2>/dev/null || true
    local m
    for m in /mnt/*; do
        mountpoint -q "$m" 2>/dev/null || continue
        case "$(findmnt -n -o FSTYPE "$m" 2>/dev/null)" in
            ntfs|ntfs3|fuseblk) ;;
            *) continue ;;
        esac
        if ! volume_rw "$m"; then
            log "skip ${m} (read-only / dirty NTFS - not a clean Windows shutdown)"
            continue
        fi
        if [ -f "$m/hiberfil.sys" ]; then
            log "skip ${m} (hiberfil.sys present: Fast Startup / hibernate - not a clean shutdown)"
            continue
        fi
        [ -f "$m/pagefile.sys" ] && setup_one "$m/pagefile.sys" "$m"
        if [ -d "$m/Users" ]; then
            while IFS= read -r sf; do
                setup_one "$sf" "$m"
            done < <(find -xdev "$m/Users" -maxdepth 9 -type f -name swapfile.vhdx 2>/dev/null)
        fi
    done
    drop_windows_cleanup
}

# Swap off + detach loops + delete the renamed temp files (space returned to
# Windows). Called at Linux shutdown by lsl-reclaim-win-swap.service.
release() {
    [ -f "$STATE_FILE" ] || { log "nothing to release"; return 0; }
    while IFS='|' read -r tmp loop zram _winpath; do
        [ -n "$zram" ] && swapoff "$zram" 2>/dev/null
        [ -n "$loop" ] && losetup -d "$loop" 2>/dev/null
        [ -n "$tmp" ] && rm -f "$tmp" 2>/dev/null
    done < "$STATE_FILE"
    rm -f "$STATE_FILE" 2>/dev/null
    log "released reclaimed Windows swap files"
}

# Sourceable for unit tests: define functions but do not run when sourced.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0 2>/dev/null || true
fi

case "${1:-setup}" in
    setup)        setup ;;
    --dry-run|dry-run) DRYRUN=1; setup ;;
    --release|release) release ;;
    -h|--help)
        sed -n '2,40p' "$0" >&2
        exit 0
        ;;
    *) echo "usage: $0 [setup | --dry-run | --release]" >&2; exit 2 ;;
esac
