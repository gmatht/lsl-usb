"""Fourth bisection step: mid3.gz (ORDER-only, 499 bytes) PANICKED, so split ORDER itself.

mid4.gz keeps ONLY the for-loop half of ORDER (re-runs the base's own
casper-premount scripts), drops the 4 dangling dot-source lines:
  for f in /scripts/casper-premount/*; do ... done

If mid4.gz boots  -> culprit is in the 4 dot-source lines for the ABSENT
  members (zz_lsl_hdd_mirror / 9990-live-ramclone / zz_lsl_f2fs_provision /
  zz_lsl_f2fs_scrub). Sourcing a missing file kills PID 1 despite the
  `2>/dev/null || true` guard.
If mid4.gz panics -> culprit is in the for-loop/case itself (glob, case
  pattern, or `"$@"` under casper's `set -e`/`set -u` shell).

The for-loop half is the clean control: it preserves the base boot path
(base scripts still run), while the dot-source-only half would skip them
and fail for an unrelated reason. Same mode as the source ORDER member.
"""
import gzip

SRC = r'D:\casper\initrd.f2fs.gz'
DST = r'D:\casper\mid4.gz'

# First half of the source ORDER, byte-identical line-for-line, dot-sources dropped.
ORDER_MID4 = b"""for f in /scripts/casper-premount/*; do
case "$f" in
*/ORDER|*/zz_lsl_hdd_mirror|*/zz_lsl_f2fs_scrub|*/zz_lsl_f2fs_provision|*/9990-live-ramclone) continue ;;
esac
[ -x "$f" ] && "$f" "$@" 2>/dev/null || true
done
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
print(f'mid4 ORDER bytes: {len(ORDER_MID4)} (source was 499)')

out = newc_file(b'scripts/casper-premount/ORDER', ORDER_MID4, order_mode)
out += newc_file(b'TRAILER!!!', b'', 0)
with open(DST, 'wb') as f:
    with gzip.GzipFile(fileobj=f, mode='wb', mtime=0) as gz:
        gz.write(out)
import os
print(f'wrote {DST}: {os.path.getsize(DST)} bytes gz ({len(out)} bytes cpio)')
print('--- mid4 ORDER ---')
print(ORDER_MID4.decode())
print('--- end ---')
