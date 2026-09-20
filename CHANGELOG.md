# Changelog

All notable changes to lsl-usb. Format based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added
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
  then offers a 10-minute cancellable reboot instead of rebooting at once -
  a per-session dialog (bundled GTK fallback, else zenity) with a live
  countdown plus Reboot now / Cancel automatic reboot (`LSL_FIRSTBOOT_REBOOT`,
  `LSL_FIRSTBOOT_REBOOT_TIMEOUT`, `LSL_FIRSTBOOT_FLAG_DIR` to tune/skip).
- Test harness (PowerShell, ~55 assertions) + bats (~77 tests) + CI + release workflow.
- `VALIDATION.md` (real-hardware checklist), `VERSION`, `CHANGELOG.md`.

### Changed
- `install.sh` appends a new squashfs layer by default (`LSL_INSTALL_MERGE=1`
  for the old merge behavior); `find_*.zstd` indexing only when no EFU exists.
- Dropped WezTerm (third-party repo + autostart) - kitty (in the main repos)
  is the terminal; smaller first-boot surface.
- `uproot` gained `--auto-append` for first-boot.
- `onboot.sh` seeds `home.sfs` on first boot; optional FUSE flatpak mount.
- `detect-wsl` reads `/cdrom/lsl-wsl-vhdx.conf` (Windows-side VHDX paths).
- `lsl` reads `find_everything.efu` catalogs alongside `find_*.zstd`.

### Fixed
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
