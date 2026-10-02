#!/bin/sh
# zz_lsl_f2fs_scrub - remove machine-specific files from the persistent upper
# BEFORE casper mounts it.
#
# Part P2 of DESIGN-F2FS-PERSISTENCE.md. Sourced by casper-premount/ORDER at
# casper:926, which is strictly before setup_overlay() creates /cow/upper
# (casper:551-583) and mounts the root overlay (casper:683). At that moment the
# cow device is NOT mounted, so this hook mounts it itself, scrubs, and unmounts.
#
# WHY: a persistent upper carries the previous machine's identity - the netplan /
# NetworkManager profile with a cleartext WPA PSK, hostname, machine-id,
# resolv.conf, autologin user - so the stick would carry one machine's identity
# onto another (WHYFAIL12).
#
# Three rules this file must not break:
#   1. SOURCED, never executed. run_scripts sources ORDER, so a dot-prefixed
#      line runs in casper's shell; an executed hook runs in a subshell where its
#      exports and function overrides are invisible, and its `return` is an error.
#   2. NEVER exit, never panic. It runs inside casper's shell: an `exit` takes the
#      boot down with it. Every failure path returns 0.
#   3. Degrade to "no scrub this boot", never to "no boot".
#
# Opt out with LSL_PERSIST_SCRUB=0, or the lsl_no_f2fs_scrub cmdline flag.
set +e

LSL_SCRUB_LOG=1

lsl_scrub_dbg() {
    [ "${LSL_SCRUB_LOG:-1}" = "1" ] || return 0
    echo "lsl-f2fs-scrub: $*" > /dev/console 2>/dev/null || echo "lsl-f2fs-scrub: $*" >&2
    return 0
}

# ---- opt-out gates -----------------------------------------------------------
grep -qw lsl_no_f2fs_scrub /proc/cmdline 2>/dev/null && return 0 2>/dev/null || exit 0
[ "${LSL_PERSIST:-0}" = "1" ] || return 0 2>/dev/null || exit 0
[ "${LSL_PERSIST_SCRUB:-1}" = "1" ] || return 0 2>/dev/null || exit 0

# The kernel must be able to mount f2fs at all. If not, every later step fails
# and the honest outcome is "no scrub", not a broken boot.
grep -qw f2fs /proc/filesystems 2>/dev/null || return 0 2>/dev/null || exit 0

# ---- find OUR device ---------------------------------------------------------
# By LABEL, never by "the second partition". The design (s8.2) is explicit that
# a partition another tool created (mkusb, a Rufus casper-rw) must not be
# hijacked, so a device without our label is left alone even if it is f2fs.
LSL_SCRUB_LABEL="${LSL_PERSIST_LABEL:-lsl-persist}"
_lsl_dev=""
if [ -b "/dev/disk/by-label/$LSL_SCRUB_LABEL" ]; then
    _lsl_dev="/dev/disk/by-label/$LSL_SCRUB_LABEL"
elif command -v blkid >/dev/null 2>&1; then
    _lsl_dev="$(blkid -L "$LSL_SCRUB_LABEL" 2>/dev/null)"
fi
[ -n "$_lsl_dev" ] && [ -b "$_lsl_dev" ] || return 0 2>/dev/null || exit 0

# Refuse casper's own persistence labels. If the user (or another tool) made a
# casper-rw, mounting and rewriting it is not ours to do.
case "$_lsl_dev" in
    */writable|*/casper-rw)
        lsl_scrub_dbg "device is a casper persistence device, not ours; skipping"
        return 0 2>/dev/null || exit 0 ;;
esac

# ---- mount read-only first ---------------------------------------------------
# Inspect before writing: the device may be dirty or foreign, and a filesystem we
# do not understand must never be modified. Only remount rw once there is
# something to remove.
_lsl_mnt=/mnt/lsl-f2fs-scrub
if ! mountpoint -q "$_lsl_mnt" 2>/dev/null; then
    mkdir -p "$_lsl_mnt" 2>/dev/null
    if ! mount -t f2fs -o ro "$_lsl_dev" "$_lsl_mnt" 2>/dev/null; then
        # F2FS has no fsck equivalent to ext4's journal replay, so a dirty
        # filesystem may refuse a ro mount (design s8.3). That failure means
        # "scrub did not run", which is the SAFE direction, but it is silent -
        # say so.
        lsl_scrub_dbg "cannot mount $_lsl_dev ro (dirty f2fs?); scrub skipped this boot"
        rmdir "$_lsl_mnt" 2>/dev/null
        return 0 2>/dev/null || exit 0
    fi
fi

# The upper may sit at the mount root (fresh, where casper moves it into place)
# or under upper/ (after a boot that used it). Handle both; "neither" is
# nothing-to-do, not an error.
_lsl_upper="$_lsl_mnt/upper"
[ -d "$_lsl_upper" ] || _lsl_upper="$_lsl_mnt"

# The identity list. Keep in sync with lsl_identity_paths() in bin/lsl-common.sh;
# this copy is what the initrd runs, and it only changes on an initrd repack -
# hence the list version in the log line, so a stale stick is diagnosable.
LSL_SCRUB_LIST_V=1
_lsl_paths="
etc/netplan
etc/NetworkManager/system-connections
etc/hostname
etc/hosts
etc/machine-id
etc/resolv.conf
etc/casper.conf
etc/lightdm/lightdm.conf
etc/ssl/certs/ssl-cert-snakeoil.pem
etc/ssl/private/ssl-cert-snakeoil.key
"

_lsl_found=0
for _p in $_lsl_paths; do
    [ -e "$_lsl_upper/$_p" ] && _lsl_found=1
done

if [ "$_lsl_found" != "1" ]; then
    lsl_scrub_dbg "no identity paths in $_lsl_upper (list-v$LSL_SCRUB_LIST_V); nothing to do"
    umount "$_lsl_mnt" 2>/dev/null
    rmdir "$_lsl_mnt" 2>/dev/null
    return 0 2>/dev/null || exit 0
fi

# ---- now write ---------------------------------------------------------------
if ! mount -o remount,rw "$_lsl_mnt" 2>/dev/null; then
    lsl_scrub_dbg "cannot remount rw; scrub skipped this boot"
    umount "$_lsl_mnt" 2>/dev/null
    rmdir "$_lsl_mnt" 2>/dev/null
    return 0 2>/dev/null || exit 0
fi

_lsl_removed=0
for _p in $_lsl_paths; do
    if [ -e "$_lsl_upper/$_p" ]; then
        # rm -rf on the DIRECTORY, not dir/* - removing only the contents leaves
        # an empty directory that some tools read as "no config" and others as
        # "unreadable" (WHYFAIL12 s6).
        rm -rf "$_lsl_upper/$_p" 2>/dev/null && _lsl_removed=$((_lsl_removed + 1))
    fi
done

# Durable before casper mounts the same device: a lazy write landing after
# casper's mount would reintroduce the file we just removed.
sync 2>/dev/null
lsl_scrub_dbg "scrubbed $_lsl_removed identity path(s) from $_lsl_upper (list-v$LSL_SCRUB_LIST_V)"

umount "$_lsl_mnt" 2>/dev/null
rmdir "$_lsl_mnt" 2>/dev/null
return 0 2>/dev/null || exit 0