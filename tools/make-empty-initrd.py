import gzip

def newc_header(name: bytes, size: int, mode: int) -> bytes:
    namesize = len(name) + 1
    fields = [0, mode, 0, 0, 1, 0, size, 0, 0, 0, 0, namesize, 0]
    h = b"070701" + b"".join(f"{v:08x}".encode() for v in fields)
    assert len(h) == 110
    return h

def pad_name(namesize: int) -> int:
    return (4 - ((110 + namesize) % 4)) % 4

def pad4(n: int) -> int:
    return (4 - (n % 4)) % 4

def newc_file(name: bytes, data: bytes, mode: int) -> bytes:
    out = bytearray()
    out += newc_header(name, len(data), mode)
    out += name + b"\x00"
    out += b"\x00" * pad_name(len(name) + 1)
    out += data
    out += b"\x00" * pad4(len(data))
    return bytes(out)

# Empty initrd: only TRAILER!!!
raw = newc_file(b"TRAILER!!!", b"", 0)
with open("initrd.gz", "wb") as f:
    with gzip.GzipFile(fileobj=f, mode="wb", mtime=0) as gz:
        gz.write(raw)
print(f"wrote initrd.gz: {len(raw)} bytes cpio -> gz done")
