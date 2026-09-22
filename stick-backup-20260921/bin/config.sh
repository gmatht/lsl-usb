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
#
# HARD GUARD: `cp -a X X` does not just fail - it TRUNCATES X and then exits 1
# (coreutils 9.4). On 2026-09-21 that ran on the live stick (REPO_ROOT ==
# CDROM == /cdrom) and zeroed /cdrom/onboot.sh, lsl-usb.env,
# fuse/fat_linux_meta_fs.py, fuse/requirements.txt and overwrote every
# systemd/*.service, because --systemd-only skips sync_cdrom and lands here
# directly. Never let cp see a self-copy again.
cp_to_cdrom() {
    local src dst real_src real_dst
    src="$1"; dst="${@: -1}"
    real_src="$(readlink -f -- "$src" 2>/dev/null || echo "$src")"
    real_dst="$(readlink -f -- "$dst" 2>/dev/null || echo "$dst")"
    if [[ "$real_src" == "$real_dst" ]]; then
        echo "config.sh: refusing to copy $src onto itself" >&2
        return 0
    fi
    # Same directory (the in-boot repo==stick layout): every source is already
    # in place, so the whole sync is a no-op.
    if [[ "$(dirname -- "$real_src")" == "$(dirname -- "$real_dst")" ]] && \
       [[ "$(basename -- "$real_src")" == "$(basename -- "$real_dst")" ]]; then
        return 0
    fi
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
    # Guard against the copy-onto-itself trap: when config.sh is run from the
    # stick (REPO_ROOT == CDROM == /cdrom, the normal in-boot layout) every
    # `cp X X` prints "are the same file" and EXITS 1 (tested on coreutils
    # 9.4), which under `set -e` aborts config.sh right there - skipping the
    # desktop shortcuts and, worse, install_systemd_units(). That is exactly
    # how onboot.service went missing (WHYFAIL3/5/6). Nothing to sync anyway
    # when source and destination are the same tree.
    if [[ "$(readlink -f -- "$REPO_ROOT" 2>/dev/null || echo "$REPO_ROOT")" == \
          "$(readlink -f -- "$CDROM" 2>/dev/null || echo "$CDROM")" ]]; then
        echo "config.sh: $CDROM is the repo root; nothing to sync" >&2
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

    # FAT has no exec bits, so every script gate on the stick must use -r and
    # invoke via bash (see the -r comments in lsl-firstboot.sh). Fix up the
    # synced copies so the stick tree matches that convention.
    local b
    for b in config.sh lsl-common.sh squashfs_config.sh uproot; do
        [[ -f "$CDROM/bin/$b" ]] && chmod 755 "$CDROM/bin/$b" 2>/dev/null || true
    done
}

install_desktop_shortcuts() {
    # $1 = force: install even when this invocation is not syncing the repo
    # (see install_desktop_shortcuts_from_onboot). Default 0 keeps the
    # historical behavior for --systemd-only / --sync-only scratch runs.
    local force="${1:-0}"
    if [[ "$SYNC" -eq 0 && "$force" -ne 1 ]]; then
        return 0
    fi
    if ! mkdir -p /home/$LSL_DESKTOP_USER/Desktop 2>/dev/null; then
        # No writable home (e.g. --sync-only against a scratch dir): the
        # desktop shortcuts cannot be installed - skip them, not the sync.
        return 0
    fi
    chown $LSL_DESKTOP_USER:$LSL_DESKTOP_USER /home/$LSL_DESKTOP_USER/Desktop 2>/dev/null || true

    # FAT has no exec bit (fmask=0022), so `Exec=/cdrom/bin/X` can NEVER work -
    # Cinnamon reports "There was an error launching the application" (EACCES)
    # even when the file exists. Every other /cdrom caller in this tree invokes
    # scripts as `bash /cdrom/...`; the desktop entries must do the same.
    # Also do not advertise entries for programs that are not actually staged
    # (the stick's bin/ is only partial - lsl-gui was missing for months; see
    # WHYFAIL5.md "Follow-up 2").
    local lsl_gui_entry="" lsl_shutdown_entry=""
    if [[ -r /cdrom/bin/lsl-gui ]]; then
        lsl_gui_entry=$(cat <<'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=lsl-gui
Comment=Launch WSL Distribution (GUI)
Exec=bash /cdrom/bin/lsl-gui
Icon=terminal
Terminal=false
Categories=System;Utility;
EOF
)
    else
        echo "config.sh: /cdrom/bin/lsl-gui not staged; skipping that desktop entry" >&2
    fi
    if [[ -r /cdrom/bin/lsl-shutdown-gui ]]; then
        lsl_shutdown_entry=$(cat <<'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=lsl-shutdown
Comment=Save home snapshot and shut down
Exec=bash /cdrom/bin/lsl-shutdown-gui
Icon=system-shutdown
Terminal=false
Categories=System;Utility;
EOF
)
    else
        echo "config.sh: /cdrom/bin/lsl-shutdown-gui not staged; skipping that desktop entry" >&2
    fi

    if [[ -n "$lsl_gui_entry" ]]; then
        printf '%s\n' "$lsl_gui_entry" >/home/$LSL_DESKTOP_USER/Desktop/lsl-gui.desktop
        chmod +x /home/$LSL_DESKTOP_USER/Desktop/lsl-gui.desktop
        chown $LSL_DESKTOP_USER:$LSL_DESKTOP_USER /home/$LSL_DESKTOP_USER/Desktop/lsl-gui.desktop
    fi
    if [[ -n "$lsl_shutdown_entry" ]]; then
        printf '%s\n' "$lsl_shutdown_entry" >/home/$LSL_DESKTOP_USER/Desktop/lsl-shutdown.desktop
        chmod +x /home/$LSL_DESKTOP_USER/Desktop/lsl-shutdown.desktop
        chown $LSL_DESKTOP_USER:$LSL_DESKTOP_USER /home/$LSL_DESKTOP_USER/Desktop/lsl-shutdown.desktop
    fi

    if command -v brave-browser >/dev/null 2>&1 || command -v brave-browser-stable >/dev/null 2>&1; then
        cat <<'EOF' >/home/$LSL_DESKTOP_USER/Desktop/brave-browser.desktop
[Desktop Entry]
Version=1.0
Type=Application
Name=Brave Web Browser
Comment=Access the Internet
Exec=/usr/bin/brave-browser-stable %U
Icon=brave-browser
Terminal=false
Categories=Network;WebBrowser;
EOF
        chmod +x /home/$LSL_DESKTOP_USER/Desktop/brave-browser.desktop
        chown $LSL_DESKTOP_USER:$LSL_DESKTOP_USER /home/$LSL_DESKTOP_USER/Desktop/brave-browser.desktop
    fi
}

# The desktop shortcuts (lsl-gui, lsl-shutdown, brave) are filesystem work that
# needs /home - NOT a repo sync. `--from-onboot` runs config.sh very early on
# every boot, when /home may still be the RAM overlay (the persistent /home
# flush/mount happens later in onboot.sh), so it deliberately skips the sync.
# But gating the shortcuts on SYNC=1 as well meant the ONLY in-boot caller ran
# with SYNC=0 and the icons were never installed at all on the live stick -
# /home/ubuntu/Desktop stayed empty while the repo copy installed them fine.
# Retry in the background until /home is writable so the icons appear on the
# boot where /home becomes persistent, without changing the boot order.
install_desktop_shortcuts_from_onboot() {
    (
        local i=0
        while [ "$i" -lt 180 ]; do
            if mkdir -p "/home/$LSL_DESKTOP_USER/Desktop" 2>/dev/null; then
                install_desktop_shortcuts 1
                exit 0
            fi
            sleep 5
            i=$((i + 1))
        done
        echo "config.sh: /home/$LSL_DESKTOP_USER never became writable; desktop shortcuts not installed" >&2
    ) &
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
    # Gate on the source file: the FAT stick's misc/ is populated by sync_cdrom
    # from the repo, and on a stick built without misc/kitty.conf (or with an
    # empty misc/) a bare `cp` fails under `set -e` and ABORTS config.sh -
    # skipping every later step (systemd units, desktop shortcuts). Same class
    # of bug as the -x gates elsewhere on FAT: only run the copy when the
    # source is actually there.
    if [[ ! -r "$REPO_ROOT/misc/kitty.conf" ]]; then
        echo "config.sh: no $REPO_ROOT/misc/kitty.conf; skipping kitty config" >&2
        return 0
    fi
    cp -a --no-preserve=ownership "$REPO_ROOT/misc/kitty.conf" "$kitty_dir/kitty.conf"
    chown $LSL_DESKTOP_USER:$LSL_DESKTOP_USER "$kitty_dir/kitty.conf" 2>/dev/null || true
}

install_lsl_terminal_autostart() {
    # The desktop/panel is expected to look like Windows Terminal out of the box:
    # a terminal pinned to the panel. Pinning is done by bin/lsl-pin-favorites
    # (which now prefers kitty, because kitty is what the base image actually
    # ships); this only guarantees the terminal itself is installed/pinned.
    #
    # NOTE: there used to be a second, separate `lsl-wezterm.desktop` autostart
    # entry that ran the SAME script (pin-favorites) as
    # install_lsl_pin_favorites_autostart - two entries, one action. Removed:
    # one entry is enough, and it also removes a stale `lsl-wezterm.desktop`
    # left behind on existing installs (see cleanup below).
    local mint_home
    if [[ -n "$CFG_ROOT" ]]; then
        mint_home="${CFG_ROOT}/home/$LSL_DESKTOP_USER"
    else
        mint_home="/home/$LSL_DESKTOP_USER"
    fi
    [[ -d "$mint_home" ]] || return 0

    # Drop the legacy duplicate from earlier builds (idempotent).
    rm -f "$mint_home/.config/autostart/lsl-wezterm.desktop" 2>/dev/null || true

    mkdir -p "$mint_home/.config/autostart"
    chown $LSL_DESKTOP_USER:$LSL_DESKTOP_USER "$mint_home/.config" "$mint_home/.config/autostart" 2>/dev/null || true

    cat <<'EOF' >"$mint_home/.config/autostart/lsl-terminal-pin.desktop"
[Desktop Entry]
Type=Application
Name=LSL terminal pin
Comment=Pin the terminal (kitty, else wezterm) to Cinnamon favorites/panel
Exec=/cdrom/bin/lsl-pin-favorites
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF
    chmod +x "$mint_home/.config/autostart/lsl-terminal-pin.desktop"
    chown $LSL_DESKTOP_USER:$LSL_DESKTOP_USER "$mint_home/.config/autostart/lsl-terminal-pin.desktop"
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
Comment=Pin the terminal (kitty, else wezterm) and Brave to Cinnamon favorites/panel
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

    local systemctl_cmd
    if [[ -n "$CFG_ROOT" ]]; then
        systemctl_cmd="chroot $CFG_ROOT systemctl"
    elif [[ "$(id -u)" -eq 0 ]]; then
        systemctl_cmd="systemctl"
    else
        echo "config.sh: systemd install skipped (need root or LSL_CONFIG_ROOT + chroot)" >&2
        return 0
    fi

    # daemon-reload may fail in a chroot without a running systemd;
    # the enable symlinks are still created, so do not fail the script.
    $systemctl_cmd daemon-reload 2>/dev/null || true
    $systemctl_cmd enable onboot.service lsl-home-flushd.service lsl-btrfs-growd.service lsl-precache.service lsl-boot-stamp.service lsl-reclaim-win-swap.service 2>/dev/null || true
    if [[ -z "$CFG_ROOT" ]]; then
        $systemctl_cmd enable lsl-win-backup.timer 2>/dev/null || true
    fi
}

if [[ "$AUTOSTART_WARN_ONLY" -eq 1 ]]; then
    install_lsl_autostart_warning
    exit 0
fi

# --from-onboot: /home may not be persistent yet (onboot.sh mounts/flushes it
# later in the same boot), so retry the icon install in the background.
if [[ "$SKIP_AUTOSTART_WARN" -eq 1 ]]; then
    install_desktop_shortcuts_from_onboot
fi

sync_cdrom
if [[ "$SKIP_AUTOSTART_WARN" -eq 0 ]]; then
    install_desktop_shortcuts
    install_lsl_autostart_warning
    install_lsl_terminal_autostart
    install_lsl_pin_favorites_autostart
    install_lsl_kitty_conf
fi
install_systemd_units
