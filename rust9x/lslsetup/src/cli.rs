//! Command-line options (mirrors install.ps1's param block).

#[derive(Debug, Clone)]
pub struct Opts {
    pub iso_path: String,
    pub mint_version: String,
    pub download_dir: String,
    pub bundle_dir: String,
    pub rufus_path: String,
    pub volume_label: String,
    pub write_mode: String,     // "rufus" (default) | "nofmt" (non-destructive grub4dos)
    pub write_mode_set: bool,   // --write-mode was passed explicitly
    pub usb_letter: String,     // --usb-letter <X>: pick the nofmt target
    pub allow_fixed: bool,      // --allow-fixed: override removable+USB checks
    pub uefi_bootx64: String,   // optional BOOTX64.EFI for the nofmt stick
    pub uefi_loader: String,    // nofmt UEFI loader: auto|signed|grub4dos (also applied via nofmt::set_uefi_loader_override)
    pub bios_boot: bool,        // nofmt: install the grub4dos BIOS path (default on)
    pub uefi_boot: bool,        // nofmt: install the UEFI files (default on)
    pub check_usb: bool,        // fill free space with PRNG data + read-back verify (default off: slow)
    pub skip_verify: bool,      // skip the post-copy ISO re-read (default off: faster, less safe)
    pub wsl_vhdx: Vec<String>,
    pub flatpak_apps: Vec<String>,
    pub extra_isos: Vec<String>,
    pub skip_iso_download: bool,
    pub skip_rufus: bool,
    pub no_gui: bool,
    pub dry_run: bool,
    pub rate_hardware: bool,
    pub no_elevation: bool,
    pub preload_rust_tools: bool,
    pub probe_os: bool,
    pub gui_test_boot_dialog: bool,
    pub gui_test_modal_clicks: bool,
    // settings the GUI also collects, exposed as flags so a FINISHED-page
    // command line can reproduce the exact wizard choices headlessly
    pub data_dir: String,
    pub wifi: bool,             // copy wifi profiles (default on)
    pub wifi_networks: Vec<String>,
    pub efu: bool,              // write the Everything EFU index (default on)
    pub drivers: bool,          // stage network drivers (default on)
    pub sfs_hdd: bool,          // copy squashfs to the HDD cache
    pub reclaim_win_swap: bool, // reclaim the Windows swapfile
}

impl Default for Opts {
    fn default() -> Self {
        let bundle_dir = {
            // %~dp0 equivalent: the directory containing this exe
            let exe = std::env::current_exe().map(|p| p.to_string_lossy().into_owned());
            match exe {
                Ok(e) => match e.rfind('\\') {
                    Some(i) => e[..i].to_string(),
                    None => ".".into(),
                },
                Err(_) => ".".into(),
            }
        };
        Opts {
            iso_path: String::new(),
            mint_version: "22.3".into(),
            download_dir: String::new(),
            bundle_dir,
            rufus_path: String::new(),
            volume_label: String::new(),
            write_mode: "rufus".into(),
            write_mode_set: false,
            usb_letter: String::new(),
            allow_fixed: false,
            uefi_bootx64: String::new(),
            uefi_loader: "auto".into(),
            bios_boot: true,
            uefi_boot: true,
            check_usb: false,
            skip_verify: false,
            wsl_vhdx: Vec::new(),
            flatpak_apps: Vec::new(),
            extra_isos: Vec::new(),
            skip_iso_download: false,
            skip_rufus: false,
            no_gui: false,
            dry_run: false,
            rate_hardware: false,
            no_elevation: false,
            preload_rust_tools: false,
            probe_os: false,
            gui_test_boot_dialog: false,
            gui_test_modal_clicks: false,
            data_dir: String::new(),
            wifi: true,
            wifi_networks: Vec::new(),
            efu: true,
            drivers: true,
            sfs_hdd: false,
            reclaim_win_swap: false,
        }
    }
}

pub const USAGE: &str = "\
Usage: lslsetup [options]

Options:
  --iso-path <path>          Path to an existing live ISO
  --mint-version <ver>       Mint 22.x point release to download (default 22.3)
  --download-dir <dir>       Folder for the downloaded ISO (default Downloads)
  --bundle-dir <dir>         lsl files to drop onto the USB (default: exe dir)
  --rufus-path <path>        Path to rufus.exe (auto-downloaded if missing)
  --write-mode <mode>        rufus (default, DD-style write) or nofmt
                             (non-destructive: grub4dos MBR-code write +
                             kernel/base extracts (no ISO file) + direct-kernel
                             menu.lst + BOOTX64.EFI/grub.cfg for UEFI (BIOS + UEFI);
                             the stick must already be FAT32/NTFS)
  --usb-letter <X>           Drive letter for the nofmt target (else a picker)
  --allow-fixed              Allow non-removable targets in nofmt mode
  --uefi-bootx64 <path>      Optional custom BOOTX64.EFI for nofmt UEFI
                             booting (installed as-is; wins over the loader
                             picked below)
  --uefi-loader <auto|signed|grub4dos>
                             nofmt UEFI loader: signed (Microsoft shim +
                             Canonical-signed GRUB2 - works with Secure Boot
                             ON, the default when that chain is bundled),
                             grub4dos (unsigned grub4dos-for-UEFI; Secure
                             Boot must be OFF), auto (best default; a
                             --uefi-bootx64 file also takes priority)
  --no-bios-boot             nofmt: skip the grub4dos BIOS path (UEFI files only)
  --no-uefi-boot             nofmt: skip the UEFI files (BIOS path only)
  --check-usb                After writing: fill free space with PRNG test
                             data in DeleteMe, read it all back uncached
                             (bypasses the OS cache), then delete it
  --skip-verify              Skip the post-copy ISO re-read (fresh copies
                             only; reuse always verifies. Faster, less safe)
  --volume-label <label>     USB volume label to target
  --wsl-vhdx <path>          Extra WSL VHDX path (repeatable)
  --flatpak-apps <id>        Extra flatpak app id (repeatable)
  --extra-iso <path>         Extra ISO to add as a loopback-only boot entry
                             (repeatable; no firstboot, no squashfs unpack -
                             the primary --iso-path keeps firstboot)
  --skip-iso-download        Do not offer to download a Mint ISO
  --skip-rufus               Do not launch Rufus; wait for a Mint live USB
  --no-gui                   Console-only flow (no config dialog)
  --dry-run                  Detection-only mode; writes nothing
  --rate-hardware            With --dry-run: rate ALL PCI/USB devices
  --no-elevation             Skip the administrator check
  --gui-test-boot-dialog     (test) show only the boot-choice dialog, print the choice, exit
  --gui-test-modal-clicks    (test) headless modal-loop click probe, print CLICK-OK/CLICK-DEAD
  --preload-rust-tools       Download fd/bat/zoxide onto <USB>:\\bin
  --data-dir <path>           LSL_DATA_DIR to write into lsl-usb.env
  --no-wifi                   Do not copy wifi profiles
  --wifi-network <name>       Copy only this wifi profile (repeatable)
  --no-efu                    Do not write the Everything EFU index
  --no-drivers                Do not stage out-of-tree network drivers
  --sfs-hdd-cache             Copy the squashfs to the HDD cache
  --reclaim-win-swap          Reclaim the Windows swapfile
  --help                     This text
";

pub fn parse(args: &[String]) -> Result<Opts, String> {
    let mut o = Opts::default();
    let mut it = args.iter();
    while let Some(a) = it.next() {
        let mut next = || -> Result<String, String> {
            it.next().cloned().ok_or_else(|| format!("missing value for {}", a))
        };
        match a.as_str() {
            "--iso-path" | "-i" => o.iso_path = next()?,
            "--mint-version" => o.mint_version = next()?,
            "--download-dir" => o.download_dir = next()?,
            "--bundle-dir" => o.bundle_dir = next()?,
            "--rufus-path" => o.rufus_path = next()?,
            "--volume-label" => o.volume_label = next()?,
            "--write-mode" => {
                o.write_mode = next()?.to_ascii_lowercase();
                o.write_mode_set = true;
                if o.write_mode != "rufus" && o.write_mode != "nofmt" {
                    return Err("--write-mode must be 'rufus' or 'nofmt'".into());
                }
            }
            "--usb-letter" => o.usb_letter = next()?,
            "--allow-fixed" => o.allow_fixed = true,
            "--uefi-bootx64" => o.uefi_bootx64 = next()?,
            "--uefi-loader" => {
                let v = next()?.to_ascii_lowercase();
                o.uefi_loader = v.clone();
                let loader = match v.as_str() {
                    "auto" => crate::nofmt::UefiLoader::Auto,
                    "signed" => crate::nofmt::UefiLoader::Signed,
                    "grub4dos" => crate::nofmt::UefiLoader::Grub4dos,
                    _ => return Err("--uefi-loader must be one of auto, signed, grub4dos".into()),
                };
                crate::nofmt::set_uefi_loader_override(loader);
            }
            "--no-bios-boot" => o.bios_boot = false,
            "--no-uefi-boot" => o.uefi_boot = false,
            "--check-usb" => o.check_usb = true,
            "--skip-verify" => o.skip_verify = true,
            "--wsl-vhdx" => o.wsl_vhdx.push(next()?),
            "--flatpak-apps" => o.flatpak_apps.push(next()?),
            "--extra-iso" => o.extra_isos.push(next()?),
            "--skip-iso-download" => o.skip_iso_download = true,
            "--skip-rufus" => o.skip_rufus = true,
            "--no-gui" => o.no_gui = true,
            "--dry-run" => o.dry_run = true,
            "--rate-hardware" => o.rate_hardware = true,
            "--no-elevation" => o.no_elevation = true,
            "--preload-rust-tools" => o.preload_rust_tools = true,
            "--probe-os" => o.probe_os = true,
            "--gui-test-boot-dialog" => o.gui_test_boot_dialog = true,
            "--gui-test-modal-clicks" => o.gui_test_modal_clicks = true,
            "--data-dir" => o.data_dir = next()?,
            "--no-wifi" => o.wifi = false,
            "--wifi-network" => o.wifi_networks.push(next()?),
            "--no-efu" => o.efu = false,
            "--no-drivers" => o.drivers = false,
            "--sfs-hdd-cache" => o.sfs_hdd = true,
            "--reclaim-win-swap" => o.reclaim_win_swap = true,
            "--help" | "-h" => return Err(USAGE.to_string()),
            other => return Err(format!("unknown option: {}\n\n{}", other, USAGE)),
        }
    }
    Ok(o)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn parses_new_automation_flags() {
        let o = parse(&args(&[
            "--data-dir", "D:\\lsl",
            "--no-wifi",
            "--wifi-network", "Home",
            "--wifi-network", "Office",
            "--no-efu",
            "--no-drivers",
            "--sfs-hdd-cache",
            "--reclaim-win-swap",
            "--preload-rust-tools",
            "--extra-iso", "D:\\a.iso",
            "--extra-iso", "D:\\b.iso",
        ]))
        .unwrap();
        assert_eq!(o.data_dir, "D:\\lsl");
        assert!(!o.wifi);
        assert_eq!(o.wifi_networks, vec!["Home".to_string(), "Office".to_string()]);
        assert!(!o.efu);
        assert!(!o.drivers);
        assert!(o.sfs_hdd);
        assert!(o.reclaim_win_swap);
        assert!(o.preload_rust_tools);
        assert_eq!(o.extra_isos, vec!["D:\\a.iso".to_string(), "D:\\b.iso".to_string()]);
    }

    #[test]
    fn defaults_match_gui_defaults() {
        let o = parse(&args(&[])).unwrap();
        assert!(o.wifi);
        assert!(o.efu);
        assert!(o.drivers);
        assert!(!o.sfs_hdd);
        assert!(!o.reclaim_win_swap);
        assert!(o.data_dir.is_empty());
        assert!(o.wifi_networks.is_empty());
        assert!(o.extra_isos.is_empty());
    }
}
