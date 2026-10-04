#!/bin/bash
# lsl-snap-fat.sh - ensure the snaps listed on the stick are installed.
#
# snapd is already installed (squashfs_config.sh removes Mint's nosnap.pref
# pin and apt-installs snapd on amd64), so `snap install foo` already works in
# a live session. What does NOT survive a reboot is snapd's state:
# /var/lib/snapd and /var/snap live on the casper RAM overlay (/cow/upper is a
# tmpfs), so every installed snap is gone at the next boot.
#
# So what persists is only two things:
#   /cdrom/snaps.txt          - the LIST (a few hundred bytes)
#   /cdrom/casper/snapcache/  - the PAYLOAD, fetched on first use only
#                                (<name>_<rev>.snap AND <name>_<rev>.snap.assert)
#
# Why the cache and not just "download every boot": snaps are 300-700 MB each
# plus base snaps snapd pulls as dependencies. Re-downloading gigabytes on
# every boot is the dealbreaker; caching makes only the FIRST use pay.
#
# Why snapd's own state is not bind-mounted onto the FAT stick, given that
# fuse/fat_linux_meta_fs.py already emulates symlinks, ownership, hardlinks and
# FIFOs on FAT (which is how flatpaks persist here):
#   1. fat_linux_meta_fs.py's lock() is an intentional NO-OP - "correct for our
#      single-writer flows". snapd is not single-writer (snapd + snap-confine +
#      AppArmor + the store client), so unlocked concurrent writes corrupt.
#   2. snapd squashfs-loop-mounts the .snap files out of its state dir on every
#      refresh; a FUSE passthrough fd is not a reliable loop source.
#   3. /snap/<name>/current is a symlink that must resolve after the mount.
# See DESIGN-SNAP-PERSISTENCE.md. Making snapd's state itself persistent is the
# btrfs/F2FS work, and is machine-local.
#
# The 4 GiB FAT32 single-file cap does not bite here: it applies to the appended
# squashfs layer, not to files on the stick, and a .snap is written once and
# then only ever read.
#
# Usage:
#   lsl-snap-fat.sh ensure              # install any snap in the list that is
#                                       # missing (idempotent; the boot path)
#   lsl-snap-fat.sh install <snap>...   # one-off; also caches for later boots
#   lsl-snap-fat.sh list                 # show the stick's list and what is
#                                       # installed / cached
#   lsl-snap-fat.sh cleancache          # drop cached .snap files
set -uo pipefail

STICK_LIST="${LSL_SNAP_LIST:-/cdrom/snaps.txt}"
# NOT /cdrom/snapcache: onboot.sh remounts /cdrom read-only, and on iso-scan
# boots /cdrom is the ISO loop while /cdrom/casper is the bind-mounted writable
# stick (same reason lsl-appimages.sh and the nvim AppImage use
# /cdrom/casper/appimages).
CACHE="${LSL_SNAP_CACHE:-/cdrom/casper/snapcache}"
# Overridable only so the test suite can point it at a fixture dir.
SNAP_STATE_DIR="${SNAP_STATE_DIR:-/var/lib/snapd/snaps}"
LOG="${LSL_LOG:-/cdrom/bash.log}"

log() {
    echo "lsl-snap: $*" >&2
    local dir
    dir="$(dirname "$LOG")"
    if mkdir -p "$dir" 2>/dev/null && touch "$LOG" 2>/dev/null && [ -w "$LOG" ]; then
        echo "lsl-snap: $*" >>"$LOG" 2>/dev/null || true
    fi
    return 0
}

# Report progress to the first-boot dialog when we are running inside
# lsl-firstboot.sh, and stay usable standalone when we are not. task_progress is
# defined by the caller; if it is not, the plain log line is all we emit.
progress() {
    log "$1"
    if command -v task_progress >/dev/null 2>&1; then
        task_progress "$1" "$2" || true
    fi
}

snap_available() {
    # snapd is only installed on amd64 (squashfs_config.sh gates it), so on
    # i386 this is correctly a no-op rather than a failure.
    [ "${LSL_SNAP_SUPPORT:-1}" != "0" ] || return 1
    command -v snap >/dev/null 2>&1 || return 1
    case "$(uname -m 2>/dev/null)" in
        x86_64 | amd64) return 0 ;;
        *) return 1 ;;
    esac
}

installed_snaps() {
    snap list 2>/dev/null | awk 'NR>1 {print $1}'
}

is_installed() {
    installed_snaps | grep -qx -- "$1"
}

# Newest cached revision for a snap name, if any.
cached_file() {
    local name="$1" f
    [ -d "$CACHE" ] || return 1
    # sort -V so revision 10 beats revision 9.
    f="$(ls -1 "$CACHE/${name}"_*.snap 2>/dev/null | sort -V | tail -n 1)"
    [ -n "$f" ] || return 1
    [ -s "$f" ] || return 1
    printf '%s' "$f"
}

# The assertion for a cached revision, if we kept one. A verified offline
# install needs BOTH files: `snap ack` registers the assertion, and
# `snap install --offline` then verifies the snap against it.
cached_assert() {
    local f
    [ -d "$CACHE" ] || return 1
    f="$(ls -1 "$CACHE/${1}"_*.snap.assert 2>/dev/null | sort -V | tail -n 1)"
    [ -n "$f" ] && [ -s "$f" ] || return 1
    printf '%s' "$f"
}

# The revision snapd actually installed, so we cache exactly what is running.
installed_rev() {
    # snap list: Name  Version  Rev  Tracking  Publisher  Notes
    snap list "$1" 2>/dev/null | awk 'NR==2 {print $3}'
}

# Copy the installed snap AND its assertion onto the stick, so the next boot
# installs a VERIFIED snap from local disk instead of re-downloading.
#
# `snap download` is what produces the matched pair. We cannot simply copy the
# .snap out of the state dir and find its assertion: snapd stores assertions in
# /var/lib/snapd/assertions/ under a content-hash filename, with no name link
# back to the snap. Re-downloading at cache time is cheap (once per snap, on a
# boot that already has network) and guarantees the two files agree.
cache_snap_files() {
    local name="$1" rev tmp snapf assertf
    rev="$(installed_rev "$name")"
    [ -n "$rev" ] || return 1
    command -v snap >/dev/null 2>&1 || return 1
    mkdir -p "$CACHE" 2>/dev/null || {
        log "WARNING: cannot create cache dir $CACHE - snaps will re-download each boot."
        return 1
    }
    tmp="$(mktemp -d)" || return 1
    # Pin the revision we actually installed: an unpinned download could fetch a
    # newer .snap whose assertion then does not match what is on the stick.
    if ! ( cd "$tmp" && snap download --revision="$rev" "$name" ) >/dev/null 2>&1; then
        rm -rf "$tmp" 2>/dev/null || true
        log "WARNING: snap download failed for $name (rev $rev) - later boots will re-fetch it."
        return 1
    fi
    snapf="$(ls -1 "$tmp/${name}"_*.snap 2>/dev/null | sort -V | tail -n 1)"
    assertf="$(ls -1 "$tmp/${name}"_*.snap.assert 2>/dev/null | sort -V | tail -n 1)"
    if [ -z "$snapf" ] || [ ! -s "$snapf" ]; then
        rm -rf "$tmp" 2>/dev/null || true
        return 1
    fi
    # Copy to .part then rename: a half-written file left behind would be picked
    # up by cached_file() on the next boot and fail there instead of here.
    cp -f "$snapf" "$CACHE/$(basename "$snapf").part" 2>/dev/null \
        && mv -f "$CACHE/$(basename "$snapf").part" "$CACHE/$(basename "$snapf")" 2>/dev/null || {
        rm -f "$CACHE/$(basename "$snapf").part" 2>/dev/null || true
        rm -rf "$tmp" 2>/dev/null || true
        log "WARNING: could not cache $name to the stick (read-only?); it will re-download next boot."
        return 1
    }
    if [ -n "$assertf" ] && [ -s "$assertf" ]; then
        cp -f "$assertf" "$CACHE/$(basename "$assertf").part" 2>/dev/null \
            && mv -f "$CACHE/$(basename "$assertf").part" "$CACHE/$(basename "$assertf")" 2>/dev/null \
            || rm -f "$CACHE/$(basename "$assertf").part" 2>/dev/null || true
    else
        log "NOTE: no assertion for $name - it will be cached unverified."
    fi
    rm -rf "$tmp" 2>/dev/null || true
    prune_cache "$name"
    return 0
}

# Keep only the newest cached revision per snap so the stick does not grow
# without bound as snaps get refreshed. The .assert and the .snap are pruned as
# a PAIR - keeping an assertion with no snap (or the reverse) is worse than
# keeping neither.
prune_cache() {
    local name="$1" f
    [ -d "$CACHE" ] || return 0
    mapfile -t old < <(ls -1 "$CACHE/${name}"_*.snap 2>/dev/null | sort -V | head -n -1)
    for f in ${old[@]+"${old[@]}"}; do
        rm -f "$f" "$f.assert" 2>/dev/null || true
    done
}

# Install one snap by name. Returns 0 if it is installed by the end.
install_one() {
    local name="$1" cached assert
    if is_installed "$name"; then
        return 0
    fi
    if cached="$(cached_file "$name")"; then
        if assert="$(cached_assert "$name")"; then
            progress "$name: installing from the stick's cache (verified)" "$name (cached)"
            # The verified path: register the assertion, then install offline so
            # snapd checks the snap against it without contacting the store.
            # `snap ack` fails harmlessly if we already know the assertion.
            snap ack "$assert" >/dev/null 2>&1 || true
            if snap install --offline "$cached" >/dev/null 2>&1; then
                return 0
            fi
            log "WARNING: verified offline install of $name failed; retrying from the store."
        else
            progress "$name: installing from the stick's cache (unverified)" "$name (cached)"
            # No assertion was cached (older cache, or snap download was
            # unavailable). --dangerous skips signature checking. We say so
            # rather than hiding it.
            log "WARNING: $name has no cached assertion - installing UNVERIFIED (--dangerous)."
            if snap install --dangerous "$cached" >/dev/null 2>&1; then
                return 0
            fi
            log "WARNING: cached install of $name failed; retrying from the store."
        fi
        # Drop the cache entry so a later boot does not keep serving whatever
        # snapd just refused.
        rm -f "$cached" "$cached.assert" 2>/dev/null || true
    fi
    progress "$name: downloading from the Snap Store (this can take a while)" "$name"
    if snap install "$name" >/dev/null 2>&1; then
        cache_snap_files "$name" || true
        return 0
    fi
    log "WARNING: snap install $name failed (offline, unknown name, or 32-bit)."
    return 1
}

# Snapd retries auto-refresh while offline, which spams the log and can fail
# noisily on a stick that boots without network. Best-effort.
hold_refresh() {
    snap refresh --hold=forever "$1" >/dev/null 2>&1 || \
        log "NOTE: could not hold refresh for $1 (older snapd?); it may try to refresh when online."
}

read_list() {
    # One snap name per line; blank lines and #comments ignored.
    [ -r "$STICK_LIST" ] || return 0
    sed -e 's/#.*//' -e 's/[[:space:]]//g' "$STICK_LIST" 2>/dev/null | grep -v '^$'
}

cmd_ensure() {
    if ! snap_available; then
        log "snapd unavailable (not installed, or non-amd64) - nothing to do."
        return 0
    fi
    if [ ! -r "$STICK_LIST" ]; then
        log "no $STICK_LIST - no snaps requested."
        return 0
    fi
    local names n total i=0 failed=0
    mapfile -t names < <(read_list)
    total="${#names[@]}"
    [ "$total" -gt 0 ] || {
        log "$STICK_LIST is empty - no snaps requested."
        return 0
    }
    log "ensuring $total snap(s) from $STICK_LIST"
    for name in "${names[@]}"; do
        i=$((i + 1))
        if install_one "$name"; then
            hold_refresh "$name"
        else
            failed=$((failed + 1))
            # Deliberately continue: one bad name must not abandon the rest.
        fi
    done
    if [ "$failed" -gt 0 ]; then
        log "$failed of $total snap(s) could not be installed (offline or unknown name)."
    fi
    return 0
}

cmd_install() {
    snap_available || {
        log "snapd unavailable - cannot install."
        return 1
    }
    [ "$#" -ge 1 ] || {
        echo "usage: lsl-snap-fat.sh install <snap>..." >&2
        return 1
    }
    local name rc=0
    for name in "$@"; do
        install_one "$name" && hold_refresh "$name" || rc=1
    done
    return "$rc"
}

cmd_list() {
    echo "list   ($STICK_LIST):"
    read_list | sed 's/^/  /' || true
    echo "installed:"
    installed_snaps | sed 's/^/  /' || true
    echo "cached ($CACHE):"
    ls -1 "$CACHE"/*.snap 2>/dev/null | sed 's/^/  /' || echo "  (none)"
    # Show which cached snaps have a matching assertion, because that is what
    # decides whether a boot can install them verified.
    echo "verified (a .snap.assert alongside each .snap):"
    ls -1 "$CACHE"/*.snap.assert 2>/dev/null | sed 's/\.assert$//' | while read -r f; do
        [ -s "$f" ] && echo "  $(basename "$f")"
    done
}

case "${1:-}" in
    ensure) shift; cmd_ensure "$@" ;;
    install) shift; cmd_install "$@" ;;
    list) shift; cmd_list "$@" ;;
    cleancache)
        rm -rf "${CACHE:?}"/* 2>/dev/null || true
        log "cleared $CACHE"
        ;;
    *)
        sed -n '2,/^set /p' "$0" | sed 's/^# \{0,1\}//; s/^#$//' >&2
        exit 1
        ;;
esac