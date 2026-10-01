//! lsl-usb file drop + env manipulation + driver/rusttool/flatpak/EFU staging
//! (Install-LslFiles, Add-SafeBootEntry, Copy-SfsToHdd, Install-RustTools,
//! Write-FlatpakRefs, Write-EverythingEfu, Install-Everything equivalents).

use crate::sys::{self, file_size, out, path_exists};
use sha2::{Digest, Sha256};
use std::io::{Read, Write};

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

/// Hash a layer file for the manifest with live progress: a silent multi-GB
/// SHA-256 over USB looks exactly like a freeze (no bar movement, no pump,
/// no console output), so every 1 MB chunk reports through `progress` - the
/// caller's closure already pumps the GUI on each call.
fn hash_for_manifest<F>(s: &str, dname: &str, progress: &mut F) -> Option<String>
where
    F: FnMut(&str, u64, u64, SfsPhase),
{
    match sha256_file_progress(s, &mut |done, total| {
        progress(dname, done, total, SfsPhase::Hashing);
        true
    }) {
        Ok(HashResult::Hash(h)) => Some(h),
        _ => None,
    }
}

/// Parse an existing manifest.txt into `(name, size, sha256)` rows so a
/// re-run can reuse a layer's recorded hash instead of re-reading the whole
/// file. Comment/header lines (`#`, `SourceUSB`, `Date`) are skipped, as are
/// rows with no `sha256:` field.
fn read_manifest_hashes(path: &str) -> Vec<(String, u64, Option<String>)> {
    let mut rows = Vec::new();
    let Ok(text) = std::fs::read_to_string(path) else {
        return rows;
    };
    for line in text.lines() {
        let Some(eq) = line.find('=') else { continue };
        let name = &line[..eq];
        if name.is_empty() || name.starts_with('#') || name == "SourceUSB" || name == "Date" {
            continue;
        }
        let rest = &line[eq + 1..];
        let size = rest
            .split_whitespace()
            .next()
            .and_then(|s| s.parse::<u64>().ok())
            .unwrap_or(0);
        let sha = rest
            .split("sha256:")
            .nth(1)
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string);
        rows.push((name.to_string(), size, sha));
    }
    rows
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
    // Boot telemetry: /etc/xdg/autostart/lsl-boot-time.desktop (z0 layer)
    // execs /cdrom/bin/lsl-boot-time.sh --desktop; shipping it was the
    // missing half of the "boot telemetry" work - without it the autostart
    // silently fails and boot-times.log never exists (2026-09-21 post-mortem).
    ("bin\\lsl-boot-time.sh", include_str!("../../../bin/lsl-boot-time.sh")),
    ("bin\\lsl-mount-home.sh", include_str!("../../../bin/lsl-mount-home.sh")),
    // Shutdown chain: lsl-shutdown-gui resolves uphome via PATH or
    // /cdrom/bin/uphome, and uphome execs lsl-flush-home.sh in USB mode.
    // The nofmt installer writes /cdrom/bin from this array only, so
    // both must be embedded or shutdown errors "Could not find 'uphome'"
    // (2026-09-22: it was missing from the stick entirely).
    ("bin\\uphome", include_str!("../../../bin/uphome")),
    ("bin\\lsl-flush-home.sh", include_str!("../../../bin/lsl-flush-home.sh")),
    // "Load to RAM + remove USB" in lsl-shutdown-gui runs this; the same
    // reasoning as uphome above applies (2026-09-28: it was never embedded,
    // so the option could only ever error "lsl-toram.sh not found" on a
    // nofmt-built stick).
    ("bin\\lsl-toram.sh", include_str!("../../../bin/lsl-toram.sh")),
    // Desktop + autostart + onboot payload (2026-09-22 post-mortems): the
    // nofmt installer writes /cdrom/bin from this array only, so every
    // script the boot references must be embedded -
    //   config.sh desktop entries  -> lsl-gui, lsl-tui, lsl-shutdown-gui
    //   config.sh autostart entries -> lsl-pin-favorites, lsl-home-readonly-warning
    //   onboot.sh (unconditional)  -> mount_all.sh
    //   reclaim service ExecStart   -> lsl-reclaim-win-swap.sh
    //   onboot.sh (-r gated)        -> clean-old-system-patches.sh, wsl-boot-setup
    ("bin\\lsl-gui", include_str!("../../../bin/lsl-gui")),
    ("bin\\lsl-tui", include_str!("../../../bin/lsl-tui")),
    ("bin\\lsl-shutdown-gui", include_str!("../../../bin/lsl-shutdown-gui")),
    ("bin\\mount_all.sh", include_str!("../../../bin/mount_all.sh")),
    ("bin\\lsl-pin-favorites", include_str!("../../../bin/lsl-pin-favorites")),
    ("bin\\lsl-home-readonly-warning", include_str!("../../../bin/lsl-home-readonly-warning")),
    ("bin\\lsl-reclaim-win-swap.sh", include_str!("../../../bin/lsl-reclaim-win-swap.sh")),
    ("bin\\clean-old-system-patches.sh", include_str!("../../../bin/clean-old-system-patches.sh")),
    ("bin\\wsl-boot-setup", include_str!("../../../bin/wsl-boot-setup")),
    ("bin\\lsl-ramclone-status", include_str!("../../../bin/lsl-ramclone-status")),
    ("bin\\lsl-ramclone-eject", include_str!("../../../bin/lsl-ramclone-eject")),
    ("systemd\\onboot.service", include_str!("../../../systemd/onboot.service")),
    ("systemd\\lsl-home.service", include_str!("../../../systemd/lsl-home.service")),
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
    // misc/kitty.conf: config.sh's install_lsl_kitty_conf reads it from
    // $REPO_ROOT/misc/ at first-boot and silently skips when it is absent
    // (there is only a debug-level log). On a nofmt-built stick REPO_ROOT is
    // /cdrom and misc/ is never staged - the nofmt installer writes /cdrom
    // from FIRSTBOOT_TOOLKIT only - so without this entry the terminal is
    // installed (kitty ships in the base image) but never configured, and
    // kitty launches with its own defaults instead of the Windows-Terminal
    // look. The file must also PARSE: kitty shows an "Errors parsing
    // configuration" dialog and never becomes usable when a value is invalid
    // (e.g. the old `tab_powerline_style no`), which reads as "kitty won't
    // start".
    ("misc\\kitty.conf", include_str!("../../../misc/kitty.conf")),
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

/// Embedded z0 firstboot layer (casper/filesystem_z0_firstboot.squashfs).
///
/// Built from misc/ by misc/build-z0.sh (mksquashfs, WSL) and committed
/// beside the other embedded assets; the nofmt installer has no mksquashfs
/// on Windows, so it ships this blob instead of building it. Rebuild
/// whenever misc/ changes - the blob carries lsl-firstboot.service, and a
/// stale blob means a stale firstboot. build.rs re-hashes each packed source
/// against assets/z0_sources.sha256 (written by build-z0.sh) and fails the
/// build when misc/ has drifted, so a stale blob can no longer ship
/// (WHYFAIL10). Content-proven in QEMU (layer stacks base+stub+appended,
/// firstboot stamps, relayer boots Brave/nvim).
static Z0_BLOB: &[u8] = include_bytes!("../assets/filesystem.z0.squashfs");

/// Write the embedded z0 layer to casper\ on the stick (always overwrite:
/// 12 KB, and this guarantees the firstboot service stays fresh). The name
/// is the underscore form so casper's alphabetical glob stacks it above the
/// base and below every appended layer; a missing/stale stub is a boot
/// failure, not a warning.
pub fn install_z0_layer(root: &str) -> Result<u64, String> {
    let dest = format!(
        "{}\\casper\\filesystem_z0_firstboot.squashfs",
        root.trim_end_matches('\\')
    );
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

    // 1) the (minimal) root layer - casper's *.squashfs glob stacks it over
    // the base image. Layer ORDER is alphabetical, so the stub's name must
    // sort above "filesystem.squashfs" ("_" 0x5F > "." 0x2E) and below every
    // appended layer ("filesystem_z<ts>" > "filesystem_z0_firstboot").
    // Legacy bundle path (install.ps1 parity): a build.sh bundle ships
    // filesystem_z0_firstboot.squashfs next to the exe. The nofmt path
    // already wrote the embedded equivalent before we get here, so don't warn
    // then - and never leave the stick without a stub layer: fall back to the
    // embedded blob when the bundle file is absent.
    //
    // There is deliberately only ONE name now. The dotted twin
    // (filesystem.z0.squashfs) existed solely so `layerfs-path=` could name
    // the dot-walk entry point; with no layerfs-path= on the cmdline, a
    // second copy sorted into the wrong slot and shadowed the appended
    // layers (see WHYFAIL14).
    let layer = format!("{}\\filesystem_z0_firstboot.squashfs", bundle_dir);
    let dest = format!("{}\\filesystem_z0_firstboot.squashfs", casper);
    if path_exists(&layer) {
        sys::copy_file(&layer, &dest)
            .map_err(|e| format!("copy layer: {}", e))?;
        copied.push("filesystem_z0_firstboot.squashfs".into());
    } else if path_exists(&dest) {
        out::info("z0 firstboot layer already present on the stick (embedded install); skipping bundle layer copy.");
    } else {
        match install_z0_layer(&root) {
            Ok(_) => copied.push("filesystem_z0_firstboot.squashfs (embedded)".into()),
            Err(e) => out::warn(&format!("filesystem_z0_firstboot.squashfs not found in bundle and embedded z0 install failed ({}); layer not copied.", e)),
        }
    }

    // 2) the FAT-side lsl scripts (same set as bin/config.sh --sync-only).
    //    "misc" carries kitty.conf, which bin/config.sh installs into the
    //    desktop user's ~/.config/kitty at first boot; without it the copy is
    //    skipped and kitty runs with its built-in defaults.
    for d in ["bin", "systemd", "initramfs", "misc"] {
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

    // casper-md5check.service (stock Mint/Ubuntu live) verifies /cdrom against
    // /cdrom/md5sum.txt. A stock ISO ships that file; this stick does not - its
    // layout is deliberately not the ISO's (kernel/initrd live under /_ISO,
    // extra squashfs layers are added), so the service fails on every boot with
    // an alarming "Failed to start casper-md5check Verify Live ISO checksums".
    // An empty md5sum.txt makes the check trivially succeed; the ISO checksums
    // cannot apply to a different file layout anyway.
    let _ = std::fs::write(format!("{}md5sum.txt", root), b"");
    copied.push("md5sum.txt".into());

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
    copy_sfs_to_hdd_with_progress(vol_letter, data_dir, &mut |_, _, _, _| {});
}

/// Which sub-step of the squashfs-to-HDD copy is reporting progress, so
/// status text can name the actual operation. When a layer has to be hashed,
/// the manifest hash makes a second 0→100% sweep over the same file after its
/// copy sweep; a layer whose hash is reused from a prior manifest reports a
/// single completed Hashing tick instead.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum SfsPhase {
    Copying,
    Hashing,
}

/// Copy squashfs layers to the HDD with live progress. Skips files that are
/// already present with the same size (idempotent re-runs); a skipped layer
/// keeps the hash recorded in the existing manifest.txt rather than re-reading
/// it, so an unchanged squashfs is not re-hashed on every run. `progress` is
/// called before each file with `(name, 0, total, phase)`, during the copy
/// and the manifest hash with `(name, done, total, phase)`, and after with
/// `(name, total, total, phase)`.
pub fn copy_sfs_to_hdd_with_progress<F>(vol_letter: &str, data_dir: &str, progress: &mut F)
where
    F: FnMut(&str, u64, u64, SfsPhase),
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
        // Beacon must match bin/lsl-copy-sfs-hdd.sh and initramfs/lsl_hdd_mirror.sh.
        // This copy path stages the RAW layers only (Windows has no mksquashfs);
        // the Linux-side builder overlays them into the merged layer the
        // initrd hook actually boots.
        "# LSL squashfs layers copied to HDD for faster boot".to_string(),
        format!("SourceUSB={}:", vol_letter),
        format!("Date={}", now_u_string()),
    ];
    // Hashes recorded by a previous run, so skipped layers can reuse them.
    let prior_hashes = read_manifest_hashes(&format!("{}\\manifest.txt", dest));
    for base in &bases {
        let s = if base == "home.sfs" {
            format!("{}home.sfs", src_root)
        } else {
            format!("{}\\{}", casper_path, base)
        };
        if !path_exists(&s) {
            continue;
        }
        // Mirror files keep their on-stick names - no renaming. The raw
        // layers are the INPUTS to the pre-merge that bin/lsl-copy-sfs-hdd.sh
        // runs on the Linux side (Windows has no mksquashfs); that merge
        // produces the single dot-free layer the initrd hook points
        // LAYERFS_PATH at. See WHYFAIL14.
        let dname = base.clone();
        let d = format!("{}\\{}", dest, dname);
        let sz = file_size(&s).unwrap_or(0);
        // Idempotency: skip if already on HDD with matching size.
        if path_exists(&d) && file_size(&d).unwrap_or(0) == sz && sz > 0 {
            skipped += 1;
            // The layer bytes did not change (same size, not re-copied), so
            // reuse the hash the previous manifest recorded for it instead of
            // re-reading the multi-GB source over USB just to rebuild the same
            // value. Fall back to hashing only when there is no prior entry.
            let hash = match prior_hashes
                .iter()
                .find(|(n, s, _)| n == &dname && *s == sz)
                .and_then(|(_, _, h)| h.clone())
            {
                Some(h) => Some(h),
                None => {
                    if sz > 256 * sys::MB {
                        out::info(&format!("  hashing {} for manifest...", dname));
                    }
                    hash_for_manifest(&s, &dname, progress)
                }
            };
            progress(&dname, sz, sz, SfsPhase::Hashing);
            match hash {
                Some(hash) => manifest.push(format!("{}={} sha256:{}", dname, sz, hash)),
                None => manifest.push(format!("{}={}", dname, sz)),
            }
            out::info(&format!("  skipped {} (already on HDD, {} bytes)", dname, sz));
            continue;
        }
        progress(&dname, 0, sz, SfsPhase::Copying);
        let copy_ok = if sz > 256 * sys::MB {
            // Large files: use the progress-aware copy so the GUI bar stays live.
            sys::copy_file_with_progress(&s, &d, |done, total| {
                progress(&dname, done, total, SfsPhase::Copying);
            })
        } else {
            sys::copy_file(&s, &d)
        };
        if copy_ok.is_ok() {
            copied += 1;
            progress(&dname, sz, sz, SfsPhase::Copying);
            if sz > 256 * sys::MB {
                out::info(&format!("  hashing {} for manifest...", dname));
            }
            match hash_for_manifest(&s, &dname, progress) {
                Some(hash) => manifest.push(format!("{}={} sha256:{}", dname, sz, hash)),
                None => manifest.push(format!("{}={}", dname, sz)),
            }
            out::info(&format!("  copied {} -> {} ({} bytes) -> {}", base, dname, sz, dest));
        }
    }
    // LF + trailing newline: lsl-copy-sfs-hdd.sh --verify parses this with
    // `while read` (drops a final unterminated line) and compares fields
    // where a stray CR breaks the size check.
    let _ = std::fs::write(format!("{}\\manifest.txt", dest), manifest.join("\n") + "\n");

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
        // Paired per asset object: a positional zip of two key scans
        // mis-pairs once the release title "name" shifts the names list.
        let asset = crate::rufus::github_asset_pairs(&json)
            .into_iter()
            .find(|(n, _)| n.contains(asset_sub.as_str()) && n.ends_with(".tar.gz"));
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
mod manifest_hash_progress_tests {
    use super::*;

    #[test]
    fn hash_for_manifest_reports_progress() {
        // Regression: the manifest hash used to be a silent multi-GB
        // re-read (no bar movement, no pump, no console output) that
        // looked exactly like a freeze. It must report per-chunk progress.
        let dir = std::env::temp_dir().join("lsl-hash-progress-test");
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("layer.bin");
        let chunk = vec![0xABu8; 1 << 20];
        let mut f = std::fs::File::create(&path).unwrap();
        for _ in 0..3 {
            f.write_all(&chunk).unwrap();
        }
        drop(f);
        let ps = path.to_string_lossy().into_owned();
        let mut calls: Vec<(u64, u64, SfsPhase)> = Vec::new();
        let got = hash_for_manifest(&ps, "layer.bin", &mut |_name: &str, done: u64, total: u64, phase| {
            calls.push((done, total, phase));
        });
        assert_eq!(got, sha256_file(&ps));
        assert!(got.is_some());
        assert!(!calls.is_empty(), "hash reported no progress");
        assert!(
            calls.iter().all(|(_, _, p)| *p == SfsPhase::Hashing),
            "manifest hash must report the Hashing phase so status text names the real operation"
        );
        assert_eq!(calls.last().unwrap(), &(3 << 20, 3 << 20, SfsPhase::Hashing));
        let mut prev = 0u64;
        for (done, total, _) in &calls {
            assert_eq!(*total, 3 << 20);
            assert!(*done >= prev, "progress went backwards");
            prev = *done;
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn read_manifest_hashes_parses_rows_and_skips_headers() {
        // Skipped layers reuse these hashes, so the parser must round-trip the
        // manifest rows and ignore the header/comment lines.
        let dir = std::env::temp_dir().join("lsl-manifest-parse-test");
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("manifest.txt");
        std::fs::write(
            &path,
            "# LSL squashfs layers copied to HDD for faster boot\n\
             SourceUSB=/dev/sdb1:\n\
             Date=2026-01-01 00:00:00 UTC\n\
             filesystem.squashfs=3411738624 sha256:deadbeef\n\
             home.sfs=12345\n",
        )
        .unwrap();
        let rows = read_manifest_hashes(&path.to_string_lossy());
        assert_eq!(rows.len(), 2);
        assert_eq!(
            rows[0],
            ("filesystem.squashfs".to_string(), 3411738624, Some("deadbeef".to_string()))
        );
        assert_eq!(rows[1], ("home.sfs".to_string(), 12345, None));
        let _ = std::fs::remove_dir_all(&dir);
    }
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
    fn toolkit_covers_shutdown_chain() {
        // Regression 2026-09-22: lsl-shutdown-gui errored "Could not find
        // 'uphome' (needed to save home)" because the nofmt installer
        // writes /cdrom/bin from FIRSTBOOT_TOOLKIT only, and uphome (plus
        // lsl-flush-home.sh, which uphome execs in USB mode) was never
        // embedded. Every sibling script the shutdown chain shells out
        // to must be here. 2026-09-28: lsl-toram.sh (the "Load to RAM +
        // remove USB" option) was missing the same way.
        for name in ["bin\\uphome", "bin\\lsl-flush-home.sh", "bin\\lsl-toram.sh"] {
            let e = FIRSTBOOT_TOOLKIT.iter().find(|(r, _)| *r == name);
            assert!(e.is_some(), "{} missing from FIRSTBOOT_TOOLKIT", name);
            assert!(
                e.unwrap().1.replace("\r\n", "\n").starts_with("#!/bin/bash\n"),
                "{} must be a bash script", name
            );
        }
    }

    #[test]
    fn toolkit_covers_desktop_and_onboot_payload() {
        // Regression 2026-09-22 (WHYFAIL6 §4, WHYFAIL5 follow-ups): the
        // desktop entries config.sh writes, the autostart entries, and the
        // unconditional `bash /cdrom/bin/mount_all.sh` in onboot.sh all
        // resolved to files the nofmt installer never staged - the stick's
        // bin/ was partial for months. Every /cdrom/bin/* reference on the
        // boot path must be embedded here.
        for name in [
            "bin\\lsl-gui",
            "bin\\lsl-tui",
            "bin\\lsl-shutdown-gui",
            "bin\\mount_all.sh",
            "bin\\lsl-pin-favorites",
            "bin\\lsl-home-readonly-warning",
            "bin\\lsl-reclaim-win-swap.sh",
            "bin\\clean-old-system-patches.sh",
            "bin\\wsl-boot-setup",
        ] {
            let e = FIRSTBOOT_TOOLKIT.iter().find(|(r, _)| *r == name);
            assert!(e.is_some(), "{} missing from FIRSTBOOT_TOOLKIT", name);
            assert!(!e.unwrap().1.is_empty(), "{} embedded empty", name);
        }
    }

    #[test]
    fn toolkit_ships_a_kitty_config_that_parses() {
        // Regression 2026-10-01: config.sh's install_lsl_kitty_conf reads
        // $REPO_ROOT/misc/kitty.conf and silently skips when it is absent, so a
        // nofmt-built stick (which stages /cdrom from FIRSTBOOT_TOOLKIT only)
        // never configured the terminal at all. Worse, the file that did ship in
        // the repo could not be loaded: kitty shows "Errors parsing
        // configuration" and never becomes usable for an invalid choice value
        // (`tab_powerline_style no` is not one of angled/round/slanted), which
        // reads to the user as "kitty won't start". The embedded conf must
        // exist and must not contain the known-fatal/invalid options.
        let e = FIRSTBOOT_TOOLKIT
            .iter()
            .find(|(r, _)| *r == "misc\\kitty.conf")
            .expect("misc\\kitty.conf missing from FIRSTBOOT_TOOLKIT");
        let conf = e.1.replace("\r\n", "\n");
        assert!(!conf.is_empty(), "misc\\kitty.conf embedded empty");
        assert!(conf.contains("font_family"), "kitty.conf lost its font section");
        // Fatal: a value kitty rejects aborts configuration entirely.
        assert!(
            !conf.contains("tab_powerline_style no"),
            "tab_powerline_style only accepts angled/round/slanted - 'no' is fatal"
        );
        // Unknown keys are silently ignored (non-fatal, but the option does
        // nothing): these were the WT-isms that had no kitty equivalent.
        for bad in [
            "padding_left",
            "padding_right",
            "padding_top",
            "padding_bottom",
            "font_subpixel_antialias",
            "active_tab_title_format",
        ] {
            assert!(!conf.contains(bad), "{} is not a kitty option", bad);
        }
        // Renamed options that kitty DOES understand must be used instead.
        assert!(conf.contains("window_padding_width"), "padding must use window_padding_width");
        assert!(conf.contains("active_tab_title_template"), "the tab title option is active_tab_title_template");
        // kitty spells the zero key "0"; "zero" is dropped as an unknown key.
        assert!(conf.contains("map ctrl+0 change_font_size all 0"));
    }

    #[test]
    fn toolkit_manifest_covers_every_embedded_source() {
        // WHYFAIL13 follow-up (2026-10-01): every shipped lslsetup.exe embedded
        // a broken bin/lsl-pin-favorites while the fix sat in bin/ unshipped -
        // nothing connected "a toolkit source changed" to "the built exe is
        // stale". build.rs now re-hashes each source listed in
        // assets/toolkit_sources.sha256 and fails the build on drift; this test
        // keeps the manifest complete, so a newly embedded file cannot be
        // added without recording its hash.
        let manifest = include_str!("../assets/toolkit_sources.sha256");
        let listed: Vec<&str> = manifest
            .lines()
            .map(str::trim)
            .filter(|l| !l.is_empty() && !l.starts_with('#'))
            .map(|l| l.split_once("  ").expect("hash<2 spaces>path").1)
            .collect();
        assert_eq!(
            listed.len(),
            FIRSTBOOT_TOOLKIT.len(),
            "assets/toolkit_sources.sha256 lists {} sources but FIRSTBOOT_TOOLKIT embeds {} - \
             regenerate with `bash misc/build-toolkit-manifest.sh`",
            listed.len(),
            FIRSTBOOT_TOOLKIT.len()
        );
        for (rel, _) in FIRSTBOOT_TOOLKIT {
            let unix = rel.replace('\\', "/");
            assert!(
                listed.iter().any(|l| *l == unix),
                "{} is embedded but missing from assets/toolkit_sources.sha256 - \
                 regenerate with `bash misc/build-toolkit-manifest.sh`",
                unix
            );
        }
    }

    #[test]
    fn z0_blob_is_fresh_against_its_source_manifest() {
        // WHYFAIL10: this blob is generated from misc/ by misc/build-z0.sh and
        // shipped verbatim as casper/filesystem_z0_firstboot.squashfs. include_bytes!
        // makes cargo depend on the blob, NOT on misc/, so an edit to misc/
        // used to reship a stale firstboot layer (the progress dialog stayed
        // broken for ~14h). build.rs enforces the freshness at build time via
        // assets/z0_sources.sha256; assert it here too so `cargo test` fails on
        // its own. Rebuild with `bash misc/build-z0.sh` whenever misc/ changes.
        assert!(Z0_BLOB.len() >= 4096 && Z0_BLOB.len() <= 1 << 20, "z0 size implausible: {}", Z0_BLOB.len());
        assert_eq!(&Z0_BLOB[0..4], &[0x68, 0x73, 0x71, 0x73], "z0 must start with hsqs magic");

        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("..");
        let manifest = include_str!("../assets/z0_sources.sha256");
        let mut checked = 0usize;
        for line in manifest.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let (want, rel) = line.split_once("  ").expect("malformed z0_sources.sha256 line");
            let bytes =
                std::fs::read(root.join(rel)).unwrap_or_else(|e| panic!("read {}: {}", rel, e));
            use sha2::Digest as _;
            let mut h = sha2::Sha256::new();
            h.update(&bytes);
            let got = format!("{:x}", h.finalize());
            assert_eq!(
                got, want,
                "{} changed since the z0 blob was packed - run `bash misc/build-z0.sh` and \
                 commit the regenerated blob + assets/z0_sources.sha256",
                rel
            );
            checked += 1;
        }
        assert!(checked > 0, "z0_sources.sha256 listed no sources");
    }
}

#[cfg(test)]
mod secondary_initrd_order_tests {
    use super::*;

    fn gunzip(data: &[u8]) -> Vec<u8> {
        let mut d = flate2::read::GzDecoder::new(data);
        let mut out = Vec::new();
        std::io::Read::read_to_end(&mut d, &mut out).unwrap();
        out
    }

    #[test]
    fn order_preserves_base_casper_premount_scripts() {
        // Regression: initramfs-tools' run_scripts SOURCES casper-premount/ORDER
        // when it exists instead of executing every script in the directory. An
        // ORDER that listed only our hook therefore made casper skip its own
        // casper-premount scripts - which is what broke the normal live boot
        // once the HDD-mirror hook became a secondary initrd. The injected ORDER
        // must (re)run the base's scripts, then source the hooks.
        let hdd = make_hddmirror_initrd(b"# hdd hook\n", b"# live hook\n").unwrap();
        let casper = String::from_utf8_lossy(&gunzip(&hdd)).into_owned();
        assert!(casper.contains("scripts/casper-premount/zz_lsl_hdd_mirror"));
        assert!(
            casper.contains("for f in /scripts/casper-premount/*"),
            "ORDER must run the base's own casper-premount scripts: {}",
            casper
        );
        let live = String::from_utf8_lossy(&gunzip(&hdd)).into_owned();
        assert!(live.contains("for f in /scripts/live-premount/*"));

        // Either secondary initrd's ORDER must work on its own, so both hooks
        // are referenced (each self-guards on the kernel cmdline).
        let ram = String::from_utf8_lossy(&gunzip(&make_ramclone_initrd(b"# ram hook\n").unwrap())).into_owned();
        assert!(ram.contains("for f in /scripts/casper-premount/*"));
        assert!(ram.contains("/scripts/casper-premount/9990-live-ramclone"));
        assert!(ram.contains("/scripts/casper-premount/zz_lsl_hdd_mirror"));
    }

    #[test]
    fn embedded_hooks_are_usable_and_lf_clean() {
        // The nofmt installer runs standalone (no bundle beside the exe), so
        // the hooks must be embedded - otherwise "Boot to RAM" is a no-op.
        for (name, content) in [
            ("live-ramclone", INITRAMFS_LIVE_RAMCLONE),
            ("lsl_hdd_mirror.sh", INITRAMFS_HDD_MIRROR),
            ("lsl_liveboot_mirror.sh", INITRAMFS_LIVEBOOT_MIRROR),
        ] {
            assert!(!content.is_empty(), "{} embedded empty", name);
            assert!(
                !content.replace("\r\n", "\n").contains('\r'),
                "{} contains CR after normalize",
                name
            );
        }
        // The ramclone hook must define the override casper calls.
        assert!(INITRAMFS_LIVE_RAMCLONE.contains("get_backing_device"));
    }

    #[test]
    fn hook_bytes_falls_back_to_embedded_when_bundle_absent() {
        let missing = std::env::temp_dir().join("lsl-no-such-bundle-xyz/initramfs/live-ramclone");
        let got = hook_bytes(&missing.to_string_lossy(), INITRAMFS_LIVE_RAMCLONE).unwrap();
        assert_eq!(got, INITRAMFS_LIVE_RAMCLONE.replace("\r\n", "\n").into_bytes());
        assert!(!got.is_empty());
    }
}

// ---------------------------------------------------------------------------
// Cpio newc packer (gzip-compressed small initrd for ramclone hook injection).
// The kernel unpacks concatenated initrds in order; a trailing archive with
// the hook at the right path is sufficient — no need to unpack the original.
// ---------------------------------------------------------------------------

fn cpio_newc_header(name: &str, size: u64, mode: u32) -> Vec<u8> {
    let namesize = name.len() + 1; // include null terminator
    format!(
        "070701{:08x}{:08x}{:08x}{:08x}{:08x}{:08x}{:08x}{:08x}{:08x}{:08x}{:08x}{:08x}{:08x}",
        0,       // c_ino
        mode,    // c_mode
        0,       // c_uid
        0,       // c_gid
        1,       // c_nlink
        0,       // c_mtime
        size,    // c_filesize
        0,       // c_devmajor
        0,       // c_devminor
        0,       // c_rdevmajor
        0,       // c_rdevminor
        namesize,// c_namesize
        0,       // c_check
    )
    .into_bytes()
}

fn cpio_pad4(n: usize) -> usize {
    (4 - (n % 4)) % 4
}

/// Padding for a newc *name* field. The newc header is 110 bytes and 110 % 4
/// == 2, so the name field must be padded to align (110 + namesize); padding
/// `namesize` alone misplaces every entry after the first by 2 bytes. GNU cpio
/// resyncs on the resulting bad magic, but the kernel's initramfs unpacker
/// (init/initramfs.c unpack_to_rootfs) does not: it stops there and silently
/// drops the remaining members (notably scripts/casper-premount/ORDER, without
/// which casper never sources the ramclone hook, so Boot to RAM never shows a
/// progress dialog).
fn cpio_pad_name(namesize: usize) -> usize {
    (4 - ((110 + namesize) % 4)) % 4
}

fn cpio_newc_file(name: &str, data: &[u8], mode: u32) -> Vec<u8> {
    let mut out = cpio_newc_header(name, data.len() as u64, mode);
    out.extend_from_slice(name.as_bytes());
    out.push(0);
    out.extend_from_slice(&vec![0u8; cpio_pad_name(name.len() + 1)]);
    out.extend_from_slice(data);
    out.extend_from_slice(&vec![0u8; cpio_pad4(data.len())]);
    out
}

fn cpio_newc_trailer() -> Vec<u8> {
    cpio_newc_file("TRAILER!!!", &[], 0)
}

// ---------------------------------------------------------------------------
// Cpio newc parser (for initrd repacking).
// ---------------------------------------------------------------------------

/// Parse a cpio newc archive into a filename -> (mode, data) map.
/// Returns Err if the archive is malformed.
fn parse_cpio_newc(data: &[u8]) -> Result<Vec<(String, u32, Vec<u8>)>, String> {
    let mut out = Vec::new();
    let mut pos = 0usize;
    while pos + 110 <= data.len() {
        if &data[pos..pos + 6] != b"070701" {
            return Err(format!("cpio parse: bad magic at {}", pos));
        }
        let read_hex = |off: usize, len: usize| -> Result<u64, String> {
            let s = std::str::from_utf8(&data[pos + off..pos + off + len])
                .map_err(|_| format!("cpio parse: non-utf8 header at {}", pos))?;
            u64::from_str_radix(s, 16)
                .map_err(|_| format!("cpio parse: bad hex at {}", pos))
        };
        let _ino = read_hex(6, 8)?;
        let mode = read_hex(14, 8)? as u32;
        let _uid = read_hex(22, 8)?;
        let _gid = read_hex(30, 8)?;
        let _nlink = read_hex(38, 8)?;
        let _mtime = read_hex(46, 8)?;
        let filesize = read_hex(54, 8)? as usize;
        let _devmajor = read_hex(62, 8)?;
        let _devminor = read_hex(70, 8)?;
        let _rdevmajor = read_hex(78, 8)?;
        let _rdevminor = read_hex(86, 8)?;
        let namesize = read_hex(94, 8)? as usize;
        let _check = read_hex(102, 8)?;
        pos += 110;
        if pos + namesize > data.len() {
            return Err("cpio parse: truncated name".into());
        }
        let name = std::str::from_utf8(&data[pos..pos + namesize - 1])
            .map_err(|_| "cpio parse: non-utf8 name".to_string())?
            .to_string();
        pos += namesize;
        pos += cpio_pad_name(namesize);
        if name == "TRAILER!!!" {
            break;
        }
        if pos + filesize > data.len() {
            return Err("cpio parse: truncated data".into());
        }
        let file_data = data[pos..pos + filesize].to_vec();
        pos += filesize;
        pos += cpio_pad4(filesize);
        out.push((name, mode, file_data));
    }
    Ok(out)
}

/// Build a cpio newc archive from a list of (name, mode, data) entries.
fn build_cpio_newc(entries: &[(String, u32, Vec<u8>)]) -> Vec<u8> {
    let mut out = Vec::new();
    for (name, mode, data) in entries {
        out.extend_from_slice(&cpio_newc_file(name, data, *mode));
    }
    out.extend_from_slice(&cpio_newc_trailer());
    out
}

/// Walk a cpio newc archive exactly the way the kernel's initramfs unpacker
/// does (init/initramfs.c unpack_to_rootfs): each member must start on a 4-byte
/// boundary at `110 + namesize` padded, and bad magic is fatal — there is no
/// resync. GNU cpio DOES resync, which is why a round-trip against GNU cpio
/// happily "passes" an archive the kernel silently truncates.
///
/// Returns the names walked (including TRAILER!!!) or the offset it stopped at.
fn kernel_unpack_names(data: &[u8]) -> Result<Vec<String>, usize> {
    let mut names = Vec::new();
    let mut pos = 0usize;
    loop {
        if pos + 110 > data.len() || &data[pos..pos + 6] != b"070701" {
            return Err(pos);
        }
        let hex = |off: usize| -> Result<usize, usize> {
            let s = std::str::from_utf8(&data[pos + off..pos + off + 8]).map_err(|_| pos)?;
            usize::from_str_radix(s, 16).map_err(|_| pos)
        };
        let namesize = hex(94)?;
        let filesize = hex(54)?;
        let name_start = pos + 110;
        if name_start + namesize > data.len() {
            return Err(pos);
        }
        let name = std::str::from_utf8(&data[name_start..name_start + namesize - 1])
            .map_err(|_| pos)?
            .to_string();
        // The kernel aligns to 4 after the NAME, not after namesize alone.
        pos = name_start + cpio_pad_name(namesize) + namesize;
        names.push(name.clone());
        if name == "TRAILER!!!" {
            return Ok(names);
        }
        if pos + filesize > data.len() {
            return Err(pos);
        }
        pos += filesize + cpio_pad4(filesize);
    }
}

#[cfg(test)]
mod cpio_tests {
    use super::*;

    #[test]
    fn pad_name_aligns_the_110_byte_header() {
        // 110 % 4 == 2, so padding namesize alone leaves every entry after the
        // first misaligned by 2 bytes.
        for namesize in 1..=64usize {
            assert_eq!(
                (110 + namesize + cpio_pad_name(namesize)) % 4,
                0,
                "namesize {} is not 4-aligned after the header",
                namesize
            );
        }
        assert_eq!(cpio_pad_name(2), 0); // "." + NUL -> 112
        assert_eq!(cpio_pad_name(42), 0); // the hdd-mirror hook name
    }

    #[test]
    fn archive_survives_the_kernel_unpack_rule() {
        let entries: Vec<(String, u32, Vec<u8>)> = vec![
            (
                "scripts/casper-premount/zz_lsl_hdd_mirror".to_string(),
                0o755,
                b"#!/bin/sh\nget_backing_device\n".to_vec(),
            ),
            (
                "scripts/casper-premount/ORDER".to_string(),
                0o644,
                b"zz_lsl_hdd_mirror\n".to_vec(),
            ),
            (
                "scripts/live-premount/00lsl_liveboot_mirror".to_string(),
                0o755,
                b"mirror\n".to_vec(),
            ),
            (
                "scripts/casper-premount/odd".to_string(),
                0o644,
                vec![7u8; 13], // unaligned data too
            ),
        ];
        let archive = build_cpio_newc(&entries);
        let names = kernel_unpack_names(&archive).expect("kernel would drop the archive tail");
        assert_eq!(
            names,
            vec![
                "scripts/casper-premount/zz_lsl_hdd_mirror",
                "scripts/casper-premount/ORDER",
                "scripts/live-premount/00lsl_liveboot_mirror",
                "scripts/casper-premount/odd",
                "TRAILER!!!",
            ]
        );
        // And the data must round-trip byte-exactly.
        let parsed = parse_cpio_newc(&archive).expect("parse");
        assert_eq!(parsed.len(), entries.len());
        for (a, b) in parsed.iter().zip(entries.iter()) {
            assert_eq!(a.0, b.0);
            assert_eq!(a.2, b.2);
        }
    }

    #[test]
    fn old_wrong_padding_is_rejected_by_the_kernel_rule() {
        // Reproduce the shipped bug: build the first entry correctly, then
        // mis-pad a later name by namesize alone. The kernel must refuse it.
        let mut archive = cpio_newc_file("scripts/casper-premount/zz_lsl_hdd_mirror", b"hook", 0o755);
        // Second entry written with the OLD (wrong) rule.
        let mut bad = cpio_newc_header("scripts/casper-premount/ORDER", 5, 0o644);
        bad.extend_from_slice(b"scripts/casper-premont/ORDER");
        bad.push(0);
        bad.extend_from_slice(&vec![0u8; cpio_pad4(29)]); // wrong: pad4(namesize)
        bad.extend_from_slice(b"order");
        bad.extend_from_slice(&vec![0u8; cpio_pad4(5)]);
        archive.extend_from_slice(&bad);
        assert!(
            kernel_unpack_names(&archive).is_err(),
            "the kernel must reject mis-aligned member padding"
        );
    }

    #[test]
    fn order_survives_injection_the_way_casper_needs_it() {
        // The regression that shipped: without ORDER, casper never sources the
        // ramclone hook and Boot to RAM shows no progress dialog.
        let entries: Vec<(String, u32, Vec<u8>)> = vec![(
            "scripts/casper-premount/9990-live-ramclone".to_string(),
            0o755,
            b"#!/bin/sh\n".to_vec(),
        )];
        let archive = build_cpio_newc(&entries);
        let names = kernel_unpack_names(&archive).expect("kernel-unpackable");
        assert!(names.iter().any(|n| n == "TRAILER!!!"));
    }
}

// ---------------------------------------------------------------------------
// Initrd repacker: decompress, inject hooks into ORDER, recompress.
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum InitrdCompression {
    None,
    Gzip,
    Zstd,
    Lz4,
}

fn detect_compression(data: &[u8]) -> InitrdCompression {
    if data.len() >= 4 && data[0..4] == [0x28, 0xb5, 0x2f, 0xfd] {
        InitrdCompression::Zstd
    } else if data.len() >= 4 && data[0..4] == [0x04, 0x22, 0x4d, 0x18] {
        InitrdCompression::Lz4
    } else if data.len() >= 2 && data[0..2] == [0x1f, 0x8b] {
        InitrdCompression::Gzip
    } else if data.len() >= 6 && data.starts_with(b"070701") {
        InitrdCompression::None
    } else {
        InitrdCompression::None
    }
}

fn decompress_initrd(data: &[u8], comp: InitrdCompression) -> Result<Vec<u8>, String> {
    match comp {
        InitrdCompression::None => Ok(data.to_vec()),
        InitrdCompression::Gzip => {
            let mut decoder = flate2::read::GzDecoder::new(data);
            let mut out = Vec::new();
            std::io::Read::read_to_end(&mut decoder, &mut out)
                .map_err(|e| format!("gzip decompress: {}", e))?;
            Ok(out)
        }
        InitrdCompression::Zstd => {
            let mut out = Vec::new();
            zstd::stream::copy_decode(data, &mut out)
                .map_err(|e| format!("zstd decompress: {}", e))?;
            Ok(out)
        }
        InitrdCompression::Lz4 => {
            let mut decoder = lz4_flex::frame::FrameDecoder::new(data);
            let mut out = Vec::new();
            std::io::Read::read_to_end(&mut decoder, &mut out)
                .map_err(|e| format!("lz4 decompress: {}", e))?;
            Ok(out)
        }
    }
}

fn compress_initrd(data: &[u8], comp: InitrdCompression) -> Result<Vec<u8>, String> {
    match comp {
        InitrdCompression::None => Ok(data.to_vec()),
        InitrdCompression::Gzip => {
            let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
            encoder.write_all(data).map_err(|e| format!("gzip compress: {}", e))?;
            encoder.finish().map_err(|e| format!("gzip finish: {}", e))
        }
        InitrdCompression::Zstd => {
            let mut out = Vec::new();
            zstd::stream::copy_encode(data, &mut out, 3)
                .map_err(|e| format!("zstd compress: {}", e))?;
            Ok(out)
        }
        InitrdCompression::Lz4 => {
            let mut encoder = lz4_flex::frame::FrameEncoder::new(Vec::new());
            std::io::Write::write_all(&mut encoder, data)
                .map_err(|e| format!("lz4 compress: {}", e))?;
            encoder.finish().map_err(|e| format!("lz4 finish: {}", e))
        }
    }
}

/// Find the start of the compressed/initrd payload after any microcode cpio prefix.
/// Returns (prefix_bytes, payload_bytes, compression).
fn split_initrd(data: &[u8]) -> Result<(&[u8], &[u8], InitrdCompression), String> {
    let mut pos = 0usize;
    // Scan for cpio trailers (microcode prefix uses plain cpio newc).
    while pos + 110 <= data.len() {
        if &data[pos..pos + 6] != b"070701" {
            break;
        }
        // Read namesize and filesize from header
        let read_hex = |off: usize| -> Option<u64> {
            let s = std::str::from_utf8(&data[pos + off..pos + off + 8]).ok()?;
            u64::from_str_radix(s, 16).ok()
        };
        let filesize = read_hex(54).ok_or_else(|| format!("cpio header parse failed at {}", pos))? as usize;
        let namesize = read_hex(94).ok_or_else(|| format!("cpio header parse failed at {}", pos))? as usize;
        let name_end = pos + 110 + namesize;
        if name_end > data.len() {
            break;
        }
        let name = std::str::from_utf8(&data[pos + 110..name_end - 1]).unwrap_or("");
        let entry_end = name_end + cpio_pad_name(namesize) + filesize + cpio_pad4(filesize);
        if entry_end > data.len() {
            break;
        }
        pos = entry_end;
        if name == "TRAILER!!!" {
            // Skip null padding to next archive/compressed block
            while pos < data.len() && data[pos] == 0 {
                pos += 1;
            }
            if pos >= data.len() {
                return Err("initrd: no payload after microcode prefix".into());
            }
            let comp = detect_compression(&data[pos..]);
            return Ok((&data[..pos], &data[pos..], comp));
        }
    }
    // No microcode prefix; entire file is the payload
    let comp = detect_compression(data);
    Ok((&[], data, comp))
}

/// Repack an initrd, injecting hooks into ORDER files.
/// `hooks` is a list of (cpio_path, file_data, mode) to inject.
/// ORDER files at scripts/casper-premount/ORDER and scripts/live-premount/ORDER
/// are automatically extended with entries for any hooks in those directories.
pub fn repack_initrd(initrd_path: &str, hooks: &[(String, Vec<u8>, u32)]) -> Result<Vec<u8>, String> {
    let data = std::fs::read(initrd_path).map_err(|e| format!("read initrd: {}", e))?;
    let (prefix, payload, comp) = split_initrd(&data)?;
    let decompressed = decompress_initrd(payload, comp)?;
    let mut entries = parse_cpio_newc(&decompressed)?;

    // Build a set of existing paths for dedup
    let existing: std::collections::HashSet<String> = entries.iter().map(|(n, _, _)| n.clone()).collect();

    // Add hooks, skipping any that already exist
    for (path, data, mode) in hooks {
        if existing.contains(path) {
            out::warn(&format!("initrd already contains {}; skipping injection", path));
            continue;
        }
        entries.push((path.clone(), *mode, data.clone()));
    }

    // Patch ORDER files to include our hooks
    let mut order_patches: std::collections::HashMap<String, Vec<String>> = std::collections::HashMap::new();
    for (path, _, _) in &entries {
        if path.starts_with("scripts/casper-premount/") && path != "scripts/casper-premount/ORDER" {
            order_patches.entry("scripts/casper-premount/ORDER".to_string())
                .or_default()
                .push(format!(". /{} \"$@\"", path));
        }
        if path.starts_with("scripts/live-premount/") && path != "scripts/live-premount/ORDER" {
            order_patches.entry("scripts/live-premount/ORDER".to_string())
                .or_default()
                .push(format!(". /{} \"$@\"", path));
        }
    }

    for (order_path, new_lines) in order_patches {
        let mut found = false;
        for (path, _, data) in &mut entries {
            if *path == order_path {
                let existing = String::from_utf8_lossy(data);
                let mut lines: Vec<String> = existing.lines().map(|s| s.to_string()).collect();
                for line in &new_lines {
                    if !lines.iter().any(|l| l.trim() == line.trim()) {
                        lines.push(line.clone());
                    }
                }
                *data = lines.join("\n").into_bytes();
                if !data.ends_with(b"\n") {
                    data.push(b'\n');
                }
                found = true;
                break;
            }
        }
        if !found {
            // Create new ORDER file
            let content = new_lines.join("\n") + "\n";
            entries.push((order_path, 0o100644, content.into_bytes()));
        }
    }

    let repacked_cpio = build_cpio_newc(&entries);
    let repacked_compressed = compress_initrd(&repacked_cpio, comp)?;
    let mut result = prefix.to_vec();
    result.extend_from_slice(&repacked_compressed);
    Ok(result)
}

/// ORDER body for scripts/casper-premount of a secondary initrd.
///
/// `run_scripts` (initramfs-tools) SOURCES this file when it exists INSTEAD of
/// iterating the directory, so an ORDER that listed only our hook would make
/// casper skip its own casper-premount scripts entirely - that is what broke
/// the normal live boot when the HDD-mirror hook became a secondary initrd.
/// So this ORDER first runs every base casper-premount script the way
/// run_scripts would (as a subprocess - those scripts call `exit`), then
/// SOURCES our hooks, which need their exports/function overrides (LAYERFS_PATH,
/// get_backing_device) to reach casper's shell. Both hooks self-guard on the
/// kernel cmdline, so listing both is safe whichever secondary initrd is loaded.
const CASPER_PREMOUNT_ORDER: &[u8] =
    b"for f in /scripts/casper-premount/*; do\n\
case \"$f\" in\n\
*/ORDER|*/zz_lsl_hdd_mirror|*/9990-live-ramclone) continue ;;\n\
esac\n\
[ -x \"$f\" ] && \"$f\" \"$@\" 2>/dev/null || true\n\
done\n\
. /scripts/casper-premount/zz_lsl_hdd_mirror \"$@\" 2>/dev/null || true\n\
. /scripts/casper-premount/9990-live-ramclone \"$@\" 2>/dev/null || true\n";

/// ORDER body for scripts/live-premount (Debian live-boot). Same idea:
/// preserve the base's own live-premount scripts, then source the hook.
const LIVE_PREMOUNT_ORDER: &[u8] =
    b"for f in /scripts/live-premount/*; do\n\
case \"$f\" in\n\
*/ORDER|*/00lsl_liveboot_mirror) continue ;;\n\
esac\n\
[ -x \"$f\" ] && \"$f\" \"$@\" 2>/dev/null || true\n\
done\n\
. /scripts/live-premount/00lsl_liveboot_mirror \"$@\" 2>/dev/null || true\n";

/// Create a gzip-compressed cpio initrd containing the ramclone hook for
/// casper-premount. The hook is placed at scripts/casper-premount/ together
/// with an ORDER file that casper's run_scripts sources. The ORDER line
/// guards the HDD-mirror hook (zz_lsl_hdd_mirror) so both can coexist.
pub fn make_ramclone_initrd(hook_bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut archive = Vec::new();
    // Hook script: sourced by casper's run_scripts, overrides get_backing_device.
    archive.extend_from_slice(&cpio_newc_file(
        "scripts/casper-premount/9990-live-ramclone",
        hook_bytes,
        0o100755,
    ));
    // ORDER file: see CASPER_PREMOUNT_ORDER - it must re-run the base's own
    // casper-premount scripts, not just ours.
    archive.extend_from_slice(&cpio_newc_file(
        "scripts/casper-premount/ORDER",
        CASPER_PREMOUNT_ORDER,
        0o100644,
    ));
    archive.extend_from_slice(&cpio_newc_trailer());
    let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    encoder.write_all(&archive).map_err(|e| format!("gzip encode: {}", e))?;
    encoder.finish().map_err(|e| format!("gzip finish: {}", e))
}

/// Embedded secondary-initrd hooks. The nofmt installer ships everything else
/// (bin/, systemd/, the z0 layer) embedded so it runs standalone from an exe
/// with no bundle beside it; the ramclone/hddmirror hooks must not depend on
/// `{bundle_dir}\initramfs\` either, or checking "Boot to RAM" silently does
/// nothing. A bundle copy still wins when present (legacy bundle parity).
static INITRAMFS_LIVE_RAMCLONE: &str = include_str!("../../../initramfs/live-ramclone");
static INITRAMFS_HDD_MIRROR: &str = include_str!("../../../initramfs/lsl_hdd_mirror.sh");
static INITRAMFS_LIVEBOOT_MIRROR: &str = include_str!("../../../initramfs/lsl_liveboot_mirror.sh");

/// Hook bytes for a secondary initrd: the bundle file when it exists, else the
/// embedded copy (LF-normalized - Windows checkouts are CRLF and the guest
/// runs these under /bin/sh).
fn hook_bytes(path: &str, embedded: &str) -> Result<Vec<u8>, String> {
    if path_exists(path) {
        return std::fs::read(path).map_err(|e| format!("read {}: {}", path, e));
    }
    Ok(embedded.replace("\r\n", "\n").into_bytes())
}

/// Write the ramclone small-initrd to the stick from the bundle hook, falling
/// back to the embedded copy when no bundle sits beside the exe. The boot menu
/// references this as a second initrd.
pub fn install_ramclone_initrd(vol_letter: &str, bundle_dir: &str) -> Result<(), String> {
    let hook = format!("{}\\initramfs\\live-ramclone", bundle_dir);
    let data = hook_bytes(&hook, INITRAMFS_LIVE_RAMCLONE)?;
    let compressed = make_ramclone_initrd(&data)?;
    let dest = format!("{}:\\casper\\initrd.ramclone.gz", vol_letter);
    std::fs::write(&dest, &compressed).map_err(|e| format!("write ramclone initrd: {}", e))?;
    out::info(&format!(
        "ramclone initrd ready ({} bytes, hook at {} paths).",
        compressed.len(),
        3
    ));
    Ok(())
}

/// Create a gzip-compressed cpio initrd containing the HDD-mirror hooks.
/// Includes both casper-premount and live-boot-premount variants, plus
/// ORDER files so each framework sources the hook.
pub fn make_hddmirror_initrd(casper_hook: &[u8], live_hook: &[u8]) -> Result<Vec<u8>, String> {
    let mut archive = Vec::new();
    // casper variant
    archive.extend_from_slice(&cpio_newc_file(
        "scripts/casper-premount/zz_lsl_hdd_mirror",
        casper_hook,
        0o100755,
    ));
    archive.extend_from_slice(&cpio_newc_file(
        "scripts/casper-premount/ORDER",
        CASPER_PREMOUNT_ORDER,
        0o100644,
    ));
    // live-boot variant
    archive.extend_from_slice(&cpio_newc_file(
        "scripts/live-premount/00lsl_liveboot_mirror",
        live_hook,
        0o100755,
    ));
    archive.extend_from_slice(&cpio_newc_file(
        "scripts/live-premount/ORDER",
        LIVE_PREMOUNT_ORDER,
        0o100644,
    ));
    archive.extend_from_slice(&cpio_newc_trailer());
    let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    encoder.write_all(&archive).map_err(|e| format!("gzip encode: {}", e))?;
    encoder.finish().map_err(|e| format!("gzip finish: {}", e))
}

/// Write the HDD-mirror small-initrd to the stick from the bundle hooks,
/// falling back to the embedded copies when no bundle sits beside the exe.
/// The boot menu references this as a second initrd.
pub fn install_hddmirror_initrd(vol_letter: &str, bundle_dir: &str) -> Result<(), String> {
    let casper_hook = format!("{}\\initramfs\\lsl_hdd_mirror.sh", bundle_dir);
    let live_hook = format!("{}\\initramfs\\lsl_liveboot_mirror.sh", bundle_dir);
    let casper = hook_bytes(&casper_hook, INITRAMFS_HDD_MIRROR)?;
    let live = hook_bytes(&live_hook, INITRAMFS_LIVEBOOT_MIRROR)?;
    let compressed = make_hddmirror_initrd(&casper, &live)?;
    let dest = format!("{}:\\casper\\initrd.hddmirror.gz", vol_letter);
    std::fs::write(&dest, &compressed).map_err(|e| format!("write hddmirror initrd: {}", e))?;
    out::info(&format!(
        "hddmirror initrd ready ({} bytes).",
        compressed.len(),
    ));
    Ok(())
}
