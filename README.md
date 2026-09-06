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
  `lsl-usb-win.zip` (or downloads `LSL_RELEASE_URL`) first. If neither is present,
  `install.bat` queries the GitHub API for the latest `lsl-usb-win.zip` release
  asset (set `LSL_REPO=owner/name` near the top of `install.bat`); the CI/CD
  workflow `release.yml` builds and publishes that asset. So the only manual step
  is running `install.bat`.
- Network access during install/customization.
- Windows partitions should be cleanly shut down before write operations.

## Quickstart

If you are currently running windows, it is recommended that you install LSL directly from Windows.
We support a GUI (on WinXP SP2+) to guide you through the initial configuration
and installation of LSL.

### Install (from windows)  

Download and run [install.bat](https://raw.githubusercontent.com/gmatht/lsl-usb/refs/heads/main/install.bat)

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
- **Network driver preload**: the Windows installer detects this PC's wifi/ethernet
  chipsets (PnP hardware IDs) and stages out-of-tree drivers (Realtek RTL8821CE /
  RTL8723DE / RTL88x2BU / RTL8812AU / RTL8814AU / RTL8188EU / RTL8723BU, Broadcom
  BCM43xx) to `<USB>\drivers\`; first boot builds and installs them via DKMS so
  wifi works on every later boot.
- **Linux compatibility rating**: the installer rates every detected device
  (wifi/ethernet/GPU/NVMe/bluetooth/audio/webcam/…) against the Linux kernel the
  ISO ships, using linux-hardware.org LKDDb data, and prints an A–D rating in the
  DryRun report. A bundled snapshot of the 500 most common devices
  (`lsl-hw-cache/`, consumer-form-factor-tuned) means the rating needs **no network
  request at all** for common
  hardware — see [Hardware compatibility rating](#hardware-compatibility-rating-linux-hardwareorg-lkddb).
- Does not modify Windows bootloader or partition table layout.
- **Daily Windows-folder backups to squashfs.** `bin/lsl-win-backup.sh` backs
  selected Windows folders (on mounted NTFS) into squashfs images with per-job
  include/exclude POSIX-ERE regexes, a space *estimate* (learned ratio or quick
  sample), and a daily incremental that captures files changed in the last ~24h
  (a chaining window so nothing is missed between runs). A systemd timer runs it
  daily; see [Backups and speed-ups](#backups-and-speed-ups).
- **Copy the squashfs layers to the NTFS HDD for speed.** The installer wizard
  (and `bin/lsl-copy-sfs-hdd.sh`) can copy the Linux root layers + home snapshot
  from the USB to the internal HDD; `lsl-precache.sh` then warms the page cache
  from the faster drive. See
  [Backups and speed-ups](#backups-and-speed-ups).

## Hardware compatibility rating (linux-hardware.org LKDDb)

The Windows installer reports how well your hardware will work on the Mint 22.x
ISO's kernel. It enumerates PnP devices (network, display, multimedia, Bluetooth,
…), and for each one queries the [linux-hardware.org](https://linux-hardware.org)
LKDDb (Linux Kernel Driver Database) to learn the minimum kernel that supports
it, then compares against the ISO kernel (6.8). Ratings:

- **A** – in-kernel since before the ISO kernel → works out of the box.
- **C** – needs a newer kernel than the ISO ships (or a known-problem chip with a
  staged out-of-tree driver) → action noted / driver preloaded.
- **D** – the only LKDDb match is a bus bridge / Bluetooth entry, not a real
  driver for this function.
- **U** – no LKDDb data (e.g. newest GPU/NVMe) or the site was unreachable.

### Bundled offline cache (`lsl-hw-cache/`)

To avoid a network request (and the upstream rate-limiting) for every device,
the bundle ships a snapshot of the **500 most common** devices' LKDDb pages in
`lsl-hw-cache/lsl-lhw-<type>-<vid>-<did>.html` (a hand-curated set plus the top-50
most frequent PCI devices per functional class — storage, network, display,
multimedia, USB — and the next-most-common consumer devices, all derived
data-driven from the
[bsdhw/PCIconf](https://github.com/bsdhw/PCIconf) corpus of 14k+ real machine
`pciconf` dumps, **tuned to consumer form factors** — Notebook/Desktop/Convertible/
Tablet/All-In-One/Mini-PC, excluding Server/Firewall/SoC). At rating time the installer
checks, in order: the per-user `%TEMP%` cache → **the bundled cache** → a live
(polite, Crawl-delay-respecting) fetch. So a typical PC rates instantly and
offline.

- **Source / attribution:** pages are from [linux-hardware.org](https://linux-hardware.org),
  which republishes the LKDDb under an open license; the device/driver facts are
derived from the upstream Linux kernel. The device-ID list in `tools/hw-cache-ids.txt`
  is a hand-curated set **augmented with PCIconf-derived devices** (top-50 per
  functional class plus the next-most-common consumer devices), derived from the
  [bsdhw/PCIconf](https://github.com/bsdhw/PCIconf)
  corpus of real-world `pciconf` dumps, **restricted to consumer form factors**
  (CC-licensed — attribution to bsdhw). Regenerate
  with `tools/build-hw-cache.ps1`.
- **Refresh / rebuild:** `pwsh tools/build-hw-cache.ps1` re-fetches any missing
  pages (idempotent; respects `robots.txt` Crawl-delay and backs off on HTTP 429).
  The device ID list lives in `tools/hw-cache-ids.txt`. The build date is recorded
  by the commit that last updated `lsl-hw-cache/`.
- **TODO:** stand up a local mirror (e.g. `www.easyp.net`) of the LKDDb pages so
the bundle can ship a complete, always-fresh cache with no dependence on the
  upstream rate limiter — see `TODO.md`.

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
- `LSL_BTRFS_GROW_INTERVAL_SEC` (default: `60`)
  - How often `lsl-btrfs-growd` polls free space (lower this on embedded/low-RAM boxes).
- `LSL_ZRAM_MIB` (default: unset -> about 80% of RAM, min 128 MiB)
  - Set to `0` to disable zram swap.
- `LSL_NTFSFIX` (default: `0`)
  - Set to `1` to let `mount_all.sh` run `safe_ntfsfix.sh` on the most-recently-booted Windows partition at boot. Off by default: the repair script is not yet battle-tested.
- `LSL_BACKUP_DIR` (default: `<LSL_DATA_DIR>/backups`)
  - Where `lsl-win-backup.sh` writes the squashfs images and its `.state` files.
- `LSL_BACKUP_CONF` (default: `<LSL_BACKUP_DIR>/backup.conf`)
  - The backup job file (see [Backups and speed-ups](#backups-and-speed-ups)).
- `LSL_BACKUP_WINDOW_HOURS` (default: `24.1`)
  - The capture window for the first/incremental run when there is no previous
    run timestamp (slightly > 24h so daily cron jitter never skips a file).
- `LSL_BACKUP_INCR_SLACK_SEC` (default: `600`)
  - Overlap subtracted from the previous run's timestamp for each incremental run.
- `LSL_BACKUP_KEEP` (default: `7`)
  - Number of squashfs images retained per job before pruning the oldest.
- `LSL_SFS_HDD_CACHE` (default: `0`)
  - Set to `1` (by the installer wizard or `lsl-copy-sfs-hdd.sh --use`) so
    `lsl-precache.sh` warms the page cache from the HDD copy of the layers.

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

## Known limitations

- **Wi‑Fi secrets are plaintext on FAT** (`/cdrom/wifi.sh`). This is inherent:
  the live boot needs the passphrase with no interactive unlock. On HDD mode the
  secret can live in the encrypted `home.btrfs`; on USB/ FAT mode it stays
  readable by anyone with the stick. Uncheck "Copy Wifi Settings to LSL" (or
  delete `/cdrom/wifi.sh`) to avoid it; open networks need no secret and are
  safe to auto-connect. This is a deliberate design tradeoff, not a bug — any
  key material stored beside the boot files would be equally readable.
- **Out‑of‑tree drivers and Secure Boot.** First boot installs DKMS drivers
  (Realtek/Broadcom) that are *not* signed by the kernel key, so under Secure
  Boot they will not load unless a MOK is enrolled (or Secure Boot is off). Plan
  accordingly (see the Secure Boot section above).
- **Online btrfs growth is kernel‑limited.** `lsl-btrfs-growd` grows the backing
  file and refreshes the loop device, but some kernels silently ignore
  `losetup -c` while `/home` (or the cache) is busy; the new space then only
  applies after a reboot (or an unmount). The daemon logs this to
  `<LSL_DATA_DIR>/lsl-btrfs-grow.log` rather than failing silently.
- **`lsl-toram.sh` removes the USB.** After the pivot, persistence writes
  (uphome / uproot / lsl-home-flushd) are unavailable until the stick is
  re‑inserted; a concurrent persistence write is now refused for safety.



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
- `install.ps1` + `install.bat`: Windows installer with a WinForms wizard (ISO selection with Everything discovery, flatpak app preload detected from installed Windows apps, WSL VHDX paths, `LSL_DATA_DIR`, per-network wifi picker, network-driver preload, reuse-an-existing-USB). Auto-downloads the Mint 22.x ISO (incremental SHA-256 verify with progress + ETA) and Rufus (Authenticode-verified), writes the USB, drops the lsl layer + config, generates `wifi.sh` from Windows' saved profiles (netsh), and stages out-of-tree network drivers for this PC's chipsets to `<USB>\drivers\` (`.deb` from the Ubuntu archive, or DKMS source tarballs from GitHub - built at first boot). It also rates every detected device against the ISO kernel using linux-hardware.org LKDDb, served from the bundled `lsl-hw-cache/` so no network is needed for common hardware. Supports Ubuntu 24.04 based ISOs (Mint 22.x, Zorin 18.x - the live-session user is detected dynamically, not hardcoded to `mint`); refuses Ubuntu 26.04+ (it still uses NetworkManager, but its nmcli is broken, so the nmcli-based tooling breaks). `-NoGui` for the console flow; `-DryRun` for a detection report; `-SkipRufus` to write the image yourself and have the script pick up the USB; `-RateHardware` to rate all detected hardware (not just network).
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
- `tools/hw-cache-ids.txt` + `tools/build-hw-cache.ps1` + `tools/pciconf-top50.py`: the device-ID list (500 common PCI/USB devices: a hand-curated set plus PCIconf-derived devices — top-50 per functional class and the next-most-common consumer devices, tuned to consumer form factors), the polite one-time fetcher that builds `lsl-hw-cache/` (shipped in the bundle so the compatibility rating needs no network for common hardware), and the parser that derives the PCIconf sections from a clone of the corpus.
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

## Backups and speed-ups

### Backing up Windows folders to squashfs (daily)

`bin/lsl-win-backup.sh` backs up selected Windows folders (mounted under
`/mnt/c/...`) into squashfs images. Each *job* in `<LSL_BACKUP_DIR>/backup.conf`
specifies a source folder, optional include/exclude POSIX-ERE regexes (matched
against each file's path **relative to the source**), and a mode:

```bash
job Documents
source /mnt/c/Users/you/Documents
include \.txt$
include \.md$
exclude node_modules
exclude \.tmp$
mode both            # full | incremental | both
```

- `lsl-win-backup.sh --estimate` reports, per job, the file count, raw size, and
  an **estimated** squashfs size (from the ratio learned on the previous run, a
  quick sample compression, or a fallback factor), plus free space on the target.
- `lsl-win-backup.sh --run` writes `<job>_<timestamp>_full.squashfs` and/or
  `<job>_<timestamp>_incr.squashfs`. The incremental captures files modified
  since the previous run (minus `LSL_BACKUP_INCR_SLACK_SEC` of overlap), so a
  daily run never misses a file even with scheduling drift; the first run falls
  back to the `LSL_BACKUP_WINDOW_HOURS` (24.1h) window from now.
- `lsl-win-backup.sh --add-folder` interactively adds a job.
- A systemd timer runs it daily: `lsl-win-backup.sh --install-timer` (also enabled
  automatically by `config.sh`, where it is a no-op until jobs exist).

### Copying the squashfs layers to the NTFS HDD for speed

The Linux root layers (`/cdrom/casper/filesystem*.squashfs`) and `home.sfs` are
read from the USB by casper at boot. To speed up *post-boot* reads and reduce USB
wear, copy those layers to the internal HDD:

- The Windows installer wizard offers this on the config page (showing free space
  on the HDD(s)) and, if accepted, copies the layers into
  `<LSL_DATA_DIR>/sfs/` and sets `LSL_SFS_HDD_CACHE=1`.
- From Linux, `bin/lsl-copy-sfs-hdd.sh` is the ad-hoc counterpart: `--yes` copies
  (with a manifest + size/sha verify), `--status` shows which copies are current
  vs the USB, `--verify` re-checks them, and `--use`/`--no-use` toggle the flag.
- When `LSL_SFS_HDD_CACHE=1`, `lsl-precache.sh` warms the page cache from the
  HDD copies instead of the USB (and the copy is the source for `toram`).

**Boot-from-HDD auto-detect.** The initrd carries a mirror hook (built into
`casper/initrd.lz` by `build.sh`) that, at boot, scans local block devices, mounts
exactly one read-only (NTFS via the initrd's `ntfs-3g`, else native), and looks for
a `*/sfs/manifest.txt` carrying the LSL beacon. If every recorded layer is present
with the expected size (+ sha256 when recorded) it redirects the live root to that
mirror. Two hook implementations share the same scan/verify/mirror layout:

- **casper (Mint/Ubuntu):** `initramfs/lsl_hdd_mirror.sh` is a casper-premount
  hook that sets casper's `LAYERFS_PATH` to the multi-layer entry
  (`filesystem.z0.squashfs`, which casper stacks over `filesystem.squashfs`).
- **live-boot (Debian):** `initramfs/lsl_liveboot_mirror.sh` is a live-premount
  hook that exports `LIVE_MEDIA_PATH=sfs`, so live-boot's *own* `find_livefs`
  scanner discovers `sfs/*.squashfs` on the internal disk and assembles the root
  from it. No patching of live-boot internals is required.
- **antiX (32-bit x86):** `initramfs/lsl_antix_mirror.sh` is sourced by antiX's
  monolithic live-init just before `find_linuxfs_file`; it exports
  `SQFILE_FILE=sfs/filesystem.squashfs` and `FROM_BOOT=hd,usb` so antiX's own
  scanner adopts the mirror. (antiX only scans `usb,cd` by default, so the
  internal HDD must be explicitly enabled via `FROM_BOOT`.) This reuses the same
  `sfs/` mirror layout - antiX honours `SQFILE_FILE` pointing anywhere, so no
  duplicate `linuxfs` copy is needed.

In both cases `/cdrom` (bin/, onboot.sh, lsl-usb.env) stays on the USB, the hook
never panics and never changes the root, and if anything is missing or fails
verification it does nothing - casper/live-boot simply fall back to the USB
(which just boots a little slower). The **same mirror layout** (`sfs/filesystem.squashfs`
+ `sfs/filesystem.z0.squashfs` + `sfs/manifest.txt`) serves both frameworks, and a
cmdline flag `lsl_no_hdd_mirror` disables the hook entirely. The hook is
POSIX-`sh` and architecture-agnostic. The casper and live-boot variants run
unchanged on a 32-bit (i386) Debian live image; the antiX variant is itself a
32-bit live-init fork and is validated under `qemu-system-i386`. (antiX ships a
*different* live-init fork that uses `linuxfs` and its own `sq=`/`from=` levers
rather than `filesystem.squashfs`/`LIVE_MEDIA_PATH`, so it needs its own hook -
now implemented; it still shares the same `sfs/` mirror layout.)

**Safe initrd.** `build.sh` also preserves the original initrd as
`casper/initrd.safe.lz`, and `install.ps1` adds a "(safe)" boot-menu entry that
uses it (no mirror, pure USB) - so a suspect mirror can never brick the boot.

See `tests/qemu-hdd-mirror-test.sh` (casper/Mint) and
`tests/qemu-hdd-mirror-liveboot-test.sh` (live-boot/Debian) for end-to-end KVM boot
tests that build a USB image + an HDD mirror and assert the hook adopts it.

## Testing

```bash
# PowerShell harness (install.ps1) - mocks Get-Volume/registry/es.exe/netsh/WebClient
pwsh -NoProfile -File tests/install.ps1.tests.ps1

# Bash regression tests (bats)
bats tests/bash.tests.bats

# End-to-end KVM boot test: builds a USB image + an HDD mirror and asserts the
# auto-detect hook adopts the mirror (needs a Mint/Ubuntu ISO + /dev/kvm).
bash tests/qemu-hdd-mirror-test.sh /path/to/linuxmint.iso

# End-to-end KVM boot test for live-boot/Debian (mirror adoption + safe fallback).
# Needs a Debian live-boot ISO (e.g. debian-live-*-amd64-xfce.iso) + /dev/kvm.
bash tests/qemu-hdd-mirror-liveboot-test.sh /path/to/debian-live.iso

# End-to-end KVM boot test for antiX (32-bit x86) live-init + the HDD mirror
# (adopt + lsl_no_hdd_mirror fallback). Needs an antiX ISO + /dev/kvm.
bash tests/qemu-hdd-mirror-antix-test.sh /path/to/antiX-*-386-full.iso
```

CI (`.github/workflows/ci.yml`) runs both, plus shellcheck and `build.sh`, on every
push; a `v*` tag triggers a release with `dist/lsl-usb-win.zip` attached.

## Status / roadmap

See [`TODO.md`](TODO.md) for current experiments and next tasks.
