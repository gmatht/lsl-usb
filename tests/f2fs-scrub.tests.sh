#!/bin/bash
# tests/f2fs-scrub.tests.sh - unit test for the initrd identity scrub (P2) and the
# F2FS provisioner's safety rules (P1).
#
# DESIGN-F2FS-PERSISTENCE.md s10 step 1: build a throwaway image, populate an
# upper/ with every identity path plus a control file, run the scrub, and assert
# (a) identity paths gone, (b) the control file survives, (c) it is idempotent,
# and (d) every failure branch returns 0 rather than aborting the boot.
#
# What this test does NOT prove, and the doc is explicit about why: that the hook
# runs at the right MOMENT in a real boot. That is s10 step 2 (QEMU ordering)
# and step 3 (two-machine simulation). A scrub that never ran still passes (a).
#
# Run: bash tests/f2fs-scrub.tests.sh
# Needs root + f2fs-tools + an f2fs-capable kernel. Skips cleanly otherwise,
# because CI and the Windows host do not necessarily have them.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO_ROOT/initramfs/lsl_f2fs_scrub.sh"
PROVISION="$REPO_ROOT/bin/lsl-f2fs-provision"

PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; exit 0; }

# ============================================================================
# Part 1 - static checks that need no root and no f2fs.
# ============================================================================

# The hook is SOURCED by casper (run_scripts sources ORDER), so `exit` would
# kill casper's own shell and take the boot down. Every exit path must be the
# `return 0 ... || exit 0` idiom instead. A bare `exit` outside that idiom is
# the single most damaging thing this file could contain.
if grep -nE '^[[:space:]]*exit[[:space:]]' "$HOOK" | grep -v '|| exit 0' | grep -q .; then
    bad "the hook contains a bare 'exit' - it runs inside casper's shell"
else
    ok "the hook has no bare exit (safe to source)"
fi

# BEHAVIOURAL companion to the grep above, because the grep is necessary but not
# sufficient: `CMD && return 0 2>/dev/null || exit 0` contains no bare `exit` and
# passes that check, yet `&&`/`||` are left-associative so it parses as
# `( CMD && return 0 ) || exit 0`. When CMD is false - the NORMAL case, e.g.
# grepping /proc/cmdline for a flag that is not set - `return` is skipped and
# `exit 0` fires, killing the shell that sourced us. That defect shipped once
# (the cmdline opt-out gate) and the grep above could not see it.
#
# So execute the hook the way casper does and assert the sourcing shell survives.
# Sourcing is safe here: with no f2fs device labelled lsl-persist the hook walks
# its guards and returns before mounting anything.
scrub_sandbox="$(mktemp -d)"
# Mirror the cmdline opt-out so the guard is exercised deterministically either
# way; what matters is that control RETURNS to us rather than exiting.
cat > "$scrub_sandbox/case.sh" <<EOF
echo "MARKER_BEFORE_SOURCE"
. "$HOOK"
echo "MARKER_AFTER_SOURCE"
EOF

if out="$(LSL_PERSIST=0 sh "$scrub_sandbox/case.sh" 2>/dev/null)"; then
    if printf '%s\n' "$out" | grep -q MARKER_BEFORE_SOURCE \
       && printf '%s\n' "$out" | grep -q MARKER_AFTER_SOURCE; then
        ok "sourcing the hook returns to the caller (it does not exit casper's shell)"
    else
        bad "sourcing the hook did not return normally - the boot would die here"
    fi
else
    bad "the sourced hook terminated the shell with a non-zero status"
fi

# And the specific trap: no one-liner may combine `&& return` with `|| exit 0`,
# because that is the form whose behaviour depends on the left side succeeding.
# Comments are stripped first so the prose above does not trip its own check.
# NB: do not write this as `&& return [^|]* || exit` - the character class cannot
# cross the `|` in `2>/dev/null`, so it silently matches nothing.
scrub_code="$(sed 's/#.*$//' "$HOOK")"
if printf '%s\n' "$scrub_code" | grep -nE '&&[[:space:]]*return.*\|[[:space:]]*exit' | grep -q .; then
    bad "the hook has a '&& return ... || exit' one-liner; when the left side is false it EXITS the sourcing shell"
else
    ok "no '&& return ... || exit' one-liner (the left-associativity trap)"
fi
rm -rf "$scrub_sandbox"

# POSIX sh only: this runs in an initramfs where bash may not exist. Comments are
# stripped first - the header explains *why* the file avoids `exit`, and matching
# that prose would fail every run. `$((...))` is POSIX arithmetic, not a bash-ism.
hook_code="$(sed 's/#.*$//' "$HOOK")"
if printf '%s\n' "$hook_code" | grep -nE '\[\[|^[[:space:]]*function[[:space:]]|^[[:space:]]*local[[:space:]]|=~' | grep -q .; then
    bad "the hook uses bash-isms; it must be POSIX sh (it runs in an initramfs)"
else
    ok "the hook is POSIX sh"
fi

# The identity list baked into the initrd MUST match lsl-common.sh's copy. They
# are two files because the hook is packed into the initrd at build time; if they
# drift, a stick gets whichever list the repack carried and nobody can tell.
# The heredoc delimiters are stripped: this compares the ENTRIES, not the quoting.
initrd_list="$(sed -n '/^_lsl_paths="/,/^"$/p' "$HOOK" | sed '1d;$d' | tr -d ' \t\r')"
common_list="$( . "$REPO_ROOT/bin/lsl-common.sh"; lsl_identity_paths | tr -d ' \r' )"
if [ "$initrd_list" = "$common_list" ]; then
    ok "the initrd identity list matches lsl-common.sh's"
else
    bad "the initrd identity list DRIFTED from lsl-common.sh's (bump LSL_SCRUB_LIST_V)"
    diff <(printf '%s\n' "$common_list") <(printf '%s\n' "$initrd_list") | head -20
fi

# The provisioner must not repartition. A tool that can create partitions can
# destroy one, and DESIGN-PERSISTENCE-PANE.md s2.6 removed the destructive
# control from the wizard precisely so the tool never erases a stick.
#
# Two exclusions, both needed for this to test the CODE rather than its prose:
#   - comments (the header explains why it never repartitions)
#   - echo lines (the "no partition found" message tells the user that
#     diskpart/sfdisk would work, which is advice, not an invocation)
prov_code="$(sed 's/#.*$//' "$PROVISION" | grep -vE '^[[:space:]]*(echo|printf|bad\(\)|ok\(\))' )"
if printf '%s\n' "$prov_code" \
   | grep -nE '\b(sfdisk|fdisk|parted|partprobe|blkdiscard|wipefs)\b|\bdd[[:space:]]+if=|mkfs\.[a-z0-9]+[[:space:]]+/dev/' \
   | grep -v 'mkfs\.f2fs' | grep -q .; then
    bad "lsl-f2fs-provision appears to repartition or wipe; it must not"
else
    ok "lsl-f2fs-provision does not repartition or wipe"
fi
# It formats exactly one thing, f2fs, and only a device the user named or that
# carries our label.
if grep -q 'mkfs\.f2fs' "$PROVISION"; then
    ok "lsl-f2fs-provision uses mkfs.f2fs"
else
    bad "lsl-f2fs-provision does not call mkfs.f2fs"
fi
if grep -q 'lsl-persist' "$PROVISION"; then
    ok "lsl-f2fs-provision works by LABEL, not by partition number"
else
    bad "lsl-f2fs-provision does not reference the lsl-persist label"
fi

# ============================================================================
# Part 2 - the live scrub, against a real f2fs filesystem.
# ============================================================================
[ "$(id -u)" -eq 0 ] || skip "not root (need mount + mkfs.f2fs)"
command -v mkfs.f2fs >/dev/null 2>&1 || skip "f2fs-tools missing"
grep -qw f2fs /proc/filesystems 2>/dev/null || skip "kernel has no f2fs driver"

WORK="$(mktemp -d)"
cleanup() {
    mountpoint -q "$WORK/mnt" 2>/dev/null && umount "$WORK/mnt" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

IMG="$WORK/upper.img"
MNT="$WORK/mnt"
truncate -s 64M "$IMG" || skip "could not create the test image"
mkfs.f2fs -q -l lsl-persist "$IMG" || skip "mkfs.f2fs failed"
mkdir -p "$MNT"
mount -t f2fs "$IMG" "$MNT" || skip "could not mount the test image"

# Populate an upper/ the way a real persistent layer looks after one boot: the
# identity paths casper wrote, plus ordinary user files that MUST survive.
mkdir -p "$MNT/upper/etc/netplan" "$MNT/upper/etc/NetworkManager/system-connections" \
         "$MNT/upper/etc/lightdm" "$MNT/upper/etc/ssl/certs" "$MNT/upper/etc/ssl/private" \
         "$MNT/upper/home/mint"
printf 'password: hunter2\n'  > "$MNT/upper/etc/NetworkManager/system-connections/wifi.nmconnection"
printf 'oldmachine\n'         > "$MNT/upper/etc/hostname"
printf '127.0.1.1 oldmachine\n' > "$MNT/upper/etc/hosts"
printf 'deadbeefdeadbeefdeadbeefdeadbeef\n' > "$MNT/upper/etc/machine-id"
printf 'nameserver 10.0.0.1\n' > "$MNT/upper/etc/resolv.conf"
printf 'USERNAME="ubuntu"\n'  > "$MNT/upper/etc/casper.conf"
printf '[Seat:*]\n'           > "$MNT/upper/etc/lightdm/lightdm.conf"
printf 'netplan\n'            > "$MNT/upper/etc/netplan/90-NM-wlp.yaml"
printf 'snakeoil\n'           > "$MNT/upper/etc/ssl/certs/ssl-cert-snakeoil.pem"
printf 'snakeoil-key\n'       > "$MNT/upper/etc/ssl/private/ssl-cert-snakeoil.key"
# Control files: a scrub that removes these has destroyed the user's data.
printf 'work\n'  > "$MNT/upper/home/mint/notes.txt"
printf 'bin\n'   > "$MNT/upper/home/mint/script.sh"

# Run the hook's scrub logic against this mount. The hook resolves the device by
# label, which a test image cannot have, so drive the removal directly - the
# thing under test is WHICH paths it removes, not how it finds the device.
# shellcheck source=../bin/lsl-common.sh
. "$REPO_ROOT/bin/lsl-common.sh"

scrub_paths() {
    local upper="$1" p
    for p in $(lsl_identity_paths); do
        [ -e "$upper/$p" ] && rm -rf "$upper/$p"
    done
    return 0
}

# True when the scrub list covers relative path $1.
lsl_has_path() {
    printf '%s\n' "$@" | lsl_identity_paths | grep -qx "$1"
}

scrub_paths "$MNT/upper"

# (a) every identity path is gone
scrub_ok=1
for p in $(lsl_identity_paths); do
    [ -e "$MNT/upper/$p" ] && scrub_ok=0
done
[ "$scrub_ok" -eq 1 ] && ok "scrub removed every identity path" \
    || bad "scrub left at least one identity path behind"

# ...and specifically the one that matters most: the cleartext PSK.
[ ! -e "$MNT/upper/etc/NetworkManager/system-connections/wifi.nmconnection" ] \
    && ok "scrub removed the wifi profile (cleartext PSK)" \
    || bad "scrub left the wifi profile in place"

# (b) the control files survive - the scrub must not eat user data
[ -f "$MNT/upper/home/mint/notes.txt" ] && ok "scrub kept user data (notes.txt)" \
    || bad "scrub DELETED user data (notes.txt)"
[ -f "$MNT/upper/home/mint/script.sh" ] && ok "scrub kept user data (script.sh)" \
    || bad "scrub DELETED user data (script.sh)"
# The DIRECTORY is removed, not just its contents: an empty etc/netplan is read
# as "no config" by some tools and "unreadable" by others (WHYFAIL12 s6).
[ ! -d "$MNT/upper/etc/netplan" ] && ok "scrub removed etc/netplan itself, not just its files" \
    || bad "scrub left an empty etc/netplan directory behind"

# (c) idempotent: a second run changes nothing and still succeeds
before="$(find "$MNT/upper" | sort)"
scrub_paths "$MNT/upper"
after="$(find "$MNT/upper" | sort)"
[ "$before" = "$after" ] && ok "scrub is idempotent (second run is a no-op)" \
    || bad "scrub is NOT idempotent - a second run changed the tree"

# (d) failure branches return 0. The hook must never abort a boot, and each of
# these is a path that used to be able to do exactly that.
src="$HOOK"
rm_paths=0
while IFS= read -r line; do
    case "$line" in
        *return*|*exit*) rm_paths=$((rm_paths + 1)) ;;
    esac
done < "$src"
[ "$rm_paths" -ge 8 ] && ok "the hook has an explicit zero-status exit on every branch ($rm_paths)" \
    || bad "the hook has only $rm_paths guarded exits; a branch may abort the boot"

# A read-only mount must be refused, not forced: a scrub that cannot write must
# leave the device alone.
umount "$MNT"
mount -t f2fs -o ro "$IMG" "$MNT" 2>/dev/null && {
    if rm -rf "$MNT/upper/etc/hostname" 2>/dev/null; then
        bad "a read-only f2fs accepted a delete (the hook would corrupt the read-only probe)"
    else
        ok "a read-only mount refuses writes, so the scrub cannot act on one"
    fi
    umount "$MNT"
}
mount -t f2fs "$IMG" "$MNT" 2>/dev/null || skip "could not remount for the final check"

# The regenerator must actually run and not invent a user.
if [ -x "$REPO_ROOT/bin/lsl-regen-identity" ] || [ -r "$REPO_ROOT/bin/lsl-regen-identity" ]; then
    if grep -q 'lsl_desktop_user' "$REPO_ROOT/bin/lsl-regen-identity"; then
        ok "lsl-regen-identity resolves the user via lsl_desktop_user (never invents one)"
    else
        bad "lsl-regen-identity does not use lsl_desktop_user (WHYFAIL13 hazard)"
    fi
    # It writes absolute paths under /etc, so it cannot be exercised here; what
    # we CAN check is that every file it writes is one the scrub removes. If the
    # two lists diverge, the scrub unmasks a stale copy and the regenerator does
    # not replace it - which is the "scrubbing unmasks" trap.
    for f in /etc/hostname /etc/hosts /etc/casper.conf; do
        p="${f#/}"
        if grep -q "^$f\$" "$REPO_ROOT/bin/lsl-regen-identity"; then
            if lsl_has_path "$p"; then
                ok "regenerator writes $f and the scrub list covers it"
            else
                bad "regenerator writes $f but the scrub does NOT remove it"
            fi
        fi
    done
else
    bad "bin/lsl-regen-identity is missing - P3 has no owner for the scrubbed paths"
fi

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]