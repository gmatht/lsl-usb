# lslsetup

Full reimplementation of lsl-usb's `install.ps1` (3040 lines of PowerShell) as
a **single native Windows executable**, built with the
[rust9x](https://github.com/rust9x) toolchain (`i686-rust9x-windows-msvc`) so
one binary runs on **Windows 95 → 11** — no PowerShell 5.1, no .NET, no
Windows Forms.

```
cargo +rust9x build --target i686-rust9x-windows-msvc
# -> target/i686-rust9x-windows-msvc/debug/lslsetup.exe
```

## Feature coverage vs install.ps1

Everything the PS script does is implemented:

- ISO resolve: existing ISO picker (Everything CLI + filesystem scan), fresh
  download (Mint 22.x by default, plus Lubuntu/Xubuntu/antiX/Zorin/Debian
  options from the GUI), SHA-256 verification against the official
  `sha256sum.txt`
- ISO validation (`Test-LiveIso`): casper layout, `.disk/info`, `dists`
  codenames, Ubuntu 26.04+ refusal
- Rufus: locate / auto-download from GitHub releases / Authenticode
  verification ("Akeo Consulting") / elevated launch / wait-for-USB with the
  stable-squashfs-size heuristic and prefer-fresh-volume logic
- Non-destructive write (`--write-mode nofmt`, the default):
  turns an already-formatted FAT32/NTFS stick into a live USB WITHOUT
  reformatting. Writes grub4dos boot code into the MBR boot-code area ONLY
  (bytes 0..440; disk signature, partition table and every file untouched),
  **plus the grub4dos stage1 continuation into sectors 1..15** (the stage1 is
  8192 bytes = 16 sectors; the BIOS loads only sector 0, and the stage1 reads
  sectors 1..15 to load the rest of itself — without them it dies with
  "Missing helper" and the stick is not bootable), copies `grldr` + the ISO as
  a regular file onto the stick and generates a
  `menu.lst` that loopback-boots the ISO (YUMI/Easy2Boot style). The grub4dos
  0.4.6a binaries are embedded (`assets/`, GPL-2, SHA-256-pinned). The target
  must really be a removable USB drive: DRIVE_REMOVABLE **and**
  IOCTL_STORAGE_QUERY_PROPERTY BusTypeUsb, mapped via
  IOCTL_STORAGE_GET_DEVICE_NUMBER; \(\\.\\)PhysicalDrive0, superfloppy
  and exFAT sticks are refused; the first 64 sectors are backed up before the
  one raw write and verified by read-back afterwards. `--usb-letter` pins the
  target, `--allow-fixed` deliberately relaxes only the removable check
  (never the USB-bus check). UEFI boots files-only from \EFI\BOOT: the
  DEFAULT loader is the bundled signed chain - Microsoft-signed shim ->
  Canonical-signed GRUB2 (`--uefi-loader signed`; works with Secure Boot ON
  or OFF) - with the unsigned grub4dos-for-UEFI `assets/BOOTX64.EFI`
  (`--uefi-loader grub4dos`; Secure Boot must be OFF) as the fallback, which
  mirrors its menu to \efi\grub\menu.lst, the only menu location that loader
  reads; `--uefi-bootx64 <file>` supplies any custom loader and wins over
  both. The INSTALL page has
  BIOS-boot and UEFI-boot checkboxes, on by default when the selected stick
  supports them and greyed out with the reason when not, plus a this-machine
  firmware line (booted UEFI/legacy, board UEFI/CSM capability via SMBIOS)
  that warns when the selection won't boot the current PC; a FAILED page offers
  Back-to-options to retry with another method. A "Check whole USB" checkbox
  (also `--check-usb`) fills free space with 4 GB pseudo-random chunks in
  DeleteMe\, reads every byte back with OS caching disabled, then deletes
  DeleteMe - catching dying and fake-capacity sticks. Win9x is refused
  (needs the NT
  \\.\\PhysicalDriveN namespace) and falls back to the Rufus flow

  **Configuration compatibility (grub4dos is picky — verified by
  `tests/qemu-boot-test.sh`):**
  - **MBR for BIOS, either for UEFI** — superfloppy (no partition table)
    sticks are refused; the grub4dos BIOS stage1 needs MBR sectors 1-15, so
    GPT sticks get a files-only UEFI install (no raw sectors touched, FAT32
    required) while MBR sticks can take both loaders at once.
  - **FAT32 or NTFS only** — exFAT (the default on many large sticks) is
    refused with a clear reason: grub4dos cannot read it, so the stick could
    not boot. FAT32 also caps the ISO at <4 GiB.
  - **The target volume must be the partition grub4dos will boot** — grub4dos's
    MBR stage1 boots the active (0x80) partition if one exists, else scans all
    partitions (including logical ones inside an extended partition). The
    installer refuses only the clear conflict: an active *filesystem*
    partition that is not the chosen volume (grub4dos would boot it instead).
    Extended partitions are fine — grub4dos scans into them and boots the
    logical FAT/NTFS partition. With no active partition and several
    partitions it warns that grub4dos may boot a different one.
  - **First partition must start after sector 15** — the grub4dos stage1
    continuation occupies sectors 1..15.
- lsl file drop (layer, bin/, systemd/, initramfs/, onboot.sh, lsl-usb.env,
  initrd.lz), build stamp, safe-boot GRUB + ISOLINUX entries
- Wifi: `netsh` profile/key extraction → `wifi.sh` (nmcli lines)
- Network driver staging: curated out-of-tree table (RTL8812AU/8814AU/8188EU/
  8723BU, BCM43142/4360/4352/4313), Ubuntu Packages.gz .deb URL resolution,
  GitHub DKMS tarballs, `lsl-drivers.txt`
- linux-hardware.org LKDDb rating (A/C/D/U) with per-user + bundle caches and
  robots.txt crawl-delay politeness
- WSL VHDX detection (registry Lxss HKCU/HKLM + Packages scan), flatpak ref
  preloading, Everything (voidtools) install + EFU index export, 32-bit Rust
  CLI tools (fd/bat/zoxide i686-musl) direct from GitHub
- Squashfs-to-HDD cache copy with sha256 manifest, `LSL_DATA_DIR` /
  `LSL_RECLAIM_WIN_SWAP` / `LSL_SFS_HDD_CACHE` env handling
- Boot: motherboard boot-menu key map, bcdedit one-time boot entry, "LSL -
  Reboot to Select USB" shortcuts, boot-choice dialog, reboot variants
- GUI: nwg-based config wizard (ISO choice, existing-USB reuse, flatpak
  picker, wifi networks, data dir, option checkboxes) — `--no-gui` gives the
  pure console flow. The Install click keeps the wizard open and does **all**
  downloads itself (ISO + Rufus) with live status/progress — no "type OK"
  console prompt in the GUI. On success it ends on a FINISHED summary page
  (window stays open) listing the chosen settings plus the equivalent command
  line so the exact choices can be re-run/automated headlessly (a **Copy**
  button puts it on the clipboard); on failure it shows a FAILED page with the
  reason and an **Open manual download** button instead of closing the windows
  with no explanation.
- `--dry-run`: the full detection report, plus a capability summary
- `--probe-os`: capability self-test (OS/UEFI/RAM/volumes/netsh/winhttp/PnP)

## Compiled-in LKDDb cache + sortable hardware page

- `build.rs` compiles `../../lsl-hw-cache/*.html` (the linux-hardware.org
  snapshot, 500 devices) into a ~92 KB per-device summary embedded in the
  binary — known hardware rates **instantly** with no network request and no
  10 s crawl-delay. Unknown devices still fall back to the on-disk caches and
  then a polite live fetch.
- The hardware page has real column headings; clicking a heading sorts by
  that column (Support sorts in rating order A < C < D < U) and toggles
  asc/desc with ▲/▼ arrows. Note: nwg's ListView defaults to `NO_HEADER` —
  `set_headers_enabled(true)` is required.

## Elevation

When not run as Administrator, the installer **self-relaunches elevated**:
it re-invokes its own exe with the same arguments via the `runas` verb (UAC
prompt), waits for the elevated instance and propagates its exit code.
Declining the prompt prints the manual instructions and exits 1. The
manifest is `asInvoker` (no installer-detection auto-elevation), and
`--no-elevation` skips the check entirely.

## Real-Windows verification (pwsh interop, Windows 11 24H2 host)

Tested on the actual host via WSL interop (`pwsh.exe`, see
`tests/win-gui-test.ps1`):

- `--probe-os`: OS Win10Plus, UEFI true, 63.9 GB RAM, 49 PnP devices via
  SetupAPI (2x Net, 2x Display, 2x SCSIAdapter, Bluetooth, Biometric, Camera),
  8 WSL VHDXs, Everything found, boot key F12, live HTTPS fetch of the Mint
  checksum through winhttp
- `--dry-run`: 9 ISOs found full-disk via Everything (incl. the two Mint 22.3
  copies + Zorin live), real wifi profiles via netsh, Killer E2600 + Wi-Fi 6
  AX1650x network hardware both rated **[A] in-kernel** against live
  linux-hardware.org LKDDb data
- GUI wizard: all 4 pages driven and screenshot-verified on the real desktop
  (Next, **Back**, column-heading sorting all click-tested); hardware page
  rates all 9 devices **instantly** from the compiled-in cache (A=5, U=4);
  flatpak page pre-checked Discord/VS Code/OBS/Steam/GIMP from the real
  install; page 3 shows real VHDX paths and 20 wifi networks
- Manifest `asInvoker` kills the UAC installer-detection heuristic that
  auto-elevated `*install*.exe` (the exe checks admin itself)
- The console download phase uses an explicit `OK` gate before pulling
  ~3 GB; the GUI flow never needs it (the wizard handles downloads itself)
- The GUI ends on a FINISHED / FAILED summary page that shows the automation
  command line (settings → CLI flags) instead of silently closing

## Bugs found by real-Windows testing (fixed)

- `SPDRP_CLASS` is 0x7 (0x8 = ClassGUID) — network devices were invisible
- `FIRMWARE_TYPE`: Uefi=2, Bios=1 — UEFI machines were reported as BIOS
- `MEMORYSTATUSEX` must be exactly 64 bytes (`dwLength` is validated)
- **nwg 1.0.13 `insert_column` hangs on real Windows**: `column_len()` loops
  `while LVM_GETCOLUMNWIDTH(n) != 0`, but comctl32 returns **-1** for
  out-of-range indices (wine returns 0, masking the bug). Columns are now
  inserted via direct `LVM_INSERTCOLUMNW`.
- **nofmt wrote only the first 446 bytes of `grldr.mbr` to the MBR** — the
  grub4dos stage1 is 8192 bytes = 16 sectors, and the BIOS loads only sector
  0; the stage1 then reads sectors 1..15 to load the rest of itself. Without
  them the stick died with "Missing helper" and was not bootable. Found by
  `tests/qemu-boot-test.sh`; the fix writes the stage1 continuation into
  sectors 1..15 (and refuses targets whose first partition starts inside
  them).

## Capability matrix (graceful degradation)

| Feature | install.ps1 needs | lslsetup needs | Fallback when unsupported |
|---|---|---|---|
| ISO mount/validate | Win8+ `Mount-DiskImage` | none | pure-Rust ISO9660 parser — works everywhere |
| PnP hardware enum | WMI (2000+) | registry only (NT `SYSTEM\CCS\Enum`, 9x `Enum`) | empty list + warning |
| HTTPS downloads | .NET TLS (PS 5.1) | `winhttp.dll` (2000+), TLS 1.2 requested | manual-download URL + exact destination printed |
| SHA-256 | .NET | pure-Rust `sha2` | always works |
| Authenticode | WinVerifyTrust (NT4+) | dynamic `wintrust.dll` | loud warning + explicit TRUST confirmation |
| Secure Boot query | Win8+ cmdlet | `GetFirmwareEnvironmentVariableW` (XP+) | `Unknown` on BIOS/9x |
| Admin check | Win8+ APIs | `IsUserAnAdmin` → token → assume admin (9x has no ACLs) | proceeds; USB writes fail loudly |
| RAM query | WMI | `GlobalMemoryStatusEx` → `GlobalMemoryStatus` (95) | always works |
| Archive extraction | PS 5.1 / Win10 tar | `zip` + `tar` crates in-process | always works |
| Wifi profiles | netsh (2000+) | netsh (2000+) | skipped with warning on 9x |
| GUI | .NET WinForms | nwg / native common controls | `--no-gui` console flow |
| UEFI one-time boot | Win8+ `shutdown /fw`, Vista+ bcdedit | same, feature-detected | boot-menu key hint + plain restart |
| MSIX/Store app names | `Get-AppxPackage` | `%LOCALAPPDATA%\Packages` scan | always works |

The statically-imported API surface is verified (via `llvm-objdump -p`) to
contain only Win9x-era exports of SHELL32/ADVAPI32/KERNEL32/ole32/USER32/
GDI32/COMCTL32; everything newer is resolved at runtime with GetProcAddress.
`sync`/`cfgmgr32` stub archives under `/opt/msvc-toolchains/stubs` absorb
`/DEFAULTLIB` markers emitted by rust9x's std without adding modern imports.

Caveat: the nwg GUI imports `COMCTL32` ordinals 410-413 (themed common
controls, IE4/2000-era). Console flow (`--no-gui`) avoids them.

## Libraries (this machine)

Same vintage toolchain setup as `../nwg-test`: Windows SDK v7.1A import libs
+ unicows.lib (`/opt/msvc-toolchains/sdk71a/Lib`), VC6 static CRT
(`/opt/msvc-toolchains/vc6/VC98Lib`), `panic = "abort"`, `/SAFESEH:NO`.
See `.cargo/config.toml`; modern VS2022/Win10-SDK paths are listed
commented-out for non-rust9x targets.

## Usage

Same options as install.ps1's parameter block, as long flags:

```
lslsetup.exe --help
lslsetup.exe --dry-run                       # detection report, writes nothing
lslsetup.exe --probe-os                      # capability self-test
lslsetup.exe --iso-path C:\ISO\zorin-18.1.iso
lslsetup.exe --skip-rufus --no-gui --volume-label "MINT"

# headless automation of the exact wizard choices (see the FINISHED page):
lslsetup.exe --iso-path C:\ISO\mint.iso --write-mode nofmt --usb-letter E \
  --data-dir D:\lsl --wifi-network Home --sfs-hdd-cache --reclaim-win-swap

# non-destructive: keep everything on the stick, no reformat (BIOS/CSM boot):
lslsetup.exe --write-mode nofmt --iso-path C:\ISO\linuxmint-22.3-cinnamon-64bit.iso
lslsetup.exe --write-mode nofmt --usb-letter E --iso-path C:\ISO\mint.iso   # pin the target
lslsetup.exe --write-mode nofmt --allow-fixed ...                            # allow a USB HDD (fixed)
lslsetup.exe --write-mode nofmt --uefi-bootx64 bootx64.efi ...               # optional UEFI files
```

Exit codes: 0 success, 1 fatal error, 2 user cancel.

## Testing

- `cargo +rust9x test --target i686-rust9x-windows-msvc` (10 unit tests,
  incl. the nofmt MBR/menu.lst logic and asset-hash pins)
- `tests/qemu-boot-test.sh` (Linux, needs qemu-system-i386 + grub-mkrescue +
  xorriso + sfdisk + mkfs.vfat, run as root): builds a disk image replicating
  exactly what the nofmt boot creator produces (using the real embedded
  `assets/grldr` + `assets/grldr.mbr`), boots it in QEMU, and verifies the
  whole chain — SeaBIOS → grub4dos MBR stage1 → grldr → menu.lst →
  loopback-map the ISO → chainload the ISO's bootloader — by grepping the
  serial console for a marker. It also asserts the stage1 continuation
  (sectors 1..15) is required (without it the image fails with "Missing
  helper"), that a no-active single-partition stick still boots (grub4dos
  scans), and that a logical partition inside an active extended partition
  boots (grub4dos scans into it).
- `tests/win-gui-test.ps1`, `tests/win-sort-test.ps1`, `tests/win-nav-test.ps1`
  (run on the Windows host): launch the wizard, navigate pages, click column
  headings and screenshot each state; `--probe-os` and `--dry-run` outputs are
  captured through pwsh interop. GUI tracing: set `LSL_GUI_DEBUG=1`.
