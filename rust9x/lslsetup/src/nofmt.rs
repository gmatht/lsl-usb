//! Non-destructive "no-reformat" live-USB install (YUMI/Easy2Boot-style).
//!
//! Instead of DD-ing the ISO over the stick (Rufus), this mode:
//!   1. writes grub4dos boot code into the MBR *boot-code area only*
//!      (bytes 0..446) - partition table (446..510), disk signature and
//!      0x55AA signature (510..512) are preserved;
//!   2. writes the grub4dos stage1 *continuation* into sectors 1..15. The
//!      stage1 (assets/grldr.mbr) is 8192 bytes = 16 sectors; the BIOS loads
//!      only sector 0, and the stage1 then reads sectors 1..15 to load the
//!      rest of itself (its FAT/NTFS/ISO reading code). Without them it dies
//!      with "Missing helper" and the stick is NOT bootable (verified by
//!      tests/qemu-boot-test.sh);
//!   3. copies `grldr` (grub4dos loader, must be in the volume root) plus
//!      the ISO *as a regular file* onto the stick;
//!   4. generates/appends a `menu.lst` that loopback-maps the ISO and
//!      chainloads the ISO's own bootloader.
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
//!     table, and must not be GPT;
//!   - the first 64 sectors are backed up before the write and verified
//!     by read-back afterwards;
//!   - Win9x is refused (needs the \\.\PhysicalDriveN NT device namespace).
//!
//! The grub4dos 0.4.6a binaries are embedded (assets/, GPL-2, see
//! assets/COPYING) and verified against pinned SHA-256 hashes at startup.

use crate::sys::{self, out};
use sha2::{Digest, Sha256};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::windows::io::AsRawHandle;

const GRLDR: &[u8] = include_bytes!("../assets/grldr");
const GRLDR_MBR: &[u8] = include_bytes!("../assets/grldr.mbr");
const GRLDR_SHA256: &str = "dece3f8d20f84ae0d0fb892b5c3a2d19e7233d0d8885b0027a6f43d77239128d";
const GRLDR_MBR_SHA256: &str = "f5c6e8e2c1eb7380285fa9cb1c9168e92d5b3b55cde052c043ba81ed17b9acef";

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
pub fn check_boot_area(head: &[u8]) -> Result<(), String> {
    if head.len() < 1024 {
        return Err("could not read the first two sectors of the target".into());
    }
    if head[510] != 0x55 || head[511] != 0xAA {
        return Err("no MBR 0x55AA signature on the target - refusing to continue".into());
    }
    if &head[512..520] == b"EFI PART" {
        return Err(
            "target is GPT-partitioned; the no-reformat method needs an MBR (msdos) partitioned stick"
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

/// Overlay the grub4dos boot code onto the existing MBR: bytes 0..446 are
/// replaced, everything else (signature, partition table) is kept.
/// Returns (new MBR, whether anything changed).
pub fn merged_mbr(mbr: &[u8; 512]) -> ([u8; 512], bool) {
    if mbr[510] != 0x55 || mbr[511] != 0xAA {
        // caller validated already; be defensive and leave it alone
        return (*mbr, false);
    }
    let mut new_mbr = *mbr;
    let n = GRLDR_MBR.len().min(MBR_CODE_END);
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
    /// Some(true/false) = bus query answered, None = query unsupported.
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
            Some((b, _)) => Some(b == 0x07),
            None => match device_property(&format!(r"\\.\PhysicalDrive{}", phys)) {
                Some((b, _)) => Some(b == 0x07),
                None => None,
            },
        };
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
                        bus_is_usb: Some(bus == "USB"),
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
        ("grldr", GRLDR, GRLDR_SHA256),
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
/// no formatting either way.
pub fn install_from_iso(
    iso: &str,
    letter_hint: &str,
    allow_fixed: bool,
    uefi_bootx64: &str,
) -> Result<UsbTarget, String> {
    let target = choose_target(letter_hint, allow_fixed)?;

    out::step("Non-destructive write (no reformat):");
    out::info(&format!("  target: {}", target.describe()));
    out::info(&format!("  iso   : {}", iso));
    out::info("  plan  : write grub4dos boot code into MBR bytes 0..446 ONLY (partition table kept),");
    out::info("          copy grldr + the ISO as a regular file, generate menu.lst (loopback boot).");
    out::info("          Nothing is formatted; existing files are not modified or deleted.");

    let (uefi, _sb) = sys::firmware();
    if uefi {
        out::warn("This machine booted in UEFI mode. The grub4dos path boots via BIOS/CSM;");
        out::info("enable 'Legacy/CSM boot' for USB in the firmware, or supply --uefi-bootx64.");
    }

    // Final typed confirmation: the user must name the drive to be touched.
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

    install_on_target(&target, iso, uefi_bootx64)?;
    Ok(target)
}

fn install_on_target(t: &UsbTarget, iso: &str, uefi_bootx64: &str) -> Result<(), String> {
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
    // (bytes 0..446, partition table preserved) AND its continuation into
    // sectors 1..15. The stage1 is 8192 bytes = 16 sectors; the BIOS loads
    // only sector 0, and the stage1 then reads sectors 1..15 to load the
    // rest of itself - without them it dies with "Missing helper" and the
    // stick is NOT bootable. ----
    let mbr: [u8; 512] = head[..512].try_into().unwrap();
    // the continuation must not clobber the first partition
    if let Some(first) = first_partition_lba(&mbr) {
        if first <= 15 {
            return Err(format!(
                "the first partition starts at sector {} - the grub4dos stage1 needs sectors 1..15 for its continuation. Repartition the stick so the first partition starts after sector 15, or use the Rufus flow.",
                first
            ));
        }
    }
    let (new_mbr, mbr_changed) = merged_mbr(&mbr);
    let cont = stage1_continuation();
    let cont_changed = &head[512..512 + cont.len()] != cont;
    if mbr_changed || cont_changed {
        disk.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
        disk.write_all(&new_mbr).map_err(|e| format!("MBR write failed: {}", e))?;
        disk.seek(SeekFrom::Start(512)).map_err(|e| e.to_string())?;
        disk.write_all(cont).map_err(|e| format!("grub4dos stage1 continuation write failed: {}", e))?;
        disk.sync_all().map_err(|e| format!("MBR flush failed: {}", e))?;
        // read back + verify
        let mut back = vec![0u8; 512 + cont.len()];
        disk.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
        disk.read_exact(&mut back).map_err(|e| e.to_string())?;
        if back[..512] != new_mbr[..] {
            return Err(format!(
                "MBR read-back mismatch - the write did not stick. Restore with the backup at {}",
                backup_path
            ));
        }
        if &back[512..] != cont {
            return Err(format!(
                "grub4dos stage1 continuation read-back mismatch - the write did not stick. Restore with the backup at {}",
                backup_path
            ));
        }
        if &back[446..510] != &mbr[446..510] {
            return Err("partition table changed during the MBR write - aborting.".into());
        }
        out::info("grub4dos boot code written to the MBR + stage1 continuation (sectors 1-15); partition table preserved.");
    } else {
        out::info("grub4dos boot code already present - MBR untouched.");
    }

    // ---- from here on it is plain file I/O on the mounted volume ----
    let root = format!("{}\\", t.letter);

    // grldr must be in the volume root.
    let grldr_path = format!("{}grldr", root);
    if sys::path_exists(&grldr_path) {
        match std::fs::read(&grldr_path) {
            Ok(old) if old == GRLDR => out::info("grldr already present and up to date."),
            Ok(_) => {
                out::warn(&format!("{} already exists with different content.", grldr_path));
                let ans = out::prompt("Overwrite it with the bundled grub4dos grldr? Type OK to overwrite, Enter to abort: ");
                if ans != "OK" {
                    return Err("aborted - existing grldr left untouched.".into());
                }
                std::fs::write(&grldr_path, GRLDR).map_err(|e| format!("copy grldr: {}", e))?;
                out::info("grldr overwritten (bundled grub4dos 0.4.6a).");
            }
            Err(e) => return Err(format!("cannot read existing grldr: {}", e)),
        }
    } else {
        std::fs::write(&grldr_path, GRLDR).map_err(|e| format!("copy grldr: {}", e))?;
        out::info("grldr written to the volume root.");
    }

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
    let mut src_hash: Option<String> = None;
    match sys::file_size(&iso_dst) {
        Some(sz) if sz == iso_len => {
            out::info(&format!(
                "ISO already on stick: {} (same size; verifying before reuse)",
                iso_dst
            ));
            let dst = crate::lslfiles::sha256_file(&iso_dst)
                .ok_or_else(|| format!("cannot hash {} for verification", iso_dst))?;
            src_hash = Some(
                crate::lslfiles::sha256_file(iso)
                    .ok_or_else(|| format!("cannot hash {} for verification", iso))?,
            );
            if dst == src_hash.clone().unwrap() {
                out::info("  existing copy verified (SHA-256 matches the source)." );
            } else {
                out::warn("  existing copy is CORRUPT (SHA-256 mismatch) - re-copying from the source.");
                sys::delete_file(&iso_dst);
                src_hash = None; // fall through to the copy path below
            }
        }
        _ => {}
    }
    if src_hash.is_none() {
        out::step(&format!(
            "Copying the ISO onto {}: (files only, no formatting)...",
            t.letter
        ));
        src_hash = Some(copy_file_progress(iso, &iso_dst)?);
    }
    // Read the written file back and compare hashes: catches silent USB
    // write corruption before the user ever tries to boot it.
    let src = src_hash.unwrap();
    out::step("Verifying the ISO copy on the stick (SHA-256)...");
    let dst = crate::lslfiles::sha256_file(&iso_dst)
        .ok_or_else(|| format!("cannot hash {} for verification", iso_dst))?;
    if dst != src {
        sys::delete_file(&iso_dst);
        return Err(format!(
            "the ISO copy on {}: is CORRUPT (SHA-256 mismatch, stick copy {} != source {}).\n  \
             The bad copy was deleted - check the stick (try a different port/cable), then re-run.",
            t.letter,
            &dst[..16.min(dst.len())],
            &src[..16.min(src.len())]
        ));
    }
    out::info("  verified: the stick copy matches the source byte for byte.");

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

    // Optional UEFI side-load (files only; FAT32 stick, Secure Boot off).
    if !uefi_bootx64.is_empty() {
        if !sys::path_exists(uefi_bootx64) {
            out::warn(&format!("--uefi-bootx64 not found: {} (UEFI files skipped)", uefi_bootx64));
        } else {
            let bootdir = format!("{}EFI\\BOOT", root);
            sys::create_dir_all(&bootdir);
            sys::copy_file(uefi_bootx64, &format!("{}\\BOOTX64.EFI", bootdir))
                .map_err(|e| format!("copy BOOTX64.EFI: {}", e))?;
            std::fs::write(format!("{}\\grub.cfg", bootdir), uefi_cfg(&title, &iso_rel))
                .map_err(|e| format!("write grub.cfg: {}", e))?;
            out::info("UEFI: BOOTX64.EFI + grub.cfg installed (no formatting).");
        }
    }

    // Flush the volume.
    if let Ok(v) = std::fs::OpenOptions::new()
        .write(true)
        .open(format!(r"\\.\{}:", t.letter))
    {
        let _ = v.sync_all();
    }

    out::step("Done - nothing was formatted; existing files were untouched.");
    out::info("Safely eject the stick, then boot from it via the firmware boot menu.");
    out::info("The grub4dos menu boots the ISO via loopback (BIOS/CSM firmware needed).");
    out::info(&format!(
        "If anything goes wrong, restore the original MBR with the backup at {}",
        backup_path
    ));
    Ok(())
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
fn copy_file_progress(src: &str, dst: &str) -> Result<String, String> {
    let mut r = std::fs::File::open(src).map_err(|e| format!("open {}: {}", src, e))?;
    let total = r.metadata().map(|m| m.len()).unwrap_or(0);
    let mut w = std::io::BufWriter::with_capacity(
        4 << 20,
        std::fs::File::create(dst).map_err(|e| format!("create {}: {}", dst, e))?,
    );
    let mut h = Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    let mut done: u64 = 0;
    let t0 = std::time::Instant::now();
    let mut last = std::time::Instant::now();
    loop {
        let n = r.read(&mut buf).map_err(|e| format!("read {}: {}", src, e))?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
        w.write_all(&buf[..n]).map_err(|e| format!("write {}: {}", dst, e))?;
        done += n as u64;
        if last.elapsed().as_secs() >= 2 {
            out::info(&format!(
                "  {:>6.0} / {:.0} MB",
                done as f64 / sys::MB as f64,
                total as f64 / sys::MB as f64
            ));
            last = std::time::Instant::now();
        }
    }
    w.flush().map_err(|e| format!("flush {}: {}", dst, e))?;
    w.get_ref().sync_all().ok();
    out::info(&format!(
        "  copied {:.1} GB in {:.0}s",
        done as f64 / sys::GB as f64,
        t0.elapsed().as_secs_f32()
    ));
    Ok(format!("{:x}", h.finalize()))
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
        assert!(GRLDR.len() > 100_000);
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
        // GPT
        let mut gpt = head.clone();
        gpt[512..520].copy_from_slice(b"EFI PART");
        assert!(check_boot_area(&gpt).is_err());
        // superfloppy
        let mut sf = head.clone();
        sf[446 + 4] = 0;
        assert!(check_boot_area(&sf).is_err());
    }

    #[test]
    fn mbr_merge_keeps_partition_table_and_signature() {
        let mut orig = valid_mbr();
        for i in 446..510 {
            orig[i] = (i % 251) as u8; // distinct partition-table bytes
        }
        let (new_mbr, changed) = merged_mbr(&orig);
        assert!(changed, "stock MBR must differ from grub4dos boot code");
        assert_eq!(&new_mbr[446..510], &orig[446..510]);
        assert_eq!(new_mbr[510], 0x55);
        assert_eq!(new_mbr[511], 0xAA);
        assert_eq!(&new_mbr[..446], &GRLDR_MBR[..446]);
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

    #[test]
    fn bus_type_names() {
        assert_eq!(bus_name(0x07), "USB");
        assert_eq!(bus_name(0x0B), "SATA");
    }
}
