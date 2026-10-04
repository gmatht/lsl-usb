#!/bin/sh
# Verify build.sh inserts the f2fs provision hook BEFORE the scrub in
# casper-premount/ORDER, and that it matches the Rust CASPER_PREMOUNT_ORDER.
#
# Two things are load-bearing and neither is expressible with `>>`:
#   1. provision must run before scrub (it creates what the scrub cleans);
#   2. casper's OWN casper-premount scripts must still run first, or the
#      injected ORDER disables them entirely (the regression recorded at
#      lslfiles.rs CASPER_PREMOUNT_ORDER).
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Replay exactly the two blocks build.sh runs, in isolation.
order="$TMP/ORDER"
cat > "$order" <<'EOF'
/scripts/casper-premount/10driver_updates "$@"
[ -e /conf/param.conf ] && . /conf/param.conf
/scripts/casper-premount/20iso_scan "$@"
EOF

# 1. the scrub (appended, as in build.sh)
printf '. /scripts/casper-premount/zz_lsl_f2fs_scrub "$@"\n' >> "$order"

# 2. the provision hook (inserted immediately BEFORE the scrub)
if ! grep -q 'zz_lsl_f2fs_provision' "$order"; then
    prov_line='. /scripts/casper-premount/zz_lsl_f2fs_provision "$@"'
    order_new="${order}.lsl.$$"
    if grep -q 'zz_lsl_f2fs_scrub' "$order"; then
        awk -v l="$prov_line" '
            !done && /zz_lsl_f2fs_scrub/ { print l; done=1 }
            { print }
        ' "$order" > "$order_new"
    else
        { cat "$order"; printf '%s\n' "$prov_line"; } > "$order_new"
    fi
    mv -f "$order_new" "$order"
fi

prov_line="$(grep -n 'zz_lsl_f2fs_provision' "$order" | head -1 | cut -d: -f1)"
scrub_line="$(grep -n 'zz_lsl_f2fs_scrub' "$order" | head -1 | cut -d: -f1)"

if [ -n "$prov_line" ] && [ -n "$scrub_line" ] && [ "$prov_line" -lt "$scrub_line" ]; then
    ok "provision sourced before scrub (line $prov_line < $scrub_line)"
else
    bad "ordering wrong: provision @${prov_line:-none}, scrub @${scrub_line:-none}"
fi

# casper's own scripts must STILL be first: both of our hooks come after them.
first_own="$(grep -n '10driver_updates' "$order" | head -1 | cut -d: -f1)"
if [ -n "$first_own" ] && [ "$first_own" -lt "$prov_line" ]; then
    ok "casper's own premount scripts still run first (line $first_own < $prov_line)"
else
    bad "provision ran ahead of casper's own scripts: $(cat "$order")"
fi

if grep -q '20iso_scan' "$order" && grep -q 'param.conf' "$order"; then
    ok "no casper premount script was dropped by the insertion"
else
    bad "insertion lost a casper script: $(cat "$order")"
fi

# Both hook lines must be dot-prefixed (sourced), never bare - an executed hook
# runs in a subshell where its `return` is an error and its exports vanish.
if [ "$(grep -c '^\. /scripts/casper-premount/zz_lsl_f2fs' "$order")" = "2" ]; then
    ok "both f2fs hooks are sourced (dot-prefixed), not executed"
else
    bad "hook lines are not all dot-prefixed: $(cat "$order")"
fi

# Idempotence: a second pass must not duplicate the provision line.
if ! grep -q 'zz_lsl_f2fs_provision' "$order"; then
    prov_line='. /scripts/casper-premount/zz_lsl_f2fs_provision "$@"'
    order_new="${order}.lsl.$$"
    awk -v l="$prov_line" '!done && /zz_lsl_f2fs_scrub/ { print l; done=1 } { print }' \
        "$order" > "$order_new" && mv -f "$order_new" "$order"
fi
after="$(grep -c 'zz_lsl_f2fs_provision' "$order")"
[ "$after" = "1" ] && ok "re-running does not duplicate the hook" \
    || bad "hook count is $after after a second pass (want 1)"

# build.sh must actually reference the new files, or the parity is nominal.
for f in lsl_f2fs_provision.sh lsl-f2fs-tools.sh F2FS_TOOLS_TARBALL; do
    if grep -q "$f" "$REPO_ROOT/build.sh"; then
        ok "build.sh references $f"
    else
        bad "build.sh does not reference $f"
    fi
done

# Parity with the Rust ORDER: base scripts first, provision before scrub.
# NB: CASPER_PREMOUNT_ORDER is a Rust BYTE STRING, so its quotes are escaped
# (\" ) in the source. Match on the hook name alone and take the first `. `
# line that mentions it.
rust="$REPO_ROOT/rust9x/lslsetup/src/lslfiles.rs"
if grep -q 'zz_lsl_f2fs_provision' "$rust" && grep -q 'zz_lsl_f2fs_scrub' "$rust"; then
    r_loop="$(grep -n 'for f in /scripts/casper-premount/\*' "$rust" | head -1 | cut -d: -f1)"
    r_prov="$(grep -n '^\. /scripts/casper-premount/zz_lsl_f2fs_provision' "$rust" | head -1 | cut -d: -f1)"
    r_scrub="$(grep -n '^\. /scripts/casper-premount/zz_lsl_f2fs_scrub' "$rust" | head -1 | cut -d: -f1)"
    if [ -n "$r_loop" ] && [ -n "$r_prov" ] && [ -n "$r_scrub" ] \
        && [ "$r_loop" -lt "$r_prov" ] && [ "$r_prov" -lt "$r_scrub" ]; then
        ok "Rust ORDER agrees: base scripts ($r_loop) < provision ($r_prov) < scrub ($r_scrub)"
    else
        bad "Rust ORDER order is loop@$r_loop prov@$r_prov scrub@$r_scrub"
    fi
else
    bad "Rust CASPER_PREMOUNT_ORDER does not source both f2fs hooks"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1