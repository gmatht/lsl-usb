//! Non-destructive "no-reformat" live-USB install (YUMI/Easy2Boot-style).
//!
//! Instead of DD-ing the ISO over the stick (Rufus), this mode:
//!   1. copies `grldr` (grub4dos loader, must be in the volume root) plus
//!      the ISO *as a regular file* onto the stick (SHA-256-verified);
//!   2. generates/appends a `menu.lst` that loopback-maps the ISO and
//!      chainloads the ISO's own bootloader (plus BOOTX64.EFI/grub.cfg
//!      for UEFI);
//!   3. LAST, writes grub4dos boot code into the MBR *boot-code area only*
//!      (bytes 0..440) - disk signature (440..446), partition table
//!      (446..510) and 0x55AA signature (510..512) are preserved - plus
//!      the stage1 *continuation* into sectors 1..15. The stage1
//!      (assets/grldr.mbr) is 8192 bytes = 16 sectors; the BIOS loads
//!      only sector 0, and the stage1 then reads sectors 1..15 to load the
//!      rest of itself (its FAT/NTFS/ISO reading code). Without them it dies
//!      with "Missing helper" and the stick is NOT bootable (verified by
//!      tests/qemu-boot-test.sh).
//!
//! The MBR write goes last deliberately: raw-sector writes can knock the
//! volume offline, and nothing after them needs the volume - while a
//! failure anywhere in the file phase leaves the boot sectors untouched.
//!
//! Nothing is formatted and no existing file is deleted; existing files
//! are untouched (menu.lst is only appended to, `grldr` only overwritten
//! after an explicit warning prompt when it exists and differs).
//!
//! Safety gates (this writes raw sectors, so be paranoid):
//!   - the target MUST be a removable drive AND on the USB bus
//!     (GetDriveTypeW == DRIVE_REMOVABLE + IOCTL_STORAGE_QUERY_PROPERTY
//!     BusType == BusTypeUsb), unless --allow-fixed is passed explicitly;
//!   - PhysicalDrive0 is refused unconditionally (system disk tripwire);
//!   - MBR must have a valid 0x55AA signature, a non-empty partition
//!     table, and must not be GPT (GPT = "EFI PART" magic at LBA1 plus a
//!     0xEE protective-MBR entry; a stale "EFI PART" header alone does not
//!     count). True GPT sticks are refused because sectors 1..15, which the
//!     grub4dos stage1 continuation needs, hold the GPT header/table there -
//!     use the Rufus (reformat) flow or convert the stick to MBR instead;
//!   - the first 64 sectors are backed up before the write and verified
//!     by read-back afterwards;
//!   - Win9x is refused (needs the \\.\PhysicalDriveN NT device namespace).
//!
//! UEFI (incl. grub4dos-for-UEFI, which reads the same menu.lst/ISO
//! mapping) is supported side-by-side via --uefi-bootx64 <BOOTX64.EFI>:
//! whenever possible BOTH loaders are installed and a boot-capability
//! summary says which firmware modes will boot (warning when only one
//! will). GPT sticks get a files-only UEFI install (no raw sectors
//! touched; FAT32 required, Secure Boot off for unsigned loaders) while
//! MBR sticks get the grub4dos BIOS path plus the optional UEFI files.
//!
//! The grub4dos 0.4.6a binaries are embedded (assets/, GPL-2, see
//! assets/COPYING) and verified against pinned SHA-256 hashes at startup.

use crate::sys::{self, out};
use sha2::{Digest, Sha256};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::windows::io::AsRawHandle;

/// Callback trait for live GUI progress during USB write / verify.
pub trait WriteUi {
    fn set_status(&self, msg: &str);
    fn set_progress(&self, done: u64, total: u64);
    fn show_progress(&self, visible: bool);
    fn pump(&self);
}

/// Timing + throughput metrics for the USB write + verify phases.
#[derive(Clone, Debug, Default)]
pub struct WriteMetrics {
    pub bytes_copied: u64,
    pub write_seconds: f64,
    pub write_mbps: f64,
    pub bytes_verified: u64,
    pub verify_seconds: f64,
    pub verify_mbps: f64,
    /// Estimated true USB read speed, decomposed from the serial
    /// read-then-hash pass (0.0 = inseparable, report measured as bound).
    pub verify_disk_est_mbps: f64,
}

/// Hash-only throughput (MB/s) of our exact verify shape: 4 MB updates +
/// finalize, hot buffer. ~0.5 s. Calibrates the CPU share so a serial
/// read-then-hash pass can be decomposed into disk vs CPU (see
/// estimate_disk_mbps). The copy phase is read+hash+write (three stages, no
/// clean split), so the estimate applies to verification reads only.
fn calibrate_hash_mbps() -> f64 {
    let buf = vec![0u8; 4 << 20];
    let t0 = std::time::Instant::now();
    let mut h = Sha256::new();
    for _ in 0..16 {
        h.update(&buf);
    }
    std::hint::black_box(h.finalize());
    64.0 / t0.elapsed().as_secs_f64().max(0.001)
}

/// Estimate true disk read speed from a serial read-then-hash pipeline:
/// 1/combined = 1/disk + 1/hash, so disk = combined*hash/(hash-combined).
/// Returns None when the stages don't separate (fully hash-bound, noise, or
/// bad inputs) - callers then report the measured rate as a lower bound.
/// Pure so the math is unit-testable.
fn estimate_disk_mbps(combined_mbps: f64, hash_mbps: f64) -> Option<f64> {
    if !(combined_mbps > 0.0) || !(hash_mbps > 0.0) {
        return None;
    }
    if hash_mbps <= combined_mbps * 1.1 {
        // Hashing explains ~all of the time-per-byte: the disk could be
        // arbitrarily faster, so any number would be fiction.
        return None;
    }
    Some(combined_mbps * hash_mbps / (hash_mbps - combined_mbps))
}

/// Compressed grub4dos loader (`assets/grldr.gz`: raw `grldr` through
/// `gzip -9` + `advdef -z -4`; build.rs verifies it inflates to the pinned
/// GRLDR_SHA256). Inflated once at startup via the already-linked flate2.
const GRLDR_GZ: &[u8] = include_bytes!("../assets/grldr.gz");
const GRLDR_MBR: &[u8] = include_bytes!("../assets/grldr.mbr");

/// The raw `grldr` bytes, inflated once and shared. Panics only if the
/// embedded blob is corrupt - build.rs already verified it, and
/// verify_assets() re-checks the hash before any install.
fn grldr() -> &'static [u8] {
    static INFLATED: std::sync::OnceLock<Vec<u8>> = std::sync::OnceLock::new();
    INFLATED
        .get_or_init(|| {
            let mut dec = flate2::read::GzDecoder::new(&GRLDR_GZ[..]);
            let mut raw = Vec::new();
            use std::io::Read;
            dec.read_to_end(&mut raw).expect("embedded grldr.gz is corrupt");
            raw
        })
        .as_slice()
}
const GRLDR_SHA256: &str = "dece3f8d20f84ae0d0fb892b5c3a2d19e7233d0d8885b0027a6f43d77239128d";
const GRLDR_MBR_SHA256: &str = "f5c6e8e2c1eb7380285fa9cb1c9168e92d5b3b55cde052c043ba81ed17b9acef";

// Optional vendored UEFI loader (see build.rs: assets/BOOTX64.EFI).
include!(concat!(env!("OUT_DIR"), "/uefi_embedded.rs"));

/// The vendored UEFI loader, if one was present at build time. Verified
/// against the pinned hash (assets/BOOTX64.EFI.sha256) when pinned.
pub fn bundled_uefi() -> Option<&'static [u8]> {
    if let (Some(data), Some(pin)) = (BUNDLED_BOOTX64_EFI, BUNDLED_BOOTX64_SHA256) {
        if sha256_hex(data) != pin {
            return None; // pinned hash mismatch: never install a wrong binary
        }
    }
    BUNDLED_BOOTX64_EFI
}

/// Where the UEFI loader would come from, in priority order.
pub fn uefi_source_name(uefi_bootx64: &str) -> Option<&'static str> {
    if !uefi_bootx64.is_empty() && sys::path_exists(uefi_bootx64) {
        Some("--uefi-bootx64 file")
    } else if bundled_uefi().is_some() {
        Some("vendored BOOTX64.EFI")
    } else {
        None
    }
}

/// Per-target boot capability: which firmware modes can boot this stick and
/// why. Used by the GUI checkboxes (auto-check + grey-out + tooltip) and
/// the console capability summary.
pub struct BootCaps {
    pub bios_ok: bool,
    pub bios_why: String,
    pub uefi_ok: bool,
    pub uefi_why: String,
}

/// Probe boot capability for a mounted drive letter without writing
/// anything. Partition-style reads need Administrator; without it the GPT
/// verdict is `None` (unknown) and both paths stay offered with a note.
pub fn probe_boot_caps(letter: &str, uefi_bootx64: &str) -> BootCaps {
    let vols = sys::list_volumes();
    let fs = vols
        .iter()
        .find(|v| v.letter.eq_ignore_ascii_case(letter))
        .map(|v| v.fs.clone())
        .unwrap_or_default();
    let fs_uc = fs.to_ascii_uppercase();
    let gpt: Option<bool> = read_head(letter).map(|h| is_gpt(&h));
    let uefi_src = uefi_source_name(uefi_bootx64);
    // BIOS (grub4dos): FAT/NTFS only, MBR only.
    let (bios_ok, bios_why) = if !(fs_uc.starts_with("FAT") || fs_uc == "NTFS") {
        (false, format!("{} is not readable by grub4dos (needs FAT/NTFS)", if fs.is_empty() { "this filesystem".into() } else { fs.clone() }))
    } else {
        match gpt {
            Some(true) => (false, "GPT stick - the grub4dos stage1 needs sectors 1-15 (the GPT header/table)".into()),
            Some(false) => (true, "grub4dos MBR stage1 + menu.lst loopback".into()),
            None => (true, "grub4dos MBR stage1 (partition style unprobed - needs Administrator to confirm GPT/MBR)".into()),
        }
    };
    // UEFI: firmware reads FAT only (this is also how Windows does GPT+NTFS:
    // a small FAT32 EFI System Partition holds the loader, which then reads
    // the NTFS data partition - single-partition non-destructive sticks
    // cannot grow an ESP, so UEFI needs FAT32 here), plus a loader binary.
    let (uefi_ok, uefi_why) = if !fs_uc.starts_with("FAT") {
        (false, format!("UEFI firmware reads FAT only ({} here); Windows solves this with a separate FAT32 ESP", if fs.is_empty() { "unknown fs".into() } else { fs.clone() }))
    } else {
        match uefi_src {
            Some(s) => (true, format!("BOOTX64.EFI + grub.cfg ({})", s)),
            None => (false, "no UEFI loader (vendor assets/BOOTX64.EFI or pass --uefi-bootx64)".into()),
        }
    };
    BootCaps { bios_ok, bios_why, uefi_ok, uefi_why }
}

/// Read the first two sectors of the physical disk behind `letter`.
fn read_head(letter: &str) -> Option<Vec<u8>> {
    let phys = device_number(letter).ok()?;
    let mut disk = std::fs::OpenOptions::new()
        .read(true)
        .open(format!(r"\\.\PhysicalDrive{}", phys))
        .ok()?;
    let mut head = vec![0u8; 1024];
    use std::io::{Read, Seek, SeekFrom};
    disk.seek(SeekFrom::Start(0)).ok()?;
    disk.read_exact(&mut head).ok()?;
    Some(head)
}

/// grub4dos MBR boot code ends where the partition table begins.
const MBR_CODE_END: usize = 446;
/// How many leading sectors to back up before touching sector 0.
const BOOT_BACKUP_SECTORS: usize = 64;

/// The grub4dos stage1 is 8192 bytes = 16 sectors. The BIOS loads only
/// sector 0 (the MBR); the stage1 then reads sectors 1..15 to load the rest
/// of itself (its FAT/NTFS/ISO reading code lives there). Without those
/// sectors on the disk it dies with "Missing helper" and the stick is NOT
/// bootable. This is the bytes that must sit in sectors 1..15.
fn stage1_continuation() -> &'static [u8] {
    &GRLDR_MBR[512..]
}

/// First partition's start LBA (from the MBR partition table), if any.
/// Used to refuse targets whose first partition starts inside the sectors
/// the grub4dos stage1 continuation needs (1..15).
fn first_partition_lba(mbr: &[u8; 512]) -> Option<u32> {
    let mut first: Option<u32> = None;
    for i in 0..4usize {
        let e = 446 + 16 * i;
        if mbr[e + 4] == 0 {
            continue; // unused entry
        }
        let lba = u32::from_le_bytes([mbr[e + 8], mbr[e + 9], mbr[e + 10], mbr[e + 11]]);
        first = Some(first.map_or(lba, |f: u32| f.min(lba)));
    }
    first
}

/// The active (bootable) partition: (start LBA, type byte), or None if no
/// partition carries the 0x80 boot flag. grub4dos's MBR stage1 boots ONLY
/// from the active partition, so a stick with no active partition (or whose
/// active partition is an extended one) cannot boot via this method.
fn active_partition(mbr: &[u8; 512]) -> Option<(u32, u8)> {
    for i in 0..4usize {
        let e = 446 + 16 * i;
        if mbr[e] == 0x80 {
            let lba = u32::from_le_bytes([mbr[e + 8], mbr[e + 9], mbr[e + 10], mbr[e + 11]]);
            return Some((lba, mbr[e + 4]));
        }
    }
    None
}

/// Is `typ` an extended-partition type (which grub4dos cannot boot from)?
fn is_extended_type(typ: u8) -> bool {
    matches!(typ, 0x05 | 0x0F | 0x85)
}

// ---------------------------------------------------------------------------
// Pure helpers (unit-tested; no Win32 calls)
// ---------------------------------------------------------------------------

fn sha256_hex(data: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(data);
    format!("{:x}", h.finalize())
}

/// Validate the boot area of the target disk: MBR signature present, not
/// GPT, and at least one partition table entry (refuses superfloppies).
/// `head` must be at least 2 sectors (sector 1 holds the GPT header).
///
/// GPT is reported only when BOTH the "EFI PART" magic at LBA1 AND a
/// protective-MBR entry (type 0xEE) are present. Sticks converted from GPT
/// to MBR without wiping LBA1 keep a stale "EFI PART" header while Windows
/// (correctly) reports them as MBR - those must not be refused.
/// True when `head` (first >=2 sectors) carries a real GPT: "EFI PART"
/// magic at LBA1 plus a 0xEE protective-MBR entry. A stale "EFI PART"
/// header without 0xEE (ex-GPT stick converted to MBR) is NOT GPT.
pub fn is_gpt(head: &[u8]) -> bool {
    if head.len() < 1024 {
        return false;
    }
    &head[512..520] == b"EFI PART"
        && (0..4usize).any(|i| head[446 + 16 * i + 4] == 0xEE)
}

pub fn check_boot_area(head: &[u8]) -> Result<(), String> {
    if head.len() < 1024 {
        return Err("could not read the first two sectors of the target".into());
    }
    if head[510] != 0x55 || head[511] != 0xAA {
        return Err("no MBR 0x55AA signature on the target - refusing to continue".into());
    }
    if is_gpt(head) {
        return Err(
            concat!(
                "target is GPT-partitioned, so the grub4dos BIOS path cannot be installed: ",
                "its stage1 needs sectors 1-15, which on GPT hold the partition header/table. ",
                "Re-run with --uefi-bootx64 <BOOTX64.EFI> for a files-only UEFI install ",
                "(no raw sectors touched), convert the stick to MBR, or use the Rufus flow."
            )
            .into(),
        );
    }
    let mut n_parts = 0;
    for i in 0..4usize {
        // A used entry has a nonzero type byte (offset +4 of the 16-byte entry).
        if head[446 + 16 * i + 4] != 0 {
            n_parts += 1;
        }
    }
    if n_parts == 0 {
        return Err(
            "target has no partition table entries (superfloppy layout) - refusing to continue".into(),
        );
    }
    Ok(())
}

/// Overlay the grub4dos boot code onto the existing MBR: bytes 0..440 are
/// replaced; the Windows disk signature + reserved bytes (440..446),
/// partition table (446..510) and 0x55AA are preserved. The signature maps
/// drive letters (MountedDevices); the template carries zeros there, so a
/// naive 446-byte copy would zero it and make Windows drop the mounted
/// volume mid-install. Returns (new MBR, whether anything changed).
pub fn merged_mbr(mbr: &[u8; 512]) -> ([u8; 512], bool) {
    if mbr[510] != 0x55 || mbr[511] != 0xAA {
        // caller validated already; be defensive and leave it alone
        return (*mbr, false);
    }
    // End of executable boot code: the 4-byte disk signature + 2 reserved
    // bytes follow (440..446) and belong to Windows, not the bootloader.
    const MBR_CODE_LEN: usize = 440;
    let mut new_mbr = *mbr;
    let n = GRLDR_MBR.len().min(MBR_CODE_LEN);
    new_mbr[..n].copy_from_slice(&GRLDR_MBR[..n]);
    let changed = new_mbr[..MBR_CODE_END] != mbr[..MBR_CODE_END];
    (new_mbr, changed)
}

/// The grub4dos menu entry that loopback-boots the ISO via its own
/// bootloader (isolinux / El Torito).
pub fn menu_entry(title: &str, iso_rel: &str) -> String {
    format!(
        "\ntitle {title}\n\
         find --set-root --ignore-floppies --ignore-cd {iso_rel}\n\
         map {iso_rel} (0xff) || map --mem {iso_rel} (0xff)\n\
         map --hook\n\
         root (0xff)\n\
         chainloader (0xff)\n\
         boot\n"
    )
}

/// Header comment block for a fresh menu.lst (documents the direct
/// kernel/initrd pattern for ISOs the chainloader path does not like).
pub fn default_menu() -> String {
    "timeout 5\ndefault 0\n\
     # 'chainloader (0xff)' boots the ISO's own isolinux/El Torito bootloader.\n\
     # If a distro dislikes that, use a direct entry, e.g. (Ubuntu/Mint):\n\
     # title Ubuntu direct\n\
     # find --set-root --ignore-floppies --ignore-cd /_ISO/ubuntu.iso\n\
     # map /_ISO/ubuntu.iso (0xff) || map --mem /_ISO/ubuntu.iso (0xff)\n\
     # map --hook\n\
     # root (0xff)\n\
     # kernel /casper/vmlinuz boot=casper quiet splash\n\
     # initrd /casper/initrd\n"
        .to_string()
}

/// Append `entry` to `menu` unless an entry with the same title exists.
/// Returns (new content, whether it was appended).
pub fn upsert_menu(existing: &str, title: &str, entry: &str) -> (String, bool) {
    if existing.lines().any(|l| l.trim() == format!("title {title}").trim()) {
        (existing.to_string(), false)
    } else {
        (format!("{existing}{entry}"), true)
    }
}

fn sanitize_iso_name(name: &str) -> String {
    name.chars()
        .map(|c| if c.is_whitespace() { '_' } else { c })
        .collect()
}

// ---------------------------------------------------------------------------
// Win32 helpers
// ---------------------------------------------------------------------------

/// STORAGE_DEVICE_DESCRIPTOR (winapi 0.3.9 does not ship it).
/// Only the fields up to BusType matter here.
#[repr(C)]
#[allow(dead_code)]
struct StorageDeviceDescriptor {
    version: u32,
    size: u32,
    device_type: u8,
    device_type_modifier: u8,
    removable_media: u8,
    reads_cap9: u8,
    writes_cap9: u8,
    seek_cap9: u8,
    writes_cap16: u8,
    reads_cap16: u8,
    vendor_id_offset: u32,
    product_id_offset: u32,
    product_revision_offset: u32,
    serial_number_offset: u32,
    bus_type: u8,
}

#[repr(C)]
struct StoragePropertyQuery {
    property_id: u32, // StorageDeviceProperty = 0
    query_type: u32,  // PropertyStandardQuery = 0
}

fn bus_name(b: u8) -> &'static str {
    match b {
        0x01 => "SCSI",
        0x02 => "ATAPI",
        0x03 => "ATA",
        0x04 => "IEEE1394",
        0x07 => "USB",
        0x0A => "SAS",
        0x0B => "SATA",
        0x0C => "SD",
        0x0D => "MMC",
        0x11 => "NVMe",
        _ => "unknown",
    }
}

/// Tri-state USB-bus verdict for the safety gate: a query that answers
/// "Unknown" (STORAGE_BUS_TYPE 0x00) carries no information, so it folds
/// to None - the same as a failed/unsupported query - instead of
/// "definitely not USB". Cheap flash drives report Unknown, and the rule
/// for removable drives is "unknown bus -> included, known non-USB ->
/// refused" (fixed/internal disks still need --allow-fixed AND a USB bus).
fn bus_is_usb_tri(b: u8) -> Option<bool> {
    if b == 0x00 {
        None
    } else {
        Some(b == 0x07)
    }
}

fn ansi_at(buf: &[u8], offset: u32) -> Option<String> {
    if offset == 0 || offset as usize >= buf.len() {
        return None;
    }
    let end = (offset as usize + 64).min(buf.len());
    let raw = &buf[offset as usize..end];
    let len = raw.iter().position(|&c| c == 0).unwrap_or(raw.len());
    let s: String = raw[..len]
        .iter()
        .map(|&c| if c.is_ascii_graphic() || c == b' ' { c as char } else { ' ' })
        .collect();
    let s = s.trim().to_string();
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

/// Query the storage bus type + vendor/product of a device path
/// (\\.\PhysicalDriveN or \\.\X:). None = query unsupported (old Windows).
fn device_property(path: &str) -> Option<(u8, String)> {
    let f = std::fs::File::open(path).ok()?;
    use winapi::um::ioapiset::DeviceIoControl;
    use winapi::um::winioctl::IOCTL_STORAGE_QUERY_PROPERTY;
    let mut q = StoragePropertyQuery {
        property_id: 0,
        query_type: 0,
    };
    let mut outbuf = vec![0u8; 4096];
    let mut got = 0u32;
    let ok = unsafe {
        DeviceIoControl(
            f.as_raw_handle() as *mut winapi::ctypes::c_void,
            IOCTL_STORAGE_QUERY_PROPERTY,
            &mut q as *mut StoragePropertyQuery as *mut winapi::ctypes::c_void,
            std::mem::size_of::<StoragePropertyQuery>() as u32,
            outbuf.as_mut_ptr() as *mut _,
            outbuf.len() as u32,
            &mut got,
            std::ptr::null_mut(),
        )
    };
    // The descriptor header alone is 8 bytes; BusType lives at offset 32.
    if ok == 0 || (got as usize) <= 32 {
        return None;
    }
    let buf = &outbuf[..got as usize];
    // Descriptor header: version u32 @0, size u32 @4. BusType sits at offset 32
    // of the descriptor (see StorageDeviceDescriptor above).
    if buf.len() <= 32 {
        return None;
    }
    let desc = buf; // offsets below are absolute within the returned buffer
    let bus = desc[32];
    let vendor = ansi_at(desc, u32::from_le_bytes([desc[16], desc[17], desc[18], desc[19]]));
    let product = ansi_at(desc, u32::from_le_bytes([desc[20], desc[21], desc[22], desc[23]]));
    let mut name = String::new();
    if let Some(v) = vendor {
        name.push_str(&v);
    }
    if let Some(p) = product {
        if !name.is_empty() {
            name.push(' ');
        }
        name.push_str(&p);
    }
    Some((bus, name))
}

/// Map a drive letter to its \\.\PhysicalDriveN number.
fn device_number(letter: &str) -> Result<u32, String> {
    use winapi::um::ioapiset::DeviceIoControl;
    use winapi::um::winioctl::{IOCTL_STORAGE_GET_DEVICE_NUMBER, STORAGE_DEVICE_NUMBER};
    let vol = std::fs::File::open(format!(r"\\.\{}:", letter))
        .map_err(|e| format!("cannot open \\.\\{}: ({}); is the volume mounted?", letter, e))?;
    let mut num: STORAGE_DEVICE_NUMBER = unsafe { std::mem::zeroed() };
    let mut got = 0u32;
    let ok = unsafe {
        DeviceIoControl(
            vol.as_raw_handle() as *mut winapi::ctypes::c_void,
            IOCTL_STORAGE_GET_DEVICE_NUMBER,
            std::ptr::null_mut(),
            0,
            &mut num as *mut STORAGE_DEVICE_NUMBER as *mut _,
            std::mem::size_of::<STORAGE_DEVICE_NUMBER>() as u32,
            &mut got,
            std::ptr::null_mut(),
        )
    };
    if ok == 0 {
        return Err(format!(
            "IOCTL_STORAGE_GET_DEVICE_NUMBER failed on {} ({}); this Windows may be too old for the no-reformat mode",
            letter,
            sys::last_err()
        ));
    }
    Ok(num.DeviceNumber)
}

/// The target volume's starting offset on its physical disk (bytes), via
/// IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS. Used to confirm the volume is the
/// active partition grub4dos will boot from.
fn volume_disk_offset(letter: &str) -> Result<u64, String> {
    use winapi::um::ioapiset::DeviceIoControl;
    use winapi::um::winioctl::IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS;
    #[repr(C)]
    struct DiskExtent {
        disk_number: u32,
        starting_offset: i64,
        extent_length: i64,
    }
    #[repr(C)]
    struct VolumeDiskExtents {
        number_of_disk_extents: u32,
        extents: [DiskExtent; 1],
    }
    let vol = std::fs::File::open(format!(r"\\.\{}:", letter))
        .map_err(|e| format!("cannot open \\.\\{}: ({}); is the volume mounted?", letter, e))?;
    let mut out: VolumeDiskExtents = unsafe { std::mem::zeroed() };
    let mut got = 0u32;
    let ok = unsafe {
        DeviceIoControl(
            vol.as_raw_handle() as *mut winapi::ctypes::c_void,
            IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS,
            std::ptr::null_mut(),
            0,
            &mut out as *mut VolumeDiskExtents as *mut _,
            std::mem::size_of::<VolumeDiskExtents>() as u32,
            &mut got,
            std::ptr::null_mut(),
        )
    };
    if ok == 0 {
        return Err(format!(
            "IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS failed on {}: {}",
            letter,
            sys::last_err()
        ));
    }
    if out.number_of_disk_extents == 0 {
        return Err(format!("no disk extents reported for {}:", letter));
    }
    Ok(out.extents[0].starting_offset as u64)
}

// ---------------------------------------------------------------------------
// Target enumeration + verification
// ---------------------------------------------------------------------------

#[derive(Clone, Debug)]
pub struct UsbTarget {
    pub letter: String,
    pub label: String,
    pub fs: String,
    pub total: u64,
    pub free: u64,
    pub phys: u32,
    /// Some(true/false) = bus query answered with a known type,
    /// None = query unsupported/failed OR answered BusTypeUnknown.
    pub bus_is_usb: Option<bool>,
    pub bus: String,
    pub device_name: String,
}

impl UsbTarget {
    pub fn describe(&self) -> String {
        format!(
            "{}:  \"{}\"  {}  {:.1} GB  ->  \\\\.\\PhysicalDrive{}  [{}{}]",
            self.letter,
            self.label,
            self.fs,
            self.total as f64 / sys::GB as f64,
            self.phys,
            self.bus,
            if self.device_name.is_empty() {
                String::new()
            } else {
                format!(" {}", self.device_name)
            }
        )
    }
}

/// Enumerate plausible write targets. Classification:
///   removable + USB bus        -> included
///   removable + unknown bus    -> included (old Windows / card reader)
///   fixed + USB bus (USB HDD)  -> included only with allow_fixed
///   fixed + non-USB bus        -> NEVER included (internal disks)
pub fn probe_targets(allow_fixed: bool) -> Vec<UsbTarget> {
    let mut targets = Vec::new();
    for v in sys::list_volumes() {
        if v.cdrom || v.letter.is_empty() {
            continue;
        }
        if v.fs.is_empty() && v.total == 0 {
            continue; // unmountable
        }
        let phys = match device_number(&v.letter) {
            Ok(n) => n,
            Err(_) => continue, // no device-number mapping -> cannot target safely
        };
        let (bus, name) = match device_property(&format!(r"\\.\PhysicalDrive{}", phys)) {
            Some((b, n)) => (bus_name(b).to_string(), n),
            None => ("unknown".to_string(), String::new()),
        };
        let bus_is_usb = match device_property(&format!(r"\\.\{}:", v.letter)) {
            Some((b, _)) => bus_is_usb_tri(b),
            None => match device_property(&format!(r"\\.\PhysicalDrive{}", phys)) {
                Some((b, _)) => bus_is_usb_tri(b),
                None => None,
            },
        }; // None (failed query or BusTypeUnknown) counts as unknown, not as non-USB
        let include = if v.removable {
            !matches!(bus_is_usb, Some(false)) // removable but NOT USB: skip unless unknown
        } else {
            // fixed drives only via --allow-fixed, and only when USB bus
            allow_fixed && bus_is_usb == Some(true)
        };
        if !include {
            continue;
        }
        targets.push(UsbTarget {
            letter: v.letter,
            label: v.label,
            fs: v.fs,
            total: v.total,
            free: v.free,
            phys,
            bus_is_usb,
            bus,
            device_name: name,
        });
    }
    targets.sort_by(|a, b| a.letter.cmp(&b.letter));
    targets
}

/// Hard safety gate: is this target allowed at all?
fn verify_target(t: &UsbTarget, allow_fixed: bool) -> Result<(), String> {
    if t.phys == 0 {
        return Err(format!(
            "refusing: \\.\\{} maps to \\\\.\\PhysicalDrive0 - that is almost certainly the system disk",
            t.letter
        ));
    }
    if t.bus_is_usb == Some(false) {
        return Err(format!(
            "refusing: \\.\\{} is on the {} bus, not USB. This tool only writes to USB sticks",
            t.letter, t.bus
        ));
    }
    let vols = sys::list_volumes();
    if let Some(v) = vols.iter().find(|v| v.letter.eq_ignore_ascii_case(&t.letter)) {
        if !v.removable && !allow_fixed {
            return Err(format!(
                "refusing: \\.\\{} is not a removable drive. Pass --allow-fixed if you really mean it",
                t.letter
            ));
        }
    }
    Ok(())
}

/// Verify + (interactive) pick a target. `letter_hint` from --usb-letter.
pub fn choose_target(letter_hint: &str, allow_fixed: bool) -> Result<UsbTarget, String> {
    if sys::is_9x() {
        return Err(
            "the no-reformat mode needs NT-family Windows (it writes via the \\\\.\\PhysicalDriveN \
             device namespace). On Windows 9x use the Rufus flow instead."
                .into(),
        );
    }
    verify_assets()?;
    let targets = probe_targets(allow_fixed);

    let target = if !letter_hint.is_empty() {
        let want = letter_hint.trim_end_matches(':').to_ascii_uppercase();
        match targets.iter().find(|t| t.letter == want) {
            Some(t) => t.clone(),
            None => {
                // Not among the candidates: build the precise refusal from
                // the raw volume list (so --usb-letter C on a fixed internal
                // disk says exactly why it was refused).
                if let Some(v) = sys::list_volumes().iter().find(|v| v.letter == want).cloned() {
                    let phys = device_number(&v.letter).unwrap_or(u32::MAX);
                    let (bus, _) = device_property(&format!(r"\\.\{}:", want))
                        .map(|(b, _)| (bus_name(b).to_string(), String::new()))
                        .unwrap_or_else(|| ("unknown".to_string(), String::new()));
                    let t = UsbTarget {
                        letter: v.letter,
                        label: v.label,
                        fs: v.fs,
                        total: v.total,
                        free: v.free,
                        phys,
                        bus_is_usb: if bus == "unknown" { None } else { Some(bus == "USB") },
                        bus,
                        device_name: String::new(),
                    };
                    verify_target(&t, allow_fixed)?;
                    // passed verify (e.g. query-less old Windows) but was
                    // still filtered out of the candidate list: use it.
                    t
                } else {
                    let mut msg = format!("--usb-letter {}: no such volume is mounted.\n", want);
                    for t in &targets {
                        msg.push_str(&format!("  {}\n", t.describe()));
                    }
                    return Err(msg);
                }
            }
        }
    } else {
        if targets.is_empty() {
            return Err(
                "no suitable USB target found (need a removable USB drive with an MBR partition table). \
                 Plug the stick in, or use the Rufus flow."
                    .into(),
            );
        }
        if targets.len() == 1 {
            targets[0].clone()
        } else {
        out::step("Select the USB stick for the non-destructive write:");
        for (i, t) in targets.iter().enumerate() {
            out::info(&format!("  {:2}. {}", i + 1, t.describe()));
        }
        let ans = out::prompt(&format!(
            "Choose a stick [1..{}], or press Enter to cancel: ",
            targets.len()
        ));
        match ans.parse::<usize>() {
            Ok(n) if n >= 1 && n <= targets.len() => targets[n - 1].clone(),
            _ => return Err("cancelled.".into()),
        }
        }
    };

    verify_target(&target, allow_fixed)?;
    Ok(target)
}

// ---------------------------------------------------------------------------
// Assets (embedded, SHA-256 pinned)
// ---------------------------------------------------------------------------

fn verify_assets() -> Result<(), String> {
    for (name, data, want) in [
        ("grldr", grldr(), GRLDR_SHA256),
        ("grldr.mbr", GRLDR_MBR, GRLDR_MBR_SHA256),
    ] {
        let got = sha256_hex(data);
        if !got.eq_ignore_ascii_case(want) {
            return Err(format!(
                "embedded grub4dos asset {} failed its SHA-256 check\n  expected: {}\n  actual:   {}",
                name, want, got
            ));
        }
        if name == "grldr.mbr" && data.len() < MBR_CODE_END {
            return Err("embedded grldr.mbr is truncated".into());
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Install
// ---------------------------------------------------------------------------

/// Full non-destructive install of `iso` onto a verified target.
/// `uefi_bootx64` is an optional standalone GRUB EFI binary to place at
/// \EFI\BOOT\BOOTX64.EFI (FAT32 sticks, Secure Boot off) - files only,
/// no formatting either way. When empty the vendored assets/BOOTX64.EFI is
/// used if one was built in. `want_bios`/`want_uefi` are the GUI checkboxes
/// (both on by default when supported); at least one must be true.
/// `preconfirmed` skips the typed drive-letter confirmation and must only
/// be true when the user already picked this exact target in the GUI
/// (INSTALL-page radio + Install click): raw-sector writes must never hinge
/// on a stale flag, so every other path keeps the console gate.
pub fn install_from_iso(
    iso: &str,
    letter_hint: &str,
    allow_fixed: bool,
    uefi_bootx64: &str,
    want_bios: bool,
    want_uefi: bool,
    ui: Option<&dyn WriteUi>,
    preconfirmed: bool,
) -> Result<(UsbTarget, WriteMetrics, Option<PendingMbr>), String> {
    if !want_bios && !want_uefi {
        // Say WHY, not just that: the GUI greys out unsupported paths (the
        // reason sits in the checkbox label), but that context is gone by
        // the time this error is read. Probe the selected stick so the
        // message stands alone on the FAILED page and the console alike.
        let mut why = String::from("both BIOS and UEFI boot are disabled - nothing to install.");
        let letter = letter_hint.trim_end_matches(':');
        if !letter.is_empty() {
            let caps = probe_boot_caps(letter, uefi_bootx64);
            why.push_str(&format!(
                "\n  {}: BIOS {} | UEFI {}.",
                letter,
                if caps.bios_ok { "supported (re-check the INSTALL-page box)".into() } else { format!("unavailable - {}", caps.bios_why) },
                if caps.uefi_ok { "supported (re-check the INSTALL-page box)".into() } else { format!("unavailable - {}", caps.uefi_why) },
            ));
        } else {
            why.push_str(" Re-check one of the INSTALL-page BIOS/UEFI boxes (unsupported paths are greyed out with the reason), or use a FAT32 MBR stick.");
        }
        return Err(why);
    }
    let target = choose_target(letter_hint, allow_fixed)?;

    out::step("Non-destructive write (no reformat):");
    out::info(&format!("  target: {}", target.describe()));
    out::info(&format!("  iso   : {}", iso));
    out::info(&format!("  plan  : BIOS boot {} + UEFI boot {} (files always: ISO as a file, menu.lst, grub.cfg).",
        if want_bios { "ON (grub4dos MBR bytes 0..440 ONLY, signature + partition table kept)" } else { "OFF" },
        if want_uefi { "ON (BOOTX64.EFI)" } else { "OFF" }));
    out::info("          Nothing is formatted; existing files are not modified or deleted.");
    // (board-vs-selection warnings print inside install_on_target, next to
    // the per-stick capability summary)

    // Final typed confirmation: the user must name the drive to be touched.
    // Skipped when the GUI already confirmed this exact target (radio +
    // Install) - re-asking on the console would stall the working phase.
    if preconfirmed {
        out::info(&format!("Target {} confirmed on the INSTALL page - no re-typing needed.", target.letter));
    } else {
        let ans = out::prompt(&format!(
            "Type the target drive letter (e.g. {}) to confirm, or press Enter to cancel: ",
            target.letter
        ));
        if !ans.eq_ignore_ascii_case(&target.letter) {
            return Err(format!(
                "cancelled (expected '{}', got '{}')",
                target.letter,
                if ans.is_empty() { "<Enter>" } else { &ans }
            ));
        }
    }

    let (metrics, pending) = install_on_target(&target, iso, uefi_bootx64, want_bios, want_uefi, ui)?;
    Ok((target, metrics, pending))
}

/// Print the dual BIOS/UEFI capability summary: which firmware modes will
/// boot this stick and why, warning whenever only one will work.
fn report_bootability(bios_ok: bool, bios_why: &str, uefi_ok: bool, title: &str) {
    out::step("Boot capability:");
    out::info(&format!(
        "  BIOS/CSM : {} - {}",
        if bios_ok { "YES" } else { "NO" },
        bios_why
    ));
    out::info(&format!(
        "  UEFI     : {}",
        if uefi_ok {
            format!("YES ('{}' via BOOTX64.EFI + grub.cfg)", title)
        } else {
            "NO (--uefi-bootx64 not installed; see above)".to_string()
        },
    ));
    if bios_ok != uefi_ok {
        out::warn("Only one firmware mode will boot this stick - check the target machine boots that way.");
    }
    let (_, sb) = sys::firmware();
    if uefi_ok && sb == sys::SecBoot::Enabled {
        out::warn("Secure Boot is ON on this machine: an unsigned BOOTX64.EFI will be rejected - turn Secure Boot off or use a signed loader.");
    }
}

/// Board-vs-selection warnings: will the chosen BIOS/UEFI mix boot on THIS
/// motherboard? Returns (hard, message): hard = will NOT boot here,
/// soft = might not. Pure (unit-tested); printing lives in report_board.
/// Note the scope: these describe the machine running the installer - if
/// the stick targets a different PC, that one is what matters.
pub fn board_warnings(
    want_bios: bool,
    want_uefi: bool,
    caps: &sys::BoardCaps,
) -> Vec<(bool, String)> {
    let mut w = Vec::new();
    if want_uefi && caps.uefi_capable == sys::FwCap::No {
        w.push((true, "the stick includes a UEFI path but this board is legacy-only - it will NOT boot here (fine if the stick targets another, UEFI-capable PC)".into()));
    }
    if !want_bios && !caps.booted_uefi {
        // UEFI-only stick, this machine booted legacy. (If the board also
        // lacks UEFI entirely the first warning already fired harder.)
        w.push((true, "the stick is UEFI-only but this machine booted legacy/BIOS - it will NOT boot here (enable UEFI boot or use a UEFI-capable PC)".into()));
    }
    if want_bios && caps.bios_capable == sys::FwCap::Unknown {
        w.push((false, "the stick includes a BIOS path but this machine booted UEFI and CSM/legacy presence is unknown - check firmware setup for a CSM/Legacy option (fine if the stick targets another PC)".into()));
    }
    if !want_uefi && caps.booted_uefi {
        w.push((false, "the stick has no UEFI path but this machine booted UEFI - it needs CSM/legacy boot here (fine if the stick targets a BIOS/CSM PC)".into()));
    }
    w
}

/// One-line board summary for the GUI INSTALL page. `None` when the
/// selection raises no board objection (still shows the basis).
pub fn board_note_short(want_bios: bool, want_uefi: bool, caps: &sys::BoardCaps) -> String {
    let boot = if caps.booted_uefi { "UEFI" } else { "legacy/BIOS" };
    let cap = |c: sys::FwCap| match c {
        sys::FwCap::Yes => "yes",
        sys::FwCap::No => "no",
        sys::FwCap::Unknown => "?",
    };
    let mut s = format!(
        "This PC boots {} (board: UEFI {}, legacy/CSM {})",
        boot,
        cap(caps.uefi_capable),
        cap(caps.bios_capable)
    );
    if board_warnings(want_bios, want_uefi, caps).iter().any(|(hard, _)| *hard) {
        s.push_str(" - WARNING: this selection will NOT boot this PC");
    }
    s
}

/// Print the board-vs-selection warnings (both install paths call this).
fn report_board(want_bios: bool, want_uefi: bool) {
    let caps = sys::board_caps();
    out::info(&format!(
        "Board firmware: this machine boots {}; UEFI-capable: {:?}, legacy/CSM-capable: {:?} ({})",
        if caps.booted_uefi { "UEFI" } else { "legacy/BIOS" },
        caps.uefi_capable,
        caps.bios_capable,
        caps.detail
    ));
    for (hard, msg) in board_warnings(want_bios, want_uefi, caps) {
        if hard {
            out::warn(&format!("THIS MACHINE: {}", msg));
        } else {
            out::info(&format!("Note (this machine): {}", msg));
        }
    }
}

/// Plain file I/O phase shared by both paths: ISO as a file (+ SHA-256
/// verify), menu.lst (BIOS menu, written whenever `with_bios_files`), and
/// the optional UEFI side-load. Returns (menu title, whether UEFI files
/// were installed).
fn install_files(
    t: &UsbTarget,
    iso: &str,
    iso_len: u64,
    uefi_bootx64: &str,
    with_bios_files: bool,
    want_uefi: bool,
    ui: Option<&dyn WriteUi>,
) -> Result<(String, bool, WriteMetrics), String> {
    let root = format!("{}:\\", t.letter);
    if with_bios_files {
        let grldr_path = format!("{}grldr", root);
        if sys::path_exists(&grldr_path) {
            match std::fs::read(&grldr_path) {
                Ok(old) if old == grldr() => out::info("grldr already present and up to date."),
                Ok(_) => {
                    out::warn(&format!("{} already exists with different content.", grldr_path));
                    if ui.is_some() {
                        // GUI working phase: no console to ask on. Fail onto
                        // the FAILED page instead of stalling on a prompt.
                        return Err(format!("{} already exists with different content and was left untouched. Rename or delete it and click Install again, or re-run with --no-gui to confirm the overwrite on the console.", grldr_path));
                    }
                    let ans = out::prompt("Overwrite it with the bundled grub4dos grldr? Type OK to overwrite, Enter to abort: ");
                    if ans != "OK" {
                        return Err("aborted - existing grldr left untouched.".into());
                    }
                    std::fs::write(&grldr_path, grldr()).map_err(|e| format!("copy grldr: {}", e))?;
                    out::info("grldr overwritten (bundled grub4dos 0.4.6a).");
                }
                Err(e) => return Err(format!("cannot read existing grldr: {}", e)),
            }
        } else {
            std::fs::write(&grldr_path, grldr()).map_err(|e| format!("copy grldr: {}", e))?;
            out::info("grldr written to the volume root.");
        }
    }
    let iso_name = std::path::Path::new(iso)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "image.iso".to_string());
    let safe_name = sanitize_iso_name(&iso_name);
    sys::create_dir_all(&format!("{}_ISO", root));
    let iso_dst = format!("{}_ISO\\{}", root, safe_name);
    let iso_rel = format!("/_ISO/{}", safe_name);
    let (_src, metrics) = copy_and_verify_iso(iso, &iso_dst, iso_len, ui)?;
    let title = format!("{} (loopback ISO)", iso_name.trim_end_matches(".iso"));
    // menu.lst uses grub4dos syntax; grub4dos-for-UEFI reads the same file,
    // so it doubles as the UEFI menu when that loader is used.
    let menu_path = format!("{}menu.lst", root);
    let (menu, existed) = match std::fs::read_to_string(&menu_path) {
        Ok(s) => (s, true),
        Err(_) => (default_menu(), false),
    };
    let entry = menu_entry(&title, &iso_rel);
    let (menu, added) = upsert_menu(&menu, &title, &entry);
    if added {
        std::fs::write(&menu_path, menu).map_err(|e| format!("write menu.lst: {}", e))?;
        out::info(&format!("{} menu.lst entry '{}'", if existed { "Appended" } else { "Created" }, title));
    } else {
        out::info(&format!("menu.lst already contains an entry titled '{}'", title));
    }
    // UEFI side-load (files only; FAT32 stick, Secure Boot off for unsigned
    // loaders). Source priority: --uefi-bootx64 file, then the vendored
    // assets/BOOTX64.EFI (grub4dos-for-UEFI preferred - it reuses this same
    // menu.lst/ISO mapping; plain GRUB2 works via the generated grub.cfg).
    let mut uefi_ok = false;
    if !uefi_bootx64.is_empty() && !sys::path_exists(uefi_bootx64) {
        out::warn(&format!("--uefi-bootx64 not found: {} (falling back to the vendored loader, if any)", uefi_bootx64));
    }
    let uefi_bytes: Option<Vec<u8>> = if !uefi_bootx64.is_empty() && sys::path_exists(uefi_bootx64) {
        Some(std::fs::read(uefi_bootx64).map_err(|e| format!("read {}: {}", uefi_bootx64, e))?)
    } else {
        bundled_uefi().map(|b| b.to_vec())
    };
    if let Some(bytes) = uefi_bytes {
        let bootdir = format!("{}EFI\\BOOT", root);
        sys::create_dir_all(&bootdir);
        std::fs::write(format!("{}\\BOOTX64.EFI", bootdir), &bytes)
            .map_err(|e| format!("write BOOTX64.EFI: {}", e))?;
        std::fs::write(format!("{}\\grub.cfg", bootdir), uefi_cfg(&title, &iso_rel))
            .map_err(|e| format!("write grub.cfg: {}", e))?;
        out::info("UEFI: BOOTX64.EFI + grub.cfg installed (no formatting).");
        uefi_ok = true;
    } else if want_uefi {
        out::warn("UEFI requested but no loader available (vendor assets/BOOTX64.EFI or pass --uefi-bootx64) - UEFI files skipped.");
    }
    Ok((title, uefi_ok, metrics))
}

/// A validated, file-complete install whose boot sectors are still
/// unwritten: every slow, fallible step (copies, hashes, menus, UEFI files -
/// plus the main-phase drops that run later) is DONE, and only the
/// seconds-long sector flip remains. Travels from the file phase to the
/// final commit across the main-phase tail (through `GuiWork` in GUI flows).
/// Plain data only (no handles, no lifetimes).
#[derive(Clone, Debug)]
pub struct PendingMbr {
    pub target: UsbTarget,
    pub phys_path: String,
    pub new_mbr: [u8; 512],
    pub early_mbr: [u8; 512],
    pub mbr_changed: bool,
    pub cont_changed: bool,
    pub backup_path: String,
    pub want_bios: bool,
    pub want_uefi: bool,
    pub title: String,
    pub uefi_ok: bool,
}

/// Final step of the non-destructive install, run AFTER every file drop
/// (install files AND the main-phase lsl/wifi/driver/flatpak drops): flip
/// the boot sectors. A volume drop from here on strands nothing - the files
/// are durable and verified, and the reboot offer is firmware-enumerated
/// (needs no mount). Re-reads sector 0 and refuses on any external change
/// since validation, so a stale payload can never clobber someone else's
/// partition table.
pub fn commit_boot_sectors(p: &PendingMbr) -> Result<(), String> {
    out::step("Committing the boot sectors (final step - all files are in place)...");
    let cont = stage1_continuation();
    if p.want_bios && (p.mbr_changed || p.cont_changed) {
        let mut disk = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(&p.phys_path)
            .map_err(|e| {
                if e.kind() == std::io::ErrorKind::PermissionDenied {
                    "access denied on the physical drive - run the installer as Administrator".to_string()
                } else {
                    format!("cannot open {}: {}", p.phys_path, e)
                }
            })?;
        let mut cur = [0u8; 512];
        disk.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
        disk.read_exact(&mut cur).map_err(|e| e.to_string())?;
        if cur != p.early_mbr {
            return Err("the MBR changed since validation (another tool touched the disk?) - aborting without writing; the files are in place and verified, so re-running re-validates and resumes safely.".into());
        }
        disk.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
        disk.write_all(&p.new_mbr).map_err(|e| format!("MBR write failed: {}", e))?;
        disk.seek(SeekFrom::Start(512)).map_err(|e| e.to_string())?;
        disk.write_all(cont).map_err(|e| format!("grub4dos stage1 continuation write failed: {}", e))?;
        disk.sync_all().map_err(|e| format!("MBR flush failed: {}", e))?;
        // read back + verify
        let mut back = vec![0u8; 512 + cont.len()];
        disk.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
        disk.read_exact(&mut back).map_err(|e| e.to_string())?;
        if back[..512] != p.new_mbr[..] {
            return Err(format!(
                "MBR read-back mismatch - the write did not stick. Restore with the backup at {}",
                p.backup_path
            ));
        }
        if &back[512..] != cont {
            return Err(format!(
                "grub4dos stage1 continuation read-back mismatch - the write did not stick. Restore with the backup at {}",
                p.backup_path
            ));
        }
        if &back[446..510] != &p.early_mbr[446..510] {
            return Err("partition table changed during the MBR write - aborting.".into());
        }
        out::info("grub4dos boot code written to the MBR + stage1 continuation (sectors 1-15); signature and partition table preserved.");
        drop(disk);
    } else if p.want_bios {
        out::info("grub4dos boot code already present - MBR untouched.");
    } else {
        out::info("BIOS boot not selected - raw sectors untouched (UEFI files only).");
    }

    report_board(p.want_bios, p.want_uefi);
    report_bootability(
        p.want_bios,
        if p.want_bios { "grub4dos MBR stage1 + menu.lst loopback" } else { "not selected (UEFI files only; MBR untouched)" },
        p.uefi_ok,
        &p.title,
    );
    out::step("Done - nothing was formatted; existing files were untouched.");
    out::info("Safely eject the stick, then boot from it via the firmware boot menu.");
    if p.want_bios {
        out::info(&format!(
            "If anything goes wrong, restore the original MBR with the backup at {}",
            p.backup_path
        ));
    }
    Ok(())
}

fn install_on_target(t: &UsbTarget, iso: &str, uefi_bootx64: &str, want_bios: bool, want_uefi: bool, ui: Option<&dyn WriteUi>) -> Result<(WriteMetrics, Option<PendingMbr>), String> {
    let fs_uc = t.fs.to_ascii_uppercase();
    // grub4dos reads FAT12/16/32 and NTFS only. exFAT (the default on many
    // large sticks) is NOT readable by grub4dos, so a stick left exFAT cannot
    // boot via this method - refuse with a clear reason rather than write a
    // stick that silently won't boot.
    if !(fs_uc.starts_with("FAT") || fs_uc == "NTFS") {
        let hint = if fs_uc == "EXFAT" {
            "exFAT is not readable by grub4dos, so this stick could not boot.\n\
             Reformat it to FAT32 (<=32 GB) or NTFS first, or use the Rufus flow (which repartitions)."
        } else {
            "grub4dos needs FAT32 or NTFS.\n\
             Reformat the stick to FAT32/NTFS, or use the Rufus flow (which repartitions)."
        };
        return Err(format!(
            "filesystem {} is not supported by the no-reformat method. {}",
            t.fs, hint
        ));
    }
    let iso_len = sys::file_size(iso).ok_or_else(|| format!("ISO not found: {}", iso))?;
    if fs_uc.starts_with("FAT") && iso_len >= 4 * sys::GB {
        return Err(
            "ISOs >= 4 GiB cannot exist on FAT32. Use an NTFS stick, or the Rufus flow (which repartitions)."
                .into(),
        );
    }
    if t.free < iso_len + sys::MB {
        return Err(format!(
            "{:.1} GB free on {}:, the ISO needs {:.1} GB - not enough space for the no-reformat method.",
            t.free as f64 / sys::GB as f64,
            t.letter,
            iso_len as f64 / sys::GB as f64
        ));
    }

    // ---- open the physical disk ----
    let phys_path = format!(r"\\.\PhysicalDrive{}", t.phys);
    let mut disk = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(&phys_path)
        .map_err(|e| {
            if e.kind() == std::io::ErrorKind::PermissionDenied {
                "access denied on the physical drive - run the installer as Administrator".to_string()
            } else {
                format!("cannot open {}: {}", phys_path, e)
            }
        })?;

    // ---- read + validate + back up the boot area ----
    let mut head = vec![0u8; BOOT_BACKUP_SECTORS * 512];
    disk.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
    disk.read_exact(&mut head).map_err(|e| e.to_string())?;
    // GPT sticks take a files-only UEFI detour (no raw sector writes at
    // all: grub4dos's stage1 needs sectors 1-15, which on GPT hold the
    // partition header/table). UEFI firmware only reads FAT, so NTFS/exFAT
    // GPT sticks are refused with a reason.
    if is_gpt(&head) {
        drop(disk);
        if !fs_uc.starts_with("FAT") {
            return Err(format!(
                "GPT stick with {} filesystem: the files-only UEFI install needs FAT32 (UEFI firmware cannot read {} without extra drivers). Reformat to FAT32, convert to MBR, or use the Rufus flow.",
                t.fs, t.fs
            ));
        }
        if !want_uefi {
            return Err(
                concat!(
                    "GPT stick cannot take the grub4dos BIOS path (sectors 1-15 are the GPT header/table) ",
                    "and UEFI boot is unchecked - nothing to install. Check UEFI boot, convert the stick to MBR, ",
                    "or use the Rufus flow."
                )
                .into(),
            );
        }
        if uefi_source_name(uefi_bootx64).is_none() {
            return Err(
                concat!(
                    "GPT stick: the grub4dos BIOS path cannot be installed on GPT and no UEFI loader is available. ",
                    "Vendor one (assets/BOOTX64.EFI, grub4dos-for-UEFI preferred) or pass --uefi-bootx64 <BOOTX64.EFI>, ",
                    "convert the stick to MBR, or use the Rufus flow."
                )
                .into(),
            );
        }
        out::step("GPT stick: files-only UEFI install (no raw sectors touched).");
        report_board(false, true);
        let (title, uefi_ok, metrics) = install_files(t, iso, iso_len, uefi_bootx64, false, true, ui)?;
        report_bootability(false, "GPT stick - grub4dos BIOS stage1 has nowhere to live (sectors 1-15 are the GPT header/table)", uefi_ok, &title);
        return Ok((metrics, None));
    }
    check_boot_area(&head)?;

    // grub4dos's MBR stage1 boots the active (0x80) partition if one exists;
    // if that partition is a filesystem it boots it directly, if it is an
    // extended partition it scans into it and boots the first logical
    // FAT/NTFS partition. With no active partition it scans all partitions.
    // So the only clear, verifiable conflict is an active *filesystem*
    // partition that is not the volume we are about to write grldr onto.
    // (Verified by tests/qemu-boot-test.sh, incl. the extended + no-active
    // cases.)
    let mbr: [u8; 512] = head[..512].try_into().unwrap();
    // The active-partition check only matters when the BIOS stage1 will
    // actually be installed; UEFI-only leaves the MBR alone.
    if want_bios {
    match active_partition(&mbr) {
        Some((lba, typ)) => {
            if !is_extended_type(typ) {
                let vol_off = volume_disk_offset(&t.letter)?;
                if (lba as u64) * 512 != vol_off {
                    return Err(format!(
                        "the target volume {}: is NOT the active (bootable) partition on the disk\n\
                         (active partition starts at sector {}, this volume at sector {}).\n\
                         grub4dos boots the active partition, so this stick would not boot.\n\
                         Mark the target partition active (diskpart: select partition; active), or use a\n\
                         single-partition stick, or the Rufus flow.",
                        t.letter,
                        lba,
                        vol_off / 512
                    ));
                }
            }
        }
        None => {
            // No active partition: grub4dos scans. Fine for a single partition;
            // warn if there are several (it may boot a different one).
            let n = (0..4usize).filter(|&i| mbr[446 + 16 * i + 4] != 0).count();
            if n > 1 {
                out::warn(
                    "no active partition and multiple partitions - grub4dos will boot the first\n\
                     bootable one, which may not be the target volume. Consider marking the target\n\
                     partition active (diskpart: select partition; active).",
                );
            }
        }
    }
    } // end if want_bios (active-partition check)
    let backup_path = format!(
        "{}\\lsl-usb\\mbr-backup-PhysicalDrive{}.bin",
        sys::local_app_data(),
        t.phys
    );
    if let Some(i) = backup_path.rfind('\\') {
        sys::create_dir_all(&backup_path[..i]);
    }
    if std::fs::write(&backup_path, &head).is_ok() {
        out::info(&format!("Backed up the first {} sectors to {}", BOOT_BACKUP_SECTORS, backup_path));
    } else {
        out::warn(&format!("Could not write the MBR backup file ({}); aborting to be safe.", backup_path));
        return Err("MBR backup could not be written - aborting (nothing was modified).".into());
    }

    // ---- the ONLY raw writes: grub4dos stage1 into the MBR boot-code area
    // (bytes 0..440: code only - signature and partition table preserved) AND its continuation into
    // sectors 1..15. The stage1 is 8192 bytes = 16 sectors; the BIOS loads
    // only sector 0, and the stage1 then reads sectors 1..15 to load the
    // rest of itself - without them it dies with "Missing helper" and the
    // stick is NOT bootable. ----
    let mbr: [u8; 512] = head[..512].try_into().unwrap();
    // Precompute the BIOS payload (BIOS only - UEFI-only touches no raw
    // sectors, and the continuation must not clobber the first partition).
    // `new_mbr`/`cont` are only written below when want_bios.
    let (new_mbr, mbr_changed, cont_changed) = if want_bios {
        if let Some(first) = first_partition_lba(&mbr) {
            if first <= 15 {
                return Err(format!(
                    "the first partition starts at sector {} - the grub4dos stage1 needs sectors 1..15 for its continuation. Repartition the stick so the first partition starts after sector 15, or use the Rufus flow.",
                    first
                ));
            }
        }
        let (nm, mc) = merged_mbr(&mbr);
        let cc = &head[512..512 + stage1_continuation().len()] != stage1_continuation();
        (nm, mc, cc)
    } else {
        (mbr, false, false)
    };
    // NOTE: `new_mbr`/`mbr_changed`/`cont_changed` are computed here from the
    // validated head, but the write itself happens LAST, after all file I/O
    // (see below): raw-sector writes can knock the volume offline, and
    // nothing after them needs the volume - while a failure anywhere in the
    // file phase leaves the boot sectors untouched. The late block re-reads
    // sector 0 and refuses to write if the disk changed meanwhile.
    // The physical handle served its purpose (validation reads + backup);
    // drop it - the late block reopens it for the write.
    drop(disk);

    // Pre-file-phase mount check: if the volume is unreachable here, every
    // file op below fails with a misleading OS error - fail LOUDLY with the
    // cause instead (after a patient wait: Windows can be slow (re-)mounting
    // sticks, as seen live with zero disk errors in the event log).
    let root = format!("{}:\\", t.letter);
    if !sys::path_exists(&root) {
        // One retry for a slow mount, then fail LOUDLY: nothing before this
        // point disturbs the mount (raw writes happen last), so a missing
        // volume here means yanked/dead stick, not impatience.
        out::warn(&format!("{}: volume not reachable - retrying once after 5s...", t.letter));
        std::thread::sleep(std::time::Duration::from_secs(5));
        if !sys::path_exists(&root) {
            let gone = sys::list_volumes().iter().all(|v| !v.letter.eq_ignore_ascii_case(&t.letter));
            return Err(if gone {
                format!("target volume {}: disappeared. Unplug the stick, plug it back in, and re-run - nothing was formatted (an MBR backup is at {}), so re-running resumes safely.", t.letter, backup_path)
            } else {
                format!("target volume {}: is still listed but not reachable at '{}'. Unplug the stick, plug it back in, and re-run (an MBR backup is at {}); if it recurs, the stick may be failing - try another port/cable or another stick.", t.letter, root, backup_path)
            });
        }
        out::info(&format!("{}: reachable again.", t.letter));
    }

    // grldr (the BIOS loader) must be in the volume root - skipped for
    // UEFI-only installs, which boot BOOTX64.EFI instead.
    if want_bios {
    let grldr_path = format!("{}grldr", root);
    if sys::path_exists(&grldr_path) {
        match std::fs::read(&grldr_path) {
            Ok(old) if old == grldr() => out::info("grldr already present and up to date."),
            Ok(_) => {
                out::warn(&format!("{} already exists with different content.", grldr_path));
                if ui.is_some() {
                    // GUI working phase: no console to ask on. Fail onto
                    // the FAILED page instead of stalling on a prompt.
                    return Err(format!("{} already exists with different content and was left untouched. Rename or delete it and click Install again, or re-run with --no-gui to confirm the overwrite on the console.", grldr_path));
                }
                let ans = out::prompt("Overwrite it with the bundled grub4dos grldr? Type OK to overwrite, Enter to abort: ");
                if ans != "OK" {
                    return Err("aborted - existing grldr left untouched.".into());
                }
                std::fs::write(&grldr_path, grldr()).map_err(|e| format!("copy grldr: {}", e))?;
                out::info("grldr overwritten (bundled grub4dos 0.4.6a).");
            }
            Err(e) => return Err(format!("cannot read existing grldr: {}", e)),
        }
    } else {
        std::fs::write(&grldr_path, grldr()).map_err(|e| format!("copy grldr: {}", e))?;
        out::info("grldr written to the volume root.");
    }
    } // end if want_bios (grldr)

    // ISO as a regular file under \_ISO\ (skip when an equal-sized copy exists).
    let iso_name = std::path::Path::new(iso)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "image.iso".to_string());
    let safe_name = sanitize_iso_name(&iso_name);
    sys::create_dir_all(&format!("{}_ISO", root));
    let iso_dst = format!("{}_ISO\\{}", root, safe_name);
    let iso_rel = format!("/_ISO/{}", safe_name);
    // The whole point of this mode is a *bootable* stick: a corrupted ISO
    // copy (bad USB write, or a stale same-size file already on the stick)
    // would loopback-boot garbage. So the stick copy is SHA-256-verified
    // against the source in every case.
    let (_src, metrics) = copy_and_verify_iso(iso, &iso_dst, iso_len, ui)?;

    // menu.lst: create or append (idempotent per title).
    let title = format!("{} (loopback ISO)", iso_name.trim_end_matches(".iso"));
    let menu_path = format!("{}menu.lst", root);
    let (menu, existed) = match std::fs::read_to_string(&menu_path) {
        Ok(s) => (s, true),
        Err(_) => (default_menu(), false),
    };
    let entry = menu_entry(&title, &iso_rel);
    let (menu, added) = upsert_menu(&menu, &title, &entry);
    if added {
        std::fs::write(&menu_path, menu).map_err(|e| format!("write menu.lst: {}", e))?;
        out::info(&format!(
            "{} menu.lst entry '{}'",
            if existed { "Appended" } else { "Created" },
            title
        ));
    } else {
        out::info(&format!("menu.lst already contains an entry titled '{}'", title));
    }

    // UEFI side-load (files only; FAT32 stick, Secure Boot off for unsigned
    // loaders). Source priority: --uefi-bootx64 file, then the vendored
    // assets/BOOTX64.EFI. Skipped when UEFI boot is unchecked.
    if want_uefi {
        if !uefi_bootx64.is_empty() && !sys::path_exists(uefi_bootx64) {
            out::warn(&format!("--uefi-bootx64 not found: {} (falling back to the vendored loader, if any)", uefi_bootx64));
        }
        let uefi_bytes: Option<Vec<u8>> = if !uefi_bootx64.is_empty() && sys::path_exists(uefi_bootx64) {
            Some(std::fs::read(uefi_bootx64).map_err(|e| format!("read {}: {}", uefi_bootx64, e))?)
        } else {
            bundled_uefi().map(|b| b.to_vec())
        };
        if let Some(bytes) = uefi_bytes {
            let bootdir = format!("{}EFI\\BOOT", root);
            sys::create_dir_all(&bootdir);
            std::fs::write(format!("{}\\BOOTX64.EFI", bootdir), &bytes)
                .map_err(|e| format!("write BOOTX64.EFI: {}", e))?;
            std::fs::write(format!("{}\\grub.cfg", bootdir), uefi_cfg(&title, &iso_rel))
                .map_err(|e| format!("write grub.cfg: {}", e))?;
            out::info("UEFI: BOOTX64.EFI + grub.cfg installed (no formatting).");
        } else {
            out::warn("UEFI requested but no loader available (vendor assets/BOOTX64.EFI or pass --uefi-bootx64) - UEFI files skipped.");
        }
    } else {
        out::info("UEFI boot not selected - EFI files skipped.");
    }

    // Flush the volume: file data must be durable before the boot-code flip.
    if let Ok(v) = std::fs::OpenOptions::new()
        .write(true)
        .open(format!(r"\\.\{}:", t.letter))
    {
        let _ = v.sync_all();
    }

    // Sectors stay untouched here - they flip in commit_boot_sectors, after
    // the main-phase drops (see below).

    let uefi_installed = sys::path_exists(&format!("{}\\EFI\\BOOT\\BOOTX64.EFI", root));
    // Package the validated payload for the final commit, which runs after
    // the main-phase drops (commit_boot_sectors re-checks freshness there).
    let pending = PendingMbr {
        target: t.clone(),
        phys_path: phys_path.clone(),
        new_mbr,
        early_mbr: mbr,
        mbr_changed,
        cont_changed,
        backup_path,
        want_bios,
        want_uefi,
        title,
        uefi_ok: want_uefi && uefi_installed,
    };
    Ok((metrics, Some(pending)))
}

fn uefi_cfg(title: &str, iso_rel: &str) -> String {
    format!(
        "set timeout=5\n\
         menuentry \"{title}\" {{\n\
         \x20   search --no-floppy --set=root --file {iso_rel}\n\
         \x20   loopback loop {iso_rel}\n\
         \x20   # Adjust kernel/initrd paths & params for your distro (Ubuntu example):\n\
         \x20   linux (loop)/casper/vmlinuz boot=casper iso-scan/filename={iso_rel} quiet splash\n\
         \x20   initrd (loop)/casper/initrd\n\
         }}\n"
    )
}

/// Buffered chunk copy with MB progress on the console. Returns the
/// SHA-256 of the bytes written (computed while copying - the source does
/// not need to be read a second time for verification).
/// Open for a single sequential hashing pass: FILE_FLAG_SEQUENTIAL_SCAN
/// tells the cache manager to readahead aggressively instead of thrashing
/// the standby list - the win on USB/slow media is real. Falls back to a
/// plain open where the flag is unavailable (Win9x's CreateFileW stub).
fn open_sequential_read(path: &str) -> std::io::Result<std::fs::File> {
    use std::os::windows::io::FromRawHandle;
    use winapi::um::fileapi::{CreateFileW, OPEN_EXISTING};
    use winapi::um::winbase::FILE_FLAG_SEQUENTIAL_SCAN;
    use winapi::um::winnt::{FILE_SHARE_READ, FILE_SHARE_WRITE, GENERIC_READ};
    let w = sys::wide(path);
    let h = unsafe {
        CreateFileW(
            w.as_ptr(),
            GENERIC_READ,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            std::ptr::null_mut(),
            OPEN_EXISTING,
            FILE_FLAG_SEQUENTIAL_SCAN,
            std::ptr::null_mut(),
        )
    };
    if h as isize == -1 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(unsafe { std::fs::File::from_raw_handle(h as *mut _) })
}

fn open_for_hash(path: &str, what: &str) -> Result<std::fs::File, String> {
    open_sequential_read(path)
        .or_else(|_| std::fs::File::open(path))
        .map_err(|e| format!("open {}: {}", what, e))
}

/// Copy the ISO to the stick with live speed/progress reporting.  Returns
/// (SHA-256 of source, write metrics).
fn copy_file_progress(
    src: &str,
    dst: &str,
    ui: Option<&dyn WriteUi>,
) -> Result<(String, WriteMetrics), String> {
    let mut r = open_for_hash(src, src)?;
    let total = r.metadata().map(|m| m.len()).unwrap_or(0);
    let mut w = std::io::BufWriter::with_capacity(
        4 << 20,
        std::fs::File::create(dst).map_err(|e| format!("create {}: {}", dst, e))?,
    );
    let mut h = Sha256::new();
    let mut buf = vec![0u8; 4 << 20];
    let mut done: u64 = 0;
    let t0 = std::time::Instant::now();
    let mut last_ui = std::time::Instant::now();

    if let Some(u) = ui {
        u.set_progress(0, total);
        u.set_status(&format!(
            "Writing ISO to USB... 0 / {:.0} MB",
            total as f64 / sys::MB as f64
        ));
        u.pump();
    }

    loop {
        let n = r.read(&mut buf).map_err(|e| format!("read {}: {}", src, e))?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
        w.write_all(&buf[..n]).map_err(|e| format!("write {}: {}", dst, e))?;
        done += n as u64;

        if last_ui.elapsed().as_millis() >= 300 {
            let elapsed = t0.elapsed().as_secs_f64().max(0.001);
            let mbps = (done as f64 / sys::MB as f64) / elapsed;
            if let Some(u) = ui {
                u.set_progress(done, total);
                u.set_status(&format!(
                    "Writing ISO to USB... {:.0} / {:.0} MB  ({:.1} MB/s)",
                    done as f64 / sys::MB as f64,
                    total as f64 / sys::MB as f64,
                    mbps
                ));
                u.pump();
            }
            last_ui = std::time::Instant::now();
        }
    }
    w.flush().map_err(|e| format!("flush {}: {}", dst, e))?;
    w.get_ref().sync_all().ok();

    let write_seconds = t0.elapsed().as_secs_f64();
    let write_mbps = (done as f64 / sys::MB as f64) / write_seconds.max(0.001);
    let hash = format!("{:x}", h.finalize());

    out::info(&format!(
        "  copied {:.1} GB in {:.1}s ({:.1} MB/s)",
        done as f64 / sys::GB as f64,
        write_seconds,
        write_mbps
    ));

    if let Some(u) = ui {
        u.set_status(&format!(
            "Write complete: {:.1} GB in {:.1}s ({:.1} MB/s). Dropping cache and verifying...",
            done as f64 / sys::GB as f64,
            write_seconds,
            write_mbps
        ));
        u.pump();
    }

    Ok((
        hash,
        WriteMetrics {
            bytes_copied: done,
            write_seconds,
            write_mbps,
            ..Default::default()
        },
    ))
}

/// Flush the volume caches, then read the file back computing SHA-256 with
/// live progress so the user sees the verification read speed.
fn verify_file_progress(
    path: &str,
    expected_hash: &str,
    ui: Option<&dyn WriteUi>,
) -> Result<WriteMetrics, String> {
    // Drop cache: flush the volume before reopening for read.
    if let Some(letter) = path.chars().next() {
        let vol = format!(r"\\.\{}:", letter);
        if let Ok(v) = std::fs::OpenOptions::new().write(true).open(&vol) {
            let _ = v.sync_all();
        }
    }

    let mut f = open_for_hash(path, path)?;
    let total = f.metadata().map(|m| m.len()).unwrap_or(0);
    let mut h = Sha256::new();
    let mut buf = vec![0u8; 4 << 20];
    let mut done: u64 = 0;
    let t0 = std::time::Instant::now();
    let mut last_ui = std::time::Instant::now();

    if let Some(u) = ui {
        u.set_progress(0, total);
        u.set_status("Verifying USB write (cache dropped, reading back)...");
        u.pump();
    }
    // CPU share of the pipeline, measured live: lets the status report the
    // disk's own speed instead of only the hash-bound combined rate.
    let hash_mbps = calibrate_hash_mbps();

    loop {
        let n = f.read(&mut buf).map_err(|e| format!("read {}: {}", path, e))?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
        done += n as u64;

        if last_ui.elapsed().as_millis() >= 300 {
            let elapsed = t0.elapsed().as_secs_f64().max(0.001);
            let mbps = (done as f64 / sys::MB as f64) / elapsed;
            let est = estimate_disk_mbps(mbps, hash_mbps)
                .map(|r| format!(", disk ~{:.0} MB/s", r))
                .unwrap_or_default();
            if let Some(u) = ui {
                u.set_progress(done, total);
                u.set_status(&format!(
                    "Verifying USB write... {:.0} / {:.0} MB  ({:.1} MB/s{})",
                    done as f64 / sys::MB as f64,
                    total as f64 / sys::MB as f64,
                    mbps,
                    est
                ));
                u.pump();
            }
            last_ui = std::time::Instant::now();
        }
    }
    drop(f);

    let verify_seconds = t0.elapsed().as_secs_f64();
    let verify_mbps = (done as f64 / sys::MB as f64) / verify_seconds.max(0.001);
    let hash = format!("{:x}", h.finalize());

    if hash != expected_hash {
        return Err(format!(
            "the ISO copy on {} is CORRUPT (SHA-256 mismatch, stick copy {} != source {}).\n  \
             The bad copy was deleted - check the stick (try a different port/cable), then re-run.",
            path,
            &hash[..16.min(hash.len())],
            &expected_hash[..16.min(expected_hash.len())]
        ));
    }

    let disk_est = estimate_disk_mbps(verify_mbps, hash_mbps);
    let disk_str = disk_est
        .map(|r| format!(", disk est. ~{:.0} MB/s", r))
        .unwrap_or_default();

    out::info(&format!(
        "  verified: {:.1} GB in {:.1}s ({:.1} MB/s{})",
        done as f64 / sys::GB as f64,
        verify_seconds,
        verify_mbps,
        disk_str
    ));

    if let Some(u) = ui {
        u.set_status(&format!(
            "Verification complete: {:.1} GB in {:.1}s ({:.1} MB/s{})",
            done as f64 / sys::GB as f64,
            verify_seconds,
            verify_mbps,
            disk_str
        ));
        u.pump();
    }

    Ok(WriteMetrics {
        bytes_verified: done,
        verify_seconds,
        verify_mbps,
        verify_disk_est_mbps: disk_est.unwrap_or(0.0),
        ..Default::default()
    })
}

/// Copy when needed, then flush cache and verify.  Returns (source hash, metrics).
fn copy_and_verify_iso(
    iso: &str,
    iso_dst: &str,
    iso_len: u64,
    ui: Option<&dyn WriteUi>,
) -> Result<(String, WriteMetrics), String> {
    // The Install handler hid the progress bar/label; re-show them so the
    // live write/verify speed has a bar to go with it. show_final hides
    // them again for the summary page.
    if let Some(u) = ui {
        u.show_progress(true);
    }
    let mut metrics = WriteMetrics::default();
    let mut src_hash: Option<String> = None;
    match sys::file_size(iso_dst) {
        Some(sz) if sz == iso_len => {
            out::info(&format!(
                "ISO already on stick: {} (same size; verifying before reuse)",
                iso_dst
            ));
            let dst = crate::lslfiles::sha256_file(iso_dst)
                .ok_or_else(|| format!("cannot hash {} for verification", iso_dst))?;
            src_hash = Some(
                crate::lslfiles::sha256_file(iso)
                    .ok_or_else(|| format!("cannot hash {} for verification", iso))?,
            );
            if dst == src_hash.clone().unwrap() {
                out::info("  existing copy verified (SHA-256 matches the source).");
            } else {
                out::warn("  existing copy is CORRUPT (SHA-256 mismatch) - re-copying from the source.");
                sys::delete_file(iso_dst);
                src_hash = None;
            }
        }
        _ => {}
    }
    if src_hash.is_none() {
        out::step(&format!(
            "Copying the ISO onto {}: (files only, no formatting)...",
            iso_dst
        ));
        let (hash, m) = copy_file_progress(iso, iso_dst, ui)?;
        src_hash = Some(hash);
        metrics.bytes_copied = m.bytes_copied;
        metrics.write_seconds = m.write_seconds;
        metrics.write_mbps = m.write_mbps;
    }
    let src = src_hash.unwrap();
    let verify = verify_file_progress(iso_dst, &src, ui)?;
    metrics.bytes_verified = verify.bytes_verified;
    metrics.verify_seconds = verify.verify_seconds;
    metrics.verify_mbps = verify.verify_mbps;
    Ok((src, metrics))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn valid_mbr() -> [u8; 512] {
        let mut m = [0u8; 512];
        m[446 + 4] = 0x0B; // one FAT32 partition entry
        m[510] = 0x55;
        m[511] = 0xAA;
        m
    }

    #[test]
    fn assets_match_pinned_hashes() {
        verify_assets().unwrap();
        assert!(grldr().len() > 100_000);
        // the shipped blob must stay compressed (catches an accidental
        // raw check-in): advdef output is ~55% of the 332181-byte loader.
        assert!(GRLDR_GZ.len() * 4 < grldr().len() * 3);
        assert!(GRLDR_MBR.len() >= MBR_CODE_END);
    }

    #[test]
    fn boot_area_checks() {
        let mut head = vec![0u8; 1024];
        head[510] = 0x55;
        head[511] = 0xAA;
        head[446 + 4] = 0x0C;
        assert!(check_boot_area(&head).is_ok());
        // missing signature
        let mut bad = head.clone();
        bad[510] = 0;
        assert!(check_boot_area(&bad).is_err());
        // true GPT: EFI magic + protective 0xEE entry
        let mut gpt = head.clone();
        gpt[512..520].copy_from_slice(b"EFI PART");
        gpt[446 + 4] = 0xEE;
        let err = check_boot_area(&gpt).unwrap_err();
        assert!(err.contains("GPT"), "unexpected: {err}");
        // stale GPT header on an otherwise-MBR stick (converted GPT->MBR
        // without wiping LBA1): must be accepted as MBR
        let mut stale = head.clone();
        stale[512..520].copy_from_slice(b"EFI PART");
        assert!(check_boot_area(&stale).is_ok());
        // is_gpt mirrors the same rule
        assert!(is_gpt(&gpt));
        assert!(!is_gpt(&stale));
        assert!(!is_gpt(&head));
        // superfloppy
        let mut sf = head.clone();
        sf[446 + 4] = 0;
        assert!(check_boot_area(&sf).is_err());
    }

    #[test]
    fn mbr_merge_keeps_partition_table_and_signature() {
        let mut orig = valid_mbr();
        // nonzero disk signature + reserved, as Windows writes them
        orig[440..446].copy_from_slice(&[0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x00]);
        for i in 446..510 {
            orig[i] = (i % 251) as u8; // distinct partition-table bytes
        }
        let (new_mbr, changed) = merged_mbr(&orig);
        assert!(changed, "stock MBR must differ from grub4dos boot code");
        // signature + reserved + partition table + 55AA all preserved...
        assert_eq!(&new_mbr[440..446], &orig[440..446]);
        assert_eq!(&new_mbr[446..510], &orig[446..510]);
        assert_eq!(new_mbr[510], 0x55);
        assert_eq!(new_mbr[511], 0xAA);
        // ...only the 440 boot-code bytes come from the template
        assert_eq!(&new_mbr[..440], &GRLDR_MBR[..440]);
        // idempotent: merging again changes nothing
        let (again, changed2) = merged_mbr(&new_mbr);
        assert!(!changed2);
        assert_eq!(again, new_mbr);
    }

    #[test]
    fn menu_lst_upsert_is_idempotent() {
        let entry = menu_entry("Mint (loopback ISO)", "/_ISO/mint.iso");
        assert!(entry.contains("map /_ISO/mint.iso (0xff)"));
        assert!(entry.contains("chainloader (0xff)"));
        let (m1, added1) = upsert_menu(&default_menu(), "Mint (loopback ISO)", &entry);
        assert!(added1);
        assert_eq!(m1.matches("title Mint (loopback ISO)").count(), 1);
        let (m2, added2) = upsert_menu(&m1, "Mint (loopback ISO)", &entry);
        assert!(!added2);
        assert_eq!(m2, m1);
        // a different ISO gets its own entry
        let (m3, added3) = upsert_menu(&m2, "Debian (loopback ISO)", &menu_entry("Debian (loopback ISO)", "/_ISO/debian.iso"));
        assert!(added3);
        // count only REAL title lines (the default menu's commented examples
        // contain "title " too and must not be counted)
        assert_eq!(
            m3.lines()
                .filter(|l| l.trim_start().starts_with("title "))
                .count(),
            2
        );
    }

    #[test]
    fn iso_name_sanitized() {
        assert_eq!(sanitize_iso_name("linux mint 22.iso"), "linux_mint_22.iso");
    }

    #[test]
    fn stage1_continuation_is_15_sectors() {
        // the grub4dos stage1 is 8192 bytes = 16 sectors; the BIOS loads only
        // sector 0, so sectors 1..15 must carry the rest or the stick is not
        // bootable ("Missing helper").
        let cont = stage1_continuation();
        assert_eq!(cont.len(), 15 * 512);
        assert_eq!(cont, &GRLDR_MBR[512..]);
        // and the MBR part is exactly the boot-code area
        assert_eq!(&GRLDR_MBR[..MBR_CODE_END].len(), &MBR_CODE_END);
    }

    #[test]
    fn first_partition_lba_parses() {
        let mut m = valid_mbr();
        // entry 0: type 0x0B, start LBA 2048
        m[446 + 4] = 0x0B;
        m[446 + 8..446 + 12].copy_from_slice(&2048u32.to_le_bytes());
        assert_eq!(first_partition_lba(&m), Some(2048));
        // a second, earlier partition wins (min)
        m[446 + 16 + 4] = 0x0C;
        m[446 + 16 + 8..446 + 16 + 12].copy_from_slice(&63u32.to_le_bytes());
        assert_eq!(first_partition_lba(&m), Some(63));
        // no used entries -> None
        let mut empty = valid_mbr();
        for i in 0..4usize {
            empty[446 + 16 * i + 4] = 0;
        }
        assert_eq!(first_partition_lba(&empty), None);
    }

    #[test]
    fn active_partition_finds_boot_flag() {
        let mut m = valid_mbr();
        // entry 0: boot flag 0x80, type 0x0C, start LBA 2048
        m[446] = 0x80;
        m[446 + 4] = 0x0C;
        m[446 + 8..446 + 12].copy_from_slice(&2048u32.to_le_bytes());
        assert_eq!(active_partition(&m), Some((2048, 0x0C)));
        // no boot flag anywhere -> None
        let mut none = valid_mbr();
        for i in 0..4usize {
            none[446 + 16 * i] = 0;
        }
        assert_eq!(active_partition(&none), None);
        // a later entry with the flag wins
        let mut later = valid_mbr();
        later[446 + 16 + 0] = 0x80;
        later[446 + 16 + 4] = 0x0B;
        later[446 + 16 + 8..446 + 16 + 12].copy_from_slice(&63u32.to_le_bytes());
        assert_eq!(active_partition(&later), Some((63, 0x0B)));
    }

    #[test]
    fn extended_partition_types_flagged() {
        assert!(is_extended_type(0x05));
        assert!(is_extended_type(0x0F));
        assert!(is_extended_type(0x85));
        assert!(!is_extended_type(0x0B)); // FAT32
        assert!(!is_extended_type(0x0C)); // FAT32 LBA
        assert!(!is_extended_type(0x07)); // NTFS
    }

    fn caps(booted_uefi: bool, uefi: sys::FwCap, bios: sys::FwCap) -> sys::BoardCaps {
        sys::BoardCaps {
            booted_uefi,
            uefi_capable: uefi,
            bios_capable: bios,
            detail: String::new(),
        }
    }

    #[test]
    fn board_warnings_matrix() {
        use sys::FwCap::*;
        // legacy-only board, UEFI requested -> hard warning
        let c = caps(false, No, Yes);
        let w = board_warnings(true, true, &c);
        assert!(w.iter().any(|(hard, m)| *hard && m.contains("legacy-only")));
        // legacy boot, UEFI-only stick -> hard warning
        let w = board_warnings(false, true, &c);
        assert!(w.iter().any(|(hard, _)| *hard));
        // legacy boot, BIOS included -> no warnings at all
        assert!(board_warnings(true, false, &c).is_empty());
        // UEFI boot, CSM unknown, BIOS included -> soft note only
        let c = caps(true, Yes, Unknown);
        let w = board_warnings(true, true, &c);
        assert!(!w.iter().any(|(hard, _)| *hard));
        assert!(w.iter().any(|(hard, m)| !hard && m.contains("CSM")));
        // UEFI boot, UEFI-only stick -> clean
        assert!(board_warnings(false, true, &c).is_empty());
        // UEFI boot, BIOS-only stick -> soft note (needs CSM here)
        let w = board_warnings(true, false, &c);
        assert!(!w.iter().any(|(hard, _)| *hard));
        assert!(!w.is_empty());
        // everything on a fully capable box -> clean
        let c = caps(true, Yes, Yes);
        assert!(board_warnings(true, true, &c).is_empty());
    }

    #[test]
    fn board_note_short_flags_hard_conflicts() {
        use sys::FwCap::*;
        let c = caps(false, No, Yes);
        assert!(board_note_short(true, true, &c).contains("WARNING"));
        assert!(!board_note_short(true, false, &c).contains("WARNING"));
    }

    #[test]
    fn bus_type_names() {
        assert_eq!(bus_name(0x07), "USB");
        assert_eq!(bus_name(0x0B), "SATA");
    }

    #[test]
    fn unknown_bus_is_not_a_refusal() {
        // BusTypeUnknown carries no information: it must fold to None
        // (unknown -> included for removable) rather than Some(false),
        // which would refuse cheap flash sticks as "not USB".
        assert_eq!(bus_is_usb_tri(0x00), None);
        assert_eq!(bus_is_usb_tri(0x07), Some(true));
        assert_eq!(bus_is_usb_tri(0x0B), Some(false));
        assert_eq!(bus_is_usb_tri(0xFF), Some(false));
    }

    #[test]
    fn disk_estimate_decomposes_serial_pipeline() {
        // 50 MB/s combined with a 117 MB/s hasher: 50*117/67 ≈ 87.3.
        let r = estimate_disk_mbps(50.0, 117.0).unwrap();
        assert!((r - 87.3).abs() < 0.5, "got {}", r);
        // Fully hash-bound (or noise): no number, report lower bound instead.
        assert_eq!(estimate_disk_mbps(115.0, 117.0), None);
        assert_eq!(estimate_disk_mbps(120.0, 117.0), None);
        assert_eq!(estimate_disk_mbps(50.0, 55.0), None);
        assert_eq!(estimate_disk_mbps(0.0, 117.0), None);
        assert_eq!(estimate_disk_mbps(50.0, 0.0), None);
        // Calibration returns something sane and positive on any machine.
        assert!(calibrate_hash_mbps() > 1.0);
    }

    #[test]
    fn vendored_uefi_loader_is_bootable_pe() {
        // assets/BOOTX64.EFI must be present and embedded: without it the
        // GUI UEFI checkbox greys out and FAT sticks lose UEFI boot.
        let data = bundled_uefi().expect("assets/BOOTX64.EFI missing from the build");
        assert!(data.len() > 100_000, "suspiciously small loader: {}", data.len());
        // DOS header + PE32+ x86-64 EFI application (subsystem 10).
        assert_eq!(&data[0..2], b"MZ");
        let pe = u32::from_le_bytes(data[0x3C..0x40].try_into().unwrap()) as usize;
        assert_eq!(&data[pe..pe + 4], b"PE\0\0");
        assert_eq!(u16::from_le_bytes(data[pe + 4..pe + 6].try_into().unwrap()), 0x8664);
        assert_eq!(u16::from_le_bytes(data[pe + 24..pe + 26].try_into().unwrap()), 0x020B);
        assert_eq!(u16::from_le_bytes(data[pe + 92..pe + 94].try_into().unwrap()), 10);
        // pinned hash must match what build.rs embedded (refuses at runtime
        // otherwise, which would silently disable UEFI).
        assert_eq!(sha256_hex(data), BUNDLED_BOOTX64_SHA256.unwrap().to_lowercase());
        assert_eq!(uefi_source_name(""), Some("vendored BOOTX64.EFI"));
    }
}
