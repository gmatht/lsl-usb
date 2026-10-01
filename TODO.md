
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

DONE: FRAGILE_HOME / WHYFAIL9 follow-ups (see FRAGILE_HOME.md):
 - lsl-home-flushd + lsl-btrfs-growd now branch on lsl_effective_home_mode via new
   lsl_effective_home_is_usb/_is_hdd helpers (behaviour-preserving; growd no longer
   re-resolves under its running loop)
 - lsl-shutdown-gui reports the EFFECTIVE home mode, so it cannot promise a btrfs
   sync that did not happen
 - firstboot `home` task now FAILS loudly (non-blocking) on usb-fallback: ERROR log,
   failed phase/detail in the live dialog, /cdrom/casper/lsl-firstboot.home-failed
   marker + .reason, and a desktop warning before the reboot-approval dialog
 - hivex pre-seed: install.ps1 stages libhivex0/libhivex-bin/libwin-hivex-perl .debs
   to <USB>:\pkgs\; lsl_ensure_hivex_tools installs them offline before /home mounts
   (onboot.sh / lsl-mount-home.sh); mount_all.sh marks the missing-hivexregedit
   ordering defect; squashfs_config.sh installs them early in the chroot
 - re-audited other prediction-vs-fact pairs (LSL_CACHE_MOUNT): consumers documented
   in FRAGILE_HOME.md; cache writes gate on lsl_effective_home_is_hdd

NOTE: install-xp.hta (legacy XP installer) does not yet stage the hivex .debs.

scan drive for vhdx while doing install.
start terminal on boot, select VHDX?

config kitty like Windows Terminal
DONE 2026-10-01: misc/kitty.conf now parses under kitty 0.32.2 (the shipped
  `tab_powerline_style no` was fatal; WT-isms padding_*/font_subpixel_antialias/
  active_tab_title_format replaced by window_padding_width/-/active_tab_title_template,
  ctrl+zero -> ctrl+0), and lslsetup now actually ships misc/kitty.conf on the
  stick (FIRSTBOOT_TOOLKIT entry + misc in the bundle copy) so config.sh can
  install it - previously the file was never staged and kitty ran unconfigured.

DONE 2026-10-01: live-session username. casper defaults to USERNAME/HOST
  "ubuntu" (/etc/casper.conf); Mint only boots as `mint` because its GRUB
  passes username=mint hostname=mint (21.3+). LSL generated its own cmdline
  without those, so a Mint stick showed the Mint logo but ran /home/ubuntu.
  nofmt.rs now derives it (Mint->mint, Ubuntu family->ubuntu, else nothing)
  and passes it in every menu/grub.cfg entry. See CHANGELOG.

OPEN 2026-10-01 (WHYFAIL12): machine identity in the overlay upper - latent
  hazard, not a live bug. /cow/upper (casper's RAM root overlay) holds this
  box's identity: /etc/netplan/90-NM-<uuid>.yaml pins match:name "wlp0s20f3" AND
  the WPA PSK in cleartext; lightdm.conf + casper.conf + hostname pin the live
  user to "ubuntu"; machine-id, resolv.conf, snakeoil certs. Harmless today
  because that upper is RAM and uproot packs a different one.

  Fix by mechanism (do NOT mix these up - WHYFAIL12 s6 records two wrong drafts):
    - squashfs PACK step (uproot layers, USB-mode home.sfs) -> mksquashfs -e
      identity list, shared by both calls, relative paths (leading / is a hard
      mksquashfs error), directory names not dir/*.
    - overlay UPPER (F2FS/casper-rw persistence) -> scrub the upper directory
      with rm before the overlay mounts. For casper that is a casper-premount
      hook, which we already inject (build.sh:154 / lslfiles.rs:1724). Order
      verified in scripts/casper: premount at :926, /cow/upper at :551-583,
      overlay mount at :683.
    - Either way: scrubbing unmasks the LOWER's stale copy, so each path also
      needs a per-boot regenerator (onboot.sh lsl_merge_fstab pattern).
  See WHYFAIL12.md section 6, and DESIGN-F2FS-PERSISTENCE.md for the full
  design (provisioning, scrub hook, regenerators, open questions, tests).
  Follow-on: Boot-to-RAM variants + block-layer options are analysed in
  DESIGN-BOOT-TO-RAM-VARIANTS.md (s1-11). Status after TESTING, not reading:
    - extra Boot-to-RAM variants  -> worth building; "vanilla" is the dear one
    - dm-clone + sparse dest      -> WORKS; RAM tracks bytes written (s11.5)
    - dm-clone RAM upper over a never-written F2FS -> WORKS (s11.7)
    - dm-clone promote-on-read    -> impossible; reads bypass hydration (s11.8)
    - dm-clone source->/dev/zero  -> silently corrupts (s11.6)
    - dm-cache                    -> DOES promote hot blocks on read (s11.10)
    - user-mode NBD + pivot       -> viable; used set enumerable (s11.12):
      walk + FIEMAP skipping EXTENT_UNWRITTEN. This stick: 0.38 GiB live
      data vs 4.2 GiB "du". Pivot safe once every enumerated extent is read.
OPEN 2026-10-01: PERSISTENCE PANE (design only) - DESIGN-PERSISTENCE-PANE.md.
  New wizard page between "system" and "wifi": backend radio (none/squashfs/
  btrfs/f2fs), random-write check (advisory - NO calibrated threshold yet),
  space slider (default 3/4, min = base layer 2.5GB + 98MB kernel + 1GB layer
  room = 3.6GB), 32GB FAT cap, caches-on-tmpfs, and an EATMYDATA SPEED OPTION.
  NO DESTRUCTIVE CONTROL: "Erase this stick" was REMOVED (design v6 s2.6) - the
  pane is non-destructive end to end. Formatting belongs to the Rufus flow, where
  Rufus prompts. Do not add a repartition/erase control here without its own
  design.
  (s2.8: wrap the sync-heavy first-boot steps - dpkg/apt, mksquashfs, layer copy.
  Default off. NOTE the manpage CAVEAT applies to us: uproot chroots into the
  target image (uproot:526-553) and the arch can differ from the host, so
  libeatmydata1 must be present IN THE CHROOT for the target arch, and the option
  must VERIFY the preload loaded or it silently does nothing).
  *** HARD CONSTRAINT: the eatmydata option enables the eatmydata UTILITY AND
  NOTHING ELSE. It must NEVER be wired to partitioning/formatting/any disk write
  - those live behind "Erase this stick" only - and must never be an excuse to
  install anything the user did not ask for. Formatting a drive is not funny and
  a destructive checkbox is not a waiver. DO NOT IMPLEMENT MALWARE. ***
  Three findings (design doc s9):
    - GPT refused for BIOS because grub4dos stage1 needs sectors 1..15 and the
      GPT header+entries occupy exactly those. Repartitioning must produce MBR.
    - Windows CANNOT resize FAT32 (Disk Management greys out Shrink; diskpart:
      "the file system does not support it"). So "shrink FAT, leave room" is
      impossible - instead CREATE an unformatted partition and let firstboot
      mkfs.f2fs it. lslsetup already opens \\.\PhysicalDriveN and writes raw
      sectors (nofmt.rs:443,2769), so a partition-table write extends existing
      capability. This also makes it QEMU-testable without Windows.
  Blocks: lslsetup does NOT partition today (zero sfdisk/IOCTL_DISK_SET_*).

OPEN 2026-10-01: COMPRESSION (findings only) - FINDINGS-COMPRESSION.md.
  Four mksquashfs sites pass -Xcompression-level 22 (help documents 1..9;
  22 IS honoured, passed to libzstd). Measured on real layer content: 9->19
  saves ~6%, 19->22 saves nothing. Unmeasured: boot-time DECOMPRESSION cost,
  which likely argues for LOWER levels. Recommend 9 everywhere from one
  shared constant. Not applied.

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
