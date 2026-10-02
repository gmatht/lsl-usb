
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
OPEN 2026-10-01: PERSISTENCE PANE - PARTIALLY BUILT (backend selection only).
  DONE: the wizard page itself (page 4, between "system" and "wifi") with the
    four-backend radio (none/squashfs/btrfs/f2fs), a bounded size selector, and
    the cache-on-tmpfs policy. INSTALL_PAGE 5->6. Harvested by control KIND and
    radio INDEX, never by label - the labels are translated. Reaches Linux via
    LSL_PERSIST / LSL_HOME_BTRFS_MIB / LSL_CACHE_TMPFS in lsl-usb.env, with
    --persist / --persist-mib / --cache-tmpfs flags for headless reproduction.
    NO DESTRUCTIVE CONTROL: nothing on the page repartitions, formats, or erases.
  NOT DONE, and why:
    - The RANDOM-WRITE CHECK (s2.2) is not implemented. There is NO calibrated
      threshold and nothing to calibrate against; a wrong threshold turns away a
      working stick. The design itself says ship advisory-only and calibrate
      first. THIS IS THE NEXT THING TO BUILD IF THE PANE IS FINISHED OFF.
    - eatmydata (s2.8) is not implemented. If it ever is, the hard constraint
      stands: it enables libeatmydata AND NOTHING ELSE - never partitioning,
      formatting, erasing, or any disk write, and never installing anything the
      user did not ask for. Do not implement malware.
    - The size control is a COMBO BOX, not the designed slider: the vendored nwg
      is Win95-era and has no Slider control. Offered sizes are bounded, and the
      real limit (FAT32's 4 GiB single-file cap on a btrfs image) is stated in
      the pane rather than discovered at write time.
    - The FAT/persistence SPLIT (s2.3-2.4) is not implemented - it needs
      repartitioning, which needs its own design.

OPEN 2026-10-01: F2FS PERSISTENCE - Linux side BUILT, unverified on hardware.
  P1 bin/lsl-f2fs-provision (format by label, never repartitions),
  P2 initramfs/lsl_f2fs_scrub.sh (casper-premount hook, injected in both initrds),
  P3 bin/lsl-regen-identity (per-boot rewrite, called from onboot.sh).
  Also fixed: uphome and lsl-flush-home.sh would have fought the f2fs backend by
  packing an ALREADY-persistent upper into home.sfs, where the squashfs copy
  (the overlay LOWER) would shadow the partition's newer content.

  STILL OPEN, and it is the part that matters:
    - DESIGN-F2FS-PERSISTENCE.md s10 steps 2-5 are NOT written. The scrub's
      STATIC checks run in tests/f2fs-scrub.tests.sh; its f2fs half skips
      without root. Step 1 tests the scrub IN ISOLATION and would pass even if
      the hook never ran at the right moment - so nothing here may be read as
      "works on a boot". The QEMU ordering test (step 2) and the two-machine
      simulation (step 3) are the ones that would actually prove it.
    - WINDOWS-SIDE PROVISIONING (s8.1) is not implemented. lslsetup does not
      create the partition; only the Linux formatter exists. That is the
      difference between "works on a stick we prepared by hand" and "works for
      a user".
    - The DENYLIST is the weak point and is unchanged: it removes the machine
      identity we know about, not machine identity.
    - No loop-device name is recorded at mount time (see the btrfs-growd note).

DONE 2026-10-01: COMPRESSION - FINDINGS-COMPRESSION.md, applied.
  Every mksquashfs call now takes -Xcompression-level "$LSL_SQUASHFS_COMPRESSION_LEVEL",
  ONE constant in bin/lsl-common.sh (default 15). 22 is gone: it was past
  libzstd's regular range (>=20 is --ultra), past mksquashfs' documented 1..9,
  bought nothing over 19, and did not finish in the measurement window on real
  content. Level 15 = the knee of the measured curve (5.7% smaller than 9 for 6x
  write time; 19 needs 14x for the last 0.7 points) - a deliberate DEVIATION from
  FINDINGS' own recommended 9, recorded in the doc so nobody "fixes" it back.
  SEVEN sites changed, not the four FINDINGS listed: install.sh:55,60 also passed
  22 and install.sh did not source lsl-common.sh (guarded source added);
  install.sh:12 (home.sfs) gained the level it had been defaulting.
  Regenerated assets/toolkit_sources.sha256 (build.rs fails on drift).

  STILL OPEN, and it is the measurement that decides the level:
  boot-time DECOMPRESSION cost per level was never measured and points the OTHER
  way - every layer is decompressed on every boot, so it favours LOWER levels.
  If boot time matters more than layer size, lower the constant (one line).

DONE 2026-10-01: WHYFAIL16 build stamp. The version no longer depends on a
  staged <bundle>\VERSION that the default (nofmt) path does not have:
  env!("CARGO_PKG_VERSION") is the fallback, the missing file is now LOGGED
  instead of unwrap_or_default()-ed to "", /cdrom/VERSION is written (lsl-diag.sh
  read it and it was never there), the stamp carries the git revision, and
  `lslsetup --version` exists. New src/version.rs with the resolver split out so
  the WHYFAIL16 regression is unit-tested (4 tests).

DONE 2026-10-01 (code half): linux-hardware.org mirror is PARAMETERISED.
  LSL_LHW_BASE_URL is honoured by install.ps1, lslsetup.exe (hardware.rs) and
  tools/build-hw-cache.ps1 (-BaseUrl), so only the URL changes to point at a
  mirror; the cache format (lsl-lhw-<type>-<vid>-<did>.html) is identical so a
  mirrored cache drops straight in, and the 10s crawl-delay still applies.

DONE 2026-10-01: btrfs-growd loop growth - docs/BTRFS-GROWD.md s3 + s3b.
  The mechanism works; what was broken was WHICH loop got refreshed. Only the
  FIRST attached loop device was (findmnt | head -1), so a stale loop from a
  crashed boot kept the old size cached while the file grew every 60s. Now
  lsl_refresh_image_loops is ONE shared implementation in bin/lsl-common.sh used
  by both onboot.sh and the daemon, and it refreshes every attached loop. Also:
  losetup -c stderr is surfaced instead of discarded (a silently-ignoring kernel
  left no trace and `btrfs resize max` then exits 0 with no growth); the size
  verification is no longer triple-gated behind blockdev, so the mismatch is
  always reported; and the re-loop recovery no longer re-mounts with `-o loop`
  (which could attach a SECOND device and strand the first) nor resizes $mp
  instead of $fs_mp. tests/btrfs-growd.tests.sh now calls the real helper rather
  than re-implementing it, and asserts the loop size matches the grown file.
  Kept: boot-time unmounted growth is still the reliable path, and the
  sparse-overprovision redesign stays deferred pending live verification.

  STILL OPEN: no loop-device name is recorded in /run/lsl-usb.state at mount
  time. Recording it would remove the discovery heuristics entirely - the
  natural next step if this recurs.

debug Nix
debug Steam

linux-hardware.org mirror: upstream rate-limits hard (HTTP 429 after a few
  rapid requests; robots.txt Crawl-delay: 10s), which makes both the bundled
  cache build (tools/build-hw-cache.ps1) and the live rating fragile. The CODE
  half is done - LSL_LHW_BASE_URL is honoured by install.ps1, lslsetup.exe and
  build-hw-cache.ps1 (-BaseUrl); the cache file format is identical
  (lsl-lhw-<type>-<vid>-<did>.html), so only the base URL changed.
  REMAINING, and it is not a code change: stand up the mirror host itself
  (e.g. on www.easyp.net) and refresh it on a cron, so the bundle can ship a
  complete, always-fresh cache with zero dependence on the upstream rate
  limiter. That is infrastructure outside this repo.
