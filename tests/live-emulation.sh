#!/bin/bash
# tests/live-emulation.sh - emulate a bootable USB in a container and run
# uproot --auto-append end-to-end with a mock apt.
#
# What this exercises (the highest-risk code before a real boot):
#   - casper-style layer stacking (filesystem.squashfs + firstboot layer)
#   - uproot's overlay mount + chroot + squashfs_config.sh run
#   - the mock apt records invocations (verifies -y flags, package list)
#   - the appended layer: naming (filesystem_z* = highest precedence),
#     companion .sh, upper-only contents
#   - the fail-loud path: apt failure -> uproot aborts (no silent "done")
#
# Requires: root + mount privileges (squashfs/overlay/loop), mksquashfs, zstd.
# Run: sudo bash tests/live-emulation.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

[ "$EUID" -eq 0 ] || { echo "ERROR: run as root" >&2; exit 1; }
command -v mksquashfs >/dev/null || { echo "ERROR: mksquashfs required" >&2; exit 1; }
command -v unsquashfs >/dev/null || { echo "ERROR: unsquashfs required" >&2; exit 1; }
mountpoint -q /cdrom && { echo "ERROR: /cdrom is already a mountpoint" >&2; exit 1; }

WORK="$(mktemp -d)"
FAKE_USB="$WORK/usb"
BASE="$WORK/base-root"
ROFS=/rofs   # uproot's literal fallback lowerdir path

cleanup() {
    for m in /tmp/squashfs/root/var/cache/apt/archives /tmp/squashfs/root/home \
             /tmp/squashfs/root/proc /tmp/squashfs/root/dev /tmp/squashfs/root/sys \
             /tmp/squashfs/root/cdrom /tmp/squashfs/root; do
        umount "$m" 2>/dev/null || true
    done
    umount /cdrom 2>/dev/null || true
    umount "$ROFS" 2>/dev/null || true
    rm -rf "$WORK" /tmp/squashfs
}
trap cleanup EXIT

# --- 1) fake USB layout -----------------------------------------------------
mkdir -p "$FAKE_USB/casper" "$FAKE_USB/bin" "$FAKE_USB/systemd"
cp -a "$REPO_ROOT/bin" "$FAKE_USB/bin"
cp -a "$REPO_ROOT/systemd" "$FAKE_USB/systemd"
cp "$REPO_ROOT/onboot.sh" "$REPO_ROOT/lsl-usb.env" "$FAKE_USB/"
[ -f "$REPO_ROOT/dist/filesystem_z0_firstboot.squashfs" ] && \
    cp "$REPO_ROOT/dist/filesystem_z0_firstboot.squashfs" "$FAKE_USB/casper/"

# --- 2) minimal base rootfs (usrmerge layout) with mocks --------------------
mkdir -p "$BASE"/{bin,etc,etc/systemd/system,etc/xdg/autostart,etc/apt/preferences.d,etc/apt/sources.list.d,usr/local/sbin,usr/local/bin,tmp,proc,sys,dev,run,home,mnt,cdrom,var/cache/apt/archives,var/log,var/lib,usr/share/keyrings}
ln -s ../bin "$BASE/usr/bin"
ln -s ../bin "$BASE/usr/sbin"
ln -s ../bin "$BASE/sbin"

cpbin() {
    # Search standard paths only: /root/bin may shadow tools with wrappers
    # (e.g. safe-rm) that break inside the chroot.
    for b in "$@"; do
        for p in /usr/bin/"$b" /bin/"$b" /usr/sbin/"$b" /sbin/"$b"; do
            if [ -f "$p" ]; then
                cp -L "$p" "$BASE/bin/$(basename "$p")" 2>/dev/null || true
                break
            fi
        done
    done
}
cpbin bash sh ls cat sleep mkdir touch grep sed awk cut date echo true false dirname basename readlink id getent mount umount findmnt df stat du nice ionice chmod chown ln rm cp mv sync tee md5sum head tail wc sort tr env
for f in "$BASE"/bin/*; do
    ldd "$f" 2>/dev/null | awk '/=>/ {print $3}' | while read -r l; do
        mkdir -p "$BASE$(dirname "$l")"; cp -L "$l" "$BASE$l" 2>/dev/null || true
    done
done
ldd /bin/bash 2>/dev/null | awk '/\/lib64\/ld/ {print $1}' | while read -r l; do
    mkdir -p "$BASE$(dirname "$l")"; cp -L "$l" "$BASE$l" 2>/dev/null || true
done

# mock apt: record invocations; fail if /cdrom/mock-apt-fail exists
cat > "$BASE/usr/bin/apt" <<'EOF'
#!/bin/bash
echo "apt $*" >> /var/log/mock-apt.log
if [ -f /cdrom/mock-apt-fail ]; then
    echo "mock apt: failing as requested" >> /var/log/mock-apt.log
    exit 1
fi
mkdir -p /var/lib/mock-apt-installed
touch "/var/lib/mock-apt-installed/$(echo "$*" | md5sum | cut -c1-8)"
exit 0
EOF
# mock curl: -o creates a file; pipes emit a no-op script
cat > "$BASE/usr/bin/curl" <<'EOF'
#!/bin/bash
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
if [ -n "$out" ]; then
    mkdir -p "$(dirname "$out")"
    printf '#!/bin/sh\necho mock\n' > "$out"
    exit 0
fi
printf '#!/bin/sh\ntrue\n'
exit 0
EOF
# mock gpg: create the -o output
cat > "$BASE/usr/bin/gpg" <<'EOF'
#!/bin/bash
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
if [ -n "$out" ]; then mkdir -p "$(dirname "$out")"; echo mock > "$out"; fi
exit 0
EOF
chmod +x "$BASE/usr/bin/apt" "$BASE/usr/bin/curl" "$BASE/usr/bin/gpg"

# --- 3) squash the base as filesystem.squashfs ------------------------------
mksquashfs "$BASE" "$FAKE_USB/casper/filesystem.squashfs" -noappend -comp zstd >/dev/null

# --- 4) mount: /rofs = base layer, /cdrom = fake USB ------------------------
mkdir -p "$ROFS" /cdrom
mount -t squashfs -o loop,ro "$FAKE_USB/casper/filesystem.squashfs" "$ROFS"
mount --bind "$FAKE_USB" /cdrom
mountpoint -q "$ROFS" || { echo "ERROR: /rofs not mounted" >&2; exit 1; }

# --- 5) run uproot --auto-append (success case) -----------------------------
echo "== uproot --auto-append (success) =="
if bash "$REPO_ROOT/bin/uproot" --auto-append; then
    pass "uproot --auto-append exited 0"
else
    fail "uproot --auto-append exited non-zero"
fi

# --- 6) assertions on the output layer --------------------------------------
# the appended layer is filesystem_z<timestamp>.squashfs (NOT the
# filesystem_z0_firstboot layer, which also matches filesystem_z*)
layer="$(ls "$FAKE_USB"/casper/filesystem_z[0-9][0-9][0-9][0-9]*.squashfs 2>/dev/null | head -1 || true)"
if [ -n "$layer" ]; then
    pass "layer created: $(basename "$layer")"
else
    fail "no filesystem_z*.squashfs layer created"
fi
[ -f "${layer%.squashfs}.sh" ] && pass "companion .sh saved next to layer" || fail "no companion .sh"
case "$(basename "$layer")" in
    filesystem_z*) pass "layer named filesystem_z* (sorts last = highest precedence)" ;;
    *) fail "layer not named filesystem_z*: $(basename "$layer")" ;;
esac
# the new layer must sort after the firstboot layer too (newest wins)
if [ -n "$layer" ] && [ -f "$FAKE_USB/casper/filesystem_z0_firstboot.squashfs" ]; then
    if [ "$(basename "$layer")" \> "filesystem_z0_firstboot.squashfs" ]; then
        pass "new layer sorts after filesystem_z0_firstboot.squashfs"
    else
        fail "new layer does not sort after filesystem_z0_firstboot.squashfs"
    fi
fi
if ls "$FAKE_USB"/casper/uproot-logs/*uproot-*.log >/dev/null 2>&1; then
    pass "uproot log written to USB"
else
    fail "no uproot log on USB"
fi

# mock apt log (captured in the overlay upper)
APTLOG=/tmp/squashfs/upper/var/log/mock-apt.log
if [ -f "$APTLOG" ]; then
    grep -q "apt install -y btrfs-progs" "$APTLOG" && pass "main package list installed with -y" || fail "main package list missing"
    grep -q "apt update" "$APTLOG" && pass "apt update ran" || fail "apt update missing"
else
    fail "mock apt log not found (squashfs_config.sh did not run?)"
fi

# layer contents: has the mock-apt marker, does NOT contain base-only files
if [ -n "$layer" ]; then
    LAYER_LIST="$(unsquashfs -l "$layer" 2>/dev/null || true)"
    echo "$LAYER_LIST" | grep -q "var/lib/mock-apt-installed" && pass "layer contains mock-apt marker (upper changes)" || fail "layer missing mock-apt marker"
    echo "$LAYER_LIST" | grep -q "var/log/mock-apt.log" && pass "layer contains mock-apt log" || fail "layer missing mock-apt log"
    if echo "$LAYER_LIST" | grep -q "bin/bash"; then
        fail "layer contains base-only file bin/bash (should be upper-only)"
    else
        pass "layer is upper-only (no base files)"
    fi
fi

# --- 7) failure case: mock apt fails -> uproot must abort --------------------
echo "== uproot --auto-append (apt failure) =="
rm -rf /tmp/squashfs
touch "$FAKE_USB/mock-apt-fail"
if bash "$REPO_ROOT/bin/uproot" --auto-append; then
    fail "uproot exited 0 despite apt failure (should abort)"
else
    pass "uproot aborted (non-zero) when apt failed"
fi
rm -f "$FAKE_USB/mock-apt-fail"

# --- 8) emulate onboot.sh: source it and assert lsl_merge_fstab wires fstab --
echo "== onboot.sh emulation (lsl_merge_fstab) =="
# Mock the mount-inspection commands onboot.sh relies on, so we can assert the
# generated /etc/fstab block deterministically without any real mounts.
findmnt() {
    local target="${!#}"
    case "$target" in
        /cdrom) case "$*" in *SOURCE*) echo /dev/loop0;; *FSTYPE*) echo vfat;; esac ;;
        /home)  case "$*" in *SOURCE*) echo /dev/loop9;; *FSTYPE*) echo btrfs;; esac ;;
        *) : ;;
    esac
}
mountpoint() { local t="${!#}"; case "$t" in /cdrom|/home) return 0;; *) return 1;; esac; }
blkid() { echo "TEST-UUID"; }
losetup() { echo "/cdrom/home.btrfs"; }

# With the new sourceable guard, sourcing onboot.sh defines its functions
# without running the boot logic (modprobe/mount/loop setup).
if ! source "$REPO_ROOT/onboot.sh" 2>/dev/null; then
    fail "could not source onboot.sh"
else
    if declare -F lsl_merge_fstab >/dev/null 2>&1; then
        pass "onboot.sh sourced: lsl_merge_fstab defined"
    else
        fail "onboot.sh sourced but lsl_merge_fstab not defined"
    fi

    FSTAB_BAK="$(mktemp)"
    cp /etc/fstab "$FSTAB_BAK" 2>/dev/null || : > "$FSTAB_BAK"
    : > /etc/fstab
    if lsl_merge_fstab 2>/dev/null; then
        pass "lsl_merge_fstab ran without error"
    else
        fail "lsl_merge_fstab returned non-zero"
    fi
    if grep -q "# BEGIN lsl-usb fstab" /etc/fstab; then
        pass "fstab got the lsl-usb block"
    else
        fail "fstab missing # BEGIN lsl-usb fstab"
    fi
    if grep -q "UUID=TEST-UUID /cdrom vfat defaults,ro,nofail 0 0" /etc/fstab; then
        pass "fstab mounts /cdrom from its UUID"
    else
        fail "fstab missing /cdrom UUID line"
    fi
    if grep -q "/cdrom/home.btrfs /home btrfs loop,compress=zstd:3,relatime,nofail 0 0" /etc/fstab; then
        pass "fstab wires /home onto the btrfs loop (home on the right fs)"
    else
        fail "fstab missing /home btrfs loop line"
    fi
    # Idempotency: re-running must not duplicate the block.
    lsl_merge_fstab 2>/dev/null || true
    if [ "$(grep -c '# BEGIN lsl-usb fstab' /etc/fstab)" -eq 1 ]; then
        pass "lsl_merge_fstab is idempotent (single block)"
    else
        fail "lsl_merge_fstab duplicated the block"
    fi
    cp "$FSTAB_BAK" /etc/fstab 2>/dev/null || true
    rm -f "$FSTAB_BAK"
fi

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
