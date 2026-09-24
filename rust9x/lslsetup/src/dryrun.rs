//! Dry-run detection report (Show-DryRunReport replacement).

use crate::sys::{self, out};
use crate::{boot, detect, hardware, lslfiles, net, wifi};

pub fn show_dry_run_report(opts: &crate::cli::Opts) {
    out::step("DRY RUN - detection report (nothing downloaded, launched, or written)");

    // ---- ISO ----
    out::step("ISO");
    if !opts.iso_path.is_empty() {
        if sys::path_exists(&opts.iso_path) {
            let sz = sys::file_size(&opts.iso_path).unwrap_or(0);
            out::info(&format!(
                "Provided: {} ({:.2} GB)",
                opts.iso_path,
                sz as f64 / sys::GB as f64
            ));
            match crate::iso::check_live_iso(&opts.iso_path) {
                Ok(c) => {
                    out::info(&format!("Image info: {}", c.info));
                    out::info(&format!("dists codenames: {}", c.dists.join(", ")));
                }
                Err(e) => out::warn(&format!("Validation skipped: {}", e)),
            }
        } else {
            out::warn(&format!("Provided ISO not found: {}", opts.iso_path));
        }
    } else {
        let es_isos = lslfiles::find_everything_isos();
        if !es_isos.is_empty() {
            out::info("Everything (voidtools) available - would offer these existing ISOs:");
            for p in &es_isos {
                out::info(&format!("  {}", p));
            }
        } else {
            out::info("Everything (voidtools) not available; would download a fresh ISO.");
        }
        let dir = if opts.download_dir.is_empty() {
            sys::downloads_dir()
        } else {
            opts.download_dir.clone()
        };
        out::info(&format!(
            "Would download: linuxmint-{}-cinnamon-64bit.iso (~3 GB) to {}",
            opts.mint_version, dir
        ));
        out::info("  (SHA-256 verified against mirrors.kernel.org sha256sum.txt)");
    }

    // ---- Rufus ----
    out::step("Rufus");
    if !opts.rufus_path.is_empty() {
        out::info(&format!("Provided: {}", opts.rufus_path));
    } else {
        let exe = crate::rufus::cached_path();
        if sys::path_exists(&exe) {
            out::info(&format!("Cached: {}", exe));
        } else if net::has_transport() {
            out::info(&format!(
                "Would download latest rufus.exe from GitHub releases (Authenticode-verified) to {}",
                exe
            ));
        } else {
            out::warn("No HTTP transport on this Windows - Rufus must be provided manually (--rufus-path).");
        }
    }

    // ---- write mode ----
    if opts.write_mode.eq_ignore_ascii_case("nofmt") {
        out::step("Write mode: non-destructive (nofmt)");
        let uefi_src = crate::nofmt::uefi_source_name(&opts.uefi_bootx64);
        out::info("Would copy grldr, extract the kernel + base squashfs out of the source ISO (the ISO file itself is never copied),");
        out::info("write the direct-kernel menu.lst entries,");
        out::info("drop the first-boot toolkit (bin/uproot et al.), extract the base squashfs,");
        out::info("and write the embedded z0 firstboot layer to casper\\filesystem.z0.squashfs,");
        out::info("offering first to delete h2testw leftovers (*.h2w) when space runs short,");
        if uefi_src != Some("vendored signed shim+GRUB2") {
            out::info("mirror the entries to efi\\grub\\menu.lst for grub4dos-for-UEFI,");
        }
        out::info(&format!(
            "install the UEFI loader ({}) + grub.cfg for UEFI (FAT32),",
            uefi_src
                .map(|s| s.to_string())
                .unwrap_or_else(|| "none bundled - use --uefi-bootx64 or vendor one".into())
        ));
        out::info("and, after every other drop below, flip the MBR boot code (bytes 0..440; signature + partition table kept).");
        out::info("No formatting; existing files untouched. Any non-system volume is a candidate:");
        out::info("removable+USB lists as ready, fixed/non-USB lists with a contents check + backup offer.");
        out::info("System disk/volume, CD-ROM and unmountable volumes are always refused.");
        if opts.extra_isos.is_empty() {
            let others = crate::nofmt::detect_other_isos(&opts.iso_path);
            if others.is_empty() {
                out::info("No other local ISOs detected for multiboot extras (--extra-iso to add any).");
            } else {
                out::info("Other local ISOs (console offer: loopback-only extras, no firstboot):");
                for p in &others {
                    out::info(&format!("  extra candidate: {}", p));
                }
            }
        } else {
            out::info("Extra loopback-only ISOs (no firstboot, no squashfs unpack):");
            for p in &opts.extra_isos {
                out::info(&format!("  extra: {}", p));
            }
        }
        if !opts.usb_letter.is_empty() {
            out::info(&format!("Target pin: --usb-letter {}", opts.usb_letter));
        }
        let cands = crate::nofmt::probe_candidates(opts.allow_fixed);
        let showable: Vec<&crate::nofmt::Candidate> = cands.iter().filter(|c| c.target.is_some()).collect();
        if showable.is_empty() {
            out::warn("No candidate volumes detected (need any non-system volume with a physical-disk mapping).");
        } else {
            for c in &showable {
                let t = c.target.as_ref().unwrap();
                out::info(&format!("  candidate: {}  [{}]", t.describe(), c.status_tag()));
                if let Some(snap) = crate::nofmt::snapshot_volume(&t.letter) {
                    for line in crate::nofmt::describe_snapshot(&snap).split('\n') {
                        out::info(&format!("      {}", line));
                    }
                }
            }
        }
    } else {
        out::info("Write mode: Rufus (default). Use --write-mode nofmt for the non-destructive flow.");
    }

    // ---- USB targets ----
    out::step("USB target");
    let vols = sys::list_volumes();
    let removables: Vec<&sys::Volume> =
        vols.iter().filter(|v| v.removable && !v.letter.is_empty()).collect();
    if !removables.is_empty() {
        for v in &removables {
            out::info(&format!(
                "{}:  {}  {:.1} GB  casper={}",
                v.letter,
                v.label,
                v.size_gb(),
                v.has_casper_squashfs()
            ));
        }
        out::info(&format!(
            "Target selection: {}",
            if opts.volume_label.is_empty() {
                "volume that ends up containing casper\\filesystem.squashfs after Rufus writes"
            } else {
                &opts.volume_label
            }
        ));
        out::info("  A plugged-in USB already containing casper\\filesystem.squashfs is offered for reuse (skips Rufus).");
    } else {
        out::warn("No removable volumes detected.");
    }

    // ---- WSL VHDX ----
    out::step("WSL VHDX (would be written to <USB>:\\lsl-wsl-vhdx.conf)");
    let vhdx = detect::wsl_vhdx_paths(&opts.wsl_vhdx);
    if !vhdx.is_empty() {
        for v in &vhdx {
            out::info(&format!("  {}", v));
        }
    } else {
        out::warn("None found (registry Lxss + Packages scan + --wsl-vhdx).");
    }

    // ---- flatpaks ----
    out::step("Flatpak suggestions (installed Windows apps -> flathub refs)");
    let sugg = hardware::flatpak_suggestions();
    if !sugg.is_empty() {
        for (app, id, matched) in &sugg {
            out::info(&format!(
                "  {} -> {}{}",
                app,
                id,
                if *matched { "  (installed)" } else { "" }
            ));
        }
    } else {
        out::warn("None.");
    }

    // ---- wifi ----
    out::step("WiFi (would be written to <USB>:\\wifi.sh)");
    if wifi::has_netsh() {
        let names = wifi::wifi_profile_names();
        if !names.is_empty() {
            for n in &names {
                out::info(&format!("  {}", n));
            }
        } else {
            out::warn("No saved wifi profiles found.");
        }
    } else {
        out::warn("netsh absent on this Windows version - wifi.sh cannot be generated.");
    }

    // ---- network drivers ----
    out::step("Network drivers (would be staged to <USB>:\\drivers\\)");
    let hw = hardware::network_hardware();
    if !hw.is_empty() {
        for d in &hw {
            out::info(&format!("  {}  [{}]", d.name, d.id));
        }
        let needs = hardware::resolve_driver_needs(&hw);
        if !needs.is_empty() {
            for (_, t) in &needs {
                let src = if t.source == "ubuntu" {
                    t.pkg.to_string()
                } else {
                    format!("{} (github)", t.pkg)
                };
                out::info(&format!("  -> needs {}: {}", t.chip, src));
            }
        } else {
            out::info("  No known problem chipsets - the ISO kernel should cover this machine.");
        }
    } else {
        out::warn("No network hardware detected (registry PnP unavailable?).");
    }

    // ---- hardware rating ----
    out::step("Linux compatibility (linux-hardware.org LKDDb, one polite query per device)");
    let rate_devices = if opts.rate_hardware {
        hardware::compat_hardware()
    } else {
        hardware::network_hardware()
    };
    if !rate_devices.is_empty() {
        let scope = if opts.rate_hardware {
            format!("{} devices", rate_devices.len())
        } else {
            format!(
                "{} network device(s) - add --rate-hardware for the full machine",
                rate_devices.len()
            )
        };
        out::info(&format!(
            "Rating {} (crawl-delay 10s between queries; cached after the first run).",
            scope
        ));
        if net::has_transport() {
            for d in &rate_devices {
                let r = hardware::linux_compat_rating(d, &opts.bundle_dir, (6, 8));
                out::info(&format!("  [{}] {}  ({})  - {}", r.rating, r.name, d.id, r.reason));
            }
        } else {
            out::warn("No HTTP transport on this Windows - ratings unavailable (all 'U').");
        }
    } else {
        out::warn("No PCI/USB devices detected (registry PnP unavailable?).");
    }

    // ---- reuse ----
    out::step("Reuse an existing Mint live USB (skip Rufus)");
    let usbs = sys::find_usb_volumes("", &[]);
    if !usbs.is_empty() {
        for u in &usbs {
            out::info(&format!(
                "  {}:  {}  ({:.1} GB)",
                u.letter,
                u.label,
                u.size_gb()
            ));
        }
    } else {
        out::info("  None detected.");
    }

    // ---- data dir ----
    out::step("LSL_DATA_DIR (pre-filled default)");
    match sys::env_var("USERNAME") {
        Some(u) if !u.is_empty() => out::info(&format!("  /mnt/c/Users/{}/lsl-usb", u)),
        _ => out::info("  (no Windows username detected)"),
    }

    out::step("Squashfs layers -> NTFS HDD (offered in the wizard)");
    out::info("  If accepted, the Linux root image (~1.5-3 GB) + home snapshot are copied");
    out::info("  from the USB to <LSL_DATA_DIR>/sfs/ and LSL_SFS_HDD_CACHE=1 is set, so");
    out::info("  lsl-precache.sh warms the page cache from the faster internal drive.");

    // ---- bundle ----
    out::step("lsl bundle (would be copied to <USB>:\\, layer to <USB>:\\casper\\)");
    for item in [
        "filesystem_z0_firstboot.squashfs",
        "onboot.sh",
        "lsl-usb.env",
        "bin",
        "systemd",
    ] {
        let p = format!("{}\\{}", opts.bundle_dir, item);
        if sys::path_exists(&p) {
            out::info(&format!("  OK       {}", item));
        } else {
            out::warn(&format!("  MISSING  {}", item));
        }
    }
    out::info(&format!("Bundle dir: {}", opts.bundle_dir));

    out::step("Rust CLI tools (would be downloaded to <USB>:\\bin; arch matched to the selected distro)");
    if opts.preload_rust_tools {
        out::info("  Would download fd / bat / zoxide (musl, arch matched to the selected distro: i686 or x86_64) directly from GitHub and drop to <USB>:\\bin.");
    } else {
        out::info("  Skipped (--preload-rust-tools to enable).");
    }

    // ---- capability summary (new: what this Windows can and cannot do) ----
    out::step("Windows capability summary (graceful-degradation map)");
    out::info(&format!(
        "  OS family: {:?}   UEFI: {}   SecureBoot: {:?}",
        sys::os_ver(),
        boot::is_uefi(),
        boot::secure_boot_status()
    ));
    // Board firmware: what THIS motherboard can boot (the stick may target
    // another PC, so this informs the checkbox choice, never blocks it).
    let bc = sys::board_caps();
    out::info(&format!(
        "  Board firmware: boots {} (UEFI-capable: {:?}, legacy/CSM-capable: {:?}, {})",
        if bc.booted_uefi { "UEFI" } else { "legacy/BIOS" },
        bc.uefi_capable,
        bc.bios_capable,
        bc.detail
    ));
    out::info(&format!("  HTTP transport (winhttp): {}", net::has_transport()));
    out::info(&format!("  netsh wifi profiles: {}", wifi::has_netsh()));
    out::info(&format!(
        "  Everything (voidtools) CLI: {}",
        if lslfiles::everything_path().is_empty() {
            "not found"
        } else {
            "found"
        }
    ));
    let _ = boot::reboot_args();
}
