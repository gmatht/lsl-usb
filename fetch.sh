#!/bin/bash
# fetch.sh - Download and install lsl-usb from GitHub

set -e  # Exit on error

REPO_URL="https://github.com/gmatht/lsl-usb"
BRANCH="main"
TARBALL_URL="${REPO_URL}/archive/refs/heads/${BRANCH}.tar.gz"
TEMP_DIR=$(mktemp -d)
TARBALL_FILE="${TEMP_DIR}/lsl-usb.tar.gz"
EXTRACT_DIR="${TEMP_DIR}/lsl-usb-${BRANCH}"

echo "Downloading lsl-usb from ${REPO_URL}..."
if command -v curl >/dev/null 2>&1; then
    curl -L -o "$TARBALL_FILE" "$TARBALL_URL"
elif command -v wget >/dev/null 2>&1; then
    wget -O "$TARBALL_FILE" "$TARBALL_URL"
else
    echo "Error: Neither curl nor wget found. Please install one of them." >&2
    exit 1
fi

if [ ! -f "$TARBALL_FILE" ] || [ ! -s "$TARBALL_FILE" ]; then
    echo "Error: Failed to download tarball" >&2
    rm -rf "$TEMP_DIR"
    exit 1
fi

echo "Extracting tarball..."
tar -xzf "$TARBALL_FILE" -C "$TEMP_DIR"

if [ ! -d "$EXTRACT_DIR" ]; then
    echo "Error: Extraction failed or unexpected directory structure" >&2
    rm -rf "$TEMP_DIR"
    exit 1
fi

if [ ! -f "$EXTRACT_DIR/install.sh" ]; then
    echo "Error: install.sh not found in extracted archive" >&2
    rm -rf "$TEMP_DIR"
    exit 1
fi

echo "Running install.sh..."
cd "$EXTRACT_DIR"
chmod +x install.sh

# Temporarily disable set -e to capture exit code and ensure cleanup
set +e
bash ./install.sh
INSTALL_EXIT_CODE=$?
set -e

echo ""
if [ $INSTALL_EXIT_CODE -eq 0 ]; then
    echo "Installation completed successfully!"
else
    echo "Installation exited with code $INSTALL_EXIT_CODE"
fi

# Cleanup - always run regardless of install.sh exit code
echo "Cleaning up temporary files..."
#rm -rf "$TEMP_DIR"
echo "$TEMP_DIR"

exit $INSTALL_EXIT_CODE