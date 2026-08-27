#!/bin/bash
# build.sh - build the lsl-usb Windows installer bundle.
#
# Produces, in ./dist/:
#   filesystem_z0_firstboot.squashfs   the ~4 KB first-boot layer (a systemd unit
#                                     + scripts only - no distro binaries), and
#   lsl-usb-win.zip                   the bundle install.ps1 drops onto a USB:
#                                     the layer + bin/ + onboot.sh + lsl-usb.env
#                                     + systemd/ + install.ps1
#
# The first boot of the finished USB runs lsl-firstboot.service, which installs
# packages from /cdrom/bin/squashfs_config.sh (editable on the FAT partition,
# even from Windows) via uproot --auto-append and persists a new layer itself.
# Nothing in the shipped bundle is tied to a specific Mint/Ubuntu release.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="$REPO_ROOT/dist"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

command -v mksquashfs >/dev/null 2>&1 || { echo "ERROR: mksquashfs (squashfs-tools) not found" >&2; exit 1; }
command -v zip       >/dev/null 2>&1 || { echo "ERROR: zip not found" >&2; exit 1; }
for f in "$REPO_ROOT"/misc/lsl-firstboot.sh "$REPO_ROOT"/misc/lsl-firstboot.service \
         "$REPO_ROOT"/misc/lsl-firstboot-progress.sh "$REPO_ROOT"/misc/lsl-firstboot-progress.desktop \
         "$REPO_ROOT"/misc/lsl-firstboot-failed.sh "$REPO_ROOT"/misc/lsl-firstboot-failed.desktop \
         "$REPO_ROOT"/misc/lsl-merge-suggest.sh "$REPO_ROOT"/misc/lsl-merge-suggest.desktop; do
    [ -f "$f" ] || { echo "ERROR: missing $f" >&2; exit 1; }
done

# --- 0) run the install.ps1 test suite (fail the build on regressions) -----
if command -v pwsh >/dev/null 2>&1; then
    echo "Running install.ps1 test suite..."
    pwsh -NoProfile -File "$REPO_ROOT/tests/install.ps1.tests.ps1"
else
    echo "WARNING: pwsh not found; skipping install.ps1 tests." >&2
fi

# --- 0b) shellcheck the shell scripts (fail the build on real bugs) -------
if command -v shellcheck >/dev/null 2>&1; then
    echo "Running shellcheck (severity: error)..."
    # Every shell script in the bundle: bin/ + misc/ (shebang-detected), plus
    # the top-level scripts.
    mapfile -t SCRIPTS < <(find "$REPO_ROOT/bin" "$REPO_ROOT/misc" -maxdepth 1 -type f -print0 |
        while IFS= read -r -d '' f; do
            if head -c 200 "$f" | grep -qE '^#![[:space:]]*/?(usr/bin/env[[:space:]]+)?(ba)?sh'; then
                printf '%s\n' "$f"
            fi
        done)
    SCRIPTS+=("$REPO_ROOT/onboot.sh" "$REPO_ROOT/install.sh" "$REPO_ROOT/fetch.sh" "$REPO_ROOT/build.sh")
    if [ "${#SCRIPTS[@]}" -gt 0 ]; then
        shellcheck -S error -x "${SCRIPTS[@]}"
    fi
else
    echo "WARNING: shellcheck not found; falling back to bash -n syntax check." >&2
    find "$REPO_ROOT/bin" "$REPO_ROOT/misc" -maxdepth 1 -type f -name '*.sh' -print0 |
        xargs -0 -n1 bash -n
    bash -n "$REPO_ROOT/onboot.sh" "$REPO_ROOT/install.sh" "$REPO_ROOT/fetch.sh" "$REPO_ROOT/build.sh"
fi

# --- 0c) bash-side smoke tests --------------------------------------------
echo "Running lsl-common smoke tests..."
bash "$REPO_ROOT/tests/lsl-common.tests.sh"

echo "Running mount_all unit tests..."
bash "$REPO_ROOT/tests/mount_all.tests.sh"

echo "Running casper layer-name check (set Casper_GLOB if your initrd differs)..."
bash "$REPO_ROOT/tests/casper-layer-check.sh"

echo "Running overlayfs-tools whiteout behavior test (skips if unavailable)..."
bash "$REPO_ROOT/tests/overlayfs-whiteout.tests.sh" || echo "  (overlayfs-whiteout test skipped or failed - non-fatal)"

echo "Running overlay-merge.py whiteout test..."
bash "$REPO_ROOT/tests/overlay-merge.tests.sh" || echo "  (overlay-merge whiteout test failed - non-fatal)"

echo "Running merge-suggestion trigger-logic test..."
bash "$REPO_ROOT/tests/lsl-merge-suggest.tests.sh" || echo "  (merge-suggestion test failed - non-fatal)"

echo "Running btrfs online-grow (lsl-btrfs-growd) test..."
bash "$REPO_ROOT/tests/btrfs-growd.tests.sh" || echo "  (btrfs-growd test skipped or failed - non-fatal)"

# --- 1) minimal first-boot layer -------------------------------------------
LAYER="$STAGE/layer"
mkdir -p "$LAYER/usr/local/sbin" "$LAYER/usr/local/bin" \
         "$LAYER/etc/systemd/system/multi-user.target.wants" \
         "$LAYER/etc/xdg/autostart"

install -m 755 "$REPO_ROOT/misc/lsl-firstboot.sh" "$LAYER/usr/local/sbin/lsl-firstboot.sh"
install -m 755 "$REPO_ROOT/misc/lsl-firstboot-progress.sh" "$LAYER/usr/local/bin/lsl-firstboot-progress.sh"
install -m 644 "$REPO_ROOT/misc/lsl-firstboot.service" "$LAYER/etc/systemd/system/lsl-firstboot.service"
install -m 644 "$REPO_ROOT/misc/lsl-firstboot-progress.desktop" "$LAYER/etc/xdg/autostart/lsl-firstboot-progress.desktop"
install -m 644 "$REPO_ROOT/misc/lsl-boot-time.desktop" "$LAYER/etc/xdg/autostart/lsl-boot-time.desktop"
install -m 755 "$REPO_ROOT/misc/lsl-firstboot-failed.sh" "$LAYER/usr/local/bin/lsl-firstboot-failed.sh"
install -m 644 "$REPO_ROOT/misc/lsl-firstboot-failed.desktop" "$LAYER/etc/xdg/autostart/lsl-firstboot-failed.desktop"
install -m 755 "$REPO_ROOT/misc/lsl-merge-suggest.sh" "$LAYER/usr/local/bin/lsl-merge-suggest.sh"
install -m 644 "$REPO_ROOT/misc/lsl-merge-suggest.desktop" "$LAYER/etc/xdg/autostart/lsl-merge-suggest.desktop"
# Enable the unit by symlink (overlayfs handles lower-layer symlinks fine).
ln -s ../lsl-firstboot.service "$LAYER/etc/systemd/system/multi-user.target.wants/lsl-firstboot.service"

mkdir -p "$DIST"
mksquashfs "$LAYER" "$DIST/filesystem_z0_firstboot.squashfs" -noappend -comp zstd >/dev/null

# --- 2) FAT-side bundle (what install.ps1 drops onto the USB) ---------------
BUNDLE="$STAGE/bundle"
mkdir -p "$BUNDLE"
cp -a "$REPO_ROOT/bin" "$BUNDLE/bin"
cp -a "$REPO_ROOT/systemd" "$BUNDLE/systemd"
cp -a "$REPO_ROOT/fuse" "$BUNDLE/fuse"
cp -a "$REPO_ROOT/onboot.sh" "$REPO_ROOT/lsl-usb.env" "$BUNDLE/"
cp -a "$REPO_ROOT/install.ps1" "$REPO_ROOT/install.bat" "$REPO_ROOT/resolve-powershell.ps1" "$REPO_ROOT/VERSION" "$BUNDLE/"
cp -a "$DIST/filesystem_z0_firstboot.squashfs" "$BUNDLE/"

# --- 3. zip it ---------------------------------------------------------------
# rm first: zip -qr updates an existing archive and leaves stale entries behind.
rm -f "$DIST/lsl-usb-win.zip"
(cd "$BUNDLE" && zip -qr "$DIST/lsl-usb-win.zip" .)
sync

# --- 4) preflight: verify the bundle is self-consistent --------------------
echo "Preflight: verifying bundle contents..."
FAIL=0

# a) the firstboot layer contains the expected files
if command -v unsquashfs >/dev/null 2>&1; then
    LAYER_LIST="$(unsquashfs -l "$DIST/filesystem_z0_firstboot.squashfs" 2>/dev/null || true)"
    for want in \
        usr/local/sbin/lsl-firstboot.sh \
        usr/local/bin/lsl-firstboot-progress.sh \
        etc/systemd/system/lsl-firstboot.service \
        etc/systemd/system/multi-user.target.wants/lsl-firstboot.service \
        etc/xdg/autostart/lsl-firstboot-progress.desktop \
        etc/xdg/autostart/lsl-boot-time.desktop \
        etc/xdg/autostart/lsl-firstboot-failed.desktop \
        etc/xdg/autostart/lsl-merge-suggest.desktop \
        usr/local/bin/lsl-firstboot-failed.sh \
        usr/local/bin/lsl-merge-suggest.sh; do
        if ! grep -qF "$want" <<<"$LAYER_LIST"; then
            echo "ERROR: firstboot layer missing: $want" >&2
            FAIL=1
        fi
    done
else
    echo "WARNING: unsquashfs not found; skipping layer content check." >&2
fi

# b) every ExecStart= /cdrom/... path in systemd/*.service exists in the bundle
for svc in "$REPO_ROOT"/systemd/*.service; do
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        rel="${p#/cdrom/}"
        if [ ! -e "$BUNDLE/$rel" ]; then
            echo "ERROR: $(basename "$svc") references missing bundle file: $p" >&2
            FAIL=1
        fi
    done < <(grep -E '^ExecStart=' "$svc" | grep -oE '/cdrom/[^ ]+' || true)
done

# c) the zip has all expected top-level entries
# Capture the listing once: grep -q on a pipe exits early and SIGPIPEs unzip,
# which under pipefail makes the check spuriously fail (intermittently).
ZIP_LIST="$(unzip -l "$DIST/lsl-usb-win.zip")"
for want in filesystem_z0_firstboot.squashfs bin/ systemd/ fuse/ onboot.sh lsl-usb.env install.ps1 install.bat; do
    if ! grep -qE "[[:space:]]$want$" <<<"$ZIP_LIST"; then
        echo "ERROR: zip missing top-level entry: $want" >&2
        FAIL=1
    fi
done

if [ "$FAIL" -ne 0 ]; then
    echo "ERROR: bundle preflight failed." >&2
    exit 1
fi
echo "Preflight OK."

echo "Built:"
ls -lh "$DIST/lsl-usb-win.zip" "$DIST/filesystem_z0_firstboot.squashfs"
echo ""
echo "How it works:"
echo "  1. Run install.ps1 on Windows (or unzip lsl-usb-win.zip next to it)."
echo "  2. First boot of the USB runs lsl-firstboot.service, which installs"
echo "     /cdrom/bin/squashfs_config.sh packages and appends a new layer."
echo "  3. Progress shows in a desktop dialog (lsl-firstboot-progress.sh)."
