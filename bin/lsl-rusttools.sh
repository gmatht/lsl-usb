#!/bin/bash
# lsl-rusttools.sh - install statically-linked CLI tools (ripgrep, fd, bat, ...)
# to /cdrom/bin (already on PATH), so they persist on the FAT partition and
# updates are a re-run. musl-static builds have no runtime dependencies.
#
# Usage: sudo bin/lsl-rusttools.sh [name ...]   (default: every entry in the list)
#
# Architecture: on a 32-bit (i686) host the script uses bin/rusttools.i686.list
# (the antiX 32-bit x86 variant); otherwise bin/rusttools.list (x86_64). Override
# with LSL_RUSTTOOL_ARCH=i686|x86_64. The i686 list names binaries that
# tools/build-rusttools.sh produces into dist/rusttools-i686/; when a local copy
# exists there it is installed directly (fully offline build), else the matching
# upstream i686-musl tarball is fetched.
#
# The list format (bin/rusttools.list or bin/rusttools.i686.list) is:
#   name<TAB>owner/repo<TAB>asset-substring<TAB>binary-name<TAB>windows-equivalent
# The latest release's first asset whose name contains the substring is
# downloaded; .tar.gz assets are extracted and the named binary installed.
set -euo pipefail

# --- arch selection ----------------------------------------------------------
LSL_ARCH="${LSL_RUSTTOOL_ARCH:-$(uname -m)}"
case "$LSL_ARCH" in
    i686|i386|x86)      LIST="$(dirname "$0")/rusttools.i686.list" ;;
    x86_64|amd64)       LIST="$(dirname "$0")/rusttools.list" ;;
    *)                  echo "unsupported arch: $LSL_ARCH" >&2; exit 1 ;;
esac
# Local prebuilt dir produced by tools/build-rusttools.sh (i686 only).
LOCAL_DIR="$(dirname "$0")/../dist/rusttools-i686"

DEST="${LSL_RUSTTOOL_DIR:-/cdrom/bin}"
# NOTE: cache under /cdrom/casper (bind-mounted to the writable stick);
# bare /cdrom is the read-only ISO loop on iso-scan boots.
CACHE="${LSL_DL_CACHE:-/cdrom/casper/.lsl-downloads.cache}"
UA="lsl-usb-installer/1.0"

[ -f "$LIST" ] || { echo "no rusttools list at $LIST" >&2; exit 1; }
mkdir -p "$DEST"
mount /cdrom -o remount,rw 2>/dev/null || true

want=("$@")
[ "${#want[@]}" -eq 0 ] && want=($(cut -f1 "$LIST"))

resolve_asset() {
    # $1=repo $2=substring -> prints the browser_download_url of the first
    # matching asset in the latest release (empty on failure).
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
        if pat in a['name'].lower():
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

# Verify a downloaded binary is a real ELF and not truncated.
verify_elf() {
    local f="$1"
    [ -s "$f" ] || return 1
    head -c 4 "$f" 2>/dev/null | od -An -tx1 | grep -q '7f 45 4c 46' || return 1
    return 0
}

for name in "${want[@]}"; do
    line="$(awk -F'\t' -v n="$name" '$1==n' "$LIST" | head -n 1)"
    [ -n "$line" ] || { echo "unknown tool: $name" >&2; continue; }
    IFS=$'\t' read -r n repo pat binname equiv <<< "$line"

    out="$DEST/$binname"
    if [ -x "$out" ]; then
        echo "  $n: already installed ($(du -h "$out" | cut -f1))"
        continue
    fi

    # Prefer a locally-built copy (tools/build-rusttools.sh -> dist/rusttools-i686).
    # This lets a 32-bit image be assembled fully offline.
    if [ -x "$LOCAL_DIR/$binname" ] && verify_elf "$LOCAL_DIR/$binname"; then
        echo "  installing $n ($equiv) from local build $LOCAL_DIR/$binname..."
        install -m 755 "$LOCAL_DIR/$binname" "$out"
        echo "  $n -> $out"
        continue
    fi

    echo "  installing $n ($equiv)..."
    url="$(get_url "$n" "$repo" "$pat")"
    [ -n "$url" ] || { echo "  $n: no matching asset (rate limit?)" >&2; continue; }

    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    if [[ "$url" == *.tar.gz || "$url" == *.tgz ]]; then
        curl -fL --max-time 300 -o "$tmp/pkg.tar.gz" "$url" 2>/dev/null || { echo "  $n: download failed" >&2; continue; }
        tar -xzf "$tmp/pkg.tar.gz" -C "$tmp" 2>/dev/null || { echo "  $n: extract failed" >&2; continue; }
        found="$(find "$tmp" -type f -name "$binname" | head -n 1)"
        [ -n "$found" ] || { echo "  $n: binary '$binname' not in archive" >&2; continue; }
        if ! verify_elf "$found"; then echo "  $n: extracted binary is not a valid ELF" >&2; continue; fi
        install -m 755 "$found" "$out"
    else
        curl -fL --max-time 300 -o "$out" "$url" 2>/dev/null || { echo "  $n: download failed" >&2; continue; }
        chmod +x "$out"
    fi
    echo "  $n -> $out"
done

echo "Installed tools in $DEST:"
ls -lh "$DEST" 2>/dev/null | grep -E "rg|rgr|rga|fd|bat|eza|zoxide|delta|lazygit|starship|just|hyperfine|btm|dust|duf|tealdeer|sd|tokei|xh|gping" || true
