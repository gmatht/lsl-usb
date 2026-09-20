//! Boot-result telemetry: probe USB boot outcomes and crowdsource a
//! firmware-compatibility database.
//!
//! Before reboot, lslsetup writes a probe file to the USB stick.
//! If Linux boots, onboot.sh writes a result file back.
//! On the next Windows run, lslsetup detects the result and offers
//! to upload it via a pre-filled GitHub issue URL (no API auth needed).

use crate::sys;

// Set this to your GitHub repository before shipping.
const GITHUB_REPO: &str = "gmatht/linux-hardware-support";
const PROBE_DIR: &str = "lsl-boot-probe";
const PROBE_EXT: &str = ".probe.txt";
const RESULT_EXT: &str = ".result.txt";

// Cloudflare Worker endpoint for anonymous hardware-report submission.
// Replace with your own worker URL after deploying.
const WORKER_URL: &str = "https://lsl-usb-reports-api.gmatht.workers.dev/report";
const WORKER_TOKEN: &str = "lsl-usb-v1";

/// Data written by Windows before reboot.
#[derive(Debug, Clone)]
pub struct Probe {
    pub id: String,
    pub lslsetup_version: String,
    pub windows_version: String,
    pub is_uefi: bool,
    pub secure_boot: String,
    pub motherboard_manufacturer: String,
    pub motherboard_product: String,
    pub cpu: String,
    pub boot_method: String,
    // Hardware detected on Windows side for cross-reference
    pub wifi_adapter: String,
    pub ethernet_adapter: String,
    pub gpu: String,
}

/// Data written by Linux after boot.
#[derive(Debug, Clone)]
pub struct BootReport {
    pub probe: Probe,
    pub boot_success: bool,
    pub boot_timestamp: String,
    pub linux_distro: String,
    pub kernel: String,
    pub firstboot_ok: bool,
    pub network_ok: bool,
    // Per-hardware Linux status (automated + user-reported)
    pub wifi_worked: bool,
    pub ethernet_worked: bool,
    pub audio_worked: bool,
    pub gpu_worked: bool,
    pub shutdown_clean: bool,
}

/// Write a probe file to the target USB volume before rebooting.
/// Returns the probe ID so callers can update the boot_method later.
pub fn write_probe(vol_letter: &str, boot_method: &str) -> String {
    let id = format!("{}-{:04x}", timestamp_compact(), random_id());
    let probe = Probe {
        id: id.clone(),
        lslsetup_version: env!("CARGO_PKG_VERSION").to_string(),
        windows_version: windows_version_string(),
        is_uefi: crate::boot::is_uefi(),
        secure_boot: format!("{:?}", crate::boot::secure_boot_status()),
        motherboard_manufacturer: reg_value(
            "HARDWARE\\DESCRIPTION\\System\\BIOS",
            "BaseBoardManufacturer",
        )
        .or_else(|| reg_value("HARDWARE\\DESCRIPTION\\System\\BIOS", "SystemManufacturer"))
        .unwrap_or_default(),
        motherboard_product: reg_value(
            "HARDWARE\\DESCRIPTION\\System\\BIOS",
            "BaseBoardProduct",
        )
        .unwrap_or_default(),
        cpu: reg_value(
            "HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0",
            "ProcessorNameString",
        )
        .unwrap_or_default(),
        boot_method: boot_method.to_string(),
        wifi_adapter: first_network_adapter("Wireless"),
        ethernet_adapter: first_network_adapter("Ethernet"),
        gpu: reg_value(
            "HARDWARE\\DEVICEMAP\\VIDEO",
            "\\Device\\Video0",
        )
        .unwrap_or_default(),
    };

    let dir = format!("{}:\\{}", vol_letter, PROBE_DIR);
    sys::create_dir_all(&dir);
    let path = format!("{}\\{}{}", dir, id, PROBE_EXT);
    let lines = probe_lines(&probe);
    let _ = std::fs::write(&path, lines.join("\r\n"));
    schedule_auto_upload();
    id
}

/// Update the boot_method in an existing probe file (e.g. after the user
/// picks a specific boot option in the reboot dialog).
pub fn update_probe_boot_method(vol_letter: &str, probe_id: &str, boot_method: &str) {
    let dir = format!("{}:\\{}", vol_letter, PROBE_DIR);
    let path = format!("{}\\{}{}", dir, probe_id, PROBE_EXT);
    let text = match std::fs::read_to_string(&path) {
        Ok(t) => t,
        Err(_) => return,
    };
    let mut lines: Vec<String> = text.lines().map(|s| s.to_string()).collect();
    let mut found = false;
    for line in &mut lines {
        if line.starts_with("boot_method: ") {
            *line = format!("boot_method: {}", boot_method);
            found = true;
            break;
        }
    }
    if found {
        let _ = std::fs::write(&path, lines.join("\r\n"));
    }
}

/// Update the most recent probe file on the given volume. Used when the
/// early write_probe used "pending" and the user later picked a concrete
/// boot method. Returns true if a probe was found and updated.
pub fn update_latest_probe(vol_letter: &str, boot_method: &str) -> bool {
    let dir = format!("{}:\\{}", vol_letter, PROBE_DIR);
    let mut latest: Option<(std::time::SystemTime, String)> = None;
    for entry in std::fs::read_dir(&dir).ok().into_iter().flatten() {
        let entry = match entry {
            Ok(e) => e,
            Err(_) => continue,
        };
        let name = entry.file_name().to_string_lossy().into_owned();
        if !name.ends_with(PROBE_EXT) {
            continue;
        }
        let meta = match entry.metadata() {
            Ok(m) => m,
            Err(_) => continue,
        };
        let mtime = match meta.modified() {
            Ok(t) => t,
            Err(_) => continue,
        };
        if latest.as_ref().map(|(t, _)| mtime > *t).unwrap_or(true) {
            latest = Some((mtime, name));
        }
    }
    if let Some((_, name)) = latest {
        let probe_id = name.trim_end_matches(PROBE_EXT);
        update_probe_boot_method(vol_letter, probe_id, boot_method);
        true
    } else {
        false
    }
}

// ---------------------------------------------------------------------------
// Auto-upload on next Windows boot (Run key)
// ---------------------------------------------------------------------------
const RUN_KEY_PATH: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
const RUN_VALUE_NAME: &str = "lsl-usb-auto-upload";

/// Register lslsetup to run once on the next Windows boot with --auto-upload.
/// Call this when the probe is written (just before reboot). Uses HKCU so
/// no elevation is needed.
pub fn schedule_auto_upload() {
    let exe = match std::env::current_exe() {
        Ok(p) => p.to_string_lossy().into_owned(),
        Err(_) => return,
    };
    let cmd = format!("\"{}\" --auto-upload", exe);
    if let Some(key) = crate::sys::RegKey::create(crate::sys::hkcu(), RUN_KEY_PATH) {
        key.set_value_string(RUN_VALUE_NAME, &cmd);
    }
}

/// Remove the auto-upload Run key entry. Call this after the upload check
/// runs (success or failure) so it never prompts again.
pub fn cancel_auto_upload() {
    if let Some(key) = crate::sys::RegKey::create(crate::sys::hkcu(), RUN_KEY_PATH) {
        key.delete_value(RUN_VALUE_NAME);
    }
}

/// Whether the auto-upload Run key is still registered.
pub fn is_auto_upload_scheduled() -> bool {
    let key = match crate::sys::RegKey::open(crate::sys::hkcu(), RUN_KEY_PATH) {
        Some(k) => k,
        None => return false,
    };
    key.value(RUN_VALUE_NAME).is_some()
}

/// Scan all volumes for completed boot reports.
/// Many USB sticks report as DRIVE_FIXED (not DRIVE_REMOVABLE) via
/// Windows GetDriveType, so we scan every volume that actually holds a
/// lsl-boot-probe directory instead of gating on vol.removable.
pub fn check_results() -> Vec<BootReport> {
    let mut out = Vec::new();
    for vol in sys::list_volumes() {
        let dir = format!("{}:\\{}", vol.letter, PROBE_DIR);
        if !sys::is_dir(&dir) {
            continue;
        }
        let probes = list_files_with_ext(&dir, PROBE_EXT);
        for probe_path in probes {
            let result_path = probe_path.replace(PROBE_EXT, RESULT_EXT);
            if !sys::path_exists(&result_path) {
                continue;
            }
            if let Some(probe) = read_probe(&probe_path) {
                if let Some(result) = read_result(&result_path, probe) {
                    out.push(result);
                }
            }
        }
    }
    out
}

/// Find orphaned probes: Linux never wrote a result file, so the boot
/// almost certainly failed (or the user never booted the USB at all).
/// Scans all volumes (see check_results for why removable-only is wrong).
pub fn check_failures() -> Vec<Probe> {
    let mut out = Vec::new();
    for vol in sys::list_volumes() {
        let dir = format!("{}:\\{}", vol.letter, PROBE_DIR);
        if !sys::is_dir(&dir) {
            continue;
        }
        let probes = list_files_with_ext(&dir, PROBE_EXT);
        for probe_path in probes {
            let result_path = probe_path.replace(PROBE_EXT, RESULT_EXT);
            if sys::path_exists(&result_path) {
                continue; // boot succeeded, already handled by check_results
            }
            if let Some(probe) = read_probe(&probe_path) {
                out.push(probe);
            }
        }
    }
    out
}

/// Convert an orphaned probe into a synthetic failure report so the
/// upload pipeline treats successes and failures uniformly.
pub fn failure_report(probe: &Probe) -> BootReport {
    BootReport {
        probe: probe.clone(),
        boot_success: false,
        boot_timestamp: String::new(),
        linux_distro: String::new(),
        kernel: String::new(),
        firstboot_ok: false,
        network_ok: false,
        wifi_worked: false,
        ethernet_worked: false,
        audio_worked: false,
        gpu_worked: false,
        shutdown_clean: false,
    }
}

/// Serialize a BootReport into JSON and POST it to the Cloudflare Worker.
/// Returns Ok(true) on HTTP 200, Ok(false) on HTTP error, Err on transport failure.
pub fn post_report(report: &BootReport) -> Result<bool, String> {
    let json = serde_json::json!({
        "probe_id": report.probe.id,
        "boot_success": report.boot_success,
        "boot_outcome": boot_outcome_description(report),
        "boot_timestamp": report.boot_timestamp,
        "linux_distro": report.linux_distro,
        "kernel": report.kernel,
        "motherboard": format!("{} {}", report.probe.motherboard_manufacturer, report.probe.motherboard_product),
        "cpu": report.probe.cpu,
        "is_uefi": report.probe.is_uefi,
        "secure_boot": report.probe.secure_boot,
        "boot_method": report.probe.boot_method,
        "wifi_adapter": report.probe.wifi_adapter,
        "wifi_worked": report.wifi_worked,
        "ethernet_adapter": report.probe.ethernet_adapter,
        "ethernet_worked": report.ethernet_worked,
        "gpu": report.probe.gpu,
        "gpu_worked": report.gpu_worked,
        "audio_worked": report.audio_worked,
        "firstboot_ok": report.firstboot_ok,
        "network_ok": report.network_ok,
        "shutdown_clean": report.shutdown_clean,
        "lslsetup_version": report.probe.lslsetup_version,
        "windows_version": report.probe.windows_version,
    });
    let body = json.to_string().into_bytes();
    let headers = format!("X-Lsl-Token: {}\r\n", WORKER_TOKEN);
    match crate::net::post(WORKER_URL, crate::net::user_agent(), &body, &headers) {
        Ok(res) if res.status == 200 => Ok(true),
        Ok(res) => {
            let msg = String::from_utf8_lossy(&res.body);
            Err(format!("Worker returned HTTP {}: {}", res.status, msg))
        }
        Err(e) => Err(format!("Network error: {}", e)),
    }
}

/// Save the report as JSON to the USB stick so the user can submit it later
/// if the automatic POST fails.
pub fn save_report_to_usb(report: &BootReport, vol_letter: &str) -> Option<String> {
    let json = serde_json::json!({
        "probe_id": report.probe.id,
        "boot_success": report.boot_success,
        "boot_outcome": boot_outcome_description(report),
        "boot_timestamp": report.boot_timestamp,
        "linux_distro": report.linux_distro,
        "kernel": report.kernel,
        "motherboard": format!("{} {}", report.probe.motherboard_manufacturer, report.probe.motherboard_product),
        "cpu": report.probe.cpu,
        "is_uefi": report.probe.is_uefi,
        "secure_boot": report.probe.secure_boot,
        "boot_method": report.probe.boot_method,
        "wifi_adapter": report.probe.wifi_adapter,
        "wifi_worked": report.wifi_worked,
        "ethernet_adapter": report.probe.ethernet_adapter,
        "ethernet_worked": report.ethernet_worked,
        "gpu": report.probe.gpu,
        "gpu_worked": report.gpu_worked,
        "audio_worked": report.audio_worked,
        "firstboot_ok": report.firstboot_ok,
        "network_ok": report.network_ok,
        "shutdown_clean": report.shutdown_clean,
        "lslsetup_version": report.probe.lslsetup_version,
        "windows_version": report.probe.windows_version,
    });
    let dir = format!("{}:\\{}", vol_letter, PROBE_DIR);
    sys::create_dir_all(&dir);
    let path = format!("{}\\{}-report.json", dir, report.probe.id);
    if std::fs::write(&path, json.to_string()).is_ok() {
        Some(path)
    } else {
        None
    }
}

/// Build a pre-filled GitHub issue URL so the user can upload with one click.
pub fn upload_url(report: &BootReport) -> String {
    let title = format!(
        "[compat] {} on {} {} — {}",
        report.linux_distro,
        report.probe.motherboard_manufacturer,
        report.probe.motherboard_product,
        if report.boot_success { "SUCCESS" } else { "FAILED" }
    );
    let body = format!(
        "## Boot Report\n\n\
        | Field | Value |\n\
        |-------|-------|\n\
        | **Result** | {} |\n\
        | **Distro** | {} |\n\
        | **Kernel** | {} |\n\
        | **Motherboard** | {} {} |\n\
        | **CPU** | {} |\n\
        | **UEFI** | {} |\n\
        | **Secure Boot** | {} |\n\
        | **Boot Method** | {} |\n\
        | **lslsetup** | {} |\n\
        | **Windows** | {} |\n\
        | **Boot Time** | {} |\n\
        | **Firstboot OK** | {} |\n\
        | **Network OK** | {} |\n\
        | **WiFi (Win)** | {} |\n\
        | **WiFi (Linux)** | {} |\n\
        | **Ethernet (Win)** | {} |\n\
        | **Ethernet (Linux)** | {} |\n\
        | **GPU (Win)** | {} |\n\
        | **Audio OK** | {} |\n\
        | **Shutdown Clean** | {} |\n\n\
        <!-- Auto-generated by lslsetup {} -->",
        if report.boot_success { "✅ Booted" } else { "❌ Did not boot" },
        report.linux_distro,
        report.kernel,
        report.probe.motherboard_manufacturer,
        report.probe.motherboard_product,
        report.probe.cpu,
        if report.probe.is_uefi { "Yes" } else { "No" },
        report.probe.secure_boot,
        report.probe.boot_method,
        report.probe.lslsetup_version,
        report.probe.windows_version,
        report.boot_timestamp,
        if report.firstboot_ok { "Yes" } else { "No" },
        if report.network_ok { "Yes" } else { "No" },
        report.probe.wifi_adapter,
        if report.wifi_worked { "✅" } else if report.boot_success { "❌" } else { "N/A" },
        report.probe.ethernet_adapter,
        if report.ethernet_worked { "✅" } else if report.boot_success { "❌" } else { "N/A" },
        report.probe.gpu,
        if report.gpu_worked { "✅" } else if report.boot_success { "❌" } else { "N/A" },
        if report.audio_worked { "✅" } else if report.boot_success { "❌" } else { "N/A" },
        if report.shutdown_clean { "✅" } else if report.boot_success { "❌" } else { "N/A" },
    );
    format!(
        "https://github.com/{}/issues/new?title={}&body={}&labels=compatibility",
        GITHUB_REPO,
        urlencode(&title),
        urlencode(&body)
    )
}

// ---------------------------------------------------------------------------
// Per-machine "Always upload" preference (HKCU, so no elevation needed)
// ---------------------------------------------------------------------------
const PREFS_KEY: &str = r"Software\lsl-usb";
const PREFS_AUTO_UPLOAD: &str = "auto_upload";

fn auto_upload_enabled() -> bool {
    let key = match sys::RegKey::open(sys::hkcu(), PREFS_KEY) {
        Some(k) => k,
        None => return false,
    };
    key.value(PREFS_AUTO_UPLOAD).map(|s| s == "1").unwrap_or(false)
}

fn set_auto_upload(enabled: bool) {
    if let Some(key) = sys::RegKey::create(sys::hkcu(), PREFS_KEY) {
        key.set_value_string(PREFS_AUTO_UPLOAD, if enabled { "1" } else { "0" });
    }
}

/// Describe what was attempted and what the outcome was.
fn boot_outcome_description(report: &BootReport) -> String {
    let method = match report.probe.boot_method.as_str() {
        "usb-one-time" => "One-time USB boot (bcdedit)",
        "advanced-menu" => "Advanced startup menu",
        "firmware-menu" => "Firmware boot menu",
        "pending" => "(user did not pick a boot option)",
        "none" => "(user chose not to reboot)",
        _ => &report.probe.boot_method,
    };

    if report.boot_success {
        format!("Linux booted successfully (method: {method})")
    } else {
        match report.probe.boot_method.as_str() {
            "pending" | "none" => format!("User did not attempt to reboot ({method})"),
            _ => format!("Attempted {method} — Linux did not boot (no result from onboot.sh)"),
        }
    }
}

/// Find the volume letter that holds the probe file for this report.
fn find_probe_volume(probe_id: &str) -> Option<String> {
    for vol in sys::list_volumes() {
        let path = format!("{}:\\{}\\{}{}", vol.letter, PROBE_DIR, probe_id, PROBE_EXT);
        if sys::path_exists(&path) {
            return Some(vol.letter);
        }
    }
    None
}

/// Delete the probe and result files for a given probe ID so they are not
/// re-scanned and re-uploaded on subsequent runs.
fn cleanup_probe_files(probe_id: &str) {
    if let Some(vol) = find_probe_volume(probe_id) {
        let dir = format!("{}:\\{}", vol, PROBE_DIR);
        let probe_path = format!("{}\\{}{}", dir, probe_id, PROBE_EXT);
        let result_path = format!("{}\\{}{}", dir, probe_id, RESULT_EXT);
        if sys::path_exists(&probe_path) {
            sys::delete_file(&probe_path);
        }
        if sys::path_exists(&result_path) {
            sys::delete_file(&result_path);
        }
    }
}

/// Build a human-readable preview of what would be uploaded.
fn report_preview(report: &BootReport) -> String {
    let mut lines = Vec::new();
    lines.push(boot_outcome_description(report));
    if !report.linux_distro.is_empty() {
        lines.push(format!("Linux distro: {}", report.linux_distro));
    }
    if !report.kernel.is_empty() {
        lines.push(format!("Kernel: {}", report.kernel));
    }
    lines.push(format!(
        "Motherboard: {} {}",
        report.probe.motherboard_manufacturer, report.probe.motherboard_product
    ));
    lines.push(format!("CPU: {}", report.probe.cpu));
    lines.push(format!("UEFI: {} | Secure Boot: {}",
        if report.probe.is_uefi { "Yes" } else { "No" },
        report.probe.secure_boot
    ));
    if !report.probe.wifi_adapter.is_empty() {
        lines.push(format!("WiFi adapter: {}", report.probe.wifi_adapter));
    }
    if !report.probe.ethernet_adapter.is_empty() {
        lines.push(format!("Ethernet adapter: {}", report.probe.ethernet_adapter));
    }
    lines.push(format!("lslsetup version: {} | Windows: {}",
        report.probe.lslsetup_version, report.probe.windows_version
    ));
    lines.join("\n")
}

/// Show a preview dialog, ask for explicit consent, then upload.
/// If the user has previously chosen "Always", skips the prompt entirely.
/// Returns true if the user wants to open the GitHub issue URL (fallback).
pub fn prompt_upload(report: &BootReport) -> bool {
    // Skip prompt if user previously chose "Always" on this machine
    let always = auto_upload_enabled();

    if !always {
        // 1. Build the preview + ask for consent
        let preview = report_preview(report);
        let consent_msg = format!(
            "lslsetup detected a previous USB boot attempt and would like to send \\n\
            an anonymous hardware-compatibility report. No personal data is included.\n\n\
            {preview}\n\n\
            Send this report?",
        );
        let wmsg = sys::wide(&consent_msg);
        let wcap = sys::wide("lsl-usb — Send Hardware Report?");
        let rc = unsafe {
            winapi::um::winuser::MessageBoxW(
                std::ptr::null_mut(),
                wmsg.as_ptr(),
                wcap.as_ptr(),
                winapi::um::winuser::MB_YESNO | winapi::um::winuser::MB_ICONQUESTION,
            )
        };
        if rc != winapi::um::winuser::IDYES {
            // User declined — still save a local copy so they can submit manually later
            if let Some(vol) = find_probe_volume(&report.probe.id) {
                let _ = save_report_to_usb(report, &vol);
            }
            return false;
        }

        // 2. Ask follow-up: remember this choice?
        let follow_msg = sys::wide(
            "Remember this choice?\n\n\
            Select Yes to always upload reports from this PC without asking again.\n\
            Select No to ask every time."
        );
        let follow_cap = sys::wide("lsl-usb — Remember Choice?");
        let rc2 = unsafe {
            winapi::um::winuser::MessageBoxW(
                std::ptr::null_mut(),
                follow_msg.as_ptr(),
                follow_cap.as_ptr(),
                winapi::um::winuser::MB_YESNO | winapi::um::winuser::MB_ICONQUESTION,
            )
        };
        if rc2 == winapi::um::winuser::IDYES {
            set_auto_upload(true);
        }
    }

    // 3. Upload with feedback
    match post_report(report) {
        Ok(true) => {
            cleanup_probe_files(&report.probe.id);
            if !always {
                let msg = sys::wide("Report uploaded successfully.\n\nThank you for helping build the compatibility database!");
                let cap = sys::wide("lsl-usb — Report Sent");
                unsafe {
                    winapi::um::winuser::MessageBoxW(
                        std::ptr::null_mut(),
                        msg.as_ptr(),
                        cap.as_ptr(),
                        winapi::um::winuser::MB_OK | winapi::um::winuser::MB_ICONINFORMATION,
                    );
                }
            }
            false
        }
        Ok(false) | Err(_) => {
            // Upload failed — save JSON locally and offer GitHub fallback
            let mut saved_path: Option<String> = None;
            if let Some(vol) = find_probe_volume(&report.probe.id) {
                saved_path = save_report_to_usb(report, &vol);
            }
            if always {
                // In always-mode, still notify that it failed
                let save_note = match &saved_path {
                    Some(p) => format!("\n\nA copy was saved to:\n{}", p),
                    None => "\n\n(Could not save a local copy.)".to_string(),
                };
                let fail_msg = sys::wide(&format!(
                    "Automatic upload failed.{save_note}\n\n\
                    Open a pre-filled GitHub issue instead?"
                ));
                let fail_cap = sys::wide("lsl-usb — Upload Failed");
                let rc = unsafe {
                    winapi::um::winuser::MessageBoxW(
                        std::ptr::null_mut(),
                        fail_msg.as_ptr(),
                        fail_cap.as_ptr(),
                        winapi::um::winuser::MB_YESNO | winapi::um::winuser::MB_ICONWARNING,
                    )
                };
                return rc == winapi::um::winuser::IDYES;
            }
            let save_note = match &saved_path {
                Some(p) => format!("\n\nA copy was saved to:\n{}", p),
                None => "\n\n(Could not save a local copy.)".to_string(),
            };
            let fallback_msg = format!(
                "Automatic upload failed.{save_note}\n\n\
                Open a pre-filled GitHub issue instead?",
            );
            let wmsg2 = sys::wide(&fallback_msg);
            let wcap2 = sys::wide("lsl-usb — Upload Failed");
            let rc2 = unsafe {
                winapi::um::winuser::MessageBoxW(
                    std::ptr::null_mut(),
                    wmsg2.as_ptr(),
                    wcap2.as_ptr(),
                    winapi::um::winuser::MB_YESNO | winapi::um::winuser::MB_ICONWARNING,
                )
            };
            rc2 == winapi::um::winuser::IDYES
        }
    }
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn probe_lines(p: &Probe) -> Vec<String> {
    vec![
        format!("probe_id: {}", p.id),
        format!("lslsetup_version: {}", p.lslsetup_version),
        format!("windows_version: {}", p.windows_version),
        format!("is_uefi: {}", p.is_uefi),
        format!("secure_boot: {}", p.secure_boot),
        format!("motherboard_manufacturer: {}", p.motherboard_manufacturer),
        format!("motherboard_product: {}", p.motherboard_product),
        format!("cpu: {}", p.cpu),
        format!("boot_method: {}", p.boot_method),
        format!("wifi_adapter: {}", p.wifi_adapter),
        format!("ethernet_adapter: {}", p.ethernet_adapter),
        format!("gpu: {}", p.gpu),
    ]
}

fn read_probe(path: &str) -> Option<Probe> {
    let text = std::fs::read_to_string(path).ok()?;
    let m = parse_kv(&text);
    Some(Probe {
        id: m.get("probe_id").cloned().unwrap_or_default(),
        lslsetup_version: m.get("lslsetup_version").cloned().unwrap_or_default(),
        windows_version: m.get("windows_version").cloned().unwrap_or_default(),
        is_uefi: m.get("is_uefi").map(|s| s == "true").unwrap_or(false),
        secure_boot: m.get("secure_boot").cloned().unwrap_or_default(),
        motherboard_manufacturer: m.get("motherboard_manufacturer").cloned().unwrap_or_default(),
        motherboard_product: m.get("motherboard_product").cloned().unwrap_or_default(),
        cpu: m.get("cpu").cloned().unwrap_or_default(),
        boot_method: m.get("boot_method").cloned().unwrap_or_default(),
        wifi_adapter: m.get("wifi_adapter").cloned().unwrap_or_default(),
        ethernet_adapter: m.get("ethernet_adapter").cloned().unwrap_or_default(),
        gpu: m.get("gpu").cloned().unwrap_or_default(),
    })
}

fn read_result(path: &str, probe: Probe) -> Option<BootReport> {
    let text = std::fs::read_to_string(path).ok()?;
    let m = parse_kv(&text);
    Some(BootReport {
        probe,
        boot_success: m.get("boot_success").map(|s| s == "true").unwrap_or(false),
        boot_timestamp: m.get("boot_timestamp").cloned().unwrap_or_default(),
        linux_distro: m.get("linux_distro").cloned().unwrap_or_default(),
        kernel: m.get("kernel").cloned().unwrap_or_default(),
        firstboot_ok: m.get("firstboot_ok").map(|s| s == "true").unwrap_or(false),
        network_ok: m.get("network_ok").map(|s| s == "true").unwrap_or(false),
        wifi_worked: m.get("wifi_worked").map(|s| s == "true").unwrap_or(false),
        ethernet_worked: m.get("ethernet_worked").map(|s| s == "true").unwrap_or(false),
        audio_worked: m.get("audio_worked").map(|s| s == "true").unwrap_or(false),
        gpu_worked: m.get("gpu_worked").map(|s| s == "true").unwrap_or(false),
        shutdown_clean: m.get("shutdown_clean").map(|s| s == "true").unwrap_or(true),
    })
}

fn parse_kv(text: &str) -> std::collections::HashMap<String, String> {
    let mut m = std::collections::HashMap::new();
    for line in text.lines() {
        if let Some(idx) = line.find(": ") {
            let k = line[..idx].trim().to_string();
            let v = line[idx + 2..].trim().to_string();
            m.insert(k, v);
        }
    }
    m
}

fn list_files_with_ext(dir: &str, ext: &str) -> Vec<String> {
    let mut out = Vec::new();
    let pattern = format!("{}\\*{}", dir, ext);
    let w = sys::wide(&pattern);
    unsafe {
        let mut fd: winapi::um::minwinbase::WIN32_FIND_DATAW = std::mem::zeroed();
        let h = winapi::um::fileapi::FindFirstFileW(w.as_ptr(), &mut fd);
        if h != winapi::um::handleapi::INVALID_HANDLE_VALUE {
            loop {
                let name = sys::from_wide(&fd.cFileName);
                if name != "." && name != ".." {
                    out.push(format!("{}\\{}", dir, name));
                }
                if winapi::um::fileapi::FindNextFileW(h, &mut fd) == 0 {
                    break;
                }
            }
            winapi::um::fileapi::FindClose(h);
        }
    }
    out
}

fn reg_value(path: &str, name: &str) -> Option<String> {
    let key = sys::RegKey::open(sys::hklm(), path)?;
    key.value(name)
}

/// Scan the Windows network adapter registry for the first adapter
/// whose DriverDesc contains the given keyword ("Wireless" or "Ethernet").
fn first_network_adapter(keyword: &str) -> String {
    let class_path = "SYSTEM\\CurrentControlSet\\Control\\Class\\{4d36e972-e325-11ce-bfc1-08002be10318}";
    let class_key = match sys::RegKey::open(sys::hklm(), class_path) {
        Some(k) => k,
        None => return String::new(),
    };
    for sub in class_key.subkeys() {
        if sub == "Properties" || sub.starts_with("AllUser") {
            continue;
        }
        let sub_path = format!("{}\\{}", class_path, sub);
        let sub_key = match sys::RegKey::open(sys::hklm(), &sub_path) {
            Some(k) => k,
            None => continue,
        };
        if let Some(desc) = sub_key.value("DriverDesc") {
            if desc.to_lowercase().contains(&keyword.to_lowercase()) {
                return desc;
            }
        }
    }
    String::new()
}

fn windows_version_string() -> String {
    match sys::os_ver() {
        sys::OsVer::Win9x => "Windows 9x".to_string(),
        sys::OsVer::Nt4 => "Windows NT 4.0".to_string(),
        sys::OsVer::Win2000 => "Windows 2000".to_string(),
        sys::OsVer::Xp => "Windows XP/2003".to_string(),
        sys::OsVer::Vista => "Windows Vista/2008".to_string(),
        sys::OsVer::Win7 => "Windows 7".to_string(),
        sys::OsVer::Win8 => "Windows 8/8.1/2012".to_string(),
        sys::OsVer::Win10Plus => "Windows 10/11".to_string(),
    }
}

fn timestamp_compact() -> String {
    // YYYYMMDD-HHMMSS
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let days = secs / 86400;
    let tod = secs % 86400;
    let (y, m, d) = civil_from_days(days as i64);
    format!(
        "{:04}{:02}{:02}-{:02}{:02}{:02}",
        y, m, d, tod / 3600, (tod % 3600) / 60, tod % 60
    )
}

fn random_id() -> u32 {
    // Not cryptographic; just needs to be unique enough for probe filenames.
    let mut seed = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);
    seed ^= unsafe { winapi::um::processthreadsapi::GetCurrentProcessId() as u64 };
    // Simple LCG
    seed = seed.wrapping_mul(1103515245).wrapping_add(12345);
    (seed & 0xFFFF_FFFF) as u32
}

fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = (z - era * 146097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

fn urlencode(s: &str) -> String {
    let mut out = String::with_capacity(s.len() * 2);
    for b in s.bytes() {
        match b {
            b' ' => out.push_str("%20"),
            b'\n' => out.push_str("%0A"),
            b'\r' => {} // strip CR
            b'#' => out.push_str("%23"),
            b'&' => out.push_str("%26"),
            b'=' => out.push_str("%3D"),
            b'?' => out.push_str("%3F"),
            b'[' => out.push_str("%5B"),
            b']' => out.push_str("%5D"),
            b'|' => out.push_str("%7C"),
            b':' => out.push_str("%3A"),
            b'/' => out.push_str("%2F"),
            b'%' => out.push_str("%25"),
            b'+' => out.push_str("%2B"),
            b'<' => out.push_str("%3C"),
            b'>' => out.push_str("%3E"),
            b'"' => out.push_str("%22"),
            b'\'' => out.push_str("%27"),
            b'@' => out.push_str("%40"),
            b'!' => out.push_str("%21"),
            b'(' => out.push_str("%28"),
            b')' => out.push_str("%29"),
            b',' => out.push_str("%2C"),
            b';' => out.push_str("%3B"),
            b'*' => out.push_str("%2A"),
            _ if b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'.' || b == b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}
