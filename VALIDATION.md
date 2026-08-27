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
  `squashfs_config.sh` before apt). If there is no network, first boot retries on
  the next boot (it does not silently proceed to a base image).

## 0. Automated pre-checks (run before burning time on real hardware)

These catch the two biggest unknowns without a physical boot:

- [ ] **Casper layer glob** — VERIFIED against `linuxmint-22.3-cinnamon-64bit.iso`:
      its initrd's `main/scripts/casper` globs `filesystem*.squashfs` (any suffix,
      line 91/142/647) and stacks them lexically with the **lexically-greatest
      file as the top layer**. Order is `filesystem.squashfs` (base) <
      `filesystem_z0_firstboot.squashfs` < `filesystem_z<timestamp>.squashfs`
      (appended layer, top), so the first-boot packages and unit appear on the
      second boot. `bash tests/casper-layer-check.sh` passes with the default glob.
      To re-verify on a different image:
      ```bash
      unmkinitramfs /cdrom/casper/initrd /tmp/ir && \
        grep -nE '\*\.squashfs' /tmp/ir/main/scripts/casper
      Casper_GLOB='<the glob you found>' bash tests/casper-layer-check.sh
      ```
- [ ] **`bash tests/mount_all.tests.sh`** passes (GPT/MBR drive-letter GUID
      resolution; the partition GUID must match `PARTUUID`).
- [ ] **`bash tests/lsl-common.tests.sh`** and **`build.sh`** pass locally.
- [ ] If `hivex-tools` / `btrfs-progs` are NOT in the base Mint live image,
      the first boot cannot mount `/mnt/c` or create `home.btrfs`; `onboot.sh`
      now falls back to a temporary tmpfs `/home` and warns, but HDD persistence
      only becomes real on the second boot. Verify both tools are present in the
      image you wrote (`which hivexget btrfs`; `apt-cache policy ...`).
- [ ] **Secure Boot off / Rufus DD mode** — this is a BIOS/MBR casper live USB,
      not a signed UEFI bootloader, so it will **not** boot on firmware with
      Secure Boot enabled. Check the firmware mode with `mokutil --sb-state` on
      any Linux box (`SecureBoot enabled` = won't boot there). With Rufus, write
      in "DD Image" mode (not "ISO" mode) so the stick boots like a real ISO;
      some UEFIs reject Rufus' "ISO" hybrid partition table.

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
- [ ] `lsl` / `lsl-gui` list the WSL distros from `lsl-wsl-vhdx.conf` and mount a
      vhdx via guestmount.

## 3. Persistence

- [ ] `uphome` flushes `/home` to `home.sfs`; reboot keeps home changes.
- [ ] `uproot` append and merge both work; the new layer boots.
- [ ] `lsl-toram.sh` (LSL_TORAM_TEST=1 first): copies root to RAM, no pivot.
- [ ] `lsl-toram.sh` full: pivot succeeds, USB removable, session continues.
      **Rollback**: if the pivot fails, hard-reset (the USB is untouched until the
      final unmount, and `lsl-diag.sh toram-pre` is captured beforehand).
      After the swap, uphome/uproot/lsl-home-flushd are unavailable until the USB
      is re-inserted.

## 4. Performance

- [ ] `lsl-precache-profile.sh` records a list; next boot `probe_ms` drops.
- [ ] `lsl-boot-time.sh` shows the before/after comparison.
- [ ] Full-image warm engages when the image < 50% RAM; memory floor stops it.

## Known-risky items (test with a sacrificial stick)

- `lsl-toram.sh` pivot_root — the only operation that can strand a session.
- First-boot apt installs — a network drop mid-install should retry next boot
  (Restart=on-failure), not wedge.
