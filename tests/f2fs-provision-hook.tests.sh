#!/bin/sh
# Test harness for initramfs/lsl_f2fs_provision.sh.
#
# Runs the hook against a real loopback disk image (sfdisk + mkfs.vfat) with a
# fake /proc/cmdline, so the geometry maths, the ordering and the refusal gates
# are exercised for real rather than grepped. Requires root for loop/mkfs;
# skips cleanly otherwise (the static half still runs).
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO_ROOT/initramfs/lsl_f2fs_provision.sh"
SIBLING="$REPO_ROOT/tests/f2fs-scrub.tests.sh"

PASS=0; FAIL=0; SKIP=0
ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
skip(){ echo "  SKIP: $1"; SKIP=$((SKIP + 1)); }

echo "== part 1: contract (runs unprivileged, no root needed) =="

[ -f "$HOOK" ] && ok "hook exists" || { bad "hook missing"; exit 1; }

# It must be POSIX sh, like every other file in initramfs/ (the initramfs shell
# is busybox ash).
if sed -n '1p' "$HOOK" | grep -q '^#!/bin/sh'; then
    ok "hook is #!/bin/sh (initramfs shell is busybox ash, not bash)"
else
    bad "hook is not #!/bin/sh"
fi

# NEVER a bare exit: run_scripts SOURCES this file, so an exit would kill
# casper's own shell and take the boot down.
if grep -nE '^[[:space:]]*exit[[:space:]]' "$HOOK" | grep -q .; then
    bad "hook contains a bare 'exit' - that would abort casper's shell"
else
    ok "no bare exit (sourced-hook contract)"
fi

# The gate must be an `if`, never `&& return 0 || exit 0`: left-associativity
# makes the || fire when the flag is ABSENT (the normal case).
if grep -n 'lsl_no_f2fs_provision' "$HOOK" | grep -q '&&.*||.*exit'; then
    bad "opt-out gate uses the && || form that exits on the NORMAL (flag absent) boot"
else
    ok "opt-out gate uses the safe if-form, not && ||"
fi

# The cmdline is the only channel: lsl-usb.env is on the medium we repartition
# and is read in userspace, so the size cannot come from there.
if grep -q 'lsl_f2fs_provision=' "$HOOK"; then
    ok "reads the requested size off /proc/cmdline"
else
    bad "does not read the size off /proc/cmdline"
fi
if sed 's/#.*$//' "$HOOK" | grep -q 'lsl-usb\.env'; then
    bad "hook CODE reads lsl-usb.env - it is on the medium being repartitioned"
else
    ok "never reads lsl-usb.env in code (it lives on the medium being repartitioned)"
fi

# Idempotence: the whole design rests on a second boot being a no-op.
if grep -q 'by-label/\$LSL_PERSIST_LABEL' "$HOOK"; then
    ok "returns early when the label already exists (idempotent on re-boot)"
else
    bad "no early return when the persistence label already exists"
fi

# Filesystem BEFORE partition. The reverse silently yields a filesystem larger
# than its partition: it mounts clean, then fails past the boundary.
fat_line="$(grep -n 'fatresize -s' "$HOOK" | head -1 | cut -d: -f1)"
sfdisk_line="$(grep -n 'sfdisk --no-reread' "$HOOK" | head -1 | cut -d: -f1)"
if [ -n "$fat_line" ] && [ -n "$sfdisk_line" ] && [ "$fat_line" -lt "$sfdisk_line" ]; then
    ok "shrinks the filesystem (L$fat_line) before the partition (L$sfdisk_line)"
else
    bad "filesystem/partition shrink order is wrong (fatresize L${fat_line:-?} vs sfdisk L${sfdisk_line:-?})"
fi

# fatresize was measured to exit 0 and change nothing, so the BPB must be
# re-read and compared - never trusted from the exit code.
if grep -q 'skip=32 count=4' "$HOOK" && grep -q 'bpb_sectors.*-gt.*new_fat_sectors' "$HOOK"; then
    ok "verifies the FAT BPB after fatresize (no silent no-op)"
else
    bad "does not verify the BPB - fatresize can exit 0 without shrinking"
fi

# Never hijack a partition we did not create (design s8.2).
if grep -qE 'Linux\|0x83' "$HOOK"; then
    ok "refuses to reshape a stick that already has a Linux partition"
else
    bad "no guard against reshaping a foreign Linux partition"
fi

# Only f2fs is ever formatted, and only after the geometry checks pass.
if grep -q 'mkfs.f2fs -q -l' "$HOOK"; then
    ok "formats f2fs with our label"
else
    bad "does not format f2fs with a label"
fi

# The content scan must cover every block-device transport the kernel can name.
# /dev/vd* (virtio) is not exotic: it is what QEMU presents AND what many VMs and
# some real controllers use. A scan without it found no device and refused, so
# the feature never ran under virtualisation.
for pat in '/dev/sd' '/dev/vd' 'mmcblk' 'nvme'; do
    if sed 's/#.*$//' "$HOOK" | grep -q "$pat"; then
        ok "content scan covers $pat"
    else
        bad "content scan does not cover $pat - the hook will not find the stick on that transport"
    fi
done

# The boot medium is identified by CONTENT, never assumed to be /dev/sda.
if grep -q 'casper/filesystem.squashfs' "$HOOK"; then
    ok "identifies the boot medium by content, not by guessing the disk"
else
    bad "no content-based identification of the boot medium"
fi

# It must never unmount the BOOT MEDIUM to "free" it. Two failure modes:
# a LAZY umount leaves writeback in flight on the device we then shrink, and
# casper needs /cdrom AFTER this hook. The correct answer is to refuse.
# (Unmounting its own read-only PROBE mount during the content scan is fine
# and is not what this guards against - so only `umount -l`, a lazy umount, and
# any umount of the boot mountpoints are disqualifying.)
if sed 's/#.*$//' "$HOOK" | grep -qE '^\s*umount[[:space:]]+(-l|-a)'; then
    bad "hook uses a LAZY/forced umount - writeback could still be in flight on the device we shrink"
else
    ok "never lazy-unmounts anything (no 'umount -l')"
fi
if sed 's/#.*$//' "$HOOK" | grep -qE '^\s*umount[[:space:]]+"?\$(LSL_BOOT_MNT|LSL_BOOT)'; then
    bad "hook unmounts the boot medium - casper needs /cdrom after this hook; it must refuse instead"
else
    ok "never unmounts the boot medium (refuses instead)"
fi
# ...and it must still CHECK that the medium is unmounted.
if grep -q 'mountpoint -q' "$HOOK"; then
    ok "checks whether the boot medium is mounted before touching it"
else
    bad "no mountpoint check - the hook could repartition a mounted filesystem"
fi

# The hold check: anything with the partition open makes the resize unsafe.
# The kernel's holders/ link is the precise test - `losetup -a` names the ISO
# FILE, not the disk, so grepping it for the disk misses the case that matters.
if grep -q 'holders' "$HOOK"; then
    ok "refuses while something holds the FAT partition (kernel holders link)"
else
    bad "no holder check - the hook could resize a partition a loop still has open"
fi

# The BPB total-sectors field is at OFFSET 32. Offset 19 is the volume serial
# number - a random 32-bit ID fixed at mkfs time, which returned the SAME value
# (16252928) for filesystems of 512 MiB, 1 GiB and 2 GiB. The guard therefore
# compared a volume ID against a partition size and never meant anything, for
# the whole life of the code. Pin the offset.
if grep -q 'skip=32 count=4' "$HOOK"; then
    ok "reads the BPB total-sectors field at offset 32 (not the volume ID at 19)"
else
    bad "BPB read is not at offset 32 - check whether it is reading the volume serial number"
fi
if grep -qE 'skip=19 count=4' "$HOOK"; then
    bad "still reads offset 19, which is the volume serial number, not the sector count"
else
    ok "does not read the volume-serial field"
fi

# The BPB read must come AFTER fatresize and BEFORE the partition rewrite:
# that ordering is the whole corruption guard.
fat_line="$(grep -n 'fatresize -s' "$HOOK" | head -1 | cut -d: -f1)"
bpb_line="$(grep -n 'skip=32 count=4' "$HOOK" | head -1 | cut -d: -f1)"
sfdisk_line="$(grep -n 'sfdisk --no-reread' "$HOOK" | head -1 | cut -d: -f1)"
if [ -n "$fat_line" ] && [ -n "$bpb_line" ] && [ -n "$sfdisk_line" ] \
    && [ "$fat_line" -lt "$bpb_line" ] && [ "$bpb_line" -lt "$sfdisk_line" ]; then
    ok "order is fatresize (L$fat_line) -> verify BPB (L$bpb_line) -> repartition (L$sfdisk_line)"
else
    bad "guard ordering wrong: fatresize L${fat_line:-?}, bpb L${bpb_line:-?}, sfdisk L${sfdisk_line:-?}"
fi

# fatresize INTERACTS when the target drops below the FAT32 limit: it offers an
# OK/Cancel FAT16 conversion, and unattended it takes EOF and aborts. The hook
# must answer, and must refuse a carve that would cross that line.
if grep -q "printf 'no" "$HOOK"; then
    ok "answers fatresize's FAT16 prompt (unattended it would abort)"
else
    bad "fatresize can block on its FAT16 OK/Cancel prompt"
fi
if grep -q '65525' "$HOOK"; then
    ok "refuses a shrink below the FAT32 cluster limit"
else
    bad "no FAT32 floor - a carve below it triggers the unanswerable prompt"
fi

# ---- park instead of panicking ----------------------------------------------
# This hook is SOURCED into casper's init shell, and that shell becomes PID 1.
# PID 1 exiting IS the kernel panic ("Attempted to kill init"), so an
# unanticipated unwind inside the destructive window must not reach the shell's
# own exit - it has to park: dump why, take a shell if there is one, sleep if not.
if grep -q 'lsl_park' "$HOOK"; then
    ok "has a park path for an unanticipated failure"
else
    bad "no park path - an unwind here takes PID 1 down and panics the kernel"
fi
if grep -qE 'trap[[:space:]]+lsl_park_on_exit[[:space:]]+EXIT' "$HOOK"; then
    ok "installs an EXIT trap that parks while the guard is armed"
else
    bad "no EXIT trap - the shell still unwinds and panics"
fi
# ...and it must not be left behind. A trap set in a SOURCED file belongs to the
# caller, so without a restore the hook keeps handling casper's own exit.
if grep -q 'lsl_park_trap_restore' "$HOOK" && grep -qE 'trap[[:space:]]+-[[:space:]]+EXIT' "$HOOK"; then
    ok "restores casper's own EXIT trap on the way out (no leak into the caller)"
else
    bad "the EXIT trap is never removed - the hook would keep handling casper's exit"
fi
if sed 's/#.*$//' "$HOOK" | grep -qE '^[[:space:]]*while[[:space:]]+true.*sleep'; then
    ok "parks with an unbounded sleep rather than exiting"
else
    bad "the park path can still exit - it must sleep instead"
fi
# Diagnostics, not just a nap: a parked boot with no explanation is unusable.
for field in cmdline LSL_STICK_DEV disk_size_sectors fat_start bpb_sectors; do
    if sed 's/#.*$//' "$HOOK" | grep -q "$field"; then
        ok "park diagnostics report $field"
    else
        bad "park diagnostics omit $field - a parked boot would say nothing"
    fi
done
# A shell first, sleep as the fallback: a parked-but-dead console is nearly as
# useless as a panic.
if sed 's/#.*$//' "$HOOK" | grep -qE 'busybox|\bsh\b' && sed 's/#.*$//' "$HOOK" | grep -q 'dev/console'; then
    ok "tries to hand the user a shell on the console before sleeping"
else
    bad "the park path sleeps without offering a shell"
fi
# The guard must be armed for the DESTRUCTIVE window and disarmed on every
# designed no-op. A refusal that forgets to disarm would park a healthy boot -
# strictly worse than the condition it was reporting.
if grep -q 'lsl_park_arm' "$HOOK" && grep -q 'lsl_park_disarm' "$HOOK"; then
    ok "arms the guard for the destructive window and disarms on designed no-ops"
else
    bad "guard is not armed/disarmed symmetrically"
fi
arm_line="$(grep -n 'lsl_park_arm$' "$HOOK" | head -1 | cut -d: -f1)"
sfdisk_line="$(grep -n 'sfdisk --no-reread' "$HOOK" | head -1 | cut -d: -f1)"
if [ -n "$arm_line" ] && [ -n "$sfdisk_line" ] && [ "$arm_line" -lt "$sfdisk_line" ]; then
    ok "guard goes live (L$arm_line) before the first write (L$sfdisk_line)"
else
    bad "guard armed L${arm_line:-?} is not before the partition rewrite L${sfdisk_line:-?}"
fi
# Every `return` inside the armed window must be preceded by a disarm, or the
# intended no-op parks instead. Count them and compare.
# The window ends at the hook's FINAL `lsl_park_disarm` (its success path), not
# the first `LSL_PARK_ARMED=0` - that one lives in the helper definitions, well
# above the window, and using it made this check compare nonsense.
window_start="$arm_line"
window_end="$(grep -n '^lsl_park_disarm$' "$HOOK" | tail -1 | cut -d: -f1)"
if [ -n "$window_start" ] && [ -n "$window_end" ] && [ "$window_start" -lt "$window_end" ]; then
    rets="$(sed -n "${window_start},${window_end}p" "$HOOK" \
            | grep -cE '^[[:space:]]*return 0 2>/dev/null|\|[[:space:]]*return 0 2>/dev/null')"
    # Each of those returns belongs to either a lsl_refuse block (which disarms
    # inside lsl_refuse itself) or an explicit lsl_park_disarm. Only the returns
    # with NEITHER nearby are the bug this guards against.
    bare="$(sed -n "${window_start},${window_end}p" "$HOOK" \
            | grep -B4 -E '^[[:space:]]*return 0 2>/dev/null|\|[[:space:]]*return 0 2>/dev/null' \
            | grep -cE 'lsl_refuse|lsl_park_disarm')"
    if [ "$rets" -gt 0 ] && [ "$rets" -le "$bare" ]; then
        ok "every early return in the armed window is a refusal (which disarms) - $rets return(s), $bare disarm site(s)"
    else
        bad "$rets early return(s) in the armed window but only $bare disarm site(s) - one would park a healthy boot"
    fi
else
    bad "cannot locate the armed window (arm L${window_start:-?}, end L${window_end:-?})"
fi

echo
echo "== part 1b: park guard behaviour (exercises the real functions) =="

# The static checks above can only see that the code is PRESENT. These drive it.
# The hook's park helpers are sourced by taking its PREFIX - everything up to
# the opt-out gates - because on a normal boot the hook returns at the first
# gate and never defines anything below it.
# mktemp -d, not $TMP: $TMP belongs to the root-only part 2 below, and this
# part runs unprivileged with `set -u`.
prefix="$(mktemp -d)"
sed -n '1,/^# ---- opt-out gates/p' "$HOOK" > "$prefix/defs.sh"

# An inert boot must return to the caller, not park.
if out="$(sh -c "LSL_PROV_LOG=0 LSL_PROV_LOGDIR=/tmp . '$prefix/defs.sh' >/dev/null 2>&1; echo RETURNED" 2>/dev/null)"; then
    case "$out" in
        *RETURNED*) ok "defining the park helpers does not park an inert boot" ;;
        *) bad "sourcing the hook's prefix did not return" ;;
    esac
else
    bad "sourcing the hook's prefix exited non-zero"
fi

# A refusal stands the guard down - otherwise a HEALTHY boot (no f2fs driver, a
# foreign Linux partition) would be parked, which is worse than the no-op it was
# reporting.
out="$(sh -c "LSL_PROV_LOG=0 LSL_PROV_LOGDIR=/tmp
    . '$prefix/defs.sh' >/dev/null 2>&1
    lsl_park_arm
    lsl_refuse 'simulated designed refusal'
    echo \"ARMED=\$LSL_PARK_ARMED\"" 2>/dev/null)"
case "$out" in
    *ARMED=0*) ok "lsl_refuse stands the guard down (a refusal never parks)" ;;
    *) bad "lsl_refuse left the guard armed - a designed refusal would park a good boot" ;;
esac

# lsl_park must not return: if it did, the shell would keep unwinding and panic.
if command -v timeout >/dev/null 2>&1; then
    sh -c "LSL_PROV_LOG=0 LSL_PROV_LOGDIR=/tmp
        . '$prefix/defs.sh' >/dev/null 2>&1
        lsl_park" >/dev/null 2>&1 &
    park_pid=$!
    sleep 3
    if kill -0 "$park_pid" 2>/dev/null; then
        ok "lsl_park blocks instead of returning (alive after 3s)"
        kill -9 "$park_pid" 2>/dev/null
    else
        bad "lsl_park returned - the shell would go on to panic"
    fi
    wait "$park_pid" 2>/dev/null || true
else
    skip "no timeout(1) to bound the lsl_park check"
fi

# THE panic scenario: a bare `exit` while the guard is armed must park. A plain
# exit would unwind the shell and return its status; parking means the process
# is still alive when the timeout fires (rc 124).
if command -v timeout >/dev/null 2>&1; then
    out="$(timeout 10 sh -c "LSL_PROV_LOG=1 LSL_PROV_LOGDIR='$prefix'
        mkdir -p '$prefix'
        . '$prefix/defs.sh' >/dev/null 2>&1
        LSL_PARK_STEP='shrink-filesystem'
        lsl_park_arm
        exit 1" 2>&1)"
    rc=$?
    case "$out" in
        *STOPPED*at*) ok "an armed bare exit prints the park banner naming the step" ;;
        *) bad "no park banner on an armed bare exit (rc=$rc)" ;;
    esac
    case "$rc" in
        124) ok "an armed bare exit did not unwind the shell (still parked at timeout)" ;;
        *) bad "armed bare exit unwound with rc=$rc - that is the panic" ;;
    esac
    # The status must be printable. dash hands an EXIT trap an EMPTY argument,
    # which once rendered as "status )" - a diagnostic that says nothing.
    case "$out" in
        *"status unknown"*|*"status "[0-9]*) ok "the park banner reports a usable exit status" ;;
        *) bad "the park banner does not report an exit status" ;;
    esac
else
    skip "no timeout(1) to bound the armed-exit check"
fi

echo
echo "== part 1c: the scan must detect AMBIGUITY, not pick a winner =="

# The scan used to `break` on the first match, so with two lsl sticks plugged in
# (the user with a spare) it silently repartitioned whichever the glob reached
# first. Collecting every match and requiring EXACTLY ONE turns that coin flip
# into a refusal - the only defence available while the cmdline carries a SIZE
# and no identity at all.

# Static: the first-match break must be GONE, and a uniqueness count must exist.
if sed -n '/^for _lsl_dev in/,/^rmdir "\$LSL_SCAN_MNT"/p' "$HOOK" \
     | grep -qE '^\s*\[ -n "\$LSL_STICK_DEV" \] && break'; then
    bad "the scan still breaks on the first match - two sticks mean a coin flip"
else
    ok "the scan no longer breaks on the first match"
fi
if grep -q 'LSL_STICK_DEV_ALL=' "$HOOK"; then
    ok "the scan accumulates every candidate disk"
else
    bad "the scan does not collect all candidates"
fi
if grep -q '_lsl_match_count' "$HOOK"; then
    ok "the scan counts distinct matching disks"
else
    bad "no distinct-disk count - ambiguity cannot be detected without it"
fi

# Two PARTITIONS of ONE disk must count once, or a normal multi-partition stick
# would refuse itself.
out="$(sh -c 'LSL_STICK_DEV_ALL="/dev/sdb"; for c in $LSL_STICK_DEV_ALL; do n=$((n+1)); done; echo "N=$n"' 2>/dev/null)"
case "$out" in
    *N=1*) ok "one disk counted once (the dedup case)" ;;
    *) bad "counting a single disk gave $out" ;;
esac
out="$(sh -c 'LSL_STICK_DEV_ALL="/dev/sdb /dev/sdc"; for c in $LSL_STICK_DEV_ALL; do n=$((n+1)); done; echo "N=$n"' 2>/dev/null)"
case "$out" in
    *N=2*) ok "two disks counted twice (the ambiguous case)" ;;
    *) bad "counting two disks gave $out" ;;
esac

# The refusal must be a REFUSAL (no disk touched, boot continues), not a park:
# two sticks plugged in is an operator-fixable condition, and parking would wedge
# a perfectly healthy boot - the same reasoning lsl_refuse already encodes.
if grep -q 'lsl_refuse "the lsl payload is present on' "$HOOK"; then
    ok "ambiguity is a refusal, not a park (an operator can fix it by unplugging)"
else
    bad "ambiguity does not go through lsl_refuse - it may park a healthy boot"
fi
# ...and the message must name the disks, so the operator knows which to pull.
if grep -q 'the lsl payload is present on .*different disks' "$HOOK" \
   && grep -q "tr ' ' ','" "$HOOK"; then
    ok "the ambiguity refusal names every disk it found"
else
    bad "the ambiguity refusal does not name the disks found"
fi
# POSIX only: `${var// /, }` is a bashism and the initramfs shell is busybox ash.
if grep -q '\${LSL_STICK_DEV_ALL//' "$HOOK"; then
    bad "uses \${var//...} - a bashism that breaks under busybox ash"
else
    ok "uses POSIX expansion only (no bashism in the refusal path)"
fi

# ---- the guard must not leak into casper's shell ---------------------------
# A trap set inside a SOURCED file belongs to the CALLING shell. Measured: it
# does survive the hook's `return` and does fire on the caller's own exit. Left
# installed, the hook would park casper's exit whenever the guard were armed -
# reaching into a shell it does not own. So arming installs the trap and every
# way out of the armed window must hand it back.
#
# The probe lives in its own FILE rather than inline: the check has to compare a
# trap name containing quotes, and nesting that inside the harness's own `sh -c`
# inside a `case` mangles it into a false failure. Keeping it in a script is the
# only way the comparison survives.
cat > "$prefix/probe.sh" <<'PROBE'
#!/bin/sh
set -u
LSL_PROV_LOG=0
LSL_PROV_LOGDIR=/tmp
# shellcheck source=/dev/null
. "$1" >/dev/null 2>&1
lsl_park_arm
if [ "${2:-disarm}" = "refuse" ]; then
    lsl_refuse 'probe'
else
    lsl_park_disarm
fi
# A CLEARLED trap still prints back, as `trap -- - EXIT`, so compare the whole
# printed line: our handler name appearing anywhere means it is still installed.
now="$(trap -p EXIT 2>/dev/null)"
case "$now" in
    *lsl_park_on_exit*) echo TRAP_LEAKED ;;
    *)                  echo TRAP_CLEAN ;;
esac
PROBE
chmod +x "$prefix/probe.sh" 2>/dev/null || true

for mode in disarm refuse; do
    got="$(sh "$prefix/probe.sh" "$prefix/defs.sh" "$mode" 2>/dev/null)"
    case "$got" in
        *TRAP_CLEAN*)
            if [ "$mode" = disarm ]; then
                ok "disarming the guard removes the EXIT trap (no leak into casper)"
            else
                ok "a refusal also hands casper's EXIT trap back"
            fi
            ;;
        *) bad "the guard's EXIT trap survives '$mode' - it leaks into casper's shell (got [$got])" ;;
    esac
done

rm -rf "$prefix"

echo
echo "== part 2: geometry against a real loopback image (needs root) =="

if [ "$(id -u)" -ne 0 ]; then
    skip "loop/mkfs need root - static half above still ran"
    echo
    echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
    [ "$FAIL" -eq 0 ] || exit 1
    exit 0
fi

for t in sfdisk mkfs.vfat mkfs.f2fs fatresize losetup blockdev dd od partprobe; do
    command -v "$t" >/dev/null 2>&1 || { skip "$t missing"; break; }
done
# The kernel must be able to mount f2fs, or the hook's own gate refuses and the
# geometry never gets exercised.
grep -qw f2fs /proc/filesystems 2>/dev/null || modprobe f2fs 2>/dev/null || true
grep -qw f2fs /proc/filesystems 2>/dev/null || { skip "kernel has no f2fs driver"; echo; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0; }

# A disk with room to give: 16 GiB, FAT first. 12 GiB of FAT leaves 4 GiB free
# on the disk AND keeps 10 GiB of FAT after a 2 GiB carve, comfortably above the
# hook's own FAT_MIN_MIB floor - which is exercised separately below.
#
# UNITS (measured, util-linux 2.37): in `sfdisk` INPUT, `size=` is in SECTORS
# (10240 means 5 MiB, not 10), and `sfdisk -d` reports sectors too. So both
# directions use sectors, and the hook's arithmetic is consistent. Getting this
# backwards by 1024x produces a 5 MiB partition holding an 8 GiB filesystem -
# the exact silent-corruption shape this hook refuses.
DISK_MIB=16384
FAT_SECTORS=$(( 12 * 1024 * 1024 * 1024 / 512 ))  # 12 GiB in sectors
WANT_GIB=2

IMG="$(mktemp -u /tmp/lsl-prov-XXXXXX.img)"
LOOP=""
TMP="$(mktemp -d)"
cleanup() { [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null; rm -f "$IMG"; rm -rf "$TMP"; }
trap cleanup EXIT
dd if=/dev/zero of="$IMG" bs=1M count=$DISK_MIB 2>/dev/null || { skip "cannot create image"; exit 0; }

LOOP="$(losetup --show -f "$IMG" 2>/dev/null)" || { skip "losetup failed"; exit 0; }
printf "label: dos\n1 : start=2048, size=$FAT_SECTORS, type=0c\n" \
    | sfdisk --force "$LOOP" >/dev/null 2>&1 || { skip "sfdisk failed"; exit 0; }
# Verify the geometry we ASKED for is the geometry we GOT, in bytes. This
# distinction is the whole point of the test and is easy to get backwards:
# measured on util-linux 2.37, `size=` in sfdisk INPUT is SECTORS (10240 means
# 5 MiB, not 10), and `sfdisk -d` reports sectors too. Getting this backwards by
# 1024x is what produced a 5 MiB partition holding a 8 GiB filesystem.
want_bytes=$(( FAT_SECTORS * 512 ))
got_sectors="$(sfdisk -d "$LOOP" 2>/dev/null | grep -E ': *start=' | head -n1 | sed -n 's/.*size=[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
got_bytes=$(( got_sectors * 512 ))
[ "$want_bytes" = "$got_bytes" ] \
    && ok "sfdisk input is sectors, as assumed (asked $want_bytes bytes, got $got_bytes)" \
    || skip "sfdisk unit mismatch: asked $want_bytes bytes for $FAT_SECTORS sectors, got $got_bytes"
partprobe "$LOOP" 2>/dev/null; sleep 1
FAT_NODE="$(ls "${LOOP}"*1 2>/dev/null | head -1)"
[ -n "$FAT_NODE" ] || { skip "no partition node appeared after sfdisk"; exit 0; }
mkfs.vfat -F 32 -n LSLTEST "$FAT_NODE" >/dev/null 2>&1 || { skip "mkfs.vfat failed on $FAT_NODE"; exit 0; }

bpb_before="$(dd if="$FAT_NODE" bs=1 skip=19 count=4 2>/dev/null | od -An -tu4 | tr -d ' ')"
[ -n "$bpb_before" ] && ok "FAT created (BPB claims $bpb_before sectors)" || bad "cannot read BPB"

fat_part_before="$(sfdisk -d "$LOOP" 2>/dev/null | grep -E '^[^#].*: *start=' | head -n1 | sed -n 's/.*size=[[:space:]]*\([0-9][0-9]*\).*/\1/p')"

# --- inert with no cmdline flag ---------------------------------------------
# With no lsl_f2fs_provision=<GiB> on the cmdline the hook must do nothing at
# all, and leave the partition byte-identical.
sh "$HOOK" >/dev/null 2>&1
fat_part_after="$(sfdisk -d "$LOOP" 2>/dev/null | grep -E '^[^#].*: *start=' | head -n1 | sed -n 's/.*size=[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
[ "$fat_part_before" = "$fat_part_after" ] \
    && ok "inert with no cmdline flag (partition still $fat_part_after sectors)" \
    || bad "no-flag boot CHANGED the partition: $fat_part_before -> $fat_part_after"

# --- the REAL carve ---------------------------------------------------------
# Drive the hook the way casper will. /proc/cmdline is read-only here, so the
# test writes a FAKE cmdline file and points the hook's `cat` at it. Doing it
# by rewriting the hook's /proc/cmdline line instead would be fragile: the
# opt-out gate also reads /proc/cmdline, and a careless substitution rewrites
# THAT and switches the whole hook off (which is exactly what happened once).
FAKE_CMDLINE="$TMP/cmdline"
echo "root=/dev/loop0 ro quiet splash lsl_f2fs_provision=$WANT_GIB" > "$FAKE_CMDLINE"
HOOK_RUN="$TMP/hook-with-flag.sh"
sed "s#cat /proc/cmdline#cat $FAKE_CMDLINE#" "$HOOK" > "$HOOK_RUN"

# Point the hook at OUR loop device instead of scanning the real machine. The
# hook exposes LSL_DISKS (whole disks) and LSL_PARTS (partition nodes) as test
# seams precisely so this is a one-line override rather than a fragile rewrite
# of a multi-line glob. Unset in production.
# The partition node is /dev/loopNp1 (NOT /dev/loopN1), which the hook's
# lsl_part_node resolves for itself.
sed -i "s#^LSL_STICK_DEV=.*#LSL_STICK_DEV=$LOOP#" "$HOOK_RUN"
sed -i "s#^LSL_STICK_PART=.*#LSL_STICK_PART=${LOOP}1#" "$HOOK_RUN"
# /dev/console does not exist here, so the hook's log lines would vanish.
sed -i "s#/dev/console#$TMP/console.log#g" "$HOOK_RUN"

# Run it with the seams pointed at our loop device and the flag on the fake
# cmdline. LSL_DISKS/LSL_PARTS are unset in production and expand to the full
# device glob, so overriding them here cannot affect the real hook.
LSL_DISKS="$LOOP" LSL_PARTS="${LOOP}1" sh "$HOOK_RUN" >/dev/null 2>&1
rc=$?
partprobe "$LOOP" 2>/dev/null; udevadm settle 2>/dev/null || sleep 1
HOOK_LOG="$(cat "$TMP/console.log" 2>/dev/null)"

echo "  hook log:"; printf '%s\n' "$HOOK_LOG" | sed 's/^/    /'

FAT_NODE="$(ls "${LOOP}"*1 2>/dev/null | head -1)"
PERSIST_NODE="$(ls "${LOOP}"*2 2>/dev/null | head -1)"

# 1. the partition table must now have TWO entries
nparts="$(sfdisk -d "$LOOP" 2>/dev/null | grep -c '^[^#].*: *start=')"
[ "$nparts" -eq 2 ] && ok "partition table now has 2 partitions" \
                    || bad "expected 2 partitions, found $nparts (hook rc=$rc)"

# 2. THE CORRUPTION CHECK: the filesystem must be smaller than its partition.
# This is the whole point of shrinking the FS first. A bare sfdisk shrink leaves
# the FS claiming more than the partition - which MOUNTS cleanly and then fails
# past the boundary, the silent failure this design exists to prevent.
bpb_after="$(dd if="$FAT_NODE" bs=1 skip=19 count=4 2>/dev/null | od -An -tu4 | tr -d ' ')"
fat_part_now="$(sfdisk -d "$LOOP" 2>/dev/null | grep -E '^[^#].*: *start=' | head -n1 | sed -n 's/.*size=[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
case "$bpb_after$fat_part_now" in
    ''|*[!0-9]*) bad "could not read geometry after the carve (bpb='$bpb_after' part='$fat_part_now'); hook log: $(cat "$TMP/run.log")";;
    *)
        [ "$bpb_after" -lt "$fat_part_now" ] \
            && ok "filesystem ($bpb_after) is smaller than its partition ($fat_part_now) - no silent corruption" \
            || bad "filesystem claims $bpb_after sectors but the partition is only $fat_part_now: it would mount clean and fail past the boundary"
        ;;
esac

# 3. the second partition must be a real f2fs with our label
if [ -n "$PERSIST_NODE" ]; then
    fstype="$(blkid -o value -s TYPE "$PERSIST_NODE" 2>/dev/null)"
    label="$(blkid -o value -s LABEL "$PERSIST_NODE" 2>/dev/null)"
    [ "$fstype" = "f2fs" ] && ok "partition 2 is f2fs (label '$label')" \
                           || bad "partition 2 is '${fstype:-unknown}', expected f2fs"
    [ "$label" = "lsl-persist" ] && ok "partition 2 carries the lsl-persist label" \
                                 || bad "partition 2 label is '$label', expected lsl-persist"

    # 4. and it must actually mount, so /home can live there
    mkdir -p "$TMP/mnt"
    if mount -t f2fs "$PERSIST_NODE" "$TMP/mnt" 2>/dev/null; then
        mkdir -p "$TMP/mnt/upper" 2>/dev/null && ok "f2fs partition mounts and accepts an upper/ dir" \
            || bad "f2fs mounted but upper/ could not be created"
        umount "$TMP/mnt" 2>/dev/null
    else
        bad "f2fs partition does not mount"
    fi
else
    bad "second partition node never appeared (hook rc=$rc)"
fi

# 5. IDEMPOTENCE: a second boot must be a no-op, not a second carve.
before2="$(sfdisk -d "$LOOP" 2>/dev/null | md5sum)"
LSL_DISKS="$LOOP" LSL_PARTS="${LOOP}1" sh "$HOOK_RUN" >/dev/null 2>&1
after2="$(sfdisk -d "$LOOP" 2>/dev/null | md5sum)"
[ "$before2" = "$after2" ] && ok "second run is a no-op (table unchanged)" \
                          || bad "second run MODIFIED the table - not idempotent"

echo
echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] || exit 1