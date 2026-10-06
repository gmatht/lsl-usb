#!/bin/sh
# zz_lsl_f2fs_provision - CREATE the F2FS persistence partition on first boot.
#
# Part P1b of DESIGN-F2FS-PERSISTENCE.md: lslsetup cannot partition (Windows has
# no way to shrink FAT32), so the stick is carved on the Linux side, at boot.
# The cmdline is the only channel: lsl-usb.env lives ON the medium we are about
# to repartition and is read in userspace by bin/lsl-common.sh, long after this
# window. Reading it here would be both impossible and self-defeating.
# Windows only writes the intent - `lsl_f2fs_provision=<GiB>` on the kernel
# cmdline - and this hook acts on it.
#
# POSIX sh, NOT bash: every file in initramfs/ is #!/bin/sh because the
# initramfs shell is busybox ash (see the note in lsl_hdd_mirror.sh:56). The
# resize logic is re-expressed here rather than shelling out to the bash
# bin/lsl-f2fs-resize, which stays as the operator tool for the userspace path.
#
# Four rules this file must not break:
#   1. SOURCED, never executed. run_scripts sources ORDER, so a dot-prefixed
#      line runs in casper's shell; an executed hook runs in a subshell where its
#      exports are invisible, and its `return` is an error.
#   2. NEVER exit, never panic. It runs inside casper's shell: an `exit` takes
#      the boot down with it. Every failure path returns 0.
#   3. Degrade to "no persistence this boot", never to "no boot".
#   4. NEVER destroy the medium it booted from. Everything below is gated on
#      proving that first - see refuse_* below.
#
# Opt out with LSL_F2FS_NO_PROVISION=1, or the lsl_no_f2fs_provision cmdline
# flag (type it at the GRUB `e` prompt when the stick looks wrong).
set +e

LSL_PROV_LOG=1
LSL_PERSIST_LABEL="${LSL_PERSIST_LABEL:-lsl-persist}"
# The boot medium must keep at least this much FAT. Sized to hold the ISO's
# extracted kernel+initrd, the base squashfs and slack; below this the stick
# could not boot, so refusing is strictly better than a broken stick.
LSL_FAT_MIN_MIB="${LSL_FAT_MIN_MIB:-4096}"
LSL_PROV_LOGDIR=/run/lsl-f2fs

lsl_prov_dbg() {
    [ "${LSL_PROV_LOG:-1}" = "1" ] || return 0
    echo "lsl-f2fs-provision: $*" > /dev/console 2>/dev/null || echo "lsl-f2fs-provision: $*" >&2
    return 0
}

lsl_prov_log() {
    [ "${LSL_PROV_LOG:-1}" = "1" ] || return 0
    # /run dies at reboot, so this is a boot-time record only - the durable
    # evidence is the partition itself plus the userspace warning.
    echo "$(date '+%F %T') $*" >> "$LSL_PROV_LOGDIR/provision.log" 2>/dev/null
    lsl_prov_dbg "$*"
    return 0
}

# ---- park on an unanticipated failure ----------------------------------------
# PID 1 quitting is the kernel panic. This hook is SOURCED into casper's init
# shell, and casper's shell is what ends up as PID 1 - so if anything unwinds
# that shell (a `set -e` abort, a syntax error, a command not found on a
# command-not-found trap, a subshell failure), the kernel panics with "Attempted
# to kill init" and there is no log, no shell, and no machine to debug on.
#
# So an unanticipated exit inside this file parks: dump the state that explains
# it, take a shell if the initrd has one, and sleep forever if it does not. A
# live boot that cannot make progress is strictly better than a panic - the user
# can read the screen, or power off, and the diagnostics name the cause.
#
# WHAT IS *NOT* TREATED AS FATAL: every `lsl_refuse` path. Those are DESIGNED
# outcomes ("a Linux partition is already there", "no f2fs driver in this
# kernel") and the whole safety policy of this file is that each of them
# degrades to a no-op so the boot continues. Parking on those would wedge a
# perfectly healthy boot, which is a worse failure than the one they describe.
# The trap below is therefore armed only for the DESTRUCTIVE WINDOW - from the
# first write to the medium until it has been verified - and lsl_refuse
# disarms it again.
LSL_PARK_STEP="start"
# Set only for real faults. lsl_refuse uses lsl_prov_log, not this.
LSL_PARK_ARMED=0

lsl_park_banner() {
    lsl_prov_dbg ""
    lsl_prov_dbg "=============================================================="
    lsl_prov_dbg "lsl-f2fs-provision STOPPED at step '$LSL_PARK_STEP'"
    lsl_prov_dbg "  cmdline    : $(cat /proc/cmdline 2>/dev/null)"
    lsl_prov_dbg "  wanted     : ${LSL_WANT_GIB:-?} GiB, label '${LSL_PERSIST_LABEL:-?}'"
    lsl_prov_dbg "  stick dev  : ${LSL_STICK_DEV:-<not identified>}"
    lsl_prov_dbg "  stick part : ${LSL_STICK_PART:-<not identified>}"
    lsl_prov_dbg "  disk size  : ${disk_size_sectors:-?} sectors"
    lsl_prov_dbg "  fat        : start=${fat_start:-?} size=${fat_sectors:-?}"
    lsl_prov_dbg "  new layout : fat=${new_fat_sectors:-?} persist=${want_sectors:-?}"
    lsl_prov_dbg "  block devs : $(ls /dev/sd* /dev/vd* /dev/nvme*n* /dev/mmcblk* 2>/dev/null | tr '\n' ' ')"
    lsl_prov_dbg "  mounts     : $(grep -E ' /cdrom | /isodevice | / ' /proc/mounts 2>/dev/null | tr '\n' ' ')"
    lsl_prov_dbg "  holders    : $(ls /sys/class/block/"$(basename "${LSL_STICK_PART:-x}")"/holders/ 2>/dev/null | tr '\n' ' ')"
    lsl_prov_dbg "  log        : $LSL_PROV_LOGDIR/provision.log"
    lsl_prov_dbg "=============================================================="
    return 0
}

# Run the shell BEFORE sleeping, so the boot is still interactive. The initrd
# usually has no shell at all (Mint's casper initrd carries busybox, which has no
# sh applet) - hence the loop that tries each in turn and the unconditional
# sleep afterwards. `set +e` is deliberate: a missing shell must not, itself,
# unwind the very shell we are trying to protect.
lsl_park() {
    LSL_PARK_ARMED=0
    # Remove our own EXIT handler FIRST. We are running *inside* that handler;
    # leaving it installed risks re-entering this function, and casper's shell
    # must not keep a park handler after this hook returns either.
    lsl_park_trap_restore
    lsl_park_banner
    sync 2>/dev/null || true
    set +e
    _lsl_shell=""
    for _lsl_c in sh bash busybox dash; do
        if command -v "$_lsl_c" >/dev/null 2>&1; then
            _lsl_shell="$_lsl_c"
            break
        fi
    done
    if [ -n "$_lsl_shell" ]; then
        echo "lsl-f2fs-provision: dropping to a shell ($_lsl_shell); type 'poweroff' to shut down." > /dev/console 2>/dev/null || true
        # Only busybox needs the applet named explicitly.
        case "$_lsl_shell" in busybox) "$_lsl_shell" sh </dev/console >/dev/console 2>&1 ;; esac
        case "$_lsl_shell" in sh|bash|dash) "$_lsl_shell" </dev/console >/dev/console 2>&1 ;; esac
    else
        lsl_prov_dbg "no shell in this initrd; parking (the boot is alive, the console shows why)."
    fi
    # Never reach here by accident, and never exit - exiting is the panic.
    while true; do sleep 3600; done
}

# Arm the guard for the destructive window only. Set AFTER every read-only gate
# has passed, so the designed refusals above are unaffected.
lsl_park_arm() {
    LSL_PARK_ARMED=1
    # Install the trap HERE, not at definition time: everything between the
    # opt-out gates and this point is a designed no-op that must leave casper's
    # shell exactly as it found it.
    lsl_park_trap_save
    return 0
}

# Stand the guard down: this is a DESIGNED no-op and the boot must continue.
# Every non-fatal exit from the destructive window has to call this - a path
# that returns without disarming would park a perfectly good boot, which is a
# worse outcome than the condition it was reporting.
# Restoring the trap belongs here too, for the same reason: this function is the
# one guaranteed to be on the way OUT of the armed window.
lsl_park_disarm() {
    LSL_PARK_ARMED=0
    lsl_park_trap_restore
    return 0
}

# One-time diagnostics for the designed refusals. A refusal is NOT fatal - it
# degrades to a no-op - but it is the last thing this hook does on that boot, so
# this is the one place worth recording the state that led to it. Bounded and
# best-effort: it must never be the reason the boot fails.
lsl_refuse_dump() {
    _lsl_ref_dev="${LSL_STICK_DEV:-}"
    _lsl_ref_part="${LSL_STICK_PART:-}"
    _lsl_ref_size=""
    [ -n "$_lsl_ref_dev" ] && _lsl_ref_size="$(blockdev --getsz "$_lsl_ref_dev" 2>/dev/null)"
    lsl_prov_log "refused (not fatal, boot continues): disk=${_lsl_ref_dev:-<none>} size=${_lsl_ref_size:-?} sectors part=${_lsl_ref_part:-<none>}"
    lsl_prov_dbg "  cmdline   : $(cat /proc/cmdline 2>/dev/null)"
    lsl_prov_dbg "  block devs: $(ls /dev/sd* /dev/vd* /dev/nvme*n* /dev/mmcblk* 2>/dev/null | tr '\n' ' ')"
    return 0
}

# The refusal helper and the park guard, together, because every gate between
# here and the first write can call one or the other.
#
# A refusal is a DESIGNED no-op - "a Linux partition is already there", "no f2fs
# driver in this kernel" - and the whole safety policy of this file is that each
# degrades to a no-op so the boot continues. It therefore records the state that
# led to it and stands the guard down.
lsl_refuse() {
    lsl_prov_log "REFUSING: $1"
    LSL_PARK_ARMED=0
    # Give casper's shell its own EXIT trap back before returning: a refusal can
    # happen while the guard is armed, and casper must not inherit our handler.
    lsl_park_trap_restore
    lsl_refuse_dump
    return 0 2>/dev/null || exit 0
}

# The guard itself. Armed by lsl_park_arm for the destructive window; when
# something unwinds casper's shell while it is armed, park instead. lsl_park
# never returns, which is the point: PID 1 stays alive.
lsl_park_on_exit() {
    _lsl_rc="$1"
    case "$_lsl_rc" in
        ''|*[!0-9]*) _lsl_rc="unknown" ;;   # dash passes the EXIT status EMPTY
    esac
    if [ "${LSL_PARK_ARMED:-0}" = "1" ]; then
        LSL_PARK_STEP="${LSL_PARK_STEP} (shell unwound, status $_lsl_rc)"
        lsl_park
    fi
    return 0
}

# A trap set inside a SOURCED file belongs to the CALLING shell, and casper then
# keeps running for the rest of the boot. Left installed, this hook's handler
# would fire on casper's own exit - a hook reaching into a shell it does not own,
# and one that would PARK casper's exit if the guard were still armed.
# (Measured: the trap does survive the hook's `return`, and does fire on the
# caller's exit. It does not rewrite the exit status, but that is not the point -
# it must not be there at all.)
#
# So install ours at arm time and remove it on the way out.
#
# A compound handler (anything more than a bare command name) is deliberately
# NOT reconstructed on restore. `trap -p` is not portable - dash prints
# `trap -- 'h' EXIT`, quoting the action AND appending the signal name, so naive
# parsing yields `'h' EXIT` and re-installing that fails and leaves the original
# trap in place. Getting this right across busybox ash, dash and bash from inside
# an initramfs is not worth it, and getting it wrong is worse than not trying.
# Clearing EXIT is safe here because casper sets no EXIT handler of its own (it
# sources every ORDER entry into one long-lived shell that is never reaped by an
# exit trap), so there is nothing to preserve. The save is kept only for the
# simple, unambiguous single-command case.
lsl_park_installed=0

lsl_park_trap_save() {
    LSL_PARK_SAVED=""
    _lsl_saved_raw="$(trap -p EXIT 2>/dev/null | head -n 1)"
    # Accept only `trap -- NAME EXIT` with an unquoted, plain command name.
    _lsl_saved_name="$(printf '%s\n' "$_lsl_saved_raw" \
        | sed -n "s/^trap -- \\([A-Za-z_][A-Za-z0-9_]*\\) EXIT\$/\\1/p")"
    LSL_PARK_SAVED="$_lsl_saved_name"
    trap lsl_park_on_exit EXIT
    lsl_park_installed=1
    return 0
}

lsl_park_trap_restore() {
    [ "${lsl_park_installed:-0}" = "1" ] || return 0
    lsl_park_installed=0
    case "$LSL_PARK_SAVED" in
        '') trap - EXIT 2>/dev/null || : ;;
        # A single command name, split on purpose: `trap NAME EXIT`.
        # shellcheck disable=SC2086
        *)  trap $LSL_PARK_SAVED EXIT 2>/dev/null || trap - EXIT 2>/dev/null || : ;;
    esac
    return 0
}

# ---- opt-out gates -----------------------------------------------------------
# The `if` form, not `[ ... ] && return 0 || exit 0`: in the latter the || fires
# whenever the condition is FALSE (the normal case), and because run_scripts
# SOURCES this hook that would exit casper's own shell and kill the boot.
# All of lsl_park*/lsl_refuse* are DEFINED ABOVE this point: every one of these
# gates can return early, so anything used further down has to be in scope
# already or a boot that exits here would fail with "command not found".
if grep -qw lsl_no_f2fs_provision /proc/cmdline 2>/dev/null; then
    lsl_prov_dbg "DISABLED via lsl_no_f2fs_provision"
    return 0 2>/dev/null || exit 0
fi
[ "${LSL_F2FS_NO_PROVISION:-0}" != "1" ] || return 0 2>/dev/null || exit 0

# ---- read the intent off the cmdline -----------------------------------------
# lsl_f2fs_provision=<GiB>. Absent => the installer did not ask for F2FS, so
# this hook must do nothing at all (it rides along on the boot entry and must
# stay inert for every other backend).
LSL_WANT_GIB=0
for _lsl_arg in $(cat /proc/cmdline 2>/dev/null); do
    case "$_lsl_arg" in
        lsl_f2fs_provision=*)
            LSL_WANT_GIB="${_lsl_arg#lsl_f2fs_provision=}"
            ;;
    esac
done
case "$LSL_WANT_GIB" in
    ''|*[!0-9]*)
        [ -n "$LSL_WANT_GIB" ] && lsl_prov_dbg "ignoring non-numeric lsl_f2fs_provision='$LSL_WANT_GIB'"
        return 0 2>/dev/null || exit 0
        ;;
esac
[ "$LSL_WANT_GIB" -gt 0 ] 2>/dev/null || return 0 2>/dev/null || exit 0

mkdir -p "$LSL_PROV_LOGDIR" 2>/dev/null
lsl_prov_log "asked for ${LSL_WANT_GIB} GiB of lsl-persist"

# ---- already done? then this is a normal boot, not a provisioning boot -------
if [ -b "/dev/disk/by-label/$LSL_PERSIST_LABEL" ]; then
    lsl_prov_dbg "label '$LSL_PERSIST_LABEL' already present; nothing to create"
    return 0 2>/dev/null || exit 0
fi

# The kernel must be able to mount f2fs at all. On the Mint 22.3 casper initrd
# f2fs is NOT builtin - it is a MODULE (the ISO's boot/grub/*/f2fs.mod is the
# giveaway; a builtin filesystem has no .mod), and it ships in the `early3`
# cpio at /usr/lib/modules/<ver>/kernel/fs/f2fs/f2fs.ko.zst. kmod, insmod and
# busybox are all in the `main` cpio, so `modprobe f2fs` is the right call and
# kmod decompresses the .zst itself (no unzstd in the initrd, and none needed).
#
# Measured: a QEMU boot of the real Mint 22.3 initrd with this hook injected
# logged "no f2fs driver in this kernel" and skipped. It had not tried to load
# the module that was sitting right there.
if ! grep -qw f2fs /proc/filesystems 2>/dev/null; then
    if command -v modprobe >/dev/null 2>&1; then
        lsl_prov_log "f2fs not builtin; loading the module from the initrd"
        if modprobe f2fs 2>/dev/null; then
            lsl_prov_log "modprobe f2fs: loaded"
        else
            lsl_prov_log "modprobe f2fs failed; provisioning skipped"
        fi
    fi
fi
if ! grep -qw f2fs /proc/filesystems 2>/dev/null; then
    lsl_prov_log "no f2fs driver available (not builtin, module load failed); provisioning skipped"
    return 0 2>/dev/null || exit 0
fi
# ---- stage the tools --------------------------------------------------------
# casper's initrd carries none of sfdisk/fatresize/mkfs.f2fs, and the live root
# does not exist yet at this point in the boot. They ride in the initrd as
# lsl-tools/f2fs-tools.tar.gz (staged from the ISO's own rootfs by
# scripts/extract-f2fs-tools.sh) and bin/lsl-f2fs-tools.sh unpacks them into
# /run and puts them on PATH. Sourced rather than executed, so the PATH it
# exports reaches this hook in casper's shell - and so a missing unpacker is a
# no-op instead of a subshell whose PATH change is silently discarded.
if [ -r /bin/lsl-f2fs-tools.sh ]; then
    . /bin/lsl-f2fs-tools.sh 2>/dev/null || true
elif [ -r /lsl-tools/lsl-f2fs-tools.sh ]; then
    . /lsl-tools/lsl-f2fs-tools.sh 2>/dev/null || true
fi

for _lsl_tool in sfdisk fatresize mkfs.f2fs; do
    command -v "$_lsl_tool" >/dev/null 2>&1 || {
        lsl_prov_log "tool '$_lsl_tool' missing; provisioning skipped (no persistence this boot)"
        return 0 2>/dev/null || exit 0
    }
done
lsl_prov_log "tools ready: sfdisk/fatresize/mkfs.f2fs on PATH"

# ---- refuse anything mounted, and find the boot medium ----------------------
# THE SAFETY GATE. A partition shrink on a mounted filesystem, or on the wrong
# disk, is unrecoverable data loss. Three independent proofs are required
# before a single byte is written:
#   (a) the medium we boot from is UNMOUNTED,
#   (b) we know which disk it is (by mount, not by guess),
#   (c) the kernel agrees the stick has no loopback pinning it.
# Any failure => no-op. Never a partial attempt.
# (lsl_refuse itself, and the park guard, are defined above the opt-out gates.)

# The kernel's partition node for N on disk DISK. Naming is NOT "<disk>N" for
# every transport: /dev/sdb1 and /dev/mmcblk0p1 both exist, and loop devices
# make it worse - /dev/loop0's first partition is /dev/loop0p1, NOT
# /dev/loop01. Guessing wrong means fatresize targets a path that does not
# exist (silently, under 2>/dev/null) or, worse, the wrong block device.
# Probes both spellings and returns whichever the kernel actually provides.
lsl_part_node() {
    _lsl_disk="$1"
    _lsl_n="$2"
    for _lsl_try in "${_lsl_disk}${_lsl_n}" "${_lsl_disk}p${_lsl_n}"; do
        [ -b "$_lsl_try" ] && { printf '%s' "$_lsl_try"; return 0; }
    done
    # Neither exists yet (the node appears only after partprobe, and a freshly
    # created partition may need a moment). Return the conventional spelling so
    # the caller can report a meaningful path in its refusal.
    case "${_lsl_disk##*/}" in
        *[0-9]) printf '%sp%s' "$_lsl_disk" "$_lsl_n" ;;
        *)       printf '%s%s'  "$_lsl_disk" "$_lsl_n" ;;
    esac
    return 1
}

# (a) the medium holding this boot must NOT be mounted - and we do not try to
# unmount it. Two reasons, both learned the hard way:
#   - A LAZY umount (`umount -l`) detaches the namespace while writeback may
#     still be in flight, which is precisely how you corrupt the filesystem you
#     are about to shrink. A clean umount that FAILS must therefore refuse,
#     not escalate to lazy.
#   - casper needs /cdrom AFTER this hook (it is what holds the squashfs
#     layers). Taking it away would break the boot outright, which is a far
#     worse outcome than no persistence.
# On the normal casper boot this branch never fires: the premount hook runs
# before live-media discovery, so nothing is mounted yet. It exists so that a
# layout which DOES mount first fails safe.
LSL_BOOT_MNT=""
for _lsl_m in /cdrom /live /rofs; do
    if mountpoint -q "$_lsl_m" 2>/dev/null; then
        LSL_BOOT_MNT="$_lsl_m"
        break
    fi
done
if [ -n "$LSL_BOOT_MNT" ]; then
    lsl_refuse "$LSL_BOOT_MNT is mounted; casper still needs it to find the live filesystem, and a failed unmount could leave writes in flight on the device we would shrink. Not touching any disk."
    return 0 2>/dev/null || exit 0
fi

# (b) identify the boot device by CONTENT, never by assuming it is /dev/sda.
# The stick is the volume holding the squashfs layers (casper/filesystem*.squashfs
# or sfs/manifest.txt). Scan for the block device that carries them, mounted
# read-only into a scratch dir. Finding it by content is the only safe way: a
# wrong --disk is how a resize becomes data loss.
#
# WAIT FOR THE BOOT DISK AND ITS PARTITION TABLE FIRST.
#
# At casper-premount the kernel has usually not even finished probing the USB,
# so there are no partition nodes to mount and the scan below sees nothing.
# Measured in a QEMU boot: the hook ran at ~3.4 s, while `virtio_blk` only
# announced `[vda]` at 11.99 s and `vda1` at 12.04 s. An earlier version's log
# line came out interleaved with `[ 3.413689] vda: vda1`, which is the same
# race seen from the other side.
#
# Bounded, because a machine with no USB must still fall through to a logged
# no-op rather than hang the boot.
lsl_wait_for_boot_disk() {
    _lsl_n=0
    while [ "$_lsl_n" -lt 60 ]; do
        for _lsl_d in ${LSL_DISKS:-/dev/sd? /dev/sd?? /dev/vd? /dev/vd?? \
                                        /dev/mmcblk[0-9]* /dev/nvme?n?}; do
            [ -b "$_lsl_d" ] || continue
            case "$(basename "$_lsl_d")" in
                loop*|ram*|dm-*|sr*|fd*|zram*|md*) continue ;;
            esac
            # The disk exists. Nudge its table, then wait for a partition node.
            partprobe "$_lsl_d" 2>/dev/null || true
            blockdev --rereadpt "$_lsl_d" 2>/dev/null || true
            for _lsl_p in "${_lsl_d}"?* "${_lsl_d}"p?*; do
                [ -b "$_lsl_p" ] && return 0 2>/dev/null || exit 0
            done
        done
        _lsl_n=$((_lsl_n + 1))
        sleep 1
    done
    return 0 2>/dev/null || exit 0
}

lsl_wait_for_boot_disk

LSL_SCAN_MNT=/mnt/lsl-provision-scan
if ! mkdir -p "$LSL_SCAN_MNT" 2>/dev/null; then
    lsl_refuse "cannot create $LSL_SCAN_MNT; not touching any disk"
    return 0 2>/dev/null || exit 0
fi
LSL_STICK_DEV=""
LSL_STICK_PART=""
# EVERY match, not just the first. The scan used to `break` on the first hit,
# which meant it never knew it was ambiguous: with two lsl sticks plugged in (the
# user with a spare, the spare being the common case) first-match-wins picks one
# arbitrarily and repartitions it. Collecting all candidates and requiring
# EXACTLY ONE turns that coin flip into a refusal that names the ambiguity.
# The probe is cheap - a read-only mount of an already-present path - so
# scanning the rest costs a few ms and buys certainty we otherwise do not have.
LSL_STICK_DEV_ALL=""
LSL_STICK_PART_ALL=""
# /dev/vd* (virtio) MATTERS: that is what QEMU presents, and also what many
# VMs and some real controllers use. A QEMU boot scanned sd*/mmcblk*/nvme* only,
# found nothing, and refused - so the scan lists every transport the kernel
# could plausibly name, rather than the three most common.
#
# LSL_DISKS / LSL_PARTS are a TEST SEAM, not a feature: the loopback test
# points them at its own device so the scan cannot wander onto a real disk.
# Unset in production, they expand to the full list above.
for _lsl_dev in ${LSL_PARTS:-/dev/sd? /dev/sd?? /dev/vd? /dev/vd?? \
                                     /dev/mmcblk[0-9]*p? /dev/nvme?n?p?}; do
    [ -b "$_lsl_dev" ] || continue
    _lsl_name="$(basename "$_lsl_dev" 2>/dev/null)"
    case "$_lsl_name" in loop*|ram*|dm-*|sr*|fd*|zram*|md*) continue ;; esac
    mkdir -p "$LSL_SCAN_MNT/$_lsl_name" 2>/dev/null || continue
    # Read-only, and noexec/nosuid/nodev: we are only looking for files.
    if mount -o ro,noexec,nosuid,nodev "$_lsl_dev" "$LSL_SCAN_MNT/$_lsl_name" 2>/dev/null; then
        for _lsl_probe in casper/filesystem.squashfs sfs/manifest.txt casper/initrd.lz; do
            if [ -e "$LSL_SCAN_MNT/$_lsl_name/$_lsl_probe" ]; then
                _lsl_hit_disk=""
                # Whole disk = the partition node minus its trailing pN/sdN.
                # NOT ${dev%[0-9]}, which strips a single character and would
                # turn /dev/sdb1 into /dev/sdb (fine) but /dev/nvme0n1p2 into
                # /dev/nvme0n1p (a device that does not exist).
                case "$_lsl_name" in
                    *[0-9]p[0-9]) _lsl_hit_disk="/dev/${_lsl_name%p[0-9]}" ;;
                    *[0-9])       _lsl_hit_disk="/dev/${_lsl_name%[0-9]}" ;;
                    *)            _lsl_hit_disk="$_lsl_dev" ;;
                esac
                # Accumulate, never break. Two PARTITIONS of ONE disk both
                # carrying the payload count once - deduped below - but two
                # different DISKS are two genuinely different mediums, and
                # that is the case this whole check exists for.
                case " $LSL_STICK_DEV_ALL " in
                    *" $_lsl_hit_disk "*) ;;
                    *) LSL_STICK_DEV_ALL="${LSL_STICK_DEV_ALL:+${LSL_STICK_DEV_ALL} }${_lsl_hit_disk}"
                       LSL_STICK_PART_ALL="${LSL_STICK_PART_ALL:+${LSL_STICK_PART_ALL} }$_lsl_dev" ;;
                esac
                break
            fi
        done
        umount "$LSL_SCAN_MNT/$_lsl_name" 2>/dev/null || true
    fi
    rmdir "$LSL_SCAN_MNT/$_lsl_name" 2>/dev/null || true
done
rmdir "$LSL_SCAN_MNT" 2>/dev/null || true

# Count the distinct disks that carried the payload. Whitespace-splitting a
# space-separated list is exactly what the kernel's own cmdline split does
# above, and the values here are kernel-provided device nodes - never user
# input - so no quoting subtlety is involved.
_lsl_match_count=0
for _lsl_cand in $LSL_STICK_DEV_ALL; do
    _lsl_match_count=$((_lsl_match_count + 1))
done

case "$_lsl_match_count" in
    0)
        lsl_refuse "could not identify the boot medium by content; refusing to guess which disk to shrink."
        return 0 2>/dev/null || exit 0
        ;;
    1)
        LSL_STICK_DEV="$LSL_STICK_DEV_ALL"
        LSL_STICK_PART="$LSL_STICK_PART_ALL"
        ;;
    *)
        # AMBIGUOUS. Two or more distinct disks carry the lsl payload, so
        # "which one did Windows mean?" has no answer available here - the
        # cmdline carries only the SIZE, never an identity (see the
        # disk-signature handshake: until that exists this is the only
        # defence). Repartitioning one of them on a guess is precisely the
        # data loss this hook exists to prevent, so refuse and say what was
        # found. The operator can pull the spare stick, or set
        # lsl_no_f2fs_provision and provision by hand.
        # `tr`, NOT `${var// /, }`: that substitution is a bash/ksh extension,
        # and this file is POSIX sh because the initramfs shell is busybox ash
        # (see the header). `tr` is already used by lsl_prov_log and
        # lsl_refuse_dump below, so this adds no new dependency.
        lsl_refuse "the lsl payload is present on ${_lsl_match_count} different disks ($(printf '%s' "$LSL_STICK_DEV_ALL" | tr ' ' ',')) - which one to reshape cannot be determined from the boot alone, and guessing could repartition the wrong one. Unplug the extra stick(s) and boot again, or add lsl_no_f2fs_provision to the kernel command line to skip provisioning."
        return 0 2>/dev/null || exit 0
        ;;
esac
lsl_prov_log "boot medium: ${LSL_STICK_PART} on ${LSL_STICK_DEV}"

# (c) nothing may still be holding the FAT partition: an ISO loop from an
# iso-scan boot, or a stale loop from a previous layer mount. A holder makes
# fatresize/sfdisk unsafe even with nothing mounted.
#
# The precise test is the kernel's holder links, NOT `losetup -a`. A loop over
# an ISO FILE ON THIS STICK reports only the file path
# (`/dev/loop0: [] (/cdrom/linuxmint.iso)`), which does not mention the disk -
# so the obvious `losetup -a | grep $disk` misses exactly the case that matters
# most. /sys/class/block/<part>/holders/ names whatever device has the
# partition open.
_lsl_holders="$(ls /sys/class/block/"$(basename "$LSL_STICK_PART")"/holders/ 2>/dev/null)"
if [ -n "$_lsl_holders" ]; then
    # POSIX-safe trim: drop the newlines `ls` added, for a one-line message.
    _lsl_holders="$(printf '%s' "$_lsl_holders" | tr '\n' ' ')"
    lsl_refuse "something still holds $LSL_STICK_PART (holder(s): ${_lsl_holders} ) - a loop over an ISO on this stick would make the resize unsafe. Refusing."
    return 0 2>/dev/null || exit 0
fi

# Never operate on anything that is itself a partition node.
if [ -e "/sys/class/block/$(basename "$LSL_STICK_DEV")/partition" ]; then
    lsl_refuse "$LSL_STICK_DEV is a partition, not a whole disk; refusing"
    return 0 2>/dev/null || exit 0
fi

# ---- read the on-disk layout ------------------------------------------------
# The guard goes live HERE: every gate above is read-only and a refusal there
# must leave the boot alone, but from this point on we are about to rewrite a
# partition table. An unwind inside this window would be both the most likely
# to happen and the most expensive - so park instead of dying.
LSL_PARK_STEP="read-layout"
lsl_park_arm
# UNITS (measured, util-linux 2.37): `sfdisk` uses SECTORS for `size=` in BOTH
# directions - the input we write below and the `-d` output we read here
# (`10240` means 5 MiB, not 10). That agreement is what makes the arithmetic in
# this file correct. If one side were KiB, every figure here would be 1024x off
# and the carve would produce a filesystem far larger than its partition - the
# silent corruption the BPB check below exists to catch.
SECTOR_SIZE=512
disk_size_sectors="$(blockdev --getsz "$LSL_STICK_DEV" 2>/dev/null)"
table="$(sfdisk -d "$LSL_STICK_DEV" 2>/dev/null)"
if [ -z "$disk_size_sectors" ] || [ -z "$table" ]; then
    lsl_refuse "could not read the layout of $LSL_STICK_DEV (blockdev/sfdisk unavailable?)"
    return 0 2>/dev/null || exit 0
fi
# Log what we actually got. A QEMU run refused with "could not parse the
# geometry" while the table was non-empty, and there was no way to tell an
# empty table from a format we failed to match - the single most expensive
# thing to debug in a boot that cannot be stepped through.
lsl_prov_log "layout of $LSL_STICK_DEV (${disk_size_sectors} sectors): $(printf '%s' "$table" | tr '\n' '|')"

# A second, non-FAT partition already present: another tool owns it. Never
# touch a partition we did not create (design s8.2 - the same rule the scrub
# applies). lsl-f2fs-resize exits 2 here; we treat it as "nothing to do".
if printf '%s\n' "$table" | grep -qiE 'Linux|0x83'; then
    lsl_prov_dbg "$LSL_STICK_DEV already has a Linux partition; not ours to reshape"
    lsl_park_disarm
    return 0 2>/dev/null || exit 0
fi

# Parse the FIRST partition line of `sfdisk -d`, which looks like:
#
#   /dev/vda1 : start=        2048, size=    12580864, type=c, bootable
#
# Two earlier attempts were wrong, both caught by running the real thing:
#   1. `awk -F'[:,]' ... print $2` - `:` separates BEFORE the first `=` ever
#      appears, so field 2 is the DEVICE NAME and both values came out as the
#      literal string "start=2048", failing the all-digits test every time.
#   2. `grep 'start=' | head -1` - grep matches (a diagnostic `grep -c` in the
#      guest reported 1) but head closes the pipe and grep dies on SIGPIPE
#      before flushing, so the match is never printed and the hook sees an
#      empty string. `sed -n '1p'` reads the first line and stops instead.
#
# So: pick the line with a literal `start=`, no character classes, and take
# the first line with sed rather than head.
#
# Also NOT a function: a QEMU boot logged a perfect table and still got
# start='' size='', so the helper must be inlined where the variable lives.
_part_line="$(printf '%s\n' "$table" | grep 'start=' | grep -v '^label' | sed -n '1p')"
fat_start="$(printf '%s\n' "$_part_line" | sed -n 's/.*start=[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
fat_sectors="$(printf '%s\n' "$_part_line" | sed -n 's/.*size=[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
case "$fat_start$fat_sectors" in
    ''|*[!0-9]*)
        # EMPTY (not merely malformed) is the expected case here, and the cause
        # is a RACE, not a bad stick: at casper-premount the kernel has
        # registered the disk but has usually not yet read its partition table.
        # A QEMU boot shows the ordering exactly - the hook's own log line is
        # interleaved with `[ 3.413689] vda: vda1`, i.e. the partition node
        # appeared a fraction of a second AFTER we looked for it.
        #
        # So: wait for the partition node, bounded. udevadm settle alone is not
        # enough (there may be no udev in the initrd), so poll directly.
        if [ -z "$fat_start" ]; then
            lsl_prov_log "no partition entries yet; waiting for the partition table to be read"
            _lsl_try=0
            while [ "$_lsl_try" -lt 20 ]; do
                partprobe "$LSL_STICK_DEV" 2>/dev/null || true
                blockdev --rereadpt "$LSL_STICK_DEV" 2>/dev/null || true
                table="$(sfdisk -d "$LSL_STICK_DEV" 2>/dev/null)"
                _part_line="$(printf '%s\n' "$table" | grep 'start=' | grep -v '^label' | sed -n '1p')"
                fat_start="$(printf '%s\n' "$_part_line" | sed -n 's/.*start=[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
                fat_sectors="$(printf '%s\n' "$_part_line" | sed -n 's/.*size=[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
                case "$fat_start$fat_sectors" in
                    ''|*[!0-9]*) _lsl_try=$((_lsl_try + 1)); sleep 1 ;;
                    *)
                        lsl_prov_log "partition table readable after ${_lsl_try}s"
                        break
                        ;;
                esac
            done
        fi
        case "$fat_start$fat_sectors" in
            ''|*[!0-9]*)
                lsl_refuse "could not read the FAT partition geometry from $LSL_STICK_DEV after 20s (start='$fat_start' size='$fat_sectors'); not touching the disk"
                return 0 2>/dev/null || exit 0
                ;;
        esac
        ;;
esac

fat_end=$(( fat_start + fat_sectors ))
LSL_PARK_STEP="check-fat-size"
fat_min_sectors=$(( LSL_FAT_MIN_MIB * 1024 * 1024 / SECTOR_SIZE ))
[ "$fat_sectors" -ge "$fat_min_sectors" ] || {
    lsl_refuse "the FAT partition is only $(( fat_sectors * SECTOR_SIZE / 1024 / 1024 )) MiB; it must stay at ${LSL_FAT_MIN_MIB} MiB to hold the image. Not touching the disk."
    return 0 2>/dev/null || exit 0
}

# The space for partition 2 comes OUT OF THE FAT PARTITION, not from whatever
# happens to trail it.
#
# This was a real bug, found by a QEMU boot of an image built the way the nofmt
# installer builds one: `,,c,*` makes ONE partition filling the whole disk, so
# trailing free space is ZERO and this hook refused with "the FAT partition
# already runs to the end of the disk". Which is every ordinary stick - the
# refusal was unconditional, and the loopback test had hidden it by leaving
# slack after the FAT.
#
# So the only real constraint is that FAT must keep enough room for the image
# (LSL_FAT_MIN_MIB); anything above that is available to carve.
want_sectors=$(( LSL_WANT_GIB * 1024 * 1024 * 1024 / SECTOR_SIZE ))
max_take=$(( fat_sectors - fat_min_sectors ))
[ "$max_take" -gt 0 ] || {
    lsl_refuse "the FAT partition is $(( fat_sectors * SECTOR_SIZE / 1024 / 1024 )) MiB and must keep ${LSL_FAT_MIN_MIB} MiB, so there is nothing to carve. Not touching the disk."
    return 0 2>/dev/null || exit 0
}
[ "$want_sectors" -le "$max_take" ] || want_sectors="$max_take"
new_fat_sectors=$(( fat_sectors - want_sectors ))
[ "$new_fat_sectors" -ge "$fat_min_sectors" ] || {
    lsl_refuse "taking ${LSL_WANT_GIB} GiB would leave FAT below the ${LSL_FAT_MIN_MIB} MiB minimum. Not touching the disk."
    return 0 2>/dev/null || exit 0
}

# The new partition starts where the shrunk FAT will end, and runs to the end
# of the disk - so trailing free space, when there is any, is absorbed too.
fat_end=$(( fat_start + new_fat_sectors ))
new_end=$(( disk_size_sectors ))

# The shrink must stay INSIDE FAT32. fatresize offers to convert to FAT16 when
# the target is below the FAT32 cluster limit, and on an unattended boot it
# takes EOF at that prompt and ABORTS (measured: exit 1, BPB untouched) - so a
# carve that would cross the boundary fails for a reason that has nothing to
# do with the disk. Keep at least this much FAT, or refuse with the reason.
# 65525 clusters is the FAT32 limit; a cluster is sectors_per_cluster * 512 B.
lsl_fat32_min_bytes=$(( 65525 * 8192 ))
lsl_fat32_min_sectors=$(( lsl_fat32_min_bytes / SECTOR_SIZE ))
if [ "$new_fat_sectors" -lt "$lsl_fat32_min_sectors" ]; then
    lsl_refuse "keeping $(( new_fat_sectors * SECTOR_SIZE / 1024 / 1024 )) MiB of FAT would fall below the FAT32 limit (~$(( lsl_fat32_min_bytes / 1024 / 1024 )) MiB), and fatresize would demand a FAT16 conversion that cannot be answered unattended. Not touching the disk."
    return 0 2>/dev/null || exit 0
fi

persist_mib=$(( want_sectors * SECTOR_SIZE / 1024 / 1024 ))
LSL_PARK_STEP="shrink-filesystem"

# LAST gate before the first write, and the only one that treats an
# inconsistency as FATAL rather than as a refusal. Everything above it is a
# legitimate "this stick is not ours to reshape" outcome. This is different:
# the numbers came from THIS file's own arithmetic, so an impossible layout
# here means the arithmetic is wrong (a unit confusion between sectors and
# bytes, or a truncated sfdisk read). Writing that to a partition table is
# unrecoverable, and every guard further down assumes the geometry is sane.
# Park with the numbers on the console rather than reshape a stick on a figure
# we know to be self-contradictory.
if [ "$fat_start" -lt 1 ] || [ "$want_sectors" -lt 1 ] || [ "$disk_size_sectors" -lt 1 ] \
   || [ "$fat_end" -ge "$disk_size_sectors" ] || [ "$(( fat_end + want_sectors ))" -gt "$disk_size_sectors" ]; then
    lsl_prov_log "FATAL: computed layout does not fit the disk"
    lsl_park
fi

lsl_prov_log "shrink FAT $(( fat_sectors * SECTOR_SIZE / 1024 / 1024 )) -> $(( new_fat_sectors * SECTOR_SIZE / 1024 / 1024 )) MiB, add ${persist_mib} MiB f2fs"

# ---- 1. shrink the FILESYSTEM first -----------------------------------------
# Order is not stylistic. A partition shrink is not a filesystem shrink: sfdisk
# will happily cut the partition while the filesystem still claims the old
# size, and the result MOUNTS with no error, then fails on any access past the
# boundary (measured: partition 200 MB, filesystem claiming 536 MB, fsck
# "Seek to 535803392: Invalid argument"). And fatresize -s on an unmounted
# loopback partition was measured to exit 0, print a banner, and leave the BPB
# untouched - so success is decided by re-reading the BPB, never by the exit
# code.
fat_part="${LSL_STICK_PART}"
[ -b "$fat_part" ] || fat_part="$(lsl_part_node "$LSL_STICK_DEV" 1)"
# fatresize INTERACTS: shrinking below the FAT32 limit makes it offer
# "OK/Cancel:" to convert to FAT16, and with no tty it takes EOF and aborts
# (measured: exit 1, BPB untouched). Feed it "no" so it declines
# deterministically instead of blocking or half-doing it, and check the exit
# status - the BPB verification below is what actually decides whether the
# filesystem shrank, since fatresize is known to exit 0 without changing
# anything.
if ! printf 'no\n' | fatresize -s "$(( new_fat_sectors * SECTOR_SIZE / 1024 / 1024 ))M" "$fat_part" >/dev/null 2>&1; then
    lsl_prov_log "fatresize declined or failed; verifying the geometry anyway"
fi

# The partition node must EXIST before we can read the BPB through it. The
# content scan above mounted the partition successfully, so it existed then;
# a QEMU boot still hit "could not read the FAT BPB", so it did not survive to
# this point (or was never a node we can open - see lsl_part_node). Wait for it
# rather than assuming, then read.
[ -b "$fat_part" ] || {
    partprobe "$LSL_STICK_DEV" 2>/dev/null || true
    sleep 1
}
# Read the FAT BPB's TOTAL-SECTORS field, and OFFSET 32 is where it lives.
#
#     0   jmp / OEM name      11  bytes/sector    13  sectors/cluster
#     19  volume serial       32  TOTAL SECTORS   36  sectors per FAT
#
# This read OFFSET 19 for a long time, which is the volume serial number - a
# random 32-bit value fixed at mkfs time. Measured: it returned the constant
# 16252928 for filesystems of 512 MiB, 1 GiB and 2 GiB alike, so the guard was
# comparing a volume ID against a partition size and never meant anything. The
# real total at offset 32 tracked the file size (1048572 for the 512 MiB image)
# and is the value that moves when fatresize shrinks the filesystem.
# (The same wrong offset was in bin/lsl-f2fs-resize; both are fixed.)
#
# `od` is STAGED, because casper's initrd has none: no /usr/bin/od, no
# hexdump, no xxd, and busybox carries no such applet either (all measured in
# the running guest). Without it this returns nothing and the guard is dead.
bpb_sectors="$(dd if="$fat_part" bs=1 skip=32 count=4 2>/dev/null | od -An -tu4 | tr -d ' ')"
LSL_PARK_STEP="verify-fs-geometry"
case "$bpb_sectors" in
    ''|*[!0-9]*)
        # The partition node can still be missing here even though the content
        # scan found it by CONTENT - it may have appeared between the two steps,
        # or been removed. Re-read the table once to force it back, then give up.
        lsl_refuse "could not read the FAT BPB from $fat_part (partition node not ready?); NOT shrinking the partition. The stick is unchanged."
        return 0 2>/dev/null || exit 0
        ;;
esac
if [ "$bpb_sectors" -gt "$new_fat_sectors" ]; then
    lsl_refuse "the filesystem still claims $bpb_sectors sectors but the partition would be only $new_fat_sectors. Shrinking now would leave the filesystem larger than its partition: it mounts without error and then fails past the boundary. Refusing rather than corrupting the stick."
    return 0 2>/dev/null || exit 0
fi
lsl_prov_log "filesystem verified at $bpb_sectors sectors (target $new_fat_sectors)"

# ---- 2. now shrink the partition and add the second one ---------------------
# First write to the medium. If anything unwinds from here, the stick may be
# half-reshaped - which is exactly the case where dying is least acceptable.
LSL_PARK_STEP="rewrite-partition-table"
printf 'label: dos\n1 : start=%s, size=%s, type=0c\n2 : start=%s, size=%s, type=83\n' \
    "$fat_start" "$new_fat_sectors" "$fat_end" "$want_sectors" \
    | sfdisk --no-reread --force "$LSL_STICK_DEV" >/dev/null 2>&1 || {
    lsl_refuse "sfdisk failed to rewrite the partition table. The FAT filesystem was already shrunk to ${bpb_sectors} sectors, which is still consistent with its partition - the stick remains bootable."
    return 0 2>/dev/null || exit 0
}

partprobe "$LSL_STICK_DEV" 2>/dev/null || true
udevadm settle 2>/dev/null || sleep 1

persist_part="$(lsl_part_node "$LSL_STICK_DEV" 2)"
if [ ! -b "$persist_part" ]; then
    lsl_prov_log "partition 2 did not appear after the repartition (the kernel may need a re-read). The FAT partition is intact; persistence will be available after a reboot."
    lsl_park_disarm
    return 0 2>/dev/null || exit 0
fi

# ---- 3. format it f2fs, by label ---------------------------------------------
LSL_PARK_STEP="format-f2fs"
if mkfs.f2fs -q -l "$LSL_PERSIST_LABEL" "$persist_part" 2>/dev/null; then
    sync 2>/dev/null
    lsl_prov_log "done: $persist_part is f2fs, label '$LSL_PERSIST_LABEL', ${persist_mib} MiB"
else
    lsl_refuse "mkfs.f2fs failed on $persist_part. The FAT partition is intact and unchanged in size; the stick still boots."
    return 0 2>/dev/null || exit 0
fi

# The new label must be visible to the rest of this boot. casper resolves
# /dev/disk/by-label through udev, which may not have re-scanned yet; without
# this the mount in lsl-mount-home.sh falls back to a RAM upper and /home does
# not persist even though the partition is right there.
udevadm settle 2>/dev/null || true
sync 2>/dev/null

# ---- 4. write the `post` receipt --------------------------------------------
# A RECEIPT, not a backup: the pre-repartition state no longer exists on this
# medium (the shrink and the table rewrite above have both landed), so this
# cannot recover anything. What it is good for is telling a human what actually
# happened - "partition 1 went 12 GiB -> 10 GiB, partition 2 was created" - so a
# manual recovery is informed rather than guesswork. The RESTORABLE geometry is
# in the `pre` record lslsetup wrote.
#
# It goes to partition 1 (the FAT stick), never to the fresh lsl-persist: that
# partition is brand-new and empty by definition, and the first thing it will
# hold is the user's /home.
#
# Written with a temporary name and renamed into place, so a reader (or a crash)
# never sees a half-written JSON file - which would parse as corrupt and be
# discarded, losing the receipt.
#
# EVERY failure here is swallowed. This runs after the repartition succeeded and
# the boot is otherwise fine; a receipt that cannot be written must never be the
# thing that breaks it. The guard is already disarmed above.
lsl_write_post_record() {
    local mnt=/mnt/lsl-post-record
    local dir="$mnt/lsl-partition-backup"
    local stamp ts file tmp
    mkdir -p "$mnt" 2>/dev/null || return 0
    # Read-write: this is where the record has to go. Same medium casper mounts
    # as /cdrom a moment later, and we unmount before returning.
    mount "$fat_part" "$mnt" 2>/dev/null || { lsl_prov_log "post-record: could not mount $fat_part; no receipt written"; return 0; }
    if mkdir -p "$dir" 2>/dev/null; then
        ts="$(date -u '+%y%m%d:%H%M%S' 2>/dev/null)"
        case "$ts" in
            ''|*[!0-9:]*) lsl_prov_log "post-record: date unavailable; no receipt written"; umount "$mnt" 2>/dev/null; return 0 ;;
        esac
        # The machine prefix is a stable hash of the motherboard identity. The
        # hook has no WMI, so use the DMI id if it is readable and fall back to
        # a marker; the restore tool reads the full geometry from the value, so
        # a coarse prefix costs nothing but a slightly longer key.
        local mid="UNK"
        if [ -r /sys/class/dmi/id/board_name ]; then
            mid="$(cat /sys/class/dmi/id/board_name 2>/dev/null | tr -cd 'A-Za-z0-9' | cut -c1-6 | tr 'a-z' 'A-Z')"
            [ -n "$mid" ] || mid="UNK"
        fi
        file="$dir/${mid}${ts}.json"
        tmp="$file.tmp"
        # Hand-rolled JSON rather than a tool: the initrd has no jq, and the
        # values are integers and hex we produced ourselves, so nothing here can
        # contain a quote or a backslash that needs escaping. Every numeric
        # field is a variable this file has already validated as digits.
        if cat > "$tmp" 2>/dev/null <<EOF
{
  "timestamp": "${ts}",
  "phase": "post",
  "vol_letter": "",
  "lslsetup_version": "",
  "motherboard": "${mid}",
  "windows_version": "",
  "disks": [
    {
      "size_sectors": ${disk_size_sectors},
      "scheme": "mbr",
      "entries": [
        { "index": 1, "start_sectors": ${fat_start}, "size_sectors": ${new_fat_sectors}, "type_id": "0c", "bootable": true, "label": "" },
        { "index": 2, "start_sectors": ${fat_end}, "size_sectors": ${want_sectors}, "type_id": "83", "bootable": false, "label": "${LSL_PERSIST_LABEL}" }
      ],
      "fs_size_sectors": ${bpb_sectors},
      "head_sectors_hex": ""
    }
  ]
}
EOF
        then
            mv -f "$tmp" "$file" 2>/dev/null && lsl_prov_log "post-record: wrote $file"
            rm -f "$tmp" 2>/dev/null || true
        else
            lsl_prov_log "post-record: write failed; no receipt"
        fi
    else
        lsl_prov_log "post-record: could not create $dir; no receipt written"
    fi
    sync 2>/dev/null || true
    umount "$mnt" 2>/dev/null || true
    rmdir "$mnt" 2>/dev/null || true
    return 0
}
lsl_write_post_record

# Done: stand the guard down and hand casper its EXIT trap back, so the caller's
# own exit unwinds its shell exactly as it did before this hook existed.
lsl_park_disarm
return 0 2>/dev/null || exit 0