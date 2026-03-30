#!/bin/bash
# Persist currently connected Wi-Fi and maintain a small command history on HDD.
# Syncs history to /cdrom/wifi.sh so future boots can reconnect.
set -u

if [ "${EUID:-0}" -ne 0 ]; then
    exec sudo -- "$0" "$@"
fi

mountpoint -q /cdrom 2>/dev/null || exit 0

STATE_DIR="/home/mint/.local/state/lsl"
STATE_WIFI_FILE="${STATE_DIR}/wifi.history.sh"
CDROM_WIFI_FILE="/cdrom/wifi.sh"

mkdir -p "$STATE_DIR" 2>/dev/null || true

append_unique_line() {
    local file="$1"
    local line="$2"
    [ -n "$line" ] || return 0
    touch "$file" 2>/dev/null || return 0
    if ! grep -Fqx "$line" "$file" 2>/dev/null; then
        printf "%s\n" "$line" >>"$file"
    fi
}

collect_current_wifi_line() {
    command -v nmcli >/dev/null 2>&1 || return 1
    local dev conn ssid psk
    dev="$(nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null | awk -F: '$2=="wifi" && $3 ~ /^connected/{print $1; exit}')"
    [ -n "$dev" ] || return 1
    conn="$(nmcli -g GENERAL.CONNECTION device show "$dev" 2>/dev/null | sed -n '1p')"
    [ -n "$conn" ] || return 1
    ssid="$(nmcli -g 802-11-wireless.ssid connection show "$conn" 2>/dev/null | sed -n '1p')"
    [ -n "$ssid" ] || return 1
    psk="$(nmcli -s -g 802-11-wireless-security.psk connection show "$conn" 2>/dev/null | sed -n '1p' || true)"
    if [ -n "$psk" ]; then
        printf "nmcli device wifi connect %q password %q\n" "$ssid" "$psk"
    else
        printf "nmcli device wifi connect %q\n" "$ssid"
    fi
    return 0
}

sync_state_to_cdrom() {
    local tmp line
    mount /cdrom -o remount,rw 2>/dev/null || return 0
    tmp="$(mktemp)"
    {
        echo "#!/bin/bash"
        echo "# Persisted Wi-Fi boot script (persist-wifi.sh)"
        [ -f "$CDROM_WIFI_FILE" ] && awk '/^nmcli device wifi connect / {print}' "$CDROM_WIFI_FILE"
        [ -f "$STATE_WIFI_FILE" ] && awk '/^nmcli device wifi connect / {print}' "$STATE_WIFI_FILE"
    } | awk '!seen[$0]++' >"$tmp"
    mv "$tmp" "$CDROM_WIFI_FILE"
    chmod +x "$CDROM_WIFI_FILE" 2>/dev/null || true
    sync
    mount /cdrom -o remount,ro 2>/dev/null || true
}

wifi_line="$(collect_current_wifi_line || true)"
[ -n "${wifi_line:-}" ] && append_unique_line "$STATE_WIFI_FILE" "$wifi_line"
sync_state_to_cdrom
