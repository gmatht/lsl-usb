#!/usr/bin/env bash
# QEMU boot test for the no-reformat (grub4dos) boot creator.
#
# Builds a disk image that replicates EXACTLY what nofmt produces — using the
# actual embedded assets/grldr + assets/grldr.mbr — then boots it in QEMU and
# verifies the whole chain works:
#   SeaBIOS -> grub4dos MBR stage1 -> grldr -> menu.lst -> loopback-map the
#   ISO -> chainload the ISO's own bootloader.
#
# The test ISO prints a marker to the serial console; the script greps the
# QEMU serial output for it. It also runs a regression check that the stage1
# continuation (sectors 1..15) is REQUIRED: without it grub4dos dies with
# "Missing helper" and the stick is not bootable.
#
# Requires: qemu-system-i386, grub-mkrescue, xorriso, sfdisk, mkfs.vfat,
# losetup, mount, python3. Run as root (losetup/mount on a raw image).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS="$REPO/assets"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for t in qemu-system-i386 grub-mkrescue xorriso sfdisk fdisk mkfs.vfat losetup mount umount python3; do
  command -v "$t" >/dev/null || { echo "missing required tool: $t"; exit 1; }
done

# ---- 1) small bootable test ISO that prints a marker to the serial console
mkdir -p "$WORK/iso/boot/grub"
cat > "$WORK/iso/boot/grub/grub.cfg" <<'EOF'
serial --unit=0 --speed=115200
terminal_input serial
terminal_output serial
set timeout=0
set default=0
menuentry "LSL TEST ISO" {
    echo "LSL-TEST-ISO-BOOTED"
    sleep 2
    halt
}
EOF
grub-mkrescue -o "$WORK/test.iso" "$WORK/iso" >/dev/null 2>&1

# ---- 2) disk image: one active FAT32 partition (like a real USB stick)
dd if=/dev/zero of="$WORK/stick.img" bs=1M count=512 status=none
printf 'label: dos\nstart=2048, type=c, bootable\n' | sfdisk "$WORK/stick.img" >/dev/null 2>&1
LOOP="$(losetup -fP --show "$WORK/stick.img")"
cleanup() { umount "$WORK/mnt" 2>/dev/null || true; losetup -d "$LOOP" 2>/dev/null || true; }
trap 'cleanup; rm -rf "$WORK"' EXIT
mkfs.vfat -F 32 -n LSLTEST "${LOOP}p1" >/dev/null 2>&1
mkdir -p "$WORK/mnt"
mount "${LOOP}p1" "$WORK/mnt"
# grldr ships compressed (assets/grldr.gz: gzip -9 + advdef -z -4); the
# installer inflates it with flate2, so the test does the same here.
python3 -c "import gzip,shutil; shutil.copyfileobj(gzip.open('$ASSETS/grldr.gz','rb'), open('$WORK/mnt/grldr','wb'))"
mkdir -p "$WORK/mnt/_ISO"
cp "$WORK/test.iso" "$WORK/mnt/_ISO/test.iso"
cat > "$WORK/menu.lst" <<'EOF'
timeout 5
default 0
title LSL TEST (loopback ISO)
find --set-root --ignore-floppies --ignore-cd /_ISO/test.iso
map /_ISO/test.iso (0xff) || map --mem /_ISO/test.iso (0xff)
map --hook
root (0xff)
chainloader (0xff)
boot
EOF
cp "$WORK/menu.lst" "$WORK/mnt/menu.lst"
umount "$WORK/mnt"
losetup -d "$LOOP"

# ---- 3) write the grub4dos stage1 (the nofmt raw write)
#   sector 0:      grldr.mbr[0..446]  (MBR boot code; partition table kept)
#   sectors 1..15: grldr.mbr[512..8192] (stage1 continuation - REQUIRED)
write_stage1() { # $1=img $2=grldr.mbr $3=write_continuation(0/1)
  python3 - "$1" "$2" "$3" <<'PYEOF'
import sys
img, mbr_path, cont = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
mbr = open(mbr_path, 'rb').read()
assert len(mbr) == 8192, "grldr.mbr must be 8192 bytes"
f = open(img, 'r+b')
f.seek(0); head = f.read(512)
assert head[510] == 0x55 and head[511] == 0xAA, "no MBR signature"
f.seek(0); f.write(mbr[:446])          # MBR boot code (partition table preserved)
if cont:
    f.seek(512); f.write(mbr[512:])    # stage1 continuation, sectors 1..15
else:
    f.seek(512); f.write(b'\x00' * (15 * 512))  # clear the continuation
f.seek(0); new = f.read(512)
assert new[446:510] == head[446:510], "partition table changed"
PYEOF
}

boot_and_check() { # $1=img $2=expected-marker
  timeout 30 qemu-system-i386 -drive file="$1",format=raw,if=ide \
    -m 256 -boot order=c -nographic 2>&1 || true
}

# copy grldr + ISO + menu.lst into a mounted partition (grub4dos layout)
# (grldr ships compressed; inflate exactly like the installer does)
populate() { # $1=mountpoint
  python3 -c "import gzip,shutil,sys; shutil.copyfileobj(gzip.open('$ASSETS/grldr.gz','rb'), open(sys.argv[1],'wb'))" "$1/grldr"
  mkdir -p "$1/_ISO"
  cp "$WORK/test.iso" "$1/_ISO/test.iso"
  cp "$WORK/menu.lst" "$1/menu.lst"
}

# ---- 4) POSITIVE test: fixed layout must boot the ISO
write_stage1 "$WORK/stick.img" "$ASSETS/grldr.mbr" 1
echo "== positive: booting the fixed layout =="
OUT="$(boot_and_check "$WORK/stick.img")"
if echo "$OUT" | grep -q "LSL-TEST-ISO-BOOTED"; then
  echo "PASS: grub4dos booted, showed the menu, and loopback-booted the ISO"
else
  echo "FAIL: marker not found in QEMU output"
  echo "$OUT" | tail -25
  exit 1
fi

# ---- 5) REGRESSION guard: without the continuation it must NOT boot
write_stage1 "$WORK/stick.img" "$ASSETS/grldr.mbr" 0
echo "== regression: continuation-less layout must fail with 'Missing helper' =="
OUT="$(boot_and_check "$WORK/stick.img")"
if echo "$OUT" | grep -q "Missing helper"; then
  echo "PASS: continuation-less layout correctly fails (stage1 continuation is required)"
else
  echo "FAIL: expected 'Missing helper' but the image booted anyway"
  echo "$OUT" | tail -25
  exit 1
fi

# ---- 6) no-active single partition must still boot (grub4dos scans) ----
dd if=/dev/zero of="$WORK/noact.img" bs=1M count=256 status=none
printf 'label: dos\nstart=2048, type=c\n' | sfdisk "$WORK/noact.img" >/dev/null 2>&1
LOOP="$(losetup -fP --show "$WORK/noact.img")"
mkfs.vfat -F 32 -n LSLTEST "${LOOP}p1" >/dev/null 2>&1
mount "${LOOP}p1" "$WORK/mnt"
populate "$WORK/mnt"
umount "$WORK/mnt"; losetup -d "$LOOP"
write_stage1 "$WORK/noact.img" "$ASSETS/grldr.mbr" 1
echo "== no-active single partition must boot (grub4dos scans) =="
OUT="$(boot_and_check "$WORK/noact.img")"
if echo "$OUT" | grep -q "LSL-TEST-ISO-BOOTED"; then
  echo "PASS: no-active single-partition stick boots (grub4dos scans)"
else
  echo "FAIL: no-active single-partition stick did not boot"
  echo "$OUT" | tail -15
  exit 1
fi

# ---- 7) active EXTENDED partition must still boot (grub4dos scans into it) ----
dd if=/dev/zero of="$WORK/ext.img" bs=1M count=512 status=none
fdisk "$WORK/ext.img" <<'EOF' >/dev/null 2>&1
o
n
e
1
2048
+200M
n
l
4096
+100M
a
1
t
5
c
w
EOF
LOOP="$(losetup -fP --show "$WORK/ext.img")"
mkfs.vfat -F 32 -n LSLTEST "${LOOP}p5" >/dev/null 2>&1
mount "${LOOP}p5" "$WORK/mnt"
populate "$WORK/mnt"
umount "$WORK/mnt"; losetup -d "$LOOP"
write_stage1 "$WORK/ext.img" "$ASSETS/grldr.mbr" 1
echo "== active extended partition must boot (grub4dos scans into it) =="
OUT="$(boot_and_check "$WORK/ext.img")"
if echo "$OUT" | grep -q "LSL-TEST-ISO-BOOTED"; then
  echo "PASS: logical partition inside an active extended partition boots (grub4dos scans into it)"
else
  echo "FAIL: extended-partition stick did not boot"
  echo "$OUT" | tail -15
  exit 1
fi

echo "ALL QEMU BOOT TESTS PASSED"
