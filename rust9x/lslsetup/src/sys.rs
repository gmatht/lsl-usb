//! Win32 capability layer for lslsetup.
//!
//! Design rule: the binary must LOAD and RUN on Windows 95/98/Me (rust9x).
//! Therefore the set of statically-linked imports is restricted to APIs that
//! exist on Win9x or are provided by unicows.dll. Anything newer (winhttp,
//! wintrust, IsUserAnAdmin, GetFirmwareType, GetFirmwareEnvironmentVariable,
//! SHGetSpecialFolderPath, ...) is resolved at runtime via GetProcAddress and
//! degrades gracefully when absent. See `caps()` for the aggregated report.

#![allow(non_snake_case, clippy::missing_safety_doc)]

use std::ffi::OsString;
use std::os::windows::ffi::OsStrExt;
use std::os::windows::ffi::OsStringExt;
use std::sync::OnceLock;

use winapi::um::fileapi::{
    CreateDirectoryW, FindClose, FindFirstFileW, FindNextFileW,
    GetDiskFreeSpaceExW, GetDriveTypeW, GetFileAttributesW, GetLogicalDriveStringsW, GetTempPathW,
    GetVolumeInformationW,
};
use winapi::um::handleapi::{CloseHandle, INVALID_HANDLE_VALUE};
use winapi::um::libloaderapi::{GetModuleHandleA, GetProcAddress, LoadLibraryA};
use winapi::um::namedpipeapi::CreatePipe;
use winapi::um::processenv::GetStdHandle;
use winapi::um::winbase::STD_OUTPUT_HANDLE;
use winapi::um::processthreadsapi::{
    CreateProcessW, GetExitCodeProcess, GetCurrentProcess, PROCESS_INFORMATION,
    STARTUPINFOW,
};
use winapi::um::synchapi::WaitForSingleObject;
use winapi::um::shellapi::{SEE_MASK_NOCLOSEPROCESS, SHELLEXECUTEINFOW, ShellExecuteA, ShellExecuteExW};
use winapi::um::sysinfoapi::GetVersionExW;
use winapi::um::winbase::{
    CopyFileW, STARTF_USESTDHANDLES,
};
use winapi::shared::minwindef::HKEY;
use winapi::um::winreg::{
    RegCloseKey, RegEnumKeyExW, RegOpenKeyExW, RegQueryValueExW,
    HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE,
};
use winapi::um::winnt::{FILE_ATTRIBUTE_DIRECTORY, HANDLE, REG_SZ};

pub const GB: u64 = 1024 * 1024 * 1024;
pub const MB: u64 = 1024 * 1024;

/// Wide (UTF-16) zero-terminated string.
pub fn wide(s: &str) -> Vec<u16> {
    std::ffi::OsStr::new(s).encode_wide().chain(std::iter::once(0)).collect()
}

pub fn from_wide(buf: &[u16]) -> String {
    let end = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
    OsString::from_wide(&buf[..end]).to_string_lossy().into_owned()
}

/// Decode bytes in the console/OEM codepage (what cmd-line tools emit).
pub fn oem_to_string(bytes: &[u8]) -> String {
    if bytes.is_empty() {
        return String::new();
    }
    unsafe extern "system" {
        fn GetOEMCP() -> u32;
        fn MultiByteToWideChar(
            cp: u32, flags: u32, s: *const u8, slen: i32, w: *mut u16, wlen: i32,
        ) -> i32;
    }
    unsafe {
        let cp = GetOEMCP();
        let need = MultiByteToWideChar(cp, 0, bytes.as_ptr(), bytes.len() as i32, std::ptr::null_mut(), 0);
        if need <= 0 {
            return String::from_utf8_lossy(bytes).into_owned();
        }
        let mut w = vec![0u16; need as usize];
        MultiByteToWideChar(cp, 0, bytes.as_ptr(), bytes.len() as i32, w.as_mut_ptr(), need);
        from_wide(&w)
    }
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------
#[derive(Debug)]
pub enum SysErr {
    Win(u32),
    Msg(String),
}
impl std::fmt::Display for SysErr {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SysErr::Win(e) => write!(f, "Windows error {}", e),
            SysErr::Msg(m) => write!(f, "{}", m),
        }
    }
}
pub type SysResult<T> = Result<T, SysErr>;
pub fn last_err() -> SysErr {
    SysErr::Win(unsafe { winapi::um::errhandlingapi::GetLastError() })
}

// ---------------------------------------------------------------------------
// Dynamic library loader
// ---------------------------------------------------------------------------
pub struct DynLib {
    h: winapi::shared::minwindef::HMODULE,
}
impl DynLib {
    pub fn load(name: &str) -> Option<DynLib> {
        // Win95: LoadLibraryW is a no-op stub; use the ANSI variant.
        let mut a = Vec::with_capacity(name.len() + 1);
        a.extend_from_slice(name.as_bytes());
        a.push(0);
        let h = unsafe { LoadLibraryA(a.as_ptr() as *const i8) };
        if h.is_null() {
            None
        } else {
            Some(DynLib { h })
        }
    }
    pub fn proc(&self, name: &str) -> Option<*const ()> {
        let a = name.as_bytes();
        let mut c = Vec::with_capacity(a.len() + 1);
        c.extend_from_slice(a);
        c.push(0);
        let p = unsafe { GetProcAddress(self.h, c.as_ptr() as *const i8) };
        if p.is_null() {
            None
        } else {
            Some(p as *const ())
        }
    }
}
impl Drop for DynLib {
    fn drop(&mut self) {
        unsafe {
            winapi::um::libloaderapi::FreeLibrary(self.h);
        }
    }
}
// NOTE: do NOT go through Option here — on this target Option<*const ()> is
// an 8-byte tagged layout while Option<fn> is niche-optimized to 4 bytes, so
// transmute_copy would copy the discriminant as the pointer (observed 0x1).
// All F types used with proc_from_module are plain fn pointers, so transmute
// the non-null address directly.
fn trans<F>(p: *const ()) -> F {
    assert!(!p.is_null());
    // Reinterpret the ADDRESS VALUE as the fn pointer F (F is always a plain
    // fn pointer here, i.e. pointer-sized on i686). Must transmute the value
    // itself - GetProcAddress returns the code address, not a pointer to it.
    unsafe { std::mem::transmute_copy::<*const (), F>(&p) }
}

/// Resolve a function from an already-loaded module (kernel32 etc).
pub fn proc_from_module<F>(module: &str, name: &str) -> Option<F> {
    // Win95: GetModuleHandleW is a no-op stub; use the ANSI variant.
    let mut a = Vec::with_capacity(module.len() + 1);
    a.extend_from_slice(module.as_bytes());
    a.push(0);
    let h = unsafe { GetModuleHandleA(a.as_ptr() as *const i8) };
    if h.is_null() {
        return None;
    }
    let a = name.as_bytes();
    let mut c = Vec::with_capacity(a.len() + 1);
    c.extend_from_slice(a);
    c.push(0);
    let p = unsafe { GetProcAddress(h, c.as_ptr() as *const i8) };
    if p.is_null() {
        None
    } else {
        Some(trans(p as *const ()))
    }
}

// ---------------------------------------------------------------------------
// OS family / version
// ---------------------------------------------------------------------------
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
pub enum OsVer {
    Win9x,   // 95/98/Me — no security model, no services as NT knows them
    Nt4,
    Win2000,
    Xp,      // XP / Server 2003
    Vista,   // Vista / 2008
    Win7,
    Win8,    // 8 / 8.1 / 2012
    Win10Plus,
}

static OS_VER: OnceLock<OsVer> = OnceLock::new();
pub fn os_ver() -> OsVer {
    *OS_VER.get_or_init(|| unsafe {
        let mut vi: winapi::um::winnt::OSVERSIONINFOW = std::mem::zeroed();
        vi.dwOSVersionInfoSize = std::mem::size_of::<winapi::um::winnt::OSVERSIONINFOW>() as u32;
        if GetVersionExW(&mut vi) == 0 {
            // Win95: GetVersionExW is a no-op stub; try the ANSI variant.
            return os_ver_ansi();
        }
        let (maj, min) = (vi.dwMajorVersion, vi.dwMinorVersion);
        if vi.dwPlatformId != winapi::um::winnt::VER_PLATFORM_WIN32_NT {
            return OsVer::Win9x;
        }
        match (maj, min) {
            (4, _) => OsVer::Nt4,
            (5, 0) => OsVer::Win2000,
            (5, _) => OsVer::Xp,
            (6, 0) => OsVer::Vista,
            (6, 1) => OsVer::Win7,
            (6, 2) | (6, 3) => OsVer::Win8,
            _ => OsVer::Win10Plus,
        }
    })
}

/// ANSI fallback for os_ver (Win95's GetVersionExW is a no-op stub).
fn os_ver_ansi() -> OsVer {
    use winapi::um::sysinfoapi::GetVersionExA;
    use winapi::um::winnt::OSVERSIONINFOA;
    unsafe {
        let mut vi: OSVERSIONINFOA = std::mem::zeroed();
        vi.dwOSVersionInfoSize = std::mem::size_of::<OSVERSIONINFOA>() as u32;
        if GetVersionExA(&mut vi) == 0 {
            return OsVer::Win10Plus;
        }
        let (maj, min) = (vi.dwMajorVersion, vi.dwMinorVersion);
        if vi.dwPlatformId != winapi::um::winnt::VER_PLATFORM_WIN32_NT {
            return OsVer::Win9x;
        }
        match (maj, min) {
            (4, _) => OsVer::Nt4,
            (5, 0) => OsVer::Win2000,
            (5, _) => OsVer::Xp,
            (6, 0) => OsVer::Vista,
            (6, 1) => OsVer::Win7,
            (6, 2) | (6, 3) => OsVer::Win8,
            _ => OsVer::Win10Plus,
        }
    }
}

pub fn is_9x() -> bool {
    os_ver() == OsVer::Win9x
}

// ---------------------------------------------------------------------------
// Admin check: shell32!IsUserAnAdmin (XP+) -> advapi32 token check (NT) ->
// true on 9x (no ACLs) -> true when undetectable ("Rufus / USB writes fail
// loudly", same policy as install.ps1).
// ---------------------------------------------------------------------------
type IsUserAnAdminFn = unsafe extern "system" fn() -> i32;
type OpenProcessTokenFn =
    unsafe extern "system" fn(*mut c_void, u32, *mut *mut c_void) -> i32;
type GetTokenInformationFn = unsafe extern "system" fn(
    *mut c_void, u32, *mut c_void, u32, *mut u32,
) -> i32;

pub fn is_admin() -> bool {
    if is_9x() {
        return true;
    }
    unsafe {
        if let Some(f) = proc_from_module::<IsUserAnAdminFn>("shell32.dll", "IsUserAnAdmin") {
            if f() != 0 {
                return true;
            }
            return false;
        }
        // XP-less NTs: token membership of the Administrators group.
        type CheckTokenMembershipFn =
            unsafe extern "system" fn(*mut c_void, *mut c_void, *mut i32) -> i32;
        let (open_tok, get_info, check_memb) = (
            proc_from_module::<OpenProcessTokenFn>("advapi32.dll", "OpenProcessToken"),
            proc_from_module::<GetTokenInformationFn>("advapi32.dll", "GetTokenInformation"),
            proc_from_module::<CheckTokenMembershipFn>("advapi32.dll", "CheckTokenMembership"),
        );
        if let (Some(open_tok), Some(get_info), Some(check_memb)) = (open_tok, get_info, check_memb) {
            let mut token: *mut c_void = std::ptr::null_mut();
            if open_tok(GetCurrentProcess() as *mut _, 0x0008, &mut token) != 0 {
                // TokenGroups = 2
                let mut len: u32 = 0;
                get_info(token, 2, std::ptr::null_mut(), 0, &mut len);
                if len > 0 {
                    let mut buf = vec![0u8; len as usize];
                    if get_info(token, 2, buf.as_mut_ptr() as *mut c_void, len, &mut len) != 0 {
                        // Walk TOKEN_GROUPS for the Administrators SID
                        // (S-1-5-32-544). Building the SID manually:
                        // S-1-5-32-544 => 1 subauthority.
                        let mut sid = [0u8; 16];
                        // Revision, SubAuthorityCount
                        sid[0] = 1;
                        sid[1] = 1;
                        // IdentifierAuthority: S-1-5 => 0,0,0,0,0,5
                        sid[2] = 0; sid[3] = 0; sid[4] = 0;
                        sid[5] = 0; sid[6] = 0; sid[7] = 5;
                        // SubAuthority[0] = 32 (BUILTIN)
                        sid[8..12].copy_from_slice(&32u32.to_le_bytes());
                        let mut admin_sid = [0u8; 20];
                        admin_sid[..16].copy_from_slice(&sid);
                        // SubAuthority[1] = 544 (ADMINISTRATORS)
                        admin_sid[16..20].copy_from_slice(&544u32.to_le_bytes());
                        let mut is_member: i32 = 0;
                        let ok = check_memb(
                            std::ptr::null_mut(),
                            admin_sid.as_mut_ptr() as *mut c_void,
                            &mut is_member,
                        );
                        winapi::um::handleapi::CloseHandle(token);
                        if ok != 0 {
                            return is_member != 0;
                        }
                    }
                }
                winapi::um::handleapi::CloseHandle(token);
            }
        }
    }
    true // cannot determine -> proceed; USB writes fail loudly
}

// ---------------------------------------------------------------------------
// Firmware: UEFI + Secure Boot. GetFirmwareType is Win8+; the EFI variable
// query works on XP+ UEFI machines and fails on BIOS/9x -> 'Unknown'.
// ---------------------------------------------------------------------------
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum SecBoot {
    Enabled,
    Disabled,
    Unknown,
}

/// Three-state capability: Yes / No / Unknown (could not be determined).
/// Unknown is honest, not a shrug: e.g. CSM presence on a UEFI-booted box
/// has no reliable API, and the stick may target a different PC anyway.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum FwCap {
    Yes,
    No,
    Unknown,
}

/// What THIS motherboard/firmware can boot (the stick may be built for
/// another PC - callers must say "this machine" explicitly).
#[derive(Clone, Debug)]
pub struct BoardCaps {
    pub booted_uefi: bool,
    /// Board can UEFI-boot.
    pub uefi_capable: FwCap,
    /// Board can legacy/CSM-boot.
    pub bios_capable: FwCap,
    /// Short basis string, e.g. "this boot is UEFI; SMBIOS reports UEFI".
    pub detail: String,
}

/// Does this CPU support 64-bit long mode? (CPUID Fn8000_0001:EDX bit 29,
/// the LM flag.) This is a property of the bare hardware - unlike
/// IsWow64Process it is true even under 32-bit Windows on a 64-bit CPU,
/// which is exactly the case that matters when picking a live-USB image
/// (the USB boots the hardware, not the installed Windows).
/// Pentium+ always has CPUID, matching the i586 baseline.
pub fn cpu_has_long_mode() -> bool {
    #[cfg(target_arch = "x86_64")]
    {
        true // 64-bit build proves long mode
    }
    #[cfg(target_arch = "x86")]
    {
        // __cpuid is safe on recent toolchains; allow(unused_unsafe) keeps
        // older ones (where it is still unsafe) warning-free too.
        #[allow(unused_unsafe)]
        unsafe {
            if std::arch::x86::__cpuid(0x8000_0000).eax < 0x8000_0001 {
                return false; // no extended leaves at all (ancient CPU)
            }
            std::arch::x86::__cpuid(0x8000_0001).edx & (1 << 29) != 0
        }
    }
    #[cfg(not(any(target_arch = "x86", target_arch = "x86_64")))]
    {
        false
    }
}

static BOARD: OnceLock<BoardCaps> = OnceLock::new();
/// Cached board firmware capabilities.
pub fn board_caps() -> &'static BoardCaps {
    BOARD.get_or_init(|| {
        let (booted_uefi, _) = firmware();
        if is_9x() {
            // No firmware APIs: 9x boots legacy by definition.
            return BoardCaps {
                booted_uefi: false,
                uefi_capable: FwCap::No,
                bios_capable: FwCap::Yes,
                detail: "Windows 9x boots legacy BIOS only".into(),
            };
        }
        let smbios = smbios_uefi_supported();
        let (uefi_capable, uefi_why) = if booted_uefi {
            (FwCap::Yes, "this boot is UEFI")
        } else {
            match smbios {
                Some(true) => (FwCap::Yes, "SMBIOS reports UEFI supported (this boot is legacy/CSM)"),
                Some(false) => (FwCap::No, "SMBIOS has no UEFI flag and this boot is legacy (legacy-only board)"),
                None => (FwCap::Unknown, "this boot is legacy; SMBIOS unreadable"),
            }
        };
        // CSM detection has no reliable API: a legacy boot proves BIOS
        // works; a UEFI boot says nothing (CSM is often gone on post-2020
        // boards, but checking needs firmware setup).
        let (bios_capable, bios_why) = if !booted_uefi {
            (FwCap::Yes, "this boot is legacy/BIOS")
        } else {
            (FwCap::Unknown, "this boot is UEFI; CSM/legacy presence unknown (check firmware setup for a CSM/Legacy option)")
        };
        BoardCaps {
            booted_uefi,
            uefi_capable,
            bios_capable,
            detail: format!("{}, {}", uefi_why, bios_why),
        }
    })
}

/// SMBIOS Type 0 "UEFI Specification is supported" flag (Characteristics
/// Extension Byte 2, bit 3). Raw RSMB table via GetSystemFirmwareTable
/// (XP+; needs no privilege). None = unavailable/unparseable/too old.
fn smbios_uefi_supported() -> Option<bool> {
    type GetTableFn = unsafe extern "system" fn(u32, u32, *mut u8, u32) -> u32;
    let f = proc_from_module::<GetTableFn>("kernel32.dll", "GetSystemFirmwareTable")?;
    const RSMB: u32 = 0x52534D42;
    let need = unsafe { f(RSMB, 0, std::ptr::null_mut(), 0) };
    if need == 0 || need > 256 * 1024 {
        return None;
    }
    let mut buf = vec![0u8; need as usize];
    let got = unsafe { f(RSMB, 0, buf.as_mut_ptr(), need) };
    if got == 0 || got > need {
        return None;
    }
    buf.truncate(got as usize);
    smbios_uefi_flag(&buf)
}

/// Scan a raw SMBIOS table for a Type 0 structure with a long enough
/// formatted area; return its UEFI-supported bit. Pure (unit-tested).
fn smbios_uefi_flag(table: &[u8]) -> Option<bool> {
    let mut pos = 0usize;
    while pos + 4 <= table.len() {
        let typ = table[pos];
        let len = table[pos + 1] as usize;
        if len < 4 || pos + len > table.len() {
            return None; // corrupt table: stop, don't guess
        }
        if typ == 0 {
            // Extension Byte 2 lives at structure offset 0x13, so the
            // formatted area must be at least 0x14 bytes.
            if len < 0x14 {
                return None; // pre-UEFI-era structure layout
            }
            return Some(table[pos + 0x13] & 0x08 != 0);
        }
        // skip formatted area + string area (double-NUL terminated)
        pos += len;
        loop {
            if pos + 1 >= table.len() {
                return None;
            }
            if table[pos] == 0 && table[pos + 1] == 0 {
                pos += 2;
                break;
            }
            pos += 1;
        }
    }
    None // no Type 0 found
}

static FIRMWARE: OnceLock<(bool, SecBoot)> = OnceLock::new();
pub fn firmware() -> (bool, SecBoot) {
    *FIRMWARE.get_or_init(|| {
        if is_9x() {
            return (false, SecBoot::Unknown);
        }
        type GetFirmwareTypeFn = unsafe extern "system" fn(*mut i32) -> i32;
        let uefi = if let Some(f) = proc_from_module::<GetFirmwareTypeFn>("kernel32.dll", "GetFirmwareType") {
            let mut t: i32 = 0;
            // FIRMWARE_TYPE: Unknown=0, Bios=1, Uefi=2
            unsafe { f(&mut t) != 0 && t == 2 }
        } else {
            false
        };
        // SecureBoot, best source first:
        //   a) registry State\\UEFISecureBootEnabled (Win8+, NO privilege
        //      needed — Confirm-SecureBootUEFI / the firmware API both fail
        //      for a plain user, so this is what actually works)
        //   b) GetFirmwareEnvironmentVariableW with the
        //      SeSystemEnvironmentPrivilege enabled (elevated processes)
        //   c) PowerShell Confirm-SecureBootUEFI (the old install.ps1 way;
        //      also only works elevated, ~1s spawn, last resort)
        let sb = if let Some(state) = RegKey::open(
            hklm(),
            "SYSTEM\\CurrentControlSet\\Control\\SecureBoot\\State",
        )
        .and_then(|k| k.value_u32("UEFISecureBootEnabled"))
        {
            if state != 0 {
                SecBoot::Enabled
            } else {
                SecBoot::Disabled
            }
        } else if try_secure_boot_firmware_var() == Some(true) {
            SecBoot::Enabled
        } else if try_secure_boot_firmware_var() == Some(false) {
            SecBoot::Disabled
        } else {
            secure_boot_via_powershell().unwrap_or(SecBoot::Unknown)
        };
        (uefi, sb)
    })
}

/// SeSystemEnvironmentPrivilege ("SeSystemEnvironmentPrivilege") must be
/// ENABLED on the token before GetFirmwareEnvironmentVariableW works.
fn enable_system_environment_privilege() -> bool {
    type OpenProcessTokenFn = unsafe extern "system" fn(*mut c_void, u32, *mut *mut c_void) -> i32;
    type LookupPrivFn = unsafe extern "system" fn(*const u16, *const u16, *mut u64) -> i32;
    type AdjustTokPrivFn = unsafe extern "system" fn(
        *mut c_void,
        i32,
        *mut u8,
        u32,
        *mut u8,
        *mut u32,
    ) -> i32;
    let (open_tok, lookup, adjust) = (
        proc_from_module::<OpenProcessTokenFn>("advapi32.dll", "OpenProcessToken"),
        proc_from_module::<LookupPrivFn>("advapi32.dll", "LookupPrivilegeValueW"),
        proc_from_module::<AdjustTokPrivFn>("advapi32.dll", "AdjustTokenPrivileges"),
    );
    let (open_tok, lookup, adjust) = match (open_tok, lookup, adjust) {
        (Some(a), Some(b), Some(c)) => (a, b, c),
        _ => return false,
    };
    unsafe {
        let mut token: *mut c_void = std::ptr::null_mut();
        // TOKEN_ADJUST_PRIVILEGES(0x0020) | TOKEN_QUERY(0x0008)
        if open_tok(GetCurrentProcess() as *mut _, 0x0020 | 0x0008, &mut token) == 0 {
            return false;
        }
        // LUID_AND_ATTRIBUTES: LUID(8) + Attributes(4); TOKEN_PRIVILEGES:
        // count(4) + 1 entry
        let mut tp = [0u8; 16];
        let name = wide("SeSystemEnvironmentPrivilege");
        let mut luid: u64 = 0;
        let ok = lookup(std::ptr::null(), name.as_ptr(), &mut luid) != 0;
        if ok {
            tp[4..12].copy_from_slice(&luid.to_le_bytes());
            tp[12..16].copy_from_slice(&2u32.to_le_bytes()); // SE_PRIVILEGE_ENABLED
            let mut prev: u32 = 0;
            adjust(
                token,
                0,
                tp.as_mut_ptr(),
                tp.len() as u32,
                std::ptr::null_mut(),
                &mut prev,
            );
        }
        let _ = token; // token left open; process-lifetime is fine
        ok
    }
}

/// GetFirmwareEnvironmentVariableW probe; needs the system-environment
/// privilege (enable_system_environment_privilege).
fn try_secure_boot_firmware_var() -> Option<bool> {
    type GetFwVarFn = unsafe extern "system" fn(*const u16, *const u16, *mut u8, *mut u32) -> u32;
    let f = proc_from_module::<GetFwVarFn>("kernel32.dll", "GetFirmwareEnvironmentVariableW")?;
    enable_system_environment_privilege();
    let name = wide("SecureBoot");
    let guid = wide("{8be4df61-93ca-11d2-aa0d-00e098032b8c}");
    let mut val = [0u8; 1];
    let mut size: u32 = 1;
    let r = unsafe { f(name.as_ptr(), guid.as_ptr(), val.as_mut_ptr(), &mut size) };
    if r != 0 && size >= 1 {
        Some(val[0] == 1)
    } else {
        None
    }
}

/// Confirm-SecureBootUEFI via Windows PowerShell (the old install.ps1 way).
/// Only succeeds for elevated processes; None = could not determine.
fn secure_boot_via_powershell() -> Option<SecBoot> {
    let (code, txt) = sys_capture_ps()?;
    if code != 0 {
        return None;
    }
    let t = txt.trim().to_lowercase();
    if t == "true" {
        Some(SecBoot::Enabled)
    } else if t == "false" {
        Some(SecBoot::Disabled)
    } else {
        None
    }
}

fn sys_capture_ps() -> Option<(u32, String)> {
    capture(
        "powershell.exe",
        &[
            "-NoProfile".into(),
            "-Command".into(),
            "[bool](Confirm-SecureBootUEFI)".into(),
        ],
    )
}

#[allow(dead_code)]
fn firmware_legacy() -> (bool, SecBoot) {
    *FIRMWARE.get_or_init(|| {
        if is_9x() {
            return (false, SecBoot::Unknown);
        }
        type GetFirmwareTypeFn = unsafe extern "system" fn(*mut i32) -> i32;
        let uefi = if let Some(f) = proc_from_module::<GetFirmwareTypeFn>("kernel32.dll", "GetFirmwareType") {
            let mut t: i32 = 0;
            // FIRMWARE_TYPE: Unknown=0, Bios=1, Uefi=2
            unsafe { f(&mut t) != 0 && t == 2 }
        } else {
            false
        };
        // SecureBoot variable: EFI Global Variable namespace, GUID passed
        // AS A STRING per the GetFirmwareEnvironmentVariableW contract:
        //   "{8be4df61-93ca-11d2-aa0d-00e098032b8c}"
        type GetFwVarFn = unsafe extern "system" fn(*const u16, *const u16, *mut u8, *mut u32) -> u32;
        let sb = match proc_from_module::<GetFwVarFn>(
            "kernel32.dll",
            "GetFirmwareEnvironmentVariableW",
        ) {
            Some(f) => {
                let name = wide("SecureBoot");
                let guid = wide("{8be4df61-93ca-11d2-aa0d-00e098032b8c}");
                let mut val = [0u8; 1];
                let mut size: u32 = 1;
                let r = unsafe { f(name.as_ptr(), guid.as_ptr(), val.as_mut_ptr(), &mut size) };
                if r != 0 && size >= 1 {
                    if val[0] == 1 {
                        SecBoot::Enabled
                    } else {
                        SecBoot::Disabled
                    }
                } else {
                    SecBoot::Unknown
                }
            }
            None => SecBoot::Unknown,
        };
        (uefi, sb)
    })
}

// ---------------------------------------------------------------------------
// RAM (installer machine, courtesy heads-up only)
// ---------------------------------------------------------------------------
pub fn total_ram() -> u64 {
    // GlobalMemoryStatusEx is 98+/2000+; the older GlobalMemoryStatus
    // (MEMORYSTATUS, plain DWORDs) exists since 95 RTM. Resolve dynamically
    // so the binary keeps loading everywhere.
    #[repr(C)]
    struct MemoryStatus {
        length: u32,
        memory_load: u32,
        total_phys: u32,
        avail_phys: u32,
        total_pagefile: u32,
        avail_pagefile: u32,
        total_virtual: u32,
        avail_virtual: u32,
    }
    #[repr(C)]
    struct MemoryStatusEx {
        length: u32,
        memory_load: u32,
        total_phys: u64,
        avail_phys: u64,
        total_pagefile: u64,
        avail_pagefile: u64,
        total_virtual: u64,
        avail_virtual: u64,
        avail_extended_virtual: u64,
    }
    // NOTE: exactly sizeof(MEMORYSTATUSEX) = 64; Windows rejects other values.
    unsafe extern "system" {
        fn GlobalMemoryStatus(buf: *mut MemoryStatus);
    }
    if let Some(f) = proc_from_module::<unsafe extern "system" fn(*mut MemoryStatusEx) -> i32>(
        "kernel32.dll",
        "GlobalMemoryStatusEx",
    ) {
        let mut ms: MemoryStatusEx = unsafe { std::mem::zeroed() };
        ms.length = std::mem::size_of::<MemoryStatusEx>() as u32;
        if unsafe { f(&mut ms) } != 0 {
            return ms.total_phys;
        }
    }
    let mut ms: MemoryStatus = unsafe { std::mem::zeroed() };
    ms.length = std::mem::size_of::<MemoryStatus>() as u32;
    unsafe { GlobalMemoryStatus(&mut ms) };
    ms.total_phys as u64
}

fn out2(tag: &str, v: u32) {
    crate::sys::out::plain(&format!("{} {}", tag, v));
}

/// Debug: report which path total_ram takes and why.
pub fn total_ram_debug() -> (u64, &'static str, u32) {
    #[repr(C)]
    struct MemoryStatusEx {
        length: u32,
        memory_load: u32,
        total_phys: u64,
        avail_phys: u64,
        total_pagefile: u64,
        avail_pagefile: u64,
        total_virtual: u64,
        avail_virtual: u64,
        avail_extended_virtual: u64,
    }
    if let Some(f) = proc_from_module::<unsafe extern "system" fn(*mut MemoryStatusEx) -> i32>(
        "kernel32.dll",
        "GlobalMemoryStatusEx",
    ) {
        out2("dbg: size_of(MemoryStatusEx) =", std::mem::size_of::<MemoryStatusEx>() as u32);
        let mut ms: MemoryStatusEx = unsafe { std::mem::zeroed() };
        ms.length = std::mem::size_of::<MemoryStatusEx>() as u32;
        let r = unsafe { f(&mut ms) };
        if r != 0 {
            return (ms.total_phys, "ex-ok", 0);
        }
        let err = unsafe { winapi::um::errhandlingapi::GetLastError() };
        // retry with a raw 64-byte buffer (exactly like the raw probe)
        let mut buf = [0u8; 64];
        buf[..4].copy_from_slice(&64u32.to_le_bytes());
        let r2 = unsafe { f(buf.as_mut_ptr() as *mut MemoryStatusEx) };
        out2("dbg: typed ret/r2 =", (r as u32) | (r2 as u32) << 16);
        return (0, "ex-failed", err);
    }
    (0, "no-export", 0)
}

// ---------------------------------------------------------------------------
// Volumes. Everything here is Win9x-safe (GetLogicalDriveStringsW /
// GetDriveTypeW / GetVolumeInformationW / GetDiskFreeSpaceExW all exist on
// 95 OSR2+/NT4, and the W registry-free forms are unicows-covered).
// ---------------------------------------------------------------------------
#[derive(Clone, Debug)]
pub struct Volume {
    pub letter: String,   // "C"
    pub label: String,
    pub fs: String,
    pub total: u64,
    pub free: u64,
    pub cdrom: bool,
    pub removable: bool,
}

impl Volume {
    pub fn root(&self) -> String {
        format!("{}:\\", self.letter)
    }
    pub fn has_casper_squashfs(&self) -> bool {
        path_exists(&format!("{}\\casper\\filesystem.squashfs", self.root()))
    }
    pub fn size_gb(&self) -> f64 {
        self.total as f64 / GB as f64
    }
}

pub fn path_exists(p: &str) -> bool {
    // Win95: GetFileAttributesW is a no-op stub (always fails). Try the ANSI
    // variant as a fallback so the same logic works on 95 through 11 without
    // needing version detection (which itself relies on W-APIs).
    let w = wide(p);
    if unsafe { GetFileAttributesW(w.as_ptr()) } != u32::MAX {
        return true;
    }
    use winapi::um::fileapi::GetFileAttributesA;
    let mut a = Vec::with_capacity(p.len() + 1);
    a.extend_from_slice(p.as_bytes());
    a.push(0);
    unsafe { GetFileAttributesA(a.as_ptr() as *const i8) != u32::MAX }
}

pub fn is_dir(p: &str) -> bool {
    let w = wide(p);
    unsafe {
        GetFileAttributesW(w.as_ptr()) != u32::MAX
            && (GetFileAttributesW(w.as_ptr()) & FILE_ATTRIBUTE_DIRECTORY) != 0
    }
}

pub fn file_size(p: &str) -> Option<u64> {
    let w = wide(p);
    unsafe {
        let mut fd: winapi::um::minwinbase::WIN32_FIND_DATAW = std::mem::zeroed();
        let h = FindFirstFileW(w.as_ptr(), &mut fd);
        if h == INVALID_HANDLE_VALUE {
            // Win95: FindFirstFileW is a no-op stub; fall back to ANSI.
            return file_size_ansi(p);
        }
        FindClose(h);
        Some(((fd.nFileSizeHigh as u64) << 32) | fd.nFileSizeLow as u64)
    }
}

/// ANSI fallback for file_size (Win95's FindFirstFileW is a no-op stub).
fn file_size_ansi(p: &str) -> Option<u64> {
    use winapi::um::fileapi::FindFirstFileA;
    use winapi::um::minwinbase::WIN32_FIND_DATAA;
    let mut a = Vec::with_capacity(p.len() + 1);
    a.extend_from_slice(p.as_bytes());
    a.push(0);
    unsafe {
        let mut fd: WIN32_FIND_DATAA = std::mem::zeroed();
        let h = FindFirstFileA(a.as_ptr() as *const i8, &mut fd);
        if h == INVALID_HANDLE_VALUE {
            return None;
        }
        FindClose(h);
        Some(((fd.nFileSizeHigh as u64) << 32) | fd.nFileSizeLow as u64)
    }
}

/// List files matching `pattern` (e.g. "C:\\ISO\\*.iso") as (name, size),
/// using the ANSI APIs. Win95's FindFirstFileW/FindNextFileW are no-op
/// stubs, so the W-API callers fall back to this.
pub fn list_files_ansi(pattern: &str) -> Vec<(String, u64)> {
    use winapi::um::fileapi::{FindFirstFileA, FindNextFileA};
    use winapi::um::minwinbase::WIN32_FIND_DATAA;
    let mut a = Vec::with_capacity(pattern.len() + 1);
    a.extend_from_slice(pattern.as_bytes());
    a.push(0);
    let mut out = Vec::new();
    unsafe {
        let mut fd: WIN32_FIND_DATAA = std::mem::zeroed();
        let h = FindFirstFileA(a.as_ptr() as *const i8, &mut fd);
        if h == INVALID_HANDLE_VALUE {
            return out;
        }
        loop {
            let mut name = Vec::new();
            let mut i = 0usize;
            while fd.cFileName[i] != 0 {
                name.push(fd.cFileName[i] as u8);
                i += 1;
            }
            let name = String::from_utf8_lossy(&name).into_owned();
            if name != "." && name != ".." {
                let size = ((fd.nFileSizeHigh as u64) << 32) | fd.nFileSizeLow as u64;
                out.push((name, size));
            }
            if FindNextFileA(h, &mut fd) == 0 {
                break;
            }
        }
        FindClose(h);
    }
    out
}

pub fn list_volumes() -> Vec<Volume> {
    unsafe {
        let mut buf = [0u16; 1024];
        let n = GetLogicalDriveStringsW(buf.len() as u32 - 1, buf.as_mut_ptr());
        if n == 0 || n as usize >= buf.len() {
            return Vec::new();
        }
        let mut out = Vec::new();
        let mut rest = &buf[..n as usize];
        while !rest.is_empty() && rest[0] != 0 {
            let end = rest.iter().position(|&c| c == 0).unwrap_or(rest.len());
            let drive = from_wide(&rest[..end]); // "C:\"
            rest = &rest[end + 1..];
            // NOTE: the drive root must be passed explicitly - NULL means
            // "the current directory's drive", which would stamp every
            // volume with C:'s type (USB sticks misread as fixed, mounted
            // ISOs never detected as CD-ROM).
            let mut wdrive = wide(&drive);
            let dt = GetDriveTypeW(wdrive.as_ptr());
            let (label, fs) = vol_info(&drive);
            let mut freeq: winapi::shared::ntdef::ULARGE_INTEGER = std::mem::zeroed();
            let mut totalq: winapi::shared::ntdef::ULARGE_INTEGER = std::mem::zeroed();
            GetDiskFreeSpaceExW(
                wdrive.as_mut_ptr(),
                &mut freeq,
                &mut totalq,
                std::ptr::null_mut(),
            );
            let free = *freeq.QuadPart() as u64;
            let total = *totalq.QuadPart() as u64;
            let letter: String = drive.chars().next().map(|c| c.to_string()).unwrap_or_default();
            out.push(Volume {
                letter,
                label,
                fs,
                total,
                free,
                cdrom: dt == winapi::um::winbase::DRIVE_CDROM,
                removable: dt == winapi::um::winbase::DRIVE_REMOVABLE,
            });
        }
        out
    }
}

unsafe fn vol_info(root: &str) -> (String, String) {
    let mut wroot = wide(root);
    let mut label = [0u16; 261];
    let mut fs = [0u16; 64];
    // explicit block: unsafe ops in an unsafe-fn body need one on this toolchain
    let ok = unsafe {
        GetVolumeInformationW(
        wroot.as_mut_ptr(),
        label.as_mut_ptr(),
        label.len() as u32,
        std::ptr::null_mut(),
        std::ptr::null_mut(),
        std::ptr::null_mut(),
        fs.as_mut_ptr(),
        fs.len() as u32,
    )};
    if ok == 0 {
        (String::new(), String::new())
    } else {
        (from_wide(&label), from_wide(&fs))
    }
}

/// The casper-layout volumes the installer targets. Mirrors Find-UsbVolumes:
/// every lettered volume except CD-ROM (mounted ISOs look identical); label
/// match wins, else the casper marker file. `exclude` = letters known before
/// a Rufus write (prefer the freshly-written stick).
pub fn find_usb_volumes(label: &str, exclude: &[String]) -> Vec<Volume> {
    let mut found = Vec::new();
    for v in list_volumes() {
        if v.cdrom || exclude.iter().any(|e| e.eq_ignore_ascii_case(&v.letter)) {
            continue;
        }
        if !label.is_empty() && v.label.to_lowercase().contains(&label.to_lowercase()) {
            found.push(v);
            continue;
        }
        if v.has_casper_squashfs() {
            found.push(v);
        }
    }
    found.sort_by(|a, b| a.letter.cmp(&b.letter));
    found
}

// ---------------------------------------------------------------------------
// Directories & paths
// ---------------------------------------------------------------------------
pub fn temp_dir() -> String {
    let mut buf = [0u16; 1024];
    let n = unsafe { GetTempPathW(buf.len() as u32, buf.as_mut_ptr()) };
    from_wide(&buf[..n as usize])
}

pub fn user_profile() -> Option<String> {
    env_var("USERPROFILE")
}

pub fn env_var(name: &str) -> Option<String> {
    std::env::var(name).ok()
}

/// Mirrors Get-LocalAppData: %LOCALAPPDATA%, else <profile>\AppData\Local,
/// else %TEMP%.
pub fn local_app_data() -> String {
    env_var("LOCALAPPDATA")
        .or_else(|| user_profile().map(|p| format!("{}\\AppData\\Local", p)))
        .unwrap_or_else(temp_dir)
}

pub fn downloads_dir() -> String {
    match user_profile() {
        Some(p) => format!("{}\\Downloads", p),
        None => "C:\\Downloads".into(),
    }
}

pub fn create_dir_all(p: &str) {
    if p.is_empty() {
        return;
    }
    // Create every leading prefix ending in a separator, plus the full
    // path, as EXACT slices of the input: rebuilding from split components
    // mangled roots (`\\?\C:\...` became `?\C:\...`, UNC lost its
    // server) and failed every call with ERROR_INVALID_NAME. Errors are
    // ignored throughout (already-exists races, roots, files in the way).
    let p = p.replace('/', "\\");
    let b = p.as_bytes();
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'\\' {
            let prefix = &p[..=i];
            unsafe {
                CreateDirectoryW(wide(prefix).as_ptr(), std::ptr::null_mut());
            }
            while i < b.len() && b[i] == b'\\' {
                i += 1;
            }
            continue;
        }
        i += 1;
    }
    unsafe {
        CreateDirectoryW(wide(&p).as_ptr(), std::ptr::null_mut());
    }
}

pub fn delete_file(p: &str) {
    unsafe {
        winapi::um::fileapi::DeleteFileW(wide(p).as_ptr());
    }
}

/// Fresh free-bytes query for a drive letter (post-cleanup re-check: the
/// UsbTarget snapshot goes stale the moment the user deletes anything).
pub fn free_bytes(letter: &str) -> Option<u64> {
    let root = format!("{}:\\", letter);
    let mut wroot = wide(&root);
    let mut freeq: winapi::shared::ntdef::ULARGE_INTEGER = unsafe { std::mem::zeroed() };
    let ok = unsafe {
        GetDiskFreeSpaceExW(
            wroot.as_mut_ptr(),
            &mut freeq,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        )
    };
    if ok == 0 {
        return None;
    }
    Some(unsafe { *freeq.QuadPart() } as u64)
}

pub fn copy_file(src: &str, dst: &str) -> SysResult<()> {
    let (s, d) = (wide(src), wide(dst));
    unsafe {
        if CopyFileW(s.as_ptr(), d.as_ptr(), 0) == 0 {
            return Err(last_err());
        }
    }
    Ok(())
}

/// Copy a whole directory tree (files only; skips junction loops).
pub fn copy_tree(src: &str, dst: &str) -> SysResult<()> {
    create_dir_all(dst);
    let pattern = format!("{}\\*", src);
    let w = wide(&pattern);
    unsafe {
        let mut fd: winapi::um::minwinbase::WIN32_FIND_DATAW = std::mem::zeroed();
        let h = FindFirstFileW(w.as_ptr(), &mut fd);
        if h == INVALID_HANDLE_VALUE {
            return Err(last_err());
        }
        loop {
            let name = from_wide(&fd.cFileName);
            if name != "." && name != ".." {
                let s = format!("{}\\{}", src, name);
                let d = format!("{}\\{}", dst, name);
                if fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0 {
                    copy_tree(&s, &d)?;
                } else {
                    copy_file(&s, &d)?;
                }
            }
            if FindNextFileW(h, &mut fd) == 0 {
                break;
            }
        }
        FindClose(h);
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Process launching (CreateProcessW is Win9x-safe)
// ---------------------------------------------------------------------------
pub struct Child {
    pub handle: HANDLE,
}

impl Child {
    pub fn wait(&self, timeout_ms: u32) -> bool {
        unsafe { WaitForSingleObject(self.handle, timeout_ms) == 0 }
    }
    pub fn exit_code(&self) -> Option<u32> {
        let mut code: u32 = 0;
        unsafe {
            if GetExitCodeProcess(self.handle, &mut code) != 0 {
                Some(code)
            } else {
                None
            }
        }
    }
}
impl Drop for Child {
    fn drop(&mut self) {
        unsafe { CloseHandle(self.handle); }
    }
}

fn quote(s: &str) -> String {
    if s.contains(' ') {
        format!("\"{}\"", s)
    } else {
        s.to_string()
    }
}

pub fn spawn(cmd: &str, args: &[String]) -> SysResult<Child> {
    let mut cmdline = quote(cmd);
    for a in args {
        cmdline.push(' ');
        cmdline.push_str(&quote(a));
    }
    let mut wcmd = wide(&cmdline);
    let mut si: STARTUPINFOW = unsafe { std::mem::zeroed() };
    si.cb = std::mem::size_of::<STARTUPINFOW>() as u32;
    let mut pi: PROCESS_INFORMATION = unsafe { std::mem::zeroed() };
    unsafe {
        if CreateProcessW(
            std::ptr::null(),
            wcmd.as_mut_ptr(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            0,
            0,
            std::ptr::null_mut(),
            std::ptr::null(),
            &mut si,
            &mut pi,
        ) == 0
        {
            return Err(last_err());
        }
        CloseHandle(pi.hThread);
    }
    Ok(Child { handle: pi.hProcess })
}

/// Spawn and capture stdout (for netsh / es.exe / bcdedit). Returns None when
/// the tool is absent (e.g. netsh on Win9x).
pub fn capture(cmd: &str, args: &[String]) -> Option<(u32, String)> {
    use winapi::um::fileapi::ReadFile;
    let mut cmdline = quote(cmd);
    for a in args {
        cmdline.push(' ');
        cmdline.push_str(&quote(a));
    }
    let mut wcmd = wide(&cmdline);
    unsafe {
        let mut sa: winapi::um::minwinbase::SECURITY_ATTRIBUTES = std::mem::zeroed();
        sa.nLength = std::mem::size_of::<winapi::um::minwinbase::SECURITY_ATTRIBUTES>() as u32;
        sa.bInheritHandle = 1;
        let mut read_end: HANDLE = std::ptr::null_mut();
        let mut write_end: HANDLE = std::ptr::null_mut();
        if CreatePipe(&mut read_end, &mut write_end, &mut sa, 0) == 0 {
            return None;
        }
        let mut si: STARTUPINFOW = std::mem::zeroed();
        si.cb = std::mem::size_of::<STARTUPINFOW>() as u32;
        si.dwFlags = STARTF_USESTDHANDLES;
        si.hStdOutput = write_end;
        si.hStdError = write_end;
        si.hStdInput = std::ptr::null_mut();
        let mut pi: PROCESS_INFORMATION = std::mem::zeroed();
        if CreateProcessW(
            std::ptr::null(),
            wcmd.as_mut_ptr(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            1,
            0,
            std::ptr::null_mut(),
            std::ptr::null(),
            &mut si,
            &mut pi,
        ) == 0
        {
            CloseHandle(read_end);
            CloseHandle(write_end);
            return None;
        }
        CloseHandle(pi.hThread);
        CloseHandle(write_end); // child holds the write end now

        let mut out: Vec<u8> = Vec::new();
        let mut buf = [0u8; 4096];
        loop {
            let mut got: u32 = 0;
            if ReadFile(read_end, buf.as_mut_ptr() as *mut _, buf.len() as u32, &mut got, std::ptr::null_mut()) == 0
                || got == 0
            {
                break;
            }
            out.extend_from_slice(&buf[..got as usize]);
        }
        CloseHandle(read_end);
        WaitForSingleObject(pi.hProcess, 60_000);
        let mut code: u32 = 0;
        GetExitCodeProcess(pi.hProcess, &mut code);
        CloseHandle(pi.hProcess);
        Some((code, oem_to_string(&out)))
    }
}

/// ShellExecute "runas" (XP+ / 2000 with SE_SHUTDOWN?). Falls back to a plain
/// CreateProcess on 9x. Returns the process handle when available.
pub fn run_elevated(exe: &str, args: &[String]) -> SysResult<Option<Child>> {
    if is_9x() {
        let c = spawn(exe, args)?;
        return Ok(Some(c));
    }
    // ShellExecuteExW with SEE_MASK_NOCLOSEPROCESS + "runas"
    type T = unsafe extern "system" fn(*mut SHELLEXECUTEINFOW) -> i32;
    let params = format!("{} ", args.iter().map(|a| quote(a)).collect::<Vec<_>>().join(" "));
    let mut file = wide(exe);
    let mut verb = wide("runas");
    let mut wparams = wide(&params);
    let mut sei: SHELLEXECUTEINFOW = unsafe { std::mem::zeroed() };
    sei.cbSize = std::mem::size_of::<SHELLEXECUTEINFOW>() as u32;
    sei.fMask = SEE_MASK_NOCLOSEPROCESS;
    sei.lpVerb = verb.as_mut_ptr();
    sei.lpFile = file.as_mut_ptr();
    sei.lpParameters = wparams.as_mut_ptr();
    sei.nShow = winapi::um::winuser::SW_SHOWNORMAL;
    let shell = DynLib::load("shell32.dll");
    let ok = match shell.and_then(|l| l.proc("ShellExecuteExW")) {
        Some(p) => unsafe {
            let f: T = std::mem::transmute_copy(&p);
            f(&mut sei) != 0
        },
        None => false,
    };
    if ok && !sei.hProcess.is_null() {
        Ok(Some(Child { handle: sei.hProcess }))
    } else if ok {
        Ok(None)
    } else {
        Err(SysErr::Msg("Run as administrator failed (user declined?)".into()))
    }
}

/// Open a URL / file with the default handler.
/// Open a URL/path with the shell association handler. Tries, in order:
/// ShellExecuteW, ShellExecuteA, `explorer <url>`, and the Win9x-era
/// `rundll32 url.dll,FileProtocolHandler`. Returns a diagnostic string of
/// every attempt (empty = first attempt just worked).
pub fn open_url(what: &str) -> String {
    use winapi::um::shellapi::ShellExecuteW;
    let mut log = String::new();
    // defensive: a bare domain is a relative path to ShellExecute — give it a scheme
    let what_owned = if !what.contains("://")
        && !what.starts_with("http:")
        && what.contains('.')
        && !what.starts_with('/')
    {
        format!("https://{what}")
    } else {
        what.to_string()
    };
    let what = what_owned.as_str();
    let wop = wide("open");
    let wwhat = wide(what);
    let res = unsafe {
        ShellExecuteW(
            std::ptr::null_mut(),
            wop.as_ptr(),
            wwhat.as_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            winapi::um::winuser::SW_SHOWNORMAL,
        ) as usize
    } as u32;
    if res > 32 {
        return log;
    }
    log.push_str(&format!("shellexecw={res} "));
    // ShellExecuteExW with NOASYNC: reports the real error via hInstApp/GetLastError
    {
        use winapi::um::shellapi::{SEE_MASK_FLAG_DDEWAIT, SEE_MASK_FLAG_NO_UI, SEE_MASK_NOASYNC};
        use winapi::um::winuser::SW_SHOWNORMAL as SW2;
        let mut sei: SHELLEXECUTEINFOW = unsafe { std::mem::zeroed() };
        sei.cbSize = std::mem::size_of::<SHELLEXECUTEINFOW>() as u32;
        sei.fMask = SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI | SEE_MASK_FLAG_DDEWAIT;
        sei.lpVerb = wop.as_ptr();
        sei.lpFile = wwhat.as_ptr();
        sei.nShow = SW2;
        // E0133 demands the block, unused_unsafe calls it unnecessary:
        // both lints are satisfied only with the block + targeted allow.
        #[allow(unused_unsafe)]
        let ok = unsafe { ShellExecuteExW(&mut sei) };
        #[allow(unused_unsafe)]
        let gle = unsafe { winapi::um::errhandlingapi::GetLastError() };
        log.push_str(&format!(
            "exw(ok={ok} hinst={} gle={gle}) ",
            sei.hInstApp as usize
        ));
        if ok != 0 && sei.hInstApp as usize > 32 {
            return log;
        }
    }
    // ShellExecuteA (ANSI associations can differ on old shells)
    let resa = unsafe {
        ShellExecuteA(
            std::ptr::null_mut(),
            b"open\0".as_ptr() as _,
            what.as_ptr() as _,
            std::ptr::null(),
            std::ptr::null(),
            winapi::um::winuser::SW_SHOWNORMAL,
        ) as usize
    } as u32;
    if resa > 32 {
        log.push_str(&format!("shellexecA={resa}"));
        return log;
    }
    log.push_str(&format!("shellexecA={resa} "));
    // explorer.exe opens URLs via its own shell machinery
    match spawn("explorer", &[what.to_string()]) {
        Ok(_) => log.push_str("explorer=ok "),
        Err(e) => log.push_str(&format!("explorer={e} ")),
    }
    // 64-bit rundll32 via Sysnative (System32 redirects to SysWOW64 for us)
    match spawn(
        "C:\\Windows\\Sysnative\\rundll32.exe",
        &["url.dll,FileProtocolHandler".to_string(), what.to_string()],
    ) {
        Ok(_) => log.push_str("rundll32_64=ok "),
        Err(e) => log.push_str(&format!("rundll32_64={e} ")),
    }
    match spawn(
        "rundll32",
        &["url.dll,FileProtocolHandler".to_string(), what.to_string()],
    ) {
        Ok(_) => log.push_str("rundll32=ok "),
        Err(e) => log.push_str(&format!("rundll32={e} ")),
    }
    // Last resort: spawn rundll32 with a MINIMAL environment. When this exe
    // is launched via WSL interop, the inherited Linux-flavoured environment
    // makes URL-association resolution fail in every child we spawn.
    match spawn_clean_env(
        "C:\\Windows\\Sysnative\\rundll32.exe",
        &["url.dll,FileProtocolHandler".to_string(), what.to_string()],
    ) {
        Ok(child) => {
            child.wait(12000);
            let code = child.exit_code().unwrap_or(0xFFFF_FFFF);
            log.push_str(&format!("rundll32_clean=ok exit={code} "));
        }
        Err(e) => log.push_str(&format!("rundll32_clean={e} ")),
    }
    // Last resort: resolve the default browser ourselves and launch it
    // directly (bypasses every shell layer — works even when ShellExecute
    // fails for every child of this process).
    match open_url_direct(what) {
        Ok(who) => log.push_str(&format!("direct={who}")),
        Err(e) => log.push_str(&format!("direct={e}")),
    }
    log
}

/// Resolve a URL/protocol association ourselves and launch the handler exe.
/// Returns a short description of what was launched.
fn open_url_direct(url: &str) -> Result<String, String> {
    // protocol scheme up to ':'
    let scheme = url.split(':').next().unwrap_or("").to_lowercase();
    if scheme.is_empty() {
        return Err("no-scheme".into());
    }
    // 1) HKCU UrlAssociations UserChoice ProgId, 2) HKCR\<scheme>\shell\open
    let progid = crate::sys::RegKey::open(
        hkcu(),
        &format!(
            "Software\\Microsoft\\Windows\\Shell\\Associations\\UrlAssociations\\{scheme}\\UserChoice"
        ),
    )
    .and_then(|k| k.value("ProgId"))
    .unwrap_or_default();
    let classes_keys = [
        ("HKCU", crate::sys::hkcu(), format!("Software\\Classes\\{progid}\\shell\\open\\command")),
        ("HKLM", crate::sys::hklm(), format!("Software\\Classes\\{progid}\\shell\\open\\command")),
    ];
    let mut cmdline = String::new();
    for (_, root, path) in classes_keys.iter() {
        if let Some(k) = crate::sys::RegKey::open(*root, path) {
            if let Some(v) = k.value("") {
                if !v.trim().is_empty() {
                    cmdline = v;
                    break;
                }
            }
        }
    }
    if cmdline.is_empty() {
        // fall back to the protocol key itself: HKCR\<scheme>\shell\open\command
        for (_, root, path) in [
            ("HKCU", crate::sys::hkcu(), format!("Software\\Classes\\{scheme}\\shell\\open\\command")),
            ("HKLM", crate::sys::hklm(), format!("Software\\Classes\\{scheme}\\shell\\open\\command")),
        ] {
            if let Some(k) = crate::sys::RegKey::open(root, &path) {
                if let Some(v) = k.value("") {
                    if !v.trim().is_empty() {
                        cmdline = v;
                        break;
                    }
                }
            }
        }
    }
    if cmdline.is_empty() {
        return Err(format!("no-association progid={progid:?}"));
    }
    // substitute %1 (also %%1 / "%1" quoting variants)
    let url_q = if url.contains(' ') { format!("\"{url}\"") } else { url.to_string() };
    let final_cmd = cmdline
        .replace("%\"1\"", &url_q)
        .replace("%1", &url_q)
        .replace("%2", &url_q);
    // split program + args: if it starts with a quoted path, split at the
    // closing quote, else at the first space
    let (prog, rest) = if let Some(rest) = final_cmd.strip_prefix('"') {
        match rest.find('"') {
            Some(i) => (rest[..i].to_string(), rest[i + 1..].trim().to_string()),
            None => (rest.to_string(), String::new()),
        }
    } else {
        match final_cmd.find(' ') {
            Some(i) => (final_cmd[..i].to_string(), final_cmd[i + 1..].trim().to_string()),
            None => (final_cmd.clone(), String::new()),
        }
    };
    let mut args: Vec<String> = Vec::new();
    if !rest.is_empty() {
        args.push(rest);
    }
    spawn_clean_env(&prog, &args).map_err(|e| format!("spawn={e}"))?;
    Ok(format!(
        "{} ({prog})",
        if progid.is_empty() { scheme.as_str() } else { progid.as_str() }
    ))
}

/// Like spawn(), but gives the child a minimal, purely Windows environment
/// (inherited WSL-interop variables can break shell URL association).
pub fn spawn_clean_env(cmd: &str, args: &[String]) -> SysResult<Child> {
    let mut cmdline = quote(cmd);
    for a in args {
        cmdline.push(' ');
        cmdline.push_str(&quote(a));
    }
    let mut wcmd = wide(&cmdline);
    let mut envblock: Vec<u16> = Vec::new();
    let profile = env_var("USERPROFILE").unwrap_or_else(|| "C:\\Users\\Public".into());
    let profile = if profile.starts_with("\\") { "C:\\Users\\Public".to_string() } else { profile };
    let mut vars = vec![
        "PATH=C:\\Windows\\System32;C:\\Windows;C:\\Windows\\System32\\wbem".to_string(),
        "SystemRoot=C:\\Windows".to_string(),
        "SystemDrive=C:".to_string(),
        "TEMP=C:\\Windows\\Temp".to_string(),
        "TMP=C:\\Windows\\Temp".to_string(),
        "windir=C:\\Windows".to_string(),
        format!("USERPROFILE={profile}"),
        format!("HOMEDRIVE={}", profile.chars().take(2).collect::<String>()),
        format!("HOMEPATH={}", profile.get(2..).unwrap_or("\\")),
        format!("LOCALAPPDATA={profile}\\AppData\\Local"),
        format!("APPDATA={profile}\\AppData\\Roaming"),
        format!("USERNAME={}", env_var("USERNAME").unwrap_or_else(|| "user".into())),
        format!("COMPUTERNAME={}", env_var("COMPUTERNAME").unwrap_or_else(|| "PC".into())),
    ];
    if let Some(pl) = env_var("ProgramFiles") { if !pl.starts_with("\\") { vars.push(format!("ProgramFiles={pl}")); } }
    if let Some(pl) = env_var("ProgramFiles(x86)") { if !pl.starts_with("\\") { vars.push(format!("ProgramFiles(x86)={pl}")); } }
    if let Some(pl) = env_var("ProgramData") { if !pl.starts_with("\\") { vars.push(format!("ProgramData={pl}")); } }
    for kv in &vars {
        envblock.extend(kv.encode_utf16());
        envblock.push(0);
    }
    envblock.push(0);
    // CreateProcessW wants a 4-byte-aligned environment block; repack the
    // UTF-16 pairs into u32s to guarantee alignment.
    while envblock.len() % 2 != 0 {
        envblock.push(0);
    }
    let aligned: Vec<u32> = envblock
        .chunks(2)
        .map(|c| c[0] as u32 | ((c[1] as u32) << 16))
        .collect();
    let mut si: STARTUPINFOW = unsafe { std::mem::zeroed() };
    si.cb = std::mem::size_of::<STARTUPINFOW>() as u32;
    let mut pi: PROCESS_INFORMATION = unsafe { std::mem::zeroed() };
    unsafe {
        if CreateProcessW(
            std::ptr::null(),
            wcmd.as_mut_ptr(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            0,
            0x400, // CREATE_UNICODE_ENVIRONMENT
            aligned.as_ptr() as *const u32 as *mut winapi::ctypes::c_void,
            std::ptr::null(),
            &mut si,
            &mut pi,
        ) == 0
        {
            return Err(last_err());
        }
        CloseHandle(pi.hThread);
    }
    Ok(Child { handle: pi.hProcess })
}

// ---------------------------------------------------------------------------
// Console helpers (color output; gracefully no-op when redirected)
// ---------------------------------------------------------------------------
unsafe extern "system" {
    fn SetConsoleTextAttribute(h: HANDLE, attr: u16) -> i32;
}

use std::os::windows::io::AsRawHandle;

fn con() -> HANDLE {
    std::io::stdout().as_raw_handle() as HANDLE
}

fn set_color(attr: u16) {
    unsafe {
        SetConsoleTextAttribute(con(), attr);
    }
}

pub fn color_supported() -> bool {
    unsafe {
        let mut mode: u32 = 0;
        // Console handles report GetConsoleMode success; pipes fail.
        winapi::um::consoleapi::GetConsoleMode(
            GetStdHandle(STD_OUTPUT_HANDLE),
            &mut mode,
        ) != 0
    }
}

pub mod out {
    use super::{color_supported, set_color};
    use std::io::Write;

    const FG_CYAN: u16 = 0x0B;
    const FG_GRAY: u16 = 0x08;
    const FG_YELLOW: u16 = 0x0E;
    const FG_RED: u16 = 0x0C;

    fn put(color: u16, indent: &str, msg: &str) {
        let stdout = std::io::stdout();
        let mut lock = stdout.lock();
        if color_supported() {
            set_color(color);
            let _ = writeln!(lock, "{}{}", indent, msg);
            set_color(0x07);
        } else {
            let _ = writeln!(lock, "{}{}", indent, msg);
        }
    }

    pub fn step(msg: &str) {
        let stdout = std::io::stdout();
        let mut lock = stdout.lock();
        let _ = writeln!(lock);
        if color_supported() {
            set_color(FG_CYAN);
            let _ = writeln!(lock, "==> {}", msg);
            set_color(0x07);
        } else {
            let _ = writeln!(lock, "==> {}", msg);
        }
    }
    pub fn info(msg: &str) {
        put(FG_GRAY, "    ", msg);
    }
    pub fn warn(msg: &str) {
        put(FG_YELLOW, "    WARNING: ", msg);
    }
    pub fn err(msg: &str) {
        put(FG_RED, "    ERROR: ", msg);
    }
    pub fn plain(msg: &str) {
        let stdout = std::io::stdout();
        let mut lock = stdout.lock();
        let _ = writeln!(lock, "{}", msg);
        let _ = lock.flush();
    }
    pub fn prompt(msg: &str) -> String {
        let stdout = std::io::stdout();
        let mut lock = stdout.lock();
        let _ = write!(lock, "{}", msg);
        let _ = lock.flush();
        let mut line = String::new();
        let _ = std::io::stdin().read_line(&mut line);
        line.trim().to_string()
    }
}

// ---------------------------------------------------------------------------
// Registry (W registry APIs are supported on Win9x; advapi32 is always linked)
// ---------------------------------------------------------------------------
use winapi::um::winnt::{KEY_READ};

pub struct RegKey(pub HKEY);

impl RegKey {
    pub fn open(root: HKEY, path: &str) -> Option<RegKey> {
        let mut h: HKEY = std::ptr::null_mut();
        let w = wide(path);
        unsafe {
            if RegOpenKeyExW(root, w.as_ptr(), 0, KEY_READ, &mut h) == 0 {
                Some(RegKey(h))
            } else {
                None
            }
        }
    }
    /// Open with KEY_WOW64_64KEY: read the native (64-bit) registry view from
    /// a 32-bit process. Used for the 64-bit app Uninstall keys.
    pub fn open_wow64(root: HKEY, path: &str) -> Option<RegKey> {
        let mut h: HKEY = std::ptr::null_mut();
        let w = wide(path);
        unsafe {
            if RegOpenKeyExW(root, w.as_ptr(), 0, KEY_READ | 0x0100, &mut h) == 0 {
                Some(RegKey(h))
            } else {
                None
            }
        }
    }
    pub fn subkeys(&self) -> Vec<String> {
        let mut out = Vec::new();
        unsafe {
            for i in 0..4096u32 {
                let mut name = [0u16; 261];
                let mut len: u32 = 261;
                if RegEnumKeyExW(
                    self.0, i, name.as_mut_ptr(), &mut len, std::ptr::null_mut(),
                    std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null_mut(),
                ) != 0
                {
                    break;
                }
                out.push(from_wide(&name[..len as usize]));
            }
        }
        out
    }
    pub fn value(&self, name: &str) -> Option<String> {
        let w = wide(name);
        unsafe {
            let mut ty: u32 = 0;
            let mut size: u32 = 0;
            if RegQueryValueExW(self.0, w.as_ptr(), std::ptr::null_mut(), &mut ty,
                std::ptr::null_mut(), &mut size) != 0 || size == 0 {
                return None;
            }
            let mut buf = vec![0u8; size as usize];
            if RegQueryValueExW(self.0, w.as_ptr(), std::ptr::null_mut(), &mut ty,
                buf.as_mut_ptr(), &mut size) != 0 {
                return None;
            }
            if ty == REG_SZ {
                let w: Vec<u16> = buf
                    .chunks_exact(2)
                    .take_while(|c| c[0] != 0 || c[1] != 0)
                    .map(|c| u16::from_le_bytes([c[0], c[1]]))
                    .collect();
                Some(from_wide(&w))
            } else {
                String::from_utf8_lossy(&buf).into_owned().into()
            }
        }
    }
    pub fn value_u32(&self, name: &str) -> Option<u32> {
        let w = wide(name);
        unsafe {
            let mut ty: u32 = 0;
            let mut v: u32 = 0;
            let mut size: u32 = 4;
            if RegQueryValueExW(self.0, w.as_ptr(), std::ptr::null_mut(), &mut ty,
                (&mut v as *mut u32) as *mut u8, &mut size) != 0 {
                None
            } else {
                Some(v)
            }
        }
    }
}
impl Drop for RegKey {
    fn drop(&mut self) {
        unsafe { RegCloseKey(self.0); }
    }
}

pub fn hkcu() -> HKEY {
    HKEY_CURRENT_USER
}
pub fn hklm() -> HKEY {
    HKEY_LOCAL_MACHINE
}

// winapi-style alias (mirrors winapi::ctypes::c_void); the lowercase name
// is deliberate, hence the allow.
#[allow(non_camel_case_types)]
pub type c_void = winapi::ctypes::c_void;

// ---------------------------------------------------------------------------
// Folder browse dialog (SHBrowseForFolder, 95+; loaded dynamically). Returns
// a Windows path like "C:\Users\you\folder".
// ---------------------------------------------------------------------------
pub fn browse_folder(title: &str) -> Option<String> {
    let lib = DynLib::load("shell32.dll")?;
    let browse = lib.proc("SHBrowseForFolderW")?;
    let get_path = lib.proc("SHGetPathFromIDListW")?;

    #[repr(C)]
    struct BrowseInfoW {
        owner: *mut c_void,
        pidl_root: *mut c_void,
        display_name: *mut u16,
        title: *const u16,
        flags: u32,
        callback: isize,
        param: isize,
        image: i32,
    }

    unsafe {
        type BrowseFn = unsafe extern "system" fn(*mut BrowseInfoW) -> *mut c_void;
        type GetPathFn = unsafe extern "system" fn(*mut c_void, *mut u16) -> i32;
        type FreeFn = unsafe extern "system" fn(*mut c_void);
        let browse_f: BrowseFn = std::mem::transmute_copy(&browse);
        let get_path_f: GetPathFn = std::mem::transmute_copy(&get_path);
        let free_f: Option<FreeFn> = DynLib::load("ole32.dll")
            .and_then(|ole| ole.proc("CoTaskMemFree"))
            .map(|p| std::mem::transmute_copy::<*const (), FreeFn>(&p));

        let mut display = [0u16; 260];
        let wtitle = wide(title);
        let mut bi = BrowseInfoW {
            owner: std::ptr::null_mut(),
            pidl_root: std::ptr::null_mut(),
            display_name: display.as_mut_ptr(),
            title: wtitle.as_ptr(),
            flags: 0x0001 | 0x0010 | 0x0040, // RETURNONLYFSDIRS | EDITBOX | NEWDIALOGSTYLE
            callback: 0,
            param: 0,
            image: 0,
        };
        let pidl = browse_f(&mut bi);
        if pidl.is_null() {
            return None;
        }
        let mut buf = [0u16; 260];
        let ok = get_path_f(pidl, buf.as_mut_ptr());
        if let Some(f) = free_f {
            f(pidl);
        }
        if ok == 0 {
            return None;
        }
        Some(from_wide(&buf))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Minimal Type 0 structure: type=0, len=0x14, ext byte2 at +0x13,
    /// then an empty string area (double NUL).
    fn type0(ext2: u8) -> Vec<u8> {
        let mut v = vec![0u8; 0x14];
        v[0] = 0;
        v[1] = 0x14;
        v[0x13] = ext2;
        v.extend_from_slice(&[0, 0]);
        v
    }

    #[test]
    fn smbios_uefi_bit_parsed() {
        assert_eq!(smbios_uefi_flag(&type0(0x08)), Some(true));
        assert_eq!(smbios_uefi_flag(&type0(0x00)), Some(false));
        // other bits set, UEFI bit clear
        assert_eq!(smbios_uefi_flag(&type0(0xF7)), Some(false));
    }

    #[test]
    fn smbios_skips_earlier_structures() {
        // a Type 1 structure with one string, then Type 0 with UEFI set
        let mut v = vec![1u8, 8, 0x10, 0x27, 1, 2, 3, 4];
        v.extend_from_slice(b"sys\0ver\0\0");
        v.extend_from_slice(&type0(0x08));
        assert_eq!(smbios_uefi_flag(&v), Some(true));
    }

    #[test]
    fn smbios_short_or_missing_is_none() {
        assert_eq!(smbios_uefi_flag(&[]), None);
        // Type 0 with a pre-UEFI short layout
        let mut v = vec![0u8; 8];
        v[0] = 0;
        v[1] = 8;
        v.extend_from_slice(&[0, 0]);
        assert_eq!(smbios_uefi_flag(&v), None);
        // corrupt length running past the buffer
        assert_eq!(smbios_uefi_flag(&[0, 200, 0, 0]), None);
        // no Type 0 at all
        let mut v = vec![127u8, 4, 0, 0];
        v.extend_from_slice(&[0, 0]);
        assert_eq!(smbios_uefi_flag(&v), None);
    }

    #[test]
    fn create_dir_all_builds_absolute_paths() {
        // Regression: the old implementation turned "C:\a\b" into "C:a\b"
        // (drive-relative), which only worked while the drive's CWD was its
        // root. Must handle a plain absolute temp path correctly.
        let mut d = std::env::temp_dir();
        d.push(format!("lslsetup-mkdir-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        let sub = d.join("efi").join("grub");
        let s = sub.to_string_lossy().into_owned();
        create_dir_all(&s);
        assert!(sub.is_dir(), "create_dir_all failed to create {}", s);
        // idempotent: existing dirs are fine (errors ignored)
        create_dir_all(&s);
        assert!(sub.is_dir());
        let _ = std::fs::remove_dir_all(&d);
    }
}

/// Convert a Windows path to the WSL-style Linux path used in lsl-usb.env:
/// "C:\Users\x\lsl-usb" -> "/mnt/c/Users/x/lsl-usb". Passes through paths
/// that are not drive-letter form.
pub fn win_to_wsl_path(p: &str) -> String {
    let b = p.as_bytes();
    if b.len() >= 3 && b[1] == b':' && (b[2] == b'\\' || b[2] == b'/') {
        let drive = (b[0] as char).to_lowercase().next().unwrap();
        let rest = p[3..].replace('\\', "/");
        format!("/mnt/{}{}", drive, rest)
    } else {
        p.to_string()
    }
}
