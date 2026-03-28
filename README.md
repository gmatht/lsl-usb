# lsl-usb
Linux Services for Linux

WSL (Windows Subsystem for Linux) is the Killer Windows 11 feature. This project is a reimplementation of WSL for Linux—so Linux can finally run Linux Services—and will undoubtedly usher in the **Year of the Linux Desktop**.

## Quickstart

### Installation

Install [Linux Cinnamon Mint 22.2](https://linuxmint.com/download.php) or a similar distribution onto a USB stick using [Rufus](https://rufus.ie/). Boot the USB stick, then download and install lsl-usb directly from GitHub:

```bash
curl -fsSL https://raw.githubusercontent.com/gmatht/lsl-usb/main/fetch.sh | sudo bash
```

### What it does

The installation script (`install.sh`) will:

1. **Create a systemd service** (`onboot.service`) that runs on boot
2. **Install `lsl-usb.env` on `/cdrom`** — edit this file on the FAT partition to set where data lives (`LSL_DATA_DIR`, default `/mnt/c/Users/lsl-usb`)
3. **Set up the `lsl` and `lsl-gui` binaries** in `/cdrom/bin` and add them to PATH
4. **Create desktop shortcuts** for `lsl-gui` and `lsl-shutdown-gui`
5. **Create a home filesystem** (`home.sfs`) from your current home directory
6. **Create an overlay filesystem** and install additional packages (including `btrfs-progs`, guestmount, neovim, nix-bin, git, steam-installer, zenity)
7. **Generate a new filesystem.squashfs** with your customizations
8. **Enable `lsl-home-flushd` and `lsl-btrfs-growd`** — see persistence modes below

### Persistence modes

Configuration is read from `/cdrom/lsl-usb.env`. The resolved **`LSL_DATA_DIR`** path selects the mode:

| Mode | When | Home | Caches | Background |
|------|------|------|--------|------------|
| **HDD** | `LSL_DATA_DIR` is **not** under `/cdrom` or `/persist` (e.g. NTFS under `/mnt/c/...`) | Loop **`home.btrfs`** with `compress=zstd` | **`cache.btrfs`**: bind-mounts over `/var/cache` and `/home/mint/.cache` | **`lsl-btrfs-growd`** extends `home.btrfs` when free space is low |
| **USB** | Path is under **`/cdrom`** or **`/persist`** | **`home.sfs`** lower + **tmpfs** overlay upper at `/run/lsl-home-overlay` | (unchanged; use `persist.btrfs` for logs if configured) | **`lsl-home-flushd`** flushes merged `/home` to **`/cdrom/home.sfs`** after **`LSL_HOME_IDLE_SEC`** (default 300) seconds of inactivity |

- **`uphome`**: On **USB**, runs a full **mksquashfs** flush to the stick (same as the idle daemon, but immediate). On **HDD**, runs **`btrfs filesystem sync`** on `/home` and the cache volume (no squashfs).
- **`lsl-shutdown-gui`**: On save, uses the same `uphome` behavior, then unmounts (HDD: cache + home btrfs; USB: existing VFAT cleanup).

### Manual migration (HDD, first boot)

If `home.btrfs` is new and empty but you still have **`/cdrom/home.sfs`**, you can one-time seed your profile (example):

```bash
sudo mkdir -p /mnt/seed && sudo mount /cdrom/home.sfs /mnt/seed
sudo rsync -a /mnt/seed/mint/ /home/mint/
sudo umount /mnt/seed
```

### Persisting changes (and reverting them)

This system boots from read-only SquashFS images and uses an overlay filesystem at runtime. That means:

- **Changes you make during a session may not survive a reboot** unless you *bake them back into the images*.
- **`uphome`** persists changes under `/home` by rebuilding `/cdrom/home.sfs`.
- **`uproot`** persists system/package changes by rebuilding `/cdrom/casper/filesystem.squashfs`.

Both commands make timestamped backups before replacing the current image:

- **Home backup**: `/cdrom/home_YYYYmmddHHMMSS.sfs`
- **Root backup**: `/cdrom/casper/filesystem_YYYYmmddHHMMSS.squashfs`

#### Revert from Windows

You can undo both the **repo edits** and any **persisted image changes** from Windows.

- **Revert the git-tracked files (e.g. README changes)**:

```bash
git restore README.md bin/lsl-gui bin/uproot
```

If you’re running this from Windows PowerShell, point `git` at the repo on the USB drive:

```powershell
git -C E:\path\to\lsl-usb restore README.md bin\lsl-gui bin\uproot
```

- **Revert persisted `uphome` changes**:
  - On the USB drive, replace `home.sfs` with one of the backups (pick the timestamp you want).
  - Concretely: rename the current `home.sfs` (or delete it) and rename `home_YYYYmmddHHMMSS.sfs` to `home.sfs`.

- **Revert persisted `uproot` changes**:
  - On the USB drive, go to `casper\` and replace `filesystem.squashfs` with one of the backups.
  - Concretely: rename the current `filesystem.squashfs` and rename `filesystem_YYYYmmddHHMMSS.squashfs` to `filesystem.squashfs`.

### Requirements

- Linux Mint 22.2 or similar Linux distribution installed on a USB using Rufus or similar.
- Network connectivity (for downloading packages)

### Boot Configuration

The `onboot.sh` script runs automatically on boot and:

- Sources **`/cdrom/lsl-usb.env`** and mounts **`/mnt/c`** / **`/mnt/d`** when possible
- Sets up **Steam library overlays** (best-effort if drives exist)
- Applies **HDD** or **USB** home layout as above
- Optionally mounts **`/cdrom/posix`** at **`/x`** via **`fat-linux-meta-fs`** (permissive mode) when that helper exists
- Configures network connections (Wi‑Fi via `/cdrom/wifi.sh`)

### Manual Installation

```bash
git clone https://github.com/gmatht/lsl-usb.git
cd lsl-usb
sudo ./install.sh
```
