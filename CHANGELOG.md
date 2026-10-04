# Changelog

All notable changes to lsl-usb. Format based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

Four open proposals closed. `FINDINGS-COMPRESSION.md`, `TODO.md` and
`docs/BTRFS-GROWD.md` carry the full reasoning for each.

### Added

- **F2FS persistence now actually creates its partition (P1b).** Choosing F2FS
  on the PERSISTENCE page used to write `LSL_PERSIST=f2fs` and then do nothing:
  nothing in the tree ever created a partition, so every boot fell back to a
  RAM upper and `/home` silently did not persist. `bin/lsl-f2fs-resize` had
  been written for exactly this and had zero callers.
  - **Windows writes only the intent.** Creating the partition means *shrinking*
    the stick's FAT partition, and Windows has no API for that (Shrink Volume
    is greyed out; diskpart refuses), so `lslsetup` cannot do it. Instead it
    appends `casper/initrd.f2fs.gz` to the boot entry and puts
    `lsl_f2fs_provision=<GiB>` on the kernel cmdline — the size has to travel
    there because `lsl-usb.env` lives on the very medium being repartitioned.
  - **The initrd does the work on first boot.**
    `initramfs/lsl_f2fs_provision.sh` shrinks the FAT filesystem, shrinks the
    partition, adds the second and formats it f2fs — then
    `zz_lsl_f2fs_scrub` (already shipped) cleans it, which is why the two are
    carried in one initrd and sourced in that order.
  - **Order is load-bearing and verified twice.** The filesystem must shrink
    before the partition, or the filesystem outlives its partition: it mounts
    clean and then fails past the boundary. And `fatresize` was measured to
    exit 0 while changing nothing, so the BPB is re-read and compared rather
    than trusting the exit code.
  - **It refuses rather than guesses.** Before writing a byte it requires the
    boot medium unmounted, identified *by content* (never by assuming
    `/dev/sda`), and unpinned by any loopback; and it never reshapes a stick
    that already has a Linux partition. Every failure is a logged no-op, so
    the worst case is "no persistence", never a broken stick.
  - **Tools come from the ISO's own rootfs** (`scripts/extract-f2fs-tools.sh`
    → `sfdisk`/`fatresize`/`mkfs.f2fs` + `ldd` closure, unpacked to `/run` at
    boot by `initramfs/lsl-f2fs-tools.sh`). No download, no vendored binary,
    no version skew with the kernel's f2fs driver. Missing tools degrade to a
    no-op, never a failed install.
  - The hook is **inert unless the cmdline flag is present**, and the initrd is
    only installed when F2FS was chosen — every other backend's boot entries
    are byte-for-byte unchanged (asserted by a new test).
  - **Geometry is now MEASURED, and it found two real bugs.** The hook ran
    end-to-end against a loopback disk (WSL2, util-linux 2.37): a 12 GiB FAT
    partition was carved to 10 GiB plus a 2 GiB f2fs partition labelled
    `lsl-persist`, which mounted, accepted an `upper/`, and was left untouched
    by a second run. Two things that had been assumed turned out to be wrong:
    - **`sfdisk` `size=` is in SECTORS**, not KiB, in both directions. The
      hook read the output in sectors and wrote the input in sectors, so its
      arithmetic was right — but only by luck, and nothing recorded the
      assumption. The test now asserts the units against measured bytes.
    - **Partition nodes are not `<disk>N`.** A loop device's first partition
      is `/dev/loop0p1`. The hook now probes for the node (`lsl_part_node`)
      instead of concatenating a suffix.
  - **The loop-pinning check was ineffective.** It used
    `losetup -a | grep <disk>`, but a loop over an ISO *file on that stick*
    reports only the file path — never the disk — so the one case that matters
    most slipped through. It now reads the kernel's `holders/` link, which
    names whatever actually has the partition open.
  - **Booted in a real casper under QEMU/KVM — the timing premise holds, and
    the boot found two blockers.** `tests/qemu-f2fs-provision-test.sh` builds a
    FAT stick from a real Mint 22.3 ISO, repacks its initrd with the hooks, and
    boots it under KVM.
    - **The premise is confirmed.** The hook runs inside `/scripts/nfs-premount`
      at ~3.4 s and the boot medium is **not mounted** at that point — no
      `/cdrom` or `vda1` mount precedes it, and casper's own `loop0` appears
      afterwards (3.82 s). So `casper-premount` really is early enough to
      repartition the stick. The boot also reached a full Cinnamon desktop,
      which is the proof that injecting the hook does not break the boot.
    - **f2fs is a MODULE in the Mint kernel, not builtin.** The first boot
      logged `no f2fs driver in this kernel` and skipped — the hook never tried
      to load the module that was sitting in the initrd's `early3` cpio. It now
      calls `modprobe f2fs` (kmod is present and decompresses the `.ko.zst`
      itself); a re-run logged `modprobe f2fs: loaded`.
    - **`fatresize` and `mkfs.f2fs` are NOT on a stock Mint ISO** — not in the
      rootfs, not in `pool/`. Only `sfdisk` can be staged out of the image.
      `DESIGN-F2FS-PERSISTENCE.md` §6.1 claimed otherwise, having checked a
      machine's live root where those packages were installed; that table is
      corrected. **The feature is therefore safe but not yet functional** — the
      hook degrades to a logged no-op, and §4.3 records the three ways to
      source the two missing binaries.
  - **The tools now come from the Ubuntu archive, and the staging is PROVEN.**
    `src/f2fstools.rs` resolves each package from the suite's `Packages` index
    (so a version bump cannot break it), downloads the `.deb`, reads it as an
    `ar` archive, and extracts the binary plus the six sonames casper's initrd
    lacks. Proven two ways: `ldd` resolves all 12 of `fatresize`'s dependencies
    from the staged set plus the initrd's own, and `fatresize --help` runs in a
    chroot built from **only** those libraries — no host library reachable. No
    helper binaries are needed (`dmidecode` is probed for the disk's model only
    and its absence changes nothing).
  - **The tools ride as cpio members, not a tarball.** casper's initrd has
    `gzip` and `cpio` but **no `tar`**, and its busybox has no `untar` applet —
    a run that shipped a tarball logged `tar: not found` and skipped. Each file
    is now a cpio member at its final path, so the kernel's own unpacker does
    the work and the hook only exports `PATH` and `LD_LIBRARY_PATH`.

### Fixed

- **The FAT BPB was read at the wrong offset, so the anti-corruption guard
  never worked.** `bin/lsl-f2fs-resize` read 4 bytes at **offset 19** and
  compared them against a partition size. Offset 19 is the **volume serial
  number** — a random 32-bit value fixed at `mkfs` time — not the sector count,
  which lives at **offset 32**. Measured: offset 19 returned the identical
  constant `16252928` for filesystems of 512 MiB, 1 GiB and 2 GiB, so the check
  compared a volume ID against a partition size and could never mean anything.
  A test now pins offset 32 in both the hook and the operator tool, and pins
  the guard's ordering (`fatresize` → verify BPB → repartition).
- **`fatresize` can block the boot on a prompt.** Below the FAT32 cluster limit
  it offers an `OK/Cancel:` FAT16 conversion; with no tty it takes EOF and
  aborts (measured: exit 1, filesystem untouched). The hook now answers `no`
  and refuses any carve that would cross the FAT32 limit, rather than relying
  on an unanswerable prompt.
- **The partition scan missed virtio disks.** `/dev/vd*` was absent from the
  content probe, so under any virtualisation the hook found no medium at all.
  The wait-for-disk logic also had to come first: measured, the hook runs at
  ~3.4 s while `virtio_blk` announces the disk at ~12 s, so the probe must wait
  for the disk and its partition table rather than assume they exist.
- **`grep … | head -1` silently lost the match.** A diagnostic `grep -c` in the
  guest reported 1 matching line while `grep … | head -1` printed nothing — head
  closes the pipe and grep dies on `SIGPIPE` before flushing. Replaced with
  `sed -n '1p'` throughout, which reads the first line and stops.

- **Firstboot reboot now asks WHERE to land, not just whether.** The
  end-of-firstboot dialog was `Reboot now` / `Reboot later`, and `Reboot now`
  was a plain `systemctl reboot` — which falls through to whatever the
  firmware boot order picks first, normally Windows. That made the one moment
  a user most wants to go back into lsl-usb the one moment the dialog could
  not offer it. It now offers **Reboot to lsl-usb** (`efibootmgr -n
  <BootCurrent>`, the same trick `bin/lsl-shutdown-gui` already uses for its
  "Reboot to USB" option) / **Firmware boot menu** (`systemctl reboot
  --firmware-setup=auto`) / **Later**, mirroring the reboot dialog
  `lslsetup.exe` already shows on the Windows side.
  - The user session still only *records* the choice (`reboot-target`, next to
    the existing `reboot-now` / `reboot-cancel`); root stays the reboot
    authority. `reboot_approval_pending()` is unchanged, so the "dialog
    reappeared on boot 2" fix is untouched.
  - The firmware row is only offered when the running systemd knows
    `--firmware-setup`, so no button is ever rendered dead. Every branch
    degrades to a plain reboot — no `efibootmgr` (legacy BIOS/CSM), or a
    systemd that refuses the flag — rather than stranding a user who already
    approved the reboot.
  - Dismissing the dialog, or any unrecognised label, defers. It can never
    reboot on its own.
  - Not verified on hardware; covered by `misc/test-reboot-choice-smoke.sh`.

- **F2FS persistence, Linux side (`DESIGN-F2FS-PERSISTENCE.md` P1+P2+P3).**
  `/home` can now live on a real F2FS partition instead of a RAM upper that
  vanishes at reboot. Three parts, and all three are needed:
  - **P1** `bin/lsl-f2fs-provision` formats a partition **by label**
    (`lsl-persist`) and **never repartitions** — a stick must already have a
    second partition, created by Rufus or by hand. It refuses to reformat
    anything carrying a different filesystem without `--force`.
  - **P2** `initramfs/lsl_f2fs_scrub.sh` runs as a casper-premount hook,
    strictly before the overlay mounts, and removes machine identity from the
    persistent upper — the netplan/NetworkManager profile (which carries a
    cleartext WPA PSK), hostname, hosts, machine-id, resolv.conf, casper.conf,
    lightdm.conf, and the snakeoil key pair. Mounts read-only first, and finds
    the device **by label** so a partition another tool made is never hijacked.
  - **P3** `bin/lsl-regen-identity` rewrites those paths for *this* boot. **P2
    without P3 is not a fix**: deleting a file unmasks the lower's stale copy
    rather than producing a correct one (`WHYFAIL12`).
  - Wired into both initrds (`build.sh` and the Rust `repack_initrd`) because the
    hook is *sourced* by casper and uses `return`.
  - **Not verified on hardware.** The scrub's static checks run in
    `tests/f2fs-scrub.tests.sh`; the design's own QEMU ordering and two-machine
    tests are not written, so this must not be read as "works on a boot".

- **A persistence page in the wizard** (`DESIGN-PERSISTENCE-PANE.md`), at page 4
  between "system" and "wifi". Four backends — none / squashfs (default, what
  the tree always did) / btrfs / f2fs — plus a bounded size selector and
  cache-on-tmpfs. Reaches Linux through `LSL_PERSIST`, `LSL_HOME_BTRFS_MIB` and
  `LSL_CACHE_TMPFS` in `lsl-usb.env`, with matching `--persist`, `--persist-mib`
  and `--cache-tmpfs` flags so the FINISHED page's command line reproduces it.
  **Non-destructive end to end**: there is no erase control, and nothing on the
  page can repartition or format.

### Fixed

- **The main UEFI boot entry never carried the HDD-mirror initrd.**
  `write_efi_bootdir` wrote `grub.cfg` from `uefi_cfg_direct_user` regardless
  of whether the HDD-mirror initrd had been installed — that template was
  `#[cfg(test)]`, because the mirror entry was only assembled inline for the
  extra "Boot to RAM" stanza. So a stick built with "copy the squashfs layers to
  the HDD" ticked booted from the internal disk on BIOS (grub4dos `menu.lst`
  had it) and from the **USB** under UEFI (`grub.cfg` did not). Found while
  wiring the F2FS path, which needed the same entry to carry a second initrd;
  `uefi_cfg_direct_hddmirror_user` is now a production template and
  `write_efi_bootdir` picks the right initrd list.

- **The "first boot complete — Reboot now / Reboot later" dialog came back on
  every later boot.** `reboot_approval_pending()` treated "the flag dir exists and
  no decision file is in it" as *approval is pending*, but `/run` is tmpfs and
  `onboot.sh:50` recreates `/run/lsl-firstboot` on **every** boot for the shared
  telemetry traces. After the first boot finished, the next boot brought the dir
  back empty — indistinguishable from "firstboot is waiting right now" — so
  every later login re-showed the end-of-firstboot dialog. An empty flag dir is
  the *absence* of a decision, which is the normal, permanent state on any boot
  that never reached the finale. The gate now requires positive evidence:
  `lsl-firstboot.sh` publishes `$FLAG_DIR/awaiting-approval` while
  `schedule_reboot_on_approval()` actually blocks, and withdraws it on both
  exits (reboot and defer), so a fresh login during a genuine wait still gets the
  dialog. Covered by two new tests (consumer and producer side); the consumer one
  was confirmed to fail against the old predicate.

- **`uphome` and `lsl-flush-home.sh` would have fought the f2fs backend.** An f2fs
  upper is *already* persistent, so packing the merged home into `home.sfs` would
  duplicate every change into two places — and on the next boot the squashfs copy
  (the overlay **lower**) would shadow the partition's newer content. Both now
  detect the `f2fs` mode and say there is nothing to flush.

- **Every build trace was blank (WHYFAIL16).** The build stamp read its version
  from `<bundle>\VERSION` and `unwrap_or_default()`-ed a failed read to the empty
  string — but the default (nofmt) path has no bundle at all, so *every* stick
  got a blank version line and `bin/lsl-diag.sh`, whose job is "which build is
  failing?", printed an empty section, silently. The compiled-in
  `CARGO_PKG_VERSION` is now the fallback (it cannot be empty and needs no staged
  file), the missing file is **logged** rather than swallowed, `/cdrom/VERSION` is
  written (the diagnostic read it; nothing ever created it), the stamp carries the
  git revision, and `lslsetup --version` exists so the exe is self-describing.

- **btrfs online growth missed the loop device.** The backing file grew but the
  loop device did not, because `lsl-btrfs-growd` refreshed only the *first*
  attached loop (`findmnt … | head -1`) — a stale loop from a crashed boot keeps
  the old size cached, so growth silently missed while the file grew every 60 s.
  `lsl_refresh_image_loops` is now one shared implementation in
  `bin/lsl-common.sh` (used by both `onboot.sh` and the daemon) that refreshes
  *every* attached loop and surfaces `losetup -c` errors instead of discarding
  them. The size verification is no longer gated behind `blockdev` — when it did
  not run, the cycle ended with no warning at all — and the re-loop recovery no
  longer re-mounts with `-o loop` (which could attach a second device and strand
  the first) nor resizes `/home` where an overlay may be stacked.

### Changed

- **`lsl-mount-home.sh` branches on `LSL_PERSIST` rather than on where the data
  dir lives.** `none` reuses the existing RAM-only path (so the pane and
  Boot-to-RAM cannot drift apart), `f2fs` reuses the overlay shape with a
  persistent upper, and `btrfs` takes the loop-image path even on a stick. Any
  f2fs failure degrades to a RAM upper with a warning rather than to no `/home`.
  An unknown `LSL_PERSIST` falls back to `squashfs` **and says so**.

- **Squashfs compression: one constant at level 15.** The tree passed
  `-Xcompression-level 22` at seven call sites — past libzstd's regular range
  (≥20 is `--ultra`), past `mksquashfs`' own documented `1..9`, buying nothing
  over 19, and not finishing inside the measurement window on real content. All
  of them now read `LSL_SQUASHFS_COMPRESSION_LEVEL` from `bin/lsl-common.sh`
  (default **15**): 5.7 % smaller than level 9 for 6× the write time, where 19
  needs 14× for the last 0.7 points. Note this deliberately overrules
  `FINDINGS-COMPRESSION.md`'s own recommendation of 9, which weighted write time
  alone; **boot-time decompression was never measured and favours lower levels**,
  so the constant is overridable and that measurement is still the open question.
  `install.sh` gained a guarded source of `lsl-common.sh` and now sets the level
  on `home.sfs` too, which had been relying on the tool default.

- **The LKDDb base URL is overridable.** `LSL_LHW_BASE_URL` (and `-BaseUrl` on
  `tools/build-hw-cache.ps1`) points `install.ps1`, `lslsetup.exe` and the cache
  builder at a mirror of the linux-hardware.org device pages, whose HTTP 429 rate
  limiting makes both the bundled cache and the live rating fragile. The cache file
  format is unchanged, so a mirrored cache drops straight in, and the 10 s
  crawl-delay still applies. Standing up the mirror host itself remains open — it
  is infrastructure outside this repo.

## [0.1.1] - first successful lslsetup.exe firstboot

First release verified end-to-end on real hardware: `lslsetup.exe` wrote a stick
with the non-destructive (nofmt) path, the stick booted, and the first-boot
install completed.

### Fixed

- **kitty would not start.** `misc/kitty.conf` failed to parse:
  `tab_powerline_style no` is not one of kitty's `angled`/`round`/`slanted`
  choices, so kitty aborted configuration with an "Errors parsing configuration"
  dialog and never became usable. Four further keys were WT-isms with no kitty
  equivalent and were dropped silently (`padding_left/right/top/bottom`,
  `font_subpixel_antialias`, `active_tab_title_format`); they are now
  `window_padding_width`, gone, and `active_tab_title_template`, and the
  `ctrl+zero` shortcut (kitty spells the key `0`) is `ctrl+0`. Verified against
  kitty 0.32.2's own config loader: the corrected file parses with zero bad
  lines. **`lslsetup` also never shipped the file** — `misc/` was not in
  `FIRSTBOOT_TOOLKIT`, so `config.sh`'s `install_lsl_kitty_conf` skipped it
  silently and kitty ran unconfigured; `misc\kitty.conf` is now embedded and
  `misc` is copied in the bundle path too, with a regression test.

- **The panel lost every pinned app, kitty included.** `bin/lsl-pin-favorites`
  stripped `[]`/quotes/commas from `gsettings get org.cinnamon favorite-apps`
  and then read the result line-wise. `gsettings` prints an `as` array on a
  **single line**, so the whole existing favorites list became one token:
  `['Calculator Calendar xed ...', 'kitty.desktop', 'brave-browser.desktop']`.
  `XApp.Favorites` cannot resolve that element and Cinnamon drops it silently,
  so Calculator/Calendar/xed/mintinstall/cinnamon-settings/terminal all vanished
  along with the kitty pin - and every re-run re-read and preserved the damage.
  A new `parse_gsettings_array()` splits on commas, and a self-heal splits
  space-joined elements so sticks already carrying the corruption repair
  themselves. Regression test added. See `WHYFAIL17.md`.
- **A Mint stick booted as `ubuntu`.** casper's built-in live identity is
  `USERNAME="ubuntu"` / `HOST="ubuntu"` (`/etc/casper.conf`), and Linux Mint only
  boots as `mint` because *its own GRUB* passes `username=mint hostname=mint`
  (21.3 onward). `lslsetup` generates the cmdline itself and passed neither, so a
  Mint image showed the Mint splash and then ran a `/home/ubuntu` session. The
  generated entries now derive the live user from the ISO name (Mint -> `mint`,
  Ubuntu family -> `ubuntu`, anything unverified -> no parameter rather than a
  guess) and pass it in every menu and `grub.cfg` entry.

- **Four scripts still invented the username `mint`** — `bin/detect-wsl`,
  `bin/persist-wifi.sh`, `bin/add-steam-libraries`, and `bin/lsl-shutdown-gui`
  (which unmounted a literal `/home/mint/.cache`). All now call the shared
  `lsl_desktop_user` resolver and skip with a message rather than writing to a
  guessed home.

### Added

- `RULES.md` — every "rule worth keeping" from the WHYFAIL and design documents,
  collected in one place (62 source blocks, 49 generalisable rules) with an index
  of the documentation gaps.
- `WHYFAIL12.md` — machine identity lives in the overlay upper (a netplan Wi-Fi
  profile with a cleartext PSK, `hostname`, `lightdm.conf`, `machine-id`). Harmless
  today because that upper is RAM; becomes live the moment persistence is added,
  and applies to every persistent live USB, not just this one.
- `rust9x/lslsetup/WHYFAIL15.md` — the fix was in `bin/`, but every shipped
  `lslsetup.exe` embedded the old copy: the firstboot toolkit is embedded with
  `include_str!`, and a committed/prebuilt exe keeps the bytes it was compiled
  with. `assets/toolkit_sources.sha256` (written by
  `misc/build-toolkit-manifest.sh`) now pins all 36 embedded sources; `build.rs`
  fails the build on drift, `misc/check-toolkit-freshness.sh` is the by-hand/CI
  gate (also asserting the manifest covers every embedded source), and `build.sh`
  and CI run it next to the z0 check. Same guard shape as `WHYFAIL10`.
- `WHYFAIL16.md` — every build trace is blank: the version is read from a file the
  nofmt path never puts on the stick, and `unwrap_or_default()` hides the failure.
  So a stick cannot report its own build, which is what `lsl-diag.sh` exists to
  ask.
- `WHYFAIL17.md` — the panel lost every pinned app because
  `bin/lsl-pin-favorites` parsed `gsettings get` output line-wise; an `as` array
  arrives on one line, so the whole favorites list collapsed into one
  unresolvable entry. Companion to `WHYFAIL15`.
- `FINDINGS-COMPRESSION.md` — the six `mksquashfs` call sites, why
  `-Xcompression-level 22` is outside the documented range, and what level 9 vs 19
  actually buys on real layer content (~6 %, for a large time cost).
- `DESIGN-F2FS-PERSISTENCE.md`, `DESIGN-PERSISTENCE-PANE.md`,
  `DESIGN-BOOT-TO-RAM-VARIANTS.md` — design notes for persistence on F2FS, the
  wizard page that would drive it, and every block-layer option for Boot-to-RAM
  (with what was **measured** marked apart from what was merely read).
- `rust9x/lslsetup/WHYFAIL13/14/16.md`, `WHYFAIL9/11.md`, `WHYFAIL15.md`,
  `WHYFAIL17.md`, `FRAGILE_HOME.md` — post-mortems committed.

### Changed

- `VERSION`, `Cargo.toml` and `Cargo.lock` are all `0.1.1`.

### Notes

- **The repository has two WHYFAIL series**: `WHYFAIL5/6/7/9/11/12/17` at the root and
  `WHYFAIL13/14/15/16` under `rust9x/lslsetup/`. Numbers 1-4, 8 and 10 exist in
  neither; `WHYFAIL8` and `WHYFAIL10` are cited by other documents but were never
  written. `README.md` now says so.
- **Nothing in the design notes is implemented.** They are designs, with their
  unverified claims labelled as such.
- A stray `$null` file (a Windows redirect artefact) and `.commandcode/` local
  tool state are now in `.gitignore`.

## [Unreleased]

### Known issues
- **The Persistence pane has NO destructive control; "Erase this stick" was
  removed (`DESIGN-PERSISTENCE-PANE.md` §2.6).** The checkbox was introduced to
  serve repartitioning, and §9.2 then showed the space can be obtained without any
  destruction (two partitions at format time, or a filesystem-aware shrink on first
  boot) — so it had no remaining justification. Deleting it removes the pane's only
  data-losing code path, which no confirmation dialog can equal. Formatting stays
  where it belongs: the Rufus flow, where **Rufus** asks the user itself. Also
  dropped with it: the `erase_stick` harvest field, the `--erase-stick` flag and
  the destructive-path test (replaced by a stronger non-destruction assertion).
- **HARD CONSTRAINT on the Persistence pane: the `eatmydata` option enables the
  `eatmydata` utility and nothing else (`DESIGN-PERSISTENCE-PANE.md` §2.8).** It
  must not be used as a licence or an excuse to install anything the user did not
  ask for, and must never be wired to partitioning, formatting or any other disk
  write. Those live behind "Erase this stick" (§2.6), which is the *only* control
  permitted to destroy data. **Formatting a drive is never funny, and a tick on
  one destructive checkbox is not consent to a different destructive act.** The
  package is inert (a 21 KB wrapper + a 35 KB `.so`), so the option is exactly one
  `LD_PRELOAD` for two install steps; any other observable effect is a defect.
  **Do not implement malware.**
- **Persistence-pane design: an `eatmydata` speed option was requested and is
  now specified (`DESIGN-PERSISTENCE-PANE.md` §2.8).** It wraps the sync-heavy
  first-boot steps — `dpkg`/`apt` (`bin/squashfs_config.sh:9,96,99`), the
  `mksquashfs` layer build (`bin/uproot:334`), the layer copy. Default off,
  because it trades durability: `libeatmydata` makes the sync calls *return
  success anyway*, so a power loss mid-install leaves a package database the
  kernel was told was committed. Its manpage CAVEAT applies to us directly —
  `uproot` chroots into the target image (`uproot:526-553`) and the architecture
  can differ from the host, so `libeatmydata1` must be installed *inside the
  chroot* for the target arch, and the option must verify the preload actually
  took effect or it silently does nothing.
- **The destructive checkbox was misnamed "EatMyData" and has been renamed
  "Erase this stick".** `eatmydata` is a real package that *speeds up* writes by
  disabling fsync; using its name for a checkbox that destroys data inverted its
  meaning and made the genuine `eatmydata` option (§2.8) unnameable.
- **The Persistence-pane design cannot use a Windows FAT resize, and the plan
  has been revised accordingly (`DESIGN-PERSISTENCE-PANE.md` §9).** Windows will
  not shrink *or* extend a FAT32 volume (Disk Management greys out *Shrink*;
  `diskpart` returns "the file system does not support it"), so reserving space
  for an F2FS partition by shrinking the FAT is not implementable. The design now
  **creates an unformatted partition and has firstboot format it** — and since
  `lslsetup` already opens `\\.\PhysicalDriveN` and writes raw sectors, that
  extends existing capability rather than adding a new one. Also recorded: why GPT
  is refused for BIOS (the grub4dos stage1 needs sectors 1-15, which the GPT
  header and entries occupy — §9.1), and that the destructive confirmation is a
  **second checkbox**, not the console `type OK` idiom.
- **Compression settings are inconsistent and one is out of the documented
  range (`FINDINGS-COMPRESSION.md`).** Six `mksquashfs` call sites use three
  different settings; four pass `-Xcompression-level 22` while `mksquashfs -help`
  documents `1 .. 9`. Measured: 22 is accepted and honoured (not clamped) but
  buys **nothing** over 19, and 9->19 buys only **~6 %** on real layer content
  for a large time cost - none of which counts boot-time *decompression*, likely
  the real constraint. Recommendation (not applied): standardise on the
  documented default 9, from one shared constant.
- **Machine identity lives in an overlay upper, and nothing scrubs it
  (WHYFAIL12).** On a live Mint stick, `/cow/upper` (casper's RAM root overlay)
  holds `/etc/netplan/90-NM-<uuid>.yaml` pinned to `match: name "wlp0s20f3"`
  **with the WPA PSK in cleartext**, plus `lightdm.conf`/`casper.conf`/`hostname`
  pinned to `ubuntu` (greeter loop if the next image uses another name),
  `machine-id`, `resolv.conf` and a snakeoil TLS pair. Not a live bug today: that
  upper is RAM and `uproot` packs a different, fresh one, so none of it is baked
  into a layer. It becomes live the moment persistence is added - and any
  persistent live USB has this, not just ours (stock casper mounts a `casper-rw`
  device as `/cow` and uses it as the upper; mkusb/Rufus/pendrivelinux do the
  same).

  Fix, by mechanism (earlier drafts of WHYFAIL12 got this wrong twice): a *packed*
  filesystem is filtered at pack time (`mksquashfs -e`); a filesystem that is an
  *overlay upper* is scrubbed as a plain directory before the overlay mounts. For
  casper the window is a `casper-premount` hook - which we already own and
  already use for the HDD mirror (`build.sh:154 repack_initrd`;
  `lslfiles.rs:1724`). Read from casper's own `scripts/casper`: our hook runs at
  `:926`, `/cow/upper` is created at `:551-583`, and the root overlay is mounted
  at `:683` - so the hook is strictly before it. Scrubbing alone unmasks the
  *lower's* stale copy, so each scrubbed path also needs a per-boot regenerator
  (`onboot.sh`'s `lsl_merge_fstab` is the pattern). See `WHYFAIL12.md` section 6.

### Changed
- **Layer stacking is now alphabetical, and the filenames carry the order.**
  The boot menus no longer pass `layerfs-path=`, so casper takes its default
  `*.squashfs` glob branch and stacks every layer it finds in lexical order,
  greatest on top. The names encode that order:

  | rank | name | role |
  |---|---|---|
  | 1 | `filesystem.squashfs` | base (distro image) |
  | 2 | `filesystem_z0_firstboot.squashfs` | first-boot stub |
  | 3+ | `filesystem_z<ts>.squashfs` | appended layers, newest last |

  `uproot` now appends a flat `filesystem_z<ts>.squashfs` — no inherited dotted
  stem, no chain to extend, and no boot config to rewrite (a new layer goes live
  simply by existing). `install_lsl_files` writes only the underscore stub name;
  the dotted `filesystem.z0.squashfs` twin existed solely to be nameable by
  `layerfs-path=` and sorted into the wrong slot under a glob. A superseded
  append is reaped by name (anything sorting below the newest), which also fixes
  the old `sort | tail -n1` stem selection that picked the wrong link on a
  multi-link chain. See WHYFAIL14.
- **HDD mirror is a single pre-merged layer.** `LAYERFS_PATH` is kept for the
  mirror only - it is the one casper input that can name a layer on a device
  other than `/cdrom`, so the glob branch cannot replace it. With the dot-walk
  gone, a dot-free name resolves to exactly one file, so
  `bin/lsl-copy-sfs-hdd.sh` now overlays base + stub + appends into one
  `filesystem_zmerged.squashfs` and refuses to publish it unless the merged tree
  contains `/sbin/init`. `initramfs/lsl_hdd_mirror.sh` verifies that file;
  `tests/qemu-hdd-mirror-test.sh` builds it the same way. live-boot (Debian) is
  unaffected and keeps the separate layers.

### Fixed
- **A Mint stick booted as `ubuntu`: the generated kernel cmdline never named
  the live-session user.** casper's built-in live identity is
  `USERNAME="ubuntu"` / `HOST="ubuntu"` (`/etc/casper.conf` in the casper
  source), so a distro that does not override it on the cmdline boots as
  `ubuntu` with `$HOME=/home/ubuntu` - whatever logo and `.disk/info` the ISO
  carries. Linux Mint passes `username=mint hostname=mint` from 21.3 on
  (before 21.3 it passed nothing and really did boot as `ubuntu`; see
  linuxmint discussion #289). LSL **generates** the cmdline instead of using
  the ISO's own GRUB, and passed neither parameter - so a Mint image showed
  the Mint splash and then a `/home/ubuntu` session, which is also why the
  WHYFAIL5/9 logs read `user=ubuntu` and `root@ubuntu:`.

  `nofmt.rs` now derives the live user from the ISO name/`.disk/info` and
  passes `username=`/`hostname=` exactly where the distro's own GRUB does
  (Mint -> `mint`; the Ubuntu family -> `ubuntu`, which is casper's default
  named explicitly). Unverified distros (Zorin, antiX, Debian) get **no**
  parameter rather than a guessed name - the same "never invent a username"
  rule as `lsl_desktop_user`. Wired through every generated entry: the
  grub4dos direct/ramclone/hddmirror stanzas, the `efi\grub\menu.lst`
  mirror, the signed-GRUB2 `grub.cfg` entries, and the extra-ISO loopback
  entry.
- **Four scripts still invented the username `mint`.** `lsl_desktop_user`
  (bin/lsl-common.sh) exists precisely so nothing guesses the live-session
  user - the live home is `mint` on Mint, `ubuntu` on Ubuntu/its flavours
  (and casper's default when a distro names none, see the entry above) -
  and WHYFAIL13 records what the old `|| u="mint"`
  fallback cost: every `$HOME`-targeted install silently wrote to a home that
  did not exist. The rule was applied in `lsl-common.sh` but four callers kept
  their own copy with the guess intact: `bin/detect-wsl` and
  `bin/persist-wifi.sh` (both resolved the user, then fell back to `mint`),
  `bin/add-steam-libraries` (same), and `bin/lsl-shutdown-gui`, which
  unmounted a literal `/home/mint/.cache` on every HDD-mode shutdown. All four
  now call the shared resolver and skip (with a message) rather than write into
  a guessed home; the shutdown unmount is a no-op on a non-Mint stick instead
  of pointing at another user's directory.
- **kitty would not start: the shipped `misc/kitty.conf` was invalid, and the
  installer never staged it.** `bin/config.sh`'s `install_lsl_kitty_conf` reads
  `$REPO_ROOT/misc/kitty.conf` at first boot and silently skips when it is
  missing, but the non-destructive installer writes `/cdrom` from its embedded
  `FIRSTBOOT_TOOLKIT` list only - which had no `misc/` entry - so on a
  nofmt-built stick the config was never copied and kitty ran with its built-in
  defaults. Worse, the repo's conf could not be loaded even when present:
  `tab_powerline_style no` is not one of kitty's `angled`/`round`/`slanted`
  choices, so kitty aborts configuration with an "Errors parsing configuration"
  dialog and never becomes usable. Four more keys were WT-isms with no kitty
  equivalent and were dropped silently (`padding_left/right/top/bottom`,
  `font_subpixel_antialias`, `active_tab_title_format`); they are now
  `window_padding_width`, gone, and `active_tab_title_template`, and the
  `ctrl+zero` shortcut (kitty spells the key `0`) is `ctrl+0`. `lslsetup` now
  embeds `misc\kitty.conf` in `FIRSTBOOT_TOOLKIT` and copies `misc` in the
  bundle path too, with a regression test asserting the conf is present and
  free of the fatal/unknown options. Verified against kitty 0.32.2's own config
  loader: the corrected file parses with zero bad lines; the old one raised
  `ValueError: The value no is not a valid choice for tab_powerline_style`.
- **Choosing "use an existing Live USB" still asked for a target USB to install
  on.** The three "main source" sections on the ISO page (Download Fresh, Local
  ISO, existing USB) are separate `WS_GROUP`s - each section's first radio
  carries `WS_GROUP` - so Win32 only auto-unchecks siblings *within* the clicked
  section. With a matching local Mint ISO present, its "main" radio is
  pre-checked at build time, so clicking "D: Lexar" left **both** checked. The
  harvest then broke the tie in favour of the ISO and silently discarded the
  click, so the run fell through to the ordinary ISO install - which then
  demanded its own target pick ("No target USB was selected on the INSTALL
  page") even though the user had just named a stick. The existing build-time
  guard could not help: it only avoids *pre-checking* reuse, and the conflicting
  state was created by the click, not by the default. An explicit click on any
  source row now clears the other source rows, so the last explicit click wins.
  Three new GUI unit tests cover the kind set, reuse-over-a-pre-checked-ISO, and
  two sticks.
- A prune glob of `filesystem_z[0-9]*` also matched
  `filesystem_z0_firstboot.squashfs` and deleted the first-boot stub, which
  carries `lsl-firstboot.service`. Every append selection now pins the 14-digit
  timestamp width, and a regression test asserts the stub survives a prune.
- `repoint_layerfs_refs` now *strips* a stale `layerfs-path=` from the boot
  configs instead of repointing it. A stick written by an older installer still
  carries the flag, and under the flattened naming it named a file that no longer
  existed - casper would have panicked on the next boot with
  `File system layers are missing`.
- `live-ramclone` resolves its layer set by globbing `/cdrom/casper/*.squashfs`
  in sorted order when `layerfs-path=` is absent, so Boot-to-RAM backs the same
  layers casper will stack.

### Added
- `misc/check-stick-drift.sh`: compares the repo's hand-written shell
  (`bin/`, `misc/`, `onboot.sh`, `install.ps1`) against a mounted stick and
  reports per-file drift. Most fixes land twice - once in the repo, once by hand
  in the live `/cdrom` - and each direction fails independently and silently: a
  repo-only fix leaves the bug on the device that shows it, a stick-only fix gets
  re-shipped-over by the next `build.sh`/`lslsetup` run. This is the sibling guard
  for the shell that is *not* embedded in a blob (what `check-z0-freshness.sh`
  does for the z0 layer). Normalises CRLF before comparing, so a Windows
  checkout does not read as drift - the same CRLF class that has broken
  `LSL_DATA_DIR` detection and the bash-log hook. Exits 0 when no stick is
  mounted, so it stays runnable on the dev box. Verified against a synthetic
  stick: identical, CRLF-only, missing-file and stale-file cases all classify
  correctly.
- `lsl-reclaim-win-swap.sh` (opt-in, `LSL_RECLAIM_WIN_SWAP=1`): after verifying a
  clean Windows shutdown (read-write NTFS and no `hiberfil.sys`), rename Windows's
  `pagefile.sys` and each WSL2 distro's `swapfile.vhdx` to temp files and reuse that
  space as the backing device for a zram (compressed) swap tier. The renamed temp
  files are deleted at Linux shutdown (returning the space to Windows) and a
  best-effort Windows Scheduled Task also deletes them on the next Windows boot.
  Wired into `onboot.sh` and released via `lsl-reclaim-win-swap.service`, and
  exposed as an opt-in checkbox in `install.ps1` (WinForms) and `install-xp.hta`.
- Windows installer wizard (WinForms): ISO selection with Everything discovery,
  flatpak app preload (detected from installed Windows apps + recommended apps
  like FSearch), WSL VHDX paths, `LSL_DATA_DIR` (pre-filled), per-network wifi
  picker, reuse-an-existing-USB, Everything index export (EFU), and
  auto-install of Everything (portable, Authenticode-verified).
- `lsl-find` / `lsl --find` / `lsl --efu`: instant search of the exported
  Everything index on Linux (with `-l` long format showing sizes).
- `lsl-toram.sh`: lazy toram (copy root to RAM, pivot, remove the USB), wired
  into `lsl-shutdown-gui` as "Load to RAM + remove USB".
- Boot to RAM now writes two menu entries: the existing one (persistent home)
  plus `(Boot to RAM, no persistence)`, which passes `lsl_home=tmpfs` so
  `onboot.sh` mounts a RAM-only `/home` (rebuilt each boot from `/etc/skel`);
  `uphome` / `lsl-flush-home.sh` skip a tmpfs home so nothing is flushed.
- `lsl-precache.sh` + `lsl-precache-profile.sh`: page-cache warmup (hot files
  first, full-image when it fits, memory floor, bfq scheduler).
- `lsl-boot-time.sh`: per-boot measurement with trend + precache suggestion.
- `lsl-rusttools.sh` / `lsl-appimages.sh`: statically-linked CLI tools and
  curated AppImages, with ELF verification and a URL cache.
- `lsl-flatpak-fat.sh`: opt-in FAT-hosted flatpak installs via the
  `fat_linux_meta_fs` FUSE layer.
- First-boot recipe: apt tools, snap unpin (`LSL_SNAP_SUPPORT`), flatpak refs,
  nvim AppImage (ELF-verified), rust tools, AppImages.
- First-boot finale: backs up `/home` to its permanent location (`uphome` -
  USB bakes `home.sfs`, HDD syncs btrfs) as a visible `Back up home` step,
  then waits for the user to approve the reboot instead of rebooting at once -
  a per-session dialog (bundled GTK fallback, else zenity) with Reboot now /
  Reboot later and no timer: it never reboots on its own (`LSL_FIRSTBOOT_REBOOT`,
  `LSL_FIRSTBOOT_FLAG_DIR` to tune/skip; `LSL_FIRSTBOOT_REBOOT_TIMEOUT=0`
  keeps the explicit reboot-immediately escape hatch).
- Layer-stacking fix: casper only stacks the chain the kernel cmdline NAMES
  (it strips dot-suffixes upward from `layerfs-path`), so `uproot`'s appended
  `filesystem.z0.<ts>.squashfs` dot-siblings never went live (five 761 MB
  layers sat inert). Appends now EXTEND the newest chain name and repoint
  `layerfs-path` in `menu.lst` / `EFI/BOOT/grub.cfg` / `efi/grub/menu.lst`;
  merge reverts the refs to plain z0 and clears the chain; a failed mksquashfs
  no longer leaves a partial chain link behind.
- Boot + dialog telemetry that survives reboot: the progress/reboot dialogs
  trace every launch (including the previously silent "already complete"
  exit) to `/run/lsl-firstboot/dialog-trace.log`, flushed to the stick by
  the firstboot finale; `lsl-diag.sh` captures the dialog journal tags,
  `loginctl` sessions with `Since=`, live dialog processes, and the
  dialog/boot-time logs; `lsl-boot-time.sh` now ships on the stick (the
  autostart entry referenced it, but it was never installed) and records
  `user@display` with a `/proc/uptime` fallback when no boot stamp exists.
- Test harness (PowerShell, ~55 assertions) + bats (~77 tests) + CI + release workflow.
- `VALIDATION.md` (real-hardware checklist), `VERSION`, `CHANGELOG.md`.
- `bin/lsl-gui`: working GUI launcher (GTK/zenity/terminal fallback, no
  wezterm or catalog dependency); `config.sh` installs an `lsl-gui.desktop`
  entry for it when staged. The old terminal launcher is now `bin/lsl-tui`
  (it never was a GUI) with its own `lsl-tui.desktop` entry; both entries
  are `-r`-gated so un-staged programs are never advertised.
- `bin/lsl-restore-stick-from-repo.sh`: re-stage repo-managed files onto a
  damaged stick (refuses to run against an empty repo).
- Installer "Turn off Windows Fast Startup / hibernate" checkbox
  (`powercfg /h off`, default off, undo with `powercfg /h on`) in
  `lslsetup.exe` (wizard + `--fast-startup-off`), with a note explaining it
  un-blocks the pagefile reclaim; the installer warns loudly when the
  reclaim is armed while `hiberfil.sys` still exists.

### Changed
- **When only one target drive is available, it is now selected by default.**
  `install.ps1`: the `-NoGui` console prompt (`Select-ExistingUsb`) accepts a
  plain Enter to install onto the single USB found (`0` still writes fresh via
  Rufus), the wizard's reuse-an-existing-USB list checks that one radio button,
  and the non-destructive-copy target picker preselects it. `lslsetup`: the
  page-1 reuse-an-existing-USB list now pre-checks the sole entry (its console
  `choose_target` and the INSTALL-page target picker already defaulted the
  single/first-Ready candidate). With several drives the choice is still left
  to the user.
- `lslsetup.exe` backup offer: the fixed-volume prompt's Yes/No buttons now read
  **Backup First** (back up the contents, then continue) and **YOLO** (continue
  without backing up). The box itself - message text, layout, Cancel - is
  unchanged: the two captions are rewritten in place, since a MessageBox cannot
  be relabeled through the API. The too-big-to-auto-back prompt keeps Yes/No.
- `install.sh` appends a new squashfs layer by default (`LSL_INSTALL_MERGE=1`
  for the old merge behavior); `find_*.zstd` indexing only when no EFU exists.
- Dropped WezTerm (third-party repo + autostart) - kitty (in the main repos)
  is the terminal; smaller first-boot surface.
- `uproot` gained `--auto-append` for first-boot.
- `onboot.sh` seeds `home.sfs` on first boot; optional FUSE flatpak mount.
- `detect-wsl` reads `/cdrom/lsl-wsl-vhdx.conf` (Windows-side VHDX paths).
- `lsl` reads `find_everything.efu` catalogs alongside `find_*.zstd`.
- **Home-persistence consumers now branch on the recorded mode, not a fresh
  prediction.** `lsl-home-flushd` and `lsl-btrfs-growd` (which re-resolved every
  60s mid-loop) use new `lsl_effective_home_is_usb` / `lsl_effective_home_is_hdd`
  helpers in `lsl-common.sh`, and `lsl-shutdown-gui` reports the mode `/home` was
  actually mounted with - so it can no longer promise a btrfs sync that did not
  happen (or unmount binds that were never made). Behavior-preserving on sticks
  with no state file, which fall back to `lsl_is_usb_mode`.

### Fixed
- **A stick that had been re-imaged a few times stopped booting with `File system
  layers are missing`: the layer prune deleted the chain it had just built.**
  `uproot` appends a layer by *extending* the newest dotted name
  (`filesystem.z0.<ts1>` → `filesystem.z0.<ts1>.<ts2>`), because casper walks
  dot-suffixes **upward** from the layer named in `layerfs-path=` and every
  ancestor must exist. The prune that ran immediately afterwards
  (`uproot:prune_superseded_layers`, plus the firstboot finale's
  `lsl_firstboot_prune_orphan_layers`) tested the two names the wrong way round
  and kept only dot-*extensions* of the named layer - the longer siblings, which
  casper never reads - while reaping the shorter ones it *requires*. So every
  append after the first destroyed the previous link, and the next boot died with
  `(initramfs/0 stdin: invalid argument / File system layers are missing`.
  Observed on a stick whose fourth successful append had left only
  `filesystem.z0.<ts1>.<ts2>.<ts3>.<ts4>.squashfs` beside `filesystem.z0.squashfs`,
  with `menu.lst` and `EFI/BOOT/grub.cfg` naming it. Both sites now keep
  dot-*ancestors* (named name as a prefix of the candidate). The test that should
  have caught it asserted the inverted direction - it required a *longer* sibling
  to survive - so it passed green through three firstboots; it is corrected, and a
  4-deep-chain case pins the exact reported failure. The doomed layers are
  therefore no longer reclaimed: a chain of N appends keeps N layers by design,
  since only the named layer's ancestors are readable.
- **Boot to RAM showed no progress dialog: `lslsetup` wrote its secondary initrds
  with the wrong cpio `newc` name padding.** The `newc` header is 110 bytes and
  `110 % 4 == 2`, so the name field must be padded to align `(110 + namesize)`;
  padding `namesize` alone misplaced every entry after the first by 2 bytes. GNU
  `cpio` resyncs on the resulting bad magic and still extracts everything, so
  `cpio -idm` verification looked healthy - but the kernel's initramfs unpacker
  (`init/initramfs.c unpack_to_rootfs`) does not resync: it stopped after the
  first member and silently dropped the tail, including
  `scripts/casper-premount/ORDER`. Without `ORDER`, casper never *sources* the
  ramclone hook, `/run/ramclone/ready` never appeared, and
  `lsl-ramclone-progress.sh` exited at its first gate. Fixed in all three sites
  (`cpio_newc_file`, `parse_cpio_newc`, `split_initrd`) via a `cpio_pad_name`
  helper; data padding still uses `cpio_pad4`. Pinned by a `kernel_unpack_names`
  helper that walks an archive by the kernel's rule - no resync - plus 4 tests
  (`pad_name_aligns_the_110_byte_header`, `archive_survives_the_kernel_unpack_rule`,
  `old_wrong_padding_is_rejected_by_the_kernel_rule`,
  `order_survives_injection_the_way_casper_needs_it`), since writer and parsers
  previously shared the wrong formula and round-tripped consistently against each
  other while both disagreed with the real format. **104 passed, 0 failed.**
  The shipped `casper/initrd.{hddmirror,ramclone}.gz` blobs stay corrupt until the
  build regenerates them.
- **`usb-fallback` still fired when the data dir was mounted read-only: the
  persistence check never asked for `OPTIONS`.** The boot journal shows
  `lsl-home.service` reaching a *read-only* `ntfs-3g` mount at 03:42:37, and the
  kernel rw mount succeeding (`onboot.sh: Using path: /mnt/c`) about one second
  later. `lsl_data_dir_is_persistent` only asked `findmnt -o TARGET` and
  `-o FSTYPE`, never `-o OPTIONS`, so a read-only ntfs mount passed as
  "persistent" - but the btrfs home image needs `rw`. `lsl-mount-home.sh` branched
  on that predicate, accepted the `ro` landing, and declared the fallback,
  discarding the session's `/home` (5.8 MB / 384 entries) into a throwaway tmpfs
  upper layer. New `lsl_data_dir_is_writable()` requires persistent **and**
  `rw` in the mount options; `lsl-mount-home.sh` now waits for a writable mount
  in a bounded loop (re-driving `mount_all.sh` every third try, since the journal
  replay that unblocks the rw mount needs a retry) before declaring the fallback,
  which stays honest if the store never becomes writable. It deliberately does
  not remount rw - that is how NTFS gets corrupted on a dirty volume.
  `onboot.sh` warns separately for "persistent but not writable". Pinned by 5 new
  cases in `tests/lsl-common.tests.sh` (**75 passed, 0 failed**).
- **`/home` was still a RAM overlay on a persistent boot entry, because
  `mount_all.sh` failed to mount `/mnt/c` and nobody checked** (WHYFAIL11, fourth
  occurrence of this symptom; see `WHYFAIL11.md`). WHYFAIL9 and WHYFAIL10 are both
  deployed and working here - the hivex `.debs` are staged by `lslsetup` and
  installed before `/home` mounts, `LSL_MODE=usb-fallback` is recorded honestly,
  and `onboot.sh` reads the recorded fact. The remaining defect was the mount
  itself: the kernel `ntfs3` driver refused the volume (`Can't mount, would change
  RO state` - Windows Fast Startup/dirty NTFS, the WHYFAIL6 5 class), the
  read-write branch had a single `mount -t ntfs3` with **no `ntfs-3g` fallback**,
  and the script never verified the result. WHYFAIL10 had already made the *exit
  code* graceful, which is exactly why this was invisible: the caller re-checks
  `lsl_data_dir_is_persistent` against the **live mount table**, not the return
  value, so a script that returns 0 while leaving `/mnt/c` unmounted still forces
  the fallback. New `mount_ntfs()` tries `ntfs3` then `ntfs-3g` (present on the
  image), then the same pair read-only, verifies every rung with `mountpoint -q`,
  treats an already-mounted target as a no-op success, and fails loudly if `/mnt/c`
  is genuinely unmountable. `ntfs_is_dirty()` no longer misreads `ntfsfix -n`'s
  `Refusing to operate on read-write mounted device` as a clean bill of health, the
  EXIT trap can no longer unmount `/mnt/c` (it was reachable when the volume was
  already mounted at scan time and `best_mount` was `/mnt/c`), and the script now
  ends with `mountpoint -q /mnt/c && exit 0 || exit 1` - making WHYFAIL10 5a's
  documented "exits 0 whenever `/mnt/c` is mounted" contract real for the first
  time (it previously returned `parse_drive Z`'s status, usually 1).
  Pinned by 6 new cases in `tests/mount_all.tests.sh` (**9 passed, 0 failed**).
- **"Load to RAM + remove USB" in `lsl-shutdown-gui` did nothing; it now copies
  with a real progress bar and a completion notice.** Two defects: (1) the zenity
  radiolist returns the option *text*, and the case arm matched only the prefix
  `Load to RAM + remove USB` - the label's `(persistence to USB stops)` suffix sent
  the selection into the catch-all `*) exit 0`, a completely silent no-op
  (dialog/whiptail return the tag `7`, so only the Mint/zenity path was broken);
  (2) even when it ran, `bin/lsl-toram.sh` printed only to stdout, which is
  discarded under `pkexec`, so there was nothing to watch. `lsl-toram.sh` gained
  `--progress`, emitting zenity `PCT # text` lines on stdout (real percent from the
  destination tmpfs's `df` usage during the tar copy; human status moves to stderr),
  and `lsl-shutdown-gui` pipes that into a `zenity --progress` bar and shows
  "Session is now running from RAM" on success (or an error dialog with the log tail
  on failure). The bar follows the WHYFAIL8 rule - no `--auto-close`; the script's
  exit closes it via EOF. `bin/lsl-toram.sh` is also now embedded in
  `FIRSTBOOT_TOOLKIT` (it never was, so a nofmt-built stick would only ever have
  errored "lsl-toram.sh not found"), pinned by a new Rust unit test plus bats tests
  for the dispatch and the `--progress` protocol.
- **A first-boot `usb-fallback` `/home` now fails loudly, and the hivex trigger
  is removed.** When the final flush finds a fallback tmpfs overlay,
  `misc/lsl-firstboot.sh` logs an ERROR, sets a failed phase/detail in the live
  progress dialog, writes `/cdrom/casper/lsl-firstboot.home-failed[.reason]` and
  shows a desktop warning *before* the reboot-approval dialog (new
  `misc/lsl-firstboot-home-failed.sh`) instead of logging `Final home flush OK`
  over lost work. To stop the fallback triggering at all, the Windows installer
  stages `libhivex0`/`libhivex-bin`/`libwin-hivex-perl` `.debs` to
  `<USB>:\pkgs\`, a new `lsl_ensure_hivex_tools` installs them offline before
  `/home` mounts (in `onboot.sh` / `lsl-mount-home.sh`), `mount_all.sh` names the
  missing-`hivexregedit` ordering defect (marker `/run/lsl-usb.mount-missing-hivex`),
  and `bin/squashfs_config.sh` installs the staged `.debs` early in the chroot.
- **The first-boot progress dialog flashed for ~1s then vanished while setup kept running for another 23 minutes** (third report of this symptom; see `WHYFAIL8.md` — not yet written). `misc/lsl-firstboot-progress.sh` piped a long-lived writer (`feed_zenity`, which loops until the stamp appears) into `zenity --progress --auto-close`. With `--auto-close`, zenity 3.44 closes the read end of its own stdin after the first couple of lines, so the next `echo` in the writer died of `SIGPIPE` - silently, without reaching the `kill -0` guard. The pipe then hit EOF and zenity exited `0`, which the caller logged as "shown to completion" (`consumer rc=0`); the writer's own `141` was never logged. Measured: with `--auto-close` the writer emitted **1** line, without it **10**; end-to-end the dialog lived ~2s before and 14s+ after. `--auto-close` is removed (the writer already emits `100` to close the window; `--auto-kill` stays for Cancel) and the exit log now records `writer rc=` as well as `consumer rc=` so a SIGPIPE death cannot masquerade as success again. `misc/lsl-ramclone-progress.sh` and `bin/lsl-shutdown-gui` use `--auto-close` too but their feeds are bounded (they finish and emit `100`), so they are unaffected and were deliberately left alone.
- **The `lsl-progress-gtk.py` fallback wrote nothing to the dialog trace**, so the two earlier post-mortems of the same symptom (2026-09-15/16 and 2026-09-21) could not see that backend at all. It now logs to the same `LSL_DIALOG_LOG`/`LSL_DIALOG_TRACE` targets on every entry and exit path - window shown (mode, `DISPLAY`, stamp/status paths), first render (step, percent, task), and the closing reason (stamp present / parent gone / window closed / stdin EOF) with a tick count and last rendered state. It polls the status file and so cannot take SIGPIPE; this is observability, not a behavioural fix.
- **`lsl-progress-gtk.py` ignored the `--opt=value` argument form.** `--status-file=`, `--stamp=`, `--title=`, `--text=` and `--poll=` were silently dropped, and `--width=480` consumed the *following* argument as its value, which could swallow a consecutive option. The shell caller uses the space-separated form so nothing was broken in practice; both forms are now accepted.
- **First-boot `/home` changes could be silently dropped via the fallback
  tmpfs overlay.** When the HDD data dir is not persistent at mount time (the
  canonical first boot: `hivexregedit` missing, so `mount_all.sh` leaves `/mnt/c`
  unmounted), `lsl-mount-home.sh` correctly falls back to a tmpfs-overlay `/home`
  - but recorded `LSL_MODE=usb`, indistinguishable from a real USB stick. By the
  time firstboot finished, the drives had mounted, so `uphome`'s fresh
  `lsl_is_usb_mode` resolve said "hdd" and it took the HDD branch: a no-op
  `btrfs filesystem sync`, exit 0, first-boot home lost on reboot (it was only
  ever in `/run`). `lsl-flush-home.sh`, reading the stale `usb`, would
  additionally have overwritten the stick's per-distro `home.sfs` with the
  near-empty overlay. Added `lsl_effective_home_mode()` (state file,
  authoritative, falls back to the live mount type), the fallback now records
  `LSL_MODE=usb-fallback`, `uphome` branches on the effective mode and fails
  loudly on `usb-fallback` instead of "succeeding", and `lsl-flush-home.sh`
  refuses to write a fallback overlay to `home.sfs`.
- **New docs: `WHYFAIL9.md` and `FRAGILE_HOME.md`.** `WHYFAIL9.md` is the
  incident write-up (evidence chain, reproduce/verify, what is not yet in
  effect on a booting stick); `FRAGILE_HOME.md` generalises it into the three
  ways lsl-usb answers "is /home persistent?", an inventory of all 8 call
  sites with the risk each carries, and six rules for future changes.
- **Boot to RAM (`ramclone`) never copied anything and never showed a dialog.**
  The initramfs hook built the dm-clone table without the mandatory region-size
  argument, and dm-clone rejects `argc < 4` - so `dmsetup create` failed and the
  stick silently booted normally from the USB (nothing hydrated, no dialog, and
  the stick could not actually be removed). It also mapped both the base and the
  `z0` layer to the single clone device, but casper mounts every layer of the
  dotted `layerfs-path` chain separately (`setup_overlay`); and
  `lsl-ramclone-status` / `lsl-ramclone-eject` read the wrong `dmsetup status`
  fields (the hydrated/total region pair is field 7, `<hydrated>/<total>`, not
  4/5), so progress was always 0% and completion was never signalled. The hook
  now passes `2048` (1 MiB) as the region size, RAM-backs every other chain
  layer (`z0` / appended) into tmpfs so no USB file stays open, and records the
  layer-to-device map for `get_backing_device`. A new
  `/etc/xdg/autostart/lsl-ramclone-progress.desktop`
  (`misc/lsl-ramclone-progress.sh` plus a `lsl-progress-gtk.py --ramclone` mode
  as the zenity fallback) shows the copy progress on a Boot-to-RAM boot and -
  once hydration is complete and every layer is RAM-backed - offers a **Detach
  USB** button that runs the eject and then reports "It is now safe to remove
  your stick." Normal boots and the `lsl_home=tmpfs` "(no persistence)" entry
  are otherwise unaffected.
- Persistent `/home` could hide the live user's home: the home image
  (`home.btrfs` / `home.sfs`) is keyed to `LSL_DATA_DIR`, not to the booted
  distro, so an image seeded by another live user - e.g. an Ubuntu-seeded
  `home.btrfs` holding `/home/ubuntu` reused on a Mint stick whose user is
  `/home/mint` - left `/home/<user>` missing. Autologin then died and fell
  back to the greeter, while the RAM-only `(Boot to RAM, no persistence)`
  entry (which rebuilds the user's home each boot) logged in normally.
  `onboot.sh` now guarantees the desktop user's home exists and is owned by
  the user on every persistent-home path (`lsl_ensure_user_home`, seeded from
  `/etc/skel`), and no longer stacks the USB home overlay when the `home.sfs`
  lower mount failed (an empty lower would expose an empty `/home`).
- The display manager could start before `onboot.sh` had mounted the
  persistent `/home`: nothing ordered `display-manager.service` after
  `onboot.service` (lightdm only waits on systemd-user-sessions/getty/
  plymouth), so a live session could begin on the live `/home` and then have
  the persistent one mounted underneath it - the same "back to the greeter"
  failure, from a race. `onboot.service` is now
  `Before=display-manager.service`, and `onboot.sh` backgrounds its (up to
  ~5 minute) wifi wait so that ordering cannot delay login.
- Split the `/home` mount out of `onboot.sh` into `bin/lsl-mount-home.sh`,
  run by the new early `lsl-home.service` (`Before=display-manager.service`,
  `After=local-fs.target`). The greeter now waits only for the home mount
  rather than for all of `onboot.service`; `onboot.service` runs
  `After=lsl-home.service` and the script call is idempotent (the
  `/run/lsl-usb.state` marker makes the second call a no-op).
- `lsl-home.service` sets a bounded `TimeoutStartSec` (a `Type=oneshot` unit
  has no default start timeout, so a wedged mount would otherwise block the
  greeter forever), and `bin/lsl-diag.sh` now captures its journal alongside
  `onboot.service`.
- The install-wizard's "Turn off Windows Fast Startup / hibernate" box is now
  pre-ticked when `hiberfil.sys` is present (Fast Startup on makes the Windows
  volume mount read-only after a Fast-Startup shutdown, so HDD-mode `home.btrfs`
  cannot be written), and the headless flow warns about it even when the
  pagefile reclaim is not selected.
- `build.sh` now stages `onboot.service` and `lsl-home.service` (and enables
  them) in the first-boot layer, so the display-manager ordering applies from
  the very first boot of an `install.ps1` stick, as it already did for the
  nofmt installer's embedded layer.
- Home and cache images are now per-distro: `home-<id>.btrfs` /
  `cache-<id>.btrfs` in `LSL_DATA_DIR` and `/cdrom/home-<id>.sfs` for USB mode
  (`<id>` from `/etc/os-release`, else the desktop user). Re-imaging a stick
  with another distro no longer reuses the previous home; a pre-existing
  legacy `home.btrfs`/`cache.btrfs`/`home.sfs` is adopted by the first distro
  to boot (`lsl_home_migrate_legacy`).
- Superseded squashfs layers were never reaped on the success path. Every
  successful firstboot appended a fresh `filesystem.z0.<ts>.squashfs` and
  repointed `menu.lst` at it, orphaning the previous one; the only cleanup
  (`lsl_firstboot_drop_prior_appended_layers`) runs while the success stamp is
  *missing*, so on a stick where every attempt succeeded nothing was ever
  pruned. Casper stacks only the layer named on the kernel cmdline (and its
  dot-ancestors), so the orphans were inert dead weight - 5x761MB = 3.6 GB on a
  32 GB FAT stick. `uproot` now prunes as part of `write_append_layer`, and
  `lsl-firstboot.sh` prunes again at the finale. Both refuse to delete anything
  unless they can positively resolve the layer the boot config names, and never
  remove that layer, its dot-ancestors, or the base layers; a first revision
  compared a hardcoded `/cdrom` path against `STICK_DIR`-relative files, failed
  to match, and deleted the layer the cmdline pointed at (a bricked boot).
- Persistent `/home` was not mounted (silent tmpfs overlay fallback): the env file
  `lsl-usb.env` has no `.gitattributes` rule, so it was checked out CRLF on
  Windows and bash sourced values with a trailing CR. `LSL_DATA_DIR` then resolved
  to `/mnt/c/Users/lsl-usb\r`, which matched neither `/cdrom` nor `/persist` in
  `lsl_is_usb_mode` and could not be resolved by `findmnt`, so `onboot.sh`
  concluded the data dir was not persistent and fell back to a volatile
  tmpfs/overlay `/home` with no log line explaining why. Fixed at three levels:
  `lsl-usb.env`/`*.env`/`*.bats` now pinned to `eol=lf`; `lsl_load_config`
  normalises CRLF/BOM before sourcing (and never lets a stale `$HOME/lsl-usb.env`
  shadow the stick's copy); and `onboot.sh` exports `LSL_ENV_FILE` before sourcing
  `lsl-common.sh` and logs the env file, data dir and mode it selected, plus a
  warning when HDD mode cannot confirm a persistent volume.
- `lsl_load_config` no longer clobbers an `LSL_DATA_DIR` the caller set explicitly
  (`lsl_resolve_data_dir` calls it, so the override was silently discarded).
- Stale CRLF in the working tree made `tests/mount_all.tests.sh`,
  `tests/lsl-merge-suggest.tests.sh`, `tests/overlay-merge.tests.sh`,
  `tests/lsl-reclaim-win-swap.tests.sh` and `tests/overlayfs-whiteout.tests.sh`
  fail with `syntax error near unexpected token $'\r'`; renormalised.
- `persist-wifi.sh` no longer unconditionally remounts `/cdrom` ro (broke
  `uproot`'s later writes).
- `install.ps1`: several StrictMode crashes (missing registry properties,
  `$null` pipeline inputs, array-wrap regressions), the `$base` unset-variable
  bug, and the Ctrl-C JIT-dialog loop (message-pump exception handling).
- `build.sh` preflight: `grep -q` + `pipefail` SIGPIPE race caused intermittent
  "zip missing entry" failures.
- `mount_all.sh`: the drive-letter line match used a backslash-escaped pattern that
  never matched `hivexget` output, so D:–Z: never resolved (caught by a new unit
  test). Resolution now uses the partition GUID against `PARTUUID` (GPT) with an
  MBR disk-signature + offset fallback.
- `lslsetup.exe` nofmt payload: `FIRSTBOOT_TOOLKIT` now embeds the full
  `/cdrom/bin` boot payload (`lsl-gui`, `lsl-tui`, `lsl-shutdown-gui`,
  `mount_all.sh`, `lsl-pin-favorites`, `lsl-home-readonly-warning`,
  `lsl-reclaim-win-swap.sh`, `clean-old-system-patches.sh`, `wsl-boot-setup`)
  instead of a partial set - every desktop, autostart, service and onboot
  reference resolves on a fresh install (pinned by a new unit test).
- `lsl-wsl-vhdx.conf` is now written LF with a trailing newline (was CRLF
  with no terminator, silently dropping the last VHDX entry in readers).
- `lsl` mounts dirty VHDX images read-only instead of failing: new
  `guestmount -r` fallback ladder plus `-o ro` retry in the qemu-nbd path
  (the existing read-only notice already points at `--overlay-disk` for a
  writable session); also fixed a misquoted sudo guestmount invocation.
- `lsl_env_file` honors `LSL_CDROM` (same convention as `config.sh`), making
  the stick-vs-`$HOME` precedence test hermetic off-stick.
- Rebuilt `assets/filesystem.z0.squashfs` from current `misc/` (picks up the
  firstboot success-path layer prune).

### Added
- `bin/lsl-diag.sh`: collect first-boot/onboot diagnostics (logs, mount state,
  `dmesg`/`journalctl`) into a tarball on the first Windows-readable volume, so a
  wedged first boot can be inspected without the USB. Wired into `lsl-firstboot.sh`
  failure paths; a failed first boot also drops `/cdrom/casper/lsl-firstboot.FAILED`.
- `tests/mount_all.tests.sh` (GPT/MBR drive-letter resolution) and
  `tests/casper-layer-check.sh` (verify the appended `filesystem_z*.squashfs`
  layers match the target casper initramfs glob — the biggest pre-hardware unknown).
- `lsl_data_dir_is_persistent` helper in `lsl-common.sh`.

### Changed
- `onboot.sh` guards HDD home mode: if `LSL_DATA_DIR` is not yet on a persistent
  volume (e.g. first boot, before firstboot installs the hivex tools that mount
  `/mnt/c`), it retries the drive mount and otherwise falls back to a temporary
  tmpfs-overlay `/home` with a warning, instead of silently writing `home.btrfs`
  into volatile RAM.
- `mount_all.sh` mounts a dirty/hibernated NTFS read-only (via `ntfsfix -n`) to
  avoid corrupting the Windows volume; gates the existing `safe_ntfsfix.sh` repair
  behind `LSL_NTFSFIX=1`.
- `lsl-toram.sh` stops all LSL daemons, detaches the home/cache loop devices, and
  lazy-unmounts the old root + USB so the stick can actually be removed after the
  pivot (previously only `lsl-home-flushd` was stopped).
- `lsl-btrfs-growd` verifies the loop device picked up the grown backing file and
  re-loops/remounts when `losetup -c` is ignored by the kernel.
- `lsl-firstboot.service` gains `StartLimitBurst`/`StartLimitIntervalSec` as a
  backstop against rapid crash loops.
- CI: `tests/*.sh` are shellchecked; the release artifact check uses the real
  `filesystem_z0_firstboot.squashfs` name.
- `lsl-diag.sh` now also captures Secure Boot state (`mokutil --sb-state`) for
  boot-failure diagnosis.
- `misc/lsl-firstboot.sh` runs `dpkg --configure -a` + `apt-get install -f`
  (via `squashfs_config.sh`) before the recipe so an interrupted prior attempt
  does not wedge; warns on < 3 GiB RAM; logs btrfs/hivex tooling presence; drops
  a baseline diagnostics tarball on every successful first boot; and removes any
  corrupt/partial appended layer before giving up.
- `squashfs_config.sh` skips `guestmount`/`guestfish` on machines with < 3 GiB
  RAM (the libguestfs appliance can OOM) so first boot does not fail low-RAM.
- `bin/lsl-flush-home.sh`, `bin/uproot` (append + merge), and `onboot.sh`
  (first-boot `home.sfs` seed) now pre-check free space on `/cdrom` via
  `lsl_ensure_cdrom_space` (new `lsl-common.sh` helper) and abort with a clear
  message instead of a mid-write "No space left on device".
- `onboot.sh` falls back to a temporary tmpfs `/home` when `btrfs-progs` is not
  present on the first boot (before firstboot installs it), and is now sourceable
  for unit tests (`tests/live-emulation.sh` emulates it and asserts the generated
  fstab block wires `/cdrom` and a btrfs-loop `/home`).
- `tests/live-emulation.sh` now sources `onboot.sh` and asserts `lsl_merge_fstab`
  output; `tests/lsl-common.tests.sh` covers `lsl_cdrom_free_mib`,
  `lsl_ensure_cdrom_space`, and `lsl_data_dir_is_persistent`.
- Docs (`README.md`, `VALIDATION.md`): Secure Boot / Rufus DD-mode guidance,
  minimum-RAM recommendation for first boot, and the `guestmount` RAM caveat.

## [0.1.0] - initial

- Initial Windows installer + Linux first-boot layer + persistence tooling.
