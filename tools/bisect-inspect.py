import gzip, struct, sys

def parse_newc(data):
    pos = 0
    out = []
    while pos + 110 <= len(data):
        if data[pos:pos+6] != b'070701':
            return out, f'bad magic at {pos}: {data[pos:pos+6]!r}'
        try:
            namesize = int(data[pos+94:pos+102], 16)
            filesize = int(data[pos+54:pos+62], 16)
            mode = int(data[pos+14:pos+22], 16)
        except Exception as e:
            return out, f'hex parse fail at {pos}: {e}'
        name_end = pos + 110 + namesize
        if name_end > len(data):
            return out, 'truncated name'
        name = data[pos+110:name_end-1].decode('utf-8', 'replace')
        # pad name: align (110+namesize) to 4
        pn = (4 - ((110 + namesize) % 4)) % 4
        dstart = name_end + pn
        dend = dstart + filesize
        if dend > len(data):
            return out, f'truncated data for {name}'
        out.append((name, filesize, mode, data[dstart:dend]))
        pos = dend + (4 - (filesize % 4)) % 4
        if name == 'TRAILER!!!':
            break
    return out, None

for path in [r'D:\casper\initrd.f2fs.gz', r'D:\casper\empty.gz', r'C:\GitHub\lsl-usb\initrd.gz']:
    try:
        with open(path, 'rb') as f:
            raw = f.read()
        print(f'== {path}: {len(raw)} bytes file')
        try:
            data = gzip.decompress(raw)
            print(f'   gzip OK: {len(data)} bytes uncompressed')
        except Exception as e:
            print(f'   NOT gzip: {e}; first16={raw[:16]!r}')
            continue
        entries, err = parse_newc(data)
        for name, sz, mode, _ in entries:
            print(f'   {oct(mode)} {sz:>10}  {name}')
        if err:
            print(f'   PARSE STOP: {err}')
    except Exception as e:
        print(f'== {path}: ERROR {e}')
