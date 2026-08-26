#!/bin/bash

set -eo pipefail

apt update
# Full system upgrade is opt-in (LSL_APT_UPGRADE=1); by default only the
# packages below are installed/upgraded, keeping the base image stable.
if [ "${LSL_APT_UPGRADE:-0}" = "1" ]; then
    apt upgrade -y
fi
apt install -y btrfs-progs guestmount neovim nix-bin git steam-installer zenity libhivex-bin chntpw guestfish kexec-tools kitty pv tmux libwin-hivex-perl fdisk xxd asciinema fatrace vmtouch libfuse2t64

# Enable snap support: Mint ships /etc/apt/preferences.d/nosnap.pref which blocks
# snapd. lsl's Windows installer can preload .snap files onto the USB
# (/cdrom/snaps/), so remove the pin and install snapd to allow offline installs.
# Set LSL_SNAP_SUPPORT=0 to keep Mint's default (no snaps).
if [ "${LSL_SNAP_SUPPORT:-1}" != "0" ]; then
    echo "Enabling snap support (removing Mint's nosnap pin)..."
    rm -f /etc/apt/preferences.d/nosnap.pref
    apt install -y snapd
fi

# Install flatpak refs preloaded by the Windows installer (apps the user has
# on Windows). Runs in the chroot so the installs land in the persisted layer.
if ls /cdrom/flatpaks/*.flatpakref >/dev/null 2>&1; then
    echo "Installing preloaded flatpaks..."
    flatpak remote-list --system 2>/dev/null | grep -q flathub || \
        flatpak remote-add --system flathub https://flathub.org/repo/flathub.flatpakrepo || true
    for ref in /cdrom/flatpaks/*.flatpakref; do
        echo "  flatpak install --from $(basename "$ref")"
        flatpak install --system --noninteractive --from "$ref" || true
    done
fi
#curl -fsS https://dl.brave.com/install.sh | sh
#Install modern a browser
# Might be better to install in a WSL vhdx?
curl -fsS https://dl.brave.com/install.sh | sh

# Latest official nvim AppImage (the noble deb is 0.9.x; the AppImage tracks
# releases). Stored on the FAT partition: it persists, and updates are just a
# file swap. A wrapper prefers it over the distro deb.
if command -v curl >/dev/null 2>&1; then
    mkdir -p /cdrom/appimages
    curl -fsSL -o /cdrom/appimages/nvim.AppImage \
        https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.appimage || true
    # Verify it is a real ELF (the GitHub API publishes no checksum; magic bytes
    # catch truncated/corrupt downloads - same check as lsl-appimages.sh).
    if [ -s /cdrom/appimages/nvim.AppImage ] && \
       [ "$(head -c 4 /cdrom/appimages/nvim.AppImage | od -An -tx1 | tr -d ' \n')" = "7f454c46" ]; then
        chmod +x /cdrom/appimages/nvim.AppImage
        cat > /usr/local/bin/nvim <<'NVIMEOF'
#!/bin/bash
# Prefer the official nvim AppImage (latest) over the distro deb.
if [ -x /cdrom/appimages/nvim.AppImage ]; then
    if [ -e /dev/fuse ]; then
        exec /cdrom/appimages/nvim.AppImage "$@"
    fi
    exec /cdrom/appimages/nvim.AppImage --appimage-extract-and-run "$@"
fi
exec /usr/bin/nvim "$@"
NVIMEOF
        chmod +x /usr/local/bin/nvim
    fi
fi

# Optional curated AppImages (e.g. LSL_APPIMAGES="rustdesk keepassxc").
# Downloads land on /cdrom/appimages (FAT) and persist across boots.
if [ -n "${LSL_APPIMAGES:-}" ]; then
    echo "Downloading requested AppImages: $LSL_APPIMAGES"
    bash /cdrom/bin/lsl-appimages.sh $LSL_APPIMAGES || true
fi

# Optional statically-linked CLI tools (e.g. LSL_RUSTTOOLS="rg fd bat").
# Installed to /cdrom/bin (on PATH) and persist on the FAT partition.
if [ -n "${LSL_RUSTTOOLS:-}" ]; then
    echo "Installing requested CLI tools: $LSL_RUSTTOOLS"
    bash /cdrom/bin/lsl-rusttools.sh $LSL_RUSTTOOLS || true
fi
