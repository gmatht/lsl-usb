//! Boot plumbing: motherboard boot-menu key map (Get-BootMenuKey), one-time
//! boot entry via bcdedit (Set-NextBootUsb), "LSL: Reboot to Select USB"
//! shortcuts (New-LslBootShortcut), and the boot-choice dialog.

use crate::sys::{self, out};
use winapi::um::winnt::HANDLE;

pub fn boot_menu_key() -> String {
    // Win32_BaseBoard Manufacturer/Product; WMI is unavailable on 9x and
    // heavy everywhere, so read the SMBIOS data from the registry instead:
    // HKLM\HARDWARE\DESCRIPTION\System\BIOS holds SystemManufacturer /
    // BaseBoardManufacturer on XP+; on 9x fall back to the generic hint.
    let mut manu = String::new();
    if let Some(bios) = sys::RegKey::open(sys::hklm(), "HARDWARE\\DESCRIPTION\\System\\BIOS") {
        manu = bios
            .value("BaseBoardManufacturer")
            .or_else(|| bios.value("SystemManufacturer"))
            .unwrap_or_default();
    }
    if manu.is_empty() {
        // 9x-era location
        if let Some(dd) = sys::RegKey::open(sys::hklm(), "Enum\\Root") {
            manu = dd
                .subkeys()
                .iter()
                .filter_map(|k| {
                    sys::RegKey::open(sys::hklm(), &format!("Enum\\Root\\{}", k))
                        .and_then(|d| d.subkeys().first().cloned())
                        .and_then(|sub| {
                            sys::RegKey::open(
                                sys::hklm(),
                                &format!("Enum\\Root\\{}\\{}", k, sub),
                            )
                            .and_then(|d| d.value("Mfg"))
                        })
                })
                .next()
                .unwrap_or_default();
        }
    }
    let m = manu.to_lowercase();
    let map: &[(&str, &str)] = &[
        ("dell", "F12"),
        ("hewlett-packard", "F9"),
        ("hp ", "F9"),
        ("hp", "F9"),
        ("lenovo", "F12"),
        ("asus", "F8"),
        ("msi", "F11"),
        ("micro-star", "F11"),
        ("gigabyte", "F12"),
        ("acer", "F12"),
        ("toshiba", "F12"),
        ("samsung", "F2"),
        ("sony", "F11"),
        ("intel", "F10"),
        ("asrock", "F11"),
        ("biostar", "F9"),
        ("fujitsu", "F12"),
        ("gateway", "F12"),
        ("medion", "F11"),
        ("razer", "F12"),
        ("framework", "F12"),
        ("system76", "F7"),
    ];
    for (needle, key) in map {
        if m.contains(needle) {
            return key.to_string();
        }
    }
    // Microsoft Surface only (generic boards also report "Microsoft Corporation").
    if m.contains("microsoft") && m.contains("surface") {
        return "F12".into();
    }
    String::new()
}

pub fn is_uefi() -> bool {
    sys::firmware().0
}

pub fn secure_boot_status() -> sys::SecBoot {
    sys::firmware().1
}

/// Set-NextBootUsb: UEFI + bcdedit (Vista+). Returns the matched entry
/// description on success, or '' if it can't be done.
pub fn set_next_boot_usb() -> String {
    if !is_uefi() || sys::os_ver() < sys::OsVer::Vista {
        return String::new();
    }
    let Some((code, txt)) = sys::capture("bcdedit.exe", &["/enum".into(), "firmware".into()]) else {
        return String::new();
    };
    if code != 0 {
        return String::new();
    }
    // Parse identifier/description pairs (localized output variants tolerated:
    // match the {....} identifier and the 'description' line by heuristic).
    let mut entries: Vec<(String, String)> = Vec::new();
    let mut cur_id = String::new();
    let mut cur_desc = String::new();
    for line in txt.lines() {
        let l = line.trim();
        if let Some(open) = l.find('{') {
            if let Some(close) = l[open..].find('}') {
                if cur_id.contains('{') {
                    entries.push((cur_id.clone(), cur_desc.clone()));
                }
                cur_id = l[open..=open + close].to_string();
                cur_desc.clear();
                continue;
            }
        }
        let lower = l.to_lowercase();
        if lower.starts_with("description") || lower.starts_with("beschreibung") {
            if let Some(i) = l.find(' ') {
                cur_desc = l[i..].trim().to_string();
            }
        }
    }
    if cur_id.contains('{') {
        entries.push((cur_id, cur_desc));
    }
    let Some((id, desc)) = entries.into_iter().find(|(_, d)| d.to_lowercase().contains("usb"))
    else {
        return String::new();
    };
    let _ = sys::capture(
        "bcdedit.exe",
        &[
            "/set".into(),
            "{fwbootmgr}".into(),
            "bootsequence".into(),
            id.clone(),
        ],
    );
    // Verify
    if let Some((code, check)) = sys::capture("bcdedit.exe", &["/enum".into(), "{fwbootmgr}".into()]) {
        if code == 0 && check.contains(&id) {
            return desc;
        }
    }
    String::new()
}

/// shutdown.exe arguments for "reboot into firmware boot menu" (Win8+).
pub fn reboot_args() -> &'static str {
    if is_uefi() && sys::os_ver() >= sys::OsVer::Win8 {
        "/r /fw /t 0"
    } else {
        "/r /t 0"
    }
}

pub fn reboot(extra_args: &str) {
    let sysroot = sys::env_var("SystemRoot").unwrap_or_else(|| "C:\\Windows".into());
    let exe = format!("{}\\System32\\shutdown.exe", sysroot);
    let args: Vec<String> = extra_args
        .split_whitespace()
        .map(|s| s.to_string())
        .collect();
    match sys::spawn(&exe, &args) {
        Ok(_) => {}
        Err(e) => out::warn(&format!("shutdown failed: {}", e)),
    }
}

/// New-LslBootShortcut: "LSL - Reboot to Select USB.lnk" on Desktop + Start
/// Menu. Uses IShellLink COM (available on every supported Windows).
pub fn create_boot_shortcuts() -> Vec<String> {
    let mut created = Vec::new();
    let fw = if is_uefi() && sys::os_ver() >= sys::OsVer::Win8 {
        "/r /fw /t 0"
    } else {
        "/r /t 0"
    };
    let desc = if fw.contains("/fw") {
        "Reboots into the firmware boot menu - use the arrow keys to select the lsl-usb USB and press Enter.".to_string()
    } else {
        let key = boot_menu_key();
        let hint = if key.is_empty() {
            "press F12/Del/Esc during POST".to_string()
        } else {
            format!("press {} during POST", key)
        };
        format!("Reboots - {} to open the boot menu, then select the lsl-usb USB.", hint)
    };

    let mut dirs: Vec<String> = Vec::new();
    if let Some(p) = sys::user_profile() {
        dirs.push(format!("{}\\Desktop", p));
        dirs.push(format!("{}\\Start Menu\\Programs", p));
    }
    // Shell "special folder" locations override the naive profile paths when
    // they resolve (roaming profiles, redirected Desktop, non-English names).
    if let Some(d) = special_folder(0x0000) {
        dirs[0] = d; // CSIDL_DESKTOPDIRECTORY
    }
    if let Some(d) = special_folder(0x0017) {
        dirs[1] = format!("{}\\Programs", d); // CSIDL_STARTMENU
    }

    let sysroot = sys::env_var("SystemRoot").unwrap_or_else(|| "C:\\Windows".into());
    for dir in &dirs {
        if !sys::is_dir(dir) {
            sys::create_dir_all(dir);
        }
        let lnk = format!("{}\\LSL - Reboot to Select USB.lnk", dir);
        if create_shortcut(&lnk, &format!("{}\\System32\\shutdown.exe", sysroot), fw, &desc) {
            created.push(lnk);
        }
    }
    created
}

fn special_folder(csidl: i32) -> Option<String> {
    // SHGetSpecialFolderPathW (shell32, IE4+); dynamic so Win95 w/o IE degrades.
    let lib = sys::DynLib::load("shell32.dll")?;
    let p = lib.proc("SHGetSpecialFolderPathW")?;
    type FnT = unsafe extern "system" fn(HANDLE, *mut u16, i32, i32) -> i32;
    let f: FnT = unsafe { std::mem::transmute_copy(&p) };
    let mut buf = [0u16; 1024];
    let ok = unsafe { f(std::ptr::null_mut(), buf.as_mut_ptr(), csidl, 0) };
    if ok != 0 {
        Some(sys::from_wide(&buf))
    } else {
        None
    }
}

fn create_shortcut(lnk: &str, target: &str, args: &str, desc: &str) -> bool {
    use winapi::shared::wtypesbase::CLSCTX_INPROC_SERVER;
use winapi::um::combaseapi::CoCreateInstance;
    use winapi::um::objidl::IPersistFile;
    use winapi::um::shobjidl_core::IShellLinkW;

    type GUID = winapi::shared::guiddef::GUID;
    // {00021401-0000-0000-C000-000000000046}
    const CLSID_SHELLLINK: GUID = winapi::shared::guiddef::GUID {
        Data1: 0x0002_1401,
        Data2: 0x0000,
        Data3: 0x0000,
        Data4: [0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46],
    };
    unsafe {
        let mut link: *mut IShellLinkW = std::ptr::null_mut();
        let hr = CoCreateInstance(
            &CLSID_SHELLLINK,
            std::ptr::null_mut(),
            CLSCTX_INPROC_SERVER as u32,
            &GUID {
                Data1: 0x0002_1409, // IShellLinkW IID
                Data2: 0x0000,
                Data3: 0x0000,
                Data4: [0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46],
            },
            (&mut link as *mut *mut IShellLinkW) as *mut *mut winapi::ctypes::c_void,
        );
        if hr != 0 {
            return false;
        }
        let wtarget = sys::wide(target);
        let wargs = sys::wide(args);
        let wdesc = sys::wide(desc);
        (*link).SetPath(wtarget.as_ptr());
        (*link).SetArguments(wargs.as_ptr());
        (*link).SetDescription(wdesc.as_ptr());
        let persist: *mut IPersistFile = std::mem::transmute_copy(&link);
        let save = (*persist).Save(sys::wide(lnk).as_ptr(), 1);
        (*persist).Release();
        (*link).Release();
        save == 0
    }
}

// ---------------------------------------------------------------------------
// Boot-choice dialog (nwg modal — replaces the WinForms version)
// ---------------------------------------------------------------------------

#[derive(Clone, Debug)]
pub enum BootChoice {
    Usb,
    Adv,
    Fw,
    None,
}

/// One-line manual boot-menu hint for reboot offers (standalone dialog +
/// wizard boot page). Falls back to the common keys when the board is
/// unknown.
pub fn boot_key_hint() -> String {
    let key = boot_menu_key();
    if key.is_empty() {
        "Manual boot-menu key unknown - watch for the prompt during POST (often F12, F9, F8, or Esc).".into()
    } else {
        format!("Manual boot menu: press {} during POST.", key)
    }
}

/// Whether the one-time-boot entry can be set (UEFI + bcdedit-capable Windows).
pub fn can_set_next_boot() -> bool {
    is_uefi() && sys::os_ver() >= sys::OsVer::Win8
}

pub fn show_boot_choice_dialog() -> BootChoice {
    use native_windows_gui as nwg;
    use std::cell::RefCell;
    use std::rc::Rc;

    // Idempotent-enough: registers common controls; harmless if already done.
    let _ = nwg::init();

    let uefi = can_set_next_boot();
    let key_hint = boot_key_hint();

    let choice: Rc<RefCell<BootChoice>> = Rc::new(RefCell::new(BootChoice::None));
    let choice2 = choice.clone();

    let mut window: nwg::Window = Default::default();
    let mut key_lbl: nwg::Label = Default::default();
    let mut usb_btn: nwg::Button = Default::default();
    let mut adv_btn: nwg::Button = Default::default();
    let mut fw_btn: nwg::Button = Default::default();
    let mut none_btn: nwg::Button = Default::default();

    let _ = nwg::Window::builder()
        .size((560, 280))
        .center(true)
        .title("lsl-usb - Boot from USB")
        .build(&mut window);
    let _ = nwg::Label::builder()
        .text(&key_hint)
        .position((12, 10))
        .size((524, 24))
        .parent(&window)
        .build(&mut key_lbl);
    let _ = nwg::Button::builder()
        .text("Boot USB now (set one-time boot entry)")
        .position((12, 42))
        .size((524, 30))
        .parent(&window)
        .build(&mut usb_btn);
    let _ = nwg::Button::builder()
        .text("Advanced boot menu (shutdown /r /o)")
        .position((12, 78))
        .size((524, 30))
        .parent(&window)
        .build(&mut adv_btn);
    let _ = nwg::Button::builder()
        .text("Firmware boot menu (shutdown /r /fw)")
        .position((12, 114))
        .size((524, 30))
        .parent(&window)
        .build(&mut fw_btn);
    let _ = nwg::Button::builder()
        .text("Don't reboot")
        .position((12, 150))
        .size((524, 30))
        .parent(&window)
        .build(&mut none_btn);
    if !uefi {
        usb_btn.set_visible(false);
    }

    let _handlers = nwg::full_bind_event_handler(&window.handle, move |event, _, handle| {
        use nwg::Event;
        match event {
            Event::OnButtonClick => {
                let val = if handle == usb_btn.handle {
                    Some(BootChoice::Usb)
                } else if handle == adv_btn.handle {
                    Some(BootChoice::Adv)
                } else if handle == fw_btn.handle {
                    Some(BootChoice::Fw)
                } else if handle == none_btn.handle {
                    Some(BootChoice::None)
                } else {
                    None
                };
                if let Some(v) = val {
                    *choice2.borrow_mut() = v;
                    nwg::stop_thread_dispatch();
                }
            }
            Event::OnWindowClose => {
                nwg::stop_thread_dispatch();
            }
            _ => {}
        }
    });
    nwg::dispatch_thread_events();

    let r = choice.borrow();
    match &*r {
        BootChoice::Usb => BootChoice::Usb,
        BootChoice::Adv => BootChoice::Adv,
        BootChoice::Fw => BootChoice::Fw,
        BootChoice::None => BootChoice::None,
    }
}
