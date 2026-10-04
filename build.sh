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

# The F2FS partitioning tools (sfdisk/fatresize/mkfs.f2fs + libs), staged from
# an ISO's own rootfs by scripts/extract-f2fs-tools.sh. OPTIONAL: without it the
# initrd still gets the hooks, they simply no-op, so a missing blob degrades a
# boot rather than failing the build.
F2FS_TOOLS_TARBALL="${F2FS_TOOLS_TARBALL:-$REPO_ROOT/rust9x/lslsetup/assets/f2fs-tools.tar.gz}"
export F2FS_TOOLS_TARBALL

command -v mksquashfs >/dev/null 2>&1 || { echo "ERROR: mksquashfs (squashfs-tools) not found" >&2; exit 1; }
command -v zip       >/dev/null 2>&1 || { echo "ERROR: zip not found" >&2; exit 1; }
for f in "$REPO_ROOT"/misc/lsl-firstboot.sh "$REPO_ROOT"/misc/lsl-firstboot.service \
         "$REPO_ROOT"/misc/lsl-firstboot-progress.sh "$REPO_ROOT"/misc/lsl-firstboot-progress.desktop \
         "$REPO_ROOT"/misc/lsl-firstboot-reboot.sh "$REPO_ROOT"/misc/lsl-progress-gtk.py \
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

echo "Running reclaim-Windows-swap unit tests..."
bash "$REPO_ROOT/tests/lsl-reclaim-win-swap.tests.sh" || echo "  (reclaim-win-swap test failed - non-fatal)"

# --- 0d) embedded z0 firstboot layer is fresh (WHYFAIL10) ------------------
# rust9x/lslsetup embeds rust9x/lslsetup/assets/filesystem.z0.squashfs
# (include_bytes!), so cargo depends on that blob, not on the misc/ sources it
# is packed from - editing misc/ without regenerating used to reship a stale
# firstboot layer silently. build.rs re-hashes the sources against
# assets/z0_sources.sha256 at build time; cross-check the committed blob against
# a fresh pack of misc/ here too, so a stale layer fails the bundle build (and
# CI, which runs build.sh) instead of shipping old firstboot scripts.
echo "Checking the embedded z0 firstboot layer is fresh (WHYFAIL10)..."
bash "$REPO_ROOT/misc/check-z0-freshness.sh" "$REPO_ROOT"

# rust9x/lslsetup embeds 36 repo files with include_str! into FIRSTBOOT_TOOLKIT
# (bin/lsl-pin-favorites, config.sh, uproot, onboot.sh, systemd units, ...) and
# the nofmt installer writes the stick's /cdrom from that array ALONE. A
# committed/prebuilt lslsetup.exe keeps whatever those files held when it was
# COMPILED, so a fix in bin/ can sit unshipped indefinitely - on 2026-10-01
# every shipped exe still embedded the broken pin script (it split gsettings
# arrays on newlines, dropping every pinned app from the panel) while the fix
# was already in bin/. build.rs re-hashes the sources against
# assets/toolkit_sources.sha256 at build time; verify the manifest covers the
# working tree here too, so a stale toolkit fails the bundle build and CI.
echo "Checking the embedded firstboot toolkit is fresh (WHYFAIL13 follow-up)..."
bash "$REPO_ROOT/misc/check-toolkit-freshness.sh" "$REPO_ROOT"

# --- 1) minimal first-boot layer -------------------------------------------
LAYER="$STAGE/layer"
mkdir -p "$LAYER/usr/local/sbin" "$LAYER/usr/local/bin" \
         "$LAYER/etc/systemd/system/multi-user.target.wants" \
         "$LAYER/etc/xdg/autostart"

install -m 755 "$REPO_ROOT/misc/lsl-firstboot.sh" "$LAYER/usr/local/sbin/lsl-firstboot.sh"
install -m 755 "$REPO_ROOT/misc/lsl-firstboot-progress.sh" "$LAYER/usr/local/bin/lsl-firstboot-progress.sh"
install -m 755 "$REPO_ROOT/misc/lsl-firstboot-reboot.sh" "$LAYER/usr/local/bin/lsl-firstboot-reboot.sh"
install -m 755 "$REPO_ROOT/misc/lsl-progress-gtk.py" "$LAYER/usr/local/bin/lsl-progress-gtk.py"
install -m 644 "$REPO_ROOT/misc/lsl-firstboot.service" "$LAYER/etc/systemd/system/lsl-firstboot.service"
install -m 644 "$REPO_ROOT/systemd/onboot.service" "$LAYER/etc/systemd/system/onboot.service"
install -m 644 "$REPO_ROOT/systemd/lsl-home.service" "$LAYER/etc/systemd/system/lsl-home.service"
install -m 644 "$REPO_ROOT/misc/lsl-firstboot-progress.desktop" "$LAYER/etc/xdg/autostart/lsl-firstboot-progress.desktop"
install -m 644 "$REPO_ROOT/misc/lsl-boot-time.desktop" "$LAYER/etc/xdg/autostart/lsl-boot-time.desktop"
install -m 755 "$REPO_ROOT/misc/lsl-firstboot-failed.sh" "$LAYER/usr/local/bin/lsl-firstboot-failed.sh"
install -m 644 "$REPO_ROOT/misc/lsl-firstboot-failed.desktop" "$LAYER/etc/xdg/autostart/lsl-firstboot-failed.desktop"
install -m 755 "$REPO_ROOT/misc/lsl-merge-suggest.sh" "$LAYER/usr/local/bin/lsl-merge-suggest.sh"
install -m 644 "$REPO_ROOT/misc/lsl-merge-suggest.desktop" "$LAYER/etc/xdg/autostart/lsl-merge-suggest.desktop"
# Enable the unit by symlink (overlayfs handles lower-layer symlinks fine).
ln -s ../lsl-firstboot.service "$LAYER/etc/systemd/system/multi-user.target.wants/lsl-firstboot.service"
ln -s ../onboot.service "$LAYER/etc/systemd/system/multi-user.target.wants/onboot.service"
ln -s ../lsl-home.service "$LAYER/etc/systemd/system/multi-user.target.wants/lsl-home.service"

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

# --- 2b) repack the initrd to add the HDD-mirror auto-detect hook ------------
# The base initrd ships from the Mint ISO Rufus wrote. We inject our casper-premount
# hook (initramfs/lsl_hdd_mirror.sh) so the live root can assemble from a local
# mirror of the squashfs layers. The unmodified initrd is preserved as
# casper/initrd.safe.lz so the user can boot a known-good "safe" entry (no mirror,
# pure USB). Set LSL_BASE_INITRD to override the source initrd location.
repack_initrd() {
    local base="${LSL_BASE_INITRD:-/cdrom/casper/initrd.lz}"
    if [ ! -f "$base" ]; then
        echo "WARNING: base initrd not found at $base; set LSL_BASE_INITRD to enable" >&2
        echo "         boot-from-HDD auto-detect. Skipping initrd repack." >&2
        return 0
    fi
    command -v unmkinitramfs >/dev/null 2>&1 || { echo "ERROR: unmkinitramfs missing; cannot repack initrd." >&2; return 1; }
    local tmp; tmp="$(mktemp -d)"
    if ! unmkinitramfs "$base" "$tmp" 2>/dev/null; then
        echo "ERROR: unmkinitramfs failed on $base" >&2; rm -rf "$tmp"; return 1
    fi
    local casper_hook="$REPO_ROOT/initramfs/lsl_hdd_mirror.sh"
    local live_hook="$REPO_ROOT/initramfs/lsl_liveboot_mirror.sh"
    local antix_hook="$REPO_ROOT/initramfs/lsl_antix_mirror.sh"
    local f2fs_hook="$REPO_ROOT/initramfs/lsl_f2fs_scrub.sh"
    local f2fs_prov="$REPO_ROOT/initramfs/lsl_f2fs_provision.sh"
    local f2fs_tools="$REPO_ROOT/initramfs/lsl-f2fs-tools.sh"
    [ -f "$casper_hook" ] || { echo "ERROR: $casper_hook missing" >&2; rm -rf "$tmp"; return 1; }
    [ -f "$live_hook" ] || { echo "ERROR: $live_hook missing" >&2; rm -rf "$tmp"; return 1; }
    [ -f "$antix_hook" ] || { echo "ERROR: $antix_hook missing" >&2; rm -rf "$tmp"; return 1; }
    [ -f "$f2fs_hook" ] || { echo "ERROR: $f2fs_hook missing" >&2; rm -rf "$tmp"; return 1; }
    [ -f "$f2fs_prov" ] || { echo "ERROR: $f2fs_prov missing" >&2; rm -rf "$tmp"; return 1; }
    [ -f "$f2fs_tools" ] || { echo "ERROR: $f2fs_tools missing" >&2; rm -rf "$tmp"; return 1; }
    local injected=0
    for d in "$tmp"/*/; do
        # --- Debian live-boot (also antiX's live-init fork roots) ---
        # live-boot's run_scripts *sources* the ORDER file in the script dir, so
        # the ORDER MUST exist (otherwise `. "${initdir}/ORDER"` fails and /init
        # aborts under set -e). We dot-source our hook so `export
        # LIVE_MEDIA_PATH=sfs` reaches Live()/find_livefs in the live-boot shell.
        if [ -d "${d}usr/lib/live/boot" ] && [ ! -f "${d}scripts/live-premount/00lsl_liveboot_mirror" ]; then
            mkdir -p "${d}scripts/live-premount"
            cp "$live_hook" "${d}scripts/live-premount/00lsl_liveboot_mirror"
            chmod +x "${d}scripts/live-premount/00lsl_liveboot_mirror"
            order="${d}scripts/live-premount/ORDER"
            if [ ! -f "$order" ]; then
                printf '. /scripts/live-premount/00lsl_liveboot_mirror "$@"\n' > "$order"
            elif ! grep -q '00lsl_liveboot_mirror' "$order"; then
                printf '. /scripts/live-premount/00lsl_liveboot_mirror "$@"\n' >> "$order"
            fi
            injected=1
        fi
        # --- antiX live-init (32-bit x86; a live-boot fork, monolithic /init) ---
        # antiX's /init calls find_linuxfs_file() and honours SQFILE_FILE (default
        # /antiX/linuxfs). We drop the hook at the initrd root and source it just
        # before that call so `export SQFILE_FILE=/sfs/filesystem.squashfs` reaches
        # antiX's scanner. The hook is SOURCED (no `return`/`exit`), so it must not
        # be executed as a subprocess; the leading `. ` sources it in /init's shell.
        if [ -f "${d}init" ] && grep -q 'DEFAULT_SQFILE=/antiX/linuxfs' "${d}init" 2>/dev/null && [ ! -f "${d}lsl_antix_mirror.sh" ]; then
            cp "$antix_hook" "${d}lsl_antix_mirror.sh"
            chmod +x "${d}lsl_antix_mirror.sh"
            # Insert the source line right before the find_linuxfs_file CALL (the
            # only bare call; the function definition is 'find_linuxfs_file() {'
            # and is not matched by the end-of-line anchor).
            if ! grep -q 'lsl_antix_mirror' "${d}init"; then
                sed -i 's#^[[:space:]]*find_linuxfs_file[[:space:]]*$#. /lsl_antix_mirror.sh\n        find_linuxfs_file#' "${d}init"
            fi
            injected=1
        fi
        # --- casper (Mint/Ubuntu) ---
        if [ -d "${d}scripts/casper-premount" ] && [ ! -f "${d}scripts/casper-premount/zz_lsl_hdd_mirror" ]; then
            cp "$casper_hook" "${d}scripts/casper-premount/zz_lsl_hdd_mirror"
            chmod +x "${d}scripts/casper-premount/zz_lsl_hdd_mirror"
            # casper's run_scripts *sources* the ORDER file; each ORDER line runs the
            # script as a subprocess, so an exported LAYERFS_PATH would NOT reach
            # casper. Source the hook instead (dot-prefixed line) so it runs in
            # casper's shell and its export propagates to find_livefs.
            order="${d}scripts/casper-premount/ORDER"
            if [ -f "$order" ] && ! grep -q 'zz_lsl_hdd_mirror' "$order"; then
                printf '. /scripts/casper-premount/zz_lsl_hdd_mirror "$@"\n' >> "$order"
            fi
            injected=1
        fi
        # --- casper (Mint/Ubuntu): F2FS identity scrub (P2 of DESIGN-F2FS) ---
        # Same sourcing requirement as the mirror hook: it uses `return`, which
        # is only valid sourced, and it must run in casper's shell.
        if [ -d "${d}scripts/casper-premount" ] && [ ! -f "${d}scripts/casper-premount/zz_lsl_f2fs_scrub" ]; then
            cp "$f2fs_hook" "${d}scripts/casper-premount/zz_lsl_f2fs_scrub"
            chmod +x "${d}scripts/casper-premount/zz_lsl_f2fs_scrub"
            order="${d}scripts/casper-premount/ORDER"
            if [ -f "$order" ] && ! grep -q 'zz_lsl_f2fs_scrub' "$order"; then
                printf '. /scripts/casper-premount/zz_lsl_f2fs_scrub "$@"\n' >> "$order"
            fi
            injected=1
        fi
        # --- casper (Mint/Ubuntu): F2FS partition CREATION (P1b) ---
        # ORDER MATTERS: this hook must be sourced BEFORE the scrub, because it
        # creates the partition the scrub then cleans - and `>>` cannot run
        # first. Insert the line IMMEDIATELY BEFORE the scrub's rather than at
        # the top of the file, so casper's own casper-premount scripts keep
        # running first. That matches the Rust CASPER_PREMOUNT_ORDER exactly
        # (base scripts, then our hooks, provision before scrub); prepending to
        # the very top would run a repartitioning hook ahead of casper's own
        # scripts, which the Rust path does not do.
        # Inert unless the kernel cmdline carries lsl_f2fs_provision=<GiB>, so
        # shipping it unconditionally is safe: only an f2fs-selected stick sets
        # that flag.
        if [ -d "${d}scripts/casper-premount" ] && [ ! -f "${d}scripts/casper-premount/zz_lsl_f2fs_provision" ]; then
            cp "$f2fs_prov" "${d}scripts/casper-premount/zz_lsl_f2fs_provision"
            chmod +x "${d}scripts/casper-premount/zz_lsl_f2fs_provision"
            order="${d}scripts/casper-premount/ORDER"
            if [ -f "$order" ] && ! grep -q 'zz_lsl_f2fs_provision' "$order"; then
                local prov_line='. /scripts/casper-premount/zz_lsl_f2fs_provision "$@"'
                local order_new="${order}.lsl.$$"
                if grep -q 'zz_lsl_f2fs_scrub' "$order"; then
                    # Insert before the scrub line (first occurrence only).
                    awk -v l="$prov_line" '
                        !done && /zz_lsl_f2fs_scrub/ { print l; done=1 }
                        { print }
                    ' "$order" > "$order_new"
                else
                    # No scrub line yet (should not happen - it is injected just
                    # above): append rather than lose the hook.
                    { cat "$order"; printf '%s\n' "$prov_line"; } > "$order_new"
                fi
                mv -f "$order_new" "$order"
            fi
            injected=1
        fi
        # The tool unpacker rides along with the hook, and the tarball with that.
        # Without the tools the hook no-ops and says so - a degraded boot beats
        # a failed build, and the tools are only needed when the flag is set.
        if [ ! -f "${d}bin/lsl-f2fs-tools.sh" ]; then
            mkdir -p "${d}bin"
            cp "$f2fs_tools" "${d}bin/lsl-f2fs-tools.sh"
            chmod +x "${d}bin/lsl-f2fs-tools.sh"
            if [ -f "$F2FS_TOOLS_TARBALL" ]; then
                mkdir -p "${d}lsl-tools"
                cp "$F2FS_TOOLS_TARBALL" "${d}lsl-tools/f2fs-tools.tar.gz"
            else
                echo "  NOTE: f2fs-tools.tar.gz not built (scripts/extract-f2fs-tools.sh);" >&2
                echo "        the stick will boot but cannot create its f2fs partition." >&2
            fi
        fi
    done
    mkdir -p "$DIST/casper"
    cp "$base" "$DIST/casper/initrd.safe.lz"   # original, untouched
    local comp="gzip"; command -v lz4 >/dev/null 2>&1 && comp="lz4"
    if [ "$comp" = "lz4" ]; then
        ( for dd in "$tmp"/*/; do ( cd "$dd" && find . -print0 | cpio -0 -H newc -o ); done ) | lz4 -l -9 - "$DIST/casper/initrd.lz"
    else
        ( for dd in "$tmp"/*/; do ( cd "$dd" && find . -print0 | cpio -0 -H newc -o ); done ) | gzip -9 -c > "$DIST/casper/initrd.lz"
    fi
    rm -rf "$tmp"
    echo "Repacked initrd -> $DIST/casper/initrd.lz (compressor=$comp, hook injected=$injected; original saved as initrd.safe.lz)"
}
repack_initrd || { echo "ERROR: initrd repack failed." >&2; exit 1; }
# Ship both initrds in the bundle so install.ps1 copies them onto the USB.
# Guarded: without a base initrd (normal in CI) the repack skips and
# $DIST/casper never exists - preflight already treats absent initrds as
# optional, so only a failed repack (above) is fatal.
if [ -d "$DIST/casper" ]; then
    cp -a "$DIST/casper" "$BUNDLE/casper"
else
    echo "No repacked initrds (skipped) - bundle ships without casper/." >&2
fi

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
        usr/local/bin/lsl-firstboot-reboot.sh \
        usr/local/bin/lsl-progress-gtk.py \
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
wants="filesystem_z0_firstboot.squashfs bin/ systemd/ fuse/ onboot.sh lsl-usb.env install.ps1 install.bat"
[ -f "$DIST/casper/initrd.lz" ] && wants="$wants casper/initrd.lz"
for want in $wants; do
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

echo "Preflight: verifying hardware cache matches the ID list..."
if [ -f "$REPO_ROOT/tools/hw-cache-ids.txt" ] && [ -d "$REPO_ROOT/lsl-hw-cache" ]; then
    # Count IDs in the list (non-comment, non-blank, valid format) and compare to
    # the shipped LKDDb page count so a dropped upstream fetch is caught in CI.
    # grep -c returns 1 when there are zero matches; guard it so set -e doesn't abort.
    want="$(grep -vE '^[[:space:]]*(#|$)' "$REPO_ROOT/tools/hw-cache-ids.txt" | grep -cE '^(pci|usb):[0-9a-fA-F]{4}-[0-9a-fA-F]{4}([[:space:]]|$)' || true)"
    have="$(ls -1 "$REPO_ROOT/lsl-hw-cache"/*.html 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$want" != "$have" ]; then
        echo "ERROR: hardware cache mismatch: $want IDs in tools/hw-cache-ids.txt but $have pages in lsl-hw-cache/." >&2
        echo "       Re-run: pwsh tools/build-hw-cache.ps1" >&2
        exit 1
    fi
    echo "Hardware cache: $have pages match $want IDs."
else
    echo "WARNING: skipping hardware-cache check (tools/hw-cache-ids.txt or lsl-hw-cache/ missing)."
fi

echo "Built:"
ls -lh "$DIST/lsl-usb-win.zip" "$DIST/filesystem_z0_firstboot.squashfs"
echo ""
echo "How it works:"
echo "  1. Run install.ps1 on Windows (or unzip lsl-usb-win.zip next to it)."
echo "  2. First boot of the USB runs lsl-firstboot.service, which installs"
echo "     /cdrom/bin/squashfs_config.sh packages and appends a new layer."
echo "  3. Progress shows in a desktop dialog (lsl-firstboot-progress.sh)."
