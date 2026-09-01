#!/usr/bin/env bash
# build-rusttools.sh - build / fetch 32-bit (i686) Rust CLI tools for lsl-usb.
#
# lsl-usb ships a 32-bit antiX variant (i686-unknown-linux-musl). Three of the
# tools (fd, bat, zoxide) already publish an i686-musl asset, so we download
# those. The other two (ripgrep, eza) do NOT publish a 32-bit Linux asset, so we
# cross-compile them:
#   * ripgrep: default build is pure-Rust (PCRE2 is an opt-in feature) -> musl
#     static, no C toolchain required. Pass --lto to build with ripgrep's
#     [profile.release-lto] (lto = "fat", panic = "abort", strip = "symbols").
#   * eza:     default build pulls in libgit2 (C). We build with
#     --no-default-features (no git status column) so it stays pure-Rust/musl.
#     Its default [profile.release] already uses thin LTO; --lto upgrades that to
#     fat LTO via --config profile.release.lto=fat.
#
# Output (default $REPO/dist/rusttools-i686):
#   rg  fd  bat  eza  zoxide          stripped, static ELF32 (i686)
#   manifest.txt                       name<tab>sha256<tab>method<tab>version
# With --gzexe, each binary also gets a self-extracting wrapper <name>.gzexe
# (gzip-99-compressed payload; decodes with plain gzip -d on the target).
#
# Usage: tools/build-rusttools.sh [--force] [--target i686-unknown-linux-musl] [--out DIR] [--lto fat] [--gzexe]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${TARGET:-i686-unknown-linux-musl}"
OUTDIR="${OUTDIR:-$REPO_ROOT/dist/rusttools-i686}"
FORCE=0
LTO=0   # 1 => build rg/eza with fat LTO (smaller/slightly faster, more build RAM)
GZEXE=0 # 1 => also emit .gzexe self-extracting wrappers (gzip-99 payload) alongside the plain binaries
while [ $# -gt 0 ]; do
    case "$1" in
        --force) FORCE=1 ;;
        --target) TARGET="$2"; shift ;;
        --out) OUTDIR="$2"; shift ;;
        --lto) LTO=1 ;;
        --gzexe) GZEXE=1 ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

ARCH="${TARGET%%-*}"   # i686
UA="lsl-rusttools/1.0"
export CARGO_NET_RETRY=5
export CARGO_HTTP_TIMEOUT=120

for c in cargo rustup curl python3 strip readelf git; do
    command -v "$c" >/dev/null 2>&1 || { echo "ERROR: $c not found" >&2; exit 1; }
done

mkdir -p "$OUTDIR"
BUILD="$REPO_ROOT/tools/rusttools-build"
mkdir -p "$BUILD"

# This script produces i686 (32-bit x86) binaries only.
[ "$ARCH" = "i686" ] || { echo "ERROR: this script targets i686 only (got $TARGET)" >&2; exit 1; }

# Ensure the cross target is installed for the active toolchain (and for any
# toolchain a repo pins via rust-toolchain.toml).
ensure_target() {
    local tc="${1:-}"
    if [ -n "$tc" ]; then
        rustup target add "$TARGET" --toolchain "$tc" 2>&1 | tail -1 || true
    else
        rustup target add "$TARGET" 2>&1 | tail -1 || true
    fi
}
detect_pinned() {
    local dir="$1" f
    f="$(find "$dir" -maxdepth 2 \( -name 'rust-toolchain.toml' -o -name 'rust-toolchain' \) 2>/dev/null | head -n1)"
    [ -n "$f" ] || return 0
    grep -oE 'channel[[:space:]]*=[[:space:]]*"?[0-9.]+' "$f" 2>/dev/null | grep -oE '[0-9.]+' | head -n1 || true
}
ensure_target ""

# Resolve the first release .tar.gz asset of $repo whose name contains $pat.
resolve_asset() {
    local repo="$1" pat="$2"
    curl -fsSL --max-time 30 -H "User-Agent: $UA" \
        "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null \
    | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    pat='''$pat'''.lower()
    for a in d.get('assets',[]):
        n=a['name'].lower()
        if pat in n and n.endswith('.tar.gz'):
            print(a['browser_download_url']); break
except Exception: pass"
}

# Verify a file is a 32-bit x86 ELF.
verify_elf32() {
    local f="$1"
    [ -s "$f" ] || return 1
    local hdr; hdr="$(readelf -h "$f" 2>/dev/null)" || return 1
    grep -q 'Class:[[:space:]]*ELF32' <<<"$hdr" || return 1
    grep -q 'Machine:[[:space:]]*Intel 80386' <<<"$hdr" || return 1
    return 0
}

# Run a binary (the host executes i686 musl-static via IA32 emulation).
probe() {
    local bin="$1"
    "$bin" --version >/dev/null 2>&1
}

is_done() {  # name -> 0 if stripped ELF32 present and runnable
    local name="$1"
    local out="$OUTDIR/$name"
    [ -x "$out" ] && verify_elf32 "$out" && probe "$out"
}

emit_manifest() {
    : > "$OUTDIR/manifest.txt"
    for n in rg fd bat eza zoxide; do
        local p="$OUTDIR/$n"
        [ -x "$p" ] || continue
        local sha ver method
        sha="$(sha256sum "$p" | cut -d' ' -f1)"
        ver="$("$p" --version 2>&1 | head -n1 | tr -s ' ' | cut -d' ' -f2-)"
        method="$(awk -F'\t' -v n="$n" '$1==n{print $2; exit}' "$OUTDIR/.method" 2>/dev/null)"
        if [ -z "$method" ]; then
            method=build
            [ "$LTO" -eq 1 ] && method=build-lto
            [ "$GZEXE" -eq 1 ] && method="$method+gzexe"
        fi
        printf '%s\t%s\t%s\t%s\n' "$n" "$sha" "$method" "$ver" >> "$OUTDIR/manifest.txt"
    done
    echo "Wrote $OUTDIR/manifest.txt"
}

# -----------------------------------------------------------------------------
# ripgrep  (cross-compile, default features = pure Rust/musl, no PCRE2)
# -----------------------------------------------------------------------------
build_ripgrep() {
    if [ "$LTO" -eq 1 ]; then
        echo "== ripgrep: cross-compiling for $TARGET with fat LTO (--profile release-lto) =="
        local prof="--profile release-lto"
        local profdir="release-lto"
        local method="build-lto"
    else
        echo "== ripgrep: cross-compiling for $TARGET (pure Rust, no PCRE2, no LTO) =="
        local prof="--release"
        local profdir="release"
        local method="build"
    fi
    local src="$BUILD/ripgrep"
    if [ ! -d "$src" ]; then
        git clone --depth 1 https://github.com/BurntSushi/ripgrep.git "$src" 2>&1 | tail -1
    fi
    ( cd "$src" && cargo build $prof --target "$TARGET" --bin rg 2>&1 | tail -3 )
    cp "$src/target/$TARGET/$profdir/rg" "$OUTDIR/rg"
    # release-lto already strips; strip again is a no-op (harmless) for the default profile
    strip "$OUTDIR/rg" 2>/dev/null || true
    printf '%s\t%s\n' "rg" "$method" >> "$OUTDIR/.method"
}

# -----------------------------------------------------------------------------
# eza  (cross-compile, --no-default-features => no libgit2/C)
# -----------------------------------------------------------------------------
build_eza() {
    local exconf=()
    local method="build"
    if [ "$LTO" -eq 1 ]; then
        echo "== eza: cross-compiling for $TARGET (--no-default-features, fat LTO) =="
        exconf=(--config 'profile.release.lto="fat"' --config 'profile.release.codegen-units=1')
        method="build-lto"
    else
        echo "== eza: cross-compiling for $TARGET (--no-default-features, no libgit2, default thin LTO) =="
    fi
    local src="$BUILD/eza"
    if [ ! -d "$src" ]; then
        git clone --depth 1 https://github.com/eza-community/eza.git "$src" 2>&1 | tail -1
    fi
    local pin; pin="$(detect_pinned "$src")"
    if [ -n "$pin" ]; then ensure_target "$pin"; echo "  (eza pins toolchain $pin; added $TARGET for it)"; fi
    ( cd "$src" && cargo build --release --target "$TARGET" --no-default-features "${exconf[@]}" 2>&1 | tail -3 )
    cp "$src/target/$TARGET/release/eza" "$OUTDIR/eza"
    strip "$OUTDIR/eza"
    printf '%s\t%s\n' "eza" "$method" >> "$OUTDIR/.method"
}

# -----------------------------------------------------------------------------
# fd / bat / zoxide  (download prebuilt i686-musl tarball)
# -----------------------------------------------------------------------------
download_prebuilt() {
    local name="$1" repo="$2" binname="$3"
    echo "== $name: downloading prebuilt $TARGET asset from $repo =="
    local url; url="$(resolve_asset "$repo" "$TARGET")"
    [ -n "$url" ] || { echo "  ERROR: no $TARGET asset for $repo" >&2; return 1; }
    echo "  $url"
    local tmp; tmp="$(mktemp -d)"
    curl -fL --max-time 300 -o "$tmp/pkg.tar.gz" "$url" || { echo "  download failed" >&2; rm -rf "$tmp"; return 1; }
    tar -xzf "$tmp/pkg.tar.gz" -C "$tmp" || { echo "  extract failed" >&2; rm -rf "$tmp"; return 1; }
    local found; found="$(find "$tmp" -type f -name "$binname" | head -n1)"
    [ -n "$found" ] || { echo "  binary '$binname' not in archive" >&2; rm -rf "$tmp"; return 1; }
    cp "$found" "$OUTDIR/$name"
    strip "$OUTDIR/$name" 2>/dev/null || true
    rm -rf "$tmp"
    printf '%s\t%s\n' "$name" "download" >> "$OUTDIR/.method"
}

# Wrap each plain binary as a self-extracting .gzexe (make-gzexe.sh). No-op
# unless --gzexe was passed. Requires python3 + gzip (both present here).
maybe_gzexe() {
    [ "$GZEXE" -eq 1 ] || return 0
    command -v python3 >/dev/null 2>&1 || { echo "  --gzexe: python3 missing, skipping" >&2; return 0; }
    local mk="$REPO_ROOT/tools/make-gzexe.sh"
    [ -x "$mk" ] || { echo "  --gzexe: $mk missing, skipping" >&2; return 0; }
    echo "== wrapping binaries as .gzexe (gzip-99 payload) =="
    for n in rg fd bat eza zoxide; do
        local p="$OUTDIR/$n"
        [ -x "$p" ] || continue
        echo "  $n -> $n.gzexe"
        "$mk" "$p" "$OUTDIR/$n.gzexe"
    done
}

# ---- main --------------------------------------------------------------------
: > "$OUTDIR/.method"

# Prebuilt (download) first since they are fast; then the two we compile.
declare -A DL_REPO=( [fd]=sharkdp/fd [bat]=sharkdp/bat [zoxide]=ajeetdsouza/zoxide )
for n in fd bat zoxide; do
    if [ "$FORCE" -eq 0 ] && is_done "$n"; then echo "  $n: already built ($(du -h "$OUTDIR/$n"|cut -f1))"; continue; fi
    download_prebuilt "$n" "${DL_REPO[$n]}" "$n" || echo "  WARNING: $n download failed" >&2
done

for n in rg eza; do
    if [ "$FORCE" -eq 0 ] && is_done "$n"; then echo "  $n: already built ($(du -h "$OUTDIR/$n"|cut -f1))"; continue; fi
    if [ "$n" = rg ]; then build_ripgrep; else build_eza; fi
done

# ---- verify + manifest -------------------------------------------------------
echo
echo "== verifying output (expect ELF32 / Intel 80386, statically linked) =="
rc=0
for n in rg fd bat eza zoxide; do
    p="$OUTDIR/$n"
    if [ ! -x "$p" ]; then echo "  MISSING: $n"; rc=1; continue; fi
    if ! verify_elf32 "$p"; then echo "  BAD ELF: $n (not i686 ELF32)"; rc=1; continue; fi
    if ! probe "$p"; then echo "  WON'T RUN: $n"; rc=1; continue; fi
    printf '  %-8s %s  %s\n' "$n" "$(file -b "$p" | cut -d',' -f1-2)" "$("$p" --version 2>&1 | head -n1)"
done
emit_manifest

# Optional: emit .gzexe self-extracting wrappers (gzip-99 payload).
maybe_gzexe

echo
echo "Artifacts in $OUTDIR:"
ls -lh "$OUTDIR" | sed '1,2d'
exit "$rc"
