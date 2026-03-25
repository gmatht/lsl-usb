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
2. **Set up the `lsl` and `lsl-gui` binaries** in `/cdrom/bin` and add them to PATH
3. **Create desktop shortcuts** for `lsl-gui` and `lsl-shutdown` on the Mint user's desktop
4. **Create a home filesystem** (`home.sfs`) from your current home directory
5. **Create an overlay filesystem** and install additional packages (guestmount, neovim, nix-bin, git, steam-installer, zenity)
6. **Generate a new filesystem.squashfs** with your customizations

### Usage

- **`lsl-gui`**: Launch the GUI to select and run a WSL distribution (double-click the desktop shortcut)
- **`lsl-shutdown-gui`**: GUI prompt to (optionally) run `uphome` and then shut down
- **`lsl`**: Command-line tool to launch WSL distributions
- **`uphome`**: Update the home.sfs filesystem snapshot
- **`uproot`**: Update the filesystem.squashfs with changes from the overlay

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
- Sets up overlay filesystems for home directory and Steam libraries
- Mounts external drives (Games, Windows partitions)
- Configures network connections

### Manual Installation

If you prefer to install manually:

```bash
git clone https://github.com/gmatht/lsl-usb.git
cd lsl-usb
sudo ./install.sh
```
