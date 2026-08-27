# lsl-usb
Linux Services for Linux

WSL is a killer Windows feature. `lsl-usb` is the obvious next step: Linux Services for Linux.

Jokes aside: this project turns a Linux Mint LiveUSB into a WSL-like workflow for Windows users who want more native Linux power. It auto-mounts Windows drives, sets up boot-time services, and adds persistence tools for home and root changes.

## Why use this instead of WSL?

- More direct access to Linux kernel and low-level tooling.
- No WSL VM memory cap surprises.
- Portable Linux environment you can boot on different machines.
- Practical path for users moving off unsupported Windows installs.

## Requirements

- Linux Mint 22.2 (or similar Ubuntu-based live image) written to USB.
- Use [Rufus](https://rufus.ie/) or similar imaging tool; do not use Ventoy for this workflow.
- **Windows side:** PowerShell **5.1 or newer**. `install.bat` resolves a
  suitable runtime before doing anything: it uses `pwsh` if present, else Windows
  PowerShell 5.1+, else **auto-downloads portable PowerShell 7.1** (the last
  release that runs on Windows 7 SP1) - so **Windows 7 is fully supported**
  without manually installing WMF. **Vista / PowerShell 2.0 are not supported**
  (they lack the cmdlets `install.ps1` uses). It launches `install.ps1` with
  `-ExecutionPolicy Bypass`; if `install.ps1` is not next to it, the `.bat` unzips
  `lsl-usb-win.zip` (or downloads `LSL_RELEASE_URL`) first.
- Network access during install/customization.
- Windows partitions should be cleanly shut down before write operations.

## Quickstart

### Install (from a booted Mint LiveUSB session)

```bash
curl -fsSL https://raw.githubusercontent.com/gmatht/lsl-usb/main/fetch.sh | sudo bash
```

This downloads the repo and runs `install.sh`.

### Manual install

```bash
git clone https://github.com/gmatht/lsl-usb.git
cd lsl-usb
sudo ./install.sh
```

### Install (from Windows)

```text
1. Download lsl-usb-win.zip (built by ./build.sh, from the releases page).
2. Extract it, double-click install.bat.
```

`install.bat` handles Windows' script friction for you: it clears the
downloaded-file marker (`Unblock-File`) and runs `install.ps1` with
`-ExecutionPolicy Bypass`, so the PowerShell execution policy is not a blocker.
If SmartScreen still warns, right-click the file -> Properties -> Unblock
(or "More info" -> "Run anyway"). `install.ps1` can also be run directly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

By default a WinForms GUI starts first: it runs the ISO download/verify in the
background (with a progress bar) while you configure - flatpak apps to preload
(detected from your installed Windows apps), WSL VHDX paths, and `LSL_DATA_DIR`.
Use `-NoGui` for the plain console flow.

To see everything that would be detected and passed to the Linux install
(ISO, Rufus, USB target, WSL VHDX paths, wifi profiles, bundle contents)
without downloading or writing anything:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -DryRun
```

## First boot checklist

1. Open `/cdrom/lsl-usb.env`.
2. Set `LSL_DATA_DIR` (default is `/mnt/c/Users/lsl-usb`).
3. Reboot so `onboot.service` applies your mode cleanly.
4. Start with `lsl-gui` (desktop shortcut is also created).
5. Use `lsl-shutdown-gui` when you want a guided save/reboot/shutdown flow.

## Daily use

- `lsl-gui`: launch/select your Linux services workflow (GUI).
- `lsl`: CLI entrypoint.
- `uphome`: persist home changes now.
  - USB mode: flushes merged `/home` to `/cdrom/home.sfs`.
  - HDD mode: syncs `home.btrfs` and cache btrfs.
- `uproot`: persist root/package changes by creating a new squashfs layer or merged image.
- `lsl-shutdown-gui`: optional safe shutdown UX with save/no-save options.

## Features

- Auto-mount helpers for Windows drives and drive-letter detection.
- WSL-like launch scripts and GUI helpers (`lsl`, `lsl-gui`, `lsl-shutdown-gui`).
- Config-driven persistence with USB mode and HDD mode.
- Background daemons for home flush (`lsl-home-flushd`) and btrfs growth (`lsl-btrfs-growd`).
- WezTerm autostart and desktop integration helpers.
- Does not modify Windows bootloader or partition table layout.

## Configuration reference (`/cdrom/lsl-usb.env`)

`onboot.sh` loads this file each boot (via `lsl-common.sh`):

- `LSL_DATA_DIR` (default: `/mnt/c/Users/lsl-usb`)
  - Decides persistence mode and data location.
  - Example (HDD mode): `/mnt/c/Users/you/lsl-usb`
  - Example (USB mode): `/cdrom/lsl-data` or `/persist/lsl-data`
- `LSL_HOME_IDLE_SEC` (default: `300`)
  - USB mode idle seconds before `lsl-home-flushd` writes `/home` back to `home.sfs`.
- `LSL_HOME_BTRFS_MIB` (default: `4096`)
  - Initial size for `home.btrfs` in HDD mode.
- `LSL_CACHE_BTRFS_MIB` (default: `2048`)
  - Initial size for `cache.btrfs` in HDD mode.
- `LSL_HOME_TMPFS_MIB` (default: `2048`)
  - USB mode tmpfs size for overlay upper/work.
- `LSL_BTRFS_MIN_FREE_PCT` (default: `10`)
  - Free-space threshold for auto-grow behavior.
- `LSL_BTRFS_GROW_CHUNK_MIB` (default: `1024`)
  - Growth chunk size used by `lsl-btrfs-growd`.
- `LSL_ZRAM_MIB` (default: unset -> about 80% of RAM, min 128 MiB)
  - Set to `0` to disable zram swap.
- `LSL_NTFSFIX` (default: `0`)
  - Set to `1` to let `mount_all.sh` run `safe_ntfsfix.sh` on the most-recently-booted Windows partition at boot. Off by default: the repair script is not yet battle-tested.

## Persistence model

Mode is selected from resolved `LSL_DATA_DIR`:

- USB mode: path resolves under `/cdrom` or `/persist`.
- HDD mode: everything else (for example `/mnt/c/...`).

### HDD mode

- Creates loop-backed `home.btrfs` and `cache.btrfs` under `LSL_DATA_DIR`.
- Mounts `/home` from `home.btrfs`.
- Binds cache paths from `cache.btrfs`:
  - `/var/cache`
  - `/home/<user>/.cache` (the live-session desktop user: mint on Mint, zorin on Zorin, ...)
  - `/nix/store`
  - `/nix/var`
- `uphome` is usually enough for day-to-day sync (no squashfs rebuild).

### USB mode

- Uses `/cdrom/home.sfs` as lowerdir and tmpfs overlay as upper/work for `/home`.
- `lsl-home-flushd` periodically flushes merged `/home` back to `/cdrom/home.sfs`.
- `uphome` forces an immediate flush.

## Persisting and reverting changes

### Persist home changes

- Run `uphome`.
- Backup file is created before replacement:
  - `/cdrom/home_YYYYmmddHHMMSS.sfs`

### Persist root changes

- Run `uproot` as root.
- You can choose:
  - Append new squashfs layer (`filesystem_z*.squashfs`), or
  - Merge to a single new `filesystem.squashfs`.
- Merge mode backs up old root image:
  - `/cdrom/casper/filesystem_YYYYmmddHHMMSS.squashfs`

### Revert persisted images (from Linux or Windows)

- Revert home: replace `/cdrom/home.sfs` with one backup `home_*.sfs`.
- Revert root: replace `/cdrom/casper/filesystem.squashfs` with one backup `filesystem_*.squashfs`.
- If you appended a layer (`filesystem_z*.squashfs`), move it out of `/cdrom/casper` to disable it on next boot.

## Safety notes (read this before writing NTFS/USB)

- **`wifi.sh` stores wifi passwords in plaintext** on the FAT partition (`/cdrom/wifi.sh`). This is inherent to the design - the live system needs them at boot to connect - but anyone with access to the USB can read them. Uncheck "Copy Wifi Settings to LSL" in the installer (or delete `/cdrom/wifi.sh`) if that is a concern.
- **Preloaded `.snap` files install with `--dangerous`** (no store signature check) - only preload snaps you trust. The first-boot recipe unpins Mint's `nosnap.pref` and installs `snapd` by default (`LSL_SNAP_SUPPORT=0` to keep Mint's default).
- **`find_everything.efu` contains the full file list of your Windows drives** (filenames, sizes, dates) in plaintext on the FAT partition. Uncheck "Export Everything index" in the installer if that is a concern.

- Disable Windows Fast Startup and fully shut down Windows before mounting writable NTFS.
- If a Windows volume is hibernated/dirty/BitLocker-locked, do not force writes.
- Prefer HDD mode (`LSL_DATA_DIR` on `/mnt/c/...`) for heavy writes; it reduces stress on the USB FAT partition.
- `lsl-shutdown-gui` tries to remount `/cdrom` read-only and sync before poweroff to reduce corruption risk.
- Keep spare backups of `home.sfs` and `casper/filesystem*.squashfs`.

## Troubleshooting

- USB not seen in boot menu:
  - Replug and cold boot.
  - Check UEFI/BIOS boot order.
  - Re-image USB if firmware intermittently fails to detect it.
- NTFS mount issues:
  - Ensure Windows was shut down cleanly (no hibernation/Fast Startup).
  - Use `safe_ntfsfix.sh` workflow only when needed.
- "My changes disappeared":
  - Home changes: run `uphome` (USB mode) or verify HDD mode path.
  - Root/package changes: run `uproot` and choose append/merge.
- Home read-only warnings:
  - Check the autostart warning helper (`lsl-home-readonly-warning`) and disk health.
- Won't boot on a UEFI machine / Secure Boot:
  - This is a BIOS/MBR-style casper live USB, **not** a signed UEFI bootloader,
    so it will not boot on firmware with Secure Boot enabled. Disable Secure Boot
    (or enroll a shim via MOK) to boot it. `mokutil --sb-state` on any Linux box
    reports the firmware Secure Boot mode.
  - With Rufus, write in **DD Image** mode (not ISO mode) so the stick boots like
    a real ISO; some firmwares reject Rufus' ISO-mode hybrid partition table.

## Boot behavior

`onboot.sh` (via `onboot.service`) does the core runtime setup:

- Loads `/cdrom/lsl-usb.env`.
- Calls `mount_all.sh` for Windows drives.
- Applies USB/HDD home mode.
- Enables cache/Nix mount layout in HDD mode.
- Starts zram swap setup (configurable with `LSL_ZRAM_MIB`).
- Refreshes generated fstab block.
- Runs optional helpers like `wsl-boot-setup`.

The first boot is memory-heavy: the apt recipe plus the libguestfs appliance used
for `guestmount` VHDX mounting can OOM below ~4 GB RAM. `guestmount`/`guestfish`
are **skipped automatically on machines with < 3 GB RAM** (VHDX mounting then
unavailable until more RAM is added); everything else in the first boot still runs.
Recommendation: **>= 4 GB RAM for first boot**.

## Project map

- `fetch.sh`: one-liner installer entrypoint (Linux live session).
- `install.sh`: image customization and initial setup (Linux live session).
- `install.ps1` + `install.bat`: Windows installer with a WinForms wizard (ISO selection with Everything discovery, flatpak app preload detected from installed Windows apps, WSL VHDX paths, `LSL_DATA_DIR`, per-network wifi picker, reuse-an-existing-USB). Auto-downloads the Mint 22.x ISO (incremental SHA-256 verify with progress + ETA) and Rufus (Authenticode-verified), writes the USB, drops the lsl layer + config, and generates `wifi.sh` from Windows' saved profiles (netsh). Supports Ubuntu 24.04 based ISOs (Mint 22.x, Zorin 18.x - the live-session user is detected dynamically, not hardcoded to `mint`); refuses Ubuntu 26.04+ (it still uses NetworkManager, but its nmcli is broken, so the nmcli-based tooling breaks). `-NoGui` for the console flow; `-DryRun` for a detection report; `-SkipRufus` to write the image yourself and have the script pick up the USB.
- `build.sh`: builds the Windows installer bundle (`dist/lsl-usb-win.zip`) - a ~4 KB `filesystem_z0_firstboot.squashfs` layer (systemd unit + scripts only, no distro binaries) plus the FAT-side file set. Runs three gates before packaging: the `install.ps1` test suite (pwsh), `shellcheck -S error` on all shell scripts, and a bundle preflight (layer contents, unit `ExecStart` paths, zip entries).
- `misc/lsl-firstboot.sh` + `misc/lsl-firstboot.service`: run once on the first boot of a Windows-installed USB - waits for network, runs `uproot --auto-append` (installs `/cdrom/bin/squashfs_config.sh` packages in a chroot overlay and persists a new layer), stamps `/cdrom/casper/lsl-firstboot.done`, then reboots. The recipe also removes Mint's `nosnap.pref` pin and installs `snapd` by default (disable with `LSL_SNAP_SUPPORT=0`) so snaps - including any `.snap` files the Windows installer preloads to `<USB>\snaps\` - can be installed.
- `misc/lsl-firstboot-progress.sh` + `.desktop`: user-session zenity progress dialog fed by `/run/lsl-firstboot-status` while the first-boot setup runs (the desktop is not blocked; the work is `nice`d/`ionice`d).
- `onboot.sh`: runtime setup on every boot.
- `bin/config.sh`: sync scripts to `/cdrom`, install services/shortcuts/autostart entries.
- `bin/uphome`: persist/sync home data.
- `bin/uproot`: persist root image changes (also `--auto-append` for first-boot).
- `bin/detect-wsl`: detects WSL rootfs dirs on mounted Windows partitions and reads `/cdrom/lsl-wsl-vhdx.conf` (written by `install.ps1`) to add WSL2 VHDX paths - so distros stored anywhere on disk (e.g. `D:\WSL\Ubuntu2404\ext4.vhdx`) are mountable via `lsl`/`lsl-gui` (guestmount).
- `bin/lsl-common.sh`: shared config loading and mode detection logic.
- `bin/lsl-precache.sh` + `systemd/lsl-precache.service`: warm the page cache so early reads hit RAM instead of the USB. Order: (1) the startup-critical hot files from `/cdrom/lsl-precache.list` first (recorded by `bin/lsl-precache-profile.sh` via fatrace), then (2) if the whole image (squashfs layers + home.sfs) is under half of total RAM, warm everything else at `ionice idle`, stopping early if unused RAM drops below 10%. Falls back to the hot-file list alone when the image is too big. Unlike `toram`, no copy or pivot is involved - it is just a reclaimable page cache.
- `bin/lsl-toram.sh`: lazy `toram` - copy the whole running root to a tmpfs and `pivot_root()` into it, then unmount the USB so the stick can be removed mid-session (run anytime after boot, in the background). Stops USB-persistence helpers first; re-insert the stick to persist again.
- `bin/lsl-boot-time.sh` + `systemd/lsl-boot-stamp.service` + `misc/lsl-boot-time.desktop`: measure boot-to-desktop time and a precache workload probe per boot, logged to `/cdrom/casper/boot-times.log` for comparison.
- `bin/lsl-rusttools.sh` + `bin/rusttools.list`: install statically-linked CLI tools (ripgrep, fd, bat, eza, zoxide, delta, lazygit, starship, just, ...) to `/cdrom/bin` (on PATH) - musl-static, no runtime deps, persist on the FAT partition.
- `bin/lsl-appimages.sh` + `bin/appimages.list`: download curated AppImages (RustDesk, KeePassXC, FreeCAD, Joplin, ...) to `/cdrom/appimages` via GitHub latest-release resolution, with a URL cache so the API is only hit once per app.
- `tests/install.ps1.tests.ps1`: mock-based test harness for `install.ps1` (mocks Get-Volume/registry/es.exe/netsh/WebClient) - run with `pwsh -File tests/install.ps1.tests.ps1`.

## File search

- **Windows**: install [Everything](https://www.voidtools.com) (voidtools) - the
  installer offers to install the portable version if missing. It powers the
  ISO picker (full-disk discovery) and the `find_everything.efu` export.
- **Linux (GUI)**: [FSearch](https://github.com/cboxdoerfer/fsearch) is the
  closest Everything equivalent (C/GTK, instant results, regex). The installer
  pre-checks it as a recommended flatpak (`io.github.cboxdoerfer.FSearch`);
  other options: ANGRYsearch, Recoll (full-text), Catfish, Synapse.
- **Linux (CLI)**: `lsl-find <pattern>` searches the exported EFU index
  instantly (the pre-indexed Windows view - no scanning). `fzf` gives
  interactive fuzzy search; `plocate` indexes the live system's own files
  (`sudo apt install plocate && sudo updatedb`).

## Testing

```bash
# PowerShell harness (install.ps1) - mocks Get-Volume/registry/es.exe/netsh/WebClient
pwsh -NoProfile -File tests/install.ps1.tests.ps1

# Bash regression tests (bats)
bats tests/bash.tests.bats
```

CI (`.github/workflows/ci.yml`) runs both, plus shellcheck and `build.sh`, on every
push; a `v*` tag triggers a release with `dist/lsl-usb-win.zip` attached.

## Status / roadmap

See [`TODO.md`](TODO.md) for current experiments and next tasks.
