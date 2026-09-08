#!/usr/bin/env bash
# Build the Windows installer and run it, forwarding "$@" to the exe
# (e.g. ./run.sh --no-elevation --probe-os).
#
# The exe is a Windows PE binary, so HOW it runs depends on where it lives:
# - On a Windows drive (/mnt/c, /mnt/d, ...): WSL interop launches it as a
#   real Windows process, like normal.
# - Inside the WSL rootfs (this repo): Windows has no path to the file, so
#   exec fails with "Invalid argument". The exe is copied to
#   C:\Users\Public\lsl-test\ (the tests' convention) and that copy is run.
# - On plain Linux (no /mnt/c): falls back to wine when available.
#
# Release variant (commented out by default):
#cargo +rust9x build --release --target i586-rust9x-windows-msvc
#target/i586-rust9x-windows-msvc/release/lslsetup.exe
set -euo pipefail
cd "$(dirname "$0")"
cargo +rust9x build --target i586-rust9x-windows-msvc
exe=target/i586-rust9x-windows-msvc/debug/lslsetup.exe
case "$(df --output=target "$exe" | tail -n 1)" in
  /mnt/*) exec "$exe" "$@" ;;
esac
if [ -d /mnt/c/Users/Public ]; then
  dest=/mnt/c/Users/Public/lsl-test/lslsetup.exe
  mkdir -p "$(dirname "$dest")"
  cp "$exe" "$dest"
  exec "$dest" "$@"
elif command -v wine >/dev/null; then
  exec wine "$exe" "$@"
else
  echo "error: $exe is a Windows binary with nowhere Windows to run it (no /mnt/c, no wine)" >&2
  exit 1
fi
