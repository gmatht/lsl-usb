#!/usr/bin/env bash
# Build nwg-test for Windows 95.
#
#   ./build.sh              build (incremental)
#   ./build.sh --release    optimized build
#
# Output: dist/nwg-test-win95.exe
#
# Does three things:
#   1. cargo build with the i586-rust9x-windows-msvc target.
#      (i586, NOT i686: Windows 95 never enables CR4.OSFXSR, so any SSE
#      instruction faults regardless of the virtual/physical CPU model.)
#   2. Patches DllCharacteristics in the PE optional header to 0.
#      rust9x emits 0x8140, which makes the Windows 95 loader reject the
#      whole executable with "not a valid Win32 application".
#   3. Copies the patched exe to dist/.
set -euo pipefail
cd "$(dirname "$0")"

TARGET=i586-rust9x-windows-msvc
PROFILE=debug
ARGS=()
for a in "$@"; do
  case "$a" in
    --release) ARGS+=(--release); PROFILE=release ;;
    *) ARGS+=("$a") ;;
  esac
done

cargo +rust9x build --offline --target "$TARGET" "${ARGS[@]}"

SRC="target/$TARGET/$PROFILE/nwg-test.exe"
mkdir -p dist
python3 - "$SRC" dist/nwg-test-win95.exe <<'EOF'
import struct, sys
# Win95 loader: zero DllCharacteristics (rust9x emits 0x8140). NOTE the
# layout: optional-header offset 68 = Subsystem (MUST keep!), 70 =
# DllCharacteristics. Zeroing 68 instead corrupts the subsystem — a GUI
# app happens to still load, a console app falls back to the DOS stub.
d = bytearray(open(sys.argv[1], "rb").read())
pe = struct.unpack("<I", d[0x3c:0x40])[0]
struct.pack_into("<H", d, pe + 24 + 70, 0)
open(sys.argv[2], "wb").write(d)
EOF

echo "-- built dist/nwg-test-win95.exe ($(stat -c%s dist/nwg-test-win95.exe) bytes)"
md5sum dist/nwg-test-win95.exe
