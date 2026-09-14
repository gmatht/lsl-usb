#!/bin/bash
# lsl-appimages.sh - download curated AppImages to /cdrom/casper/appimages/.
#
# Usage: sudo bin/lsl-appimages.sh [name ...]   (default: every entry in the list)
#
# The list (bin/appimages.list, one entry per line) is:
#   name<TAB>github<TAB>owner/repo<TAB>asset-substring
#   name<TAB>url<TAB>https://...<TAB>
# GitHub entries resolve the latest release via the API (same pattern as the
# Windows installer's Get-Rufus) and pick the first .appimage asset whose name
# contains the substring. Downloads land on the FAT partition, so they persist
# and updates are just a re-run (curl -C - resumes).
set -euo pipefail

LIST="$(dirname "$0")/appimages.list"
# NOTE: /cdrom/casper (not bare /cdrom) - on iso-scan boots /cdrom itself
# is the read-only ISO loop while /cdrom/casper is bind-mounted to the
# writable stick. Same location the nvim AppImage block uses.
DEST="${LSL_APPIMAGE_DIR:-/cdrom/casper/appimages}"
CACHE="${LSL_DL_CACHE:-/cdrom/casper/.lsl-downloads.cache}"
UA="lsl-usb-installer/1.0"

[ -f "$LIST" ] || { echo "no appimage list at $LIST" >&2; exit 1; }
mkdir -p "$DEST"
mount /cdrom -o remount,rw 2>/dev/null || true

want=("$@")
# mapfile (not word-splitting) so names with spaces/globs survive intact.
[ "${#want[@]}" -eq 0 ] && mapfile -t want < <(cut -f1 "$LIST")

resolve_asset() {
    # $1=repo $2=substring -> prints the browser_download_url of the first
    # matching .appimage asset in the latest release (empty on failure).
    local repo="$1" pat="$2" json
    json="$(curl -fsSL --max-time 30 -H "User-Agent: $UA" \
        "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null || true)"
    [ -n "$json" ] || return 1
    printf '%s' "$json" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    pat='$pat'.lower()
    for a in d.get('assets',[]):
        n=a['name'].lower()
        if n.endswith('.appimage') and pat in n:
            print(a['browser_download_url']); break
except: pass"
}

# Asset downloads are CDN-served and NOT API-rate-limited; only the resolution
# above is. Cache resolved URLs on the USB and verify with a free HEAD request,
# re-resolving only when a cached URL goes stale (new release).
get_url() {
    local name="$1" repo="$2" pat="$3" url code
    url="$(awk -F'\t' -v n="$name" '$1==n{print $2}' "$CACHE" 2>/dev/null | head -n 1)"
    if [ -n "$url" ]; then
        code="$(curl -sIL -o /dev/null -w '%{http_code}' --max-time 20 "$url" 2>/dev/null || echo 000)"
        [ "$code" = "200" ] && { echo "$url"; return 0; }
    fi
    url="$(resolve_asset "$repo" "$pat")" || return 1
    [ -n "$url" ] || return 1
    if [ -w "$(dirname "$CACHE")" ]; then
        awk -F'\t' -v n="$name" '$1!=n' "$CACHE" 2>/dev/null > "$CACHE.tmp" && mv "$CACHE.tmp" "$CACHE" 2>/dev/null || true
        printf '%s\t%s\n' "$name" "$url" >> "$CACHE" 2>/dev/null || true
    fi
    echo "$url"
}

# Verify a downloaded binary is a real ELF and not truncated (the GitHub API
# does not publish asset checksums, so this is the best available check).
verify_elf() {
    local f="$1"
    [ -s "$f" ] || return 1
    head -c 4 "$f" 2>/dev/null | od -An -tx1 | grep -q '7f 45 4c 46' || return 1
    return 0
}

for name in "${want[@]}"; do
    line="$(awk -F'\t' -v n="$name" '$1==n' "$LIST" | head -n 1)"
    [ -n "$line" ] || { echo "unknown appimage: $name" >&2; continue; }
    IFS=$'\t' read -r n type src pat <<< "$line"
    out="$DEST/$n.AppImage"
    if [ -s "$out" ]; then
        echo "  $n: already present ($(du -h "$out" | cut -f1))"
        continue
    fi
    echo "  downloading $n ..."
    if [ "$type" = "url" ]; then
        # Direct URL entries: no resolution needed; cache the URL as-is.
        url="$src"
        if [ -w "$(dirname "$CACHE")" ]; then
            awk -F'\t' -v n="$n" '$1!=n' "$CACHE" 2>/dev/null > "$CACHE.tmp" && mv "$CACHE.tmp" "$CACHE" 2>/dev/null || true
            printf '%s\t%s\n' "$n" "$url" >> "$CACHE" 2>/dev/null || true
        fi
    else
        url="$(get_url "$n" "$src" "$pat")"
        [ -n "$url" ] || { echo "  $n: no matching asset (rate limit?)" >&2; continue; }
    fi
    if curl -fL --max-time 600 -C - -o "$out" "$url"; then
        if verify_elf "$out"; then chmod +x "$out"; else
            echo "  $n: download is not a valid ELF (truncated?)" >&2; rm -f "$out"; fi
    else
        echo "  $n: failed" >&2; rm -f "$out"; fi
done

echo "AppImages in $DEST:"
ls -lh "$DEST" 2>/dev/null | tail -n +2
