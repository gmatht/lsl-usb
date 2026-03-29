#!/usr/bin/env bash
# Remove legacy hooks that write to /cdrom/bash.log (fails with "Permission denied"
# when /cdrom is read-only or in HDD mode). Safe to re-run; requires root for /etc.
set -u

strip_lines_matching_cdrom_bash_log() {
    local f=$1
    [[ -f "$f" ]] || return 0
    if grep -qE 'cdrom/bash\.log' "$f" 2>/dev/null; then
        sed -i '\|cdrom/bash\.log|d' "$f"
    fi
}

clean_bash_bashrc_legacy_lsl_hook() {
    local f=/etc/bash.bashrc
    [[ -f "$f" ]] || return 0
    # Old LSL block that logged to /cdrom directly (no /run/lsl-bash-log.path).
    if grep -q "LSL_BASH_LOG_HOOK" "$f" 2>/dev/null && ! grep -q "lsl-bash-log.path" "$f" 2>/dev/null; then
        sed -i '/# LSL_BASH_LOG_HOOK/,/^esac$/d' "$f"
    fi
    strip_lines_matching_cdrom_bash_log "$f"
}

clean_bash_bashrc_legacy_lsl_hook

strip_lines_matching_cdrom_bash_log /etc/profile
shopt -s nullglob
for f in /etc/profile.d/*.sh; do
    strip_lines_matching_cdrom_bash_log "$f"
done
shopt -u nullglob
