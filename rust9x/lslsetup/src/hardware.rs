//! PnP hardware detection without WMI (Get-PnpHardware replacement), the
//! curated out-of-tree driver table, driver staging, and the
//! linux-hardware.org LKDDb compatibility rating.
//!
//! WMI (Win32_PnPEntity) is unavailable on Win9x and fragile on stripped
//! installs, so devices are enumerated from the PnP registry instead:
//!   NT:  HKLM\SYSTEM\CurrentControlSet\Enum\{PCI,USB}\...
//!   9x:  HKLM\Enum\{PCI,USB}\...
//! The key names carry the same VEN_/DEV_ / VID_/PID_ IDs that
//! `lspci -nn` / `lsusb` would show on Linux.

use crate::sys::{hklm, out, path_exists, RegKey};
use std::time::Instant;

#[derive(Clone, Debug)]
pub struct Device {
    pub name: String,
    pub pnp_id: String,
    pub kind: &'static str, // "PCI" | "USB"
    pub class: String,
    pub vendor: String, // 4 hex upper
    pub device: String, // 4 hex upper
    pub id: String,     // "VID:DID"
}

fn parse_pci_key(seg: &str) -> Option<(String, String)> {
    // VEN_10EC&DEV_C821...
    let up = seg.to_uppercase();
    let ven = find_after(&up, "VEN_", 4)?;
    let dev = find_after(&up, "DEV_", 4)?;
    Some((ven, dev))
}

fn parse_usb_key(seg: &str) -> Option<(String, String)> {
    let up = seg.to_uppercase();
    let vid = find_after(&up, "VID_", 4)?;
    let pid = find_after(&up, "PID_", 4)?;
    Some((vid, pid))
}

fn find_after(s: &str, prefix: &str, len: usize) -> Option<String> {
    let idx = s.find(prefix)? + prefix.len();
    let rest = &s[idx..];
    if rest.len() < len {
        return None;
    }
    let take = &rest[..len];
    if take.chars().all(|c| c.is_ascii_hexdigit()) {
        Some(take.to_string())
    } else {
        None
    }
}

fn clean_device_desc(v: &str) -> String {
    // Vista+ DeviceDesc is "@oem12.inf,%desc%;Realtek ..." — take after ';'
    match v.rfind(';') {
        Some(i) => v[i + 1..].to_string(),
        None => v.to_string(),
    }
}

fn enum_bus(root_path: &str, bus: &'static str, out: &mut Vec<Device>) {
    let enum_root = match RegKey::open(hklm(), root_path) {
        Some(k) => k,
        None => return,
    };
    for id_seg in enum_root.subkeys() {
        let Some((vid, did)) = (if bus == "PCI" { parse_pci_key(&id_seg) } else { parse_usb_key(&id_seg) }) else {
            continue;
        };
        let instance_path = format!("{}\\{}", root_path, id_seg);
        let instances = match RegKey::open(hklm(), &instance_path) {
            Some(k) => k,
            None => continue,
        };
        for inst in instances.subkeys() {
            let dev_path = format!("{}\\{}", instance_path, inst);
            if let Some(dev) = RegKey::open(hklm(), &dev_path) {
                let class = dev.value("Class").unwrap_or_default();
                let name = dev
                    .value("FriendlyName")
                    .or_else(|| dev.value("DeviceDesc"))
                    .map(|v| clean_device_desc(&v))
                    .unwrap_or_default();
                let pnp_id = format!("{}\\{}\\{}", bus, id_seg, inst);
                out.push(Device {
                    name,
                    pnp_id,
                    kind: bus,
                    class: class.clone(),
                    vendor: vid.clone(),
                    device: did.clone(),
                    id: format!("{}:{}", vid, did),
                });
            }
        }
    }
}

/// A model-specific prerequisite the user must fix in the firmware setup
/// before the live USB will boot. `model` is the SMBIOS system product
/// ("Aspire 5560"); `notice` is the operator-facing text.
pub struct ModelNotice {
    pub model: &'static str,
    pub notice: &'static str,
}

/// Models with a known BIOS prerequisite that the live session cannot work
/// around. Matched case-insensitively against the SMBIOS SystemProductName /
/// BaseBoardProduct (see `machine_model`).
pub const MODEL_NOTICES: &[ModelNotice] = &[ModelNotice {
    // Acer Aspire 5560 (AMD A6/A8 "Llano" era laptop). The BIOS ships with the
    // graphics switch set to Discrete and SATA in AHCI; Linux then has no
    // working display (the Radeon HD 6520G is only driven with the switchable/
    // integrated setting) and casper cannot see the internal disk. Both are
    // BIOS-only settings - set them at the F2 setup screen before booting the
    // stick, not from Windows.
    model: "Aspire 5560",
    notice: "Acer Aspire 5560: before booting, enter the BIOS setup (press F2 \
             during POST) and set the graphics mode from Discrete to Switchable \
             (integrated graphics), and change the hard disk mode from AHCI to \
             IDE - otherwise the live session may not reach the desktop or see \
             the internal disk.",
}];

/// The notice for this machine, if its model has one. Pure (unit-tested).
pub fn model_notice_for(model: &str) -> Option<&'static ModelNotice> {
    let m = model.to_lowercase();
    MODEL_NOTICES.iter().find(|n| m.contains(&n.model.to_lowercase()))
}

/// This machine's model string from the SMBIOS registry data (SystemProductName,
/// else BaseBoardProduct), or "" when unavailable (Win9x, stripped installs).
/// Registry, not WMI: see `boot::boot_menu_key` for the same reasoning.
pub fn machine_model() -> String {
    const PATH: &str = "HARDWARE\\DESCRIPTION\\System\\BIOS";
    let Some(k) = RegKey::open(hklm(), PATH) else {
        return String::new();
    };
    for name in ["SystemProductName", "BaseBoardProduct"] {
        if let Some(v) = k.value(name) {
            let v = v.trim().trim_end_matches('\0').trim().to_string();
            // Some boards report a placeholder instead of a model name.
            if !v.is_empty()
                && !v.eq_ignore_ascii_case("to be filled by o.e.m.")
                && !v.eq_ignore_ascii_case("system product name")
                && !v.eq_ignore_ascii_case("default string")
            {
                return v;
            }
        }
    }
    String::new()
}

/// The BIOS warning for this machine as display text: empty when the model has
/// no known prerequisite, else a one-line "WARNING: ..." notice.
pub fn hardware_notice() -> String {
    match model_notice_for(&machine_model()) {
        Some(n) => format!("WARNING: {}", n.notice),
        None => String::new(),
    }
}

/// Print this machine's BIOS notice, if it has one, to the console.
///
/// Console counterpart of the GUI hardware-page label. Nothing lslsetup can do
/// fixes a firmware setting, so the user must see this BEFORE writing (or at
/// least before rebooting): a scripted --no-gui / --dry-run run must not drop
/// the one prerequisite the wizard would have shown. Prints nothing on machines
/// without a notice.
pub fn print_notice() {
    let text = hardware_notice();
    if text.is_empty() {
        return;
    }
    let mut lines = text.lines();
    if let Some(first) = lines.next() {
        out::warn(first);
    }
    for l in lines {
        out::info(l);
    }
}

/// All PCI+USB devices. Primary source: SetupAPI (`SetupDiGetClassDevs` with
/// the PCI/USB enumerators) — the proper PnP API, available since 95 OSR2/
/// NT4, no WMI required, loaded dynamically so the static import surface
/// stays 9x-safe. Fallback: direct PnP-registry enumeration.
pub fn pnp_hardware() -> Vec<Device> {
    let mut out = setupapi_pnp();
    if out.is_empty() {
        registry_pnp(&mut out);
    }
    out.sort_by(|a, b| a.class.cmp(&b.class).then(a.name.cmp(&b.name)));
    out
}

#[repr(C)]
struct SpDevinfoData {
    cb_size: u32,
    class_guid: [u8; 16],
    dev_inst: u32,
    reserved: usize,
}

const DIGCF_PRESENT: u32 = 0x2;
const DIGCF_ALLCLASSES: u32 = 0x4;
const SPDRP_DEVICEDESC: u32 = 0x0;
const SPDRP_HARDWAREID: u32 = 0x1;
const SPDRP_CLASS: u32 = 0x7; // (8 is SPDRP_CLASSGUID!)
const SPDRP_FRIENDLYNAME: u32 = 0xC;

fn setupapi_pnp() -> Vec<Device> {
    let Some(lib) = crate::sys::DynLib::load("setupapi.dll") else {
        return Vec::new();
    };
    type GetClassDevs =
        unsafe extern "system" fn(*const u16, *const u16, *mut winapi::ctypes::c_void, u32) -> *mut winapi::ctypes::c_void;
    type EnumDeviceInfo =
        unsafe extern "system" fn(*mut winapi::ctypes::c_void, u32, *mut SpDevinfoData) -> i32;
    type GetDevProp = unsafe extern "system" fn(
        *mut winapi::ctypes::c_void,
        *mut SpDevinfoData,
        u32,
        *mut u32,
        *mut u8,
        u32,
        *mut u32,
    ) -> i32;
    type DestroyList = unsafe extern "system" fn(*mut winapi::ctypes::c_void) -> i32;
    let (Some(get_class_devs), Some(enum_dev_info), Some(get_prop), Some(destroy_list)) = (
        lib.proc("SetupDiGetClassDevsW").map(|p| unsafe { std::mem::transmute_copy::<*const (), GetClassDevs>(&p) }),
        lib.proc("SetupDiEnumDeviceInfo").map(|p| unsafe { std::mem::transmute_copy::<*const (), EnumDeviceInfo>(&p) }),
        lib.proc("SetupDiGetDeviceRegistryPropertyW").map(|p| unsafe { std::mem::transmute_copy::<*const (), GetDevProp>(&p) }),
        lib.proc("SetupDiDestroyDeviceInfoList").map(|p| unsafe { std::mem::transmute_copy::<*const (), DestroyList>(&p) }),
    ) else {
        return Vec::new();
    };

    unsafe {
        let mut out: Vec<Device> = Vec::new();
        for (enumerator, kind) in [("PCI", "PCI"), ("USB", "USB")] {
            let wenum = crate::sys::wide(enumerator);
            let h = get_class_devs(
                std::ptr::null(),
                wenum.as_ptr(),
                std::ptr::null_mut(),
                DIGCF_PRESENT | DIGCF_ALLCLASSES,
            );
            if h.is_null() {
                continue;
            }
            let mut index: u32 = 0;
            loop {
                let mut did: SpDevinfoData = std::mem::zeroed();
                did.cb_size = std::mem::size_of::<SpDevinfoData>() as u32;
                if enum_dev_info(h, index, &mut did) == 0 {
                    break;
                }
                index += 1;

                let mut prop = |code: u32| -> String {
                    let mut buf = [0u8; 2048];
                    let mut size: u32 = buf.len() as u32;
                    if get_prop(h, &mut did, code, std::ptr::null_mut(), buf.as_mut_ptr(), size, &mut size)
                        == 0
                    {
                        return String::new();
                    }
                    // REG_SZ / REG_MULTI_SZ: UTF-16, take the first string
                    let w: Vec<u16> = buf
                        .chunks_exact(2)
                        .take(size as usize / 2)
                        .take_while(|c| c[0] != 0 || c[1] != 0)
                        .map(|c| u16::from_le_bytes([c[0], c[1]]))
                        .collect();
                    crate::sys::from_wide(&w)
                };

                let hw_id = prop(SPDRP_HARDWAREID);
                let (vid, did_id) = match kind {
                    "PCI" => parse_pci_key(&hw_id).unwrap_or_default(),
                    _ => parse_usb_key(&hw_id).unwrap_or_default(),
                };
                if vid.is_empty() {
                    continue;
                }
                let vid2 = vid.clone();
                let did2 = did_id.clone();
                let class = prop(SPDRP_CLASS);
                let name = {
                    let f = prop(SPDRP_FRIENDLYNAME);
                    if f.is_empty() {
                        clean_device_desc(&prop(SPDRP_DEVICEDESC))
                    } else {
                        clean_device_desc(&f)
                    }
                };
                out.push(Device {
                    name,
                    pnp_id: hw_id.clone(),
                    kind,
                    class,
                    vendor: vid2,
                    device: did2,
                    id: format!("{}:{}", vid, did_id),
                });
            }
            destroy_list(h);
        }
        out
    }
}

/// Fallback: direct registry enumeration (what WMI's Win32_PnPEntity reads
/// behind the scenes). Handles both NT (SYSTEM\CurrentControlSet\Enum) and
/// Win9x (Enum) layouts.
fn registry_pnp(out: &mut Vec<Device>) {
    for base in ["SYSTEM\\CurrentControlSet\\Enum", "Enum"] {
        let before = out.len();
        enum_bus(&format!("{}\\PCI", base), "PCI", &mut *out);
        enum_bus(&format!("{}\\USB", base), "USB", &mut *out);
        if out.len() > before {
            break; // first root that yields devices wins
        }
    }
    out.sort_by(|a, b| a.class.cmp(&b.class).then(a.name.cmp(&b.name)));
}

/// Get-NetworkHardware: Class == 'Net' devices only.
pub fn network_hardware() -> Vec<Device> {
    pnp_hardware().into_iter().filter(|d| d.class.eq_ignore_ascii_case("Net")).collect()
}

/// Get-CompatHardware: the classes worth rating against LKDDb.
const RATE_CLASSES: &[&str] = &[
    "Net", "Display", "MEDIA", "Bluetooth", "Biometric", "Image",
    "SmartCardReader", "HDC", "SCSIAdapter", "Modem", "PCMCIA", "Camera",
    "61883",
];

pub fn compat_hardware() -> Vec<Device> {
    pnp_hardware()
        .into_iter()
        .filter(|d| RATE_CLASSES.iter().any(|c| c.eq_ignore_ascii_case(&d.class)))
        .collect()
}

// ---------------------------------------------------------------------------
// Curated out-of-tree driver table (verbatim from install.ps1 Get-DriverTable)
// ---------------------------------------------------------------------------
pub struct DriverEntry {
    pub id: &'static str,
    pub chip: &'static str,
    pub pkg: &'static str,
    pub source: &'static str, // "ubuntu" | "github"
    pub suite: &'static str,
    pub component: &'static str,
    pub repo: &'static str,
    pub branch: &'static str,
    // per-entry documentation (why the override exists); not read by code.
    #[allow(dead_code)]
    pub note: &'static str,
}

pub fn driver_table() -> &'static [DriverEntry] {
    &[
        DriverEntry { id: "0BDA:8812", chip: "Realtek RTL8812AU", pkg: "rtl8812au-dkms", source: "ubuntu", suite: "noble-updates", component: "universe", repo: "", branch: "", note: "in-kernel only since 6.14" },
        DriverEntry { id: "0BDA:881A", chip: "Realtek RTL8814AU", pkg: "rtl8814au", source: "github", suite: "", component: "", repo: "morrownr/8814au", branch: "main", note: "in-kernel only since 6.14" },
        DriverEntry { id: "0BDA:8179", chip: "Realtek RTL8188EU", pkg: "rtl8188eu", source: "github", suite: "", component: "", repo: "lwfinger/rtl8188eu", branch: "master", note: "kernel has only a staging driver" },
        DriverEntry { id: "0BDA:B720", chip: "Realtek RTL8723BU", pkg: "rtl8723bu", source: "github", suite: "", component: "", repo: "lwfinger/rtl8723bu", branch: "master", note: "LKDDb entry is the bluetooth function only" },
        DriverEntry { id: "14E4:4365", chip: "Broadcom BCM43142", pkg: "broadcom-sta-dkms", source: "ubuntu", suite: "noble-updates", component: "restricted", repo: "", branch: "", note: "wl driver; LKDDb entry is the bcma bus bridge only" },
        DriverEntry { id: "14E4:43A0", chip: "Broadcom BCM4360", pkg: "broadcom-sta-dkms", source: "ubuntu", suite: "noble-updates", component: "restricted", repo: "", branch: "", note: "wl driver; LKDDb entry is the bcma bus bridge only" },
        DriverEntry { id: "14E4:43B1", chip: "Broadcom BCM4352", pkg: "broadcom-sta-dkms", source: "ubuntu", suite: "noble-updates", component: "restricted", repo: "", branch: "", note: "wl driver; LKDDb entry is the bcma bus bridge only" },
        DriverEntry { id: "14E4:4727", chip: "Broadcom BCM4313", pkg: "broadcom-sta-dkms", source: "ubuntu", suite: "noble-updates", component: "restricted", repo: "", branch: "", note: "wl driver; LKDDb entry is the bcma bus bridge only" },
    ]
}

pub fn resolve_driver_needs(hw: &[Device]) -> Vec<(Device, &'static DriverEntry)> {
    let mut out = Vec::new();
    for h in hw {
        if let Some(t) = driver_table().iter().find(|t| t.id == h.id) {
            out.push((h.clone(), t));
        }
    }
    out
}

/// Get-UbuntuPackageUrl: resolve the exact .deb URL by parsing the archive's
/// Packages index (cached in %TEMP%).
///
/// The mirror is resolved from `suite` rather than hardcoded. The driver
/// table pins every entry to `noble`, so in practice this always lands on the
/// Ubuntu archive - but the two share a cache key namespace with the f2fs
/// tool fetcher, and a key that omits the mirror host silently serves one
/// distro's index for another's. `apt_cache_name` puts the host in the key.
fn ubuntu_package_url(pkg: &str, suite: &str, component: &str) -> Option<String> {
    let mirror = crate::f2fstools::mirror_for_suite(suite)?;
    let arch = crate::f2fstools::apt_arch_for(None);
    let cache = format!(
        "{}\\{}",
        crate::sys::temp_dir(),
        crate::f2fstools::apt_cache_name(&mirror, suite, component, arch)
    );
    if !path_exists(&cache) {
        let url = format!(
            "{}/dists/{}/{}/binary-{}/Packages.gz",
            mirror.root, suite, component, arch
        );
        let dest = cache.clone();
        let r = crate::net::download_to_file(&url, &dest, crate::net::user_agent(), &mut |_| {});
        if r.is_err() {
            return None;
        }
    }
    let f = std::fs::File::open(&cache).ok()?;
    let gz = flate2::read::GzDecoder::new(f);
    let reader = std::io::BufReader::new(gz);
    use std::io::BufRead;
    let mut in_block = false;
    for line in reader.lines().flatten() {
        if line == format!("Package: {}", pkg) {
            in_block = true;
            continue;
        }
        if in_block {
            if let Some(fn_part) = line.strip_prefix("Filename: ") {
                return Some(format!("{}/{}", mirror.root, fn_part.trim()));
            }
            if line.is_empty() {
                in_block = false;
            }
        }
    }
    None
}

fn driver_download_url(entry: &DriverEntry) -> Option<(String, String)> {
    if entry.source == "ubuntu" {
        let url = ubuntu_package_url(entry.pkg, entry.suite, entry.component)?;
        let fname = url.rsplit('/').next()?.to_string();
        return Some((url, fname));
    }
    Some((
        format!(
            "https://github.com/{}/archive/refs/heads/{}.tar.gz",
            entry.repo, entry.branch
        ),
        format!("{}.tar.gz", entry.pkg),
    ))
}

/// Install-DriverPackages: stage driver source to <USB>:\drivers\ and write
/// lsl-drivers.txt. Returns the report lines.
pub fn install_driver_packages(vol_letter: &str, skip_download: bool) -> Vec<String> {
    let root = format!("{}:\\", vol_letter);
    let drv_dir = format!("{}drivers", root);
    let mut report = Vec::new();
    let hw = network_hardware();
    if hw.is_empty() {
        report.push("No network hardware detected (registry PnP unavailable?) - nothing staged.".into());
        let _ = std::fs::write(format!("{}lsl-drivers.txt", root), report.join("\r\n"));
        return report;
    }
    let needs = resolve_driver_needs(&hw);
    if needs.is_empty() {
        report.push("No known problem chipsets detected - the ISO kernel should cover this machine.".into());
        let _ = std::fs::write(format!("{}lsl-drivers.txt", root), report.join("\r\n"));
        return report;
    }
    crate::sys::create_dir_all(&drv_dir);
    for (h, t) in &needs {
        let Some((url, fname)) = driver_download_url(t) else {
            report.push(format!("SKIP  {} ({}): could not resolve download URL", t.chip, h.id));
            continue;
        };
        let dest = format!("{}\\{}", drv_dir, fname);
        if skip_download {
            report.push(format!("STAGE {} ({}): {} (download skipped)", t.chip, h.id, fname));
            continue;
        }
        match crate::net::download_to_file(&url, &dest, crate::net::user_agent(), &mut |_| {}) {
            Ok(n) if n > 0 => {
                report.push(format!(
                    "STAGE {} ({}): {} ({:.1} MB)",
                    t.chip,
                    h.id,
                    fname,
                    n as f64 / crate::sys::MB as f64
                ));
            }
            Ok(_) => {
                crate::sys::delete_file(&dest);
                report.push(format!("FAIL  {} ({}): empty download", t.chip, h.id));
            }
            Err(e) => {
                crate::sys::delete_file(&dest);
                report.push(format!("FAIL  {} ({}): {}", t.chip, h.id, e));
            }
        }
    }
    let _ = std::fs::write(format!("{}lsl-drivers.txt", root), report.join("\r\n"));
    report
}

// ---------------------------------------------------------------------------
// Staged tooling packages (<USB>:\pkgs) - offline boot-critical .debs.
//
// WHY THIS EXISTS (WHYFAIL9 / WHYFAIL10)
// --------------------------------------
// mount_all.sh maps Windows drive letters by reading the MountedDevices
// registry key with hivexget/hivexregedit. Those tools are NOT in the live
// image, and on a stock first boot the same firstboot run installs them only
// ~23 minutes AFTER /home has already been mounted. Without them mount_all.sh
// cannot map /mnt/c, the data dir is not persistent, and /home falls back to a
// transient tmpfs overlay - so that boot's home is lost. The Linux side
// (lsl_ensure_hivex_tools) installs the .debs staged HERE, BEFORE /home
// mounts, which removes the trigger with no network.
//
// The three packages are self-contained against the 24.04 base image: their
// only deps are libc6, libreadline8t64, libxml2 and perl, all present.
// ---------------------------------------------------------------------------

/// hivex packages to stage, in install order (libhivex0 before its dependants).
/// (package, suite, component) - all in noble/universe.
const STAGED_PKGS: &[(&str, &str, &str)] = &[
    ("libhivex0", "noble", "universe"),
    ("libhivex-bin", "noble", "universe"),
    ("libwin-hivex-perl", "noble", "universe"),
];

/// Install-StagedPackages: download the boot-critical tooling .debs to
/// <USB>:\pkgs\ and write lsl-pkgs.txt. Returns the report lines.
///
/// Best-effort: a package that cannot be resolved or downloaded is reported and
/// skipped, never fatal - the stick still boots, it just loses the offline
/// hivex path (and therefore /home persistence on a drive-letter-mapped boot).
pub fn install_staged_packages(vol_letter: &str, skip_download: bool) -> Vec<String> {
    let root = format!("{}:\\", vol_letter);
    let pkg_dir = format!("{}pkgs", root);
    let mut report = Vec::new();
    let mut staged = 0usize;

    for (pkg, suite, component) in STAGED_PKGS {
        let Some(url) = ubuntu_package_url(pkg, suite, component) else {
            report.push(format!(
                "SKIP  {}: could not resolve a download URL (no network / index unavailable)",
                pkg
            ));
            continue;
        };
        let fname = url.rsplit('/').next().unwrap_or(pkg).to_string();
        if skip_download {
            report.push(format!("STAGE {}: {} (download skipped)", pkg, fname));
            continue;
        }
        crate::sys::create_dir_all(&pkg_dir);
        let dest = format!("{}\\{}", pkg_dir, fname);
        match crate::net::download_to_file(&url, &dest, crate::net::user_agent(), &mut |_| {}) {
            Ok(n) if n > 0 => {
                report.push(format!(
                    "STAGE {}: {} ({:.1} KB)",
                    pkg,
                    fname,
                    n as f64 / 1024.0
                ));
                staged += 1;
            }
            Ok(_) => {
                crate::sys::delete_file(&dest);
                report.push(format!("FAIL  {}: empty download", pkg));
            }
            Err(e) => {
                crate::sys::delete_file(&dest);
                report.push(format!("FAIL  {}: {}", pkg, e));
            }
        }
    }

    if staged == 0 {
        report.push(
            "WARNING: no hivex packages staged - a boot whose Windows drives need \
             drive-letter mapping will fall back to a transient /home."
                .into(),
        );
    } else {
        report.push(format!(
            "Staged {} hivex package(s) to {} - the Linux side installs them before /home mounts.",
            staged, pkg_dir
        ));
    }
    let _ = std::fs::write(format!("{}lsl-pkgs.txt", root), report.join("\r\n"));
    report
}

// ---------------------------------------------------------------------------
// linux-hardware.org LKDDb rating (Get-LinuxCompatRating).
// ---------------------------------------------------------------------------

// Compiled-in copy of the lsl-hw-cache snapshot (see build.rs): the raw
// device pages, gzipped as one blob and inflated once on first lookup, so
// common hardware rates instantly with no network request and no sidecar
// files beside the exe. flate2's decoder is already linked for Packages.gz.
// Parsed at runtime with parse_lhw_html - the SAME parser as the on-disk
// cache - so embedded and sidecar ratings can never drift apart.
include!(concat!(env!("OUT_DIR"), "/hw_cache_embedded.rs"));

struct HwCacheEntry {
    id: String,
    html: String,
}

static HW_CACHE: std::sync::OnceLock<Vec<HwCacheEntry>> = std::sync::OnceLock::new();

fn hw_cache() -> &'static [HwCacheEntry] {
    HW_CACHE.get_or_init(|| {
        let mut dec = flate2::read::GzDecoder::new(COMPRESSED_HW_CACHE);
        let mut raw: Vec<u8> = Vec::new();
        use std::io::Read;
        if dec.read_to_end(&mut raw).is_err() {
            return Vec::new(); // build-verified; on failure callers fall through to disk/network
        }
        // Raw concatenated pages, each prefixed by its id and byte length:
        //   <id>\n<len>\n<page bytes>
        // Rejects a truncated blob instead of rating from half a page.
        let mut out = Vec::with_capacity(HW_CACHE_ENTRIES);
        let mut p = &raw[..];
        while !p.is_empty() {
            let nl = match p.iter().position(|&b| b == b'\n') {
                Some(i) => i,
                None => break,
            };
            let id = match std::str::from_utf8(&p[..nl]) {
                Ok(s) => s,
                Err(_) => break,
            };
            p = &p[nl + 1..];
            let nl2 = match p.iter().position(|&b| b == b'\n') {
                Some(i) => i,
                None => break,
            };
            let len: usize = match std::str::from_utf8(&p[..nl2]).ok().and_then(|s| s.parse().ok()) {
                Some(n) => n,
                None => break,
            };
            p = &p[nl2 + 1..];
            if p.len() < len {
                break; // truncated entry: stop, keep nothing partial
            }
            let html = match std::str::from_utf8(&p[..len]) {
                Ok(s) => s,
                Err(_) => {
                    p = &p[len..];
                    continue; // non-UTF8 page: skip, keep parsing the rest
                }
            };
            out.push(HwCacheEntry {
                id: id.to_string(),
                html: html.to_string(),
            });
            p = &p[len..];
        }
        out
    })
}

fn embedded_lookup(id: &str) -> Option<String> {
    for e in hw_cache().iter() {
        if e.id == id {
            return Some(e.html.clone());
        }
    }
    None
}

// robots.txt Crawl-delay politeness state.
const LHW_DELAY_SECS: u64 = 10;

/// Default linux-hardware.org base URL.
pub const LHW_BASE_URL_DEFAULT: &str = "https://linux-hardware.org/";

/// Base URL for LKDDb device pages, overridable with the `LSL_LHW_BASE_URL`
/// environment variable.
///
/// Upstream rate-limits hard (HTTP 429 after a few rapid requests) and its
/// robots.txt asks for a 10 s Crawl-delay, which makes both the bundled cache
/// build and the live rating fragile. A mirror of the device pages fixes that,
/// and the only code change a mirror needs is this URL - the cache file format
/// (`lsl-lhw-<type>-<vid>-<did>.html`) and the parser are unchanged, so a
/// mirrored cache drops straight in.
///
/// The override changes WHERE pages are fetched from, not how politely: the
/// crawl-delay above still applies.
pub fn lhw_base_url() -> String {
    let b = crate::sys::env_var("LSL_LHW_BASE_URL")
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| LHW_BASE_URL_DEFAULT.to_string());
    if b.ends_with('/') {
        b
    } else {
        format!("{}/", b)
    }
}

struct LhwState {
    last: Option<Instant>,
}
static LHW: std::sync::Mutex<LhwState> = std::sync::Mutex::new(LhwState { last: None });

fn lhw_cache_file(id: &str) -> String {
    let fname = format!("lsl-lhw-{}.html", id.replace(':', "-"));
    format!("{}\\lsl-usb\\lsl-hw-cache\\{}", crate::sys::local_app_data(), fname)
}

fn bundle_cache_file(bundle_dir: &str, id: &str) -> String {
    let fname = format!("lsl-lhw-{}.html", id.replace(':', "-"));
    format!("{}\\lsl-hw-cache\\{}", bundle_dir, fname)
}

fn lhw_fetch_page(id: &str, bundle_dir: &str) -> String {
    let user_cache = lhw_cache_file(id);
    if let Ok(s) = std::fs::read_to_string(&user_cache) {
        return s;
    }
    if !bundle_dir.is_empty() {
        let bc = bundle_cache_file(bundle_dir, id);
        if let Ok(s) = std::fs::read_to_string(&bc) {
            return s;
        }
    }
    // Politeness: robots.txt Crawl-delay 10s between live requests.
    {
        let st = LHW.lock().unwrap();
        if let Some(t) = st.last {
            let elapsed = t.elapsed().as_secs();
            if elapsed < LHW_DELAY_SECS {
                std::thread::sleep(std::time::Duration::from_secs(LHW_DELAY_SECS - elapsed));
            }
        }
    }
    let url = format!("{}?id={}", lhw_base_url(), id);
    let html = match crate::net::get(&url, "lsl-usb/1.0") {
        Ok(r) if r.status == 200 => String::from_utf8_lossy(&r.body).into_owned(),
        _ => {
            LHW.lock().unwrap().last = Some(Instant::now());
            return String::new(); // failures are not cached, later runs retry
        }
    };
    LHW.lock().unwrap().last = Some(Instant::now());
    let path = lhw_cache_file(id);
    crate::sys::create_dir_all(&format!("{}\\lsl-usb\\lsl-hw-cache", crate::sys::local_app_data()));
    let _ = std::fs::write(&path, &html);
    html
}

fn find_between<'a>(s: &'a str, start: &str, end: &str) -> Option<&'a str> {
    let i = s.find(start)? + start.len();
    let rest = &s[i..];
    let j = rest.find(end)?;
    Some(&rest[..j])
}

/// Extract (name, kernel support, driver source, third-party repos) from a
/// linux-hardware.org device page. Mirrors the build.rs summary parser.
fn parse_lhw_html(html: &str) -> (String, String, String, Vec<String>) {
    let mut name = String::new();
    let mut ksup = String::new();
    let mut src = String::new();
    let mut third: Vec<String> = Vec::new();
    if let Some(n) = find_between(html, "<h2 class='top'>Device '", "'") {
        name = n.to_string();
    }
    if let Some(k) = find_between(html, "supported by kernel versions <a", "</a>") {
        let k = match k.find('>') {
            Some(i) => &k[i + 1..],
            None => k,
        };
        ksup = k.to_string();
    }
    if let Some(seg) = find_between(html, "&nbsp;-&nbsp;</td>", "</td><td>") {
        src = seg.to_string();
    } else if let Some(seg) = find_between(html, "<td>", "</td>") {
        if seg.chars().next().map(|c| c.is_ascii_digit()).unwrap_or(false) {
            src = seg.to_string();
        }
    }
    let mut from = 0;
    while let Some(rel) = html[from..].find("<a href=\"https://github.com/") {
        let start = from + rel + "<a href=\"https://github.com/".len();
        let rest = &html[start..];
        if let Some(q) = rest.find('"') {
            third.push(rest[..q].to_string());
            from = start + q;
        } else {
            break;
        }
    }
    (name, ksup, src, third)
}

#[derive(Debug, Clone)]
pub struct Rating {
    pub rating: char, // A / C / D / U
    pub name: String,
    pub reason: String,
}

pub fn lhw_url(d: &Device) -> String {
    format!(
        "{}?id={}:{}-{}",
        lhw_base_url(),
        d.kind.to_lowercase(),
        d.vendor.to_lowercase(),
        d.device.to_lowercase()
    )
}

/// Page URL for a raw device id (`pci:8086-1234`), honouring the base-URL
/// override. The GUI builds its "link" column from ids rather than from
/// `Device`, so it needs this too.
pub fn lhw_id_url(id: &str) -> String {
    format!("{}?id={}", lhw_base_url(), id)
}

/// Fast path: curated table + embedded cache + on-disk cache, NO network.
/// Returns Some(Rating) if any cache hit, None if a live fetch is needed.
pub fn linux_compat_rating_cached(d: &Device, bundle_dir: &str, iso_kernel: (u32, u32)) -> Option<Rating> {
    // Curated-table override first
    if let Some(t) = driver_table().iter().find(|t| t.id == d.id) {
        return Some(Rating {
            rating: 'C',
            name: d.name.clone(),
            reason: format!("needs out-of-tree driver ({}) - staged to <USB>:\\drivers\\", t.pkg),
        });
    }
    let id = format!(
        "{}:{}-{}",
        d.kind.to_lowercase(),
        d.vendor.to_lowercase(),
        d.device.to_lowercase()
    );
    // Compiled-in snapshot (raw pages, same parser as the on-disk cache)
    if let Some(html) = embedded_lookup(&id) {
        let (name, ksup, src, third) = parse_lhw_html(&html);
        let name = if name.is_empty() { d.name.clone() } else { name };
        return Some(rating_from_lkddb(name, ksup, src, third, iso_kernel));
    }
    // On-disk caches (user + bundle)
    let user_cache = lhw_cache_file(&id);
    if let Ok(html) = std::fs::read_to_string(&user_cache) {
        if !html.is_empty() {
            let (name, ksup, src, third) = parse_lhw_html(&html);
            let name = if name.is_empty() { d.name.clone() } else { name };
            return Some(rating_from_lkddb(name, ksup, src, third, iso_kernel));
        }
    }
    if !bundle_dir.is_empty() {
        let bc = bundle_cache_file(bundle_dir, &id);
        if let Ok(html) = std::fs::read_to_string(&bc) {
            if !html.is_empty() {
                let (name, ksup, src, third) = parse_lhw_html(&html);
                let name = if name.is_empty() { d.name.clone() } else { name };
                return Some(rating_from_lkddb(name, ksup, src, third, iso_kernel));
            }
        }
    }
    None
}

pub fn linux_compat_rating(d: &Device, bundle_dir: &str, iso_kernel: (u32, u32)) -> Rating {
    let id = format!(
        "{}:{}-{}",
        d.kind.to_lowercase(),
        d.vendor.to_lowercase(),
        d.device.to_lowercase()
    );
    // Curated-table override first: known-problem chips are 'C' before any
    // cache/network rating is even consulted (matches install.ps1). This
    // also means a known chip never triggers a slow, rate-limited fetch.
    if let Some(t) = driver_table().iter().find(|t| t.id == d.id) {
        return Rating {
            rating: 'C',
            name: d.name.clone(),
            reason: format!("needs out-of-tree driver ({}) - staged to <USB>:\\drivers\\", t.pkg),
        };
    }
    // Compiled-in snapshot FIRST (../..lsl-hw-cache → build.rs → raw pages):
    // common hardware rates instantly with no network request at all. Before
    // this, only a lossy summary was embedded — and a live linux-hardware.org
    // fetch carried a 10-second robots crawl-delay per device, which is why
    // a fresh (deployed) machine crept through the rating. Devices in the
    // snapshot never touch the network now.
    if let Some(html) = embedded_lookup(&id) {
        let (e_name, ksup, src, third) = parse_lhw_html(&html);
        let name = if e_name.is_empty() { d.name.clone() } else { e_name };
        return rating_from_lkddb(name, ksup, src, third, iso_kernel);
    }
    // Not in the snapshot: on-disk caches (user + bundle), then ONE polite
    // live fetch (10s crawl-delay). Unlisted devices alone pay that cost.
    let html = lhw_fetch_page(&id, bundle_dir);
    if html.is_empty() {
        return Rating {
            rating: 'U',
            name: d.name.clone(),
            reason: "no data (linux-hardware.org unreachable/rate-limited/TLS too old)".into(),
        };
    }
    let (name, ksup, src, third) = parse_lhw_html(&html);
    let name = if name.is_empty() { d.name.clone() } else { name };
    rating_from_lkddb(name, ksup, src, third, iso_kernel)
}

/// Turn an LKDDb summary (device name, "X and newer" kernel-support string,
/// driver source, out-of-tree repos) into an A/C/D/U Rating against the ISO
/// kernel. Shared by the compiled-in snapshot and the live/fetch path so
/// both rate identically.
fn rating_from_lkddb(
    name: String,
    ksup: String,
    src: String,
    third: Vec<String>,
    iso_kernel: (u32, u32),
) -> Rating {
    if ksup.is_empty() {
        let extra = if !third.is_empty() {
            format!(" - out-of-tree options: {}", third.join(", "))
        } else {
            String::new()
        };
        return Rating {
            rating: 'U',
            name,
            reason: format!("no LKDDb entry{}", extra),
        };
    }
    // Parse the minimum kernel from '5.9 and newer' or '4.17 - 6.1'.
    let mut min_major = 0u32;
    let mut min_minor = 0u32;
    let mut collecting = false;
    let mut num = String::new();
    for c in ksup.chars().chain(std::iter::once(' ')) {
        if c.is_ascii_digit() || c == '.' {
            num.push(c);
            collecting = true;
        } else if collecting {
            break;
        }
    }
    let _ = collecting;
    let mut it = num.split('.');
    if let Some(m) = it.next() {
        min_major = m.parse().unwrap_or(0);
    }
    if let Some(m) = it.next() {
        min_minor = m.parse().unwrap_or(0);
    }
    let in_kernel =
        min_major < iso_kernel.0 || (min_major == iso_kernel.0 && min_minor <= iso_kernel.1);
    // A bus-bridge / bluetooth entry is not a real driver for this function.
    let bridge_only = ["bcma", "bluetty", "usb/class", "host_pci", "pci-bridge"]
        .iter()
        .any(|p| src.contains(p));
    if in_kernel && !bridge_only {
        return Rating {
            rating: 'A',
            name,
            reason: format!("in-kernel since {} ({}) - no action needed", ksup, src),
        };
    }
    if in_kernel && bridge_only {
        return Rating {
            rating: 'D',
            name,
            reason: format!("LKDDb entry is only {} - no real driver for this function", src),
        };
    }
    let extra = if !third.is_empty() {
        format!(" - out-of-tree options: {}", third.join(", "))
    } else {
        String::new()
    };
    Rating {
        rating: 'C',
        name,
        reason: format!(
            "needs kernel {}+ (ISO has {}.{}){}",
            ksup, iso_kernel.0, iso_kernel.1, extra
        ),
    }
}

pub fn hardware_compat_report(devices: &[Device], bundle_dir: &str) -> Vec<String> {
    let mut lines = Vec::new();
    for d in devices {
        let r = linux_compat_rating(d, bundle_dir, (6, 8));
        lines.push(format!("[{}] {}  ({})  - {}", r.rating, r.name, d.id, r.reason));
    }
    lines
}

// ---------------------------------------------------------------------------
// Flatpak suggestions (Get-FlatpakSuggestions)
// ---------------------------------------------------------------------------
pub const FLATPAK_MAP: &[(&str, &str)] = &[
    ("Slack", "com.slack.Slack"),
    ("Discord", "com.discordapp.Discord"),
    ("Spotify", "com.spotify.Client"),
    ("Visual Studio Code", "com.visualstudio.code"),
    ("Telegram", "org.telegram.desktop"),
    ("Zoom", "us.zoom.Zoom"),
    ("Obsidian", "md.obsidian.Obsidian"),
    ("GIMP", "org.gimp.GIMP"),
    ("Inkscape", "org.inkscape.Inkscape"),
    ("Blender", "org.blender.Blender"),
    ("OBS", "com.obsproject.Studio"),
    ("Steam", "com.valvesoftware.Steam"),
    ("VLC", "org.videolan.VLC"),
    ("Firefox", "org.mozilla.firefox"),
    ("Docker", "com.docker.Desktop"),
    ("VirtualBox", "org.virtualbox.VirtualBox"),
];

pub fn flatpak_suggestions() -> Vec<(String, String, bool)> {
    let installed = crate::detect::installed_app_names();
    let ilc: Vec<String> = installed.iter().map(|s| s.to_lowercase()).collect();
    FLATPAK_MAP
        .iter()
        .map(|(m, id)| {
            let matched = ilc.iter().any(|s| s.contains(&m.to_lowercase()));
            (m.to_string(), id.to_string(), matched)
        })
        .collect()
}

// ---------------------------------------------------------------------------
// Snap suggestions (Get-SnapSuggestions)
//
// Same shape as FLATPAK_MAP on purpose, so the wizard page can render both
// grids from one loop. Only snaps that actually exist in the Snap Store are
// listed - unlike flatpak there is no free-text escape hatch here, because
// `snap install` will just fail on a name the store has never heard of.
//
// The snap NAME is what lands in snaps.txt; nothing is downloaded on the
// Windows side (see DESIGN-SNAP-PERSISTENCE.md and bin/lsl-snap-fat.sh).
// ---------------------------------------------------------------------------
pub const SNAP_MAP: &[(&str, &str)] = &[
    ("Slack", "slack"),
    ("Discord", "discord"),
    ("Spotify", "spotify"),
    ("Visual Studio Code", "code"),
    ("Telegram", "telegram-desktop"),
    ("Zoom", "zoom-client"),
    ("Obsidian", "obsidian"),
    ("GIMP", "gimp"),
    ("Inkscape", "inkscape"),
    ("Blender", "blender"),
    ("OBS", "obs-studio"),
    ("VLC", "vlc"),
    ("Steam", "steam"),
];

pub fn snap_suggestions() -> Vec<(String, String, bool)> {
    let installed = crate::detect::installed_app_names();
    let ilc: Vec<String> = installed.iter().map(|s| s.to_lowercase()).collect();
    SNAP_MAP
        .iter()
        .map(|(m, name)| {
            let matched = ilc.iter().any(|s| s.contains(&m.to_lowercase()));
            (m.to_string(), name.to_string(), matched)
        })
        .collect()
}

#[allow(unused)]
fn unused_out() {
    out::plain("");
    path_exists("");
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dev(kind: &'static str, vendor: &str, device: &str) -> Device {
        Device {
            name: format!("{}-{}", kind, device),
            pnp_id: format!("{}VEN_{}&DEV_{}", kind, vendor, device),
            kind,
            class: "Net".into(),
            vendor: vendor.to_string(),
            device: device.to_string(),
            id: format!("{}:{}", vendor, device),
        }
    }

    // Common hardware in the compiled-in snapshot must rate INSTANTLY (the
    // embedded cache is hit first, so no linux-hardware.org fetch / 10s
    // crawl-delay is ever incurred). This is the "make sure cache is
    // compiled into exe" fix for the slow deployed-machine fetch.
    #[test]
    fn embedded_cache_rates_known_hardware_without_network() {
        // pci:8086-3ea0 = Intel WhiskeyLake-U GT2 [UHD Graphics 620],
        // "4.16 and newer", present in the embedded lsl-hw-cache blob.
        let d = dev("pci", "8086", "3ea0");
        let r = linux_compat_rating(&d, "", (6, 8));
        assert_eq!(r.rating, 'A', "{}: {}", r.rating, r.reason);
        assert!(
            r.name.contains("UHD Graphics"),
            "should use the embedded device name, got: {}",
            r.name
        );
        assert!(
            !r.reason.contains("unreachable"),
            "embedded path must not report a missing network",
        );
    }

    // Devices in the curated driver table are always 'C', regardless of
    // cache/network data.
    #[test]
    fn driver_table_override_wins() {
        // 0BDA:8179 = Realtek RTL8188EU (in driver_table).
        let d = dev("usb", "0BDA", "8179");
        let r = linux_compat_rating(&d, "", (6, 8));
        assert_eq!(r.rating, 'C', "{}: {}", r.rating, r.reason);
        assert!(r.reason.contains("rtl8188eu"), "{}", r.reason);
    }

    #[test]
    fn rating_parser_handles_in_kernel_since() {
        // "4.16 and newer" vs ISO kernel 6.8 -> in-kernel -> A.
        let r = rating_from_lkddb("x".into(), "4.16 and newer".into(), "driver".into(), vec![], (6, 8));
        assert_eq!(r.rating, 'A', "{}: {}", r.rating, r.reason);
    }

    #[test]
    fn rating_parser_reports_bridge_only_as_d() {
        // A bcma/bridge-only src is not a real driver, even if "old enough".
        let r = rating_from_lkddb("x".into(), "3.0 and newer".into(), "bcma".into(), vec![], (6, 8));
        assert_eq!(r.rating, 'D', "{}: {}", r.rating, r.reason);
    }

    #[test]
    fn rating_parser_reports_newer_kernel_as_c() {
        // Needs 6.9+, ISO has 6.8 -> not in-kernel -> C.
        let r = rating_from_lkddb("x".into(), "6.9 and newer".into(), "driver".into(), vec![], (6, 8));
        assert_eq!(r.rating, 'C', "{}: {}", r.rating, r.reason);
        assert!(
            r.reason.contains("needs kernel") && r.reason.contains("6.9"),
            "{}",
            r.reason
        );
    }

    #[test]
    fn rating_parser_reports_missing_entry_as_u() {
        let r = rating_from_lkddb("x".into(), String::new(), String::new(), vec![], (6, 8));
        assert_eq!(r.rating, 'U', "{}: {}", r.rating, r.reason);
    }

    // The Aspire 5560 BIOS prerequisite. The notice must name BOTH BIOS
    // changes and how to reach setup, because each one alone is useless: the
    // wrong graphics mode has no display, the wrong disk mode has no disk.
    #[test]
    fn aspire_5560_notice_names_both_bios_changes_and_f2() {
        let n = model_notice_for("Aspire 5560").expect("Aspire 5560 must have a notice");
        assert_eq!(n.model, "Aspire 5560");
        let t = n.notice.to_lowercase();
        assert!(t.contains("switchable"), "graphics mode: {}", n.notice);
        assert!(t.contains("integrated"), "integrated graphics: {}", n.notice);
        assert!(t.contains("ide"), "disk mode: {}", n.notice);
        assert!(t.contains("ahci"), "disk mode source: {}", n.notice);
        assert!(t.contains("f2"), "how to enter setup: {}", n.notice);
    }

    #[test]
    fn model_notice_matching_is_case_insensitive_and_model_specific() {
        // SMBIOS reports the product name with varying case.
        assert!(model_notice_for("acer aspire 5560").is_some());
        // A different model must not inherit an Aspire 5560 warning.
        assert!(model_notice_for("Aspire 5750").is_none());
        assert!(model_notice_for("Aspire 556").is_none());
        // Unknown machine (Win9x / stripped install): no notice, no panic.
        assert!(model_notice_for("").is_none());
    }
}
