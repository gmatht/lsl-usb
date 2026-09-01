
DONE: boot-from-HDD auto-detect (casper/Mint) - casper-premount hook
(initramfs/lsl_hdd_mirror.sh) sets LAYERFS_PATH from a verified HDD mirror; safe
original preserved as casper/initrd.safe.lz + "(safe)" boot entry; end-to-end KVM
test in tests/qemu-hdd-mirror-test.sh.
DONE: boot-from-HDD auto-detect (live-boot/Debian) - live-premount hook
(initramfs/lsl_liveboot_mirror.sh) exports LIVE_MEDIA_PATH=sfs so live-boot's own
find_livefs adopts the mirror; same sfs/ mirror layout as casper; validated end-to-end
under KVM (tests/qemu-hdd-mirror-liveboot-test.sh: adopt + lsl_no_hdd_mirror fallback).
The hook is POSIX-sh and arch-agnostic, so it runs unchanged on a 32-bit (i386)
Debian live image - only the kernel/initrd binaries differ.
DONE: antiX port (32-bit x86). `initramfs/lsl_antix_mirror.sh` is sourced by antiX's
monolithic live-init just before `find_linuxfs_file`; it exports `SQFILE_FILE=sfs/filesystem.squashfs`
and `FROM_BOOT=hd,usb` so antiX's own scanner adopts the mirror. Reuses the same `sfs/` mirror
layout as casper/live-boot (antiX honours SQFILE_FILE pointing anywhere, so no separate `linuxfs`
copy). Validated end-to-end under qemu-system-i386 (tests/qemu-hdd-mirror-antix-test.sh: adopt +
lsl_no_hdd_mirror fallback). NOTE: antiX only scans usb,cd by default, so the internal HDD is
enabled via FROM_BOOT=hd,usb; on real hardware the internal disk is /dev/sda (major 8) and is
classified as `hd`. (virtio disks, major 253, are NOT classified by antiX's from_filter - a QEMU
test emulation detail; use if=ide in tests.)

scan drive for vhdx while doing install.
start terminal on boot, select VHDX?

config kitty like Windows Terminal

debug Nix
debug Steam

btrfs-growd: at present growing the file doesn't seem to grow the loop-device, can we fix?

linux-hardware.org mirror: upstream rate-limits hard (HTTP 429 after a few
rapid requests; robots.txt Crawl-delay: 10s), which makes both the bundled
cache build (tools/build-hw-cache.ps1) and the live rating fragile. Stand up a
local mirror of the LKDDb device pages (e.g. on www.easyp.net) and point both
the build script and Get-LhwPage (install.ps1) at it. Refresh on a cron so the
bundle ships a complete, always-fresh cache with zero dependence on the
upstream rate limiter. Cache file format is identical (lsl-lhw-<type>-<vid>-<did>.html),
so only the base URL changes. See the TODO comment in tools/build-hw-cache.ps1.
