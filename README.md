# lsl-usb
Linux Services for Linux

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
3. **Create a desktop shortcut** for `lsl-gui` on the Mint user's desktop
4. **Create a home filesystem** (`home.sfs`) from your current home directory
5. **Create an overlay filesystem** and install additional packages (guestmount, neovim, nix-bin, git, steam-installer, zenity)
6. **Generate a new filesystem.squashfs** with your customizations

### Usage

- **`lsl-gui`**: Launch the GUI to select and run a WSL distribution (double-click the desktop shortcut)
- **`lsl`**: Command-line tool to launch WSL distributions
- **`uphome`**: Update the home.sfs filesystem snapshot
- **`uproot`**: Update the filesystem.squashfs with changes from the overlay

### Requirements

- Linux Mint 22.2 or similar Linux distribution
- Root/sudo access
- A USB drive mounted at `/cdrom`
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
