#!/bin/bash
# fetch-flatpaks.sh - builder-side flatpak fetch (runs in WSL/Ubuntu).
# Downloads the app IDs staged as <stick>/flatpaks/*.flatpakref (or given as
# args) over the FAST builder network and exports an offline sideload repo to
# <stick>/flatpaks/usb (archive-mode ostree: small FAT-safe files, no symlinks,
# no >4GB files). First boot installs from that repo with NO network, straight
# into the FAT-hosted 'lsl-fat' installation - nothing is ever baked into the
# squashfs layer, so the FAT32 4 GiB single-file ceiling cannot be hit.
#
# Usage: ./misc/fetch-flatpaks.sh [STICK] [APPID...]
#   STICK defaults to /mnt/d (re-mount with `wsl -u root mount -t drvfs D: /mnt/d`
#   if the letter vanished). With no APPIDs, every *.flatpakref basename is used.
# Requires (in WSL): flatpak (apt install flatpak). Needs no systemd (--user).
set -euo pipefail

STICK="${1:-/mnt/d}"
if [ -n "${2:-}" ]; then
    shift
    IDS=("$@")
else
    IDS=()
    for ref in "$STICK"/flatpaks/*.flatpakref; do
        [ -e "$ref" ] || continue
        IDS+=("$(basename "$ref" .flatpakref)")
    done
fi
[ "${#IDS[@]}" -gt 0 ] || { echo "no app IDs (no $STICK/flatpaks/*.flatpakref and none given)" >&2; exit 1; }
echo "fetching: ${IDS[*]}"

flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
# P2P/USB export requires a collection ID on the remote.
flatpak remote-modify --user --collection-id=org.flathub.Stable flathub
flatpak install --user -y flathub "${IDS[@]}"

OUT="$STICK/flatpaks/usb"
rm -rf "$OUT"
mkdir -p "$OUT"
flatpak create-usb "$OUT" "${IDS[@]}"
du -sh "$OUT"
echo "sideload repo ready: $OUT ($(find "$OUT" -type f | wc -l) files)"
