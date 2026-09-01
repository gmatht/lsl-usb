#!/bin/sh
# make-gzexe.sh - produce an *efficient* gzexe wrapper around a binary.
#
# A gzexe file is a self-decompressing executable: running it decodes its own
# embedded payload with `gzip -d` and execs it in place (no /tmp extract, no
# extra tooling beyond gzip on the target -- antiX ships gzip via busybox/GNU).
#
# The classic `gzexe` uses plain -9` for the payload. This variant uses
# tools/gzip-99 instead: gzip -9 -> 7z -tgzip -mx=9 -> advdef -z -4, keeping the
# smallest *gzip-compatible* DEFLATE stream. So the on-disk wrapper is smaller
# while still `gzip -d`-decodable at runtime.
#
# Usage: tools/make-gzexe.sh SRC_BINARY [OUT]   (OUT default: SRC.gzexe)
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GZIP99="$REPO_ROOT/tools/gzip-99"

[ -x "$1" ] || { echo "usage: $0 SRC_BINARY [OUT]" >&2; exit 1; }
SRC="$1"
OUT="${2:-$SRC.gzexe}"

MARKER='__GZEXE__'

# --- 1) runtime stub. The payload offset is a FIXED-WIDTH 6-digit placeholder
#        (000000) so patching never shifts the byte layout. We patch it to a
#        zero-padded 6-digit value, keeping the file size constant. -----------
STUB="$(mktemp)"
cat > "$STUB" <<'STUB'
#!/bin/sh
# self-decompressing executable (lsl-usb gzexe). decodes its own payload via gzip -d.
if [ "$1" = "-d" ]; then tail -c +000000 "$0" | gzip -d; exit $?; fi
GZTMP="$(mktemp "${TMPDIR:-/tmp}/gx.XXXXXX")" || exit 1
tail -c +000000 "$0" | gzip -d > "$GZTMP" || { echo "gzexe: decode failed" >&2; exit 1; }
chmod +x "$GZTMP"
trap 'rm -f "$GZTMP"' EXIT
exec "$GZTMP" "$@"
STUB

# --- 2) assemble stub + NUL + marker, then append the gzip-99 payload ----------
{
  cat "$STUB"
  printf '\0'
  printf '%s' "$MARKER"
} > "$OUT"
rm -f "$STUB"
"$GZIP99" "$OUT.payload.gz" < "$SRC" >/dev/null
cat "$OUT.payload.gz" >> "$OUT"
rm -f "$OUT.payload.gz"

# --- 3) find the gzip magic in the COMPLETE file; patch with a fixed-width value
GZOFF="$(python3 - "$OUT" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
i = d.find(b'\x1f\x8b\x08')
if i < 0:
    sys.exit("make-gzexe: gzip payload magic not found")
print(i + 1)   # 1-based for tail -c +N
PY
)"
# Fixed-width replacement (6-digit) so the layout does not move between scan and write.
GZOFF6="$(printf '%06d' "$GZOFF")"
sed "s/000000/$GZOFF6/g" "$OUT" > "$OUT.tmp"
mv -f "$OUT.tmp" "$OUT"
chmod +x "$OUT"

echo "made: $OUT ($(stat -c%s "$OUT") bytes; payload @ $GZOFF)"
echo "verify: $OUT -d | cmp - $SRC"
"$OUT" -d | cmp -s - "$SRC" && echo "OK: decompresses byte-identical to $SRC" || echo "WARN: decompress mismatch"
