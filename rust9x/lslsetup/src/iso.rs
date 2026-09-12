//! Pure-Rust ISO9660 reader — replaces `Mount-DiskImage` (Win8+/Enterprise
//! only) with something that works on every Windows version we support.
//! Validates a live ISO the same way install.ps1's Test-LiveIso does:
//! casper\filesystem.squashfs present, .disk\info text, dists codenames.

use std::io::{Read, Seek, SeekFrom};

const SECTOR: u64 = 2048;

pub struct Iso {
    file: std::fs::File,
    root_extent: u32,
    root_size: u32,
}

#[derive(Debug)]
pub enum IsoErr {
    Io(std::io::Error),
    NotIso9660,
}
impl std::fmt::Display for IsoErr {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            IsoErr::Io(e) => write!(f, "{}", e),
            IsoErr::NotIso9660 => write!(f, "not an ISO9660 image"),
        }
    }
}

fn read_dir_record(file: &mut std::fs::File, extent: u32, size: u32) -> std::io::Result<Vec<u8>> {
    file.seek(SeekFrom::Start(extent as u64 * SECTOR))?;
    let mut buf = vec![0u8; size as usize];
    file.read_exact(&mut buf)?;
    Ok(buf)
}

/// Whether a directory entry name is visible (filters `.`, `..`, and the
/// raw 0x00/0x01 self/parent markers). Single rule shared by `list_dir`
/// and the tree walker so the two can never drift apart.
fn is_visible_entry(n: &str) -> bool {
    n != "." && n != ".." && !n.starts_with('\0')
}

/// Sanitize one path component for Windows/FAT32: map illegal characters
/// (`<> : " / \ | ? *` + C0 controls) to `%XX` (uppercase hex), trim
/// trailing dots/spaces (illegal as name endings), and guard reserved DOS
/// device names (`CON`, `PRN`, `AUX`, `NUL`, `COM1`-`9`, `LPT1`-`9`).
/// Deterministic; same-directory collisions (including case-only ones on
/// case-insensitive filesystems) are resolved by the walker with `~n`.
pub fn sanitize_component(name: &str) -> String {
    let mut s = String::with_capacity(name.len());
    for c in name.chars() {
        if matches!(c, '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*')
            || (c as u32) < 0x20
        {
            for b in c.encode_utf8(&mut [0u8; 4]).as_bytes() {
                s.push_str(&format!("%{:02X}", b));
            }
        } else {
            s.push(c);
        }
    }
    while s.ends_with('.') || s.ends_with(' ') {
        s.pop();
    }
    if s.is_empty() {
        return "_".to_string();
    }
    // Reserved device names, with or without extension (case-insensitive).
    let stem = s.split('.').next().unwrap_or("").to_ascii_uppercase();
    let reserved = matches!(
        stem.as_str(),
        "CON" | "PRN" | "AUX" | "NUL"
            | "COM1" | "COM2" | "COM3" | "COM4" | "COM5" | "COM6" | "COM7" | "COM8" | "COM9"
            | "LPT1" | "LPT2" | "LPT3" | "LPT4" | "LPT5" | "LPT6" | "LPT7" | "LPT8" | "LPT9"
    );
    if reserved {
        s = format!("_{}", s);
    }
    s
}

/// `\\?\` verbatim prefix for absolute Windows paths (lifts MAX_PATH for
/// deep ISO trees). Already-verbatim, relative, and non-drive paths pass
/// through untouched.
pub fn verbatim_path(path: &str) -> String {
    if path.starts_with(r"\\?\") {
        return path.to_string();
    }
    let p = path.replace('/', "\\");
    let b = p.as_bytes();
    if b.len() >= 3 && b[1] == b':' && b[2] == b'\\' {
        return format!(r"\\?\{}", p);
    }
    if p.starts_with(r"\\") {
        return format!(r"\\?\UNC\{}", &p[2..]);
    }
    p
}

fn parse_entries(dir: &[u8]) -> Vec<(String, u32, u32, bool)> {
    // (name, extent, size, is_dir)
    let mut out = Vec::new();
    let mut i = 0usize;
    while i < dir.len() {
        let len = dir[i] as usize;
        if len == 0 {
            // rest of the sector; skip to the next sector boundary
            i = (i / 2048 + 1) * 2048;
            if i >= dir.len() {
                break;
            }
            continue;
        }
        let rec = &dir[i..i + len];
        if rec.len() >= 34 {
            let extent = u32::from_le_bytes([rec[2], rec[3], rec[4], rec[5]]);
            let size = u32::from_le_bytes([rec[10], rec[11], rec[12], rec[13]]);
            let flags = rec[25];
            let name_len = rec[32] as usize;
            let raw = &rec[33..33 + name_len.min(rec.len() - 33)];
            let name = if raw.first() == Some(&0) {
                "\0".to_string()
            } else if raw.first() == Some(&1) {
                "..".to_string()
            } else {
                let mut s = raw.to_vec();
                // Strip ";1" version suffix
                if let Some(p) = s.iter().position(|&b| b == b';') {
                    s.truncate(p);
                }
                // Trim trailing dot (8.3 legacy padding)
                while s.last() == Some(&b'.') {
                    s.pop();
                }
                String::from_utf8_lossy(&s).into_owned()
            };
            out.push((name, extent, size, flags & 2 != 0));
        }
        i += len;
    }
    out
}

/// One enumerated entry: original ISO-rel path plus its location.
/// (Kept private: dest mapping needs the collision sets, which live
/// for exactly one `extract_tree` run.)
#[derive(Clone, Debug)]
struct TreeEntry {
    iso_rel: String, // forward slashes, original ISO names
    extent: u32,
    size: u64,
    is_dir: bool,
}

impl Iso {
    pub fn open(path: &str) -> Result<Iso, IsoErr> {
        let mut file =
            std::fs::File::open(path).map_err(IsoErr::Io)?;
        // Primary Volume Descriptor lives at sector 16
        file.seek(SeekFrom::Start(16 * SECTOR)).map_err(IsoErr::Io)?;
        let mut pvd = [0u8; 2048];
        file.read_exact(&mut pvd).map_err(IsoErr::Io)?;
        if &pvd[1..6] != b"CD001" || pvd[0] != 1 {
            return Err(IsoErr::NotIso9660);
        }
        // Root directory record starts at offset 156 (34 bytes)
        let r = &pvd[156..190];
        let root_extent = u32::from_le_bytes([r[2], r[3], r[4], r[5]]);
        let root_size = u32::from_le_bytes([r[10], r[11], r[12], r[13]]);
        Ok(Iso { file, root_extent, root_size })
    }

    pub fn list_dir(&mut self, path: &str) -> Result<Vec<(String, bool)>, IsoErr> {
        let mut cur_extent = self.root_extent;
        let mut cur_size = self.root_size;
        if !path.is_empty() {
            for part in path.split('/') {
                if part.is_empty() || part == "." {
                    continue;
                }
                let dir = read_dir_record(&mut self.file, cur_extent, cur_size).map_err(IsoErr::Io)?;
                let entries = parse_entries(&dir);
                let hit = entries
                    .iter()
                    .find(|(n, _, _, is_dir)| *is_dir && n.eq_ignore_ascii_case(part))
                    .ok_or(IsoErr::NotIso9660)?;
                cur_extent = hit.1;
                cur_size = hit.2;
            }
        }
        let dir = read_dir_record(&mut self.file, cur_extent, cur_size).map_err(IsoErr::Io)?;
        Ok(parse_entries(&dir)
            .into_iter()
            .filter(|(n, _, _, _)| is_visible_entry(n))
            .map(|(n, _, _, d)| (n, d))
            .collect())
    }

    /// Stream one extent range to an open file. Shared by `extract_file`
    /// and the tree extractor so single-file and whole-tree paths agree
    /// byte for byte.
    fn stream_to_file(
        &mut self,
        extent: u32,
        size: u64,
        out: &mut std::fs::File,
        progress: &mut dyn FnMut(u64, u64),
    ) -> Result<u64, IsoErr> {
        use std::io::Write;
        self.file
            .seek(SeekFrom::Start(extent as u64 * SECTOR))
            .map_err(IsoErr::Io)?;
        let mut buf = vec![0u8; 1 << 20];
        let mut done = 0u64;
        while done < size {
            let n = ((size - done).min(buf.len() as u64)) as usize;
            self.file.read_exact(&mut buf[..n]).map_err(IsoErr::Io)?;
            out.write_all(&buf[..n]).map_err(IsoErr::Io)?;
            done += n as u64;
            progress(done, size);
        }
        Ok(done)
    }

    pub fn read_file(&mut self, path: &str, max: usize) -> Result<Vec<u8>, IsoErr> {
        let mut parts: Vec<&str> = path.split('/').filter(|p| !p.is_empty()).collect();
        let fname = parts.pop().unwrap_or("").to_string();
        let dirpath = parts.join("/");
        // validated for existence here; extents are re-read below
        // (list_dir drops them), so the listing itself is discarded
        self.list_dir(&dirpath)?;
        let entries = {
            // re-read the directory to get extents (list_dir drops them)
            let mut cur_extent = self.root_extent;
            let mut cur_size = self.root_size;
            if !dirpath.is_empty() {
                for part in dirpath.split('/') {
                    if part.is_empty() {
                        continue;
                    }
                    let d = read_dir_record(&mut self.file, cur_extent, cur_size).map_err(IsoErr::Io)?;
                    let e = parse_entries(&d);
                    let hit = e
                        .iter()
                        .find(|(n, _, _, is_dir)| *is_dir && n.eq_ignore_ascii_case(part))
                        .ok_or(IsoErr::NotIso9660)?;
                    cur_extent = hit.1;
                    cur_size = hit.2;
                }
            }
            read_dir_record(&mut self.file, cur_extent, cur_size).map_err(IsoErr::Io)?
        };
        let hit = parse_entries(&entries)
            .into_iter()
            .find(|(n, _, _, is_dir)| !*is_dir && n.eq_ignore_ascii_case(&fname))
            .ok_or(IsoErr::NotIso9660)?;
        let mut buf = vec![0u8; (hit.2 as usize).min(max)];
        self.file
            .seek(SeekFrom::Start(hit.1 as u64 * SECTOR))
            .map_err(IsoErr::Io)?;
        self.file.read_exact(&mut buf).map_err(IsoErr::Io)?;
        Ok(buf)
    }

    /// Stream a file out of the ISO to `dest` (chunked, with progress),
    /// without ever holding the whole file in memory: vmlinuz+initrd run
    /// ~100 MB, too much to buffer on a 256 MB Win9x box. Returns bytes
    /// written. Case-insensitive lookup, like `read_file`.
    pub fn extract_file(
        &mut self,
        path: &str,
        dest: &str,
        progress: &mut dyn FnMut(u64, u64),
    ) -> Result<u64, IsoErr> {
        let mut parts: Vec<&str> = path.split('/').filter(|p| !p.is_empty()).collect();
        let fname = parts.pop().unwrap_or("").to_string();
        let dirpath = parts.join("/");
        let mut cur_extent = self.root_extent;
        let mut cur_size = self.root_size;
        if !dirpath.is_empty() {
            for part in dirpath.split('/') {
                if part.is_empty() {
                    continue;
                }
                let d = read_dir_record(&mut self.file, cur_extent, cur_size).map_err(IsoErr::Io)?;
                let e = parse_entries(&d);
                let hit = e
                    .iter()
                    .find(|(n, _, _, is_dir)| *is_dir && n.eq_ignore_ascii_case(part))
                    .ok_or(IsoErr::NotIso9660)?;
                cur_extent = hit.1;
                cur_size = hit.2;
            }
        }
        let dir = read_dir_record(&mut self.file, cur_extent, cur_size).map_err(IsoErr::Io)?;
        let hit = parse_entries(&dir)
            .into_iter()
            .find(|(n, _, _, is_dir)| !*is_dir && n.eq_ignore_ascii_case(&fname))
            .ok_or(IsoErr::NotIso9660)?;
        let (extent, size) = (hit.1, hit.2);
        let mut out = std::fs::File::create(dest).map_err(IsoErr::Io)?;
        self.stream_to_file(extent, size as u64, &mut out, progress)
    }

    /// Depth-first walk from a directory extent; each directory read once.
    /// Skips the El Torito `[BOOT]` pseudo-directory (boot catalog images,
    /// not part of the live system). Returns (entries, saw_boot_dir).
    fn enumerate(&mut self) -> Result<(Vec<TreeEntry>, bool), IsoErr> {
        let mut out = Vec::new();
        let mut saw_boot = false;
        let mut stack = vec![(self.root_extent, self.root_size, String::new())];
        while let Some((extent, size, rel)) = stack.pop() {
            let dir = read_dir_record(&mut self.file, extent, size).map_err(IsoErr::Io)?;
            for (name, ext, sz, is_dir) in parse_entries(&dir) {
                if !is_visible_entry(&name) {
                    continue;
                }
                if is_dir && name.eq_ignore_ascii_case("[BOOT]") {
                    saw_boot = true;
                    continue;
                }
                let child = if rel.is_empty() {
                    name.clone()
                } else {
                    format!("{}/{}", rel, name)
                };
                if is_dir {
                    stack.push((ext, sz, child.clone()));
                }
                out.push(TreeEntry {
                    iso_rel: child,
                    extent: ext,
                    size: sz as u64,
                    is_dir,
                });
            }
        }
        Ok((out, saw_boot))
    }

    /// Locate a file by ISO-rel path, returning (extent, size).
    /// (Small duplication of the traversal in `extract_file`/`file_size`,
    /// deliberately: those are working, tested paths - not churned.)
    /// Matching is exact-first, case-insensitive fallback: relaxed-ISO trees
    /// can hold names differing only by case (`File.TxT` vs `FILE.TXT`), and
    /// first-insensitive-match would return the wrong extent for the second.
    fn locate(&mut self, path: &str) -> Result<(u64, u64), IsoErr> {
        fn pick(entries: Vec<(String, u32, u32, bool)>, want: &str, dir: bool) -> Option<(u32, u32)> {
            entries
                .iter()
                .find(|(n, _, _, d)| *d == dir && *n == *want)
                .or_else(|| {
                    entries
                        .iter()
                        .find(|(n, _, _, d)| *d == dir && n.eq_ignore_ascii_case(want))
                })
                .map(|(_, extent, size, _)| (*extent, *size))
        }
        let mut parts: Vec<&str> = path.split('/').filter(|p| !p.is_empty()).collect();
        let fname = parts.pop().ok_or(IsoErr::NotIso9660)?.to_string();
        let mut cur_extent = self.root_extent;
        let mut cur_size = self.root_size;
        for part in &parts {
            let d = read_dir_record(&mut self.file, cur_extent, cur_size).map_err(IsoErr::Io)?;
            let hit = pick(parse_entries(&d), part, true).ok_or(IsoErr::NotIso9660)?;
            cur_extent = hit.0;
            cur_size = hit.1;
        }
        let dir = read_dir_record(&mut self.file, cur_extent, cur_size).map_err(IsoErr::Io)?;
        pick(parse_entries(&dir), &fname, false)
            .map(|(extent, size)| (extent as u64, size as u64))
            .ok_or(IsoErr::NotIso9660)
    }

    pub fn file_size(&mut self, path: &str) -> Option<u64> {
        let mut parts: Vec<&str> = path.split('/').filter(|p| !p.is_empty()).collect();
        let fname = parts.pop()?.to_string();
        let dirpath = parts.join("/");
        let dir = self.list_dir(&dirpath).ok()?;
        // find via read of the dir extents
        let mut cur_extent = self.root_extent;
        let mut cur_size = self.root_size;
        if !dirpath.is_empty() {
            for part in dirpath.split('/') {
                if part.is_empty() {
                    continue;
                }
                let d = read_dir_record(&mut self.file, cur_extent, cur_size).ok()?;
                let e = parse_entries(&d);
                let hit = e
                    .iter()
                    .find(|(n, _, _, is_dir)| *is_dir && n.eq_ignore_ascii_case(part))?;
                cur_extent = hit.1;
                cur_size = hit.2;
            }
        }
        let _ = dir;
        let d = read_dir_record(&mut self.file, cur_extent, cur_size).ok()?;
        parse_entries(&d)
            .into_iter()
            .find(|(n, _, _, is_dir)| !*is_dir && n.eq_ignore_ascii_case(&fname))
            .map(|(_, _, size, _)| size as u64)
    }
}

/// One extracted file: ISO source path, absolute dest path as written,
/// size. Returned so callers can verify (compare against the ISO) and
/// generate boot entries pointing at the tree.
#[derive(Clone, Debug)]
pub struct ExtractedFile {
    pub iso_rel: String,
    pub dest: String,
    pub size: u64,
}

#[derive(Clone, Debug, Default)]
pub struct ExtractStats {
    pub files: Vec<ExtractedFile>,
    pub dirs: u64,
    pub bytes: u64,
    pub remapped: u64,
    pub collisions: u64,
    pub skipped_boot: bool,
}

/// Split `name` into (stem, extension) at the last dot for `~n` suffixing.
fn split_suffix(name: &str) -> (String, String) {
    match name.rfind('.') {
        Some(i) if i > 0 => (name[..i].to_string(), name[i..].to_string()),
        _ => (name.to_string(), String::new()),
    }
}

impl Iso {
    /// Extract the whole tree to `dest_root` (created), skipping `[BOOT]`.
    /// Two passes: enumerate for true totals, then stream each file once.
    /// Names are sanitized per component with per-directory collision
    /// suffixes; every filesystem op goes through `verbatim_path`.
    /// `progress(bytes_done, bytes_total)`. Overwrites existing files.
    pub fn extract_tree(
        &mut self,
        dest_root: &str,
        progress: &mut dyn FnMut(u64, u64),
    ) -> Result<ExtractStats, IsoErr> {
        let (entries, skipped_boot) = self.enumerate()?;
        let total: u64 = entries.iter().filter(|e| !e.is_dir).map(|e| e.size).sum();
        progress(0, total);
        let mut stats = ExtractStats {
            skipped_boot,
            ..Default::default()
        };
        crate::sys::create_dir_all(&verbatim_path(dest_root));
        // raw parent-rel -> sanitized parent-rel, so children of renamed
        // directories land consistently no matter the walk order.
        let mut dir_map: std::collections::HashMap<String, String> =
            std::collections::HashMap::new();
        // sanitized parent-rel -> lowercased leaf names already taken.
        let mut used: std::collections::HashMap<String, std::collections::HashSet<String>> =
            std::collections::HashMap::new();
        let mut done = 0u64;
        for e in &entries {
            let slash = e.iso_rel.rfind('/');
            let (praw, leaf_raw) = match slash {
                Some(i) => (e.iso_rel[..i].to_string(), &e.iso_rel[i + 1..]),
                None => (String::new(), e.iso_rel.as_str()),
            };
            let psan = if praw.is_empty() {
                String::new()
            } else {
                dir_map.get(&praw).cloned().unwrap_or_else(|| praw.clone())
            };
            let mut leaf = sanitize_component(leaf_raw);
            if leaf != leaf_raw {
                stats.remapped += 1;
            }
            let set = used.entry(psan.clone()).or_default();
            let mut cand = leaf.clone();
            let mut n = 0u32;
            while set.contains(&cand.to_ascii_lowercase()) {
                n += 1;
                stats.collisions += 1;
                let (stem, ext) = split_suffix(&leaf);
                cand = format!("{}~{}{}", stem, n, ext);
            }
            set.insert(cand.to_ascii_lowercase());
            leaf = cand;
            let rel = if psan.is_empty() {
                leaf.clone()
            } else {
                format!("{}/{}", psan, leaf)
            };
            if e.is_dir {
                dir_map.insert(e.iso_rel.clone(), rel.clone());
                crate::sys::create_dir_all(&verbatim_path(&format!("{}\\{}", dest_root, rel.replace('/', "\\"))));
                stats.dirs += 1;
                continue;
            }
            let dest_fs = format!("{}\\{}", dest_root, rel.replace('/', "\\"));
            let mut out = std::fs::File::create(verbatim_path(&dest_fs)).map_err(IsoErr::Io)?;
            let mut prog = |d: u64, _t: u64| progress(done + d, total);
            self.stream_to_file(e.extent, e.size, &mut out, &mut prog)?;
            done += e.size;
            stats.bytes += e.size;
            stats.files.push(ExtractedFile {
                iso_rel: e.iso_rel.clone(),
                dest: dest_fs,
                size: e.size,
            });
        }
        progress(done, total);
        Ok(stats)
    }

    /// Re-read every extracted file and its ISO source, comparing bytes.
    /// Catches extractor bugs (sanitizer/collision), media errors, and
    /// truncation - no hashes, no extra crates. Returns the ISO-rel paths
    /// that mismatch (empty = clean); unreadable sides are reported too.
    pub fn verify_tree(&mut self, files: &[ExtractedFile]) -> Result<Vec<String>, IsoErr> {
        let mut bad = Vec::new();
        for f in files {
            let loc = match self.locate(&f.iso_rel) {
                Ok(l) => l,
                Err(_) => {
                    bad.push(format!("{} (vanished from ISO)", f.iso_rel));
                    continue;
                }
            };
            if loc.1 != f.size {
                bad.push(format!("{} (size changed)", f.iso_rel));
                continue;
            }
            let mut df = match std::fs::File::open(verbatim_path(&f.dest)) {
                Ok(x) => x,
                Err(e) => {
                    bad.push(format!("{} (unreadable: {})", f.iso_rel, e));
                    continue;
                }
            };
            if df.metadata().map(|m| m.len()).unwrap_or(u64::MAX) != f.size {
                bad.push(format!("{} (dest size mismatch)", f.iso_rel));
                continue;
            }
            self.file
                .seek(SeekFrom::Start(loc.0 * SECTOR))
                .map_err(IsoErr::Io)?;
            let mut buf_i = vec![0u8; 1 << 20];
            let mut buf_d = vec![0u8; 1 << 20];
            let mut left = f.size;
            let mut ok = true;
            while left > 0 {
                let n = left.min(buf_i.len() as u64) as usize;
                if self.file.read_exact(&mut buf_i[..n]).is_err() {
                    ok = false;
                    break;
                }
                if df.read_exact(&mut buf_d[..n]).is_err() {
                    ok = false;
                    break;
                }
                if buf_i[..n] != buf_d[..n] {
                    ok = false;
                    break;
                }
                left -= n as u64;
            }
            if !ok {
                bad.push(f.iso_rel.clone());
            }
        }
        Ok(bad)
    }
}

pub struct LiveIsoCheck {
    pub info: String,
    pub dists: Vec<String>,
}

/// Test-LiveIso equivalent (no mount needed).
pub fn check_live_iso(path: &str) -> Result<LiveIsoCheck, String> {
    let mut iso = Iso::open(path).map_err(|e| format!("{}: {}", path, e))?;
    // validates the squashfs exists (its size is not needed downstream)
    iso.file_size("casper/filesystem.squashfs")
        .ok_or_else(|| "Not a casper/Ubuntu-family live image (no casper\\filesystem.squashfs).".to_string())?;
    let info = String::from_utf8_lossy(
        &iso.read_file(".disk/info", 4096).unwrap_or_default(),
    )
    .trim()
    .to_string();
    let dists: Vec<String> = iso
        .list_dir("dists")
        .map(|v| v.into_iter().filter(|(_, d)| *d).map(|(n, _)| n).collect())
        .unwrap_or_default();
    Ok(LiveIsoCheck { info, dists })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_non_iso() {
        let tmp = std::env::temp_dir().join("lsl-not-iso.iso");
        std::fs::write(&tmp, vec![0u8; 4096]).unwrap();
        let r = check_live_iso(tmp.to_str().unwrap());
        assert!(r.is_err());
        let _ = std::fs::remove_file(&tmp);
    }

    // --- synthetic ISO9660 image for tree tests (sectors, not gigabytes) ---
    fn dir_record(name: &[u8], extent: u32, size: u32, is_dir: bool) -> Vec<u8> {
        let total = 33 + name.len() + (33 + name.len()) % 2; // even length
        let mut r = vec![0u8; total];
        r[0] = total as u8;
        r[2..6].copy_from_slice(&extent.to_le_bytes());
        r[6..10].copy_from_slice(&extent.to_be_bytes());
        r[10..14].copy_from_slice(&size.to_le_bytes());
        r[14..18].copy_from_slice(&size.to_be_bytes());
        r[25] = if is_dir { 2 } else { 0 };
        r[28..30].copy_from_slice(&1u16.to_le_bytes());
        r[30..32].copy_from_slice(&1u16.to_be_bytes());
        r[32] = name.len() as u8;
        r[33..33 + name.len()].copy_from_slice(name);
        r
    }

    fn make_test_iso() -> Vec<u8> {
        // sectors: 16 PVD, 20 root dir, 21 SUB dir, 22..28 contents.
        let mut img = vec![0u8; 29 * 2048];
        img[16 * 2048] = 1;
        img[16 * 2048 + 1..16 * 2048 + 6].copy_from_slice(b"CD001");
        img[16 * 2048 + 6] = 1;
        let mut rr = vec![0u8; 34];
        rr[0] = 34;
        rr[2..6].copy_from_slice(&20u32.to_le_bytes());
        rr[10..14].copy_from_slice(&2048u32.to_le_bytes());
        img[16 * 2048 + 156..16 * 2048 + 190].copy_from_slice(&rr);
        let mut root = Vec::new();
        root.extend(dir_record(b"SUB", 21, 2048, true));
        root.extend(dir_record(b"A:B", 22, 10, false));
        root.extend(dir_record(b"File.TxT;1", 23, 8, false));
        root.extend(dir_record(b"FILE.TXT;1", 24, 8, false));
        root.extend(dir_record(b"CON", 25, 8, false));
        root.extend(dir_record(b"small.bin", 26, 5, false));
        root.extend(dir_record(b"[BOOT]", 27, 2048, true));
        img[20 * 2048..20 * 2048 + root.len()].copy_from_slice(&root);
        let mut sub = Vec::new();
        sub.extend(dir_record(b"inner.dat", 28, 5, false));
        img[21 * 2048..21 * 2048 + sub.len()].copy_from_slice(&sub);
        let blobs: &[(u32, &[u8])] = &[
            (22, b"colon-file"),
            (23, b"case-one"),
            (24, b"case-two"),
            (25, b"reserved"),
            (26, b"small"),
            (28, b"inner"),
        ];
        for (ext, data) in blobs {
            img[*ext as usize * 2048..*ext as usize * 2048 + data.len()].copy_from_slice(data);
        }
        img
    }

    #[test]
    fn synthetic_iso_lists_relaxed_names() {
        let img = make_test_iso();
        let tmp = std::env::temp_dir().join("lsl-synth.iso");
        std::fs::write(&tmp, &img).unwrap();
        let mut iso = Iso::open(tmp.to_str().unwrap()).unwrap();
        let mut names: Vec<String> = iso.list_dir("").unwrap().into_iter().map(|(n, _)| n).collect();
        names.sort();
        // [BOOT] IS listed (listing doesn't filter it; the walker skips it).
        assert_eq!(
            names,
            // byte order (sort() is not case-folded)
            vec!["A:B", "CON", "FILE.TXT", "File.TxT", "SUB", "[BOOT]", "small.bin"]
        );
        let _ = std::fs::remove_file(&tmp);
    }

    // Live-proof helper (not a test): Mint ISO path or None so ignored
    // tests skip cleanly. Set LSL_TEST_ISO or drop
    // linuxmint-22.3-cinnamon-64bit.iso in Downloads.
    fn mint_iso_path() -> Option<String> {
        let iso_path = std::env::var("LSL_TEST_ISO").unwrap_or_else(|_| {
            let profile = std::env::var("USERPROFILE").unwrap_or_default();
            format!(
                "{}\\Downloads\\linuxmint-22.3-cinnamon-64bit.iso",
                profile.trim_end_matches('\\')
            )
        });
        std::path::Path::new(&iso_path)
            .is_file()
            .then(|| iso_path)
    }

    #[test]
    #[ignore]
    // Pulls just the base squashfs out via our own reader (for unsquashfs
    // inspection elsewhere). Skips cleanly without the ISO present.
    fn live_extract_squashfs_only() {
        let Some(iso_path) = mint_iso_path() else {
            eprintln!("skipping squashfs pull (no ISO)");
            return;
        };
        let dest = std::env::temp_dir().join(format!("lsl-base-sqfs-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dest);
        std::fs::create_dir_all(&dest).unwrap();
        let out = dest.join("filesystem.squashfs");
        let mut iso = Iso::open(&iso_path).unwrap();
        let want = iso.file_size("casper/filesystem.squashfs").unwrap();
        let t0 = std::time::Instant::now();
        let n = iso
            .extract_file(
                "casper/filesystem.squashfs",
                out.to_str().unwrap(),
                &mut |done, total| {
                    if done % (512 << 20) < (4 << 20) {
                        eprintln!("  {:.1} / {:.1} GB", done as f64 / 1073741824.0, total as f64 / 1073741824.0);
                    }
                },
            )
            .unwrap();
        assert_eq!(n, want);
        eprintln!(
            "pulled {:.2} GB in {:.0}s -> {}",
            n as f64 / 1073741824.0,
            t0.elapsed().as_secs_f64(),
            out.to_string_lossy()
        );
    }

    fn live_mint_extract_and_verify() {
        let Some(iso_path) = mint_iso_path() else {
            eprintln!("skipping live extract (no ISO found)");
            return;
        };
        let dest = std::env::temp_dir().join(format!("lsl-live-tree-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dest);
        let mut iso = Iso::open(&iso_path).unwrap();
        let t0 = std::time::Instant::now();
        let stats = iso
            .extract_tree(dest.to_str().unwrap(), &mut |done, total| {
                if done % (512 << 20) < (4 << 20) {
                    eprintln!(
                        "  {:.1} / {:.1} GB",
                        done as f64 / 1073741824.0,
                        total as f64 / 1073741824.0
                    );
                }
            })
            .unwrap();
        eprintln!(
            "extracted {} files + {} dirs, {:.2} GB in {:.0}s ({} remapped, {} collisions, boot skipped: {})",
            stats.files.len(),
            stats.dirs,
            stats.bytes as f64 / 1073741824.0,
            t0.elapsed().as_secs_f64(),
            stats.remapped,
            stats.collisions,
            stats.skipped_boot
        );
        assert!(stats.files.len() > 1000);
        // NOTE: no [BOOT] here - 7z virtualizes El Torito images as a
        // pseudo-dir; they are not ISO9660 tree entries (hence the 2-file
        // delta vs the 7z listing). The synthetic test covers the skip path.
        assert!(!stats.skipped_boot);
        let t1 = std::time::Instant::now();
        let bad = iso.verify_tree(&stats.files).unwrap();
        eprintln!("verified in {:.0}s, mismatches: {:?}", t1.elapsed().as_secs_f64(), bad);
        assert!(bad.is_empty(), "mismatches: {:?}", bad);
        // Boot-critical files land where the direct entries expect them.
        for rel in ["casper/vmlinuz", "casper/filesystem.squashfs", "boot/grub/grub.cfg"] {
            assert!(
                stats.files.iter().any(|f| f.iso_rel.eq_ignore_ascii_case(rel)),
                "missing {}",
                rel
            );
        }
        let _ = std::fs::remove_dir_all(&dest);
    }

    #[test]
    fn sanitize_and_verbatim_table() {
        assert_eq!(sanitize_component("a:b"), "a%3Ab"); // trailing 'b' is literal; hex itself is upper
        assert_eq!(sanitize_component("A:B"), "A%3AB"); // 0x3A -> %3A, uppercase hex
        assert_eq!(sanitize_component("plain.txt"), "plain.txt");
        assert_eq!(sanitize_component("CON"), "_CON");
        assert_eq!(sanitize_component("aux.log"), "_aux.log");
        assert_eq!(sanitize_component("trailing."), "trailing");
        assert_eq!(sanitize_component("..."), "_");
        assert_eq!(split_suffix("a.b.c"), ("a.b".to_string(), ".c".to_string()));
        assert_eq!(split_suffix("noext"), ("noext".to_string(), String::new()));
        assert_eq!(verbatim_path(r"D:\x\y"), r"\\?\D:\x\y");
        assert_eq!(verbatim_path(r"D:/x"), r"\\?\D:\x");
        assert_eq!(verbatim_path(r"\\?\D:\x"), r"\\?\D:\x");
        assert_eq!(verbatim_path("rel\\x"), "rel\\x");
    }

    #[test]
    fn tree_extract_sanitizes_and_verifies() {
        let img = make_test_iso();
        let tmp = std::env::temp_dir().join("lsl-synth2.iso");
        std::fs::write(&tmp, &img).unwrap();
        let dest = std::env::temp_dir().join(format!("lsl-iso-tree-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dest);
        let mut iso = Iso::open(tmp.to_str().unwrap()).unwrap();
        let stats = iso
            .extract_tree(dest.to_str().unwrap(), &mut |_, _| {})
            .unwrap();
        assert_eq!(stats.dirs, 1); // SUB only; [BOOT] skipped
        assert!(stats.skipped_boot);
        assert_eq!(stats.remapped, 2); // A:B -> A%3AB, CON -> _CON
        assert_eq!(stats.collisions, 1); // File.TxT vs FILE.TXT
        assert_eq!(stats.bytes, 10 + 8 + 8 + 8 + 5 + 5);
        assert_eq!(stats.files.len(), 6);
        let names: std::collections::HashSet<String> = stats
            .files
            .iter()
            .map(|f| f.dest.rsplit(['\\', '/']).next().unwrap().to_string())
            .collect();
        for n in ["A%3AB", "File.TxT", "FILE~1.TXT", "_CON", "small.bin", "inner.dat"] {
            assert!(names.contains(n), "missing {}", n);
        }
        assert_eq!(std::fs::read(dest.join("SUB").join("inner.dat")).unwrap(), b"inner");
        // clean verify, then tamper + delete are both reported.
        let bad = iso.verify_tree(&stats.files).unwrap();
        assert!(bad.is_empty(), "unexpected mismatches: {:?}", bad);
        std::fs::write(dest.join("small.bin"), b"XXXXX").unwrap();
        std::fs::remove_file(dest.join("SUB").join("inner.dat")).unwrap();
        let bad2 = iso.verify_tree(&stats.files).unwrap();
        assert_eq!(bad2.len(), 2);
        let _ = std::fs::remove_dir_all(&dest);
        let _ = std::fs::remove_file(&tmp);
    }
}
