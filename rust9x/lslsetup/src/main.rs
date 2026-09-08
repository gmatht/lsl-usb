//! lslsetup — full reimplementation of lsl-usb's install.ps1 as a native
//! Windows executable built with the rust9x toolchain.
//!
//! The binary runs on Windows 95 -> 11 (rust9x + unicows + VC6 CRT). Every
//! feature that needs a newer Windows is behind a runtime capability check
//! with a graceful fallback (see README.md for the capability matrix).

// (Patch-Win95) no C main() -> the Win95 entry below (extern "C" fn main).
// Test builds keep the normal Rust entry so libtest's harness main is
// generated and `cargo test` actually runs the #[test]s.
#![cfg_attr(not(test), no_main)]

mod boot;
mod cli;
mod detect;
mod dryrun;
mod float_shim;
mod gui;
mod hardware;
mod iso;
mod lslfiles;
mod net;
mod nofmt;
mod rufus;
mod sys;
mod wifi;

use sys::out;

/// Overrides the rustc `lang_start` shim (Win95: `std::rt` init hangs
/// inside KERNEL32; the VC6 CRT startup calls `main` directly instead).
/// (Patch-Win95 applied by win95.sh.)
// (Patch-Win95 applied by win95.sh.) Only in real builds: in test builds the
// libtest harness generates the entry point, and a second `main` would be a
// duplicate-symbol error.
#[cfg(not(test))]
#[unsafe(no_mangle)]
pub extern "C" fn main() -> i32 {
    // (Patch-Win95) std console writes die on Win95 (WriteConsoleW is a W
    // stub), so surface panics in a MessageBox instead of dead stderr.
    std::panic::set_hook(Box::new(|info| {
        use winapi::um::winuser::{MB_ICONERROR, MB_OK, MessageBoxA};
        let mut msg: Vec<u8> = format!(
            "panic: {}\r\nat: {}",
            info,
            info.location().map(|l| l.to_string()).unwrap_or_default()
        )
        .bytes()
        .collect();
        msg.push(0);
        unsafe {
            MessageBoxA(
                0 as _,
                msg.as_ptr() as *const _,
                b"lslsetup panic\0".as_ptr() as *const _,
                MB_OK | MB_ICONERROR,
            );
        }
    }));
    run();
    0
}


fn run() {
    // When launched via WSL interop the current directory can be a
    // \\wsl.localhost\... UNC path. ShellExecute (URL opening, Rufus
    // launch, ...) fails with ERROR_FILE_NOT_FOUND while the CWD is a UNC
    // path, and every spawned child inherits it. Switch to a local dir.
    {
        let cwd = std::env::current_dir()
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_default();
        if cwd.starts_with("\\") {
            if let Ok(exe) = std::env::current_exe() {
                if let Some(dir) = exe.parent() {
                    let _ = std::env::set_current_dir(dir);
                }
            }
            if std::env::current_dir()
                .map(|p| p.to_string_lossy().starts_with("\\"))
                .unwrap_or(true)
            {
                let _ = std::env::set_current_dir("C:\\");
            }
        }
    }
    let args: Vec<String> = win95_args().into_iter().skip(1).collect();
    let opts = match cli::parse(&args) {
        Ok(o) => o,
        Err(usage) => {
            // --help exits 0, parse errors exit 2
            out::plain(&usage);
            if usage.starts_with("unknown option") {
                std::process::exit(2);
            }
            return;
        }
    };

    show_compat_notes();

    if opts.probe_os {
        out::plain(&format!("os_ver: {:?}  is_9x: {}", sys::os_ver(), sys::is_9x()));
        let (uefi, sb) = sys::firmware();
        out::plain(&format!("uefi: {} secureboot: {:?}", uefi, sb));
        {
            // raw GetFirmwareType probe
            type GT = unsafe extern "system" fn(*mut i32) -> i32;
            if let Some(f) = sys::proc_from_module::<GT>("kernel32.dll", "GetFirmwareType") {
                let mut t: i32 = -1;
                let r = unsafe { f(&mut t) };
                out::plain(&format!("GetFirmwareType raw: ret={} type={}", r, t));
            } else {
                out::plain("GetFirmwareType not exported");
            }
        }
        out::plain(&format!("ram: {:.1} GB  admin: {}  dbg: {:?}",
            sys::total_ram() as f64 / sys::GB as f64,
            sys::is_admin(),
            sys::total_ram_debug()));
        {
            type GME = unsafe extern "system" fn(*mut u8) -> i32;
            match sys::proc_from_module::<GME>("kernel32.dll", "GlobalMemoryStatusEx") {
                Some(f) => {
                    let mut buf = [0u8; 64];
                    buf[..4].copy_from_slice(&64u32.to_le_bytes());
                    let r = unsafe { f(buf.as_mut_ptr()) };
                    let total_phys = u64::from_le_bytes(buf[8..16].try_into().unwrap());
                    let err = unsafe { winapi::um::errhandlingapi::GetLastError() };
                    out::plain(&format!("GlobalMemoryStatusEx raw: ret={} total_phys={} err={}", r, total_phys, err));
                }
                None => out::plain("GlobalMemoryStatusEx not exported"),
            }
        }
        out::plain(&format!("volumes: {}  netsh: {}", sys::list_volumes().len(), wifi::has_netsh()));
        out::plain(&format!("winhttp: {}  wsl_vhdx: {}  everything: {}",
            net::has_transport(),
            detect::wsl_vhdx_paths(&[]).len(),
            !lslfiles::everything_path().is_empty()));
        {
            let devs = hardware::pnp_hardware();
            out::plain(&format!("pnp devices: {}  net devices: {}", devs.len(),
                devs.iter().filter(|d| d.class.eq_ignore_ascii_case("Net")).count()));
            let mut classes: Vec<(String, usize)> = Vec::new();
            for d in &devs {
                match classes.iter_mut().find(|(c, _)| c.eq_ignore_ascii_case(&d.class)) {
                    Some((_, n)) => *n += 1,
                    None => classes.push((d.class.clone(), 1)),
                }
            }
            classes.sort_by(|a, b| b.1.cmp(&a.1));
            for (c, n) in classes.iter().take(12) {
                out::plain(&format!("  class '{}': {}", if c.is_empty() { "(empty)" } else { c }, n));
            }
            for d in devs.iter().take(3) {
                out::plain(&format!("  sample: name='{}' class='{}' id={} hwid-pnp='{}'", d.name, d.class, d.id, d.pnp_id));
            }
        }
        out::plain(&format!("boot key: '{}'  downloads: {}",
            boot::boot_menu_key(), sys::downloads_dir()));
        out::plain("network probe: fetching Mint sha256sum.txt ...");
        match net::get(
            "https://mirrors.kernel.org/linuxmint/stable/22.3/sha256sum.txt",
            net::user_agent(),
        ) {
            Ok(r) if r.status == 200 => {
                let text = String::from_utf8_lossy(&r.body);
                match text.lines().next() {
                    Some(l) => out::plain(&format!("  OK ({} bytes): {}...", r.body.len(), &l[..l.len().min(72)])),
                    None => out::plain("  OK but empty"),
                }
            }
            Ok(r) => out::plain(&format!("  HTTP {}", r.status)),
            Err(e) => out::plain(&format!("  FAILED: {} (graceful fallback would print manual-download URL)", e)),
        }
        std::process::exit(0);
    }

    if opts.dry_run {
        dryrun::show_dry_run_report(&opts);
        std::process::exit(0);
    }

    // Pre-flight: this installer writes to the USB and launches Rufus, both of
    // which require Administrator rights, and the DD-mode live USB interacts
    // with Secure Boot - confirm with the user before any destructive step.
    assert_admin(&opts);
    confirm_secure_boot();
    warn_low_ram();

    let mut iso_path = opts.iso_path.clone();
    let mut flatpak_apps = opts.flatpak_apps.clone();
    let mut wsl_vhdx = opts.wsl_vhdx.clone();
    let mut data_dir = String::new();
    let mut copy_wifi = true;
    let mut wifi_networks: Vec<String> = Vec::new();
    let mut do_efu = true;
    let install_everything = true;
    let mut preload_drivers = true;
    let mut copy_sfs_hdd = false;
    let mut reclaim_win_swap = false;
    let mut rust_tools = false;
    let mut distro_arch: Option<&'static str> = None;
    let mut reuse_usb: Option<String> = None;
    let mut download_iso: Option<(String, String)> = None;
    let mut write_mode = opts.write_mode.clone();
    let mut write_mode_explicit = opts.write_mode_set;
    let mut skip_write = false;

    // GUI first: collects configuration while nothing destructive happens.
    // After the Install click the wizard STAYS OPEN in a working phase
    // (status text + progress bar) while this callback resolves the ISO and
    // launches Rufus; the window only closes once Rufus is up (it used to
    // vanish right at the click, leaving the console looking hung until
    // Rufus finally appeared). Nothing destructive happens inside the
    // wizard itself - Rufus's START button remains the one confirmation.
    let mut work: Option<gui::GuiWork> = None;
    let mut on_confirm = |g: gui::GuiResult, ui: &gui::WorkingUi| -> gui::GuiWork {
        // Reusing an existing live USB (page-1 "Use an existing Live USB"
        // radio): there is nothing to download or write - the main flow
        // picks up the drive letter from g.use_existing_usb after the
        // wizard closes and drops the lsl-usb files in place. Skipping the
        // ISO resolution here is what stops the installer from downloading
        // Mint (or any distro) when the user already has a rufus'ed stick.
        if g.use_existing_usb.is_some() {
            ui.set_status("Using the existing live USB - no download, no Rufus write...");
            ui.pump();
            ui.close();
            return gui::GuiWork {
                iso: String::new(),
                mode: "skip".into(),
                rufus_proc: None,
                known: Vec::new(),
                nofmt_letter: None,
            };
        }
        // a fresh download picked on page 1 may still be running: join it
        // with the window open (progress bar keeps updating)
        ui.wait_downloads();
        let iso = match resolve_iso(
            &g.iso_path,
            &opts.mint_version,
            &opts.download_dir,
            &opts.bundle_dir,
            !opts.skip_iso_download,
            g.download_iso.clone(),
            Some(ui),
        ) {
            Ok(i) => i,
            Err(e) => fatal_gui(&e, ui),
        };
        if let Err(e) = validate_live_iso(&iso) {
            fatal_gui(&e, ui);
        }
        // the wizard's write-method radio is explicit by construction
        let mode = g.write_mode.clone().unwrap_or_else(|| "rufus".into());
        match mode.as_str() {
            "nofmt" => {
                ui.set_status(
                    "Preparing the USB stick (non-destructive write, no reformat) - see the console for progress...",
                );
                ui.pump();
                out::step("USB write method: built-in non-destructive (wizard choice).");
                // the INSTALL page's target-USB radio wins; without a plugged-in
                // stick (or --usb-letter) nofmt falls back to its own picker
                let letter_hint = g.target_usb.as_deref().unwrap_or(opts.usb_letter.as_str());
                match nofmt::install_from_iso(&iso, letter_hint, opts.allow_fixed, &opts.uefi_bootx64) {
                    Ok(t) => {
                        ui.close();
                        gui::GuiWork {
                            iso,
                            mode,
                            rufus_proc: None,
                            known: Vec::new(),
                            nofmt_letter: Some(t.letter.clone()),
                        }
                    }
                    Err(e) => fatal_gui(&e, ui),
                }
            }
            "skip" => {
                out::step("Skipping the USB write (wizard choice).");
                out::info("Write the image yourself (e.g. with Rufus), then this step picks up the USB.");
                ui.close();
                gui::GuiWork {
                    iso,
                    mode,
                    rufus_proc: None,
                    known: Vec::new(),
                    nofmt_letter: None,
                }
            }
            _ => {
                ui.set_status("Launching Rufus with the ISO pre-selected...");
                ui.pump();
                out::step("Launching Rufus with the ISO pre-selected.");
                out::info("In Rufus: pick the target USB stick, then click START (this is the one destructive confirmation).");
                let rufus_exe = match rufus::get_rufus(&opts.rufus_path) {
                    Ok(p) => p,
                    Err(e) => fatal_gui(&e, ui),
                };
                // Do NOT swallow a launch failure: the window must not just
                // vanish with no Rufus and no explanation. A failed launch
                // (e.g. runas declined, exe missing) surfaces as a dialog
                // instead of a silent close.
                let proc = match rufus::launch(&rufus_exe, &iso) {
                    Ok(p) => p,
                    Err(e) => fatal_gui(&e, ui),
                };
                let known: Vec<String> = sys::list_volumes()
                    .iter()
                    .filter(|v| !v.letter.is_empty())
                    .map(|v| v.letter.clone())
                    .collect();
                // Rufus is up (or spawning): the GUI has done its job
                ui.close();
                gui::GuiWork {
                    iso,
                    mode: "rufus".into(),
                    rufus_proc: proc,
                    known,
                    nofmt_letter: None,
                }
            }
        }
    };
    if !opts.no_gui {
        let Some((g, w)) = gui::run_gui(
            &wsl_vhdx,
            &flatpak_apps,
            &iso_path,
            &opts.mint_version,
            &opts.download_dir,
            // preselect the write-method radio from explicit CLI choices
            if opts.skip_rufus {
                "skip"
            } else if opts.write_mode_set && opts.write_mode == "nofmt" {
                "nofmt"
            } else {
                "rufus"
            },
            &mut on_confirm,
        ) else {
            out::warn("Cancelled.");
            std::process::exit(2); // 2 = user cancel (bat skips pause)
        };
        work = Some(w);
        iso_path = g.iso_path;
        flatpak_apps = [g.flatpak_ids, flatpak_apps].concat();
        wsl_vhdx = g.wsl_vhdx;
        data_dir = g.data_dir;
        copy_wifi = g.wifi;
        wifi_networks = g.wifi_networks;
        do_efu = g.efu;
        preload_drivers = g.drivers;
        copy_sfs_hdd = g.sfs_hdd;
        reclaim_win_swap = g.reclaim_win_swap;
        rust_tools = g.rust_tools;
        distro_arch = g.distro_arch;
        download_iso = g.download_iso;
        if let Some(m) = g.write_mode.clone() {
            // the wizard's USB-write-method radio is the user's choice:
            // never re-ask on the console
            write_mode_explicit = true;
            if m == "skip" {
                skip_write = true;
            } else {
                write_mode = m;
            }
        }
        reuse_usb = g.use_existing_usb;
    }

    let mut vol: Option<sys::Volume> = None;

    // Reuse an existing Mint live USB when chosen (GUI) or offered (console).
    if let Some(letter) = reuse_usb.clone() {
        let found = sys::find_usb_volumes(&opts.volume_label, &[]);
        if let Some(v) = found.into_iter().find(|v| v.letter.eq_ignore_ascii_case(&letter)) {
            out::step(&format!(
                "Using existing Mint live USB: {}: ({}) - no Rufus write.",
                v.letter, v.label
            ));
            vol = Some(v);
        }
    }

    // Console flow (when the GUI was skipped or made no choice): offer reuse,
    // then resolve/validate the ISO, then Rufus or wait.
    let mut iso_used = String::new();
    if vol.is_none() && iso_path.is_empty() && !opts.no_gui == false {
        // (GUI without ISO choice and without USB reuse falls through to the
        // console offer below.)
    }
    if vol.is_none() && iso_path.is_empty() && !download_iso.is_some() {
        if let Some(existing) = select_existing_usb(&opts.volume_label) {
            vol = Some(existing);
            out::step("Using existing Mint live USB - no ISO download, no Rufus write.");
        }
    }

    if vol.is_none() {
        if let Some(w) = work.take() {
            // The working phase already resolved the ISO and started the
            // write step while the wizard was still visible; only the
            // wait for the (Rufus-)written USB remains.
            iso_path = w.iso.clone();
            match w.mode.as_str() {
                "rufus" => {
                    vol = Some(rufus::wait_usb_ready(
                        &opts.volume_label,
                        w.rufus_proc,
                        &w.known,
                        0,
                    ));
                    iso_used = w.iso;
                }
                "nofmt" => {
                    if let Some(letter) = &w.nofmt_letter {
                        vol = sys::list_volumes()
                            .into_iter()
                            .find(|v| v.letter.eq_ignore_ascii_case(letter));
                        if vol.is_none() {
                            out::err(&format!(
                                "Target volume {} disappeared after the write.",
                                letter
                            ));
                            std::process::exit(1);
                        }
                    }
                    iso_used = String::new();
                }
                _ => {
                    let known: Vec<String> = Vec::new();
                    vol = Some(rufus::wait_usb_ready(&opts.volume_label, None, &known, 0));
                    iso_used = w.iso;
                }
            }
        } else {
        let iso = match resolve_iso(
            &iso_path,
            &opts.mint_version,
            &opts.download_dir,
            &opts.bundle_dir,
            !opts.skip_iso_download,
            download_iso.clone(),
            None,
        ) {
            Ok(i) => i,
            Err(e) => {
                out::err(&e);
                std::process::exit(1);
            }
        };
        iso_path = iso.clone();
        if let Err(e) = validate_live_iso(&iso) {
            out::err(&e);
            std::process::exit(1);
        }
        // Provenance check for ANY linuxmint-* ISO (downloads were verified in
        // resolve_iso; this also covers user-supplied/picked-from-disk ISOs)
        // before either write path touches a stick.
        if let Err(e) = verify_mint_iso_sha256(&iso) {
            out::err(&e);
            std::process::exit(1);
        }

        if opts.skip_rufus {
            out::step("Skipping Rufus (--skip-rufus).");
            out::info("Write the image yourself (e.g. with Rufus), then this step picks up the USB.");
            let known: Vec<String> = Vec::new();
            vol = Some(rufus::wait_usb_ready(&opts.volume_label, None, &known, 0));
            iso_used = iso;
        } else {
            // No explicit write method (no --write-mode, no GUI checkbox):
            // present the choice - Rufus first (well supported), then the
            // built-in non-destructive install (less tested).
            if !write_mode_explicit {
                out::step("USB write method:");
                out::info("  1. Rufus (recommended - well tested, UEFI + BIOS; rewrites the stick)");
                out::info("  2. Built-in non-destructive (less tested - no reformat, keeps existing files;");
                out::info("     grub4dos loopback boot, BIOS/CSM firmware, stick must be FAT32/NTFS)");
                out::info("  3. Skip - I will write the USB myself (like --skip-rufus)");
                let ans = out::prompt("Choose [1-3], or press Enter for 1 (Rufus): ");
                match ans.as_str() {
                    "2" => write_mode = "nofmt".into(),
                    "3" => skip_write = true,
                    _ => write_mode = "rufus".into(),
                }
            }
            if skip_write {
                out::step("Skipping the USB write (--skip-rufus / console choice).",
                );
                out::info("Write the image yourself (e.g. with Rufus), then this step picks up the USB.");
                let known: Vec<String> = Vec::new();
                vol = Some(rufus::wait_usb_ready(&opts.volume_label, None, &known, 0));
                iso_used = iso;
            } else if write_mode.eq_ignore_ascii_case("nofmt") {
            // Non-destructive grub4dos install: MBR boot-code area only,
            // ISO copied as a file, menu.lst loopback. The stick keeps its
            // filesystem and all existing files.
            match nofmt::install_from_iso(&iso, &opts.usb_letter, opts.allow_fixed, &opts.uefi_bootx64) {
                Ok(t) => {
                    vol = sys::list_volumes()
                        .into_iter()
                        .find(|v| v.letter.eq_ignore_ascii_case(&t.letter));
                    if vol.is_none() {
                        out::err(&format!("Target volume {} disappeared after the write.", t.letter));
                        std::process::exit(1);
                    }
                }
                Err(e) => {
                    out::err(&e);
                    std::process::exit(1);
                }
            }
            // The ISO is already ON the stick now; do not double-count it
            // in the remaining-space check below.
            iso_used = String::new();
        } else {
            let rufus_exe = match rufus::get_rufus(&opts.rufus_path) {
                Ok(p) => p,
                Err(e) => {
                    out::err(&e);
                    std::process::exit(1);
                }
            };
            out::step("Launching Rufus with the ISO pre-selected.");
            out::info("In Rufus: pick the target USB stick, then click START (this is the one destructive confirmation).");
            let proc = rufus::launch(&rufus_exe, &iso).ok().flatten();
            let known: Vec<String> = sys::list_volumes()
                .iter()
                .filter(|v| !v.letter.is_empty())
                .map(|v| v.letter.clone())
                .collect();
            vol = Some(rufus::wait_usb_ready(&opts.volume_label, proc, &known, 0));
            iso_used = iso;
            }
        }
        }
    }

    let vol = vol.expect("USB target");
    assert_usb_capacity(&vol, &iso_used);

    out::step("Dropping lsl-usb files onto the USB...");
    if let Err(e) = lslfiles::install_lsl_files(&vol.letter, &opts.bundle_dir) {
        out::err(&e);
        std::process::exit(1);
    }

    if opts.preload_rust_tools || rust_tools {
        // the tools must match the selected DISTRO's architecture: a 64-bit
        // distro cannot run i686 binaries (and vice versa)
        let hay = format!(
            "{} {}",
            download_iso.as_ref().map(|(_, n)| n.clone()).unwrap_or_default(),
            iso_path
        )
        .to_lowercase();
        let arch = distro_arch
            .map(|s| s.to_string())
            .or_else(|| {
                if hay.contains("i386") || hay.contains("i686") || hay.contains("386")
                    || hay.contains("32-bit") || hay.contains("tinycore")
                {
                    Some("i686".to_string())
                } else if hay.contains("64") {
                    Some("x86_64".to_string())
                } else {
                    None
                }
            })
            .unwrap_or_else(|| {
                // no distro markers: fall back to the host's capability
                let pae = std::env::var("PROCESSOR_ARCHITEW6432").unwrap_or_default();
                let pa = std::env::var("PROCESSOR_ARCHITECTURE").unwrap_or_default();
                if pae.contains("64") || pa.contains("64") {
                    "x86_64".to_string()
                } else {
                    "i686".to_string()
                }
            });
        out::step(&format!("Preloading Rust CLI tools (fd/bat/zoxide, {}) onto the USB...", arch));
        lslfiles::install_rust_tools(&vol.letter, &arch);
    } else {
        out::info("Skipping Rust tools (tick the page-3 checkbox or pass --preload-rust-tools to add fd/bat/zoxide to <USB>:\\bin).");
    }

    if preload_drivers {
        out::step("Preloading network drivers for this machine...");
        let report = hardware::install_driver_packages(&vol.letter, false);
        for l in &report {
            out::info(&format!("  {}", l));
        }
        out::info("Rating network devices against linux-hardware.org (LKDDb)...");
        let net_hw = hardware::network_hardware();
        if !net_hw.is_empty() {
            if net::has_transport() {
                let compat_lines = hardware::hardware_compat_report(&net_hw, &opts.bundle_dir);
                for l in &compat_lines {
                    out::info(&format!("  {}", l));
                }
                let _ = append_file(
                    &format!("{}:\\lsl-drivers.txt", vol.letter),
                    &compat_lines.join("\r\n"),
                );
            } else {
                out::warn("  No HTTP transport on this Windows - LKDDb ratings unavailable.");
            }
        }
    } else {
        out::info("Skipping network driver preload (unchecked).");
    }

    if !data_dir.is_empty() {
        let env_file = format!("{}:\\lsl-usb.env", vol.letter);
        if sys::path_exists(&env_file) {
            lslfiles::env_file_set(&env_file, "LSL_DATA_DIR", &data_dir);
            out::info(&format!("Set LSL_DATA_DIR={} in lsl-usb.env", data_dir));
        }
    }

    if reclaim_win_swap {
        let env_file = format!("{}:\\lsl-usb.env", vol.letter);
        if sys::path_exists(&env_file) {
            lslfiles::env_file_set(&env_file, "LSL_RECLAIM_WIN_SWAP", "1");
            out::info("Set LSL_RECLAIM_WIN_SWAP=1 in lsl-usb.env (reclaims pagefile.sys / WSL2 swapfile as compressed swap)");
        } else {
            out::warn(&format!(
                "lsl-usb.env not found on {}:\\; LSL_RECLAIM_WIN_SWAP not set (set it manually in lsl-usb.env).",
                vol.letter
            ));
        }
    } else {
        out::info("Leaving LSL_RECLAIM_WIN_SWAP off (unchecked in installer).");
    }

    if copy_sfs_hdd {
        out::step("Copying Linux squashfs layers to the NTFS HDD for faster boot...");
        lslfiles::copy_sfs_to_hdd(&vol.letter, &data_dir);
    } else {
        out::info("Skipping squashfs-to-HDD copy (unchecked).");
    }

    out::step("Locating WSL VHDX files...");
    let vhdx = detect::wsl_vhdx_paths(&wsl_vhdx);
    if !vhdx.is_empty() {
        let conf = format!("{}:\\lsl-wsl-vhdx.conf", vol.letter);
        let _ = std::fs::write(&conf, vhdx.join("\r\n"));
        out::info(&format!(
            "Wrote {} VHDX path(s) to {} (Linux mounts them via detect-wsl/guestmount).",
            vhdx.len(),
            conf
        ));
    } else {
        out::warn("No WSL VHDX files found; Linux will still auto-detect WSL rootfs dirs at boot.");
    }

    out::step("Preloading flatpak refs for apps you have on Windows...");
    lslfiles::write_flatpak_refs(&vol.letter, &flatpak_apps);

    if install_everything && lslfiles::everything_path().is_empty() {
        out::step("Everything (voidtools) not found - installing the portable version...");
        let _ = lslfiles::install_everything();
        let now_isos = lslfiles::find_everything_isos();
        if !now_isos.is_empty() {
            out::info(&format!(
                "Everything index now available - {} ISO(s) found full-disk (re-run the installer to use them in the picker).",
                now_isos.len()
            ));
        }
    }

    if do_efu {
        out::step("Exporting Everything index (EFU) for Linux browsing...");
        lslfiles::write_everything_efu(&vol.letter);
    } else {
        out::info("Skipping Everything index export (unchecked).");
    }

    if copy_wifi {
        out::step("Generating wifi.sh from Windows saved wifi profiles (netsh)...");
        match wifi::generate_wifi_sh(&wifi_networks) {
            Some((body, n)) => {
                let wifi_sh = format!("{}:\\wifi.sh", vol.letter);
                if std::fs::write(&wifi_sh, &body).is_ok() {
                    out::info(&format!("wifi.sh written ({} network(s)).", n));
                } else {
                    out::warn("wifi.sh could not be written.");
                }
            }
            None => {}
        }
    } else {
        out::info("Skipping wifi.sh (Copy Wifi Settings to LSL unchecked).");
    }

    out::step("Done.");
    out::info("Boot the USB. First boot runs the minimal layer script (installs packages, then persists a new layer).");
    out::info("Set LSL_DATA_DIR in /cdrom/lsl-usb.env if you do not want the default (/mnt/c/Users/lsl-usb).");

    // Reboot into the USB boot menu + drop a "Reboot to Select USB" shortcut.
    let shortcuts = boot::create_boot_shortcuts();
    if !shortcuts.is_empty() {
        out::info(&format!("Created 'LSL - Reboot to Select USB' shortcut(s): {}", shortcuts.join(", ")));
    }
    let choice = boot::show_boot_choice_dialog();
    match choice {
        boot::BootChoice::Usb => {
            let set = boot::set_next_boot_usb();
            if !set.is_empty() {
                out::info(&format!("Set one-time boot to the USB ({}). Rebooting...", set));
                boot::reboot("/r /t 0");
            } else {
                out::warn("Could not set the one-time boot entry - rebooting into the boot menu instead.");
                boot::reboot(boot::reboot_args());
            }
        }
        boot::BootChoice::Adv => {
            out::info("Rebooting into the advanced boot menu (shutdown /r /o)...");
            boot::reboot("/r /o /f /t 0");
        }
        boot::BootChoice::Fw => {
            out::info("Rebooting into the firmware boot menu...");
            boot::reboot(boot::reboot_args());
        }
        boot::BootChoice::None => out::info("Not rebooting."),
    }
}

/// Verify a linuxmint-* ISO against the official sha256sum.txt (the only
/// distro with a checksum contract here). Applies to user-supplied ISOs too:
/// the write step (Rufus OR the non-destructive grub4dos path) should never
/// run on an ISO whose contents nobody has verified.
/// No-op (Ok) for every other distro name. Missing transport / missing
/// entry in the checksum file => warning + proceed, consistent with
/// resolve_iso's "proceeding UNVERIFIED" stance for downloads.
fn verify_mint_iso_sha256(iso: &str) -> Result<(), String> {
    // NOTE: no std::path here - the rust9x std's Path::file_name proved
    // unreliable for drive-letter paths on this target (the unit test caught
    // it: a full C:\...\linuxmint-*.iso yielded None => verification would
    // silently be skipped). mint_version_from_name splits on separators
    // itself.
    let name = iso.to_string();
    let Some(version) = mint_version_from_name(&name) else {
        return Ok(());
    };
    let sum_url = format!(
        "https://mirrors.kernel.org/linuxmint/stable/{}/sha256sum.txt",
        version
    );
    out::step(&format!("Verifying SHA-256 of {} ...", name));
    let expected = match net::get(&sum_url, net::user_agent()) {
        Ok(r) if r.status == 200 => {
            find_checksum(&String::from_utf8_lossy(&r.body), &name)
        }
        _ => None,
    };
    let Some(exp) = expected else {
        out::warn(&format!(
            "Could not fetch the official checksum ({}) - proceeding UNVERIFIED.",
            sum_url
        ));
        return Ok(());
    };
    out::info("Computing SHA-256 (this takes a while)...");
    match lslfiles::sha256_file(iso) {
        Some(actual) if actual.eq_ignore_ascii_case(&exp) => {
            out::info("SHA256 verified.");
            Ok(())
        }
        Some(actual) => Err(format!(
            "SHA256 mismatch for {}:\n  expected: {}\n  actual:   {}\nDo NOT write this ISO to a USB - it is corrupt or tampered with.",
            name, exp, actual
        )),
        None => Err(format!("Cannot read {} for hashing.", iso)),
    }
}

/// The Mint version in a `linuxmint-<ver>-*.iso` name, or None when the
/// file is not a Mint ISO (=> no checksum contract => skip verification).
fn mint_version_from_name(name: &str) -> Option<String> {
    // Accept full paths too: the GUI hands us "C:\Downloads\linuxmint-22.3-..."
    // (and the wizard's local-ISO radios are full paths), so compare on the
    // basename - otherwise a perfectly good Mint ISO would silently skip its
    // checksum contract.
    let base = name.rsplit(['\\', '/']).next().unwrap_or(name);
    if !base.starts_with("linuxmint-") {
        return None;
    }
    base.split('-').nth(1).map(|v| v.to_string())
}

fn append_file(path: &str, text: &str) -> std::io::Result<()> {
    use std::io::Write;
    std::fs::OpenOptions::new()
        .append(true)
        .create(true)
        .open(path)?
        .write_all(text.as_bytes())
}

fn show_compat_notes() {
    out::step("Compatibility:");
    out::info("  Supported   : Ubuntu 24.04 based live distros - Linux Mint 22.x, Zorin OS 18.x.");
    out::info("  NOT supported: Ubuntu 26.04+ (still uses NetworkManager, but its nmcli is broken,");
    out::info("                so the nmcli-based wifi tooling in onboot.sh / wifi.sh breaks).");
}

fn assert_admin(opts: &cli::Opts) {
    if opts.no_elevation {
        return;
    }
    if sys::is_admin() {
        return;
    }
    out::warn("Administrator rights are required (Rufus + USB writes).");
    out::info("Requesting elevation - accept the UAC prompt to continue...");
    let exe = std::env::current_exe()
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_default();
    let args: Vec<String> = win95_args().into_iter().skip(1).collect();
    match sys::run_elevated(&exe, &args) {
        Ok(child) => {
            // The elevated instance runs in its own console; wait for it and
            // propagate its exit code so callers (install.bat, CI) see the
            // real result.
            out::info("Elevated instance launched; waiting for it to finish...");
            let code = match child {
                Some(c) => {
                    c.wait(u32::MAX);
                    c.exit_code().unwrap_or(0)
                }
                None => 0,
            };
            std::process::exit(code as i32);
        }
        Err(e) => {
            out::err(&format!("Elevation was declined or failed ({}).", e));
            out::info("To continue: right-click the installer and choose \"Run as administrator\",");
            out::info("or re-run from an Administrator console (Rufus and USB writes need admin).");
            std::process::exit(1);
        }
    }
}

fn confirm_secure_boot() {
    if boot::secure_boot_status() != sys::SecBoot::Enabled {
        return;
    }
    out::warn("Secure Boot is ENABLED in this machine firmware.");
    out::info("Linux Mint ships a Microsoft-signed boot shim, so the USB usually boots");
    out::info("under Secure Boot. On first boot you may see a blue \"MOK management\" screen");
    out::info("asking to enroll Linux Mint's signing key - choose \"Enroll MOK\" and continue.");
    out::info("If the USB will not start at all, disable Secure Boot in your firmware setup");
    out::info("(Boot / Security / Authentication menu) and try again.");
    let ans = out::prompt("If you have enrolled the MOK (or disabled Secure Boot), type OK to continue; otherwise press Enter to abort: ");
    if ans != "OK" {
        out::err("Aborted. Enroll the Linux Mint MOK or disable Secure Boot, then re-run the installer.");
        std::process::exit(1);
    }
}

fn warn_low_ram() {
    let bytes = sys::total_ram();
    if bytes > 0 && bytes < 4 * sys::GB {
        out::warn(&format!(
            "This machine has only {:.1} GB RAM.",
            bytes as f64 / sys::GB as f64
        ));
        out::info("The first boot installs packages and can need >= 4 GB RAM. If you will boot this");
        out::info("USB on THIS machine, expect a slow or OOM-prone first boot. (The boot machine's");
        out::info("RAM is checked again at first boot.)");
    }
}

/// Select-ExistingUsb (console): offer reuse of an already-plugged Mint USB.
fn select_existing_usb(label: &str) -> Option<sys::Volume> {
    let found = sys::find_usb_volumes(label, &[]);
    if found.is_empty() {
        return None;
    }
    out::step("Existing Mint live USB detected");
    for (i, v) in found.iter().enumerate() {
        let lsl = sys::path_exists(&format!("{}\\bin\\uproot", v.root()))
            || sys::path_exists(&format!("{}\\lsl-usb.env", v.root()));
        let kind = if lsl {
            "lsl-usb (update)"
        } else {
            "plain Mint live (first install)"
        };
        let img = match sys::file_size(&format!("{}\\casper\\filesystem.squashfs", v.root())) {
            Some(sz) => format!("  {:.2} GB image", sz as f64 / sys::GB as f64),
            None => String::new(),
        };
        out::info(&format!(
            "  {:2}. {}:  {}  {:.1} GB  {}{}",
            i + 1,
            v.letter,
            v.label,
            v.size_gb(),
            kind,
            img
        ));
    }
    out::info("Reusing skips the ISO download and the Rufus re-write; the lsl-usb files are dropped in place.");
    let ans = out::prompt("Choose a USB [1..N] to install lsl-usb onto now, or 0 to write fresh via Rufus: ");
    if let Ok(n) = ans.parse::<usize>() {
        if n >= 1 && n <= found.len() {
            return Some(found[n - 1].clone());
        }
    }
    None
}

/// Pick the desktop installer ISO out of an Ubuntu-flavor cdimage directory
/// listing (Apache autoindex HTML). Returns (file_url, file_name), preferring
/// the 64-bit desktop live image (`*-desktop-amd64.iso`, what the USB write
/// paths expect) and falling back to the last `.iso` link. Manifest /
/// metalink / torrent / zsync sidecar links are never ISOs and are skipped.
pub(crate) fn pick_flavor_iso(listing: &str, base_url: &str) -> Option<(String, String)> {
    let mut cands: Vec<String> = Vec::new();
    let mut from = 0;
    while let Some(rel) = listing[from..].find("href=\"") {
        let s = from + rel + 6;
        let rest = &listing[s..];
        let end = rest.find('"')?;
        let href = &rest[..end];
        if href.ends_with(".iso") {
            let lower = href.to_lowercase();
            if !lower.contains("manifest")
                && !lower.contains("metalink")
                && !lower.contains("torrent")
                && !lower.contains("zsync")
            {
                if let Some(base) = href.rsplit('/').next() {
                    if !base.is_empty() && !cands.contains(&base.to_string()) {
                        cands.push(base.to_string());
                    }
                }
            }
        }
        from = s + end + 1;
    }
    cands.sort();
    let pick = cands
        .iter()
        .filter(|n| n.contains("desktop") && n.contains("amd64"))
        .last()
        .or(cands.last())?;
    let base = base_url.trim_end_matches('/');
    Some((format!("{}/{}", base, pick), (*pick).clone()))
}

/// Resolve a page-1 "Download Fresh" URL to a directly-downloadable ISO.
/// Direct `.iso` URLs pass through; Ubuntu-flavor cdimage *directory* URLs
/// (Lubuntu/Xubuntu `.../release/`) are scraped for the current desktop ISO
/// so Install keeps working instead of aborting to the browser flow.
/// Returns None for real download *pages* (antiX/Zorin HTML pages), which
/// still need the browser + manual pick.
pub(crate) fn resolve_page_iso(url: &str) -> Option<(String, String)> {
    if url.ends_with(".iso") {
        let name = url
            .rsplit('/')
            .next()
            .filter(|s| s.ends_with(".iso"))
            .unwrap_or("downloaded.iso")
            .to_string();
        return Some((url.to_string(), name));
    }
    if url.contains("cdimage.ubuntu.com") {
        match net::get(url, net::user_agent()) {
            Ok(r) if r.status == 200 => {
                return pick_flavor_iso(&String::from_utf8_lossy(&r.body), url);
            }
            _ => return None,
        }
    }
    None
}

/// Fatal error inside the Install working phase: the wizard window is still
/// open, but the elevated child may own a different console (or none) than
/// the one the user is watching - via ShellExecute "runas" the child gets
/// its own console window, which vanishes on exit. Print to the console AND
/// show a dialog with the reason, so a failure never looks like a silent
/// abort with no explanation.
fn fatal_gui(msg: &str, ui: &gui::WorkingUi) -> ! {
    ui.close();
    out::err(msg);
    use winapi::um::winuser::{MB_ICONERROR, MB_OK, MessageBoxA};
    let mut m: Vec<u8> = msg.bytes().collect();
    m.push(0);
    unsafe {
        MessageBoxA(
            0 as _,
            m.as_ptr() as *const _,
            b"lslsetup\0".as_ptr() as *const _,
            MB_OK | MB_ICONERROR,
        );
    }
    std::process::exit(1);
}

/// Resolve-Iso: provided path -> existing ISO picker -> download (Mint or the
/// GUI-chosen distro URL).
fn resolve_iso(
    path: &str,
    mint_version: &str,
    download_dir: &str,
    _bundle_dir: &str,
    auto_download: bool,
    gui_download: Option<(String, String)>,
    ui: Option<&crate::gui::WorkingUi>,
) -> Result<String, String> {
    if !path.is_empty() {
        if !sys::path_exists(path) {
            return Err(format!("ISO not found: {}", path));
        }
        out::info(&format!("Using provided ISO: {}", path));
        return Ok(path.to_string());
    }

    // Offer an existing ISO found via Everything / filesystem before
    // downloading. Skipped when the GUI already chose a fresh download: the
    // wizard selection IS the choice, and asking again would ignore what the
    // user picked (and re-prompt for a download already running in the
    // background).
    if gui_download.is_none() {
        if let Some(existing) = select_existing_iso() {
            out::info(&format!("Using existing ISO: {}", existing));
            return Ok(existing);
        }
    }

    if !auto_download {
        return Err("No ISO given and download disabled (--skip-iso-download).".into());
    }

    let (url, iso_name) = match &gui_download {
        Some((u, _)) => match resolve_page_iso(u) {
            Some((real_url, real_name)) => {
                if !u.ends_with(".iso") {
                    out::info(&format!(
                        "Resolved {} to the current desktop ISO: {}",
                        u, real_name
                    ));
                }
                (real_url, real_name)
            }
            None => {
                // Real download *page* (antiX/Zorin HTML): open it in the
                // browser so the user picks the latest ISO there.
                out::info(&format!("Opening {} in your browser - pick the ISO there, then re-run and use the local-ISO section.", u));
                sys::open_url(u);
                return Err(format!("Pick the ISO from {} manually, then re-run and choose it under 'Use Already Downloaded ISO'.", u));
            }
        },
        None => (
            format!(
                "https://mirrors.kernel.org/linuxmint/stable/{}/linuxmint-{}-cinnamon-64bit.iso",
                mint_version, mint_version
            ),
            format!("linuxmint-{}-cinnamon-64bit.iso", mint_version),
        ),
    };

    let dir = if download_dir.is_empty() {
        sys::downloads_dir()
    } else {
        download_dir.to_string()
    };
    let dest = format!("{}\\{}", dir, iso_name);
    if !sys::path_exists(&dest) {
        let local = {
            let mut v = lslfiles::find_everything_isos();
            if v.is_empty() {
                v = lslfiles::find_local_isos();
            }
            v
        };
        if !local.is_empty() {
            out::info("Local ISO image(s) found that you could use instead:");
            for p in local.iter().take(5) {
                out::info(&format!("  {}", p));
            }
        }
        // The GUI download selection is its own confirmation; only the
        // pure-console flow gets the typed OK prompt.
        if gui_download.is_none() {
            let ans = out::prompt(&format!(
                "Download {} (~3 GB) to {}? Type OK to continue, or press Enter to abort: ",
                iso_name, dir
            ));
            if ans != "OK" {
                return Err(format!(
                    "Aborted. Re-run and pick an existing ISO ({} shown above), or type OK at the download prompt.",
                    if local.is_empty() { "none found" } else { "listed above" }
                ));
            }
        }
        sys::create_dir_all(&dir);
        out::step(&format!("Downloading {} (~3 GB) from {}...", iso_name, base_url(&url)));
        if !net::has_transport() {
            return Err(format!(
                "No HTTP transport on this Windows (winhttp.dll absent).\n\
                 Download manually:\n  {}\nand save it as:\n  {}\nthen re-run with --iso-path.",
                url, dest
            ));
        }
        let mut last = 0u64;
        let mut last_ui = 0u64;
        match net::download_to_file(&url, &dest, net::user_agent(), &mut |n| {
            let mb = n / sys::MB;
            if mb >= last + 200 {
                last = mb;
                out::info(&format!("  {} MB...", mb));
            }
            // the wizard window is still open: keep its status + progress
            // live (the message pump repaints; without this the window the
            // user is watching would sit frozen mid-download)
            if let Some(ui) = ui {
                if mb >= last_ui + 50 {
                    last_ui = mb;
                    ui.set_status(&format!("Downloading {} - {} MB of ~3 GB...", iso_name, mb));
                    ui.pump();
                }
            }
        }) {
            Ok(n) if n > 0 => {}
            _ => {
                sys::delete_file(&dest);
                return Err(format!(
                    "Download failed. Fetch manually:\n  {}\nand save as:\n  {}",
                    url, dest
                ));
            }
        }
    } else {
        out::info(&format!("ISO already present: {}", dest));
    }

    // Verify SHA-256 for Mint (the only distro we have a checksum contract for).
    if iso_name.starts_with("linuxmint-") {
        out::info("Verifying SHA-256 against the official sha256sum.txt...");
        let sum_url = format!("{}/sha256sum.txt", base_url(&url));
        let expected = match net::get(&sum_url, net::user_agent()) {
            Ok(r) if r.status == 200 => {
                let text = String::from_utf8_lossy(&r.body).into_owned();
                find_checksum(&text, &iso_name)
            }
            _ => None,
        };
        match expected {
            Some(exp) => {
                out::info("Computing SHA-256 of the downloaded ISO (this takes a while)...");
                match lslfiles::sha256_file(&dest) {
                    Some(actual) if actual.eq_ignore_ascii_case(&exp) => {
                        out::info("SHA256 verified.");
                    }
                    Some(actual) => {
                        sys::delete_file(&dest);
                        return Err(format!(
                            "SHA256 mismatch for {}.\n  expected: {}\n  actual:   {}\nDownload deleted; try again or fetch manually.",
                            iso_name, exp, actual
                        ));
                    }
                    None => return Err("Cannot read the downloaded ISO for hashing.".into()),
                }
            }
            None => out::warn("Could not fetch the official checksum - proceeding UNVERIFIED."),
        }
    } else {
        out::info("SHA-256 not verified for this distro (no checksum contract).");
    }
    Ok(dest)
}

fn base_url(url: &str) -> String {
    match url.rfind('/') {
        Some(i) => url[..i].to_string(),
        None => url.to_string(),
    }
}

fn find_checksum(sum_text: &str, iso_name: &str) -> Option<String> {
    for line in sum_text.lines() {
        if line.contains(iso_name) {
            let first = line.split_whitespace().next()?;
            if first.len() == 64 && first.chars().all(|c| c.is_ascii_hexdigit()) {
                return Some(first.to_lowercase());
            }
        }
    }
    None
}

/// Test-LiveIso (pure-Rust ISO9660 — no Mount-DiskImage needed, works on all
/// Windows versions; on Win8+ the PS version required Enterprise features).
fn validate_live_iso(path: &str) -> Result<(), String> {
    out::step(&format!("Validating {} ...", path));
    let check = crate::iso::check_live_iso(path)?;
    out::info(&format!("Image info: {}", check.info));
    out::info(&format!("dists codenames: {}", check.dists.join(", ")));
    if check.info.contains("26.04") {
        return Err("Ubuntu 26.04+ detected. Not supported: it still uses NetworkManager, but its nmcli is broken, so the nmcli-based wifi tooling breaks. Use an Ubuntu 24.04 based image (Mint 22.x, Zorin 18.x).".into());
    }
    if check.dists.iter().any(|d| d.eq_ignore_ascii_case("noble")) {
        out::info("Confirmed Ubuntu 24.04 base (dists/noble) - supported.");
    } else if !check.dists.is_empty() {
        return Err(format!(
            "Not an Ubuntu 24.04 based image (dists codenames: {}). Only Ubuntu 24.04 based images (Mint 22.x, Zorin 18.x) are supported.",
            check.dists.join(", ")
        ));
    } else {
        out::warn("No dists codenames found; cannot confirm the Ubuntu 24.04 base.");
    }
    out::info("ISO validation passed.");
    Ok(())
}

/// Select-ExistingIso (console).
fn select_existing_iso() -> Option<String> {
    let mut isos = lslfiles::find_everything_isos();
    if isos.is_empty() {
        isos = lslfiles::find_local_isos();
    }
    // drop empty / partial downloads (0.00 GB entries in the picker)
    isos.retain(|p| sys::file_size(p).unwrap_or(0) > 0);
    if isos.is_empty() {
        return None;
    }
    out::step(&format!("Found {} existing ISO image(s):", isos.len()));
    for (i, p) in isos.iter().enumerate() {
        let sz = sys::file_size(p).unwrap_or(0);
        out::info(&format!("  {:2}. {}  {:.2} GB", i + 1, p, sz as f64 / sys::GB as f64));
    }
    let ans = out::prompt("Use an existing ISO? Enter its number, or press Enter to download a fresh Mint ISO: ");
    if let Ok(n) = ans.parse::<usize>() {
        if n >= 1 && n <= isos.len() {
            return Some(isos[n - 1].clone());
        }
    }
    None
}

/// Assert-UsbCapacity: warn before the Rufus write + first boot.
fn assert_usb_capacity(vol: &sys::Volume, iso_path: &str) {
    let iso_size = if iso_path.is_empty() {
        0
    } else {
        sys::file_size(iso_path).unwrap_or(0)
    };
    let vols = sys::list_volumes();
    let Some(v) = vols.into_iter().find(|v| v.letter.eq_ignore_ascii_case(&vol.letter)) else {
        return;
    };
    if v.free == 0 && v.total == 0 {
        return;
    }
    // Appended squashfs layer (apt changes): ~4 GB. /cdrom/home.sfs: ~2 GB.
    // Plus a 1 GB buffer.
    let added_est = 4 * sys::GB + 2 * sys::GB + sys::GB;
    let remaining_after_iso = v.free.saturating_sub(iso_size);
    if remaining_after_iso < added_est {
        out::warn(&format!(
            "Target USB {}: ~{:.1} GB free; after the {:.1} GB ISO is written, ~{:.1} GB remains.",
            v.letter,
            v.free as f64 / sys::GB as f64,
            iso_size as f64 / sys::GB as f64,
            remaining_after_iso as f64 / sys::GB as f64
        ));
        out::info(&format!(
            "lsl-usb then needs ~{:.1} GB for the appended layer + home.sfs (+ buffer). Use a larger USB (>= 16 GB recommended).",
            added_est as f64 / sys::GB as f64
        ));
        out::info("You can continue, but the first boot may fail to persist changes if space runs out.");
        let ans = out::prompt("Type OK to continue anyway, or press Enter to abort: ");
        if ans != "OK" {
            out::err("Aborted - use a larger USB.");
            std::process::exit(1);
        }
    }
}

// ----------------------------------------------------------------- Win95 ---
/// Win95-safe command line: `GetCommandLineW` is a no-op stub on Windows 95
/// (returns NULL), so `std::env::args()` cannot be used. Read the ANSI
/// command line instead. DBCS bytes decode lossily, which is fine for the
/// ASCII-only options this program takes.
#[cfg(windows)]
fn win95_args() -> Vec<String> {
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetCommandLineA() -> *const u8;
    }
    unsafe {
        let p = GetCommandLineA();
        if p.is_null() {
            return Vec::new();
        }
        let mut raw = Vec::new();
        let mut i = 0usize;
        while *p.add(i) != 0 {
            raw.push(*p.add(i));
            i += 1;
        }
        let mut out: Vec<String> = Vec::new();
        let mut cur = String::new();
        let mut in_quotes = false;
        for &b in &raw {
            match b {
                b'"' => in_quotes = !in_quotes,
                b' ' | b'\t' if !in_quotes => {
                    if !cur.is_empty() {
                        out.push(std::mem::take(&mut cur));
                    }
                }
                _ => cur.push(b as char),
            }
        }
        if !cur.is_empty() {
            out.push(cur);
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mint_version_parse() {
        assert_eq!(
            mint_version_from_name("linuxmint-22.3-cinnamon-64bit.iso"),
            Some("22.3".to_string())
        );
        assert_eq!(
            mint_version_from_name("C:\\Downloads\\linuxmint-21.3-mate-64bit.iso"),
            Some("21.3".to_string())
        );
        // non-Mint ISOs have no checksum contract
        assert_eq!(mint_version_from_name("ubuntu-24.04.iso"), None);
        assert_eq!(mint_version_from_name("debian-live-13.6.0.iso"), None);
        assert_eq!(mint_version_from_name("redox_desktop_i686.iso"), None);
        assert_eq!(mint_version_from_name("linuxmint-"), Some("".to_string()));
    }

    #[test]
    fn pick_flavor_iso_prefers_latest_desktop_amd64() {
        let listing = "<html><head><title>Index of /lubuntu/releases/24.04/release/</title></head><body>\
<a href=\"?C=N;O=D\">Name</a>\
<a href=\"/lubuntu/releases/24.04/\">Parent Directory</a>\
<a href=\"lubuntu-24.04-desktop-amd64.iso\">lubuntu-24.04-desktop-amd64.iso</a>\
<a href=\"lubuntu-24.04-desktop-amd64.iso.zsync\">zsync</a>\
<a href=\"lubuntu-24.04-desktop-amd64.manifest\">manifest</a>\
<a href=\"lubuntu-24.04.3-desktop-amd64.iso\">lubuntu-24.04.3-desktop-amd64.iso</a>\
<a href=\"lubuntu-24.04.3-desktop-amd64.iso.torrent\">torrent</a>\
<a href=\"SHA256SUMS\">SHA256SUMS</a>\
</body></html>";
        assert_eq!(
            pick_flavor_iso(
                listing,
                "https://cdimage.ubuntu.com/lubuntu/releases/24.04/release/"
            ),
            Some((
                "https://cdimage.ubuntu.com/lubuntu/releases/24.04/release/lubuntu-24.04.3-desktop-amd64.iso"
                    .to_string(),
                "lubuntu-24.04.3-desktop-amd64.iso".to_string()
            ))
        );
    }

    #[test]
    fn pick_flavor_iso_falls_back_to_any_iso() {
        let listing = "<a href=\"custom-1.0-i386.iso\">x</a><a href=\"custom-1.1-i386.iso\">y</a>";
        assert_eq!(
            pick_flavor_iso(listing, "https://example.com/dir"),
            Some((
                "https://example.com/dir/custom-1.1-i386.iso".to_string(),
                "custom-1.1-i386.iso".to_string()
            ))
        );
    }

    #[test]
    fn pick_flavor_iso_none_without_iso_links() {
        let listing =
            "<html><body><a href=\"SHA256SUMS\">sums</a><a href=\"/\">parent</a></body></html>";
        assert_eq!(pick_flavor_iso(listing, "https://example.com/dir/"), None);
    }

    #[test]
    fn resolve_page_iso_passes_direct_urls_through() {
        assert_eq!(
            resolve_page_iso("https://example.com/d/linuxmint-22.3-cinnamon-64bit.iso"),
            Some((
                "https://example.com/d/linuxmint-22.3-cinnamon-64bit.iso".to_string(),
                "linuxmint-22.3-cinnamon-64bit.iso".to_string()
            ))
        );
        // real download *pages* (no cdimage listing) still need the browser flow
        assert_eq!(resolve_page_iso("https://antixlinux.com/download/"), None);
    }
}
