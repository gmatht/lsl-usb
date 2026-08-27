# Real-hardware validation plan

Everything in this repo is unit-tested (PowerShell harness, bats) or CI-built, but
the end-to-end flow has never run on real hardware. This is the checklist for the
first real validation pass. Do it in order; each step is a prerequisite for the next.

## Prerequisites

- A Windows machine with Everything (voidtools) installed and its index current.
- A USB stick >= 16 GB (FAT32, Rufus-written Mint 22.x live USB).
- A second machine (or the same one) to boot the USB from.

## 0. Automated pre-checks (run before burning time on real hardware)

These catch the two biggest unknowns without a physical boot:

- [ ] **Casper layer glob** — confirm the appended `filesystem_z*.squashfs`
      layers are actually picked up by the target Mint initrd. Extract it and
      check the glob, then run the check:
      ```bash
      unmkinitramfs /cdrom/casper/initrd . && \
        grep -nE 'filesystem.*squashfs' ./main/scripts/casper
      Casper_GLOB='<the glob you found>' bash tests/casper-layer-check.sh
      ```
      If a layer is reported as *skipped*, the second boot will not see the
      first-boot packages (or the firstboot unit). Rename the layers or patch
      the initrd before proceeding.
- [ ] **`bash tests/mount_all.tests.sh`** passes (GPT/MBR drive-letter GUID
      resolution; the partition GUID must match `PARTUUID`).
- [ ] **`bash tests/lsl-common.tests.sh`** and **`build.sh`** pass locally.
- [ ] If `hivex-tools` / `btrfs-progs` are NOT in the base Mint live image,
      the first boot cannot mount `/mnt/c` or create `home.btrfs`; `onboot.sh`
      now falls back to a temporary tmpfs `/home` and warns, but HDD persistence
      only becomes real on the second boot. Verify both tools are present in the
      image you wrote (`which hivexget btrfs`; `apt-cache policy ...`).

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
- [ ] Second boot: packages present, no firstboot re-run, `lsl-precache.service`
      active, `lsl-boot-time` records a row in `/cdrom/casper/boot-times.log`.
- [ ] `lsl` / `lsl-gui` list the WSL distros from `lsl-wsl-vhdx.conf` and mount a
      vhdx via guestmount.

## 3. Persistence

- [ ] `uphome` flushes `/home` to `home.sfs`; reboot keeps home changes.
- [ ] `uproot` append and merge both work; the new layer boots.
- [ ] `lsl-toram.sh` (LSL_TORAM_TEST=1 first): copies root to RAM, no pivot.
- [ ] `lsl-toram.sh` full: pivot succeeds, USB removable, session continues.
      **Rollback**: if the pivot fails, reboot (the USB is untouched until the
      final unmount).

## 4. Performance

- [ ] `lsl-precache-profile.sh` records a list; next boot `probe_ms` drops.
- [ ] `lsl-boot-time.sh` shows the before/after comparison.
- [ ] Full-image warm engages when the image < 50% RAM; memory floor stops it.

## Known-risky items (test with a sacrificial stick)

- `lsl-toram.sh` pivot_root — the only operation that can strand a session.
- First-boot apt installs — a network drop mid-install should retry next boot
  (Restart=on-failure), not wedge.
