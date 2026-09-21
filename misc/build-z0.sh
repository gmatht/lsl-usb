#!/bin/bash
# build-z0.sh - rebuild the firstboot stub layer from misc/ sources.
# ============================================================================
# The nofmt installer ships the output as casper/filesystem.z0.squashfs
# (embedded from rust9x/lslsetup/assets/filesystem.z0.squashfs via
# include_bytes! in src/lslfiles.rs); casper's layerfs-path walk stacks
# base + z0 + whatever layer the boot configs NAME (bin/uproot repoints
# them when it appends). Rebuild whenever misc/ changes
# and commit the blob (cargo test checks hsqs magic/size).
#
# Usage: ./misc/build-z0.sh [OUTPUT]
#   default OUTPUT: <repo-root>/rust9x/lslsetup/assets/filesystem.z0.squashfs
#
# Requires: mksquashfs, unsquashfs (WSL: sudo apt install squashfs-tools).
# Runs unprivileged; all inputs are plain files.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
M="$REPO_ROOT/misc"
OUT="${1:-$REPO_ROOT/rust9x/lslsetup/assets/filesystem.z0.squashfs}"

for f in lsl-firstboot.sh lsl-firstboot-progress.sh lsl-progress-gtk.py lsl-firstboot-reboot.sh lsl-firstboot.service \
         lsl-firstboot-progress.desktop lsl-boot-time.desktop \
         lsl-firstboot-failed.sh lsl-firstboot-failed.desktop \
         lsl-merge-suggest.sh lsl-merge-suggest.desktop \
         "$REPO_ROOT/systemd/onboot.service"; do
    case "$f" in /*) check="$f" ;; *) check="$M/$f" ;; esac
    [ -f "$check" ] || { echo "missing $check" >&2; exit 1; }
done

rm -rf /tmp/z0build
mkdir -p /tmp/z0build/usr/local/sbin /tmp/z0build/usr/local/bin \
         /tmp/z0build/etc/systemd/system/multi-user.target.wants \
         /tmp/z0build/etc/xdg/autostart
install -m 755 "$M/lsl-firstboot.sh" /tmp/z0build/usr/local/sbin/lsl-firstboot.sh
install -m 755 "$M/lsl-firstboot-progress.sh" /tmp/z0build/usr/local/bin/lsl-firstboot-progress.sh
install -m 755 "$M/lsl-firstboot-reboot.sh" /tmp/z0build/usr/local/bin/lsl-firstboot-reboot.sh
install -m 755 "$M/lsl-progress-gtk.py" /tmp/z0build/usr/local/bin/lsl-progress-gtk.py
install -m 644 "$M/lsl-firstboot.service" /tmp/z0build/etc/systemd/system/lsl-firstboot.service
install -m 644 "$REPO_ROOT/systemd/onboot.service" /tmp/z0build/etc/systemd/system/onboot.service
install -m 644 "$M/lsl-firstboot-progress.desktop" /tmp/z0build/etc/xdg/autostart/lsl-firstboot-progress.desktop
install -m 644 "$M/lsl-boot-time.desktop" /tmp/z0build/etc/xdg/autostart/lsl-boot-time.desktop
install -m 755 "$M/lsl-firstboot-failed.sh" /tmp/z0build/usr/local/bin/lsl-firstboot-failed.sh
install -m 644 "$M/lsl-firstboot-failed.desktop" /tmp/z0build/etc/xdg/autostart/lsl-firstboot-failed.desktop
install -m 755 "$M/lsl-merge-suggest.sh" /tmp/z0build/usr/local/bin/lsl-merge-suggest.sh
install -m 644 "$M/lsl-merge-suggest.desktop" /tmp/z0build/etc/xdg/autostart/lsl-merge-suggest.desktop
ln -s ../lsl-firstboot.service /tmp/z0build/etc/systemd/system/multi-user.target.wants/lsl-firstboot.service
ln -s ../onboot.service /tmp/z0build/etc/systemd/system/multi-user.target.wants/onboot.service

# LF-guard: /bin/bash chokes on CRLF from Windows checkouts.
if grep -rlq $'\r' /tmp/z0build/usr /tmp/z0build/etc 2>/dev/null; then
    echo "CR bytes found in staged scripts - aborting" >&2
    grep -rl $'\r' /tmp/z0build/usr /tmp/z0build/etc >&2 || true
    exit 1
fi

mksquashfs /tmp/z0build "$OUT" -noappend -comp zstd >/dev/null
echo "BUILD_OK $OUT ($(du -h "$OUT" | cut -f1))"

# Self-checks against the packed blob.
echo -n "try_mount_stick count: "
unsquashfs -cat "$OUT" usr/local/sbin/lsl-firstboot.sh 2>/dev/null | grep -c try_mount_stick || true
echo -n "run-from-stick UPROOT refs: "
unsquashfs -cat "$OUT" usr/local/sbin/lsl-firstboot.sh 2>/dev/null | grep -c 'STICK_DIR/bin/uproot' || true
echo -n "dotted-layer cleanup globs: "
unsquashfs -cat "$OUT" usr/local/sbin/lsl-firstboot.sh 2>/dev/null | grep -c 'filesystem.z0' || true
echo -n "CR bytes in packed service script: "
unsquashfs -cat "$OUT" usr/local/sbin/lsl-firstboot.sh 2>/dev/null | tr -cd '\r' | wc -c
rm -rf /tmp/z0build
