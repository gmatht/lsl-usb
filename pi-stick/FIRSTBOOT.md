# LSL-USB first boot — mission brief (read me first, pi agent)

You are running on a **Linux Mint 22.3 live USB** built by `lslsetup.exe`
(non-destructive: FAT32 stick, nothing reformatted). Your job: finish and
verify the **first-boot setup** described below. The stick is `/cdrom`.

## 1. What we are trying to do

Turn a plain Mint ISO stick into a self-installing portable workstation:

1. Boot the stick (direct-kernel entry, no ISO file on the stick).
2. `lsl-firstboot.service` (oneshot, from the `filesystem.z0` stub layer)
   finds the stick, waits for network, then runs `/cdrom/bin/uproot
   --auto-append`: it installs packages (Brave, nvim, rust tools, flatpaks…)
   per `/cdrom/bin/squashfs_config.sh` inside an overlay chroot and packs
   ONLY the changes into a new dotted layer
   `casper/filesystem.z0.<timestamp>.squashfs`.
3. It stamps `casper/lsl-firstboot.done` and reboots. Next boot stacks
   base + z0 + timestamped layer → Brave/nvim live. Proven before in QEMU.

## 2. Current status (2026-09-15)

- Install on the stick is **complete and verified**: kernel/initrd under
  `_ISO/linuxmint-22.3-cinnamon-64bit/`, base squashfs + z0 in `casper/`,
  signed UEFI chain in `EFI/BOOT/`, BIOS `grldr` + `menu.lst`, toolkit in
  `bin/`, 6 wifi networks staged in `wifi.sh`.
- **Network now works** (wifi `eero` connected; the old "no network" loop was
  an out-of-range machine — cable/tether still the fastest fix if it drops).
- **Blocker: the appended layer hit the FAT32 4 GiB file cap.** The overlay
  upper reached ~7.2 GiB (5.2 G baked-in flatpaks + Brave + apt), so uproot
  refused and the service crash-looped on a poisoned overlay. Fix deployed:
  flatpaks install into the FAT-hosted `lsl-fat` installation as direct
  files (builder pre-installs them; firstboot only mounts, sideloads, or
  downloads into FAT as fallback) and never enter the layer; the append
  path excludes `var/lib/flatpak`, failures tear down the overlay, and
  deterministic refusals stop immediately with FAILED + dialog instead of
  retrying. Non-flatpak changes are only ~2 GiB — comfortably under the cap.
- Fixes already deployed on this stick: wifi/onboot/diag scripts run via
  `bash` with `-r` gates (FAT has no exec bit — the old `-x` gates silently
  skipped everything); failure tarballs go to `/cdrom/lsl-diag/` (survive
  reboot); no-network failures write `lsl-firstboot.FAILED` + reason and pop
  a desktop Error dialog (autostart + best-effort immediate).

## 3. Key paths (all on /cdrom unless noted)

- `casper/lsl-firstboot-logs/firstboot-<ts>.log` — per-attempt log (tail it).
- `casper/lsl-firstboot.done` — success stamp (absent = not done yet).
- `casper/lsl-firstboot.FAILED` + `.FAILED.reason` — visible failure state.
- `casper/lsl-firstboot.no-network` — offline attempt counter.
- `lsl-diag/lsl-firstboot-no-network-<ts>.tar.gz` — full snapshot incl.
  `network.txt` (ip/nmcli/rfkill/scan), `dmesg-net.txt` (firmware),
  `journal-NetworkManager.txt`, staged `wifi.sh`.
- `bin/uproot`, `bin/squashfs_config.sh`, `bin/lsl-diag.sh`, `wifi.sh`.
- Guest scripts: `lsl-firstboot.sh` runs from `/usr/local/sbin`
  (from the z0 layer, NOT the stick copy — the stick holds no copy).

## 4. How to continue (in this live session)

```bash
# where is firstboot?
systemctl is-active lsl-firstboot onboot
tail -n 20 /cdrom/casper/lsl-firstboot-logs/$(ls /cdrom/casper/lsl-firstboot-logs | sort | tail -n 1)
# network right now?
nmcli dev status; nmcli radio wifi; ip link
nmcli -f SSID,SIGNAL,SECURITY dev wifi list
# force a diagnostics tarball any time:
bash /cdrom/bin/lsl-diag.sh manual
# retry the install step by hand (needs network):
sudo bash /cdrom/bin/uproot --auto-append
```

Bounded waits only; never loop forever. Failures must stay loud (log +
FAILED marker + dialog). The service restarts itself on failure.

## 5. This agent

- Launched via `bash /cdrom/pi/pi.sh` (seeds `~/.pi/agent/auth.json` from
  the stick, stages node to /tmp, runs pi 0.85.1 on node v24.21.0).
- Model/auth: provider `opencode-go`, model `muse-spark`; keys are in
  `/cdrom/pi/auth.json`. **These keys live on this FAT stick in the clear**
  (same threat model as the wifi passwords in `wifi.sh`): do not copy the
  stick contents anywhere untrusted, do not paste keys into chats/logs.
- Sessions persist only in RAM (`$HOME`); the stick keeps code+logs+docs.

## 6. Source repo (NOT on this stick)

`lslsetup.exe` and all guest scripts are built from `C:/GitHub/lsl-usb`
(`rust9x/lslsetup`, `bin/`, `misc/`, `onboot.sh`) on the Windows builder.
Changes you make to stick files are live-test overlays; lasting fixes must
be re-applied to that repo (ask the operator — they have the checkout).
