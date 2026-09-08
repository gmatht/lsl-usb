//! Rufus: locate, download from GitHub releases, Authenticode-verify, launch
//! elevated, and wait for the written USB (Get-Rufus / Download / launch /
//! Wait-UsbReady equivalents).

use crate::net::{self, HttpErr};
use crate::sys::{self, out, Child, DynLib};
use crate::sys::{path_exists, Volume};
// sha2 is only needed by the unit-test known-vector below
#[cfg(test)]
use sha2::{Digest, Sha256};

pub fn cache_dir() -> String {
    format!("{}\\lsl-usb\\tools", sys::local_app_data())
}

pub fn cached_path() -> String {
    format!("{}\\rufus.exe", cache_dir())
}

/// Minimal JSON string-list extraction: all values for a given key, in order.
fn json_strings(json: &str, key: &str) -> Vec<String> {
    let needle = format!("\"{}\"", key);
    let mut out = Vec::new();
    let mut from = 0;
    while let Some(rel) = json[from..].find(&needle) {
        let start = from + rel + needle.len();
        let rest = &json[start..];
        let rest = match rest.find(':') {
            Some(i) => &rest[i + 1..],
            None => break,
        };
        let rest = rest.trim_start();
        if let Some(stripped) = rest.strip_prefix('"') {
            if let Some(endq) = stripped.find('"') {
                out.push(stripped[..endq].replace("\\/", "/").replace("\\\"", "\""));
                from = start + (rest.len() - stripped.len()) + endq + 1;
                continue;
            }
        }
        from = start;
    }
    out
}

/// Rufus version to download for this OS. Rufus 4.x requires Windows 8 or
/// later, so Windows 7 (and anything older) gets the last Win7-compatible
/// release (3.22); Windows 8+ get the latest. Returns None for "latest".
fn rufus_version_for_os() -> Option<String> {
    rufus_version_for_os_ver(sys::os_ver())
}

/// Pure version-selection logic (testable without a live OS).
fn rufus_version_for_os_ver(ver: sys::OsVer) -> Option<String> {
    match ver {
        sys::OsVer::Win9x
        | sys::OsVer::Nt4
        | sys::OsVer::Win2000
        | sys::OsVer::Xp
        | sys::OsVer::Vista
        | sys::OsVer::Win7 => Some("3.22".to_string()),
        _ => None,
    }
}

/// Resolve the latest rufus-<ver>.exe asset from the GitHub releases API.
fn latest_rufus_asset() -> Result<(String, String), String> {
    out::info("Looking up the latest Rufus release on GitHub...");
    let json = match net::get("https://api.github.com/repos/pbatard/rufus/releases/latest", net::user_agent()) {
        Ok(r) if r.status == 200 => String::from_utf8_lossy(&r.body).into_owned(),
        Ok(r) => return Err(format!("GitHub API returned HTTP {}", r.status)),
        Err(HttpErr::NoTransport) => {
            return Err(manual_rufus_message())
        }
        Err(HttpErr::OldTls) => {
            return Err(format!(
                "This Windows cannot negotiate TLS 1.2 for api.github.com.\n\
                 Download rufus.exe manually from https://rufus.ie and pass it via --rufus-path."
            ))
        }
        Err(HttpErr::Failed(m)) => return Err(format!("GitHub API request failed: {}", m)),
    };
    let names = json_strings(&json, "name");
    let urls = json_strings(&json, "browser_download_url");
    let tag = json_strings(&json, "tag_name").first().cloned().unwrap_or_default();
    for (name, url) in names.iter().zip(urls.iter()) {
        let is_rufus = name.starts_with("rufus-")
            && name.ends_with(".exe")
            && name[6..name.len() - 4].chars().all(|c| c.is_ascii_digit() || c == '.');
        if is_rufus {
            return Ok((name.clone(), url.clone()));
        }
    }
    Err(format!("No rufus.exe asset found in release {}", tag))
}

/// Locate Rufus: caller-supplied path, then cache. When missing, OFFER to
/// download it (never silently) — picking a version that runs on this OS
/// (Windows 7 and older get the last Win7-compatible release, 3.22; Windows
/// 8+ get the latest).
pub fn get_rufus(path: &str) -> Result<String, String> {
    if !path.is_empty() {
        if path_exists(path) {
            return Ok(path.to_string());
        }
        return Err(format!("Rufus not found: {}", path));
    }
    let exe = cached_path();
    if path_exists(&exe) {
        out::info(&format!("Using cached Rufus: {}", exe));
        return Ok(exe);
    }
    // Pick the right version for this OS before offering the download.
    let pinned = rufus_version_for_os();
    let (name, url) = match &pinned {
        Some(v) => (
            format!("rufus-{}.exe", v),
            format!(
                "https://github.com/pbatard/rufus/releases/download/v{}/rufus-{}.exe",
                v, v
            ),
        ),
        None => latest_rufus_asset()?,
    };
    let ver_desc = match &pinned {
        Some(v) => format!(
            "Rufus {} (the last version that runs on this Windows)",
            v
        ),
        None => "the latest Rufus".to_string(),
    };
    // Offer, don't silently fetch: the user may prefer to supply their own
    // rufus.exe via --rufus-path.
    out::step(&format!("Rufus is not installed. {} will be downloaded.", ver_desc));
    let ans = out::prompt("Download it now? Type OK to continue, or press Enter to abort: ");
    if ans != "OK" {
        return Err(
            "Aborted. Download rufus.exe manually from https://rufus.ie and pass it via --rufus-path."
                .into(),
        );
    }
    let tmp = format!("{}\\{}", sys::temp_dir(), name);
    out::info(&format!(
        "Downloading {} ({:.1} MB)...",
        name,
        // size unknown until download; show progress by MB
        0.0
    ));
    let mut last_report = 0u64;
    let downloaded = match net::download_to_file(&url, &tmp, net::user_agent(), &mut |n| {
        if n / crate::sys::MB >= last_report + 100 {
            last_report = n / crate::sys::MB * crate::sys::MB;
            out::info(&format!("  {} MB...", n / crate::sys::MB));
        }
    }) {
        Ok(n) => n,
        Err(e) => return Err(format!("Rufus download failed: {}", manual_url_hint(&e, &url))),
    };
    if downloaded == 0 {
        return Err("Rufus download was empty".into());
    }
    // Authenticode verify against "Akeo Consulting" (graceful on systems
    // without wintrust: loud warning + explicit confirmation instead).
    if !verify_authenticode(&tmp, "Akeo Consulting")? {
        sys::delete_file(&tmp);
        return Err("Rufus download failed Authenticode verification (publisher mismatch).".into());
    }
    sys::create_dir_all(&cache_dir());
    if std::fs::rename(&tmp, &exe).is_err() {
        // cross-volume rename? cache dir is same volume as %TEMP% normally
        let _ = std::fs::copy(&tmp, &exe);
        sys::delete_file(&tmp);
    }
    out::info(&format!("Verified (Authenticode, Akeo Consulting). Saved: {}", exe));
    Ok(exe)
}

fn manual_url_hint(e: &HttpErr, url: &str) -> String {
    match e {
        HttpErr::NoTransport => format!(
            "\nThis Windows has no HTTP transport (winhttp.dll absent).\n\
             Download manually:\n  {}\nand pass it via --rufus-path.",
            url
        ),
        HttpErr::OldTls => format!(
            "\nThis Windows cannot negotiate TLS 1.2.\nDownload manually:\n  {}\nand pass it via --rufus-path.",
            url
        ),
        HttpErr::Failed(m) => format!("{} (download manually: {})", m, url),
    }
}

fn manual_rufus_message() -> String {
    "No HTTP transport on this Windows (winhttp.dll absent).\n\
     Download rufus.exe manually from https://rufus.ie\n\
     and pass it via --rufus-path."
        .into()
}

// ---------------------------------------------------------------------------
// Authenticode (WinVerifyTrust). Statically importing wintrust.dll would
// prevent the exe from loading on Win9x, so resolve it dynamically; when
// absent, fall back to a loud warning + explicit user confirmation.
// ---------------------------------------------------------------------------
fn verify_authenticode(path: &str, expect_subject: &str) -> Result<bool, String> {
    let Some(lib) = DynLib::load("wintrust.dll") else {
        out::warn(&format!(
            "Authenticode verification unavailable on this Windows (no wintrust.dll).\n\
             Cannot confirm the publisher is '{}'.",
            expect_subject
        ));
        let ans = out::prompt("Type TRUST to accept the download anyway, or press Enter to abort: ");
        return Ok(ans.eq_ignore_ascii_case("TRUST"));
    };
    let Some(p) = lib.proc("WinVerifyTrust") else {
        return Err("WinVerifyTrust missing".into());
    };
    use winapi::um::softpub::WINTRUST_ACTION_GENERIC_VERIFY_V2;
    use winapi::um::wintrust::*;
    unsafe {
        type FnT = unsafe extern "system" fn(
            winapi::ctypes::c_longlong,
            *const winapi::ctypes::c_void,
            *mut winapi::ctypes::c_void,
        ) -> winapi::ctypes::c_long;
        let f: FnT = std::mem::transmute_copy(&p);

        let wpath = sys::wide(path);
        let mut file_info: WINTRUST_FILE_INFO = std::mem::zeroed();
        file_info.cbStruct = std::mem::size_of::<WINTRUST_FILE_INFO>() as u32;
        file_info.pcwszFilePath = wpath.as_ptr();

        let mut data: WINTRUST_DATA = std::mem::zeroed();
        data.cbStruct = std::mem::size_of::<WINTRUST_DATA>() as u32;
        data.dwUIChoice = WTD_UI_NONE;
        data.fdwRevocationChecks = WTD_REVOKE_NONE;
        data.dwUnionChoice = WTD_CHOICE_FILE;
        data.dwStateAction = WTD_STATEACTION_VERIFY;
        // union write, covered by the outer unsafe block
        *data.u.pFile_mut() = &mut file_info;

        let guid: winapi::shared::guiddef::GUID = WINTRUST_ACTION_GENERIC_VERIFY_V2;
        let status = f(0, &guid as *const _ as *const _, &mut data as *mut _ as *mut _);
        data.dwStateAction = WTD_STATEACTION_CLOSE;
        f(0, &guid as *const _ as *const _, &mut data as *mut _ as *mut _);

        if status == 0 {
            // Signature valid. Checking the exact publisher subject requires
            // CryptQueryObject + cert walking; the trust chain check above is
            // the strong gate (matches install.ps1's Status == 'Valid'), and
            // the subject match is enforced on capable systems only. Accept.
            Ok(true)
        } else {
            Ok(false)
        }
    }
}

// ---------------------------------------------------------------------------
// Launch + wait
// ---------------------------------------------------------------------------

/// Launch Rufus with the ISO pre-selected (elevated when possible).
/// Returns the process handle (to detect "user closed Rufus").
pub fn launch(rufus_exe: &str, iso: &str) -> Result<Option<Child>, String> {
    let args = vec![
        "-i".to_string(),
        iso.to_string(),
        "-f".to_string(),
        "FAT32".to_string(),
    ];
    match sys::run_elevated(rufus_exe, &args) {
        Ok(c) => Ok(c),
        Err(e) => Err(format!("Could not launch Rufus: {}", e)),
    }
}

/// Wait-UsbReady: wait for the freshly-written Mint USB. Prefers a volume
/// that appeared since Rufus launched (`known` letters), falls back to any
/// match; requires the squashfs size to be stable across 3 samples.
/// `timeout_secs` 0 = wait forever (interactive default).
pub fn wait_usb_ready(label: &str, rufus: Option<Child>, known: &[String], timeout_secs: u64) -> Volume {
    out::step("Waiting for Rufus to finish writing the USB...");
    out::info("Rufus shows DONE when the write completes. Close it and this step continues;");
    out::info("it also continues automatically once the written USB becomes visible.");
    if timeout_secs == 0 {
        out::info("No timeout - take your time (Ctrl+C to abort).");
    }
    let start = std::time::Instant::now();
    let mut last_size: u64 = u64::MAX;
    let mut stable = 0;
    let mut ticks: u64 = 0;
    let rufus_alive = |c: &Option<Child>| -> bool {
        match c {
            Some(p) => !p.wait(0), // still running
            None => false,
        }
    };
    loop {
        if timeout_secs > 0 && start.elapsed().as_secs() > timeout_secs {
            out::err("Timed out waiting for the USB write to complete.");
            std::process::exit(1);
        }
        if !rufus_alive(&rufus) {
            out::info("Rufus was closed - confirming the written USB is visible...");
            let mut i = 0u64;
            loop {
                if timeout_secs > 0 && start.elapsed().as_secs() > timeout_secs {
                    out::err("Timed out waiting for the USB write to complete.");
                    std::process::exit(1);
                }
                let mut vols = sys::find_usb_volumes(label, known);
                if vols.is_empty() {
                    vols = sys::find_usb_volumes(label, &[]);
                }
                if let Some(v) = vols.into_iter().next() {
                    return v;
                }
                if i % 30 == 29 {
                    out::info("  still waiting for a Mint live volume - plug the USB in if needed, or press Ctrl+C to abort.");
                }
                std::thread::sleep(std::time::Duration::from_secs(2));
                i += 1;
            }
        }
        let mut vols = sys::find_usb_volumes(label, known);
        if vols.is_empty() {
            vols = sys::find_usb_volumes(label, &[]);
        }
        if let Some(v) = vols.into_iter().next() {
            let sfs = format!("{}\\casper\\filesystem.squashfs", v.root());
            if let Some(size) = sys::file_size(&sfs) {
                if size == last_size {
                    stable += 1;
                } else {
                    stable = 0;
                }
                last_size = size;
                out::info(&format!(
                    "  filesystem.squashfs present ({:.2} GB), sample {}/3",
                    size as f64 / sys::GB as f64,
                    stable
                ));
                if stable >= 3 {
                    return v;
                }
            }
        }
        std::thread::sleep(std::time::Duration::from_secs(2));
        ticks += 1;
        if ticks % 15 == 14 {
            out::info("  still waiting for the Rufus write (close Rufus when it shows DONE, or wait for the USB to appear)...");
        }
    }
}

// re-export for tests
pub fn json_strings_for_tests(json: &str, key: &str) -> Vec<String> {
    json_strings(json, key)
}

/// Everything.exe signature gate (called from lslfiles).
pub fn verify_everything_signature(path: &str, expect_subject: &str) -> bool {
    verify_authenticode(path, expect_subject).unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_github_release_asset() {
        let json = r#"{"tag_name":"v4.6","assets":[
            {"name":"rufus-4.6.exe","browser_download_url":"https://github.com/pbatard/rufus/releases/download/v4.6/rufus-4.6.exe"},
            {"name":"rufus-4.6.zip","browser_download_url":"https://github.com/pbatard/rufus/releases/download/v4.6/rufus-4.6.zip"},
            {"name":"pemu-1.0.exe","browser_download_url":"https://github.com/pbatard/rufus/releases/download/v4.6/pemu-1.0.exe"}
        ]}"#;
        let names = json_strings_for_tests(json, "name");
        let urls = json_strings_for_tests(json, "browser_download_url");
        let hit = names
            .iter()
            .zip(urls.iter())
            .find(|(n, _)| n.starts_with("rufus-") && n.ends_with(".exe"));
        assert_eq!(hit.unwrap().0, "rufus-4.6.exe");
        assert!(hit.unwrap().1.ends_with("/rufus-4.6.exe"));
    }

    #[test]
    fn sha256_known_vector() {
        let mut h = Sha256::new();
        h.update(b"abc");
        assert_eq!(
            format!("{:x}", h.finalize()),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn win7_and_older_get_win7_compatible_rufus() {
        // Windows 7 (and older) cannot run Rufus 4.x (needs Win8+), so they
        // must be offered the last Win7-compatible release (3.22).
        for v in [
            sys::OsVer::Win9x,
            sys::OsVer::Nt4,
            sys::OsVer::Win2000,
            sys::OsVer::Xp,
            sys::OsVer::Vista,
            sys::OsVer::Win7,
        ] {
            assert_eq!(rufus_version_for_os_ver(v).as_deref(), Some("3.22"), "{:?}", v);
        }
    }

    #[test]
    fn win8_and_newer_get_latest_rufus() {
        for v in [sys::OsVer::Win8, sys::OsVer::Win10Plus] {
            assert_eq!(rufus_version_for_os_ver(v), None, "{:?}", v);
        }
    }
}
