#!/usr/bin/env bash
# bundle-vendored-source.sh
# ============================================================================
# Bundles the complete corresponding source code for all vendored third-party
# binaries into a single tarball suitable for attaching to GitHub releases.
#
# Usage:
#   ./scripts/bundle-vendored-source.sh [OUTPUT_NAME]
#
# Example:
#   ./scripts/bundle-vendored-source.sh lslsetup-vendored-src-v0.1.0.tar.gz
#
# The script fetches:
#   - chenall/grub4dos at the exact commit pinned in assets/BOOTX64.EFI.txt
#   - Ubuntu shim source package (shim_15.8-0ubuntu2)
#   - Ubuntu GRUB2 source package (grub2_2.14-2ubuntu1, with fallback)
#
# Run this before creating a GitHub release, then attach the resulting tarball
# to the release assets.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ASSETS_DIR="${PROJECT_ROOT}/assets"

# ---------------------------------------------------------------------------
# Parse output name
# ---------------------------------------------------------------------------
if [ $# -ge 1 ]; then
    OUT_FILE="$1"
else
    # Default: include date so multiple runs don't clobber each other
    OUT_FILE="${PROJECT_ROOT}/lslsetup-vendored-src-$(date +%Y%m%d).tar.gz"
fi

OUT_FILE="$(cd "$(dirname "${OUT_FILE}")" && pwd)/$(basename "${OUT_FILE}")"

echo "==> Output: ${OUT_FILE}"

# ---------------------------------------------------------------------------
# Working directory
# ---------------------------------------------------------------------------
WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

SRC_DIR="${WORK_DIR}/vendored-src"
mkdir -p "${SRC_DIR}"

# ---------------------------------------------------------------------------
# Helper: fetch URL to file, die on failure
# ---------------------------------------------------------------------------
fetch() {
    local url="$1"
    local dest="$2"
    echo "    fetching $(basename "${dest}") ..."
    if ! curl -fsL "${url}" -o "${dest}"; then
        echo "    ERROR: failed to download ${url}" >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Helper: try multiple URLs, succeed if any works
# ---------------------------------------------------------------------------
fetch_any() {
    local dest="$1"
    shift
    for url in "$@"; do
        if curl -fsI "${url}" >/dev/null 2>&1; then
            fetch "${url}" "${dest}"
            return 0
        fi
    done
    echo "    ERROR: none of the URLs were reachable for $(basename "${dest}")" >&2
    return 1
}

# ---------------------------------------------------------------------------
# 1. grub4dos (GPL v2) — exact git commit
# ---------------------------------------------------------------------------
echo "==> grub4dos (chenall/grub4dos)"
GRUB4DOS_COMMIT=$(grep 'git checkout' "${ASSETS_DIR}/BOOTX64.EFI.txt" | sed -n 's/.*git checkout \([0-9a-f]*\).*/\1/p' | head -n1 || true)
if [ -z "${GRUB4DOS_COMMIT}" ]; then
    echo "ERROR: could not parse grub4dos commit from BOOTX64.EFI.txt" >&2
    exit 1
fi
echo "    commit: ${GRUB4DOS_COMMIT}"

GRUB4DOS_DIR="${SRC_DIR}/grub4dos-${GRUB4DOS_COMMIT}"
mkdir -p "${GRUB4DOS_DIR}"

# Fetch only the exact commit (shallow clone of specific ref)
(
    cd "${GRUB4DOS_DIR}"
    git init -q
    git remote add origin "https://github.com/chenall/grub4dos.git"
    if ! git fetch --depth 1 origin "${GRUB4DOS_COMMIT}"; then
        echo "ERROR: failed to fetch grub4dos commit ${GRUB4DOS_COMMIT}" >&2
        exit 1
    fi
    git checkout -q FETCH_HEAD
)

# Remove .git to save space in the tarball
rm -rf "${GRUB4DOS_DIR}/.git"

# ---------------------------------------------------------------------------
# 2. shim (BSD-2-Clause) — Ubuntu source package
# ---------------------------------------------------------------------------
echo "==> shim (Ubuntu source package)"
SHIM_VERSION="15.8-0ubuntu2"
SHIM_ARCHIVE="https://archive.ubuntu.com/ubuntu/pool/main/s/shim"
SHIM_OLD="https://old-releases.ubuntu.com/ubuntu/pool/main/s/shim"
SHIM_DEST="${SRC_DIR}/shim-${SHIM_VERSION}"
mkdir -p "${SHIM_DEST}"

fetch_any "${SHIM_DEST}/shim_${SHIM_VERSION}.dsc" \
    "${SHIM_ARCHIVE}/shim_${SHIM_VERSION}.dsc" \
    "${SHIM_OLD}/shim_${SHIM_VERSION}.dsc"

fetch_any "${SHIM_DEST}/shim_${SHIM_VERSION}.debian.tar.xz" \
    "${SHIM_ARCHIVE}/shim_${SHIM_VERSION}.debian.tar.xz" \
    "${SHIM_OLD}/shim_${SHIM_VERSION}.debian.tar.xz"

# The orig tarball may be shared across versions; try multiple locations
if ! fetch_any "${SHIM_DEST}/shim_${SHIM_VERSION}.orig.tar.gz" \
    "${SHIM_ARCHIVE}/shim_${SHIM_VERSION}.orig.tar.gz" \
    "${SHIM_OLD}/shim_${SHIM_VERSION}.orig.tar.gz" 2>/dev/null; then
    if ! fetch_any "${SHIM_DEST}/shim_${SHIM_VERSION}.orig.tar.xz" \
        "${SHIM_ARCHIVE}/shim_${SHIM_VERSION}.orig.tar.xz" \
        "${SHIM_OLD}/shim_${SHIM_VERSION}.orig.tar.xz" 2>/dev/null; then
        echo "    WARNING: could not find shim orig tarball; .dsc + debian.tar.xz may be sufficient" >&2
    fi
fi

# ---------------------------------------------------------------------------
# 3. GRUB2 (GPL v3+) — Ubuntu source package
# ---------------------------------------------------------------------------
echo "==> GRUB2 (Ubuntu source package)"
GRUB_VERSION="2.14-2ubuntu1"
GRUB_ARCHIVE="https://archive.ubuntu.com/ubuntu/pool/main/g/grub2"
GRUB_OLD="https://old-releases.ubuntu.com/ubuntu/pool/main/g/grub2"
GRUB_DEST="${SRC_DIR}/grub2-${GRUB_VERSION}"
mkdir -p "${GRUB_DEST}"

GRUB_DSC_URLS=("${GRUB_ARCHIVE}/grub2_${GRUB_VERSION}.dsc" "${GRUB_OLD}/grub2_${GRUB_VERSION}.dsc")
GRUB_DEBIAN_URLS=("${GRUB_ARCHIVE}/grub2_${GRUB_VERSION}.debian.tar.xz" "${GRUB_OLD}/grub2_${GRUB_VERSION}.debian.tar.xz")
GRUB_ORIG_URLS=("${GRUB_ARCHIVE}/grub2_2.14.orig.tar.xz" "${GRUB_OLD}/grub2_2.14.orig.tar.xz")

if fetch_any "${GRUB_DEST}/grub2_${GRUB_VERSION}.dsc" "${GRUB_DSC_URLS[@]}"; then
    fetch_any "${GRUB_DEST}/grub2_${GRUB_VERSION}.debian.tar.xz" "${GRUB_DEBIAN_URLS[@]}"
    fetch_any "${GRUB_DEST}/grub2_2.14.orig.tar.xz" "${GRUB_ORIG_URLS[@]}"
else
    echo "    WARNING: GRUB2 source ${GRUB_VERSION} not in archive or old-releases" >&2
    rmdir "${GRUB_DEST}" 2>/dev/null || true
    GRUB_FALLBACK="2.14-2ubuntu2"
    echo "    FALLING BACK to closest available version: ${GRUB_FALLBACK}" >&2
    GRUB_DEST="${SRC_DIR}/grub2-${GRUB_FALLBACK}"
    mkdir -p "${GRUB_DEST}"
    fetch_any "${GRUB_DEST}/grub2_${GRUB_FALLBACK}.dsc" \
        "${GRUB_ARCHIVE}/grub2_${GRUB_FALLBACK}.dsc" \
        "${GRUB_OLD}/grub2_${GRUB_FALLBACK}.dsc"
    fetch_any "${GRUB_DEST}/grub2_${GRUB_FALLBACK}.debian.tar.xz" \
        "${GRUB_ARCHIVE}/grub2_${GRUB_FALLBACK}.debian.tar.xz" \
        "${GRUB_OLD}/grub2_${GRUB_FALLBACK}.debian.tar.xz"
    fetch_any "${GRUB_DEST}/grub2_2.14.orig.tar.xz" \
        "${GRUB_ARCHIVE}/grub2_2.14.orig.tar.xz" \
        "${GRUB_OLD}/grub2_2.14.orig.tar.xz"
fi

# ---------------------------------------------------------------------------
# 4. Bundle
# ---------------------------------------------------------------------------
echo "==> Bundling source into ${OUT_FILE}"
tar -czf "${OUT_FILE}" -C "${WORK_DIR}" vendored-src

# Show contents
echo "==> Contents:"
tar -tzf "${OUT_FILE}" | head -20
FILESIZE=$(du -h "${OUT_FILE}" | cut -f1)
echo "==> Size: ${FILESIZE}"

echo ""
echo "Done. Attach ${OUT_FILE} to your GitHub release."
