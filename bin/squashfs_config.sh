#!/bin/bash

set -eo pipefail

apt update
# Resume cleanly if a previous first-boot attempt left dpkg/apt half-configured
# (interrupted apt install, etc.) before we add more packages.
dpkg --configure -a || true
apt-get install -f -y || true
# Optional offline firmware: the Windows installer (or the user) can drop .deb
# packages into /cdrom/firmware/ for hardware whose WiFi/ethernet needs
# out-of-tree firmware not in the base image. Install them first so the first-boot
# apt can then fetch over that interface even with no preloaded drivers.
if ls /cdrom/firmware/*.deb >/dev/null 2>&1; then
    echo "Installing offline firmware from /cdrom/firmware ..."
    dpkg -i /cdrom/firmware/*.deb >/dev/null 2>&1 || true
    apt-get install -f -y >/dev/null 2>&1 || true
fi
# Staged network drivers: the Windows installer drops these in /cdrom/drivers/
# for chipsets that need out-of-tree drivers on the 24.04 base (RTL8821CE,
# RTL8723DE, RTL88x2BU, RTL8812AU, RTL8814AU, RTL8188EU, RTL8723BU, Broadcom
# BCM43xx). Two forms:
#   *.deb     - Ubuntu-packaged DKMS drivers (apt installs + builds them)
#   *.tar.gz  - DKMS source tarballs from GitHub (built via dkms below)
if ls /cdrom/drivers/*.deb /cdrom/drivers/*.tar.gz >/dev/null 2>&1; then
    echo "Installing staged network drivers from /cdrom/drivers ..."
    # DKMS needs the exact running kernel's headers + build tools. The live ISO
    # does not ship them, so this needs network (same as the rest of the recipe).
    apt-get install -y --no-install-recommends dkms build-essential "linux-headers-$(uname -r)" || \
        echo "WARNING: could not install driver build tools; staged drivers skipped."
    for deb in /cdrom/drivers/*.deb; do
        echo "  apt install $(basename "$deb")"
        apt-get install -y "$deb" || echo "WARNING: failed to install $(basename "$deb")"
    done
    for tarball in /cdrom/drivers/*.tar.gz; do
        echo "  dkms build $(basename "$tarball")"
        d="/tmp/drv-$(basename "$tarball" .tar.gz)"
        rm -rf "$d"; mkdir -p "$d"
        tar -xzf "$tarball" -C "$d" --strip-components=1 || { echo "WARNING: bad tarball $tarball"; continue; }
        if [ -x "$d/dkms-install.sh" ]; then
            # Repos with a self-contained installer (e.g. tomaspinho/rtl8821ce)
            # handle their own version substitution.
            ( cd "$d" && bash ./dkms-install.sh ) || echo "WARNING: dkms-install.sh failed for $(basename "$tarball")"
        else
            pkg_name="$(sed -n 's/^PACKAGE_NAME="\?\([^"]*\)"\?/\1/p' "$d/dkms.conf" | head -1)"
            pkg_ver="$(sed -n 's/^PACKAGE_VERSION="\?\([^"]*\)"\?/\1/p' "$d/dkms.conf" | head -1)"
            if [ -z "$pkg_name" ] || [ -z "$pkg_ver" ] || [ "$pkg_ver" = "#MODULE_VERSION#" ]; then
                echo "WARNING: no usable PACKAGE_NAME/PACKAGE_VERSION in $(basename "$tarball") dkms.conf; skipped."
                continue
            fi
            ( cd "$d" && dkms add . && dkms install -m "$pkg_name" -v "$pkg_ver" ) || \
                echo "WARNING: dkms build failed for $(basename "$tarball")"
        fi
    done
    # Load the freshly built modules now so wifi works without a reboot.
    modprobe -a wl 8821ce 8723de 88x2bu 8812au 8814au 8188eu 8723bu 2>/dev/null || true
fi
# Full system upgrade is opt-in (LSL_APT_UPGRADE=1); by default only the
# packages below are installed/upgraded, keeping the base image stable.
if [ "${LSL_APT_UPGRADE:-0}" = "1" ]; then
    apt upgrade -y
fi
# guestmount/guestfish (libguestfs) are heavy and run a RAM-hungry appliance at
# runtime to mount WSL VHDXes. Skip them on low-RAM machines so the first boot
# does not OOM; VHDX mounting is then unavailable (re-run after adding RAM).
GUESTMOUNT_PKGS=""
MEM_KB="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
if [ "${MEM_KB:-0}" -lt 3145728 ] 2>/dev/null; then
    echo "Low RAM (<3 GiB); skipping guestmount/guestfish (WSL VHDX mounting unavailable)."
else
    GUESTMOUNT_PKGS="guestmount guestfish"
fi
# Architecture-aware package set. Flatpak/AppImage/Snap and most "modern" apps are
# x86_64-only, and a 32-bit kernel cannot execute 64-bit binaries at all, so on
# i386 we install a native 32-bit apt set and SKIP the blocks below.
ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
case "$ARCH" in
    i386|i686)
        # Native 32-bit set. Avoid amd64-only packages: nix-bin, steam-installer,
        # kitty (no i386 build), and libfuse2t64 (a 64-bit-time_t package -> use
        # libfuse2 on i386). The browser is installed separately below.
        apt install -y btrfs-progs ${GUESTMOUNT_PKGS} neovim git zenity libhivex-bin chntpw kexec-tools pv tmux libwin-hivex-perl fdisk xxd asciinema fatrace vmtouch libfuse2
        ;;
    *)
        apt install -y btrfs-progs ${GUESTMOUNT_PKGS} neovim nix-bin git steam-installer zenity libhivex-bin chntpw kexec-tools kitty pv tmux libwin-hivex-perl fdisk xxd asciinema fatrace vmtouch libfuse2t64
        ;;
esac

# Enable snap support: Mint ships /etc/apt/preferences.d/nosnap.pref which blocks
# snapd. lsl's Windows installer can preload .snap files onto the USB
# (/cdrom/snaps/), so remove the pin and install snapd to allow offline installs.
# Set LSL_SNAP_SUPPORT=0 to keep Mint's default (no snaps).
if [ "$ARCH" = "amd64" ] && [ "${LSL_SNAP_SUPPORT:-1}" != "0" ]; then
    echo "Enabling snap support (removing Mint's nosnap pin)..."
    rm -f /etc/apt/preferences.d/nosnap.pref
    apt install -y snapd
fi

# Flatpaks are NOT installed here. They install host-side (firstboot's
# install_flatpaks_fat) into the FAT-hosted 'lsl-fat' installation as direct
# files: baking multi-GB apps into this chroot would pack them into the single
# squashfs layer file and hit the FAT32 4 GiB ceiling. The *.flatpakref files
# in /cdrom/flatpaks are only the app LIST for that step.
# --- web browser: everyone gets one ---
# 64-bit: Brave (amd64). 32-bit: Pale Moon non-SSE2 from the antiX repo (supports
# old 32-bit CPUs, incl. pre-SSE2), with fallbacks to firefox-esr / chromium.
if [ "$ARCH" = "amd64" ]; then
    curl -fsS https://dl.brave.com/install.sh | sh
else
    if apt-get install -y palemoon-nonsse2 2>/dev/null; then
        echo "Installed palemoon-nonsse2"
    elif apt-get install -y firefox-esr 2>/dev/null; then
        echo "Installed firefox-esr"
    elif apt-get install -y chromium 2>/dev/null; then
        echo "Installed chromium"
    else
        echo "WARNING: no 32-bit browser available in the configured repos"
    fi
fi

# Latest official nvim AppImage (the noble deb is 0.9.x; the AppImage tracks
# releases). Stored under /cdrom/casper/appimages: that directory is
# bind-mounted to the stick, so it stays writable even on iso-scan boots
# where /cdrom itself is the read-only ISO loop. It persists, and updates
# are just a file swap. A wrapper prefers it over the distro deb.
APPIMG_DIR=/cdrom/casper/appimages
if [ "$ARCH" = "amd64" ] && command -v curl >/dev/null 2>&1; then
    if mkdir -p "$APPIMG_DIR"; then
        curl -fsSL -o "$APPIMG_DIR/nvim.AppImage" \
            https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.appimage \
            || echo "WARNING: nvim AppImage download failed; using distro nvim"
    else
        echo "WARNING: cannot stage $APPIMG_DIR (read-only?); using distro nvim"
    fi
    # Verify it is a real ELF (the GitHub API publishes no checksum; magic bytes
    # catch truncated/corrupt downloads - same check as lsl-appimages.sh).
    if [ -s "$APPIMG_DIR/nvim.AppImage" ] && \
       [ "$(head -c 4 "$APPIMG_DIR/nvim.AppImage" | od -An -tx1 | tr -d ' \n')" = "7f454c46" ]; then
        chmod +x "$APPIMG_DIR/nvim.AppImage"
        cat > /usr/local/bin/nvim <<'NVIMEOF'
#!/bin/bash
# Prefer the official nvim AppImage (latest) over the distro deb.
if [ -x /cdrom/casper/appimages/nvim.AppImage ]; then
    if [ -e /dev/fuse ]; then
        exec /cdrom/casper/appimages/nvim.AppImage "$@"
    fi
    exec /cdrom/casper/appimages/nvim.AppImage --appimage-extract-and-run "$@"
fi
exec /usr/bin/nvim "$@"
NVIMEOF
        chmod +x /usr/local/bin/nvim
    else
        echo "WARNING: no usable nvim AppImage in $APPIMG_DIR; using distro nvim"
    fi
fi

# Optional curated AppImages (e.g. LSL_APPIMAGES="rustdesk keepassxc").
# Downloads land on /cdrom/casper/appimages (stick, writable) and persist across boots.
if [ "$ARCH" = "amd64" ] && [ -n "${LSL_APPIMAGES:-}" ]; then
    echo "Downloading requested AppImages: $LSL_APPIMAGES"
    bash /cdrom/bin/lsl-appimages.sh $LSL_APPIMAGES || true
fi

# Optional statically-linked CLI tools (e.g. LSL_RUSTTOOLS="rg fd bat").
# Installed to /cdrom/bin (on PATH) and persist on the FAT partition.
if [ "$ARCH" = "amd64" ] && [ -n "${LSL_RUSTTOOLS:-}" ]; then
    echo "Installing requested CLI tools: $LSL_RUSTTOOLS"
    bash /cdrom/bin/lsl-rusttools.sh $LSL_RUSTTOOLS || true
fi
