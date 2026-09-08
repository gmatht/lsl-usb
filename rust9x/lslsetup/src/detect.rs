//! Windows-side detection: WSL VHDX paths, installed apps (flatpak matching).
//! Mirrors bin/lsl-win-detect.ps1. Registry + filesystem only — no WMI, no
//! PowerShell, so it works on every Windows version.

use crate::sys::{hkcu, hklm, local_app_data, path_exists, RegKey};
use winapi::shared::minwindef::HKEY;

/// Get-WslVhdxPaths: registry Lxss (HKCU+HKLM) -> Packages scan -> legacy lxss
/// dir -> user-supplied extras. Deduplicated.
pub fn wsl_vhdx_paths(extra: &[String]) -> Vec<String> {
    let mut found: Vec<String> = Vec::new();
    for root in [hkcu(), hklm()] {
        let lxss_path = "Software\\Microsoft\\Windows\\CurrentVersion\\Lxss".to_string();
        if let Some(lxss) = RegKey::open(root, &lxss_path) {
            for guid in lxss.subkeys() {
                if let Some(distro) = RegKey::open(root, &format!("{}\\{}", lxss_path, guid)) {
                    // Some Lxss subkeys (Notifications) are not distros — read
                    // defensively like the PS version.
                    let base = match distro.value("BasePath") {
                        Some(b) if !b.is_empty() => b,
                        _ => continue,
                    };
                    let base = base
                        .strip_prefix("\\\\?\\")
                        .map(|s| s.to_string())
                        .unwrap_or(base);
                    let ver = distro.value_u32("Version").unwrap_or(1);
                    if ver == 2 {
                        let vhdx = format!("{}\\ext4.vhdx", base);
                        if path_exists(&vhdx) {
                            found.push(vhdx);
                        }
                    }
                }
            }
        }
    }
    // 2) Fallback scan: default Store locations (covers stale/missing registry).
    let pkg_root = format!("{}\\Packages", local_app_data());
    scan_vhdx(&pkg_root, 4, &mut found);
    let legacy = format!("{}\\lxss\\ext4.vhdx", local_app_data());
    if path_exists(&legacy) {
        found.push(legacy);
    }
    for e in extra {
        if !e.is_empty() && path_exists(e) {
            found.push(e.clone());
        }
    }
    // order-preserving, case-insensitive dedup (dedup_by only removes
    // CONSECUTIVE duplicates)
    let mut seen: Vec<String> = Vec::new();
    found.retain(|p| {
        let lower = p.to_lowercase();
        if seen.contains(&lower) {
            false
        } else {
            seen.push(lower);
            true
        }
    });
    found
}

fn scan_vhdx(dir: &str, depth: u32, out: &mut Vec<String>) {
    if depth == 0 {
        return;
    }
    let pattern = format!("{}\\*", dir);
    let w = crate::sys::wide(&pattern);
    unsafe {
        let mut fd: winapi::um::minwinbase::WIN32_FIND_DATAW = std::mem::zeroed();
        let h = winapi::um::fileapi::FindFirstFileW(w.as_ptr(), &mut fd);
        if h == winapi::um::handleapi::INVALID_HANDLE_VALUE {
            return;
        }
        loop {
            let name = crate::sys::from_wide(&fd.cFileName);
            if name != "." && name != ".." {
                let full = format!("{}\\{}", dir, name);
                if fd.dwFileAttributes & winapi::um::winnt::FILE_ATTRIBUTE_DIRECTORY != 0 {
                    scan_vhdx(&full, depth - 1, out);
                } else if name.eq_ignore_ascii_case("ext4.vhdx")
                    && dir.to_lowercase().ends_with("\\localstate")
                {
                    out.push(full);
                }
            }
            if winapi::um::fileapi::FindNextFileW(h, &mut fd) == 0 {
                break;
            }
        }
        winapi::um::fileapi::FindClose(h);
    }
}

/// Get-InstalledWindowsApps: DisplayName from the standard Uninstall registry
/// keys (HKCU + HKLM, 32/64-bit), plus MSIX/Store package names discovered by
/// scanning %LOCALAPPDATA%\Packages (the graceful stand-in for
/// Get-AppxPackage, which needs the Appx module — PowerShell-only).
pub fn installed_app_names() -> Vec<String> {
    let mut names: Vec<String> = Vec::new();
    // KEY_WOW64_64KEY (0x0100): a 32-bit process is by default redirected to
    // WOW6432Node and can NEVER see the native 64-bit Uninstall view — that
    // hides 64-bit apps (Firefox, Docker Desktop, Inkscape MSI, ...). Open
    // the native view first; the flag is ignored on 32-bit Windows.
    let roots: Vec<(HKEY, &str, bool)> = vec![
        (hkcu(), "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall", false),
        (hklm(), "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall", true),
        (hklm(), "Software\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall", false),
    ];
    for (root, path, native) in roots {
        let k = if native {
            RegKey::open_wow64(root, path).or_else(|| RegKey::open(root, path))
        } else {
            RegKey::open(root, path)
        };
        if let Some(k) = k {
            for sub in k.subkeys() {
                // the subkey must be opened with the SAME view flag — a
                // plain open() redirects back to WOW6432Node, where these
                // native-only entries (Docker Desktop, Firefox, Inkscape…)
                // simply do not exist
                let item = if native {
                    RegKey::open_wow64(root, &format!("{}\\{}", path, sub))
                } else {
                    RegKey::open(root, &format!("{}\\{}", path, sub))
                };
                if let Some(item) = item {
                    if let Some(n) = item.value("DisplayName") {
                        if !n.is_empty() {
                            names.push(n);
                        }
                    }
                }
            }
        }
    }
    // MSIX package family names live as directories under %LOCALAPPDATA%\Packages
    let pkg_root = format!("{}\\Packages", local_app_data());
    let w = crate::sys::wide(&format!("{}\\*", pkg_root));
    unsafe {
        let mut fd: winapi::um::minwinbase::WIN32_FIND_DATAW = std::mem::zeroed();
        let h = winapi::um::fileapi::FindFirstFileW(w.as_ptr(), &mut fd);
        if h != winapi::um::handleapi::INVALID_HANDLE_VALUE {
            loop {
                let name = crate::sys::from_wide(&fd.cFileName);
                if name != "." && name != ".."
                    && fd.dwFileAttributes & winapi::um::winnt::FILE_ATTRIBUTE_DIRECTORY != 0
                {
                    names.push(name);
                }
                if winapi::um::fileapi::FindNextFileW(h, &mut fd) == 0 {
                    break;
                }
            }
            winapi::um::fileapi::FindClose(h);
        }
    }
    names.sort_by(|a, b| a.to_lowercase().cmp(&b.to_lowercase()));
    names.dedup_by(|a, b| a.to_lowercase() == b.to_lowercase());
    names
}

#[cfg(test)]
mod tests {
    #[test]
    fn flatpak_map_matches_substring() {
        assert!(matches_app("GIMP.43237F745459", "GIMP"));
        assert!(matches_app("Visual Studio Code", "Visual Studio Code"));
        assert!(!matches_app("Firefox Developer", "Slack"));
    }

    fn matches_app(installed: &str, needle: &str) -> bool {
        installed.to_lowercase().contains(&needle.to_lowercase())
    }
}
