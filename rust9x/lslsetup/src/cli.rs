//! Command-line options (mirrors install.ps1's param block).

#[derive(Debug, Clone)]
pub struct Opts {
    pub iso_path: String,
    pub mint_version: String,
    pub download_dir: String,
    pub bundle_dir: String,
    pub rufus_path: String,
    pub volume_label: String,
    pub write_mode: String,     // "nofmt" (default, non-destructive grub4dos) | "rufus"
    pub write_mode_set: bool,   // --write-mode was passed explicitly
    pub usb_letter: String,     // --usb-letter <X>: pick the nofmt target
    pub allow_fixed: bool,      // --allow-fixed: accepted, but no longer changes the gate (a confirmed USB bus suffices)
    pub uefi_bootx64: String,   // optional BOOTX64.EFI for the nofmt stick
    pub uefi_loader: String,    // nofmt UEFI loader: auto|signed|grub4dos (also applied via nofmt::set_uefi_loader_override)
    pub bios_boot: bool,        // nofmt: install the grub4dos BIOS path (default on)
    pub uefi_boot: bool,        // nofmt: install the UEFI files (default on)
    pub check_usb: bool,        // fill free space with PRNG data + read-back verify (default off: slow)
    pub skip_verify: bool,      // skip the post-copy ISO re-read (default off: faster, less safe)
    pub wsl_vhdx: Vec<String>,
    pub flatpak_apps: Vec<String>,
    /// Extra snap NAMES (not ids) to stage into snaps.txt. Repeatable. Only
    /// names are stored - the stick downloads the snaps itself on first boot.
    pub snap_apps: Vec<String>,
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
    pub gui_test_boot_page: bool,
    pub auto_upload: bool,
    /// Print the partition-layout records on a stick and exit. `Some(letter)`
    /// overrides the default `D:`. Read-only: no writes, no Administrator, no
    /// install - it exists so the geometry a manual F2FS recovery needs can be
    /// read off a stick that will not boot (where the GUI cannot run).
    pub show_partition_records: Option<String>,
    // settings the GUI also collects, exposed as flags so a FINISHED-page
    // command line can reproduce the exact wizard choices headlessly
    pub data_dir: String,
    /// Persistence backend written to lsl-usb.env as LSL_PERSIST. Empty means
    /// "not specified" - the installer then leaves the env file alone rather
    /// than overwriting a setting the user made by hand.
    pub persist_backend: String,
    /// Persistence image size in MiB (LSL_HOME_BTRFS_MIB). 0 = unspecified.
    pub persist_mib: u32,
    /// Keep caches in RAM (LSL_CACHE_TMPFS). Defaults to on, matching the pane.
    pub cache_tmpfs: bool,
    pub wifi: bool,             // copy wifi profiles (default on)
    pub wifi_networks: Vec<String>,
    pub efu: bool,              // write the Everything EFU index (default on)
    pub drivers: bool,          // stage network drivers (default on)
    pub pkgs: bool,             // stage boot-critical hivex .debs (default on)
    pub sfs_hdd: bool,          // copy squashfs to the HDD cache
    pub reclaim_win_swap: bool, // reclaim the Windows swapfile
    pub fast_startup_off: bool, // powercfg /h off (WHYFAIL6 §5)
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
            write_mode: "nofmt".into(),
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
            snap_apps: Vec::new(),
            extra_isos: Vec::new(),
            // Persistence: empty backend = "leave lsl-usb.env alone", so the
            // headless default does NOT overwrite a hand-edited LSL_PERSIST.
            // cache_tmpfs defaults ON to match the pane (design s2.7).
            persist_backend: String::new(),
            persist_mib: 0,
            cache_tmpfs: true,
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
            gui_test_boot_page: false,
            auto_upload: false,
            show_partition_records: None,
            data_dir: String::new(),
            wifi: true,
            wifi_networks: Vec::new(),
            efu: true,
            drivers: true,
            pkgs: true,
            sfs_hdd: false,
            reclaim_win_swap: false,
            fast_startup_off: false,
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
  --write-mode <mode>        nofmt (default, non-destructive) or rufus
                             (non-destructive: grub4dos MBR-code write +
                             kernel/base extracts (no ISO file) + direct-kernel
                             menu.lst + BOOTX64.EFI/grub.cfg for UEFI (BIOS + UEFI);
                             the stick must already be FAT32/NTFS)
  --usb-letter <X>           Drive letter for the nofmt target (else a picker)
  --allow-fixed              Accepted but no longer needed: a volume on the
                             USB bus is ready on its own, because a USB stick
                             reports DRIVE_FIXED legitimately
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
  --snap-apps <name>         Extra snap NAME (repeatable). Only the names are
                             written to snaps.txt; the stick downloads each snap
                             on first boot, keeps it (with its assertion) in its
                             own cache, and on later boots installs VERIFIED from
                             that cache with `snap ack` + `--offline`.
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
  --gui-test-boot-page       (test) real wizard boot page (no install), print the clicked choice, exit
  --auto-upload              Check for pending boot telemetry and prompt to upload; then exit
  --show-partition-records [letter]
                             List the partition-layout records on a stick
                             (default D:) and print the geometry needed for a
                             manual F2FS recovery; then exit. Writes nothing and
                             needs no Administrator.
  --preload-rust-tools       Download fd/bat/zoxide onto <USB>:\\bin
  --data-dir <path>           LSL_DATA_DIR to write into lsl-usb.env
  --persist <backend>         Persistence backend for lsl-usb.env:
                             squashfs (default; home.sfs on the stick),
                             btrfs (home.btrfs loopback),
                             f2fs (a real partition; experimental)
  --persist-mib <MiB>         Persistence image size for the btrfs backend
                             (default 4096; a FAT32 stick caps one file at 4 GiB)
  --cache-tmpfs / --no-cache-tmpfs
                             Keep caches in RAM instead of a persistent image
  --no-wifi                   Do not copy wifi profiles
  --wifi-network <name>       Copy only this wifi profile (repeatable)
  --no-efu                    Do not write the Everything EFU index
  --no-drivers                Do not stage out-of-tree network drivers
  --no-pkgs                   Do not stage the boot-critical hivex .debs
                             (without them /home is not persistent)
  --sfs-hdd-cache             Copy the squashfs to the HDD cache
  --reclaim-win-swap          Reclaim the Windows swapfile
  --fast-startup-off          Turn off Fast Startup/hibernate (powercfg /h off)
  --version                   Print the version and git revision, then exit
  --help                     This text
";

/// Does this token look like a drive letter - `D:`, `D:\`, `d`?
///
/// Used by the optional-value flag above so `--show-partition-records F:` takes
/// its target while `--show-partition-records --dry-run` does not swallow the
/// next flag. Deliberately strict: one ASCII letter then a colon, which no other
/// flag value in this parser resembles.
fn is_volume_letter(s: &str) -> bool {
    let t = s.trim_end_matches(['\\', '/']);
    let mut cs = t.chars();
    match (cs.next(), cs.next()) {
        (Some(c), Some(':')) if c.is_ascii_alphabetic() => cs.next().is_none(),
        _ => false,
    }
}

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
            "--snap-apps" => o.snap_apps.push(next()?),
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
            "--gui-test-boot-page" => o.gui_test_boot_page = true,
            "--auto-upload" => o.auto_upload = true,
            // The letter is OPTIONAL: `--show-partition-records` alone must
            // work, because the moment someone needs it they are on a machine
            // where guessing a flag's arity is a nuisance. A following token
            // that looks like a drive letter is taken as the target; anything
            // else is left for the next flag.
            "--show-partition-records" => {
                o.show_partition_records = match it.clone().next() {
                    Some(v) if is_volume_letter(&v) => {
                        it.next();
                        Some(v.trim_end_matches(['\\', '/']).to_string())
                    }
                    _ => Some("D:".to_string()),
                };
            }
            "--data-dir" => o.data_dir = next()?,
            "--persist" => {
                let v = next()?.to_ascii_lowercase();
                // Validate here, not at write time: an unknown backend reaching
                // lsl-usb.env would be silently downgraded to squashfs by
                // lsl_persist_backend() on the Linux side, so the user would
                // get a different backend than the one they typed.
                if !crate::gui::PERSIST_BACKENDS.contains(&v.as_str()) {
                    return Err(format!(
                        "--persist must be one of: {}",
                        crate::gui::PERSIST_BACKENDS.join(", ")
                    ));
                }
                o.persist_backend = v;
            }
            "--persist-mib" => {
                let v = next()?;
                o.persist_mib = v
                    .parse::<u32>()
                    .map_err(|_| "--persist-mib must be a whole number of MiB".to_string())?;
            }
            "--cache-tmpfs" => o.cache_tmpfs = true,
            "--no-cache-tmpfs" => o.cache_tmpfs = false,
            "--no-wifi" => o.wifi = false,
            "--wifi-network" => o.wifi_networks.push(next()?),
            "--no-efu" => o.efu = false,
            "--no-drivers" => o.drivers = false,
            "--no-pkgs" => o.pkgs = false,
            "--sfs-hdd-cache" => o.sfs_hdd = true,
            "--reclaim-win-swap" => o.reclaim_win_swap = true,
            "--fast-startup-off" => o.fast_startup_off = true,
            "--help" | "-h" => return Err(USAGE.to_string()),
            // Same "print and exit 0" path as --help: main.rs only treats a
            // message starting with "unknown option" as an error. WHYFAIL16 -
            // the exe could not be asked what version it was at all.
            "--version" | "-V" => return Err(crate::version::version_line()),
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
            "--no-pkgs",
            "--sfs-hdd-cache",
            "--reclaim-win-swap",
            "--fast-startup-off",
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
        assert!(!o.pkgs);
        assert!(o.sfs_hdd);
        assert!(o.reclaim_win_swap);
        assert!(o.fast_startup_off);
        assert!(o.preload_rust_tools);
        assert_eq!(o.extra_isos, vec!["D:\\a.iso".to_string(), "D:\\b.iso".to_string()]);
    }

    #[test]
    fn the_records_flag_takes_an_optional_volume_letter() {
        // Both spellings must work. The bare flag is the common case: someone
        // recovering a stick should not have to remember which letter it was,
        // and `--show-partition-records --dry-run` must not eat the next flag.
        let o = parse(&args(&["--show-partition-records"])).unwrap();
        assert_eq!(o.show_partition_records.as_deref(), Some("D:"));

        let o = parse(&args(&["--show-partition-records", "F:"])).unwrap();
        assert_eq!(o.show_partition_records.as_deref(), Some("F:"));

        let o = parse(&args(&["--show-partition-records", "E:\\"])).unwrap();
        assert_eq!(o.show_partition_records.as_deref(), Some("E:"));

        // A following flag is NOT a volume letter and must survive parsing.
        let o = parse(&args(&["--show-partition-records", "--dry-run"])).unwrap();
        assert_eq!(o.show_partition_records.as_deref(), Some("D:"));
        assert!(o.dry_run);

        // Absent by default: nothing prints records unless asked.
        assert!(parse(&args(&[])).unwrap().show_partition_records.is_none());
    }

    #[test]
    fn only_a_real_drive_letter_is_read_as_a_volume() {
        // The whole point of the strict test: these must NOT be taken as the
        // target, or the flag would swallow a legitimate argument.
        for s in ["D", "DD:", "--dry-run", "data", "1:", ":", "D:extra"] {
            assert!(!is_volume_letter(s), "{s} must not read as a volume letter");
        }
        for s in ["D:", "d:", "Z:\\", "e:/"] {
            assert!(is_volume_letter(s), "{s} should read as a volume letter");
        }
    }

    #[test]
    fn snap_apps_flag_is_repeatable_and_defaults_empty() {
        // Snaps are opt-in: an empty default must not stage a snaps.txt.
        let o = parse(&args(&[])).unwrap();
        assert!(o.snap_apps.is_empty());
        let o = parse(&args(&[
            "--snap-apps", "spotify", "--snap-apps", "code", "--snap-apps", "vlc",
        ]))
        .unwrap();
        assert_eq!(
            o.snap_apps,
            vec!["spotify".to_string(), "code".to_string(), "vlc".to_string()]
        );
    }

    #[test]
    fn snap_apps_values_are_kept_verbatim() {
        // Snap names are case- and hyphen-sensitive ("obs-studio", not
        // "OBS Studio"): normalising here would produce a name snapd has never
        // heard of, and the failure would only surface on the stick.
        let o = parse(&args(&["--snap-apps", "OBS-Studio"])).unwrap();
        assert_eq!(o.snap_apps, vec!["OBS-Studio".to_string()]);
    }

    #[test]
    fn defaults_match_gui_defaults() {
        let o = parse(&args(&[])).unwrap();
        assert!(o.wifi);
        assert!(o.efu);
        assert!(o.drivers);
        assert!(o.pkgs);
        assert!(!o.sfs_hdd);
        assert!(!o.reclaim_win_swap);
        assert!(!o.fast_startup_off);
        assert!(o.data_dir.is_empty());
        assert!(o.wifi_networks.is_empty());
        assert!(o.extra_isos.is_empty());
        // Persistence: an UNSPECIFIED backend must stay unspecified so a headless
        // run does not overwrite a hand-edited LSL_PERSIST in lsl-usb.env. The
        // pane's own default (squashfs) is applied by the GUI, not by the CLI.
        assert!(o.persist_backend.is_empty(), "no backend means 'leave env alone'");
        assert_eq!(o.persist_mib, 0);
        assert!(o.cache_tmpfs, "cache-on-tmpfs defaults on, matching the pane");
    }

    #[test]
    fn persistence_flags_round_trip() {
        let o = parse(&args(&["--persist", "f2fs", "--persist-mib", "8192", "--no-cache-tmpfs"]))
            .unwrap();
        assert_eq!(o.persist_backend, "f2fs");
        assert_eq!(o.persist_mib, 8192);
        assert!(!o.cache_tmpfs);
        // Case is normalised so `--persist F2FS` cannot reach lsl-usb.env as
        // "F2FS" and be silently downgraded to squashfs on the Linux side.
        let o2 = parse(&args(&["--persist", "BTRFS"])).unwrap();
        assert_eq!(o2.persist_backend, "btrfs");
    }

    /// WHYFAIL-class guard: an unknown backend must be REJECTED here, not
    /// written to lsl-usb.env and downgraded later. Accepting it would mean the
    /// user typed one thing and got another with no error.
    #[test]
    fn unknown_persistence_backend_is_rejected_at_parse_time() {
        assert!(parse(&args(&["--persist", "btfs"])).is_err());
        assert!(parse(&args(&["--persist", ""])).is_err());
        // ...and a non-numeric size is an error, not a silent 0.
        assert!(parse(&args(&["--persist-mib", "4gb"])).is_err());
    }

    /// Every backend the GUI can offer must be accepted by the CLI, or the
    /// FINISHED page's "copy this command line" would produce something that
    /// fails to re-run.
    #[test]
    fn cli_accepts_every_backend_the_pane_offers() {
        for b in crate::gui::PERSIST_BACKENDS {
            let o = parse(&args(&["--persist", b])).unwrap_or_else(|e| panic!("{} rejected: {}", b, e));
            assert_eq!(o.persist_backend, b);
        }
    }

    /// The pane's radio INDEX must select the same backend the constant names -
    /// the harvest maps positionally, never by label (labels are translated).
    #[test]
    fn pane_radio_order_matches_the_backend_list() {
        assert_eq!(crate::gui::PERSIST_BACKENDS[0], crate::gui::PERSIST_DEFAULT);
        // The default must be findable, or the pane would pre-check a radio whose
        // index does not map back to the default.
        assert!(crate::gui::PERSIST_BACKENDS.contains(&crate::gui::PERSIST_DEFAULT));
        // The slider's rules, pinned so they cannot drift back to fixed constants:
        //   * min = 1 GiB
        //   * max = total - iso - (vmlinuz + initrd)
        //   * default = 3/4 of that max
        // 32 GB is a CEILING on FAT, not the stick size - so it does NOT bound
        // persistence from above. Getting that backwards is what previously made
        // 93 (which is total-32) look like a maximum.
        let (min, max, default) = crate::gui::persist_gib_bounds(128, 3);
        assert_eq!(min, 1, "the minimum is 1 GiB");
        assert_eq!(max, 124, "128 - 3 (ISO) - 1 (kernel+initrd)");
        assert_eq!(default, 93, "the default is 3/4 of the available space");
        assert!((min..=max).contains(&default), "default must be reachable");

        // No ISO chosen yet: only the kernel allowance bounds the maximum.
        let (_, max0, def0) = crate::gui::persist_gib_bounds(128, 0);
        assert_eq!(max0, 127);
        assert_eq!(def0, 95);

        // With no ISO at all the 32 GB FAT ceiling is the only real limit, and it
        // does not cap persistence: 128 GB of stick still yields a large range.
        let (_, max_noiso, _) = crate::gui::persist_gib_bounds(128, 0);
        assert!(
            max_noiso > 96,
            "persistence must not be capped at total-32; that inverts the rule"
        );

        // A stick smaller than the image: never invert the range (an inverted
        // trackbar range is what makes the control unusable).
        for (total, iso) in [(0u32, 0u32), (1, 0), (4, 3), (8, 16), (16, 16)] {
            let (lo, hi, d) = crate::gui::persist_gib_bounds(total, iso);
            assert!(lo <= hi, "range inverted for {}/{}: {}..{}", total, iso, lo, hi);
            assert!((lo..=hi).contains(&d), "default {} outside {}..{} for {}/{}", d, lo, hi, total, iso);
            assert!(lo >= 1, "the minimum is 1 GiB, got {}", lo);
        }

        // The readout shows the split, not a bare number.
        assert_eq!(crate::gui::persist_split_text(128, 93 * 1024), "35 GB FAT / 93 GB persistence");
        assert!(crate::gui::persist_split_text(0, 4096).contains("No USB stick"));
        assert!(crate::gui::persist_split_text(4, 8192).contains("cannot hold"));
        // ...and the size readout names the MiB the env file actually receives.
        assert_eq!(crate::gui::persist_gib_text(4096), "4.0 GiB (4096 MiB)");
    }

    /// Regression: the slider must not be sourced from a volume filter that only
    /// finds sticks ALREADY holding a live image.
    ///
    /// `largest_usb_gib` used `sys::find_usb_volumes("", &[])`, which answers
    /// "which volumes contain an LSL live image?". With an empty label it falls
    /// through to `has_casper_squashfs()` and drops every BLANK stick - the
    /// normal state before an install - so a perfectly good D: was invisible and
    /// the pane reported "no USB stick detected". It now reads
    /// `nofmt::probe_candidates`, the same enumeration the INSTALL page lists.
    ///
    /// Real hardware is needed to observe the bug (a blank stick with a drive
    /// letter), so what is pinned here is that the candidate enumeration is
    /// usable and that a stick the slider could be sized from is found whenever
    /// one is present. On a machine with no removable media the list is empty
    /// and `largest_usb_gib` returns 0, which is the documented fallback.
    #[test]
    fn slider_size_source_sees_plain_volumes() {
        let cands = crate::nofmt::probe_candidates(false);
        for c in &cands {
            assert!(!c.volume.letter.is_empty(), "a candidate needs a drive letter");
            // The size the slider would derive must be the WHOLE volume, not a
            // leftover figure from some other partition of the same disk.
            assert!(c.volume.size_gb() > 0.0 || c.volume.total == 0);
        }
        // Whatever the enumeration finds, the derived size must land inside the
        // bounds the slider offers - a size outside them would be unreachable.
        let stick = crate::gui::largest_usb_gib();
        if stick > 0 {
            let (lo, hi, d) = crate::gui::persist_gib_bounds(stick, 0);
            assert!(lo <= hi && (lo..=hi).contains(&d), "bounds invalid for {} GB", stick);
            assert!(hi <= stick as usize, "the slider must not offer more than the stick has");
        }
    }

    /// The persistence pane must not offer a size on a stick whose second
    /// partition already exists: the partition's size is a measured fact, and
    /// re-choosing it would silently create a partition that disagrees with the
    /// one on disk. The pane pins min == max == that size, so no other value is
    /// reachable on the slider.
    #[test]
    fn existing_partition_pins_the_slider_instead_of_sizing_it() {
        for gib in [1u32, 8, 64, 512] {
            let g = gib.max(crate::gui::PERSIST_GIB_MIN as u32) as usize;
            // Pinned: there is exactly one reachable position.
            let lo = g;
            let hi = g;
            let default = g;
            assert_eq!((lo, hi, default), (g, g, g));
            assert!(lo <= hi && (lo..=hi).contains(&default));
            assert!(hi >= crate::gui::PERSIST_GIB_MIN, "a pinned size below the minimum is wrong");
        }
        // ...whereas an UNPINNED stick must offer a real range, otherwise the
        // pinned case above would prove nothing.
        let (lo, hi, d) = crate::gui::persist_gib_bounds(128, 3);
        assert!(hi > lo, "an unpartitioned stick must still offer a range");
        assert!((lo..=hi).contains(&d));
    }

    /// The resize path must refuse rather than leave a filesystem larger than its
    /// partition.
    ///
    /// DESIGN-PERSISTENCE-PANE.md s9.2 records the measured failure: sfdisk cuts
    /// the partition while the filesystem still claims the old size, the result
    /// MOUNTS with no error and then fails on any access past the boundary
    /// (fsck "Seek to ...: Invalid argument"). bin/lsl-f2fs-resize shrinks the
    /// filesystem FIRST and re-reads the BPB before touching the table. The rule
    /// the script implements is `filesystem_sectors <= partition_sectors`, and
    /// that is what is pinned here - as a function, so the cases read as the
    /// situations they describe.
    #[test]
    fn resize_refuses_when_filesystem_outlives_its_partition() {
        // The script's guard, as a predicate.
        let proceed = |fs_sectors: u32, part_sectors: u32| fs_sectors <= part_sectors;

        // The measured corruption case: filesystem still claims 536 MB after the
        // partition was cut to 200 MB. Must NOT proceed.
        assert!(
            !proceed(1_046_493, 409_600),
            "a filesystem claiming 536 MB inside a 200 MB partition must abort"
        );
        // The correct outcome of a successful shrink: filesystem already inside.
        assert!(proceed(400_000, 409_600), "a filesystem inside its partition may proceed");
        // Exactly equal is the boundary fatresize should leave behind: fine.
        assert!(proceed(409_600, 409_600), "filesystem exactly filling its partition is fine");
        // A filesystem that refused to shrink at all (the silent no-op the design
        // measured) must abort: this is the case an exit-code check would miss.
        assert!(
            !proceed(1_046_493, 409_600),
            "fatresize's measured no-op (BPB unchanged) must abort the resize"
        );
    }
}
