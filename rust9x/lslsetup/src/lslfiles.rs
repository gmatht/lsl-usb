//! lsl-usb file drop + env manipulation + driver/rusttool/flatpak/EFU staging
//! (Install-LslFiles, Add-SafeBootEntry, Copy-SfsToHdd, Install-RustTools,
//! Write-FlatpakRefs, Write-EverythingEfu, Install-Everything equivalents).

use crate::sys::{self, file_size, out, path_exists};
use sha2::{Digest, Sha256};
use std::io::Read;

pub fn sha256_file(path: &str) -> Option<String> {
    match sha256_file_progress(path, &mut |_, _| true) {
        Ok(HashResult::Hash(h)) => Some(h),
        _ => None,
    }
}

/// Outcome of a cancellable file hash.
pub enum HashResult {
    Hash(String),
    Aborted,
}

/// SHA-256 of a file with live (done, total) progress. `progress` returns
/// false to abort early (mid-flight skip). Same hash as `sha256_file` on
/// completion; use it for multi-GB files so callers can drive a progress
/// bar and pump the GUI — a silent 3 GB hash over USB looks exactly like
/// a freeze.
pub fn sha256_file_progress(
    path: &str,
    progress: &mut dyn FnMut(u64, u64) -> bool,
) -> Result<HashResult, String> {
    let mut f = std::fs::File::open(path).map_err(|e| format!("open {}: {}", path, e))?;
    let total = f.metadata().map(|m| m.len()).unwrap_or(0);
    let mut h = Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    let mut done = 0u64;
    if !progress(0, total) {
        return Ok(HashResult::Aborted);
    }
    loop {
        let n = f.read(&mut buf).map_err(|e| format!("read {}: {}", path, e))?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
        done += n as u64;
        if !progress(done, total) {
            return Ok(HashResult::Aborted);
        }
    }
    Ok(HashResult::Hash(format!("{:x}", h.finalize())))
}

/// Set (or append) a KEY=value line in an env file, leaving the rest intact.
pub fn env_file_set(path: &str, key: &str, value: &str) {
    let content = std::fs::read_to_string(path).unwrap_or_default();
    let prefix = format!("{}=", key);
    let mut out_lines: Vec<String> = Vec::new();
    let mut replaced = false;
    for line in content.lines() {
        if line.starts_with(&prefix) {
            if !replaced {
                out_lines.push(format!("{}={}", key, value));
                replaced = true;
            }
        } else {
            out_lines.push(line.to_string());
        }
    }
    if !replaced {
        out_lines.push(format!("{}={}", key, value));
    }
    let mut text = out_lines.join("\n");
    text.push('\n');
    let _ = std::fs::write(path, text);
}

// ---------------------------------------------------------------------------
// Firstboot toolkit (nofmt path)
// ---------------------------------------------------------------------------
// The non-destructive install has no bundle dir (it works from the ISO plus
// embedded assets), but the first boot needs the FAT-side toolkit
// (bin/uproot, bin/squashfs_config.sh, bin/lsl-diag.sh,
// bin/persist-wifi.sh, onboot.sh) - without it lsl-firstboot.service finds
// "uproot missing" and can only stamp trivially. These are small text
// files embedded at compile time from the repo; they are LF-normalized on
// write because the guest runs them under /bin/bash, which chokes on the
// CRLF that Windows checkouts produce (do not depend on checkout settings).
static FIRSTBOOT_TOOLKIT: &[(&str, &str)] = &[
    ("bin\\uproot", include_str!("../../../bin/uproot")),
    ("bin\\squashfs_config.sh", include_str!("../../../bin/squashfs_config.sh")),
    ("bin\\config.sh", include_str!("../../../bin/config.sh")),
    ("bin\\lsl-diag.sh", include_str!("../../../bin/lsl-diag.sh")),
    ("bin\\lsl-common.sh", include_str!("../../../bin/lsl-common.sh")),
    ("bin\\persist-wifi.sh", include_str!("../../../bin/persist-wifi.sh")),
    ("bin\\lsl-flatpak-fat.sh", include_str!("../../../bin/lsl-flatpak-fat.sh")),
    ("systemd\\onboot.service", include_str!("../../../systemd/onboot.service")),
    ("systemd\\lsl-boot-stamp.service", include_str!("../../../systemd/lsl-boot-stamp.service")),
    ("systemd\\lsl-btrfs-growd.service", include_str!("../../../systemd/lsl-btrfs-growd.service")),
    ("systemd\\lsl-home-flushd.service", include_str!("../../../systemd/lsl-home-flushd.service")),
    ("systemd\\lsl-precache.service", include_str!("../../../systemd/lsl-precache.service")),
    ("systemd\\lsl-reclaim-win-swap.service", include_str!("../../../systemd/lsl-reclaim-win-swap.service")),
    ("systemd\\lsl-win-backup.service", include_str!("../../../systemd/lsl-win-backup.service")),
    ("systemd\\lsl-win-backup.timer", include_str!("../../../systemd/lsl-win-backup.timer")),
    ("fuse\\fat_linux_meta_fs.py", include_str!("../../../fuse/fat_linux_meta_fs.py")),
    ("fuse\\fusepy\\fuse.py", include_str!("../../../fuse/fusepy/fuse.py")),
    ("onboot.sh", include_str!("../../../onboot.sh")),
];

pub fn install_firstboot_toolkit(root: &str) -> Result<Vec<String>, String> {
    let mut done = Vec::new();
    for (rel, content) in FIRSTBOOT_TOOLKIT {
        let dest = format!("{}\\{}", root.trim_end_matches('\\'), rel);
        if let Some(parent) = std::path::Path::new(&dest).parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| format!("create dir for {}: {}", rel, e))?;
        }
        let lf = content.replace("\r\n", "\n");
        std::fs::write(&dest, lf.as_bytes()).map_err(|e| format!("write {}: {}", rel, e))?;
        let back = std::fs::read(&dest).map_err(|e| format!("read back {}: {}", rel, e))?;
        if back != lf.as_bytes() {
            return Err(format!("verify failed for {} (readback mismatch)", rel));
        }
        done.push(rel.to_string());
    }
    out::info(&format!("first-boot toolkit ({} files) ready.", done.len()));
    Ok(done)
}

/// Embedded z0 firstboot layer (casper/filesystem.z0.squashfs).
///
/// Built from misc/ by misc/build-z0.sh (mksquashfs, WSL) and committed
/// beside the other embedded assets; the nofmt installer has no mksquashfs
/// on Windows, so it ships this blob instead of building it. Rebuild
/// whenever misc/ changes - the blob carries lsl-firstboot.service, and a
/// stale blob means a stale firstboot. Content-proven in QEMU (layer
/// stacks base+z0+appended, firstboot stamps, relayer boots Brave/nvim).
static Z0_BLOB: &[u8] = include_bytes!("../assets/filesystem.z0.squashfs");

/// Write the embedded z0 layer to casper\ on the stick (always overwrite:
/// 12 KB, and this guarantees the firstboot service stays fresh). The
/// menu's layerfs-path points at exactly this file, so a missing/stale z0
/// is a boot failure, not a warning.
pub fn install_z0_layer(root: &str) -> Result<u64, String> {
    let dest = format!("{}\\casper\\filesystem.z0.squashfs", root.trim_end_matches('\\'));
    if Z0_BLOB.len() < 4096 || Z0_BLOB[0..4] != [0x68, 0x73, 0x71, 0x73] {
        return Err("embedded z0 layer is not a squashfs blob (bad magic/size)".into());
    }
    if let Some(parent) = std::path::Path::new(&dest).parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("create casper dir: {}", e))?;
    }
    std::fs::write(&dest, Z0_BLOB).map_err(|e| format!("write z0 layer: {}", e))?;
    let back = std::fs::read(&dest).map_err(|e| format!("read back z0 layer: {}", e))?;
    if back != Z0_BLOB {
        return Err("verify failed for z0 layer (readback mismatch)".into());
    }
    out::info(&format!("z0 firstboot layer ready ({} bytes).", Z0_BLOB.len()));
    Ok(Z0_BLOB.len() as u64)
}

// ---------------------------------------------------------------------------
// Install-LslFiles
// ---------------------------------------------------------------------------
pub fn install_lsl_files(vol_letter: &str, bundle_dir: &str) -> Result<(), String> {
    let root = format!("{}:\\", vol_letter);
    let casper = format!("{}casper", root);
    sys::create_dir_all(&casper);

    let mut copied: Vec<String> = Vec::new();

    // 1) the (minimal) root layer - casper stacks it over the base image.
    // Legacy bundle path (install.ps1 parity): a build.sh bundle ships
    // filesystem_z0_firstboot.squashfs next to the exe. The nofmt path
    // already wrote the embedded equivalent (casper/filesystem.z0.squashfs)
    // before we get here, so don't warn then - and never leave the stick
    // without a z0 layer: fall back to the embedded blob when the bundle
    // file is absent.
    let layer = format!("{}\\filesystem_z0_firstboot.squashfs", bundle_dir);
    let dotted = format!("{}\\filesystem.z0.squashfs", casper);
    if path_exists(&layer) {
        sys::copy_file(&layer, &format!("{}\\filesystem_z0_firstboot.squashfs", casper))
            .map_err(|e| format!("copy layer: {}", e))?;
        copied.push("filesystem_z0_firstboot.squashfs".into());
        // Dotted twin for casper's multi-layer dotted-chain walk (the
        // `layerfs-path=` on direct entries needs exactly this name; 8 KB,
        // and every existing `_firstboot` reader keeps working untouched).
        sys::copy_file(&layer, &dotted)
            .map_err(|e| format!("copy dotted layer: {}", e))?;
        copied.push("filesystem.z0.squashfs".into());
    } else if path_exists(&dotted) {
        out::info("z0 firstboot layer already present on the stick (embedded install); skipping bundle layer copy.");
    } else {
        match install_z0_layer(&root) {
            Ok(_) => copied.push("filesystem.z0.squashfs (embedded)".into()),
            Err(e) => out::warn(&format!("filesystem_z0_firstboot.squashfs not found in bundle and embedded z0 install failed ({}); layer not copied.", e)),
        }
    }

    // 2) the FAT-side lsl scripts (same set as bin/config.sh --sync-only)
    for d in ["bin", "systemd", "initramfs"] {
        let src = format!("{}\\{}", bundle_dir, d);
        if sys::is_dir(&src) {
            sys::copy_tree(&src, &format!("{}\\{}", root, d))
                .map_err(|e| format!("copy {}: {}", d, e))?;
            copied.push(format!("{}\\", d));
        }
    }
    for f in ["onboot.sh", "lsl-usb.env", "resolve-powershell.ps1"] {
        let src = format!("{}\\{}", bundle_dir, f);
        if path_exists(&src) {
            sys::copy_file(&src, &format!("{}\\{}", root, f))
                .map_err(|e| format!("copy {}: {}", f, e))?;
            copied.push(f.into());
        }
    }
    // 3) initrd: normally NOT shipped in the bundle any more - copy if present.
    for i in ["initrd.lz", "initrd.safe.lz"] {
        let src = format!("{}\\casper\\{}", bundle_dir, i);
        if path_exists(&src) {
            sys::copy_file(&src, &format!("{}\\{}", casper, i))
                .map_err(|e| format!("copy casper/{}: {}", i, e))?;
            copied.push(format!("casper/{}", i));
        }
    }
    // Stamp the build for traceability (captured by lsl-diag.sh on failure).
    let build_ver = std::fs::read_to_string(format!("{}\\VERSION", bundle_dir))
        .map(|s| s.trim().to_string())
        .unwrap_or_default();
    let stamp = format!(
        "{}\nBuilt: {}\n",
        build_ver,
        chrono_compat_utc()
    );
    let _ = std::fs::write(format!("{}lsl-build.txt", root), stamp);
    copied.push("lsl-build.txt".into());

    if copied.is_empty() {
        return Err("No lsl files found in bundle; nothing was copied.".into());
    }
    add_safe_boot_entry(vol_letter);
    out::info(&format!("Copied to {} : {}", root, copied.join(", ")));
    Ok(())
}

/// UTC timestamp without chrono (this format is stable and easy to generate).
fn chrono_compat_utc() -> String {
    // std::time gives us the epoch; format YYYY-MM-DD HH:MM:SS UTC by hand.
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let days = secs / 86400;
    let tod = secs % 86400;
    let (y, m, d) = civil_from_days(days as i64);
    format!(
        "{:04}-{:02}-{:02} {:02}:{:02}:{:02} UTC",
        y,
        m,
        d,
        tod / 3600,
        (tod % 3600) / 60,
        tod % 60
    )
}

fn civil_from_days(z: i64) -> (i64, u32, u32) {
    // Howard Hinnant's civil_from_days
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

/// Add-SafeBootEntry: clone the first Mint menuentry/label with the original
/// initrd, appending a "(safe)" variant.
pub fn add_safe_boot_entry(vol_letter: &str) {
    let root = format!("{}:\\", vol_letter);
    let safe = format!("{}casper\\initrd.safe.lz", root);
    if !path_exists(&safe) {
        return; // no safe initrd shipped -> nothing to offer
    }
    // GRUB (UEFI)
    let grub = format!("{}boot\\grub\\grub.cfg", root);
    if path_exists(&grub) {
        if let Ok(txt) = std::fs::read_to_string(&grub) {
            if !txt.contains("initrd.safe.lz") {
                if let Some(orig) = find_menuentry(&txt) {
                    let safe_entry = orig
                        .replacen("initrd /casper/initrd.lz", "initrd /casper/initrd.safe.lz", 1)
                        .replacen("menuentry \"", "menuentry \"(safe) ", 1);
                    let _ = std::fs::OpenOptions::new()
                        .append(true)
                        .open(&grub)
                        .and_then(|mut f| std::io::Write::write_all(&mut f, format!("\n{}\n", safe_entry).as_bytes()));
                    out::info("Added safe-boot GRUB entry (original initrd, no HDD mirror).");
                }
            }
        } else {
            out::warn("Could not add safe-boot GRUB entry (non-fatal).");
        }
    }
    // ISOLINUX (BIOS)
    let mut live = format!("{}isolinux\\live.cfg", root);
    if !path_exists(&live) {
        live = format!("{}isolinux\\isolinux.cfg", root);
    }
    if path_exists(&live) {
        if let Ok(txt) = std::fs::read_to_string(&live) {
            if !txt.contains("initrd.safe.lz") {
                if let Some(orig) = find_label_live(&txt) {
                    let safe_label = orig
                        .replacen("label live", "label safe", 1)
                        .replacen("menu label", "menu label ^Safe: original initrd (no HDD mirror)", 1)
                        .replacen("initrd /casper/initrd.lz", "initrd /casper/initrd.safe.lz", 1);
                    let _ = std::fs::OpenOptions::new()
                        .append(true)
                        .open(&live)
                        .and_then(|mut f| std::io::Write::write_all(&mut f, format!("\n{}\n", safe_label).as_bytes()));
                    out::info("Added safe-boot ISOLINUX entry (original initrd, no HDD mirror).");
                }
            }
        } else {
            out::warn("Could not add safe-boot ISOLINUX entry (non-fatal).");
        }
    }
}

fn find_menuentry(txt: &str) -> Option<String> {
    // menuentry "..." --class linuxmint { ... initrd /casper/initrd.lz ... }
    let start = txt.find("menuentry \"")?;
    let rest = &txt[start..];
    let end_marker = "initrd /casper/initrd.lz";
    let rel = rest.find(end_marker)? + end_marker.len();
    // close over the closing brace
    let seg = &rest[..rel];
    let close = seg.rfind('}')?;
    Some(seg[..=close].to_string())
}

fn find_label_live(txt: &str) -> Option<String> {
    let start = txt.find("label live")?;
    let rest = &txt[start..];
    let end_marker = "initrd /casper/initrd.lz";
    let rel = rest.find(end_marker)? + end_marker.len();
    Some(rest[..rel].trim_end().to_string())
}

// ---------------------------------------------------------------------------
// Copy-SfsToHdd
// ---------------------------------------------------------------------------
pub fn copy_sfs_to_hdd(vol_letter: &str, data_dir: &str) {
    copy_sfs_to_hdd_with_progress(vol_letter, data_dir, &mut |_, _, _| {});
}

/// Copy squashfs layers to the HDD with live progress. Skips files that are
/// already present with the same size (idempotent re-runs). `progress` is
/// called before each file with `(name, 0, total)`, during the copy with
/// `(name, done, total)`, and after with `(name, total, total)`.
pub fn copy_sfs_to_hdd_with_progress<F>(vol_letter: &str, data_dir: &str, progress: &mut F)
where
    F: FnMut(&str, u64, u64),
{
    if data_dir.is_empty() {
        return;
    }
    let src_root = format!("{}:\\", vol_letter);
    let dest = format!("{}\\sfs", data_dir);
    sys::create_dir_all(&dest);
    let casper_path = format!("{}casper", src_root);

    let mut bases: Vec<String> = vec![
        "filesystem_z0_firstboot.squashfs".into(),
        "filesystem.squashfs".into(),
        "home.sfs".into(),
    ];
    // any appended filesystem_z*.squashfs layers
    let w = sys::wide(&format!("{}\\filesystem_*.squashfs", casper_path));
    unsafe {
        let mut fd: winapi::um::minwinbase::WIN32_FIND_DATAW = std::mem::zeroed();
        let h = winapi::um::fileapi::FindFirstFileW(w.as_ptr(), &mut fd);
        if h != winapi::um::handleapi::INVALID_HANDLE_VALUE {
            loop {
                let name = sys::from_wide(&fd.cFileName);
                if name != "." && name != ".." {
                    bases.push(name);
                }
                if winapi::um::fileapi::FindNextFileW(h, &mut fd) == 0 {
                    break;
                }
            }
            winapi::um::fileapi::FindClose(h);
        }
    }
    bases.sort();
    bases.dedup();

    let mut copied = 0;
    let mut skipped = 0;
    let mut manifest = vec![
        "# LSL squashfs layers copied to HDD for faster boot".to_string(),
        format!("SourceUSB={}:", vol_letter),
        format!("Date={}", now_u_string()),
    ];
    for base in &bases {
        let s = if base == "home.sfs" {
            format!("{}home.sfs", src_root)
        } else {
            format!("{}\\{}", casper_path, base)
        };
        if !path_exists(&s) {
            continue;
        }
        // casper's multi-layer LAYERFS_PATH chain stacks filesystem.z0 over
        // filesystem, so the firstboot layer is renamed on copy.
        let dname = if base.starts_with("filesystem_z") && base.ends_with("_firstboot.squashfs") {
            "filesystem.z0.squashfs".to_string()
        } else {
            base.clone()
        };
        let d = format!("{}\\{}", dest, dname);
        let sz = file_size(&s).unwrap_or(0);
        // Idempotency: skip if already on HDD with matching size.
        if path_exists(&d) && file_size(&d).unwrap_or(0) == sz && sz > 0 {
            skipped += 1;
            progress(&dname, sz, sz);
            // Still include in manifest so a partial run leaves a valid file.
            match sha256_file(&s) {
                Some(hash) => manifest.push(format!("{}={} sha256:{}", dname, sz, hash)),
                None => manifest.push(format!("{}={}", dname, sz)),
            }
            out::info(&format!("  skipped {} (already on HDD, {} bytes)", dname, sz));
            continue;
        }
        progress(&dname, 0, sz);
        let copy_ok = if sz > 256 * sys::MB {
            // Large files: use the progress-aware copy so the GUI bar stays live.
            sys::copy_file_with_progress(&s, &d, |done, total| {
                progress(&dname, done, total);
            })
        } else {
            sys::copy_file(&s, &d)
        };
        if copy_ok.is_ok() {
            copied += 1;
            progress(&dname, sz, sz);
            match sha256_file(&s) {
                Some(hash) => manifest.push(format!("{}={} sha256:{}", dname, sz, hash)),
                None => manifest.push(format!("{}={}", dname, sz)),
            }
            out::info(&format!("  copied {} -> {} ({} bytes) -> {}", base, dname, sz, dest));
        }
    }
    let _ = std::fs::write(format!("{}\\manifest.txt", dest), manifest.join("\r\n"));

    // Flip the env flag so lsl-precache.sh uses the HDD copies.
    let env_file = format!("{}lsl-usb.env", src_root);
    if path_exists(&env_file) {
        env_file_set(&env_file, "LSL_SFS_HDD_CACHE", "1");
        out::info("Set LSL_SFS_HDD_CACHE=1 in lsl-usb.env");
    }
    if copied > 0 && skipped > 0 {
        out::info(&format!(
            "Copied {} + skipped {} layer file(s) to {} (used for faster page-cache warm).",
            copied, skipped, dest
        ));
    } else if copied > 0 {
        out::info(&format!(
            "Copied {} layer file(s) to {} (used for faster page-cache warm).",
            copied, dest
        ));
    } else if skipped > 0 {
        out::info(&format!(
            "All {} layer file(s) already on {} (nothing to copy).",
            skipped, dest
        ));
    } else {
        out::warn("No squashfs layers found on the USB to copy.");
    }
}

fn now_u_string() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let days = (secs / 86400) as i64;
    let tod = secs % 86400;
    let z = days + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = (z - era * 146097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let y2 = if m <= 2 { y + 1 } else { y };
    format!(
        "{:04}-{:02}-{:02} {:02}:{:02}:{:02} UTC",
        y2, m, d, tod / 3600, (tod % 3600) / 60, tod % 60
    )
}

// ---------------------------------------------------------------------------
// Install-RustTools: fd / bat / zoxide musl assets from GitHub. The asset
// architecture MUST match the selected distro (i686 for antiX / Tiny
// CorePlus, x86_64 for the 64-bit distros) — a 32-bit binary is useless on
// a 64-bit live system.
// ---------------------------------------------------------------------------
pub fn install_rust_tools(vol_letter: &str, arch: &str) {
    let root = format!("{}:\\", vol_letter);
    let bin_dir = format!("{}bin", root);
    sys::create_dir_all(&bin_dir);

    let asset_sub = format!("{}-unknown-linux-musl", arch);
    let tools: Vec<(&str, String, &str)> = vec![
        ("sharkdp/fd", asset_sub.clone(), "fd"),
        ("sharkdp/bat", asset_sub.clone(), "bat"),
        ("ajeetdsouza/zoxide", asset_sub.clone(), "zoxide"),
    ];

    for (repo, asset_sub, bin) in tools {
        let dest = format!("{}\\{}", bin_dir, bin);
        if let Some(sz) = file_size(&dest) {
            out::info(&format!("  {}: already on USB ({} KB)", bin, sz / 1024));
            continue;
        }
        out::info(&format!(
            "  {}: resolving latest {} release asset...",
            bin, repo
        ));
        let rel_url = format!("https://api.github.com/repos/{}/releases/latest", repo);
        let json = match crate::net::get(&rel_url, crate::net::user_agent()) {
            Ok(r) if r.status == 200 => String::from_utf8_lossy(&r.body).into_owned(),
            Ok(r) => {
                out::warn(&format!("  {}: GitHub API HTTP {} - run bin/lsl-rusttools.sh on the live USB to fetch it later.", bin, r.status));
                continue;
            }
            Err(e) => {
                out::warn(&format!(
                    "  {}: direct download failed ({}) - run bin/lsl-rusttools.sh on the live USB to fetch it later.",
                    bin, e
                ));
                continue;
            }
        };
        let names = crate::rufus::json_strings_for_tests(&json, "name");
        let urls = crate::rufus::json_strings_for_tests(&json, "browser_download_url");
        let asset = names
            .iter()
            .zip(urls.iter())
            .find(|(n, _)| n.contains(asset_sub.as_str()) && n.ends_with(".tar.gz"))
            .map(|(n, u)| (n.clone(), u.clone()));
        let Some((asset_name, asset_url)) = asset else {
            out::warn(&format!("  {}: no {} .tar.gz asset - run bin/lsl-rusttools.sh on the live USB to fetch it later.", bin, asset_sub));
            continue;
        };
        let tmp = format!("{}\\{}", sys::temp_dir(), asset_name);
        match crate::net::download_to_file(&asset_url, &tmp, crate::net::user_agent(), &mut |_| {}) {
            Ok(n) if n > 0 => {
                // Extract the named binary from the tarball and verify it is a
                // real ELF (tag is user-supplied, so never trust it blindly).
                let extract_dir = format!("{}\\lsl-{}-extract", sys::temp_dir(), bin);
                let _ = std::fs::remove_dir_all(&extract_dir);
                sys::create_dir_all(&extract_dir);
                match extract_tar_gz_binary(&tmp, bin, &dest) {
                    Ok(sz) => {
                        out::info(&format!("  {}: downloaded {} -> {} ({} KB)", bin, asset_name, dest, sz / 1024));
                    }
                    Err(e) => {
                        sys::delete_file(&dest);
                        out::warn(&format!("  {}: extraction failed ({}).", bin, e));
                    }
                }
                let _ = std::fs::remove_dir_all(&extract_dir);
                sys::delete_file(&tmp);
            }
            Ok(_) => {
                sys::delete_file(&dest);
                out::warn(&format!("  {}: empty download - run bin/lsl-rusttools.sh on the live USB later.", bin));
            }
            Err(e) => {
                out::warn(&format!(
                    "  {}: direct download failed ({}) - run bin/lsl-rusttools.sh on the live USB to fetch it later.",
                    bin, e
                ));
            }
        }
    }
}

/// Extract the file named `bin` from a .tar.gz archive and copy it to `dest`,
/// verifying the ELF magic (in-process: no tar.exe dependency — Windows 10's
/// bundled tar does not exist on older Windows).
fn extract_tar_gz_binary(archive: &str, bin: &str, dest: &str) -> Result<u64, String> {
    let f = std::fs::File::open(archive).map_err(|e| e.to_string())?;
    let gz = flate2::read::GzDecoder::new(f);
    let mut tar = tar::Archive::new(gz);
    for entry in tar.entries().map_err(|e| e.to_string())? {
        let mut entry = entry.map_err(|e| e.to_string())?;
        if !entry.header().entry_type().is_file() {
            continue;
        }
        let name = entry
            .path()
            .map_err(|e| e.to_string())?
            .file_name()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_default();
        if name == bin {
            let mut bytes = Vec::new();
            entry.read_to_end(&mut bytes).map_err(|e| e.to_string())?;
            if bytes.len() < 4 || bytes[0..4] != [0x7f, b'E', b'L', b'F'] {
                return Err(format!("'{}' is not an ELF binary", bin));
            }
            std::fs::write(dest, &bytes).map_err(|e| e.to_string())?;
            return Ok(bytes.len() as u64);
        }
    }
    Err(format!("binary '{}' not found in {}", bin, archive))
}

// ---------------------------------------------------------------------------
// Write-FlatpakRefs
// ---------------------------------------------------------------------------
pub fn write_flatpak_refs(vol_letter: &str, extra: &[String]) {
    let sugg = crate::hardware::flatpak_suggestions();
    let mut ids: Vec<String> = sugg
        .iter()
        .filter(|(_, _, m)| *m)
        .map(|(_, id, _)| id.clone())
        .collect();
    for e in extra {
        if !e.is_empty() && !ids.iter().any(|i| i.eq_ignore_ascii_case(e)) {
            ids.push(e.clone());
        }
    }
    if ids.is_empty() {
        out::warn("No flatpak suggestions (no matching installed Windows apps).");
        return;
    }
    let dir = format!("{}:\\flatpaks", vol_letter);
    sys::create_dir_all(&dir);
    for id in &ids {
        let ref_path = format!("{}\\{}.flatpakref", dir, id);
        let url = format!("https://dl.flathub.org/repo/appstream/{}.flatpakref", id);
        match crate::net::download_to_file(&url, &ref_path, crate::net::user_agent(), &mut |_| {}) {
            Ok(n) if n > 0 => out::info(&format!("  wrote {}.flatpakref", id)),
            _ => {
                sys::delete_file(&ref_path);
                out::warn(&format!("  could not fetch {}.flatpakref", id));
            }
        }
    }
    out::info(&format!(
        "Flatpak refs in {} - first boot runs 'flatpak install --from' on each.",
        dir
    ));
}

// ---------------------------------------------------------------------------
// Everything (voidtools) integration
// ---------------------------------------------------------------------------
pub fn everything_path() -> String {
    // PATH candidates, then common install locations.
    if let Some(paths) = sys::env_var("PATH") {
        for dir in paths.split(';') {
            let c = format!("{}\\es.exe", dir);
            if path_exists(&c) {
                return c;
            }
        }
    }
    let bases = [
        sys::env_var("ProgramFiles"),
        sys::env_var("ProgramFiles(x86)"),
        Some(sys::local_app_data()),
    ];
    for b in bases.iter().flatten() {
        let c = format!("{}\\Everything\\es.exe", b);
        if path_exists(&c) {
            return c;
        }
    }
    String::new()
}

pub fn install_everything() -> String {
    let dir = format!("{}\\lsl-usb\\tools\\Everything", sys::local_app_data());
    let es = format!("{}\\es.exe", dir);
    if path_exists(&es) {
        return es;
    }
    let zip_path = format!("{}\\Everything-portable.zip", sys::temp_dir());
    let url = "https://www.voidtools.com/Everything-1.4.1.1026.x64.zip";
    out::info("Downloading Everything (voidtools) portable...");
    if let Err(e) = crate::net::download_to_file(url, &zip_path, crate::net::user_agent(), &mut |_| {}) {
        out::warn(&format!("Everything download failed: {}", e));
        return String::new();
    }
    let _ = std::fs::create_dir_all(&dir);
    if let Err(e) = unzip(&zip_path, &dir) {
        out::warn(&format!("Everything extraction failed: {}", e));
        return String::new();
    }
    sys::delete_file(&zip_path);
    if !path_exists(&es) {
        out::warn("Everything portable did not contain es.exe.");
        return String::new();
    }
    // Trust anchor: Authenticode-signed by voidtools (graceful where wintrust
    // is unavailable — that path asks for explicit confirmation).
    let exe = format!("{}\\Everything.exe", dir);
    if path_exists(&exe) && !crate::rufus::verify_everything_signature(&exe, "voidtools") {
        out::warn("Everything.exe failed Authenticode verification (publisher: voidtools expected).");
        return String::new();
    }
    // Launch it so the index builds in the background.
    if path_exists(&exe) {
        let _ = sys::spawn(&exe, &[]);
        out::info(&format!(
            "Everything installed to {} - its index is building in the background (es.exe works once ready).",
            dir
        ));
    }
    es
}

pub fn unzip(zip_path: &str, dest: &str) -> Result<(), String> {
    let f = std::fs::File::open(zip_path).map_err(|e| e.to_string())?;
    let mut z = zip::ZipArchive::new(std::io::BufReader::new(f)).map_err(|e| e.to_string())?;
    for i in 0..z.len() {
        let mut entry = z.by_index(i).map_err(|e| e.to_string())?;
        let name = entry.name().to_string();
        let out_path = format!("{}\\{}", dest, name.replace('/', "\\"));
        if entry.is_dir() {
            sys::create_dir_all(&out_path);
        } else {
            if let Some(parent) = std::path::Path::new(&out_path).parent() {
                sys::create_dir_all(&parent.to_string_lossy());
            }
            let mut out_f = std::fs::File::create(&out_path).map_err(|e| e.to_string())?;
            std::io::copy(&mut entry, &mut out_f).map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

/// Write-EverythingEfu: export the index (EFU CSV) to the USB.
pub fn write_everything_efu(vol_letter: &str) {
    let es = everything_path();
    if es.is_empty() {
        out::warn("Everything not found; skipping EFU export.");
        return;
    }
    // Free-space check: the full index can be large.
    if let Some(v) = sys::list_volumes().into_iter().find(|v| v.letter.eq_ignore_ascii_case(vol_letter)) {
        if v.free < sys::GB {
            out::warn(&format!(
                "USB has only {} MB free - skipping the EFU export (it can be hundreds of MB).",
                v.free / sys::MB
            ));
            return;
        }
    }
    let dest = format!("{}:\\find_everything.efu", vol_letter);
    out::info("Exporting the Everything index - this may take a minute for large indexes...");
    match sys::spawn(&es, &["-export-efu".into(), dest.clone()]) {
        Ok(child) => {
            child.wait(600_000);
            if let Some(sz) = file_size(&dest) {
                out::info(&format!(
                    "Exported Everything index to find_everything.efu ({:.1} MB)",
                    sz as f64 / sys::MB as f64
                ));
            } else {
                out::warn("Everything export produced no file.");
            }
        }
        Err(e) => out::warn(&format!("Everything export failed: {}", e)),
    }
}

// ---------------------------------------------------------------------------
// ISO discovery: Everything index, then filesystem fallback (Find-LocalIsos)
// ---------------------------------------------------------------------------
pub fn find_everything_isos() -> Vec<String> {
    let es = everything_path();
    if es.is_empty() {
        return Vec::new();
    }
    let Some((code, raw)) = sys::capture(&es, &["-sort".into(), "date-modified-descending".into(), "*.iso".into()]) else {
        return Vec::new();
    };
    if code != 0 {
        return Vec::new(); // Everything index not available
    }
    let mut paths = Vec::new();
    for line in raw.lines() {
        let l = line.trim();
        let is_abs = l.len() > 2 && l.as_bytes()[1] == b':' && (l.as_bytes()[2] == b'\\' || l.as_bytes()[2] == b'/');
        if is_abs && l.to_lowercase().ends_with(".iso") && !paths.iter().any(|p: &String| p.eq_ignore_ascii_case(l)) {
            paths.push(l.to_string());
            if paths.len() >= 20 {
                break;
            }
        }
    }
    // Drop empty (0-byte) ISOs - partial/corrupt downloads can never boot.
    paths.retain(|p| file_size(p).unwrap_or(0) > 0);
    paths
}

pub fn find_local_isos() -> Vec<String> {
    let mut dirs = Vec::new();
    if let Some(p) = sys::user_profile() {
        dirs.push(format!("{}\\Downloads", p));
    }
    dirs.push(format!("{}\\Downloads", sys::local_app_data()));
    dirs.push("C:\\ISO".into());
    dirs.push("D:\\ISO".into());
    dirs.push("C:\\Images".into());
    dirs.push("D:\\Images".into());
    let mut hits: Vec<(String, u64)> = Vec::new();
    for d in dirs {
        let w = sys::wide(&format!("{}\\*.iso", d));
        unsafe {
            let mut fd: winapi::um::minwinbase::WIN32_FIND_DATAW = std::mem::zeroed();
            let h = winapi::um::fileapi::FindFirstFileW(w.as_ptr(), &mut fd);
            if h == winapi::um::handleapi::INVALID_HANDLE_VALUE {
                // Win95: FindFirstFileW is a no-op stub; fall back to ANSI.
                for (name, size) in sys::list_files_ansi(&format!("{}\\*.iso", d)) {
                    if size > 0 {
                        hits.push((format!("{}\\{}", d, name), size));
                    }
                }
                continue;
            }
            loop {
                let name = sys::from_wide(&fd.cFileName);
                if name != "." && name != ".." {
                    let full = format!("{}\\{}", d, name);
                    let size = ((fd.nFileSizeHigh as u64) << 32) | fd.nFileSizeLow as u64;
                    if size > 0 {
                        hits.push((full, size));
                    }
                }
                if winapi::um::fileapi::FindNextFileW(h, &mut fd) == 0 {
                    break;
                }
            }
            winapi::um::fileapi::FindClose(h);
        }

    }
    // sort newest first is impossible without full timestamps sorting; keep
    // the simple name ordering and cap at 20 like the PS version.
    hits.sort_by(|a, b| a.0.cmp(&b.0));
    hits.into_iter().map(|(p, _)| p).take(20).collect()
}

#[cfg(test)]
mod firstboot_toolkit_tests {
    use super::*;

    #[test]
    fn toolkit_embeds_lf_clean_scripts() {
        assert!(!FIRSTBOOT_TOOLKIT.is_empty());
        for (rel, content) in FIRSTBOOT_TOOLKIT {
            assert!(!content.is_empty(), "{} embedded empty", rel);
            // The write path LF-normalizes (working-tree checkouts may be
            // CRLF); the normalized form is what the guest executes.
            let lf = content.replace("\r\n", "\n");
            assert!(!lf.contains('\r'), "{} contains CR after normalize", rel);
        }
        let ups = FIRSTBOOT_TOOLKIT.iter().find(|(r, _)| *r == "bin\\uproot");
        assert!(ups.is_some());
        assert!(ups.unwrap().1.replace("\r\n", "\n").starts_with("#!/bin/bash\n"));
    }

    #[test]
    fn z0_blob_is_shippable_squashfs() {
        // Rebuild via misc/build-z0.sh whenever misc/ changes; this blob is
        // what the nofmt installer drops as casper/filesystem.z0.squashfs.
        assert!(Z0_BLOB.len() >= 4096 && Z0_BLOB.len() <= 1 << 20, "z0 size implausible: {}", Z0_BLOB.len());
        assert_eq!(&Z0_BLOB[0..4], &[0x68, 0x73, 0x71, 0x73], "z0 must start with hsqs magic");
    }
}
