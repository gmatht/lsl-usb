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
            .filter(|(n, _, _, _)| n != "." && n != ".." && !n.starts_with('\0'))
            .map(|(n, _, _, d)| (n, d))
            .collect())
    }

    pub fn read_file(&mut self, path: &str, max: usize) -> Result<Vec<u8>, IsoErr> {
        let mut parts: Vec<&str> = path.split('/').filter(|p| !p.is_empty()).collect();
        let fname = parts.pop().unwrap_or("").to_string();
        let dirpath = parts.join("/");
        let dir = self.list_dir(&dirpath)?;
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

pub struct LiveIsoCheck {
    pub info: String,
    pub dists: Vec<String>,
    pub sfs_size: Option<u64>,
}

/// Test-LiveIso equivalent (no mount needed).
pub fn check_live_iso(path: &str) -> Result<LiveIsoCheck, String> {
    let mut iso = Iso::open(path).map_err(|e| format!("{}: {}", path, e))?;
    let has_casper = iso
        .file_size("casper/filesystem.squashfs")
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
    Ok(LiveIsoCheck { info, dists, sfs_size: Some(has_casper) })
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
}
