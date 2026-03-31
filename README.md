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

## Persistence model

Mode is selected from resolved `LSL_DATA_DIR`:

- USB mode: path resolves under `/cdrom` or `/persist`.
- HDD mode: everything else (for example `/mnt/c/...`).

### HDD mode

- Creates loop-backed `home.btrfs` and `cache.btrfs` under `LSL_DATA_DIR`.
- Mounts `/home` from `home.btrfs`.
- Binds cache paths from `cache.btrfs`:
  - `/var/cache`
  - `/home/mint/.cache`
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

## Boot behavior

`onboot.sh` (via `onboot.service`) does the core runtime setup:

- Loads `/cdrom/lsl-usb.env`.
- Calls `mount_all.sh` for Windows drives.
- Applies USB/HDD home mode.
- Enables cache/Nix mount layout in HDD mode.
- Starts zram swap setup (configurable with `LSL_ZRAM_MIB`).
- Refreshes generated fstab block.
- Runs optional helpers like `wsl-boot-setup`.

## Project map

- `fetch.sh`: one-liner installer entrypoint.
- `install.sh`: image customization and initial setup.
- `onboot.sh`: runtime setup on every boot.
- `bin/config.sh`: sync scripts to `/cdrom`, install services/shortcuts/autostart entries.
- `bin/uphome`: persist/sync home data.
- `bin/uproot`: persist root image changes.
- `bin/lsl-common.sh`: shared config loading and mode detection logic.

## Status / roadmap

See [`TODO.md`](TODO.md) for current experiments and next tasks.
