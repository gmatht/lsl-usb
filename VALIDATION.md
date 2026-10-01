# Real-hardware validation plan

Everything in this repo is unit-tested (PowerShell harness, bats) or CI-built, but
the end-to-end flow has never run on real hardware. This is the checklist for the
first real validation pass. Do it in order; each step is a prerequisite for the next.

## Prerequisites

- A Windows machine with Everything (voidtools) installed and its index current.
- A USB stick >= 16 GB (FAT32, Rufus-written Mint 22.x live USB).
- A second machine (or the same one) to boot the USB from.
- **First boot needs network for `apt`.** Prefer **wired Ethernet**; some wireless
  cards need firmware absent from the base image. For fully-offline first boots,
  drop `.deb` packages into `<USB>:/firmware/` before booting (installed by
  `squashfs_config.sh` before apt). The installer also stages the hivex `.debs`
  in `<USB>:/pkgs/` (see below). If there is no network, first boot retries on
  the next boot (it does not silently proceed to a base image).

## 0. Automated pre-checks (run before burning time on real hardware)

These catch the two biggest unknowns without a physical boot:

- [ ] **Casper layer order** — VERIFIED against `linuxmint-22.3-cinnamon-64bit.iso`:
      its initrd's `main/scripts/casper` globs `*.squashfs` and stacks the
      matches lexically with the **lexically-greatest file as the top layer**.
      Layer order is therefore carried entirely by the filenames:

      | rank | name | role |
      |---|---|---|
      | 1 | `filesystem.squashfs` | base (distro image) |
      | 2 | `filesystem_z0_firstboot.squashfs` | first-boot stub |
      | 3+ | `filesystem_z<timestamp>.squashfs` | appended layers, newest last |

      (`'_'` 0x5F > `'.'` 0x2E puts every `filesystem_z*` above the base;
      `'2'` > `'0'` puts the appends above the stub; the fixed-width timestamp
      makes lexical order equal chronological order.)

      **No `layerfs-path=` is passed on the kernel cmdline.** That flag selects
      casper's other branch, which walks dot-suffixes upward from one named
      file and `panic`s if a walked layer is missing — the scheme this project
      used until 2026-09-30 (see WHYFAIL14). Only `initramfs/lsl_hdd_mirror.sh`
      still sets it, to point at a single pre-merged layer on the internal disk.

      `bash tests/casper-layer-check.sh` asserts the names and the sort order.
      To re-verify on a different image:
      ```bash
      unmkinitramfs /cdrom/casper/initrd /tmp/ir && \
        grep -nE '\*\.squashfs|LAYERFS_PATH' /tmp/ir/main/scripts/casper
      Casper_GLOB='<the glob you found>' bash tests/casper-layer-check.sh
      ```
      Note the real glob is `*.squashfs`, NOT `filesystem*.squashfs`: any other
      `.squashfs` in the layer directory becomes an overlay layer.
- [ ] **`bash tests/mount_all.tests.sh`** passes (GPT/MBR drive-letter GUID
      resolution; the partition GUID must match `PARTUUID`).
- [ ] **`bash tests/lsl-common.tests.sh`** and **`build.sh`** pass locally.
- [ ] **hivex-tools / btrfs-progs on the base image.** If `hivex-tools` is NOT in
      the base Mint live image, `mount_all.sh` cannot map `/mnt/c`, so the first
      boot's `/home` falls back to a temporary tmpfs overlay. The installer now
      stages `libhivex0`/`libhivex-bin`/`libwin-hivex-perl` `.debs` to
      `<USB>:/pkgs/`, and `lsl_ensure_hivex_tools` installs them offline before
      `/home` mounts (`onboot.sh` / `lsl-mount-home.sh`), so this should no longer
      trigger. To verify: confirm `<USB>:/pkgs/` has the three `.debs`, and on the
      first boot check `/run/lsl-usb.state` says `LSL_MODE=hdd` (not
      `usb-fallback`) and that `/mnt/c` is mounted. If `/run/lsl-usb.mount-missing-hivex`
      exists, the early install failed (see `lsl-firstboot.home-failed` on the stick).
- [ ] **Rufus DD mode** — with Rufus, write in "DD Image" mode (not "ISO" mode)
      so the stick boots like a real ISO; some UEFIs reject Rufus' "ISO" hybrid
      partition table. **Secure Boot**: Mint ships a Microsoft-signed shim, so the
      USB normally boots under Secure Boot (you may need a one-time MOK enrollment
      on first boot - see the Secure Boot section below); if it will not start,
      disable Secure Boot in firmware. The installer now confirms this with you
      before writing (see "Secure Boot & Linux Mint" below).

### Test matrix (cover before declaring the hardware test passed)

- [ ] **Boot on at least one UEFI machine and one legacy/CSM (BIOS) machine** -
      the DD-mode hybrid ISO should boot both, but real firmware varies. Note the
      firmware entry you pick (e.g. "UEFI: SanDisk" vs "UEFI: SanDisk (Partition 2)")
      - some boards expose two entries for the same stick and only one boots.
- [ ] **Secure Boot is OFF** on the test machine (or the USB will not boot; the
      installer now warns about this *before* writing the stick).
- [ ] **`LSL_REPO` is set** in `install.bat` to your GitHub `owner/name` (shipped
      default `gmatht/lsl-usb`) so the auto-fetch of `lsl-usb-win.zip` works;
      otherwise keep `install.bat` beside the bundle, or set `LSL_RELEASE_URL`.
- [ ] **First boot is the long pole** (10-30 min apt). Use wired Ethernet and
      watch the zenity phases; if it wedges, the diagnostics tarball's new
      `hardware.txt` (lsblk/blkid//cdrom mount//proc/cmdline/casper layers)
      distinguishes DD-mode vs casper-glob vs space failures.

## Capture logs on failure

On any wedged first boot or `onboot` failure, `lsl-firstboot.sh` writes a
diagnostics tarball via `bin/lsl-diag.sh` to the first writable Windows-readable
location (`/mnt/c/lsl-diag`, `/persist/...`, else `/tmp`). **Copy that tarball off
before rebooting** — it contains the firstboot logs, `boot-times.log`, mount
state, and `dmesg`/`journalctl`. A failed first boot also drops
`/cdrom/casper/lsl-firstboot.FAILED` as a visible marker.

## 1. Windows install (install.bat)

- [ ] Run `install.bat`; the wizard appears within ~1 s (before any download).
- [ ] Page 1 shows the ISO radios (Everything-discovered) with the matching Mint
      version pre-selected; "Linux Mint Cinnamon is the recommended option" is shown.
- [ ] Pick an existing ISO (or let it download); progress bar + ETA move smoothly
      through download AND SHA-256 verification.
- [ ] Page 2 flatpak checkboxes populate (one per app, pre-checked for installed).
- [ ] Page 3: WSL VHDX paths pre-filled, `LSL_DATA_DIR` pre-filled with
      `/mnt/c/Users/<you>/lsl-usb`, wifi networks listed.
- [ ] Ctrl-C during the wizard: closes cleanly, no JIT dialogs, bat exits.
- [ ] Cancel: bat exits immediately (no pause).
- [ ] Rufus launches pre-selected; after the write, the wait detects the fresh
      volume (not an older Mint USB) within ~2 s of it appearing.
- [ ] `find_*.efu` files written to the USB (Everything export).
      Note: if Everything was auto-installed, its index builds in the background
      - the first export may be partial; re-run the installer (or wait) for the
      full index.

## 2. First boot (the critical path)

- [ ] USB boots; `lsl-firstboot.service` runs after network.
- [ ] The zenity progress dialog shows phases (waiting → installing → done).
- [ ] `uproot --auto-append` installs the recipe packages and appends a layer.
      Note: the apt installs are the long pole - expect 10-30 min on the first
      boot (network + package downloads). The progress dialog shows the phase.
- [ ] `/cdrom/casper/lsl-firstboot.done` exists; reboot happens.
- [ ] **Memory**: >= 4 GB RAM recommended for first boot. `guestmount`/`guestfish`
      are skipped automatically when RAM < 3 GB (VHDX mounting then unavailable),
      but the apt recipe alone can OOM low-RAM boxes — watch the log for OOM kills.
- [ ] Second boot: packages present, no firstboot re-run, `lsl-precache.service`
      active, `lsl-boot-time` records a row in `/cdrom/casper/boot-times.log`.
- [ ] `lsl` / and `lsl-gui` list the WSL distros from `lsl-wsl-vhdx.conf` and mount a
      vhdx via guestmount.

### Expected timing & what good looks like (first boot)

- **0-1 min** — USB boots, `lsl-firstboot.service` starts after network; the
  zenity dialog shows phase "waiting for network".
- **1-5 min** — network acquired; phase moves to "installing packages and packing
  layer". This is the long pole: **expect 10-30 min** of apt downloads/build.
- **~30-45 min** — `uproot --auto-append` finishes, `/cdrom/casper/lsl-firstboot.done`
  is written, the machine reboots.
- **Second boot (2-5 min)** — desktop appears; recipe packages are present; no
  firstboot dialog; `lsl-precache.service` runs; a row appears in
  `/cdrom/casper/boot-times.log`.

**What good looks like:** the zenity phases advance; `cat /cdrom/casper/lsl-firstboot.done`
exists after the first boot; on the second boot your installed apps are there and
`lsl-firstboot` does NOT run again.

**Things that should never happen (wedged - capture the diag tarball):**
- First boot sits on "waiting for network" >5 min on a working network -> captive
  portal or DNS issue (see the captive-portal lines in the firstboot log).
- `uproot` fails and after 5 attempts the USB reboots into the *base* Mint image
  (no recipe packages) -> `lsl-firstboot.FAILED` + `.FAILED.reason` will be on the
  USB; open a terminal and run `sudo bash /cdrom/bin/uproot --auto-append`.
- The USB will not boot at all with Secure Boot on without MOK enrollment (see
  below).

### Secure Boot & Linux Mint (what to do if it won't boot)

Linux Mint's ISO ships a **Microsoft-signed boot shim**, so the USB normally boots
under Secure Boot. If your machine's firmware has Secure Boot enabled:

1. Try booting first - it usually works. On the very first boot you may see a blue
   **MOK management** screen. Choose **Enroll MOK** (press Continue; the password
   is normally empty), then it boots. This enrolls Linux Mint's signing key so grub
   can load.
2. If it still will not start, reboot into your firmware setup (often F2 / Del /
   F12 at power-on -> Boot / Security / Authentication) and **disable Secure Boot**,
   then boot the USB again.
3. The installer warns you about this and asks for confirmation before writing -
   if you already enrolled the MOK (or disabled Secure Boot), just continue.

Note: this applies to UEFI boots. On legacy/CSM (BIOS) boots Secure Boot is not
involved at all.

**Verified on the 22.3 ISO (pre-hardware check):** the EFI boot chain is the
standard Ubuntu/Mint one - `boot/grub/efi.img` contains `EFI/boot/bootx64.efi`
(the **Microsoft-signed shim**) plus `EFI/boot/grubx64.efi` (Canonical-signed
grub), so the ISO itself is Secure-Boot capable and boots under SB without MOK
enrollment. The one real SB risk is **DKMS modules**: the first boot installs
out-of-tree drivers (e.g. `broadcom-sta-dkms`, `rtl8723bu`) that are *not*
signed by the kernel's key, so under Secure Boot they will **not load** unless a
MOK is enrolled for the custom key or Secure Boot is disabled. Plan for the
hardware test accordingly: either disable SB, or expect to enroll a MOK and
re-sign the DKMS modules (or accept no wifi until SB is off).

## 3. Persistence

> **Layer size / FAT32:** each `--auto-append` writes a *delta* layer (just your
> changes), bounded by a 4 GiB FAT32 file limit - `uproot` refuses an append that
> would exceed it. A single **merge** into one `filesystem.squashfs` packs the
> *entire* rootfs (base + changes) and CAN exceed 4 GiB; `uproot` also refuses a
> merge that would, on a FAT32 `/cdrom`. We keep `/cdrom` as FAT32 (not exFAT):
> grub's exFAT support in the Mint ISO is unreliable for booting, whereas stacked
> FAT32 delta layers are safe. **Prefer repeated appends over merging.**

- [ ] `uphome` flushes `/home` to `home.sfs`; reboot keeps home changes.
- [ ] `uproot` append and merge both work; the new layer boots.
- [ ] `lsl-toram.sh` (LSL_TORAM_TEST=1 first): copies root to RAM, no pivot.
- [ ] `lsl-toram.sh` full: pivot succeeds, USB removable, session continues.
      **Rollback**: if the pivot fails, hard-reset (the USB is untouched until the
      final unmount, and `lsl-diag.sh toram-pre` is captured beforehand).
      After the swap, uphome/uproot/lsl-home-flushd are unavailable until the USB
      is re-inserted.
- [ ] Boot to RAM (`ramclone`): on the `(Boot to RAM, no persistence)` entry,
      `dmsetup status clone` shows the clone device and `lsl-ramclone-status`
      reports a rising percent; the autostart dialog shows the copy progress and,
      at 100%, a **Detach USB** button. Clicking it powers off the stick and
      reports "It is now safe to remove your stick."; pulling it keeps the
      session alive. Repeat on the persistent `(Boot to RAM)` entry, and confirm
      a normal (non-RAM) boot shows no dialog.

## 4. Performance

- [ ] `lsl-precache-profile.sh` records a list; next boot `probe_ms` drops.
- [ ] `lsl-boot-time.sh` shows the before/after comparison.
- [ ] Full-image warm engages when the image < 50% RAM; memory floor stops it.

## Known-risky items (test with a sacrificial stick)

- `lsl-toram.sh` pivot_root — the only operation that can strand a session.
- First-boot apt installs — a network drop mid-install should retry next boot
  (Restart=on-failure), not wedge.
