"""Fifth bisection step: mid4.gz (for-loop half of ORDER, dot-sources dropped)
BOOTED, so the for-loop/case/glob half is innocent.

mid5.gz keeps the FULL ORDER shape (for-loop + all 4 dot-source lines),
but guards each dot-source with an existence test, still ORDER-only
(no hook members packed):
  for f in ...; do ... done  (byte-identical to source/mid4)
  + 4x guarded sources

If mid5.gz boots  -> confirms the diagnosis (bare `. <absent-file>` kills
  PID 1 despite `2>/dev/null || true` under casper's `set -e`-sourced ORDER)
  AND validates the fix shape (`if [ -e ... ]; then . ...; fi`).
If mid5.gz panics -> the guard form itself is still fatal (or the culprit
  is elsewhere), and the fix needs rethinking.

Same single-member form as mid3/mid4: scripts/casper-premount/ORDER only,
same mode as the source ORDER member.
"""
import gzip

SRC = r'D:\casper\initrd.f2fs.gz'
DST = r'D:\casper\mid5.gz'

# For-loop half: byte-identical to ORDER_MID4 / the source's first half.
# Guarded half: `if [ -e ... ]; then . ...; fi` -- a failing `[ -e ]` test as
# an `if` condition never triggers `set -e`, unlike a bare `. <missing>`.
ORDER_MID5 = b"""for f in /scripts/casper-premount/*; do
case "$f" in
*/ORDER|*/zz_lsl_hdd_mirror|*/zz_lsl_f2fs_scrub|*/zz_lsl_f2fs_provision|*/9990-live-ramclone) continue ;;
esac
[ -x "$f" ] && "$f" "$@" 2>/dev/null || true
done
if [ -e /scripts/casper-premount/zz_lsl_hdd_mirror ]; then . /scripts/casper-premount/zz_lsl_hdd_mirror "$@" 2>/dev/null || true; fi
if [ -e /scripts/casper-premount/9990-live-ramclone ]; then . /scripts/casper-premount/9990-live-ramclone "$@" 2>/dev/null || true; fi
if [ -e /scripts/casper-premount/zz_lsl_f2fs_provision ]; then . /scripts/casper-premount/zz_lsl_f2fs_provision "$@" 2>/dev/null || true; fi
if [ -e /scripts/casper-premount/zz_lsl_f2fs_scrub ]; then . /scripts/casper-premount/zz_lsl_f2fs_scrub "$@" 2>/dev/null || true; fi
"""

def parse_newc(data):
    pos = 0
    entries = []  # (name, mode, data_bytes)
    while pos + 110 <= len(data):
        if data[pos:pos+6] != b'070701':
            raise ValueError(f'bad magic at {pos}')
        namesize = int(data[pos+94:pos+102], 16)
        filesize = int(data[pos+54:pos+62], 16)
        mode = int(data[pos+14:pos+22], 16)
        name_end = pos + 110 + namesize
        name = data[pos+110:name_end-1].decode()
        pn = (4 - ((110 + namesize) % 4)) % 4
        dstart = name_end + pn
        dend = dstart + filesize
        fdata = data[dstart:dend]
        entries.append((name, mode, fdata))
        pos = dend + (4 - (filesize % 4)) % 4
        if name == 'TRAILER!!!':
            break
    return entries

def newc_file(name: bytes, data: bytes, mode: int) -> bytes:
    namesize = len(name) + 1
    fields = [0, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, namesize, 0]
    h = b'070701' + b''.join(f'{v:08x}'.encode() for v in fields)
    out = bytearray(h + name + b'\x00')
    out += b'\x00' * ((4 - ((110 + namesize) % 4)) % 4)
    out += data
    out += b'\x00' * ((4 - (len(data) % 4)) % 4)
    return bytes(out)

with open(SRC, 'rb') as f:
    raw = gzip.decompress(f.read())
entries = parse_newc(raw)
order_mode = next(m for (n, m, d) in entries if n == 'scripts/casper-premount/ORDER')
print(f'source ORDER mode: {oct(order_mode)}')
print(f'mid5 ORDER bytes: {len(ORDER_MID5)} (source was 499)')

out = newc_file(b'scripts/casper-premount/ORDER', ORDER_MID5, order_mode)
out += newc_file(b'TRAILER!!!', b'', 0)
with open(DST, 'wb') as f:
    with gzip.GzipFile(fileobj=f, mode='wb', mtime=0) as gz:
        gz.write(out)
import os
print(f'wrote {DST}: {os.path.getsize(DST)} bytes gz ({len(out)} bytes cpio)')
print('--- mid5 ORDER ---')
print(ORDER_MID5.decode())
print('--- end ---')
