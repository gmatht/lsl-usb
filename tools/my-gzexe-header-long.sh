#!/bin/sh
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_NAME="$(basename "$0")"
TMP_FILE="$SCRIPT_DIR/.${SCRIPT_NAME}.tmp"

# This elegant trick skips the header until it hits 'EOF', 
# then hands the rest of the file directly to gunzip.
extract_payload() {
  (
    while read f; do
      if [ "$f" = "EOF" ]; then break; fi
    done
    gunzip
  ) < "$0"
}

# Handle explicit unpacking (replace the script with the binary)
case "$1" in
  --unpack)
    # Verify the directory is writable
    if ! touch "$SCRIPT_DIR/.test_write" 2>/dev/null; then
      echo "Error: Cannot write to $SCRIPT_DIR" >&2
      exit 1
    fi
    rm -f "$SCRIPT_DIR/.test_write"

    # Extract to a temp file in the same directory, then atomically replace $0
    if extract_payload > "$TMP_FILE"; then
      chmod 700 "$TMP_FILE"
      if mv -f "$TMP_FILE" "$0"; then
        echo "Unpacked successfully. $SCRIPT_NAME is now the native executable."
        exit 0
      else
        echo "Error: Failed to replace $0" >&2
        rm -f "$TMP_FILE"
        exit 1
      fi
    else
      rm -f "$TMP_FILE"
      echo "Error: Failed to decompress $0" >&2
      exit 1
    fi
    ;;
esac

# --- Normal execution flow (no --unpack flag provided) ---
# We MUST fall back to a temporary runtime extraction to execute the binary.

# Setup secure temp directory
case $TMPDIR in
  / | /*/) ;;
  /*) TMPDIR=$TMPDIR/;;
  *) TMPDIR=/tmp/;;
esac
if type mktemp >/dev/null 2>&1; then
  gztmpdir=$(mktemp -d "${TMPDIR}gztmpXXXXXXXXX")
else
  gztmpdir=${TMPDIR}gztmp$$; mkdir -p "$gztmpdir"
fi || { echo "Cannot create temp dir" >&2; exit 127; }

gztmp="$gztmpdir/$SCRIPT_NAME"

# Print the requested warning to stderr
printf >&2 '%s\n' "packed executable. run $0 --unpack to unpack"

# Extract to temp file and execute
if extract_payload > "$gztmp"; then
  chmod 700 "$gztmp"
  # Clean up temp file in the background after 5 seconds
  (sleep 5; rm -fr "$gztmpdir") 2>/dev/null &
  exec "$gztmp" "$@"
else
  printf >&2 '%s\n' "Cannot decompress $0"
  rm -fr "$gztmpdir"
  exit 127
fi

EOF
