#!/bin/bash
# Persist the currently connected Wi-Fi to /cdrom/wifi.sh so the next boot can reconnect
# (onboot.sh runs /cdrom/wifi.sh). Used by lsl-shutdown-gui and kexec-reboot.
set -u

if [ "${EUID:-0}" -ne 0 ]; then
    exec sudo -- "$0" "$@"
fi

mountpoint -q /cdrom 2>/dev/null || exit 0
if ! command -v nmcli >/dev/null 2>&1; then
    exit 0
fi

mount /cdrom -o remount,rw 2>/dev/null || exit 0

dev=""
dev="$(nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null | awk -F: '$2=="wifi" && $3 ~ /^connected/{print $1; exit}')"
[ -n "$dev" ] || exit 0

conn=""
conn="$(nmcli -g GENERAL.CONNECTION device show "$dev" 2>/dev/null | head -n1)"
[ -n "$conn" ] || exit 0

ssid=""
ssid="$(nmcli -g 802-11-wireless.ssid connection show "$conn" 2>/dev/null | head -n1)"
[ -n "$ssid" ] || exit 0

psk=""
psk="$(nmcli -s -g 802-11-wireless-security.psk connection show "$conn" 2>/dev/null | head -n1 || true)"

{
    echo "#!/bin/bash"
    echo "# Persisted Wi-Fi boot script (persist-wifi.sh)"
    if [ -n "$psk" ]; then
        printf "nmcli device wifi connect %q password %q\n" "$ssid" "$psk"
    else
        printf "nmcli device wifi connect %q\n" "$ssid"
    fi
} >/cdrom/wifi.sh

chmod +x /cdrom/wifi.sh
sync
mount /cdrom -o remount,ro 2>/dev/null || true
