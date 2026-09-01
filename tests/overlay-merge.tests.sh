#!/bin/bash
# tests/overlay-merge.tests.sh - whiteout-correctness of bin/overlay-merge.py
#
# Exercises the bundled Python overlay merge against hand-built layers using
# real overlayfs whiteouts (char devices, rdev 0:0) - both the kernel naming
# (whiteout named after the file) and the .wh.<name> convention. Requires root
# (for mknod) and python3; skips cleanly otherwise.
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="${OVERLAY_MERGE_PY:-$REPO_ROOT/bin/overlay-merge.py}"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 missing"; exit 0; }
[ -x "$PY" ] || command -v "$PY" >/dev/null 2>&1 || { echo "SKIP: $PY missing"; exit 0; }
[ "$(id -u)" -eq 0 ] || { echo "SKIP: not root (need mknod for whiteouts)"; exit 0; }

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
cd "$ROOT"

# TEST 1: basic override + .wh.-convention whiteouts
rm -rf L1 L2 out; mkdir -p L1/sub L2/sub
echo L1 > L1/a.txt; echo L1 > L1/sub/b.txt; echo L1 > L1/sub/c.txt; echo L1 > L1/z.txt
echo L2 > L2/a.txt; mknod L2/sub/.wh.c.txt c 0 0; mknod L2/.wh.z.txt c 0 0
python3 "$PY" out L1 L2
[ "$(cat out/a.txt 2>/dev/null)" = L2 ] && ok "T1 override a.txt=L2" || bad "T1 a.txt"
{ [ -e out/sub/c.txt ] && bad "T1 sub/c.txt should be absent"; } || ok "T1 sub/c.txt absent"
{ [ -e out/z.txt ] && bad "T1 z.txt should be absent"; } || ok "T1 z.txt absent"
[ "$(cat out/sub/b.txt 2>/dev/null)" = L1 ] && ok "T1 sub/b.txt=L1" || bad "T1 sub/b.txt"

# TEST 2: kernel whiteout convention (char dev named after the file, top-level)
rm -rf K1 K2 kout; mkdir -p K1 K2; echo v1 > K1/foo.txt; mknod K2/foo.txt c 0 0
python3 "$PY" kout K1 K2
{ [ -e kout/foo.txt ] && bad "T2 kernel whiteout foo.txt should be absent"; } || ok "T2 kernel whiteout foo.txt absent"

# TEST 2b: kernel whiteout convention, nested
rm -rf N1 N2 nout; mkdir -p N1/sub N2/sub; echo v1 > N1/sub/foo.txt; mknod N2/sub/foo.txt c 0 0
python3 "$PY" nout N1 N2
{ [ -e nout/sub/foo.txt ] && bad "T2b nested whiteout should be absent"; } || ok "T2b nested whiteout absent"

# TEST 3: opaque directory (own content survives, lower content hidden)
rm -rf O1 O2 oout; mkdir -p O1/sub O2/sub
echo L1 > O1/sub/x.txt; echo L1 > O1/sub/y.txt; echo L2 > O2/sub/x.txt; touch O2/sub/.wh.__dir_opaque
python3 "$PY" oout O1 O2
[ "$(cat oout/sub/x.txt 2>/dev/null)" = L2 ] && ok "T3 opaque keeps own x.txt=L2" || bad "T3 x.txt"
{ [ -e oout/sub/y.txt ] && bad "T3 opaque should hide y.txt"; } || ok "T3 opaque hides y.txt"

# TEST 4: delete-then-recreate across layers (top-level)
rm -rf R1 R2 R3 rout; mkdir -p R1 R2 R3; echo v1 > R1/f.txt; mknod R2/.wh.f.txt c 0 0; echo v3 > R3/f.txt
python3 "$PY" rout R1 R2 R3
[ "$(cat rout/f.txt 2>/dev/null)" = v3 ] && ok "T4 delete+recreate f.txt=v3" || bad "T4 f.txt"

# TEST 4b: delete-then-recreate across layers (nested)
rm -rf Q1 Q2 Q3 qout; mkdir -p Q1/sub Q2/sub Q3/sub
echo v1 > Q1/sub/f.txt; mknod Q2/sub/.wh.f.txt c 0 0; echo v3 > Q3/sub/f.txt
python3 "$PY" qout Q1 Q2 Q3
[ "$(cat qout/sub/f.txt 2>/dev/null)" = v3 ] && ok "T4b nested delete+recreate=v3" || bad "T4b f.txt"

# TEST 5: symlink preservation
rm -rf S1 sout; mkdir -p S1; echo target > S1/real.txt; ln -s real.txt S1/link.txt
python3 "$PY" sout S1
[ -L sout/link.txt ] && ok "T5 symlink preserved" || bad "T5 symlink"
[ "$(cat sout/link.txt 2>/dev/null)" = target ] && ok "T5 symlink resolves" || bad "T5 symlink resolve"

# TEST 6: whiteout a whole directory (kernel convention)
rm -rf D1 D2 dout; mkdir -p D1/dir D2; echo v > D1/dir/keep.txt; mknod D2/dir c 0 0
python3 "$PY" dout D1 D2
{ [ -e dout/dir ] && bad "T6 dir whiteout should be absent"; } || ok "T6 dir whiteout absent"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ] && exit 0 || exit 1
