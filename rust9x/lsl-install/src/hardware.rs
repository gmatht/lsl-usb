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
    pub kind: &'static str,
    pub chip: &'static str,
    pub pkg: &'static str,
    pub source: &'static str, // "ubuntu" | "github"
    pub suite: &'static str,
    pub component: &'static str,
    pub repo: &'static str,
    pub branch: &'static str,
    pub note: &'static str,
}

pub fn driver_table() -> &'static [DriverEntry] {
    &[
        DriverEntry { id: "0BDA:8812", kind: "USB", chip: "Realtek RTL8812AU", pkg: "rtl8812au-dkms", source: "ubuntu", suite: "noble-updates", component: "universe", repo: "", branch: "", note: "in-kernel only since 6.14" },
        DriverEntry { id: "0BDA:881A", kind: "USB", chip: "Realtek RTL8814AU", pkg: "rtl8814au", source: "github", suite: "", component: "", repo: "morrownr/8814au", branch: "main", note: "in-kernel only since 6.14" },
        DriverEntry { id: "0BDA:8179", kind: "USB", chip: "Realtek RTL8188EU", pkg: "rtl8188eu", source: "github", suite: "", component: "", repo: "lwfinger/rtl8188eu", branch: "master", note: "kernel has only a staging driver" },
        DriverEntry { id: "0BDA:B720", kind: "USB", chip: "Realtek RTL8723BU", pkg: "rtl8723bu", source: "github", suite: "", component: "", repo: "lwfinger/rtl8723bu", branch: "master", note: "LKDDb entry is the bluetooth function only" },
        DriverEntry { id: "14E4:4365", kind: "PCI", chip: "Broadcom BCM43142", pkg: "broadcom-sta-dkms", source: "ubuntu", suite: "noble-updates", component: "restricted", repo: "", branch: "", note: "wl driver; LKDDb entry is the bcma bus bridge only" },
        DriverEntry { id: "14E4:43A0", kind: "PCI", chip: "Broadcom BCM4360", pkg: "broadcom-sta-dkms", source: "ubuntu", suite: "noble-updates", component: "restricted", repo: "", branch: "", note: "wl driver; LKDDb entry is the bcma bus bridge only" },
        DriverEntry { id: "14E4:43B1", kind: "PCI", chip: "Broadcom BCM4352", pkg: "broadcom-sta-dkms", source: "ubuntu", suite: "noble-updates", component: "restricted", repo: "", branch: "", note: "wl driver; LKDDb entry is the bcma bus bridge only" },
        DriverEntry { id: "14E4:4727", kind: "PCI", chip: "Broadcom BCM4313", pkg: "broadcom-sta-dkms", source: "ubuntu", suite: "noble-updates", component: "restricted", repo: "", branch: "", note: "wl driver; LKDDb entry is the bcma bus bridge only" },
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
fn ubuntu_package_url(pkg: &str, suite: &str, component: &str) -> Option<String> {
    let cache = format!(
        "{}\\lsl-apt-{}-{}-Packages.gz",
        crate::sys::temp_dir(),
        suite,
        component
    );
    if !path_exists(&cache) {
        let url = format!(
            "http://archive.ubuntu.com/ubuntu/dists/{}/{}/binary-amd64/Packages.gz",
            suite, component
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
                return Some(format!("http://archive.ubuntu.com/ubuntu/{}", fn_part.trim()));
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
// linux-hardware.org LKDDb rating (Get-LinuxCompatRating).
// ---------------------------------------------------------------------------

// Compiled-in summary of the lsl-hw-cache snapshot (see build.rs): common
// hardware rates instantly, with no network request at all.
include!(concat!(env!("OUT_DIR"), "/hw_cache_embedded.rs"));

fn embedded_lookup(id: &str) -> Option<(&'static str, &'static str, &'static str, Vec<String>)> {
    for (e_id, e_name, e_ksup, e_src, e_third) in EMBEDDED_HW_CACHE.iter() {
        if *e_id == id {
            return Some((*e_name, *e_ksup, *e_src, e_third.iter().map(|t| t.to_string()).collect()));
        }
    }
    None
}

// robots.txt Crawl-delay politeness state.
const LHW_DELAY_SECS: u64 = 10;

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
        let mut st = LHW.lock().unwrap();
        if let Some(t) = st.last {
            let elapsed = t.elapsed().as_secs();
            if elapsed < LHW_DELAY_SECS {
                std::thread::sleep(std::time::Duration::from_secs(LHW_DELAY_SECS - elapsed));
            }
        }
    }
    let url = format!("https://linux-hardware.org/?id={}", id);
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

fn html_attr(s: &str, pat: &str) -> Option<String> {
    let i = s.find(pat)? + pat.len();
    let rest = &s[i..];
    let j = rest.find('"')?;
    Some(rest[..j].to_string())
}

#[derive(Debug, Clone)]
pub struct Rating {
    pub rating: char, // A / C / D / U
    pub name: String,
    pub reason: String,
    pub kernel_support: String,
    pub driver_source: String,
    pub third_party: Vec<String>,
}

pub fn lhw_url(d: &Device) -> String {
    format!(
        "https://linux-hardware.org/?id={}:{}-{}",
        d.kind.to_lowercase(),
        d.vendor.to_lowercase(),
        d.device.to_lowercase()
    )
}

pub fn linux_compat_rating(d: &Device, bundle_dir: &str, iso_kernel: (u32, u32)) -> Rating {
    let id = format!(
        "{}:{}-{}",
        d.kind.to_lowercase(),
        d.vendor.to_lowercase(),
        d.device.to_lowercase()
    );
    let html = lhw_fetch_page(&id, bundle_dir);
    let (mut name, mut ksup, mut src, mut third) = parse_lhw_html(&html);
    let mut have_data = !html.is_empty();
    if !have_data {
        // compiled-in snapshot: rates common hardware with no network request
        if let Some((e_name, e_ksup, e_src, e_third)) = embedded_lookup(&id) {
            if !e_name.is_empty() {
                name = e_name.to_string();
            }
            ksup = e_ksup.to_string();
            src = e_src.to_string();
            third = e_third;
            have_data = true;
        }
    }
    // Curated table override (known-problem chips).
    if let Some(t) = driver_table().iter().find(|t| t.id == d.id) {
        return Rating {
            rating: 'C',
            name,
            reason: format!("needs out-of-tree driver ({}) - staged to <USB>:\\drivers\\", t.pkg),
            kernel_support: ksup,
            driver_source: src,
            third_party: third,
        };
    }
    if !have_data {
        return Rating {
            rating: 'U',
            name,
            reason: "no data (linux-hardware.org unreachable/rate-limited/TLS too old)".into(),
            kernel_support: ksup,
            driver_source: src,
            third_party: third,
        };
    }
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
            kernel_support: ksup,
            driver_source: src,
            third_party: third,
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
            kernel_support: ksup,
            driver_source: src,
            third_party: third,
        };
    }
    if in_kernel && bridge_only {
        return Rating {
            rating: 'D',
            name,
            reason: format!("LKDDb entry is only {} - no real driver for this function", src),
            kernel_support: ksup,
            driver_source: src,
            third_party: third,
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
        kernel_support: ksup,
        driver_source: src,
        third_party: third,
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

#[allow(unused)]
fn unused_out() {
    out::plain("");
    path_exists("");
}
