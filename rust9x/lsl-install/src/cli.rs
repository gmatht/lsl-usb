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
    pub wsl_vhdx: Vec<String>,
    pub flatpak_apps: Vec<String>,
    pub skip_iso_download: bool,
    pub skip_rufus: bool,
    pub no_gui: bool,
    pub dry_run: bool,
    pub rate_hardware: bool,
    pub no_elevation: bool,
    pub preload_rust_tools: bool,
    pub probe_os: bool,
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
            wsl_vhdx: Vec::new(),
            flatpak_apps: Vec::new(),
            skip_iso_download: false,
            skip_rufus: false,
            no_gui: false,
            dry_run: false,
            rate_hardware: false,
            no_elevation: false,
            preload_rust_tools: false,
            probe_os: false,
        }
    }
}

pub const USAGE: &str = "\
Usage: lsl-install [options]

Options:
  --iso-path <path>          Path to an existing live ISO
  --mint-version <ver>       Mint 22.x point release to download (default 22.3)
  --download-dir <dir>       Folder for the downloaded ISO (default Downloads)
  --bundle-dir <dir>         lsl files to drop onto the USB (default: exe dir)
  --rufus-path <path>        Path to rufus.exe (auto-downloaded if missing)
  --write-mode <mode>        rufus (default, DD-style write) or nofmt
                             (non-destructive: grub4dos MBR-code write + the
                             ISO copied as a file + menu.lst loopback; the
                             stick must already be FAT32/NTFS)
  --usb-letter <X>           Drive letter for the nofmt target (else a picker)
  --allow-fixed              Allow non-removable targets in nofmt mode
  --uefi-bootx64 <path>      Optional BOOTX64.EFI for nofmt UEFI booting
  --volume-label <label>     USB volume label to target
  --wsl-vhdx <path>          Extra WSL VHDX path (repeatable)
  --flatpak-apps <id>        Extra flatpak app id (repeatable)
  --skip-iso-download        Do not offer to download a Mint ISO
  --skip-rufus               Do not launch Rufus; wait for a Mint live USB
  --no-gui                   Console-only flow (no config dialog)
  --dry-run                  Detection-only mode; writes nothing
  --rate-hardware            With --dry-run: rate ALL PCI/USB devices
  --no-elevation             Skip the administrator check
  --preload-rust-tools       Download fd/bat/zoxide onto <USB>:\\bin
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
            "--wsl-vhdx" => o.wsl_vhdx.push(next()?),
            "--flatpak-apps" => o.flatpak_apps.push(next()?),
            "--skip-iso-download" => o.skip_iso_download = true,
            "--skip-rufus" => o.skip_rufus = true,
            "--no-gui" => o.no_gui = true,
            "--dry-run" => o.dry_run = true,
            "--rate-hardware" => o.rate_hardware = true,
            "--no-elevation" => o.no_elevation = true,
            "--preload-rust-tools" => o.preload_rust_tools = true,
            "--probe-os" => o.probe_os = true,
            "--help" | "-h" => return Err(USAGE.to_string()),
            other => return Err(format!("unknown option: {}\n\n{}", other, USAGE)),
        }
    }
    Ok(o)
}
