#!/bin/bash
# lsl-usb portable pi agent launcher.
# Runs the pi coding agent from this stick on any Linux with no install:
# seeds ~/.pi/agent auth from the stick, stages the Linux node binary to
# /tmp (FAT has no exec bit, so it cannot run in place), and execs the
# bundled CLI. Sessions/config land in $HOME (RAM on a live USB).
#
#   bash /cdrom/pi/pi.sh [pi args...]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/dist/bundle/cli.js" ] || { echo "pi.sh: $HERE/dist/bundle/cli.js missing" >&2; exit 1; }
[ -f "$HERE/node" ] || { echo "pi.sh: $HERE/node missing" >&2; exit 1; }
mkdir -p "$HOME/.pi/agent" 2>/dev/null || true
cp -f "$HERE/auth.json" "$HOME/.pi/agent/auth.json" 2>/dev/null || true
cp -f "$HERE/settings.json" "$HOME/.pi/agent/settings.json" 2>/dev/null || true
chmod 600 "$HOME/.pi/agent/auth.json" 2>/dev/null || true
mkdir -p /tmp/lsl-pi 2>/dev/null || true
cp -f "$HERE/node" /tmp/lsl-pi/node 2>/dev/null || { echo "pi.sh: cannot stage node to /tmp" >&2; exit 1; }
chmod +x /tmp/lsl-pi/node
exec /tmp/lsl-pi/node "$HERE/dist/bundle/cli.js" "$@"
