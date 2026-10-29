"""Second bisection step: mid.gz (3 script members) PANICKED, so split it again.

mid2.gz keeps ONLY scrub + ORDER, byte-identical, drops the 47K provision:
  scripts/casper-premount/zz_lsl_f2fs_scrub
  scripts/casper-premount/ORDER

If mid2.gz boots  -> culprit is zz_lsl_f2fs_provision (partition/mkfs path).
If mid2.gz panics -> culprit is zz_lsl_f2fs_scrub or ORDER (dangling sources?).

ORDER is kept byte-identical (still references the absent hdd_mirror /
ramclone members, but those dot-sources are guarded by 2>/dev/null || true).
"""
import gzip

SRC = r'D:\casper\initrd.f2fs.gz'
DST = r'D:\casper\mid2.gz'
KEEP = {
    'scripts/casper-premount/zz_lsl_f2fs_scrub',
    'scripts/casper-premount/ORDER',
}

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
print(f'source members: {len(entries)}')
kept = [(n, m, d) for (n, m, d) in entries if n in KEEP]
print(f'keeping {len(kept)}:')
for n, m, d in kept:
    print(f'  {oct(m)} {len(d):>8}  {n}')
assert {n for n, _, _ in kept} == KEEP, 'a member is missing from f2fs.gz!'

out = b''.join(newc_file(n.encode(), d, m) for n, m, d in kept)
out += newc_file(b'TRAILER!!!', b'', 0)
with open(DST, 'wb') as f:
    with gzip.GzipFile(fileobj=f, mode='wb', mtime=0) as gz:
        gz.write(out)
import os
print(f'wrote {DST}: {os.path.getsize(DST)} bytes gz ({len(out)} bytes cpio)')
