#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# pciconf-top50.py - derive the most common PCI devices from a clone of the
# bsdhw/PCIconf corpus (real-world `pciconf` dumps) for the bundled LKDDb cache.
#
# Two selection modes:
#   --mode perclass  (default) top-N most frequent PCI vendor:device IDs in each
#                    functional class (storage/network/display/multimedia/USB).
#   --mode global    top-N most frequent PCI vendor:device IDs across all
#                    functional classes combined (global frequency ranking).
#
# Both modes de-duplicate against the IDs already present in tools/hw-cache-ids.txt
# and write the new IDs (with corpus frequency as a comment) to --out, ready to
# append. The bundled LKDDb cache (lsl-hw-cache/) is then rebuilt from the list
# with tools/build-hw-cache.ps1.
#
# --consumer-only restricts the corpus to consumer form factors (Notebook,
# Desktop, Convertible, Tablet, All In One, Mini Pc), excluding Server, Firewall
# and System On Chip dumps - the lsl-usb target market.
#
# Usage:
#   git clone --depth 1 https://github.com/bsdhw/PCIconf.git /tmp/PCIconf
#   python3 tools/pciconf-top50.py --repo /tmp/PCIconf \
#       --ids tools/hw-cache-ids.txt --out /tmp/new.txt --consumer-only \
#       --mode global --top 170
#
# The corpus is CC-BY-4.0 (see PCIconf/LICENSE); attribution: bsdhw/PCIconf.
# ---------------------------------------------------------------------------
import argparse, collections, os, re

# Functional PCI classes we care about (major class byte -> label).
CLASSES = [
    (0x01, 'Storage (AHCI/NVMe/RAID)'),
    (0x02, 'Network (Ethernet/WiFi)'),
    (0x03, 'Display (GPU)'),
    (0x04, 'Multimedia (audio/AV)'),
    (0x0c, 'Serial bus (USB xHCI / SMBus)'),
]
TARGET = {c for c, _ in CLASSES}

# Consumer form factors (lsl-usb target market); everything else is excluded
# with --consumer-only.
CONSUMER = {'All In One', 'Convertible', 'Desktop', 'Mini Pc', 'Notebook', 'Tablet'}

# First line of each device block in a `pciconf -l` dump:
#   bcm_xhci0@pci0:1:0:0:	class=0x0c0330 rev=0x01 hdr=0x00 vendor=0x1106 device=0x3483 ...
RX = re.compile(
    r'@pci[0-9:]+\s+class=0x([0-9a-fA-F]{6})\s+rev=0x[0-9a-fA-F]+\s+'
    r'hdr=0x[0-9a-fA-F]+\s+vendor=0x([0-9a-fA-F]{4})\s+device=0x([0-9a-fA-F]{4})')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--repo', required=True, help='path to a PCIconf clone')
    ap.add_argument('--ids', required=True, help='existing tools/hw-cache-ids.txt')
    ap.add_argument('--out', required=True, help='output file for the new IDs')
    ap.add_argument('--top', type=int, default=50, help='how many IDs to select (default 50)')
    ap.add_argument('--mode', choices=['perclass', 'global'], default='perclass',
                    help='perclass = top-N per functional class; global = top-N across classes')
    ap.add_argument('--consumer-only', action='store_true',
                    help='only count consumer form factors (exclude Server/Firewall/SoC)')
    args = ap.parse_args()

    per_class = collections.defaultdict(collections.Counter)
    global_cnt = collections.Counter()
    nfiles = 0
    for dp, _, fns in os.walk(args.repo):
        if '/.git' in dp:
            continue
        ff = os.path.relpath(dp, args.repo).split(os.sep)[0]
        if args.consumer_only and ff not in CONSUMER:
            continue
        for fn in fns:
            try:
                with open(os.path.join(dp, fn), 'r', errors='ignore') as fh:
                    for line in fh:
                        m = RX.search(line)
                        if m:
                            cls = int(m.group(1), 16)
                            ven = m.group(2).lower()
                            dev = m.group(3).lower()
                            key = f"pci:{ven}-{dev}"
                            maj = cls >> 16
                            if maj in TARGET:
                                per_class[maj][key] += 1
                                global_cnt[key] += 1
            except OSError:
                pass
            nfiles += 1

    existing = set()
    with open(args.ids) as fh:
        for line in fh:
            s = line.split('#')[0].strip()
            if s.startswith('pci:'):
                existing.add(s.lower())

    out = []
    if args.mode == 'perclass':
        for cls, label in CLASSES:
            out.append(f"\n# --- PCIconf Top-{args.top}: {label} (data-driven, by frequency) ---")
            for key, cnt in per_class[cls].most_common(args.top):
                if key in existing:
                    continue
                existing.add(key)
                out.append(f"{key}  # PCIconf top-{args.top} {label}: seen in {cnt} machine dumps")
    else:  # global
        out.append(f"\n# --- PCIconf Top-{args.top} across functional classes (global frequency) ---")
        for key, cnt in global_cnt.most_common():
            if key in existing:
                continue
            existing.add(key)
            out.append(f"{key}  # PCIconf top-{args.top} (global): seen in {cnt} machine dumps")
            if sum(1 for l in out if l.startswith('pci:')) >= args.top:
                break

    with open(args.out, 'w') as fh:
        fh.write("\n".join(out) + "\n")
    nnew = sum(1 for l in out if l.startswith('pci:'))
    print(f"scanned {nfiles} files; wrote {nnew} new IDs to {args.out}")


if __name__ == '__main__':
    main()
