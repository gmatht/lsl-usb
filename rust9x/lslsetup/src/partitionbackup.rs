//! Partition-layout records: the restorable half of the F2FS provisioning
//! safety net.
//!
//! ## Why this exists
//!
//! `initramfs/lsl_f2fs_provision.sh` shrinks the stick's FAT **filesystem**
//! (fatresize) and then rewrites its partition table (sfdisk). If either step
//! goes wrong the stick does not boot, and there is nothing on it to boot from.
//! This module records the layout that existed *before* the run so a restore
//! tool has exact geometry to work from.
//!
//! ## What a record is NOT
//!
//! It is **not** a file backup. The shrink happens first, so by the time the
//! table is rewritten the directory entries and f2fs metadata are already gone.
//! A restored table gives you geometry to rebuild on - not the user's files.
//! That limit is inherent to the operation and is why this is a safety net for
//! the *medium*, not a substitute for a backup.
//!
//! ## Keys
//!
//! `<machine-id><shortest-unique-date>` - a machine prefix followed by the
//! timestamp, truncated to the shortest prefix still unique among the keys
//! that share that prefix. Keeping the date truncatable is the whole reason the
//! machine prefix leads: two runs on one machine are the only realistic
//! collision, so uniqueness is decided among a handful of siblings and the
//! enumeration stays bounded.
//!
//! Phases are SEPARATE keys (`.../pre`, `.../post`), never one record that is
//! rewritten. A same-second re-run would otherwise overwrite the only
//! restorable copy - the exact failure this exists to prevent.
//!
//! ## Units
//!
//! Everything the restore path needs is in **sectors**, matching `sfdisk`
//! (`size=` is sectors in both directions, util-linux 2.37 measured) and
//! `fatresize -s` (which takes MiB, converted at the boundary). A readable
//! "128 GB" cannot be written to a partition table, so the readable sizes in
//! this record are for humans only - `entries` is the record of truth.

use crate::sys;
use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// Capture: read a medium's layout off the physical disk.
// ---------------------------------------------------------------------------

/// A medium that could not be read, with the reason. Capture is best-effort by
/// design - a disk we cannot open (locked, virtual, in use by a VM) must not
/// abort the install, it just produces no record for that disk.
#[derive(Debug, Clone, PartialEq)]
pub struct CaptureFailure {
    pub disk: u32,
    pub reason: String,
}

/// Sectors read for the record: 0..15 plus the GPT header/table if present.
///
/// 16 sectors because that is exactly what grub4dos stage1 needs (the BIOS
/// loads only sector 0, stage1 reads 1..15) - a record without them cannot
/// restore this project's own boot area.
pub const HEAD_SECTORS: usize = 16;
const SECTOR: u64 = 512;
/// GPT: the header is at LBA 1 and the entries table follows. Reading 34
/// sectors covers the standard 128-entry table (LBA 2..33).
const GPT_SECTORS: usize = 34;

/// Read `sectors` sectors from offset 0 of `\\.\PhysicalDrive{n}`.
fn read_sectors(disk_no: u32, sectors: usize) -> Result<Vec<u8>, String> {
    use std::io::{Read, Seek, SeekFrom};
    let mut f = std::fs::OpenOptions::new()
        .read(true)
        .open(format!(r"\\.\PhysicalDrive{}", disk_no))
        .map_err(|e| format!("cannot open PhysicalDrive{disk_no}: {e}"))?;
    f.seek(SeekFrom::Start(0))
        .map_err(|e| format!("seek PhysicalDrive{disk_no}: {e}"))?;
    let mut buf = vec![0u8; sectors * SECTOR as usize];
    f.read_exact(&mut buf)
        .map_err(|e| format!("read PhysicalDrive{disk_no}: {e}"))?;
    Ok(buf)
}

/// Total size of the physical disk, in sectors.
fn disk_size_sectors(disk_no: u32) -> Option<u64> {
    use std::os::windows::io::AsRawHandle;
    use winapi::um::ioapiset::DeviceIoControl;
    use winapi::um::winioctl::{GET_LENGTH_INFORMATION, IOCTL_DISK_GET_LENGTH_INFO};
    let f = std::fs::OpenOptions::new()
        .read(true)
        .open(format!(r"\\.\PhysicalDrive{}", disk_no))
        .ok()?;
    // GET_LENGTH_INFORMATION, not DISK_LENGTH_INFORMATION: the latter is the
    // STORAGE_DEVICE_NUMBER-style name some headers use, and winapi exposes this
    // one for IOCTL_DISK_GET_LENGTH_INFO. `.Length` is a LARGE_INTEGER (bytes),
    // so divide to sectors - the unit the whole record is in.
    let mut info: GET_LENGTH_INFORMATION = unsafe { std::mem::zeroed() };
    let mut got = 0u32;
    let ok = unsafe {
        DeviceIoControl(
            f.as_raw_handle() as *mut winapi::ctypes::c_void,
            IOCTL_DISK_GET_LENGTH_INFO,
            std::ptr::null_mut(),
            0,
            &mut info as *mut _ as *mut _,
            std::mem::size_of::<GET_LENGTH_INFORMATION>() as u32,
            &mut got,
            std::ptr::null_mut(),
        )
    };
    if ok == 0 {
        return None;
    }
    // Explicit block: unsafe ops in a fn body need one on this toolchain
    // (edition 2024, rust9x).
    Some(unsafe { *info.Length.QuadPart() } as u64 / SECTOR)
}

/// Total sectors of the FAT filesystem on the partition starting at
/// `start_sectors`, from the BPB field at OFFSET 32.
///
/// Read straight off the physical disk at the partition's byte offset, so it
/// works for a partition that has no drive letter (an unmounted second
/// partition) - which is exactly the case the hook's partition 1 is in when it
/// is mid-resize.
///
/// Offset 32, not 19: 19 is the volume serial number, a random 32-bit ID fixed
/// at mkfs time. The hook read 19 for its whole life and compared a volume ID
/// against a partition size, which could never mean anything - a bug this
/// project has already paid for once (see the hook's own comment).
///
/// This is the number that makes restore COMPLETE: the partition table alone
/// would leave a filesystem smaller than its partition after a restore, and
/// growing it back needs exactly this.
pub fn fat_bpb_sectors(disk_no: u32, start_sectors: u64) -> Option<u64> {
    use std::io::{Read, Seek, SeekFrom};
    let mut f = std::fs::OpenOptions::new()
        .read(true)
        .open(format!(r"\\.\PhysicalDrive{}", disk_no))
        .ok()?;
    f.seek(SeekFrom::Start(start_sectors * SECTOR + 32)).ok()?;
    let mut b = [0u8; 4];
    f.read_exact(&mut b).ok()?;
    let v = u32::from_le_bytes(b) as u64;
    // A FAT32 volume's BPB holds a 16-bit total at 0x13 when the 32-bit field
    // reads 0; treat 0 as unreadable rather than recording a bogus size.
    if v == 0 {
        return None;
    }
    Some(v)
}

/// Parse GPT partition entries out of the header + entry array.
///
/// The header carries the entries' LBA (offset 72, u64) and each entry is 128
/// bytes with `first_lba`/`last_lba` as u64, so entries past 2 TiB are read
/// correctly - an MBR's u32 `start_lba` simply cannot express them, which is
/// one reason restore must know the scheme.
fn parse_gpt(head: &[u8]) -> Option<Vec<PartitionEntry>> {
    if head.len() < GPT_SECTORS * SECTOR as usize {
        return None;
    }
    let hdr = &head[SECTOR as usize..(2 * SECTOR as usize)];
    if &hdr[0..8] != b"EFI PART" {
        return None;
    }
    let entries_lba = u64::from_le_bytes(hdr[72..80].try_into().ok()?);
    let entry_count = u32::from_le_bytes(hdr[80..84].try_into().ok()?) as usize;
    let entry_size = u32::from_le_bytes(hdr[84..88].try_into().ok()?) as usize;
    // Sanity-bound the parse: a corrupt header claiming millions of entries
    // must not make us walk off the buffer or allocate unboundedly.
    if entry_size < 128 || entry_size > 4096 || entry_count == 0 || entry_count > 4096 {
        return None;
    }
    let mut out = Vec::new();
    for i in 0..entry_count {
        let off = entries_lba as usize * SECTOR as usize + i * entry_size;
        if off + entry_size > head.len() {
            break;
        }
        let e = &head[off..off + entry_size];
        let first = u64::from_le_bytes(e[32..40].try_into().ok()?);
        let last = u64::from_le_bytes(e[40..48].try_into().ok()?);
        // An unused entry has a zero type GUID; stop at the first gap.
        if e[0..16].iter().all(|b| *b == 0) {
            break;
        }
        if last < first {
            continue;
        }
        out.push(PartitionEntry {
            index: (i + 1) as u32,
            start_sectors: first,
            size_sectors: last - first + 1,
            type_id: format!("{:02X}", e[4]),
            bootable: false,
            label: gpt_label_utf16le(&e[56..128]),
        });
    }
    if out.is_empty() { None } else { Some(out) }
}

/// GPT labels are UTF-16LE, null-terminated, in 72 bytes (36 chars).
fn gpt_label_utf16le(b: &[u8]) -> String {
    let mut units = Vec::new();
    for pair in b.chunks_exact(2) {
        let u = u16::from_le_bytes([pair[0], pair[1]]);
        if u == 0 {
            break;
        }
        units.push(u);
    }
    String::from_utf16_lossy(&units)
}

/// Capture one physical disk's layout.
///
/// `disk_no` is a `PhysicalDriveN` number. Read-only throughout: this must
/// never be able to modify what it is recording.
pub fn capture_disk(disk_no: u32) -> Result<DiskRecord, String> {
    // 34 sectors covers sectors 0..15 (the boot area) plus the GPT header and
    // entry array. A 16-sector read would miss GPT entirely and silently record
    // an MBR-shaped empty table for a GPT disk - the worst kind of wrong.
    let head = read_sectors(disk_no, GPT_SECTORS)?;
    let gpt = parse_gpt(&head);
    let is_gpt = gpt.is_some();

    let mut mbr = [0u8; 512];
    mbr.copy_from_slice(&head[..512]);
    let mbr_parts = crate::nofmt::parse_mbr_parts(&mbr);

    let (scheme, entries) = match (is_gpt, mbr_parts) {
        (true, _) => ("gpt".to_string(), gpt.unwrap_or_default()),
        // parse_mbr_parts returns None for a protective MBR (which is what a
        // GPT disk looks like) or an empty table. Neither is an error worth
        // refusing the whole disk over: record it as mbr with no entries and
        // let restore say "nothing to restore here".
        (false, Some(parts)) => {
            let mut v: Vec<PartitionEntry> = parts
                .iter()
                .map(|p| PartitionEntry {
                    index: 0,
                    start_sectors: p.start_lba as u64,
                    size_sectors: p.sectors as u64,
                    type_id: format!("{:02x}", p.typ),
                    bootable: p.boot != 0,
                    label: String::new(),
                })
                .collect();
            for (i, e) in v.iter_mut().enumerate() {
                e.index = (i + 1) as u32;
            }
            ("mbr".to_string(), v)
        }
        (false, None) => ("mbr".to_string(), Vec::new()),
    };

    // The BPB of partition 1, read at that partition's own byte offset on the
    // physical disk. Only meaningful for a FAT partition - on a GPT disk whose
    // first entry is an EFI System Partition there is no FAT BPB to read, and
    // a bogus number here would make restore grow a filesystem that does not
    // exist.
    let fs_size_sectors = match entries.first() {
        Some(e) if e.type_id.eq_ignore_ascii_case("0c") || e.type_id.eq_ignore_ascii_case("0b")
            || e.type_id.eq_ignore_ascii_case("06") || e.type_id.eq_ignore_ascii_case("0e") =>
        {
            fat_bpb_sectors(disk_no, e.start_sectors)
        }
        _ => None,
    };

    Ok(DiskRecord {
        size_sectors: disk_size_sectors(disk_no).unwrap_or(0),
        scheme,
        entries,
        fs_size_sectors,
        head_sectors_hex: hex_encode(&head[..HEAD_SECTORS * SECTOR as usize]),
        serial_number: crate::nofmt::disk_serial_number(disk_no),
    })
}

/// Capture every fixed/removable physical disk reachable from the volume list.
///
/// Volume letters are the only enumeration primitive that works on Windows 9x
/// (the minimum target), so disks are discovered via `\\.\<letter>:` and then
/// resolved to a `PhysicalDriveN`. Duplicates are collapsed - one disk with
/// several volumes must be recorded ONCE, or the restore step would be offered
/// the same geometry twice.
pub fn capture_all_disks() -> (Vec<DiskRecord>, Vec<CaptureFailure>) {
    let mut by_disk: std::collections::BTreeMap<u32, DiskRecord> = Default::default();
    let mut fails = Vec::new();
    for v in sys::list_volumes() {
        if v.cdrom {
            continue;
        }
        // Only media that hold a partition table are worth recording: an
        // optical drive has no sectors 0..15 in the sense restore needs, and
        // network drives would fail the physical-disk resolve anyway.
        let Ok(disk_no) = crate::nofmt::physical_drive_number(&v.letter) else {
            continue;
        };
        if by_disk.contains_key(&disk_no) {
            continue;
        }
        match capture_disk(disk_no) {
            Ok(rec) => {
                by_disk.insert(disk_no, rec);
            }
            Err(e) => fails.push(CaptureFailure {
                disk: disk_no,
                reason: e,
            }),
        }
    }
    (by_disk.into_values().collect(), fails)
}

/// One partition as it exists on the medium. Sectors, always.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PartitionEntry {
    /// Index in the table (1-based, as printed).
    pub index: u32,
    pub start_sectors: u64,
    pub size_sectors: u64,
    /// sfdisk type string, e.g. `0c`, `83`.
    #[serde(default)]
    pub type_id: String,
    #[serde(default)]
    pub bootable: bool,
    /// Volume label, for a human reading the record. Never load-bearing:
    /// labels are routinely blank or duplicated.
    #[serde(default)]
    pub label: String,
}

/// What one medium looked like at the moment the record was taken.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DiskRecord {
    /// Whole-disk size in sectors, from `blockdev --getsz` on the Linux side.
    pub size_sectors: u64,
    /// `mbr` or `gpt`. Restore differs between them, so this must not be
    /// inferred from the entries.
    pub scheme: String,
    pub entries: Vec<PartitionEntry>,
    /// The FAT filesystem's own total-sector field (BPB offset 32) on
    /// partition 1, when it was readable. This is the number that makes
    /// restore *complete*: the table alone leaves a filesystem smaller than its
    /// partition, and growing it back needs this.
    #[serde(default)]
    pub fs_size_sectors: Option<u64>,
    /// Bytes 0..15 (1 KiB) as hex: boot record, partition table, GPT header.
    /// This project depends on exactly these sectors (grub4dos stage1 needs
    /// 1..15), so a record without them is not restorable on this stick.
    #[serde(default)]
    pub head_sectors_hex: String,
    /// Disk serial number from the firmware (STORAGE_DEVICE_DESCRIPTOR).
    /// Used for KeyVal keys; best-effort.
    #[serde(default)]
    pub serial_number: Option<String>,
}

impl DiskRecord {
    /// Concise JSON for KeyVal storage (<300 chars). Omits bootable, label,
    /// index, and head_sectors_hex to stay within the limit.
    pub fn concise_json(&self) -> String {
        let pt: Vec<String> = self.entries.iter().map(|e| {
            format!(
                "{{\"s\":{},\"n\":{},\"t\":\"{}\"}}",
                e.start_sectors, e.size_sectors, e.type_id
            )
        }).collect();
        let fs = match self.fs_size_sectors {
            Some(f) => format!(",\"fs\":{}", f),
            None => String::new(),
        };
        format!(
            "{{\"sz\":{},\"sc\":\"{}\",\"pt\":[{}]{} }}",
            self.size_sectors, self.scheme, pt.join(","), fs
        )
    }
}

/// Human-readable disk size from sector count, e.g. `128G`, `32G`, `500M`.
///
/// Rounds to the nearest whole unit that fits in 3-4 characters so the KeyVal
/// key stays short. Used in the key path `DISK_SERIAL-SIZE`.
pub fn human_size(sectors: u64) -> String {
    let bytes = sectors * 512;
    if bytes >= 1_000_000_000_000 {
        format!("{}T", bytes / 1_000_000_000_000)
    } else if bytes >= 1_000_000_000 {
        format!("{}G", (bytes + 500_000_000) / 1_000_000_000)
    } else if bytes >= 1_000_000 {
        format!("{}M", (bytes + 500_000) / 1_000_000)
    } else {
        format!("{}K", (bytes + 500) / 1000)
    }
}

/// Which side of the repartition this record was taken from.
///
/// Serialized as the same lowercase string used in the key (`pre`/`post`), so a
/// record's `phase` field can be compared against the phase segment of its own
/// key without a mapping table at the consumer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Phase {
    /// Before lslsetup touched anything. Documentary only - lslsetup rewrites
    /// sectors 1..15 itself, so this is already stale for those bytes by the
    /// time the hook runs.
    Found,
    /// After every lslsetup write, before reboot. The restorable one.
    Pre,
    /// After the hook repartitioned and formatted. A receipt, not a backup:
    /// the pre state no longer exists on the medium, so this proves what the
    /// tool did and cannot recover it.
    Post,
}

impl Phase {
    pub fn as_str(self) -> &'static str {
        match self {
            Phase::Found => "found",
            Phase::Pre => "pre",
            Phase::Post => "post",
        }
    }

    pub fn parse(s: &str) -> Option<Phase> {
        match s {
            "found" => Some(Phase::Found),
            "pre" => Some(Phase::Pre),
            "post" => Some(Phase::Post),
            _ => None,
        }
    }
}

impl std::fmt::Display for Phase {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// One recorded run.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BackupRecord {
    /// Full, untruncated timestamp. The KEY may be truncated to a shortest
    /// unique prefix; this field is what makes a truncated key recoverable to
    /// its full date, so a forgotten date is never a dead end.
    pub timestamp: String,
    pub phase: Phase,
    /// The target volume letter, e.g. `D:`. Human-facing.
    #[serde(default)]
    pub vol_letter: String,
    #[serde(default)]
    pub lslsetup_version: String,
    /// Machine identity, for a human confirming "is this my machine?". Not
    /// part of the key's correctness - the machine prefix is.
    #[serde(default)]
    pub motherboard: String,
    #[serde(default)]
    pub windows_version: String,
    pub disks: Vec<DiskRecord>,
}

/// Directory on the stick holding the local index. The local copy is the
/// authoritative record: the online one is best-effort, and the hook runs with
/// no network at all.
pub const LOCAL_INDEX_DIR: &str = "lsl-partition-backup";

/// Build the timestamp used for keys: `YYMMDD:HHMMSS`.
///
/// Shortest-unique-prefix truncation works on this, so it must be in the order
/// the operator reads: year, month, day, hour, minute, second. Unlike
/// `telemetry::timestamp_compact` (which is `YYYYMMDD-HHMMSS` and starts with
/// four digits of year) this front-loads the fields that differ most between
/// runs, so the common case truncates after a few characters.
pub fn timestamp_key(secs: u64) -> String {
    let days = secs / 86400;
    let tod = secs % 86400;
    let (y, m, d) = civil_from_days(days as i64);
    format!(
        "{:02}{:02}{:02}:{:02}{:02}{:02}",
        y % 100,
        m,
        d,
        tod / 3600,
        (tod % 3600) / 60,
        tod % 60
    )
}

/// Shorten `candidate` to the shortest prefix that no entry of `siblings`
/// shares - i.e. the shortest unique prefix (SUP) of the set.
///
/// `siblings` must be the keys that share `candidate`'s machine prefix;
/// passing the whole keyspace would be correct but unbounded, and passing too
/// few can yield a prefix that collides with a key not in the list. Every
/// caller supplies the machine's own keys.
///
/// A candidate that already exists is extended until it is unique, so calling
/// this twice with the same inputs is stable rather than silently colliding.
pub fn shortest_unique_prefix(candidate: &str, siblings: &[String]) -> String {
    // A prefix of length n is unique when no other key has it. Walk the length
    // up one character at a time and stop at the first that is alone.
    let bytes = candidate.as_bytes();
    for len in 1..=bytes.len() {
        // Respect char boundaries: this is a UTF-8 string and a slice that
        // split one would panic.
        if len < bytes.len() && !candidate.is_char_boundary(len) {
            continue;
        }
        let prefix = &candidate[..len];
        let clashes = siblings
            .iter()
            .filter(|k| k.as_str() != candidate && k.starts_with(prefix))
            .count();
        if clashes == 0 {
            return prefix.to_string();
        }
    }
    // Unreachable while `candidate` itself is in `siblings`, but a caller that
    // excluded it must still get something usable rather than an empty key.
    candidate.to_string()
}

/// `<machine-prefix><shortest-unique-date>` - the run key, without a phase.
pub fn run_key(machine_id: &str, date: &str, siblings: &[String]) -> String {
    format!("{machine_id}{}", shortest_unique_prefix(date, siblings))
}

/// Full key for one phase of one run.
pub fn record_key(machine_id: &str, date: &str, siblings: &[String], phase: Phase) -> String {
    format!("{}/{phase}", run_key(machine_id, date, siblings))
}

/// Days since the Unix epoch to (year, month, day). Howard Hinnant's
/// `civil_from_days`, which `telemetry.rs` already uses - duplicated rather
/// than shared to keep this module free of that one's Windows-only imports.
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

/// Hex-encode bytes for the `head_sectors_hex` field. Uppercase, no
/// separators - the restore path decodes it with a trivial loop and must not
/// depend on formatting.
pub fn hex_encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push_str(&format!("{b:02X}"));
    }
    out
}

/// Inverse of [`hex_encode`]. Returns None on odd length or a non-hex digit,
/// so a corrupted record is refused rather than silently restoring garbage.
pub fn hex_decode(s: &str) -> Option<Vec<u8>> {
    if s.len() % 2 != 0 {
        return None;
    }
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(s.len() / 2);
    for pair in b.chunks(2) {
        let hi = (pair[0] as char).to_digit(16)?;
        let lo = (pair[1] as char).to_digit(16)?;
        out.push((hi * 16 + lo) as u8);
    }
    Some(out)
}

/// A stable, short, machine-local prefix. Not a security boundary - it exists
/// so keys sort grouped by machine and stay readable while recovering.
///
/// Built from the motherboard identity the telemetry probe already collects.
/// When the board reports nothing usable, the MachineGuid stands in; when both
/// are missing the prefix is `UNK`, which is honest and still collision-safe
/// because the date is unique-ified by enumeration either way.
pub fn machine_id(motherboard: &str, machine_guid: &str) -> String {
    let basis = if motherboard.trim().is_empty() {
        machine_guid
    } else {
        motherboard
    };
    if basis.trim().is_empty() {
        return "UNK".to_string();
    }
    // FNV-1a: no dependency, deterministic, and adequate for a grouping key.
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in basis.as_bytes() {
        h ^= *b as u64;
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    let mut key = format!("{:06X}", h & 0x00ff_ffff);
    // Keep the prefix uppercase-hex so the key stays a single readable token.
    key.truncate(6);
    key
}

/// Read the machine's install-specific GUID. Falls back to empty; see
/// [`machine_id`].
pub fn machine_guid() -> String {
    sys::RegKey::open(
        sys::hkcu(),
        "SOFTWARE\\Microsoft\\Cryptography",
    )
    .and_then(|k| k.value("MachineGuid"))
    .unwrap_or_default()
}

/// Take the `pre` record: capture every readable disk and write it locally.
///
/// Local-first, unconditionally, with NO dialog. Nothing leaves the machine
/// here - this is a plain file write onto the stick, so it has no consent
/// surface and therefore no way to be dismissed. Any future upload is a
/// separate, later, explicit action (see the module docs); putting an upload
/// here would put a network call in the path that runs after the boot sectors
/// have already been rewritten.
///
/// Best-effort, and it never fails the install: this is a safety net, so its own
/// failure must not be the thing that breaks a working stick. A disk we cannot
/// open produces a named skip, not an abort.
pub fn take_pre_record(vol_letter: &str) -> Result<(String, Vec<CaptureFailure>, BackupRecord), String> {
    let (disks, fails) = capture_all_disks();
    if disks.is_empty() {
        return Err("no disk could be read".into());
    }
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let rec = build_record(
        Phase::Pre,
        vol_letter,
        disks,
        secs,
        motherboard_identity(),
    );
    let key = record_key(
        &machine_id(&rec.motherboard, &machine_guid()),
        &rec.timestamp,
        // Local-first: the machine's own run keys are read from the stick, so
        // the date truncation is decided against real siblings rather than
        // guessed at. An empty list on a fresh stick truncates to one
        // character, which is correct - nothing else is there to collide with.
        &local_run_keys(vol_letter),
        Phase::Pre,
    );
    let path = write_local(vol_letter, &key, &rec)?;
    Ok((format!("{key} -> {path}"), fails, rec))
}

/// Upload each disk's layout to the online KeyVal store.
///
/// Key format: `<mobo_serial>/<N>/<disk_serial>-<size>/<stage>` where N is the
/// per-machine run counter (incremented on each F2FS install).  Size is
/// human-readable (`128G`, `32G`, …).
///
/// Also uploads `<mobo_serial>/<N>//disks` — a JSON array listing each disk's
/// serial and human-readable size so a reader can discover which disks belong
/// to a run without enumerating the key space.
///
/// Best-effort: a network failure is logged but never aborts the install.
/// Opt-out: respects `telemetry::partition_upload_allowed()`.
pub fn upload_to_keyval(rec: &BackupRecord) {
    if !crate::telemetry::partition_upload_allowed() {
        return;
    }
    let run_n = crate::telemetry::increment_partition_run_count();
    let mobo = motherboard_serial();
    let phase = rec.phase.as_str();

    // Upload each disk's layout.
    for disk in &rec.disks {
        let serial = disk.serial_number.as_deref().unwrap_or("NOSN");
        let sz = human_size(disk.size_sectors);
        let key = format!("{}/{}/{}-{}/{}", mobo, run_n, serial, sz, phase);
        let value = disk.concise_json();
        put_kv(&key, &value);
    }

    // Upload the disks index for this run.
    let entries: Vec<String> = rec.disks.iter().map(|d| {
        let s = d.serial_number.as_deref().unwrap_or("NOSN");
        format!("\"{}-{}\"", s, human_size(d.size_sectors))
    }).collect();
    let disks_key = format!("{}/{}/disks", mobo, run_n);
    put_kv(&disks_key, &format!("[{}]", entries.join(",")));
}

/// PUT a key-value pair to the KeyVal store. Best-effort, silent on failure.
fn put_kv(key: &str, value: &str) {
    let headers = format!(
        "X-Lsl-Token: {}\r\nX-Key: {}\r\n",
        crate::telemetry::WORKER_TOKEN, key
    );
    let _ = crate::net::put(
        crate::telemetry::KV_URL,
        crate::net::user_agent(),
        value.as_bytes(),
        &headers,
    );
}

/// GET a value from the KeyVal store. Returns None on any failure.
fn get_kv(key: &str) -> Option<String> {
    let url = format!("{}?key={}", crate::telemetry::KV_URL, key);
    match crate::net::get(&url, crate::net::user_agent()) {
        Ok(res) if res.status == 200 => {
            Some(String::from_utf8_lossy(&res.body).into_owned())
        }
        _ => None,
    }
}

/// Fetch partition layout history from the online KeyVal store for this machine.
///
/// Returns a human-readable multi-line string showing all recorded runs and
/// their disk layouts, or an explanation of why nothing could be fetched.
pub fn fetch_past_layouts() -> String {
    let mobo = motherboard_serial();
    let run_n = crate::telemetry::partition_run_count();

    if run_n == 0 {
        return format!(
            "No partition layouts recorded for this machine ({mobo}) yet.\n\
             Layouts are uploaded when an F2FS persistence install runs."
        );
    }

    let mut out = String::new();
    out.push_str(&format!("Partition layouts for {}:\n\n", mobo));

    // Walk runs from newest to oldest. Stop at the first run where we cannot
    // read the disks index (it may not have been uploaded yet).
    let mut found_any = false;
    for n in (1..=run_n).rev() {
        let disks_key = format!("{}/{}/disks", mobo, n);
        let disks_json = match get_kv(&disks_key) {
            Some(j) => j,
            None => continue,
        };

        // Parse the simple JSON array: ["serial-size","serial-size",...]
        let disk_ids: Vec<String> = disks_json
            .trim_matches(|c| c == '[' || c == ']')
            .split(',')
            .map(|s| s.trim().trim_matches('"').to_string())
            .filter(|s| !s.is_empty())
            .collect();

        found_any = true;
        out.push_str(&format!("Run {}:\n", n));
        for disk_id in &disk_ids {
            out.push_str(&format!("  Disk {}\n", disk_id));
            for stage in &["init", "pre", "post"] {
                let layout_key = format!("{}/{}/{}/{}", mobo, n, disk_id, stage);
                if let Some(val) = get_kv(&layout_key) {
                    out.push_str(&format!("    {}: {}\n", stage, val));
                }
            }
        }
        out.push('\n');
    }

    if !found_any {
        out.push_str("(No layouts could be retrieved from the online store.)\n");
    }
    out
}

/// Keys of runs already recorded on this stick, for the uniqueness enumeration.
/// Best-effort: an unreadable index means "no siblings", which yields a
/// shorter key and a possible overwrite of a same-machine record - recoverable,
/// and never worse than refusing to write a backup at all.
fn local_run_keys(vol_letter: &str) -> Vec<String> {
    let dir = format!("{}\\{LOCAL_INDEX_DIR}", vol_letter.trim_end_matches('\\'));
    let mut out = Vec::new();
    let Ok(rd) = std::fs::read_dir(&dir) else {
        return out;
    };
    for e in rd.flatten() {
        if let Some(n) = e.file_name().to_str() {
            if let Some(run) = n.strip_suffix(".json") {
                out.push(run.to_string());
            }
        }
    }
    out
}

/// Write a record onto the stick as `<machine><date>.json`, keyed by phase.
///
/// The filename IS the run key and the file body is the record, whose own
/// `timestamp` field carries the full date. That is what makes a truncated key
/// recoverable: the key is for humans scanning a directory, the value is for
/// the restore tool.
fn write_local(vol_letter: &str, key: &str, rec: &BackupRecord) -> Result<String, String> {
    let root = vol_letter.trim_end_matches('\\');
    let dir = format!("{}\\{LOCAL_INDEX_DIR}", root);
    sys::create_dir_all(&dir);
    let path = format!("{}\\{}.json", dir, key);
    let json = serde_json::to_string_pretty(rec).map_err(|e| format!("serialize record: {e}"))?;
    // Write-then-rename: a reader (or a crash) must never see a half-written
    // record, because a truncated JSON file parses as corrupt and would be
    // discarded - losing the only restorable copy.
    let tmp = format!("{path}.tmp");
    std::fs::write(&tmp, json.as_bytes()).map_err(|e| format!("write {}: {e}", tmp))?;
    std::fs::rename(&tmp, &path).map_err(|e| format!("rename into {}: {e}", path))?;
    Ok(path)
}

/// Machine identity for the record's `motherboard` field and the key prefix.
///
/// Read from the registry rather than WMI: this project targets Windows 9x
/// upward, where WMI is unavailable or heavy (`boot.rs:9` records the same
/// reason for the motherboard lookup it does).
pub fn motherboard_identity() -> String {
    const PATH: &str = "HARDWARE\\DESCRIPTION\\System\\BIOS";
    let product = sys::RegKey::open(sys::hklm(), PATH)
        .and_then(|k| k.value("BaseBoardProduct"));
    let maker = sys::RegKey::open(sys::hklm(), PATH)
        .and_then(|k| k.value("BaseBoardManufacturer"));
    match (maker, product) {
        (Some(m), Some(p)) => format!("{m} {p}"),
        (None, Some(p)) => p,
        (Some(m), None) => m,
        (None, None) => String::new(),
    }
}

/// The board's own serial number, for KeyVal keys.
///
/// Read from the BIOS registry. Falls back to the FNV hash of the full
/// motherboard identity (manufacturer + product) so the key is still stable
/// and short when no serial is published.
pub fn motherboard_serial() -> String {
    const PATH: &str = "HARDWARE\\DESCRIPTION\\System\\BIOS";
    if let Some(s) = sys::RegKey::open(sys::hklm(), PATH)
        .and_then(|k| k.value("BaseBoardSerialNumber"))
    {
        let s = s.trim().to_string();
        if !s.is_empty() {
            return s;
        }
    }
    // Fallback: hash the identity string the same way machine_id does.
    let ident = motherboard_identity();
    if ident.is_empty() {
        return "UNK".to_string();
    }
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in ident.as_bytes() {
        h ^= *b as u64;
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("S{:08X}", h)
}

/// Everything a record needs from the running system, without touching a disk.
/// Split out so the assembly is testable without one.
pub fn build_record(
    phase: Phase,
    vol_letter: &str,
    disks: Vec<DiskRecord>,
    timestamp_secs: u64,
    motherboard: String,
) -> BackupRecord {
    BackupRecord {
        timestamp: timestamp_key(timestamp_secs),
        phase,
        vol_letter: vol_letter.to_string(),
        lslsetup_version: env!("CARGO_PKG_VERSION").to_string(),
        motherboard,
        windows_version: String::new(),
        disks,
    }
}

/// A record found on the stick, with where it came from.
#[derive(Debug, Clone, PartialEq)]
pub struct FoundRecord {
    /// Filename stem: the run key (machine prefix + shortened date).
    pub key: String,
    pub path: String,
    pub record: BackupRecord,
    /// Set when the file could not be parsed. The record is None then, and the
    /// reason is shown instead - a corrupt file must be visible, not skipped.
    pub error: Option<String>,
}

/// Read every record in a stick's local index.
///
/// Never fails: an absent index yields an empty list (nothing recorded yet),
/// and an unreadable or corrupt file yields an entry carrying the reason. Both
/// are states the operator needs to SEE - silently returning fewer records than
/// exist is how a restore tool talks someone into restoring the wrong thing.
pub fn find_records(vol_letter: &str) -> Vec<FoundRecord> {
    let root = vol_letter.trim_end_matches('\\');
    find_records_from(std::path::Path::new(&format!("{}\\{LOCAL_INDEX_DIR}", root)))
}

/// [`find_records`] against an explicit directory.
///
/// Split out so the retrieval rules can be tested without a mounted volume:
/// corrupt-file visibility, `.tmp` exclusion and ordering are all properties of
/// the directory walk, not of the drive it sits on.
pub fn find_records_from(dir: &std::path::Path) -> Vec<FoundRecord> {
    let mut out = Vec::new();
    let Ok(rd) = std::fs::read_dir(dir) else {
        return out;
    };
    let mut names: Vec<String> = rd
        .flatten()
        .filter_map(|e| e.file_name().to_str().map(|s| s.to_string()))
        // A `.tmp` left by an interrupted write is not a record: showing it
        // would offer geometry that was never committed.
        .filter(|n| n.ends_with(".json") && !n.ends_with(".json.tmp"))
        .collect();
    names.sort();
    for n in names {
        let key = n.trim_end_matches(".json").to_string();
        let path = format!("{}\\{}", dir.display(), n);
        match std::fs::read_to_string(&path) {
            Ok(text) => match serde_json::from_str::<BackupRecord>(&text) {
                Ok(record) => out.push(FoundRecord {
                    key,
                    path,
                    record,
                    error: None,
                }),
                Err(e) => out.push(FoundRecord {
                    key,
                    path,
                    record: empty_record(),
                    error: Some(format!("could not parse: {e}")),
                }),
            },
            Err(e) => out.push(FoundRecord {
                key,
                path,
                record: empty_record(),
                error: Some(format!("could not read: {e}")),
            }),
        }
    }
    // Order by the timestamp INSIDE the record, not the filename: the key leads
    // with the machine prefix, so filename order says nothing about time. An
    // unreadable record has an empty timestamp and therefore sorts first, where
    // it is visible rather than buried.
    out.sort_by(|a, b| a.record.timestamp.cmp(&b.record.timestamp));
    out
}

/// A placeholder for a record we could not read, so the caller can carry a
/// uniform `Vec<FoundRecord>` and show the reason in place of the data.
fn empty_record() -> BackupRecord {
    BackupRecord {
        timestamp: String::new(),
        phase: Phase::Pre,
        vol_letter: String::new(),
        lslsetup_version: String::new(),
        motherboard: String::new(),
        windows_version: String::new(),
        disks: Vec::new(),
    }
}

/// Human-readable render of one record: the geometry a manual recovery needs.
///
/// Readable sizes are shown ALONGSIDE the sectors, never instead of them: the
/// sectors are what must be typed into `sfdisk`, and a rounded "10.0 GiB" cannot
/// be written to a partition table.
pub fn render_record(f: &FoundRecord) -> String {
    let mut s = String::new();
    if let Some(e) = &f.error {
        s.push_str(&format!("{}  [UNREADABLE: {}]\n", f.key, e));
        s.push_str(&format!("    {}\n", f.path));
        return s;
    }
    let r = &f.record;
    s.push_str(&format!("{}  ({})\n", f.key, r.timestamp));
    s.push_str(&format!(
        "  phase={}  stick={}  lslsetup={}\n",
        r.phase, r.vol_letter, r.lslsetup_version
    ));
    if !r.motherboard.is_empty() {
        s.push_str(&format!("  machine: {}\n", r.motherboard));
    }
    for (i, d) in r.disks.iter().enumerate() {
        s.push_str(&format!(
            "  disk {}: {} sectors ({:.1} GiB), {}\n",
            i + 1,
            d.size_sectors,
            d.size_sectors as f64 * 512.0 / (1u64 << 30) as f64,
            d.scheme.to_uppercase()
        ));
        for e in &d.entries {
            s.push_str(&format!(
                "    {}: start={} size={} ({} MiB) type={}{}{}\n",
                e.index,
                e.start_sectors,
                e.size_sectors,
                e.size_sectors / 2048,
                e.type_id,
                if e.bootable { " bootable" } else { "" },
                if e.label.is_empty() {
                    String::new()
                } else {
                    format!(" label='{}'", e.label)
                }
            ));
        }
        match d.fs_size_sectors {
            Some(fs) => s.push_str(&format!(
                "    FAT filesystem: {} sectors ({} MiB)\n",
                fs,
                fs / 2048
            )),
            None => s.push_str(&format!(
                "    FAT filesystem: not recorded - the partition can be restored, the filesystem cannot be grown back\n"
            )),
        }
        s.push_str(&format!(
            "    boot area (sectors 0-15): {} bytes recorded\n",
            d.head_sectors_hex.len() / 2
        ));
    }
    s
}

/// The record to restore from: the newest readable `pre` with no `post`
/// sibling for the same run key.
///
/// The "no post" condition is the whole point - a run that completed
/// repartitioning successfully does NOT need restoring, and offering it would
/// invite someone to undo a working install.
pub fn restorable(found: &[FoundRecord]) -> Option<&FoundRecord> {
    found
        .iter()
        .filter(|f| f.error.is_none() && f.record.phase == Phase::Pre)
        .filter(|f| {
            !found
                .iter()
                .any(|o| o.error.is_none() && o.record.phase == Phase::Post && o.key == f.key)
        })
        .next_back()
}

/// Render every record on a stick, for a human to read.
pub fn render_all(vol_letter: &str) -> String {
    let found = find_records(vol_letter);
    if found.is_empty() {
        return format!(
            "No partition-layout records in {vol_letter}:\\{LOCAL_INDEX_DIR}.\n\
             A record is written when a stick is installed with F2FS persistence.\n"
        );
    }
    let mut s = String::new();
    s.push_str(&format!(
        "Partition-layout records on {vol_letter} ({}):\n\n",
        found.len()
    ));
    for f in &found {
        s.push_str(&render_record(f));
        s.push('\n');
    }
    match restorable(&found) {
        Some(r) => {
            s.push_str(&format!(
                "Restorable geometry is in '{}'. Restoring it deletes partition 2 (the\n\
                 lsl-persist area) - restoring the stick and keeping the persisted /home\n\
                 are mutually exclusive. See the record above for the exact sectors.\n",
                r.key
            ));
        }
        None => s.push_str(
            "No unrestored run found: every `pre` record here has a matching `post` receipt,\n\
             so no repartition is outstanding.\n",
        ),
    }
    s
}

/// Build a synthetic GPT header + entry array in the shape `parse_gpt` reads.
#[cfg(test)]
fn synth_gpt(entries: &[(u64, u64, &str)], entry_count: u32) -> Vec<u8> {
    let mut buf = vec![0u8; GPT_SECTORS * SECTOR as usize];
    // Header at LBA 1.
    let h = SECTOR as usize;
    buf[h..h + 8].copy_from_slice(b"EFI PART");
    buf[h + 72..h + 80].copy_from_slice(&2u64.to_le_bytes()); // entries LBA
    buf[h + 80..h + 84].copy_from_slice(&entry_count.to_le_bytes());
    buf[h + 84..h + 88].copy_from_slice(&128u32.to_le_bytes()); // entry size
    // Entries at LBA 2.
    for (i, (first, last, label)) in entries.iter().enumerate() {
        let off = 2 * SECTOR as usize + i * 128;
        // Non-zero type GUID at byte 0..16 (all-zero means "unused").
        buf[off..off + 16].iter_mut().for_each(|b| *b = 0xAB);
        buf[off + 32..off + 40].copy_from_slice(&first.to_le_bytes());
        buf[off + 40..off + 48].copy_from_slice(&last.to_le_bytes());
        // UTF-16LE label at byte 56.
        for (j, u) in label.encode_utf16().take(36).enumerate() {
            let p = off + 56 + j * 2;
            buf[p..p + 2].copy_from_slice(&u.to_le_bytes());
        }
    }
    buf
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timestamp_is_year_month_day_hour_minute_second() {
        // 2026-10-05T22:23:01+08:00 == 2026-10-05T14:23:01Z == 1791210181.
        // UTC: the record's timestamp is not a local wall-clock reading, so a
        // DST shift must not be able to produce a colliding key.
        assert_eq!(timestamp_key(1_791_210_181), "261005:142301");
    }

    #[test]
    fn a_unique_timestamp_keeps_only_the_digits_needed_to_disambiguate() {
        // A lone key needs no date at all: one character already separates it
        // from every other key sharing the prefix (there are none).
        assert_eq!(shortest_unique_prefix("261005:142301", &[]), "2");
        // Two runs in the same minute but different seconds diverge at the
        // FIRST second digit, not at the minute: the minutes are identical, so
        // "261005:1423" is a prefix of BOTH and cannot separate them. The
        // shortest prefix that actually distinguishes 01 from 59 is one
        // character longer.
        let sibs = vec!["261005:142301".to_string(), "261005:142359".to_string()];
        assert_eq!(shortest_unique_prefix("261005:142301", &sibs), "261005:14230");
        // Two runs an hour apart diverge at the hour field.
        let sibs = vec!["261005:142301".to_string(), "261005:152301".to_string()];
        assert_eq!(shortest_unique_prefix("261005:142301", &sibs), "261005:14");
        // Runs in different months diverge at the month field.
        let sibs = vec!["261005:142301".to_string(), "261105:142301".to_string()];
        assert_eq!(shortest_unique_prefix("261005:142301", &sibs), "2610");
    }

    #[test]
    fn the_prefix_never_collides_with_a_sibling() {
        // The property that matters, over a set that is adversarially prefix-
        // related rather than neatly separated.
        let sibs = vec![
            "261005:1423".to_string(),
            "261005:14230".to_string(),
            "261005:142300".to_string(),
        ];
        let sup = shortest_unique_prefix("261005:142301", &sibs);
        for s in &sibs {
            assert!(
                !s.starts_with(&sup),
                "{sup} is not unique: sibling {s} shares it"
            );
        }
    }

    #[test]
    fn truncating_does_not_lose_the_full_date() {
        // The reason the record carries `timestamp` and the key does not: a
        // one-character key must still be resolvable back to a real date.
        let full = timestamp_key(1_791_210_181);
        let sup = shortest_unique_prefix(&full, &[]);
        assert!(full.starts_with(&sup));
        // YYMMDD:HHMMSS is 13 characters, not 15 - and the record carries the
        // full string, so the truncated key can always be resolved back.
        assert_eq!(full.len(), 13);
    }

    #[test]
    fn the_machine_prefix_leads_so_keys_group_by_machine() {
        let k = run_key("A1B2C3", "261005:1423", &[]);
        assert!(k.starts_with("A1B2C3"));
        // With no siblings the date needs a single character, so the key is
        // the machine prefix plus that one character.
        assert_eq!(k, "A1B2C32");
    }

    #[test]
    fn phases_are_separate_keys() {
        let pre = record_key("A1B2C3", "261005:1423", &[], Phase::Pre);
        let post = record_key("A1B2C3", "261005:1423", &[], Phase::Post);
        assert_ne!(pre, post, "a same-second re-run must not overwrite `pre`");
        assert!(pre.ends_with("/pre"));
        assert!(post.ends_with("/post"));
    }

    #[test]
    fn head_sectors_round_trip_exactly() {
        // Bytes 0..15 are the only thing restore has for the boot area, so the
        // encode/decode pair must be lossless for every byte value.
        let mut head = Vec::with_capacity(16);
        for i in 0..16u8 {
            head.push(i.wrapping_mul(17));
        }
        assert_eq!(hex_decode(&hex_encode(&head)), Some(head));
    }

    #[test]
    fn a_corrupted_record_is_refused_rather_than_restored() {
        // Silent garbage in a partition table is worse than no record.
        assert_eq!(hex_decode("ABC"), None, "odd length");
        assert_eq!(hex_decode("ZZ"), None, "non-hex digit");
        assert_eq!(hex_decode("00 11"), None, "embedded space");
        assert_eq!(hex_decode("0011"), Some(vec![0x00, 0x11]));
    }

    #[test]
    fn a_record_round_trips_through_json_with_its_numbers_intact() {
        // Sectors must survive as JSON numbers. A float round trip here would
        // silently corrupt the geometry restore depends on.
        let rec = BackupRecord {
            timestamp: timestamp_key(1_772_934_181),
            phase: Phase::Pre,
            vol_letter: "D:".into(),
            lslsetup_version: "0.1.1".into(),
            motherboard: "ASUS X".into(),
            windows_version: "Windows 11".into(),
            disks: vec![DiskRecord {
                size_sectors: 62_914_560,
                scheme: "mbr".into(),
                entries: vec![PartitionEntry {
                    index: 1,
                    start_sectors: 2048,
                    size_sectors: 24_576_000,
                    type_id: "0c".into(),
                    bootable: true,
                    label: "LSLUSB".into(),
                }],
                fs_size_sectors: Some(24_575_999),
                head_sectors_hex: hex_encode(&[0xEB, 0x3C, 0x90]),
                serial_number: None,
            }],
        };
        let json = serde_json::to_string(&rec).expect("serialize");
        let back: BackupRecord = serde_json::from_str(&json).expect("round trip");
        assert_eq!(rec, back);
        assert_eq!(back.disks[0].entries[0].size_sectors, 24_576_000);
        assert_eq!(back.disks[0].fs_size_sectors, Some(24_575_999));
    }

    #[test]
    fn a_record_with_no_readable_filesystem_size_still_parses() {
        // fs_size_sectors is Option: a disk whose BPB could not be read must
        // still produce a record - a partial geometry is better than none, and
        // restore must be able to say "growth unavailable" rather than refuse
        // to restore the table at all.
        let json = r#"{"timestamp":"261005:1423","phase":"pre","disks":[
            {"size_sectors":100,"scheme":"mbr","entries":[]}]}"#;
        let rec: BackupRecord = serde_json::from_str(json).expect("parse");
        assert_eq!(rec.disks[0].fs_size_sectors, None);
        assert_eq!(rec.phase, Phase::Pre);
    }

    #[test]
    fn a_machine_with_no_identifiers_says_so_instead_of_colliding_silently() {
        // An empty prefix would put every unidentified machine's runs in one
        // namespace; "UNK" is honest and the date enumeration still separates
        // them.
        assert_eq!(machine_id("", ""), "UNK");
        // A board that identifies gets a stable key.
        let a = machine_id("ASUS X570", "");
        assert_eq!(a.len(), 6);
        assert_eq!(a, machine_id("ASUS X570", "ignored-when-board-present"));
        // Different boards differ.
        assert_ne!(a, machine_id("MSI B450", ""));
        // With no board, the MachineGuid stands in.
        assert_eq!(machine_id("", "abc-123"), machine_id("", "abc-123"));
        assert_ne!(machine_id("", "abc-123"), machine_id("", "def-456"));
    }

    #[test]
    fn the_sup_never_returns_an_empty_key() {
        // A zero-length key would match every sibling - the one result that
        // must never come out of this function.
        for n in 1..8 {
            let sibs: Vec<String> = (0..n).map(|i| format!("{i:02}")).collect();
            let sup = shortest_unique_prefix("251005:142301", &sibs);
            assert!(!sup.is_empty());
        }
    }

    #[test]
    fn gpt_entries_are_read_with_inclusive_last_lba() {
        // last_lba is INCLUSIVE in GPT, so size = last - first + 1. Getting
        // this off by one silently shrinks every restored partition by a sector.
        let buf = synth_gpt(&[(2048, 24_575_999, "LSLUSB")], 128);
        let parts = parse_gpt(&buf).expect("valid GPT");
        assert_eq!(parts.len(), 1);
        assert_eq!(parts[0].start_sectors, 2048);
        assert_eq!(parts[0].size_sectors, 24_575_999 - 2048 + 1);
        assert_eq!(parts[0].label, "LSLUSB");
    }

    #[test]
    fn gpt_past_two_terabytes_is_read_correctly() {
        // An MBR's u32 start_lba cannot express a disk over 2 TiB; GPT's u64
        // can. A restore that round-tripped through u32 here would place a
        // partition at entirely the wrong offset. u32::MAX is 4294967295
        // sectors (~2 TiB at 512 B), so go past it.
        let huge = 5_000_000_000u64;
        let buf = synth_gpt(&[(huge, huge + 9999, "BIG")], 128);
        let parts = parse_gpt(&buf).expect("valid GPT");
        assert_eq!(parts[0].start_sectors, huge);
        assert!(parts[0].start_sectors > u32::MAX as u64);
    }

    #[test]
    fn an_unused_gpt_slot_terminates_the_list() {
        // Entries past the first all-zero GUID are undefined in practice; a
        // parser that kept going would record garbage partitions.
        let mut buf = synth_gpt(&[(2048, 4095, "ONE")], 128);
        // Zero the SECOND entry's type GUID to mark it unused.
        let off = 2 * SECTOR as usize + 128;
        buf[off..off + 16].iter_mut().for_each(|b| *b = 0);
        let parts = parse_gpt(&buf).expect("valid GPT");
        assert_eq!(parts.len(), 1, "must stop at the unused slot");
    }

    #[test]
    fn a_header_without_the_gpt_magic_is_not_a_gpt_disk() {
        // The magic check is the only thing separating a GPT disk from an MBR
        // one; without it every MBR stick would be recorded as GPT with no
        // entries, and restore would write an empty GPT table over a real one.
        let mut buf = synth_gpt(&[(2048, 4095, "X")], 128);
        let h = SECTOR as usize;
        buf[h..h + 8].copy_from_slice(b"NOTGPT!!");
        assert_eq!(parse_gpt(&buf), None);
    }

    #[test]
    fn a_corrupt_gpt_header_cannot_walk_off_the_buffer() {
        // A header claiming an absurd entry count/size must be refused, not
        // allowed to allocate or index past the 34 sectors we read.
        let mut buf = synth_gpt(&[(2048, 4095, "X")], 128);
        let h = SECTOR as usize;
        buf[h + 80..h + 84].copy_from_slice(&u32::MAX.to_le_bytes()); // count
        buf[h + 84..h + 88].copy_from_slice(&u32::MAX.to_le_bytes()); // size
        assert_eq!(parse_gpt(&buf), None);
        // An entry size below the 128-byte minimum is equally impossible.
        let mut buf = synth_gpt(&[(2048, 4095, "X")], 128);
        buf[h + 84..h + 88].copy_from_slice(&64u32.to_le_bytes());
        assert_eq!(parse_gpt(&buf), None);
    }

    #[test]
    fn a_short_read_is_refused_rather_than_parsed_as_empty() {
        // 16 sectors is enough for the boot area but NOT for a GPT table.
        // Truncating here would record a GPT disk as having no partitions -
        // the silent-wrong direction that matters.
        let short = vec![0u8; HEAD_SECTORS * SECTOR as usize];
        assert_eq!(parse_gpt(&short), None);
    }

    #[test]
    fn build_record_carries_the_phase_and_the_full_timestamp() {
        // The two fields the restore path cannot reconstruct for itself: which
        // side of the repartition this is, and the untruncated date the key may
        // have shortened.
        let rec = build_record(
            Phase::Pre,
            "D:",
            vec![DiskRecord {
                size_sectors: 62_914_560,
                scheme: "mbr".into(),
                entries: vec![],
                fs_size_sectors: Some(100),
                head_sectors_hex: hex_encode(&[0u8; 16]),
                serial_number: None,
            }],
            1_791_210_181,
            "ASUS X570".into(),
        );
        assert_eq!(rec.phase, Phase::Pre);
        assert_eq!(rec.timestamp, "261005:142301");
        assert_eq!(rec.vol_letter, "D:");
        assert_eq!(rec.disks.len(), 1);
        assert_eq!(rec.disks[0].fs_size_sectors, Some(100));
    }

    #[test]
    fn the_record_is_only_requested_when_f2fs_was_chosen() {
        // A run that writes no record must be a run where none was NEEDED.
        // F2FS is the only backend where the hook repartitions, so the flag is
        // exactly `f2fs_gib > 0` - never "always", which would write a record on
        // every install and quietly teach people to ignore it.
        for (gib, expect_record) in [(0u32, false), (1, true), (64, true)] {
            assert_eq!(
                gib > 0, expect_record,
                "f2fs_gib={gib} should record={expect_record}"
            );
        }
    }

    // ---- retrieval + rendering -----------------------------------------
    //
    // The point of this half is MANUAL recovery: a human reads the record and
    // retypes the geometry. So the tests care about (a) never hiding a record,
    // (b) never offering a completed run as restorable, and (c) printing the
    // sectors, which are the only numbers sfdisk can accept.

    /// A record on disk with the given phase, as find_records would see it.
    fn put_record(dir: &std::path::Path, key: &str, phase: Phase, ts: &str) {
        let rec = build_record(
            phase,
            "D:",
            vec![DiskRecord {
                size_sectors: 24_576_000,
                scheme: "mbr".into(),
                entries: vec![PartitionEntry {
                    index: 1,
                    start_sectors: 2048,
                    size_sectors: 24_575_999,
                    type_id: "0c".into(),
                    bootable: true,
                    label: String::new(),
                }],
                fs_size_sectors: Some(24_575_999),
                head_sectors_hex: hex_encode(&[0xABu8; 16]),
                serial_number: None,
            }],
            1_791_210_181,
            "ASUS X570".into(),
        );
        let mut rec = rec;
        rec.timestamp = ts.to_string();
        std::fs::write(
            dir.join(format!("{key}.json")),
            serde_json::to_string_pretty(&rec).unwrap(),
        )
        .unwrap();
    }

    /// A private scratch directory for one test.
///
/// NAMED per test, not just per process: the tests run in parallel in one
/// process, so a single shared directory would have them deleting and writing
/// each other's files - which is exactly the class of bug these tests exist to
/// catch, so it must not be present in the harness.
fn tmpdir(name: &str) -> std::path::PathBuf {
    let d = std::env::temp_dir().join(format!("lslpb-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

    #[test]
    fn an_absent_index_yields_no_records_rather_than_an_error() {
        // "Nothing recorded yet" is the normal state on a non-F2FS install and
        // must not look like a failure.
        let d = tmpdir("absent");
        let _ = std::fs::create_dir_all(&d);
        // find_records takes a volume letter; drive the directory form it builds.
        let found = find_records_from(&d);
        assert!(found.is_empty());
    }

    #[test]
    fn a_corrupt_record_is_shown_not_hidden() {
        // Silently dropping an unreadable file would show "1 of 2 records" and
        // leave the operator believing nothing else exists.
        let d = tmpdir("corrupt");
        std::fs::write(d.join("AABBCC2.json"), "{ this is not json").unwrap();
        let found = find_records_from(&d);
        assert_eq!(found.len(), 1);
        assert!(found[0].error.is_some(), "a corrupt file must be visible");
        let text = render_record(&found[0]);
        assert!(text.contains("UNREADABLE"), "got: {text}");
    }

    #[test]
    fn an_interrupted_tmp_file_is_not_offered_as_a_record() {
        // The write is tmp-then-rename precisely so a torn file cannot be read;
        // a `.tmp` must therefore be invisible, not treated as corrupt data.
        let d = tmpdir("tmpfile");
        put_record(&d, "AABBCC2", Phase::Pre, "261005:142301");
        std::fs::write(d.join("AABBCC3.json.tmp"), "{ partial").unwrap();
        let found = find_records_from(&d);
        assert_eq!(found.len(), 1, "the .tmp must not appear at all");
        assert_eq!(found[0].key, "AABBCC2");
    }

    #[test]
    fn a_completed_run_is_not_offered_as_restorable() {
        // The `post` receipt means the repartition succeeded. Offering that run
        // for restore would invite someone to undo a working install.
        let d = tmpdir("completed");
        put_record(&d, "AABBCC2", Phase::Pre, "261005:142301");
        put_record(&d, "AABBCC2p", Phase::Post, "261005:142301");
        let mut found = find_records_from(&d);
        assert_eq!(found.len(), 2);
        // Same run key on both -> nothing outstanding.
        found[0].key = "SAME".into();
        found[1].key = "SAME".into();
        assert!(restorable(&found).is_none());
    }

    #[test]
    fn an_uncompleted_run_is_offered_and_the_newest_wins() {
        let d = tmpdir("newest");
        put_record(&d, "AABBCC2", Phase::Pre, "261005:142301");
        put_record(&d, "DDEEFF2", Phase::Pre, "261006:093000");
        let found = find_records_from(&d);
        assert_eq!(found.len(), 2);
        let r = restorable(&found).expect("two outstanding runs");
        // Newest by the timestamp INSIDE the record, not by filename order.
        assert_eq!(r.record.timestamp, "261006:093000");
    }

    #[test]
    fn the_rendered_record_prints_the_sectors_a_manual_restore_needs() {
        // Readable sizes are shown ALONGSIDE the sectors, never instead: only
        // the integers can be typed into sfdisk, and a rounded "11.7 GiB" cannot
        // be written to a partition table.
        let d = tmpdir("render");
        put_record(&d, "AABBCC2", Phase::Pre, "261005:142301");
        let found = find_records_from(&d);
        let text = render_record(&found[0]);
        assert!(text.contains("start=2048"), "got:\n{text}");
        assert!(text.contains("size=24575999"), "got:\n{text}");
        assert!(text.contains("24575999 sectors"), "the fs size must appear:\n{text}");
        assert!(text.contains("MBR"));
        // And it must be readable enough to act on.
        assert!(text.contains("261005:142301"));
    }

    #[test]
    fn concise_json_fits_in_300_chars_for_a_typical_record() {
        // A realistic MBR disk with one FAT partition. The KeyVal value limit
        // is 300 chars; head_sectors_hex (8192 chars) and bootable/label/index
        // are omitted to stay within it.
        let rec = DiskRecord {
            size_sectors: 62_914_560,
            scheme: "mbr".into(),
            entries: vec![PartitionEntry {
                index: 1,
                start_sectors: 2048,
                size_sectors: 24_576_000,
                type_id: "0c".into(),
                bootable: true,
                label: "LSLUSB".into(),
            }],
            fs_size_sectors: Some(24_575_999),
            head_sectors_hex: hex_encode(&[0xEB, 0x3C, 0x90]),
            serial_number: Some("WD123456".into()),
        };
        let j = rec.concise_json();
        assert!(
            j.len() <= 300,
            "concise_json too long ({} chars): {}",
            j.len(),
            j
        );
        // Must contain the essential geometry.
        assert!(j.contains("\"sz\":62914560"));
        assert!(j.contains("\"sc\":\"mbr\""));
        assert!(j.contains("\"s\":2048"));
        assert!(j.contains("\"n\":24576000"));
        assert!(j.contains("\"t\":\"0c\""));
        assert!(j.contains("\"fs\":24575999"));
        // Must NOT contain the bootable/label/index fields.
        assert!(!j.contains("bootable"));
        assert!(!j.contains("LSLUSB"));
    }
}