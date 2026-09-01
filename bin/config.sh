#!/usr/bin/env bash
# Sync LSL scripts to the USB root and install systemd units. Safe to re-run.
# Usage:
#   sudo ./bin/config.sh              # sync to /cdrom + systemd on this system
#   sudo ./bin/config.sh --sync-only
#   sudo ./bin/config.sh --systemd-only
#   sudo LSL_CONFIG_ROOT=/tmp/squashfs/root ./bin/config.sh --systemd-only   # install.sh
# Env:
#   LSL_CDROM        USB mount (default: /cdrom)
#   LSL_CONFIG_ROOT  Prefix for etc (e.g. chroot); empty = real /
set -euo pipefail

mount /cdrom -o rw,remount 2>/dev/null || echo "config.sh: warning: could not remount /cdrom read-write." >&2

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lsl-common.sh"
LSL_DESKTOP_USER="$(lsl_desktop_user)"
CDROM="${LSL_CDROM:-/cdrom}"
CFG_ROOT="${LSL_CONFIG_ROOT:-}"

SYNC=1
SYSTEMD=1
SKIP_AUTOSTART_WARN=0
AUTOSTART_WARN_ONLY=0

usage() {
    echo "Usage: $0 [--sync-only | --systemd-only | --from-onboot | --install-autostart-warning-only]" >&2
    exit 1
}

# USB root is often FAT/exFAT: ownership (and sometimes mode) cannot be stored; plain cp -a spams EPERM.
cp_to_cdrom() {
    cp -a --no-preserve=ownership "$@"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sync-only) SYSTEMD=0 ;;
        --systemd-only) SYNC=0 ;;
        --from-onboot) SYNC=0; SKIP_AUTOSTART_WARN=1 ;;
        --install-autostart-warning-only) SYNC=0; SYSTEMD=0; AUTOSTART_WARN_ONLY=1 ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
    shift
done

sync_cdrom() {
    if [[ "$SYNC" -eq 0 ]]; then
        return 0
    fi
    if [[ ! -d "$CDROM" ]]; then
        echo "config.sh: $CDROM not found; skip sync" >&2
        return 0
    fi
    mkdir -p "$CDROM/bin" "$CDROM/systemd" "$CDROM/misc" "$CDROM/fuse"
    cp_to_cdrom "$REPO_ROOT/bin/"* "$CDROM/bin/"
    cp_to_cdrom "$REPO_ROOT/onboot.sh" "$CDROM/"
    cp_to_cdrom "$REPO_ROOT/lsl-usb.env" "$CDROM/lsl-usb.env"
    if [[ -f "$REPO_ROOT/misc/.wezterm.lua" ]]; then
        cp_to_cdrom "$REPO_ROOT/misc/.wezterm.lua" "$CDROM/misc/.wezterm.lua"
    fi
    shopt -s nullglob
    cp_to_cdrom "$REPO_ROOT/systemd/"*.service "$CDROM/systemd/"
    shopt -u nullglob
    cp_to_cdrom "$REPO_ROOT/fuse/fat_linux_meta_fs.py" "$CDROM/fuse/fat_linux_meta_fs.py"
    cp_to_cdrom "$REPO_ROOT/fuse/requirements.txt" "$CDROM/fuse/requirements.txt"

    if [[ -x "$REPO_ROOT/bin/persist-wifi.sh" ]]; then
        "$REPO_ROOT/bin/persist-wifi.sh" || true
    fi
}

install_desktop_shortcuts() {
    if [[ "$SYNC" -eq 0 ]]; then
        return 0
    fi
    if [[ ! -d /home/$LSL_DESKTOP_USER/Desktop ]]; then
        return 0
    fi
    mkdir -p /home/$LSL_DESKTOP_USER/Desktop
    chown $LSL_DESKTOP_USER:$LSL_DESKTOP_USER /home/$LSL_DESKTOP_USER/Desktop 2>/dev/null || true

    cat <<'EOF' >/home/$LSL_DESKTOP_USER/Desktop/lsl-gui.desktop
[Desktop Entry]
Version=1.0
Type=Application
Name=lsl-gui
Comment=Launch WSL Distribution (GUI)
Exec=/cdrom/bin/lsl-gui
Icon=terminal
Terminal=false
Categories=System;Utility;
EOF
    chmod +x /home/$LSL_DESKTOP_USER/Desktop/lsl-gui.desktop
    chown $LSL_DESKTOP_USER:$LSL_DESKTOP_USER /home/$LSL_DESKTOP_USER/Desktop/lsl-gui.desktop

    cat <<'EOF' >/home/$LSL_DESKTOP_USER/Desktop/lsl-shutdown.desktop
[Desktop Entry]
Version=1.0
Type=Application
Name=lsl-shutdown
Comment=Save home snapshot and shut down
Exec=/cdrom/bin/lsl-shutdown-gui
Icon=system-shutdown
Terminal=false
Categories=System;Utility;
EOF
    chmod +x /home/$LSL_DESKTOP_USER/Desktop/lsl-shutdown.desktop
    chown $LSL_DESKTOP_USER:$LSL_DESKTOP_USER /home/$LSL_DESKTOP_USER/Desktop/lsl-shutdown.desktop
}

# Runs even when SYNC=0 (--from-onboot) so login warning is installed after /home exists.
install_lsl_autostart_warning() {
    local mint_home
    if [[ -n "$CFG_ROOT" ]]; then
        mint_home="${CFG_ROOT}/home/$LSL_DESKTOP_USER"
    else
        mint_home="/home/$LSL_DESKTOP_USER"
    fi
    if [[ ! -d "$mint_home" ]]; then
        return 0
    fi
    mkdir -p "$mint_home/.config/autostart"
    chown $LSL_DESKTOP_USER:$LSL_DESKTOP_USER "$mint_home/.config" "$mint_home/.config/autostart" 2>/dev/null || true

    cat <<'EOF' >"$mint_home/.config/autostart/lsl-home-readonly-warning.desktop"
[Desktop Entry]
Type=Application
Name=LSL home read-only warning
Comment=Notify if /home is mounted read-only (e.g. NTFS dirty flag)
Exec=/cdrom/bin/lsl-home-readonly-warning
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF
    chmod +x "$mint_home/.config/autostart/lsl-home-readonly-warning.desktop"
    chown $LSL_DESKTOP_USER:$LSL_DESKTOP_USER "$mint_home/.config/autostart/lsl-home-readonly-warning.desktop"
}


install_lsl_kitty_conf() {
    # Ship a Windows-Terminal-like kitty config so the default terminal matches
    # what users expect from Windows. Installed into the desktop user's config.
    local mint_home kitty_dir
    if [[ -n "$CFG_ROOT" ]]; then
        mint_home="${CFG_ROOT}/home/$LSL_DESKTOP_USER"
    else
        mint_home="/home/$LSL_DESKTOP_USER"
    fi
    [[ -d "$mint_home" ]] || return 0
    kitty_dir="$mint_home/.config/kitty"
    mkdir -p "$kitty_dir"
    chown $LSL_DESKTOP_USER:$LSL_DESKTOP_USER "$mint_home/.config" "$kitty_dir" 2>/dev/null || true
    cp -a --no-preserve=ownership "$REPO_ROOT/misc/kitty.conf" "$kitty_dir/kitty.conf"
    chown $LSL_DESKTOP_USER:$LSL_DESKTOP_USER "$kitty_dir/kitty.conf" 2>/dev/null || true
}

install_lsl_wezterm_autostart() {
    # Pin WezTerm to the desktop/panel and add it to autostart so the terminal
    # opens on first login (mirrors the Windows Terminal expectation). The actual
    # favorites pinning is done by bin/lsl-pin-favorites; here we just ensure the
    # WezTerm autostart entry exists for the desktop user.
    local mint_home
    if [[ -n "$CFG_ROOT" ]]; then
        mint_home="${CFG_ROOT}/home/$LSL_DESKTOP_USER"
    else
        mint_home="/home/$LSL_DESKTOP_USER"
    fi
    [[ -d "$mint_home" ]] || return 0
    mkdir -p "$mint_home/.config/autostart"
    chown $LSL_DESKTOP_USER:$LSL_DESKTOP_USER "$mint_home/.config" "$mint_home/.config/autostart" 2>/dev/null || true

    cat <<'EOF' >"$mint_home/.config/autostart/lsl-wezterm.desktop"
[Desktop Entry]
Type=Application
Name=LSL WezTerm
Comment=Open a terminal on first login (Windows-Terminal-like)
Exec=/cdrom/bin/lsl-pin-favorites
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF
    chmod +x "$mint_home/.config/autostart/lsl-wezterm.desktop"
    chown $LSL_DESKTOP_USER:$LSL_DESKTOP_USER "$mint_home/.config/autostart/lsl-wezterm.desktop"
}

install_lsl_pin_favorites_autostart() {
    local mint_home
    if [[ -n "$CFG_ROOT" ]]; then
        mint_home="${CFG_ROOT}/home/$LSL_DESKTOP_USER"
    else
        mint_home="/home/$LSL_DESKTOP_USER"
    fi
    if [[ ! -d "$mint_home" ]]; then
        return 0
    fi
    mkdir -p "$mint_home/.config/autostart"
    chown $LSL_DESKTOP_USER:$LSL_DESKTOP_USER "$mint_home/.config" "$mint_home/.config/autostart" 2>/dev/null || true

    cat <<'EOF' >"$mint_home/.config/autostart/lsl-pin-favorites.desktop"
[Desktop Entry]
Type=Application
Name=LSL pin favorites
Comment=Pin WezTerm and Brave to Cinnamon favorites/panel
Exec=/cdrom/bin/lsl-pin-favorites
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF
    chmod +x "$mint_home/.config/autostart/lsl-pin-favorites.desktop"
    chown $LSL_DESKTOP_USER:$LSL_DESKTOP_USER "$mint_home/.config/autostart/lsl-pin-favorites.desktop"
}

ensure_cdrom_path_in_bashrc() {
    local bashrc
    if [[ -n "$CFG_ROOT" ]]; then
        bashrc="${CFG_ROOT}/etc/bash.bashrc"
    else
        bashrc="/etc/bash.bashrc"
    fi
    [[ -f "$bashrc" ]] || return 0
    if ! grep -q '/cdrom/bin' "$bashrc"; then
        echo 'export PATH="/cdrom/bin:$PATH"' >>"$bashrc"
    fi
}

install_systemd_units() {
    if [[ "$SYSTEMD" -eq 0 ]]; then
        return 0
    fi
    local sysdir
    if [[ -n "$CFG_ROOT" ]]; then
        sysdir="${CFG_ROOT}/etc/systemd/system"
    else
        sysdir="/etc/systemd/system"
    fi
    mkdir -p "$sysdir"
    if [[ ! -d "$REPO_ROOT/systemd" ]]; then
        echo "config.sh: missing $REPO_ROOT/systemd (sync repo to $CDROM first?)" >&2
        return 1
    fi
    shopt -s nullglob
    local f found=0
    for f in "$REPO_ROOT/systemd/"*.service "$REPO_ROOT/systemd/"*.timer; do
        cp -a "$f" "$sysdir/"
        found=1
    done
    shopt -u nullglob
    if [[ "$found" -eq 0 ]]; then
        echo "config.sh: no *.service in $REPO_ROOT/systemd" >&2
        return 1
    fi

    ensure_cdrom_path_in_bashrc

    if [[ -n "$CFG_ROOT" ]]; then
        chroot "$CFG_ROOT" systemctl daemon-reload
        chroot "$CFG_ROOT" systemctl enable onboot.service lsl-home-flushd.service lsl-btrfs-growd.service lsl-precache.service lsl-boot-stamp.service lsl-reclaim-win-swap.service
    elif [[ "$(id -u)" -eq 0 ]]; then
        systemctl daemon-reload
        systemctl enable onboot.service lsl-home-flushd.service lsl-btrfs-growd.service lsl-precache.service lsl-boot-stamp.service lsl-win-backup.timer lsl-reclaim-win-swap.service
    else
        echo "config.sh: systemd install skipped (need root or LSL_CONFIG_ROOT + chroot)" >&2
    fi
}

if [[ "$AUTOSTART_WARN_ONLY" -eq 1 ]]; then
    install_lsl_autostart_warning
    exit 0
fi

sync_cdrom
install_desktop_shortcuts
if [[ "$SKIP_AUTOSTART_WARN" -eq 0 ]]; then
    install_lsl_autostart_warning
    install_lsl_wezterm_autostart
    install_lsl_pin_favorites_autostart
    install_lsl_kitty_conf
fi
install_systemd_units
