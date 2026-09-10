//! Installer GUI (Show-InstallerGui replacement) — native Win32 common
//! controls via nwg, so the same wizard works on Windows 95 -> 11 (the PS
//! version needs .NET WinForms).
//!
//! Mirrors the original wizard (now 6 pages; wifi split off system, plus
//! the INSTALL NOW page like install.ps1):
//!   page 0  hardware compatibility (LKDDb ratings, streamed in by a
//!           background thread so the 10s crawl-delay never blocks the UI)
//!   page 1  ISO selection (fresh-download radios, local ISOs, USB reuse)
//!   page 2  flatpak preloads (+ recommended FSearch + extra IDs)
//!   page 3  system: WSL VHDX, data dir, EFU, drivers, HDD cache, swap
//!           reclaim
//!   page 4  wifi networks (master switch + per-network list)
//!   page 5  INSTALL NOW: USB write method (Rufus / built-in
//!           non-destructive / skip) + target USB picker
//! On Install the wizard STAYS OPEN in a working phase and handles every
//! download (ISO + Rufus) itself with live status/progress — no "type OK"
//! console gate. It ends on a FINISHED / FAILED summary page (window stays
//! open) that shows the chosen settings and the equivalent command line for
//! headless/scripted runs; the page only closes when the user clicks
//! Finish/Close. The boot-choice dialog then finishes the flow.
//!
//! A console flow is still available via --no-gui.
//!
//! Layout: everything is positioned from the live CLIENT size in one place
//! (`relayout`). The window opens at the default 880x760 client — clamped to
//! the work area, so a 640x480 Win9x box (work area 640x452, client
//! ~632x~413 after title bar + borders) gets a window that fits instead of
//! running off-screen — and is fully resizable: WM_SIZE relayouts every
//! page, and WM_GETMINMAXINFO clamps dragging/maximizing to the work area.
//! Pages 1-5 scroll (page 0's ListView scrolls natively), so every size
//! works and enlarging the window genuinely shows more.

use native_windows_gui as nwg;

use crate::sys;

/// Multiline TextBox flags WITHOUT `ES_AUTOVSCROLL`. On Windows 10/11 a
/// multiline edit with `ES_AUTOVSCROLL` can auto-size its height to the
/// number of lines of text, squashing a fixed-height box to a few pixels
/// (the "squashed edit box" bug). These boxes are fixed-height, so keep the
/// scrollbars but drop the auto-scroll style that triggers the collapse.
fn multiline_edit_flags() -> nwg::TextBoxFlags {
    nwg::TextBoxFlags::VISIBLE
        | nwg::TextBoxFlags::VSCROLL
        | nwg::TextBoxFlags::HSCROLL
        | nwg::TextBoxFlags::AUTOHSCROLL
        | nwg::TextBoxFlags::TAB_STOP
}

/// Summary-page body flags: multiline readonly WITHOUT `TAB_STOP`. A readonly
/// multiline edit with TAB_STOP swallows the Tab key (inserts a tab) instead
/// of moving focus, which would trap the user on the FINISHED/FAILED page
/// (found by the Win95 puppeting session: Tab never reached the Finish
/// button).
fn summary_body_flags() -> nwg::TextBoxFlags {
    nwg::TextBoxFlags::VISIBLE
        | nwg::TextBoxFlags::VSCROLL
        | nwg::TextBoxFlags::HSCROLL
        | nwg::TextBoxFlags::AUTOHSCROLL
}

fn glog(msg: &str) {
    // Opt-in tracing: set LSL_GUI_DEBUG=1 (tests/win-gui-test.ps1 does).
    if std::env::var("LSL_GUI_DEBUG").as_deref() != Ok("1") {
        return;
    }
    use std::io::Write;
    let path = format!("{}\\lsl-gui-debug.log", sys::temp_dir());
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
        let _ = writeln!(f, "{}", msg);
    }
}
use std::cell::Cell;
use std::rc::Rc;
use std::sync::mpsc;

#[derive(Clone)]
pub struct GuiResult {
    pub iso_path: String,
    pub flatpak_ids: Vec<String>,
    pub wsl_vhdx: Vec<String>,
    pub data_dir: String,
    pub wifi: bool,
    pub wifi_networks: Vec<String>,
    pub efu: bool,
    pub drivers: bool,
    pub sfs_hdd: bool,
    pub reclaim_win_swap: bool,
    pub rust_tools: bool,
    pub distro_arch: Option<&'static str>,      // Some("i686"/"x86_64") when a fresh distro is selected
    pub download_iso: Option<(String, String)>, // (url, name) when fresh download chosen
    pub use_existing_usb: Option<String>,       // drive letter
    pub write_mode: Option<String>,             // "rufus" | "nofmt" | "skip" (INSTALL-page radio choice)
    pub target_usb: Option<String>,             // INSTALL-page target drive letter (nofmt copy)
    pub bios_boot: bool,                       // INSTALL-page "BIOS boot" checkbox (default: supported)
    pub uefi_boot: bool,                       // INSTALL-page "UEFI boot" checkbox (default: supported)
    pub check_usb: bool,                       // INSTALL-page "Check whole USB" checkbox (default: off, slow)
    pub skip_verify: bool,                     // INSTALL-page "Skip verify" checkbox (default: off = verify)
}

/// Wizard pages: 0 hw, 1 iso, 2 flatpak, 3 system, 4 wifi, 5 install.
/// The nav button reads "Next >" on every page BEFORE the install page and
/// "Install" only on the install page itself - clicking it on page 5 runs
/// the working phase (Rufus launch / built-in copy), never before.
pub(crate) const INSTALL_PAGE: usize = 5;
pub(crate) const NEXT_LABEL: &str = "Next >";
pub(crate) const INSTALL_LABEL: &str = "Install";

/// Nav-button caption for `page`: "Install" only on the INSTALL page.
/// Pure helper so the caption rule is unit-testable (the live button is
/// covered by the win-install-page GUI test).
pub(crate) fn nav_label(page: usize) -> &'static str {
    if page == INSTALL_PAGE {
        INSTALL_LABEL
    } else {
        NEXT_LABEL
    }
}

/// Refresh the INSTALL-page BIOS/UEFI boot checkboxes (Check kinds 5/6)
/// for the selected target stick: supported paths stay enabled (check state
/// preserved, except on first build where supported means checked),
/// unsupported paths are greyed out, unchecked, with the reason in the
/// label. `uefi_flag` is the --uefi-bootx64 path ("" in the wizard, where
/// only the vendored loader counts).
/// Recompute the firmware line (Lbl kind 7) from the checkbox states.
/// Call after any BIOS/UEFI checkbox or target change.
pub(crate) fn refresh_fw_note(items: &PageItems) {
    let mut bios = true;
    let mut uefi = true;
    for it in items.borrow().iter() {
        match &it.ctl {
            PageCtl::Check(cb, 5) => bios = cb.check_state() == nwg::CheckBoxState::Checked,
            PageCtl::Check(cb, 6) => uefi = cb.check_state() == nwg::CheckBoxState::Checked,
            _ => {}
        }
    }
    let text = crate::nofmt::board_note_short(bios, uefi, crate::sys::board_caps());
    for it in items.borrow().iter() {
        if let PageCtl::Lbl(lb, 7) = &it.ctl {
            lb.set_text(&text);
        }
    }
}

pub(crate) fn apply_boot_caps(items: &PageItems, letter: &str, uefi_flag: &str, first: bool) {
    let caps = crate::nofmt::probe_boot_caps(letter, uefi_flag);
    for it in items.borrow().iter() {
        match &it.ctl {
            PageCtl::Check(cb, 5) => {
                if caps.bios_ok {
                    cb.set_enabled(true);
                    cb.set_text("BIOS/CSM boot (grub4dos MBR, no reformat)");
                    if first {
                        cb.set_check_state(nwg::CheckBoxState::Checked);
                    }
                } else {
                    cb.set_enabled(false);
                    cb.set_check_state(nwg::CheckBoxState::Unchecked);
                    cb.set_text(&format!("BIOS boot (unavailable - {})", caps.bios_why));
                }
            }
            PageCtl::Check(cb, 6) => {
                if caps.uefi_ok {
                    cb.set_enabled(true);
                    cb.set_text("UEFI boot (BOOTX64.EFI, Secure Boot off)");
                    if first {
                        cb.set_check_state(nwg::CheckBoxState::Checked);
                    }
                } else {
                    cb.set_enabled(false);
                    cb.set_check_state(nwg::CheckBoxState::Unchecked);
                    cb.set_text(&format!("UEFI boot (unavailable - {})", caps.uefi_why));
                }
            }
            _ => {}
        }
    }
    refresh_fw_note(items);
}

/// Map a write-method radio label to its mode ("rufus" | "nofmt" | "skip").
/// Pure helper so the mapping is unit-testable (harvest itself needs live
/// Win32 controls and is covered by the win-install-page GUI test).
pub(crate) fn write_mode_from_label(t: &str) -> &'static str {
    let tl = t.to_lowercase();
    if tl.contains("non-destructive") {
        "nofmt"
    } else if tl.starts_with("skip") {
        "skip"
    } else {
        "rufus"
    }
}

/// Distro options (page 1 "Download Fresh" radios, from the PS GUI).
const DISTRO_OPTIONS: &[(&str, &str)] = &[
    (
        "Mint Cinnamon 22.x (64-bit)  (2GB/4GB)",
        "https://mirrors.kernel.org/linuxmint/stable/22.3/linuxmint-22.3-cinnamon-64bit.iso",
    ),
    (
        "Lubuntu 24.04 (64-bit, light)  (1GB/2GB)",
        "https://cdimage.ubuntu.com/lubuntu/releases/24.04/release/",
    ),
    (
        "Xubuntu 24.04 (64-bit, light-ish)  (1GB/2GB)",
        "https://cdimage.ubuntu.com/xubuntu/releases/24.04/release/",
    ),
    ("antiX 26 (i386 / 32-bit)  (0.25GB/1GB)", "https://antixlinux.com/download/"),
    ("Zorin OS (64-bit)  (2GB/4GB)", "https://zorin.com/os/download/"),
    (
        "Debian 13.6 live XFCE (64-bit)  (1GB/2GB)",
        "https://cdimage.debian.org/cdimage/release/13.6.0-live/amd64/iso-hybrid/debian-live-13.6.0-amd64-xfce.iso",
    ),
    (
        "Tiny CorePlus (32-bit, tiny)  (46MB/128MB)",
        "http://www.tinycorelinux.net/16.x/x86/release/CorePlus-current.iso",
    ),
];

pub fn recommended_distro() -> usize {
    let ram = sys::total_ram();
    if ram > 0 && ram <= 256 * sys::MB {
        return 6; // Tiny CorePlus
    }
    // CPU capability, not installed-OS bitness: the USB boots the bare
    // hardware, so 32-bit Windows on a 64-bit CPU still takes 64-bit ISOs.
    let is64 = is_64bit_capable();
    let ram_gb = ram as f64 / sys::GB as f64;
    if !is64 || ram_gb < 1.0 {
        3 // antiX
    } else if ram_gb < 2.0 {
        1 // Lubuntu
    } else {
        0 // Mint Cinnamon
    }
}

/// Machine 64-bit capability: 64-bit Windows proves it, otherwise ask the
/// CPU directly (IsWow64Process is blind on 32-bit Windows).
pub fn is_64bit_capable() -> bool {
    is_64bit_os() || sys::cpu_has_long_mode()
}

/// Guess an ISO's x86 arch from its filename: Some(true) = 64-bit,
/// Some(false) = 32-bit, None = no marker (treated as compatible).
/// Pure (unit-tested). Ordering matters: check 64-bit markers first so
/// "x86_64" is not misread as 32-bit "x86".
pub fn iso_arch_64(name: &str) -> Option<bool> {
    let n = name.to_ascii_lowercase();
    if n.contains("x86_64") || n.contains("amd64") || n.contains("64-bit") || n.contains("64bit") {
        Some(true)
    } else if n.contains("i386")
        || n.contains("i686")
        || n.contains("386")
        || n.contains("32-bit")
        || n.contains("32bit")
        || n.contains("x86")
    {
        Some(false)
    } else {
        None
    }
}

fn is_64bit_os() -> bool {
    // IsWow64Process, dynamically loaded; on 9x always false.
    if sys::is_9x() {
        return false;
    }
    type IsWow64Fn = unsafe extern "system" fn(winapi::um::winnt::HANDLE, *mut i32) -> i32;
    match sys::proc_from_module::<IsWow64Fn>("kernel32.dll", "IsWow64Process") {
        Some(f) => unsafe {
            let mut wow64: i32 = 0;
            let proc_handle = winapi::um::processthreadsapi::GetCurrentProcess();
            if f(proc_handle, &mut wow64) != 0 {
                wow64 != 0 // 32-bit process on 64-bit Windows => OS is 64-bit
            } else {
                false
            }
        },
        None => false, // pre-XP x86 => 32-bit OS
    }
}

pub fn recommendation_text() -> (String, String) {
    let ram_bytes = sys::total_ram();
    if ram_bytes > 0 && ram_bytes <= 256 * sys::MB {
        return (
            "Tiny CorePlus is the recommended option.".into(),
            format!(
                "Your machine has only {} MB of RAM. We recommend Tiny CorePlus, which needs as little as 46 MB and runs in 128 MB -- lighter than the minimalist 0.25 GB antiX. It is 32-bit, so it runs whether or not your machine supports 64-bit.",
                ram_bytes / sys::MB
            ),
        );
    }
    // Pure decision matrix (unit-tested below); probes stay at the edges.
    recommendation_for(is_64bit_capable(), is_64bit_os(), ram_bytes as f64 / sys::GB as f64)
}

/// Recommendation text from probed facts. `cpu64` = hardware long mode,
/// `os64` = installed Windows is 64-bit. The two differ on 32-bit Windows
/// atop a 64-bit CPU - where 64-bit live USBs still boot fine.
fn recommendation_for(cpu64: bool, os64: bool, ram_gb: f64) -> (String, String) {
    // 32-bit Windows on 64-bit hardware: say so once, then recommend
    // exactly as for 64-bit Windows (same ISOs boot).
    let wow_note = if cpu64 && !os64 {
        " Note: the Windows running here is 32-bit, but your CPU does support 64-bit, so 64-bit live USBs boot normally."
    } else {
        ""
    };
    if !cpu64 {
        (
            "antiX 26 is the recommended option.".into(),
            "Your machine does not support 64-bit and will not be able to run Cinnamon. We recommend antiX 26, which runs on old hardware that doesn't support 64-bit and has as little as 0.25 GB of RAM.".into(),
        )
    } else if ram_gb >= 4.0 {
        (
            "Linux Mint Cinnamon is the recommended option.".into(),
            format!(
                "Your machine supports 64-bit and has {:.0} GB of RAM, meeting Cinnamon's recommended 4 GB spec. There is no need to use the minimalist 0.25 GB antiX.{}",
                ram_gb, wow_note
            ),
        )
    } else if ram_gb >= 2.0 {
        (
            "Linux Mint Cinnamon is the recommended option.".into(),
            format!(
                "Your machine supports 64-bit and has {:.0} GB of RAM, meeting Cinnamon's minimum requirements of 2 GB, but not the recommended 4 GB. Consider enabling the experimental pagefile.sys swap. Your machine may be slow, but we still recommend Cinnamon over the minimalist 0.25 GB antiX.{}",
                ram_gb, wow_note
            ),
        )
    } else if ram_gb >= 1.0 {
        (
            "Lubuntu 24.04 is the recommended option (Xubuntu 24.04 also viable).".into(),
            format!(
                "Your machine supports 64-bit and has {:.0} GB of RAM (1-2 GB). We recommend Lubuntu 24.04, which is light enough for 1 GB. Xubuntu 24.04 is also a viable option on 1 GB, but it is a bit heavier and should still run.{}",
                ram_gb, wow_note
            ),
        )
    } else {
        (
            "antiX 26 is the recommended option.".into(),
            format!(
                "Your machine supports 64-bit, but only has {:.1} GB of RAM. We recommend the minimalist 0.25 GB antiX distro.{}",
                ram_gb, wow_note
            ),
        )
    }
}

// ---------------------------------------------------------------------------
// Background hardware rating thread messages
// ---------------------------------------------------------------------------
enum HwMsg {
    Row {
        class: String,
        support: String,
        rating: char,
        name: String,
        id: String,
        url: String,
    },
    /// Replace a row that was previously emitted with "Loading..." once the
    /// live linux-hardware.org fetch completes.
    UpdateRow {
        id: String,
        support: String,
        rating: char,
        name: String,
        url: String,
    },
    Progress(String),
    Done {
        a: u32,
        c: u32,
        d: u32,
        u: u32,
    },
    EverythingDone(bool),
    /// A page/directory distro URL (Lubuntu/Xubuntu `.../release/`) resolved
    /// to a direct ISO by the worker thread - the GUI thread starts the
    /// real background download (the Rc<Vec<BgDl>> is !Send, so the entry
    /// must be created here, not in the thread).
    DistroResolved { url: String, name: String, dir: String },
}

#[derive(Clone)]
struct HwRow {
    class: String,
    rating: char,
    support: String,
    name: String,
    id: String,
    url: String,
}

fn rating_key(r: char) -> u8 {
    match r {
        'A' => 0,
        'C' => 1,
        'D' => 2,
        '?' => 3,
        _ => 4,
    }
}

fn support_text(rating: char) -> &'static str {
    match rating {
        'A' => "in-kernel (works out of the box)",
        'C' => "needs out-of-tree driver",
        'D' => "no driver",
        '?' => "Loading...",
        _ => "unknown (no data)",
    }
}

fn spawn_hw_rating(tx: mpsc::Sender<HwMsg>, bundle_dir: String) {
    std::thread::spawn(move || {
        // Test hook: LSL_FAKE_HW=1 seeds a few fake rows so the www-globe
        // rendering can be verified without real hardware (the win95 VM
        // rates 0 devices, so the list would stay empty).
        if std::env::var("LSL_FAKE_HW").as_deref() == Ok("1") {
            for (class, rating, name, id) in [
                ("Display", 'A', "UHD Graphics 630", "pci\u{8086}_3ea0"),
                ("Ethernet", 'C', "RTL8111/8168 Gigabit", "pci\u{10ec}_8168"),
                ("Wireless", 'D', "RTL8188CE WLAN", "pci\u{10ec}_8178"),
                ("USB", 'A', "xHCI Host Controller", "pci\u{8086}_9d2f"),
            ] {
                let _ = tx.send(HwMsg::Row {
                    class: class.into(),
                    support: support_text(rating).to_string(),
                    rating,
                    name: name.into(),
                    id: id.into(),
                    url: format!("https://linux-hardware.org/?id={}", id),
                });
            }
            let _ = tx.send(HwMsg::Done { a: 2, c: 1, d: 1, u: 0 });
            return;
        }
        let devices = crate::hardware::compat_hardware();
        if devices.is_empty() {
            let _ = tx.send(HwMsg::Progress("No ratable devices found.".into()));
            let _ = tx.send(HwMsg::Done { a: 0, c: 0, d: 0, u: 0 });
            return;
        }
        let _ = tx.send(HwMsg::Progress(format!(
            "Rating {} device(s) against linux-hardware.org LKDDb...",
            devices.len()
        )));
        let (mut a, mut c, mut d, mut u) = (0u32, 0u32, 0u32, 0u32);
        let mut pending: Vec<crate::hardware::Device> = Vec::new();

        // Phase 1: instant cached display (compiled-in + on-disk)
        for dev in &devices {
            let url = crate::hardware::lhw_url(dev);
            if let Some(r) = crate::hardware::linux_compat_rating_cached(dev, &bundle_dir, (6, 8)) {
                match r.rating {
                    'A' => a += 1,
                    'C' => c += 1,
                    'D' => d += 1,
                    _ => u += 1,
                }
                let _ = tx.send(HwMsg::Row {
                    class: dev.class.clone(),
                    support: support_text(r.rating).to_string(),
                    rating: r.rating,
                    name: r.name,
                    id: dev.id.clone(),
                    url,
                });
            } else {
                pending.push(dev.clone());
                let _ = tx.send(HwMsg::Row {
                    class: dev.class.clone(),
                    support: support_text('?').to_string(),
                    rating: '?',
                    name: dev.name.clone(),
                    id: dev.id.clone(),
                    url,
                });
            }
        }

        if pending.is_empty() {
            let _ = tx.send(HwMsg::Done { a, c, d, u });
        } else {
            let _ = tx.send(HwMsg::Progress(format!(
                "Fetching details for {} device(s) from linux-hardware.org...",
                pending.len()
            )));
            // Phase 2: network fetch for uncached devices (10s crawl-delay each)
            for dev in pending {
                let url = crate::hardware::lhw_url(&dev);
                let r = crate::hardware::linux_compat_rating(&dev, &bundle_dir, (6, 8));
                match r.rating {
                    'A' => a += 1,
                    'C' => c += 1,
                    'D' => d += 1,
                    _ => u += 1,
                }
                let _ = tx.send(HwMsg::UpdateRow {
                    id: dev.id.clone(),
                    support: support_text(r.rating).to_string(),
                    rating: r.rating,
                    name: r.name,
                    url,
                });
                let _ = tx.send(HwMsg::Done { a, c, d, u });
            }
        }
    });
}


/// nwg 1.0.13's `insert_column` calls `column_len()`, which loops
/// `while LVM_GETCOLUMNWIDTH(count) != 0` — but comctl32 returns **-1** (not
/// 0) for an out-of-range index on real Windows, hanging the loop forever
/// (works under wine only because wine returns 0). Insert columns directly.
fn lv_insert_column_direct(lv: &nwg::ListView, index: usize, text: &str, width: i32) {
    // (Patch-Win95) ANSI column insert: Win95 comctl32 has no W-message
    // support and SendMessageW itself is a stub.
    use winapi::um::commctrl::{LVM_INSERTCOLUMNA, LVCOLUMNA, LVCF_TEXT, LVCF_WIDTH};
    use winapi::um::winuser::SendMessageA;
    let Some(hwnd) = lv.handle.hwnd() else { return };
    let mut atext: Vec<u8> = text.bytes().collect();
    atext.push(0);
    let mut col: LVCOLUMNA = unsafe { std::mem::zeroed() };
    col.mask = LVCF_TEXT | LVCF_WIDTH;
    col.cx = width;
    col.pszText = atext.as_mut_ptr() as *mut i8;
    col.cchTextMax = atext.len() as i32;
    unsafe {
        SendMessageA(hwnd, LVM_INSERTCOLUMNA, index as usize, &col as *const LVCOLUMNA as isize);
    }
}


/// Custom-draw styling for the hardware ListView's www column (subitem 4):
/// the cell text ("link") paints blue and underlined, like a hyperlink.
/// The listview draws the text itself - the handler only supplies the color
/// and selects an underlined font (CDRF_NEWFONT uses the font currently
/// selected into the HDC). ANSI font APIs throughout: Win95's comctl32 has
/// no W-message support (see nwg-test/vendor/.../README-WIN95.md).
unsafe extern "system" fn hw_custom_draw_proc(
    hwnd: winapi::shared::windef::HWND,
    msg: winapi::shared::minwindef::UINT,
    w: winapi::shared::minwindef::WPARAM,
    l: winapi::shared::minwindef::LPARAM,
    _id: usize,
    _data: winapi::shared::basetsd::DWORD_PTR,
) -> winapi::shared::minwindef::LRESULT {
    use winapi::shared::windef::HFONT;
    use winapi::um::commctrl::{
        CDDS_ITEMPREPAINT, CDDS_PREPAINT, CDDS_SUBITEM, CDRF_DODEFAULT, CDRF_NEWFONT,
        CDRF_NOTIFYSUBITEMDRAW, NM_CUSTOMDRAW, NMLVCUSTOMDRAW,
    };
    use winapi::um::wingdi::{
        CreateFontIndirectA, GetCurrentObject, GetObjectA, SelectObject, LOGFONTA, OBJ_FONT,
    };
    use winapi::um::commctrl::DefSubclassProc;
    use winapi::um::winuser::WM_NOTIFY;
    if msg == WM_NOTIFY {
        // explicit blocks: unsafe ops in an unsafe-fn body need them
        // on this toolchain (E0133)
        let nmh = unsafe { &*(l as *const winapi::um::winuser::NMHDR) };
        // Only handle notifications from the hardware listview itself (the
        // header control sends its own NM_CUSTOMDRAW that must be left alone)
        if nmh.hwndFrom as usize == *LV_HW_HWND.get().unwrap_or(&0) && nmh.code == NM_CUSTOMDRAW {
            // NOTE: CDDS_ITEMPREPAINT|CDDS_SUBITEM is the VALUE 0x30000 — it
            // must be compared, not used as an or-pattern (which would match
            // either constant alone and never the combined stage).
            let nmcd = unsafe { &*(l as *const NMLVCUSTOMDRAW) };
            let stage = nmcd.nmcd.dwDrawStage;
            if stage == CDDS_PREPAINT {
                return CDRF_NOTIFYSUBITEMDRAW as _;
            }
            if stage == (CDDS_ITEMPREPAINT | CDDS_SUBITEM) {
                if nmcd.iSubItem == 4 {
                    // Hyperlink look: blue text, underlined font. The
                    // control paints the "link" cell text itself with
                    // these attributes (CDRF_NEWFONT).
                    unsafe { (*(l as *mut NMLVCUSTOMDRAW)).clrText = 0x00FF_0000; } // COLORREF = 0x00BBGGRR
                    let hfont = *UNDERLINE_FONT.get_or_init(|| {
                        // Derive from the listview's own font so size/DPI
                        // track the control (ANSI APIs: Win95-safe).
                        unsafe {
                            let cur = GetCurrentObject(nmcd.nmcd.hdc, OBJ_FONT);
                            let mut lf: LOGFONTA = std::mem::zeroed();
                            let ok = GetObjectA(
                                cur,
                                std::mem::size_of::<LOGFONTA>() as i32,
                                &mut lf as *mut LOGFONTA as *mut winapi::ctypes::c_void,
                            );
                            if ok == 0 {
                                return 0;
                            }
                            lf.lfUnderline = 1;
                            CreateFontIndirectA(&lf) as usize
                        }
                    }) as HFONT;
                    if !hfont.is_null() {
                        unsafe {
                            SelectObject(nmcd.nmcd.hdc, hfont as *mut winapi::ctypes::c_void);
                        }
                    }
                    return CDRF_NEWFONT as _;
                }
                return CDRF_DODEFAULT as _;
            }
            // Some listview/comctl stacks skip the subitem descent after
            // CDDS_PREPAINT; requesting subitem notification at the item
            // stage as well makes them descend.
            if stage == CDDS_ITEMPREPAINT {
                return CDRF_NOTIFYSUBITEMDRAW as _;
            }
        }
    }
    unsafe { DefSubclassProc(hwnd, msg, w, l) }
}

static LV_HW_HWND: std::sync::OnceLock<usize> = std::sync::OnceLock::new();

/// Underlined listview font for the www hyperlink cells, created once from
/// the control's own font (stored as usize: raw HFONT is !Sync). Leaks one
/// GDI object for the process lifetime by design - deleting it would need a
/// hook after every paint.
static UNDERLINE_FONT: std::sync::OnceLock<usize> = std::sync::OnceLock::new();

fn install_hw_custom_draw(lv: &nwg::ListView, frame: &nwg::Frame) {
    // NM_CUSTOMDRAW notifications are sent to the listview's PARENT (the
    // frame), so the subclass must be installed there.
    if let (Some(_lv_hwnd), Some(frame_hwnd)) = (lv.handle.hwnd(), frame.handle.hwnd()) {
        let _ = LV_HW_HWND.set(_lv_hwnd as usize);
        glog("custom draw installed");
        unsafe {
            winapi::um::commctrl::SetWindowSubclass(
                frame_hwnd,
                Some(hw_custom_draw_proc),
                0x4C56, // 'LV'
                0,
            );
        }
    }
}

// ---------------------------------------------------------------------------
// Layout engine
// ---------------------------------------------------------------------------
// All geometry derives from the live CLIENT size in one place (`relayout`),
// so the window opens work-area-sized on small screens and relayouts on
// WM_SIZE. Keep literals out of the page builders: any control's final
// geometry is set by relayout, not by its builder.
const MARGIN: i32 = 12; // window-side margin
const NAV_H: i32 = 66; // bottom strip: download-label band (20) + gaps + nav buttons (28) + margin
const DEF_CW: i32 = 880; // default client size (the old fixed size)
const DEF_CH: i32 = 760;
const MIN_CW: i32 = 600; // smallest usable client (fits 640x480 boxes)
const MIN_CH: i32 = 380;
/// Dev accelerator: Ctrl+Alt+B jumps straight to the INSTALL page with the
/// built-in non-destructive method preselected, so repeat nofmt test runs
/// skip five Next clicks plus the radio hunt. Jump-only by design: it
/// never clicks Install (write-mode default may be Rufus and the target
/// pick deserves eyes before anything destructive). Unregistered on window
/// close AND on WorkingUi::close (the post-Install destroy path never fires
/// OnWindowClose) so the combo is never swallowed with a dead target.
const INSTALL_HOTKEY_ID: i32 = 0x5A17;

// Work area + outer-frame chrome, measured once; the WM_GETMINMAXINFO
// handler reads these (it can fire before the window is fully created).
static WORK_AREA: std::sync::OnceLock<(i32, i32, i32, i32)> = std::sync::OnceLock::new();
static CHROME: std::sync::OnceLock<(i32, i32)> = std::sync::OnceLock::new();

/// SPI_GETWORKAREA: screen minus the taskbar (640x452 on a 640x480 Win9x
/// desktop). Falls back to the classic minimum resolution.
fn work_area() -> (i32, i32, i32, i32) {
    use winapi::shared::windef::RECT;
    use winapi::um::winuser::{SystemParametersInfoW, SPI_GETWORKAREA};
    unsafe {
        let mut r: RECT = std::mem::zeroed();
        if SystemParametersInfoW(SPI_GETWORKAREA, 0, &mut r as *mut RECT as *mut winapi::ctypes::c_void, 0)
            != 0
            && r.right > r.left
            && r.bottom > r.top
        {
            (r.left, r.top, r.right, r.bottom)
        } else {
            (0, 0, 640, 480)
        }
    }
}

/// (outer - client) of a window: (extra width, extra height) of title bar +
/// borders, so client sizes can be clamped against the work area.
fn window_chrome(hwnd: winapi::shared::windef::HWND) -> (i32, i32) {
    use winapi::um::winuser::{GetClientRect, GetWindowRect};
    unsafe {
        let (mut wr, mut cr) = (std::mem::zeroed(), std::mem::zeroed());
        GetWindowRect(hwnd, &mut wr);
        GetClientRect(hwnd, &mut cr);
        (
            (wr.right - wr.left) - (cr.right - cr.left),
            (wr.bottom - wr.top) - (cr.bottom - cr.top),
        )
    }
}

fn client_size(hwnd: winapi::shared::windef::HWND) -> (i32, i32) {
    use winapi::um::winuser::GetClientRect;
    unsafe {
        let mut cr: winapi::shared::windef::RECT = std::mem::zeroed();
        GetClientRect(hwnd, &mut cr);
        (cr.right - cr.left, cr.bottom - cr.top)
    }
}

/// Position + size a raw HWND (as usize).
fn set_ctl_rect(h: usize, x: i32, y: i32, w: i32, hpx: i32) {
    use winapi::um::winuser::{SetWindowPos, HWND_TOP, SWP_NOZORDER};
    if h == 0 || !is_window(h) {
        return;
    }
    unsafe {
        SetWindowPos(
            h as winapi::shared::windef::HWND,
            HWND_TOP,
            x,
            y,
            w.max(1),
            hpx.max(1),
            SWP_NOZORDER,
        );
    }
}

/// Put `text` on the clipboard as ANSI text (CF_TEXT — the only format
/// Win95 reliably supports; a command line / error message is ASCII).
fn copy_to_clipboard(text: &str) {
    use winapi::um::winuser::{
        CloseClipboard, EmptyClipboard, OpenClipboard, SetClipboardData, CF_TEXT,
    };
    use winapi::um::winbase::{GlobalAlloc, GMEM_MOVEABLE, GMEM_ZEROINIT};
    unsafe {
        if OpenClipboard(std::ptr::null_mut()) == 0 {
            return;
        }
        EmptyClipboard();
        // ANSI bytes, NUL-terminated
        let mut bytes: Vec<u8> = text.bytes().collect();
        bytes.push(0);
        let h = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, bytes.len());
        if !h.is_null() {
            let p = winapi::um::winbase::GlobalLock(h);
            if !p.is_null() {
                std::ptr::copy_nonoverlapping(bytes.as_ptr(), p as *mut u8, bytes.len());
                winapi::um::winbase::GlobalUnlock(h);
                SetClipboardData(CF_TEXT, h);
            }
        }
        CloseClipboard();
    }
}

/// First http(s) URL in `text` (for the "Open manual download" button).
fn first_url(text: &str) -> Option<String> {
    for needle in ["https://", "http://"] {
        if let Some(i) = text.find(needle) {
            let rest = &text[i..];
            let end = rest
                .find(|c: char| c.is_whitespace())
                .unwrap_or(rest.len());
            return Some(rest[..end].to_string());
        }
    }
    None
}

/// Bottom-strip geometry from the client height: pages must end at or
/// above `pages_end`, the "Downloading ..." label owns [label_y,
/// label_y + label_h), and the progress bar sits inside the button row.
/// Pure so the no-overlap rule is unit-testable (see
/// bottom_bands_never_overlap); relayout applies it. The label gets a full
/// 20px line (the codebase's own single-line metric is 18px) so descenders
/// ('g', 'y', ...) never touch the rows above or below, at any font size
/// the band layout supports.
pub(crate) fn bottom_bands(ch: i32) -> (i32, i32, i32, i32, i32, i32, i32) {
    let pages_end = ch - NAV_H;
    let label_y = ch - NAV_H + 2;
    let label_h = 20;
    let btn_y = ch - MARGIN - 28;
    let btn_h = 28;
    let bar_y = btn_y + 7;
    let bar_h = 14;
    (pages_end, label_y, label_h, bar_y, bar_h, btn_y, btn_h)
}
/// Wrapped height for a label showing `text` in width `w` (18 px per line
/// + 6 px padding). Uses the EXACT greedy word-wrap loop as wrap_text, so
/// the height can never disagree with the rendered breaks and clip the
/// last line (observed: the rec-help text clipped after "There is").
/// 9px/char stays deliberately conservative (real dialog-font average is
/// ~8.5px); an optimistic estimate re-wraps into lines that do not fit.
fn text_h(text: &str, w: i32) -> i32 {
    let per_line = (((w - 8) / 9).max(10)) as usize;
    (wrap_line_count(text, per_line) as i32 * 18 + 6).max(18)
}

/// Greedy wrapped-line count shared by wrap_text (rendering) and text_h
/// (height): explicit \n breaks plus word-wrap at `per_line` chars.
/// Pure (unit-tested).
fn wrap_line_count(text: &str, per_line: usize) -> usize {
    let mut lines = 0usize;
    for logical in text.split('\n') {
        let mut line = 0usize;
        let mut wrapped = 1usize;
        for (i, word) in logical.split(' ').enumerate() {
            let wl = word.chars().count();
            if i > 0 && line + 1 + wl > per_line {
                wrapped += 1;
                line = 0;
            } else if i > 0 {
                line += 1;
            }
            line += wl;
        }
        lines += wrapped;
    }
    lines.max(1)
}

/// Word-wrap `text` to `per_line` chars with \r\n (labels only honor
/// explicit breaks reliably across comctl versions/wine).
fn wrap_text(text: &str, per_line: usize) -> String {
    let mut out = String::new();
    let mut line = 0usize;
    for (i, word) in text.split(' ').enumerate() {
        let wl = word.chars().count();
        if i > 0 && line + 1 + wl > per_line {
            out.push_str("\r\n");
            line = 0;
        } else if i > 0 {
            out.push(' ');
            line += 1;
        }
        out.push_str(word);
        line += wl;
    }
    out
}

/// System-page pagefile-reclaim note (multi-line label; covered by the
/// multiline-label contract test below - keep in sync if reworded).
pub(crate) const PAGEFILE_NOTE: &str = "Renames pagefile.sys and each WSL2 swapfile.vhdx (after a clean-shutdown check) and uses that space as compressed swap. Used only if Windows was shut down normally (no Fast Startup / hibernate) - otherwise the reclaim is skipped entirely.";

/// One control on a scrollable page. Built straight into the Box so the
/// win32 control has exactly one owner (nwg's Drop DESTROYS the window, so
/// nwg controls must never be cloned-and-kept — see the ScrollBar note in
/// run_gui).
pub(crate) enum PageCtl {
    Lbl(Box<nwg::Label>, u8),
    Check(Box<nwg::CheckBox>, u8),
    Radio(Box<nwg::RadioButton>, u8),
    Edit(Box<nwg::TextBox>, u8),
    EditLine(Box<nwg::TextInput>, u8),
    Btn(Box<nwg::Button>, u8),
}

/// Kind tags (harvest + handler routing):
///   ISO page:  Radio 0=distro 1=local iso 2=existing usb (one group per
///              section: the FIRST radio of each section carries WS_GROUP, so
///              Win32 auto-unchecks only the siblings of that section);
///              Check (none); Lbl 0
///   FP page:   Check 0=app 1=fsearch; Lbl 1=extra caption; Edit 1=extra ids
///   SYS page:  Edit 1=vhdx 2=data dir; Btn 3=browse; Check 4=efu 5=drivers
///              6=sfs 7=reclaim 8=rust tools; Lbl 0
///   WIFI page: Check 9=wifi master; Lbl 0
///
/// A scrollable-page item: control + placement in the scroll space.
/// x < 0 → right-aligned (x = frame_w + x). w > 0 → fixed width;
/// w <= 0 → right edge at frame_w - 10 + w (0 = full fill).
pub(crate) struct PageItem {
    ctl: PageCtl,
    x: i32,
    y: i32, // base y in scroll space (before offset/shift)
    w: i32,
    h: i32,
    idx: usize, // FP grid slot (column-major index); 0 elsewhere
}

pub(crate) type PageItems = Rc<std::cell::RefCell<Vec<PageItem>>>;

fn ctl_kind(ctl: &PageCtl) -> u8 {
    match ctl {
        PageCtl::Lbl(_, k) | PageCtl::Check(_, k) | PageCtl::Radio(_, k) | PageCtl::Edit(_, k) | PageCtl::EditLine(_, k) | PageCtl::Btn(_, k) => *k,
    }
}

/// Position + size one page item at scroll offset `off` (plus `shift`, used
/// by the ISO page when its wrapped help text is taller than at build time).
/// Items outside the scroll band [top, bot_edge] are HIDDEN: without this a
/// static/checkbox paints right over the fixed header/bottom strips (there
/// is no viewport clipping — Win32 just clips at the frame border).
fn layout_page(items: &PageItems, fw: i32, off: i32, shift: i32, top: i32, bot_edge: i32) {
    for it in items.borrow().iter() {
        let x = if it.x < 0 { fw + it.x } else { it.x };
        let w = if it.w > 0 { it.w } else { (fw - 10 + it.w - x).max(60) };
        let y = it.y + shift - off;
        let show = y >= top - 4 && y + it.h <= bot_edge + 4;
        macro_rules! place {
            ($b:expr) => {{
                $b.set_visible(show);
                $b.set_position(x, y);
                $b.set_size(w as u32, it.h as u32);
            }};
        }
        match &it.ctl {
            PageCtl::Lbl(b, _) => place!(b),
            PageCtl::Check(b, _) => place!(b),
            PageCtl::Radio(b, _) => place!(b),
            PageCtl::Edit(b, _) => place!(b),
            PageCtl::EditLine(b, _) => place!(b),
            PageCtl::Btn(b, _) => place!(b),
        }
    }
}

/// Scroll geometry for a page: (visible height, max offset, top band edge,
/// bottom band edge, shift). The page scrolls whenever the item stack is
/// taller than the frame; the band edges are the visibility-cull bounds.
fn page_geom(fh: i32, top: i32, bot: i32, content: i32, shift: i32) -> (i32, i32, i32, i32, i32) {
    let visible = (fh - top - bot).max(20);
    let max_off = (content + shift - (fh - bot)).max(0);
    (visible, max_off, top, fh - bot, shift)
}

/// HWND (as usize) of the first item with `kind` — used to route clicks to
/// controls that live inside the shared page storage.
fn ctl_hwnd(items: &PageItems, kind: u8) -> Option<usize> {
    for it in items.borrow().iter() {
        if ctl_kind(&it.ctl) == kind {
            let hwnd = match &it.ctl {
                PageCtl::Lbl(b, _) => b.handle.hwnd(),
                PageCtl::Check(b, _) => b.handle.hwnd(),
                PageCtl::Radio(b, _) => b.handle.hwnd(),
                PageCtl::Edit(b, _) => b.handle.hwnd(),
                PageCtl::EditLine(b, _) => b.handle.hwnd(),
                PageCtl::Btn(b, _) => b.handle.hwnd(),
            };
            return hwnd.map(|h| h as usize);
        }
    }
    None
}

/// WM_VSCROLL raw handler for one page's scrollbar. WM_VSCROLL from a
/// scrollbar control is sent to its PARENT window (the frame); nwg's built-in
/// scroll hook never made it past our subclass chain, so each scrollable
/// frame gets its own raw handler that owns the position math. The handler
/// only owns Rc clones + a copy of the scrollbar HWND — the ScrollBar itself
/// stays in run_gui's scope (dropping a moved ScrollBar DESTROYS the window).
fn bind_page_scroll(
    frame: &nwg::Frame,
    id: usize,
    sb_hwnd: Option<winapi::shared::windef::HWND>,
    items: PageItems,
    geom: Rc<Cell<(i32, i32, i32, i32, i32)>>, // (vis, max_off, top, bot_edge, shift)
    off: Rc<Cell<i32>>,
    fw: Rc<Cell<i32>>,
) -> nwg::RawEventHandler {
    nwg::bind_raw_event_handler(&frame.handle, id, move |_, msg, w, l| {
        use winapi::shared::minwindef::LOWORD;
        use winapi::shared::windef::HWND;
        use winapi::um::winuser::{
            GetScrollInfo, SCROLLINFO, SetScrollInfo, SIF_ALL, SIF_POS, SB_CTL, SB_LINEUP,
            SB_LINEDOWN, SB_PAGEUP, SB_PAGEDOWN, SB_THUMBPOSITION, SB_THUMBTRACK, WM_VSCROLL,
        };
        if msg != WM_VSCROLL {
            return None;
        }
        let sb_hwnd = match sb_hwnd {
            Some(h) => h,
            None => return None,
        };
        if l as HWND != sb_hwnd {
            return None;
        }
        let (vis, max_off, top, bot_edge, shift) = geom.get();
        let mut si: SCROLLINFO = unsafe { std::mem::zeroed() };
        si.cbSize = std::mem::size_of::<SCROLLINFO>() as u32;
        si.fMask = SIF_ALL;
        unsafe {
            GetScrollInfo(sb_hwnd, SB_CTL as i32, &mut si);
        }
        let max_pos = si.nMax.saturating_sub(1).max(0);
        let page = (vis / 20).max(1);
        let new_pos = match LOWORD(w as u32) as i32 {
            x if x == SB_LINEUP as i32 => si.nPos - 1,
            x if x == SB_LINEDOWN as i32 => si.nPos + 1,
            x if x == SB_PAGEUP as i32 => si.nPos - page,
            x if x == SB_PAGEDOWN as i32 => si.nPos + page,
            x if x == SB_THUMBTRACK as i32 || x == SB_THUMBPOSITION as i32 => si.nTrackPos,
            _ => si.nPos,
        }
        .clamp(0, max_pos);
        si.fMask = SIF_POS;
        si.nPos = new_pos;
        unsafe {
            SetScrollInfo(sb_hwnd, SB_CTL as _, &si, 1);
        }
        let new_off = (new_pos * 20).min(max_off);
        glog(&format!("scroll new={} off={}", new_pos, new_off));
        layout_page(&items, fw.get(), new_off, shift, top, bot_edge);
        // stale pixels of moved items would linger; erase the page
        let ph = unsafe { winapi::um::winuser::GetParent(sb_hwnd) };
        if !ph.is_null() {
            unsafe {
                winapi::um::winuser::InvalidateRect(ph, std::ptr::null(), 1);
            }
        }
        off.set(new_off);
        Some(0)
    })
    .expect("bind page scroll handler")
}

/// Base y of the first per-network checkbox in the wifi scroll space.
const WIFI_Y0: i32 = 54;

/// Wifi-page checkboxes ride the wifi scroll space below the fixed items.
fn place_wifi(
    wifi: &std::cell::RefCell<Vec<Box<nwg::CheckBox>>>,
    fw: i32,
    off: i32,
    top: i32,
    bot_edge: i32,
    y0: i32,
) {
    for (i, cb) in wifi.borrow().iter().enumerate() {
        let y = y0 + (i as i32) * 20 - off;
        cb.set_visible(y >= top - 4 && y + 20 <= bot_edge + 4);
        cb.set_position(20, y);
        cb.set_size((fw - 60).max(160) as u32, 20);
    }
}

/// FP page: reflow the app grid (column count from width, rows from count)
/// and move the extras below it; stores the new content height in fp_content.
fn relayout_fp(fp: &PageItems, fp_content: &Cell<i32>, fw: i32, fh: i32) {
    let (n_grid, rows_fit, max_cols) = {
        let items = fp.borrow();
        let n_grid = items
            .iter()
            .filter(|it| matches!(&it.ctl, PageCtl::Check(_, 0)))
            .count();
        (
            n_grid,
            (((fh - 130) / 24).max(1)) as usize,
            (((fw - 20) / 240).max(1)) as usize,
        )
    };
    let cols = (((n_grid + rows_fit - 1) / rows_fit).max(1)).min(max_cols);
    let rows = ((n_grid + cols - 1) / cols).max(1);
    let colw = (fw - 20) / cols as i32;
    let mut items = fp.borrow_mut();
    let mut max_y = 30i32;
    for it in items.iter_mut() {
        if matches!(&it.ctl, PageCtl::Check(_, 0)) {
            let col = (it.idx / rows) as i32;
            let row = (it.idx % rows) as i32;
            it.x = 10 + col * colw;
            it.y = 30 + row * 24;
            it.w = (colw - 6).max(120);
            max_y = max_y.max(it.y + 24);
        }
    }
    // extras below the used rows of the grid
    let yb = 30 + rows as i32 * 24 + 2; // rows == ceil(n_grid/cols) by construction
    for it in items.iter_mut() {
        let k = ctl_kind(&it.ctl);
        let is_chk = matches!(&it.ctl, PageCtl::Check(_, _));
        let is_lbl = matches!(&it.ctl, PageCtl::Lbl(_, _));
        let is_edit = matches!(&it.ctl, PageCtl::Edit(_, _));
        if is_chk && k == 1 {
            it.x = 10;
            it.y = yb;
            it.w = -20;
            it.h = 20;
        } else if is_lbl && k == 1 {
            it.x = 10;
            it.y = yb + 26;
            it.w = -20;
            it.h = 18;
        } else if is_edit && k == 1 {
            it.x = 10;
            it.y = yb + 46;
            it.w = -20;
            it.h = 76; // 4 lines deep
            max_y = max_y.max(it.y + it.h);
        }
    }
    fp_content.set(max_y + 10);
}

/// Everything the relayout pass needs. Borrowed from run_gui's scope (the
/// full-bind event closure constructs it from the controls it owns).
struct LayoutCtx<'a> {
    lbl_sb: &'a nwg::Label,
    sb_text: &'a str,
    frame_hw: &'a nwg::Frame,
    frame_iso: &'a nwg::Frame,
    frame_fp: &'a nwg::Frame,
    frame_sys: &'a nwg::Frame,
    frame_wifi: &'a nwg::Frame,
    frame_install: &'a nwg::Frame,
    lbl_hw: &'a nwg::Label,
    lv_hw: &'a nwg::ListView,
    lbl_rec: &'a nwg::Label,
    lbl_rec_help: &'a nwg::Label,
    rec_help_text: &'a str,
    lbl_fp: &'a nwg::Label,
    sb_iso: &'a nwg::ScrollBar,
    sb_fp: &'a nwg::ScrollBar,
    sb_sys: &'a nwg::ScrollBar,
    sb_wifi: &'a nwg::ScrollBar,
    sb_install: &'a nwg::ScrollBar,
    btn_everything: &'a nwg::Button,
    btn_back: &'a nwg::Button,
    btn_next: &'a nwg::Button,
    btn_cancel: &'a nwg::Button,
    btn_reboot: &'a nwg::Button,
    lbl_dl: &'a nwg::Label,
    pb_dl: &'a nwg::ProgressBar,
    iso: &'a PageItems,
    fp: &'a PageItems,
    sys: &'a PageItems,
    wifi_items: &'a PageItems,
    install: &'a PageItems,
    wifi: &'a std::cell::RefCell<Vec<Box<nwg::CheckBox>>>,
    fw: &'a Cell<i32>,
    iso_off: &'a Cell<i32>,
    fp_off: &'a Cell<i32>,
    sys_off: &'a Cell<i32>,
    wifi_off: &'a Cell<i32>,
    install_off: &'a Cell<i32>,
    iso_geom: &'a Cell<(i32, i32, i32, i32, i32)>,
    fp_geom: &'a Cell<(i32, i32, i32, i32, i32)>,
    sys_geom: &'a Cell<(i32, i32, i32, i32, i32)>,
    wifi_geom: &'a Cell<(i32, i32, i32, i32, i32)>,
    install_geom: &'a Cell<(i32, i32, i32, i32, i32)>,
    fp_content: &'a Cell<i32>,
    guard: &'a Cell<bool>,
    iso_content: i32,
    sys_content: i32,
    wifi_content: i32,
    install_content: i32,
}

/// The one pass that positions EVERY control from the client size (cw, ch).
fn relayout(c: &LayoutCtx, cw: i32, ch: i32) {
    if c.guard.get() {
        return; // re-entrant OnResize from our own child SetWindowPos calls
    }
    c.guard.set(true);
    let fw = cw - 2 * MARGIN;
    let sb_h = text_h(c.sb_text, fw);
    let top = 10 + sb_h + 14; // header strip: secure-boot label + gap
    let fh = ch - top - NAV_H;
    c.fw.set(fw);

    // window-level (long labels are pre-wrapped to the current width; a
    // bare SS_LEFT static may not re-wrap on every comctl stack)
    let sb_per_line = (((fw - 8) / 9).max(10)) as usize;
    c.lbl_sb.set_text(&wrap_text(c.sb_text, sb_per_line));
    c.lbl_sb.set_position(MARGIN, 10);
    c.lbl_sb.set_size(fw as u32, sb_h as u32);
    for f in [c.frame_hw, c.frame_iso, c.frame_fp, c.frame_sys, c.frame_wifi, c.frame_install] {
        f.set_position(MARGIN, top);
        f.set_size(fw as u32, fh.max(60) as u32);
    }

    // nav strip: Next bottom-right, Back left of it, Cancel bottom-left;
    // the "Downloading ..." label + bar share the strip in their own
    // bands (bottom_bands: unit-tested no-overlap, descender-safe).
    let (_pages_end, label_y, label_h, bar_y, bar_h, ny, _btn_h) = bottom_bands(ch);
    c.btn_next.set_position(cw - MARGIN - 96, ny);
    c.btn_next.set_size(96, 28);
    c.btn_back.set_position(cw - MARGIN - 96 - 96, ny);
    c.btn_back.set_size(90, 28);
    c.btn_reboot.set_position(8, ny);
    c.btn_reboot.set_size(90, 28);
    let cancel_x = if c.btn_reboot.visible() { 8 + 90 + 8 } else { 8 };
    c.btn_cancel.set_position(cancel_x, ny);
    c.btn_cancel.set_size(90, 28);

    // persistent download progress ("Downloading {}-..." label + bar):
    // owned bands that touch neither the scrollable pages above nor the
    // buttons below, at ANY window size - geometry comes from bottom_bands
    // (unit-tested no-overlap). The label gets the full-width band to
    // itself (long file names clip instead of overlapping); the bar rides
    // the button row in the free middle between Cancel (left) and Back.
    c.lbl_dl.set_position(MARGIN, label_y);
    c.lbl_dl.set_size(fw as u32, label_h as u32);
    let bar_x0 = cancel_x + 90 + 12;
    let bar_x1 = cw - MARGIN - 96 - 96 - 10;
    // MIN_CW guarantees room, but clamp anyway so a sub-minimum window
    // can only clip the bar, never push it under a button.
    let bar_w = (bar_x1 - bar_x0).max(50);
    c.pb_dl.set_position(bar_x0, bar_y);
    c.pb_dl.set_size(bar_w as u32, bar_h as u32);

    // page 0 (hardware): the ListView scrolls natively, so it just fills
    c.lbl_hw.set_position(10, 6);
    c.lbl_hw.set_size((fw - 20) as u32, 20);
    c.lv_hw.set_position(10, 30);
    c.lv_hw.set_size((fw - 20) as u32, (fh - 40).max(40) as u32);

    // ISO page's fixed header: recommendation + wrapped help text
    c.lbl_rec.set_position(10, 4);
    c.lbl_rec.set_size((fw - 40) as u32, 18);
    c.lbl_rec_help.set_text(&wrap_text(
        c.rec_help_text,
        (((fw - 48) / 9).max(10)) as usize,
    ));
    c.lbl_rec_help.set_position(10, 22);
    let rec_h = text_h(c.rec_help_text, fw - 48);
    c.lbl_rec_help.set_size((fw - 40) as u32, rec_h as u32);
    c.lbl_fp.set_position(10, 6);
    c.lbl_fp.set_size((fw - 20) as u32, 18);

    // FP grid reflow FIRST (it computes fp_content, needed by the loop)
    relayout_fp(c.fp, c.fp_content, fw, fh);

    // ISO page bottom row: just the Everything button
    let iso_bot = 44;
    c.btn_everything.set_position(10, fh - 34);
    c.btn_everything.set_size(400, 26);


    // scrollable pages 1-5: geometry, scrollbar, items
    // (top = fixed strip above the scroll area, bot = fixed strip below)
    let iso_top = (22 + rec_h + 10).max(72);
    let iso_shift = (iso_top - 72).max(0); // push items below a taller help text
    let pages = [
        (c.sb_iso, c.iso, c.iso_off, c.iso_geom, c.iso_content, iso_top, iso_bot, iso_shift),
        (c.sb_fp, c.fp, c.fp_off, c.fp_geom, c.fp_content.get(), 30, 32, 0),
        (c.sb_sys, c.sys, c.sys_off, c.sys_geom, c.sys_content, 4, 32, 0),
        (c.sb_wifi, c.wifi_items, c.wifi_off, c.wifi_geom, c.wifi_content, 4, 32, 0),
        (c.sb_install, c.install, c.install_off, c.install_geom, c.install_content, 4, 32, 0),
    ];
    for (sb, items, off, geom, content, top, bot, shift) in pages {
        let (vis, max_off, top, bot_edge, shift) = page_geom(fh, top, bot, content, shift);
        geom.set((vis, max_off, top, bot_edge, shift));
        off.set(off.get().min(max_off));
        // Only show the vertical scrollbar when the page doesn't fit
        // vertically (max_off > 0); otherwise hide it so the content uses
        // the full width.
        sb.set_visible(max_off > 0);
        let units = (((max_off as f64) / 20.0).ceil() as usize).max(1);
        sb.set_range(0..units);
        sb.set_size(18, (fh - 8).max(20) as u32);
        sb.set_position(fw - 22, 4);
        layout_page(items, fw, off.get(), shift, top, bot_edge);
    }

    // WIFI page network list rides the wifi scroll space
    place_wifi(c.wifi, fw, c.wifi_off.get(), 4, fh - 12, WIFI_Y0);
    c.guard.set(false);
}

/// Floor for "the ISO is complete": Mint 22.x Cinnamon 64-bit is ~2.9 GB,
/// so a 2.5 GB floor excludes truncated downloads while accepting any real
/// release of this version.
const MIN_ISO_SIZE: u64 = 2_500_000_000;

/// An up-to-date, right-sized local ISO for `name` (e.g.
/// linuxmint-22.3-cinnamon-64bit.iso): the file name must contain the
/// version-carrying stem ("up-to-date") and the size must clear
/// MIN_ISO_SIZE ("right size").
fn find_matching_local_iso(name: &str, min_bytes: u64) -> Option<String> {
    let stem = name.trim_end_matches(".iso").to_lowercase();
    let mut v = crate::lslfiles::find_everything_isos();
    if v.is_empty() {
        v = crate::lslfiles::find_local_isos();
    }
    for p in v {
        let base = p.rsplit('\\').next().unwrap_or("").to_lowercase();
        if base.contains(&stem) && sys::file_size(&p).map(|s| s >= min_bytes).unwrap_or(false) {
            return Some(p);
        }
    }
    None
}

/// The wizard. `mint_version` parameterizes the Mint download URL.
/// A background ISO download started the moment the user selects a
/// "Download Fresh" distro in the wizard (PowerShell-version behaviour:
/// the file downloads while the user configures the remaining pages, and
/// the console step after "Install" just waits for it to finish).
struct BgDl {
    dest: String,
    prog: std::sync::Arc<std::sync::atomic::AtomicU64>,
    total: std::sync::Arc<std::sync::atomic::AtomicU64>,
    finished: std::sync::Arc<std::sync::atomic::AtomicBool>,
    rx: std::sync::mpsc::Receiver<Result<(), String>>,
}

/// Start downloading `url` to <download_dir>\<name> in a background thread.
/// A page/directory URL (Lubuntu/Xubuntu `.../release/`) is resolved to the
/// current desktop ISO first, on a worker thread so the listing fetch never
/// blocks the UI; unresolvable pages (antiX/Zorin HTML) are left for the
/// Install-time flow (browser + message) instead of dying here.
fn start_bg_download(
    bg: &Rc<std::cell::RefCell<Vec<BgDl>>>,
    url: &str,
    name: &str,
    dir: &str,
    tx: mpsc::Sender<HwMsg>,
) {
    if url.ends_with(".iso") {
        start_direct_download(bg, url, name, dir);
        return;
    }
    // Directory URL: resolve on a worker thread (the listing fetch must not
    // block the UI), then hand the direct URL back to the GUI thread through
    // the timer channel - the Rc<Vec<BgDl>> is !Send, so the download entry
    // itself is created on the GUI thread (DistroResolved arm below).
    let (url2, dir2) = (url.to_string(), dir.to_string());
    std::thread::spawn(move || {
        if let Some((real_url, real_name)) = crate::resolve_page_iso(&url2) {
            let _ = tx.send(HwMsg::DistroResolved {
                url: real_url,
                name: real_name,
                dir: dir2,
            });
        }
        // unresolvable pages (antiX/Zorin HTML): the Install-time flow
        // opens the browser + explains
    });
}

/// Start downloading a direct `.iso` `url` to <download_dir>\<name> in a
/// background thread. No-ops when the ISO is already on disk or there is no
/// HTTP transport.
fn start_direct_download(
    bg: &Rc<std::cell::RefCell<Vec<BgDl>>>,
    url: &str,
    name: &str,
    dir: &str,
) {
    glog(&format!("bg download requested: {name}"));
    // same fallback as resolve_iso: empty --download-dir -> the user's Downloads
    let dir = if dir.trim().is_empty() {
        sys::downloads_dir()
    } else {
        dir.trim_end_matches('\\').to_string()
    };
    let dest = format!("{}\\{}", dir, name);
    if sys::path_exists(&dest) {
        sys::out::info(&format!("ISO already downloaded: {}", dest));
        return;
    }
    // (page/directory URLs are resolved to a direct .iso by the caller)
    // an up-to-date, right-sized local copy of the same ISO beats a
    // re-download (the console step picks it up via the harvest reuse)
    if let Some(existing) = find_matching_local_iso(name, MIN_ISO_SIZE) {
        sys::out::info(&format!(
            "Using existing up-to-date ISO instead of downloading: {}",
            existing
        ));
        return;
    }
    if !crate::net::has_transport() {
        sys::out::warn("No HTTP transport on this Windows - cannot download in the background.");
        return;
    }
    sys::out::info(&format!(
        "Downloading {} in the background (continues while you configure the wizard)...",
        name
    ));
    let prog = std::sync::Arc::new(std::sync::atomic::AtomicU64::new(0));
    let total = std::sync::Arc::new(std::sync::atomic::AtomicU64::new(
        crate::net::content_length(url).unwrap_or(0),
    ));
    let finished = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let (tx, rx) = std::sync::mpsc::channel();
    // Download to a .part file and only rename to the final name on success,
    // so a truncated download can never be mistaken for a complete ISO by
    // resolve_iso's "ISO already present" check.
    let part = format!("{}.part", dest);
    let (u2, d2, p2, f2) = (url.to_string(), dest.clone(), prog.clone(), part.clone());
    let fin = finished.clone();
    std::thread::spawn(move || {
        let r = crate::net::download_to_file(&u2, &f2, crate::net::user_agent(), &mut |n| {
            p2.store(n, std::sync::atomic::Ordering::Relaxed);
        })
        .map(|_| ())
        .map_err(|e| e.to_string());
        let r = match r {
            Ok(()) => match std::fs::rename(&f2, &d2) {
                Ok(()) => Ok(()),
                Err(e) => Err(format!("rename {} -> {}: {}", f2, d2, e)),
            },
            Err(e) => {
                sys::delete_file(&f2);
                Err(e)
            }
        };
        let _ = tx.send(r);
        fin.store(true, std::sync::atomic::Ordering::Relaxed);
    });
    bg.borrow_mut().push(BgDl {
        dest,
        prog,
        total,
        finished,
        rx,
    });
}

// ---------------------------------------------------------------------------
// Working phase: after the wizard's Install click the window STAYS VISIBLE
// (big status text + the live download progress bar) while main() resolves
// the ISO and launches Rufus. It used to vanish first and the console appeared
// to stall until Rufus finally popped up. WorkingUi is a raw-handle facade
// for that phase: it never touches nwg control objects (their Drop would
// destroy the windows - see the ScrollBar note), it only sends messages to
// already-owned HWNDs.
// ---------------------------------------------------------------------------

/// What the working phase (the Install-click callback in main()) did.
pub struct GuiWork {
    /// Resolved ISO path.
    pub iso: String,
    /// "rufus" | "nofmt" | "skip" - the wizard's USB-write choice.
    pub mode: String,
    /// Rufus child process when mode == "rufus" (main waits for the USB).
    pub rufus_proc: Option<crate::sys::Child>,
    /// Volumes visible before the Rufus write (wait_usb_ready baseline).
    pub known: Vec<String>,
    /// mode == "nofmt": target drive letter after the in-process write.
    pub nofmt_letter: Option<String>,
    /// mode == "nofmt": validated-but-unflipped boot sectors, committed
    /// after the main-phase file drops (see nofmt::commit_boot_sectors).
    pub nofmt_pending: Option<crate::nofmt::PendingMbr>,
    /// mode == "nofmt": reboot choice from the in-window boot page
    /// (ask_boot_choice); run() executes it instead of a second dialog.
    pub boot_choice: Option<crate::boot::BootChoice>,
    /// FAILED page "Back to install options": resume the wizard.
    pub back: bool,
}

impl GuiWork {
    /// Sentinel: the user went Back from a FAILED page - run_gui resumes
    /// the wizard instead of proceeding.
    pub fn back() -> Self {
        GuiWork {
            iso: String::new(),
            mode: String::new(),
            rufus_proc: None,
            known: Vec::new(),
            nofmt_letter: None,
            nofmt_pending: None,
            boot_choice: None,
            back: true,
        }
    }
}

/// Raw-HWND facade over the wizard window while the working phase runs and
/// during the FINISHED / FAILED summary page shown at the very end.
pub struct WorkingUi {
    main: usize,
    status: usize,
    bg: Rc<std::cell::RefCell<Vec<BgDl>>>,
    // FINISHED/SUMMARY page controls + the nav buttons they temporarily
    // replace (all raw HWNDs so the GUI thread can drive them mid-pump).
    sum_frame: usize,
    sum_heading: usize,
    sum_body: usize,
    sum_btn: usize,
    sum_copy: usize,
    sum_open: usize,
    nav_back: usize,
    nav_next: usize,
    nav_cancel: usize,
    dl: usize, // "Downloading ..." label (hidden on the final page)
    dlbar: usize, // the persistent ISO progress bar (hidden on the final page)
    done: Rc<std::cell::Cell<bool>>, // set by the Finish/Close button click
    copy_clicked: Rc<std::cell::Cell<bool>>,
    open_clicked: Rc<std::cell::Cell<bool>>,
    sum_back: usize, // "Back to install options" (FAILED page only)
    back_clicked: Rc<std::cell::Cell<bool>>,
    // Boot-choice page clicks (ask_boot_choice reuses the summary HWNDs;
    // separate cells so the two modal loops never read stale flags).
    boot_usb: Rc<std::cell::Cell<bool>>,
    boot_adv: Rc<std::cell::Cell<bool>>,
    boot_fw: Rc<std::cell::Cell<bool>>,
    boot_none: Rc<std::cell::Cell<bool>>,
}

impl WorkingUi {
    pub fn set_status(&self, text: &str) {
        set_wnd_text(self.status, text);
        repaint(self.status);
    }

    pub fn set_progress(&self, done: u64, total: u64) {
        const PBM_SETRANGE32: u32 = 1030;
        const PBM_SETPOS: u32 = 1026;
        // PBM limits are 32-bit ints: a ~3 GB byte total overflows them
        // (wraps negative) and pins the bar at 100% from the first chunk.
        // Track megabytes instead - ample resolution for a bar.
        let (max, pos) = bar_units(done, total);
        if self.dlbar != 0 && is_window(self.dlbar) {
            use winapi::um::winuser::SendMessageW;
            unsafe {
                SendMessageW(self.dlbar as _, PBM_SETRANGE32, 0, max as isize);
                SendMessageW(self.dlbar as _, PBM_SETPOS, pos as _, 0);
            }
        }
        if self.dl != 0 && is_window(self.dl) {
            let text = if total > 0 {
                format!("{} / {} MB", done / sys::MB, total / sys::MB)
            } else {
                format!("{} MB", done / sys::MB)
            };
            set_wnd_text(self.dl, &text);
        }
    }

    /// Dispatch all pending messages so the window keeps painting while
    /// blocking work runs on this (the GUI) thread.
    pub fn pump(&self) {
        pump_pending(self.main);
    }

    pub fn close(&self) {
        if is_window(self.main) {
            use winapi::um::winuser::{DestroyWindow, UnregisterHotKey};
            unsafe {
                UnregisterHotKey(self.main as winapi::shared::windef::HWND, INSTALL_HOTKEY_ID);
                DestroyWindow(self.main as winapi::shared::windef::HWND)
            };
        }
    }

    fn raw_show(&self, h: usize, vis: bool) {
        use winapi::um::winuser::{ShowWindow, SW_HIDE, SW_SHOW};
        if h != 0 && is_window(h) {
            unsafe { ShowWindow(h as winapi::shared::windef::HWND, if vis { SW_SHOW } else { SW_HIDE }) };
        }
    }

    /// Hide every summary-page control (used when going Back to the wizard).
    pub fn hide_summary(&self) {
        self.raw_show(self.sum_frame, false);
        self.raw_show(self.sum_heading, false);
        self.raw_show(self.sum_body, false);
        self.raw_show(self.sum_btn, false);
        self.raw_show(self.sum_copy, false);
        self.raw_show(self.sum_open, false);
        self.raw_show(self.sum_back, false);
    }

    /// Render the FINAL page and block (pumping the GUI) until the user
    /// clicks its button, then destroy the window. `ok` picks the heading
    /// tone + button label: a green-ish "finished" summary on success, a
    /// red "failed" screen (with the reason) on error. The window does NOT
    /// just vanish: the reason / summary stays on-screen so the user reads
    /// it before choosing to dismiss.
    ///
    /// On failure a "Back to install options" button is offered: returns
    /// true when the user picks it (window left alive for the wizard to
    /// resume), false when finished/closed (window destroyed).
    pub fn show_final(&self, heading: &str, body: &str, ok: bool) -> bool {
        let (cw, ch) = client_size(self.main as winapi::shared::windef::HWND);
        let fw = (cw - 2 * MARGIN).max(MIN_CW - 2 * MARGIN);
        // frame fills the page area (below the secure-boot header, above the
        // nav strip); heading + a readonly body box inside it.
        self.raw_show(self.sum_frame, true);
        let top = 78;
        let fh = (ch - top - NAV_H).max(80);
        set_ctl_rect(self.sum_frame, MARGIN, top, fw, fh);
        set_wnd_text(self.sum_heading, heading);
        set_ctl_rect(self.sum_heading, MARGIN + 10, top + 6, (fw - 20).max(60), 22);
        set_wnd_text(self.sum_body, body);
        set_ctl_rect(
            self.sum_body,
            MARGIN + 10,
            top + 34,
            (fw - 20).max(60),
            (fh - 34 - 46).max(40),
        );
        self.raw_show(self.sum_body, true);
        self.raw_show(self.sum_heading, true);
        // one button, bottom-right where "Next"/"Install" lived
        let btn_x = (cw - MARGIN - 96).max(MARGIN);
        let btn_y = (ch - MARGIN - 28).max(top);
        set_wnd_text(self.sum_btn, if ok { "Finish" } else { "Close" });
        set_ctl_rect(self.sum_btn, btn_x, btn_y, 96, 28);
        self.raw_show(self.sum_btn, true);
        // "Copy" sits left of Finish. On failure "Back to install options"
        // sits left of Copy (the wizard Back button's neighbourhood, right
        // cluster) and "Open manual download" takes the bottom-left slot
        // where Cancel lived.
        let copy_x = (btn_x - 90 - 8).max(MARGIN);
        set_ctl_rect(self.sum_copy, copy_x, btn_y, 90, 28);
        self.raw_show(self.sum_copy, true);
        if !ok {
            set_ctl_rect(self.sum_open, MARGIN, btn_y, 150, 28);
            self.raw_show(self.sum_open, true);
            // FAILED escape hatch: back to the INSTALL page to pick another
            // method (e.g. Rufus) instead of only closing with an error.
            set_ctl_rect(self.sum_back, (copy_x - 170 - 8).max(MARGIN), btn_y, 170, 28);
            self.raw_show(self.sum_back, true);
        } else {
            self.raw_show(self.sum_open, false);
            self.raw_show(self.sum_back, false);
        }
        // hide everything else that could paint over / distract from it
        self.raw_show(self.nav_back, false);
        self.raw_show(self.nav_next, false);
        self.raw_show(self.nav_cancel, false);
        self.raw_show(self.status, false); // working-status label
        self.raw_show(self.dl, false);
        self.raw_show(self.dlbar, false);
        self.repaint_window();

        // Give the Finish/Close button focus so Enter/Space dismisses the
        // page. Without this the readonly body textbox keeps focus and Tab
        // (even without TAB_STOP) may not reach the button on every Windows.
        use winapi::um::winuser::SetFocus;
        unsafe {
            SetFocus(self.sum_btn as winapi::shared::windef::HWND);
        }

        // block until the Finish/Close button (or a window close) fires;
        // Copy / Open-manual-download are handled in-place and keep waiting.
        // Escape/Enter also dismiss: keyboard button activation (BN_CLICKED
        // via Enter/Space) proved flaky on the Win95 VM, so catch the raw
        // WM_KEYDOWN too.
        self.done.set(false);
        self.copy_clicked.set(false);
        self.open_clicked.set(false);
        self.back_clicked.set(false);
        while !self.done.get() && !self.back_clicked.get() {
            use winapi::um::winuser::{
                PeekMessageW, PM_NOREMOVE, WM_KEYDOWN, MSG, VK_ESCAPE, VK_RETURN,
            };
            let mut msg: MSG = unsafe { std::mem::zeroed() };
            if unsafe { PeekMessageW(&mut msg, std::ptr::null_mut(), WM_KEYDOWN, WM_KEYDOWN, PM_NOREMOVE) }
                != 0
            {
                let vk = msg.wParam as u32;
                if vk == VK_ESCAPE as u32 || vk == VK_RETURN as u32 {
                    self.done.set(true);
                }
            }
            self.pump();
            if !is_window(self.main) {
                break;
            }
            if self.copy_clicked.get() {
                self.copy_clicked.set(false);
                copy_to_clipboard(body);
                set_wnd_text(self.sum_btn, if ok { "Finish" } else { "Close" });
            }
            if self.open_clicked.get() {
                self.open_clicked.set(false);
                if let Some(url) = first_url(body) {
                    crate::sys::open_url(&url);
                }
            }
            std::thread::sleep(std::time::Duration::from_millis(60));
        }
        if self.back_clicked.get() {
            // Back to install options: hide the summary and leave the
            // window alive - run_gui resumes the wizard on the INSTALL page.
            self.hide_summary();
            self.repaint_window();
            return true;
        }
        // the window's job is done - destroy it so the post-GUI (Rufus wait,
        // lsl file drop) console phase isn't left with an orphan window.
        self.close();
        false
    }

    /// Boot-choice page in the SAME window (after the FINISHED summary):
    /// stacked full-width action buttons reusing the summary HWNDs,
    /// mirroring the standalone boot dialog. Blocks pumping the GUI until
    /// a choice is made; window close / Escape means Don't reboot. `can_usb`
    /// hides the one-time-boot button where bcdedit can't work. The window
    /// is destroyed on return - the console tail + reboot follow.
    pub fn ask_boot_choice(&self, body: &str, can_usb: bool) -> crate::boot::BootChoice {
        use crate::boot::BootChoice;
        let (cw, ch) = client_size(self.main as winapi::shared::windef::HWND);
        let fw = (cw - 2 * MARGIN).max(MIN_CW - 2 * MARGIN);
        let bw = (fw - 20).max(60);
        let top = 78;
        self.raw_show(self.sum_frame, true);
        set_ctl_rect(self.sum_frame, MARGIN, top, fw, (ch - top - NAV_H).max(80));
        set_wnd_text(self.sum_heading, "lslsetup - boot the USB");
        set_ctl_rect(self.sum_heading, MARGIN + 10, top + 6, bw, 22);
        self.raw_show(self.sum_heading, true);
        set_wnd_text(self.sum_body, body);
        set_ctl_rect(self.sum_body, MARGIN + 10, top + 34, bw, 60);
        self.raw_show(self.sum_body, true);
        // stacked actions, same order as the standalone dialog
        let mut y = top + 100;
        if can_usb {
            set_wnd_text(self.sum_btn, "Reboot to USB now");
            set_ctl_rect(self.sum_btn, MARGIN + 10, y, bw, 28);
            self.raw_show(self.sum_btn, true);
        } else {
            self.raw_show(self.sum_btn, false);
        }
        y += 36;
        set_wnd_text(self.sum_copy, "Firmware boot menu");
        set_ctl_rect(self.sum_copy, MARGIN + 10, y, bw, 28);
        self.raw_show(self.sum_copy, true);
        y += 36;
        set_wnd_text(self.sum_open, "Advanced startup menu");
        set_ctl_rect(self.sum_open, MARGIN + 10, y, bw, 28);
        self.raw_show(self.sum_open, true);
        y += 36;
        set_wnd_text(self.sum_back, "Don't reboot");
        set_ctl_rect(self.sum_back, MARGIN + 10, y, bw, 28);
        self.raw_show(self.sum_back, true);
        // hide everything else that could paint over it
        self.raw_show(self.nav_back, false);
        self.raw_show(self.nav_next, false);
        self.raw_show(self.nav_cancel, false);
        self.raw_show(self.status, false);
        self.raw_show(self.dl, false);
        self.raw_show(self.dlbar, false);
        self.repaint_window();

        use winapi::um::winuser::SetFocus;
        unsafe {
            SetFocus((if can_usb { self.sum_btn } else { self.sum_copy }) as winapi::shared::windef::HWND);
        }

        self.boot_usb.set(false);
        self.boot_adv.set(false);
        self.boot_fw.set(false);
        self.boot_none.set(false);
        let mut choice: Option<BootChoice> = None;
        while choice.is_none() {
            // raw keys: Escape declines, Return takes the primary action
            // (BN_CLICKED via Enter proved flaky on the Win95 VM).
            use winapi::um::winuser::{
                PeekMessageW, PM_NOREMOVE, WM_KEYDOWN, MSG, VK_ESCAPE, VK_RETURN,
            };
            let mut msg: MSG = unsafe { std::mem::zeroed() };
            if unsafe { PeekMessageW(&mut msg, std::ptr::null_mut(), WM_KEYDOWN, WM_KEYDOWN, PM_NOREMOVE) }
                != 0
            {
                let vk = msg.wParam as u32;
                if vk == VK_ESCAPE as u32 {
                    choice = Some(BootChoice::None);
                } else if vk == VK_RETURN as u32 {
                    choice = Some(if can_usb { BootChoice::Usb } else { BootChoice::None });
                }
            }
            self.pump();
            if !is_window(self.main) {
                break;
            }
            if self.boot_usb.get() {
                choice = Some(BootChoice::Usb);
            } else if self.boot_adv.get() {
                choice = Some(BootChoice::Adv);
            } else if self.boot_fw.get() {
                choice = Some(BootChoice::Fw);
            } else if self.boot_none.get() {
                choice = Some(BootChoice::None);
            }
            std::thread::sleep(std::time::Duration::from_millis(60));
        }
        // page's job is done - destroy the window; the console tail and the
        // reboot itself follow (both need no window).
        self.close();
        choice.unwrap_or(BootChoice::None)
    }

    fn repaint_window(&self) {
        use winapi::um::winuser::GetClientRect;
        if !is_window(self.main) {
            return;
        }
        unsafe {
            let mut cr: winapi::shared::windef::RECT = std::mem::zeroed();
            GetClientRect(self.main as winapi::shared::windef::HWND, &mut cr);
            use winapi::um::winuser::InvalidateRect;
            InvalidateRect(self.main as winapi::shared::windef::HWND, std::ptr::null(), 1);
        }
        repaint(self.main);
    }

    /// Join any background ISO download started from the page-1 distro
    /// radios, pumping the GUI (the progress bar keeps updating) while
    /// waiting. Previously this join ran with plain sleeps AFTER the window
    /// closed - the GUI vanished while the download was still going.
    pub fn wait_downloads(&self) {
        while let Some(b) = {
            let mut bg = self.bg.borrow_mut();
            bg.iter()
                .position(|b| !b.finished.load(std::sync::atomic::Ordering::Relaxed))
                .map(|i| bg.remove(i))
        } {
            let name = b.dest.rsplit('\\').next().unwrap_or("").to_string();
            self.set_status(&format!(
                "Downloading {} - the progress bar below stays live; the installer continues once it finishes.",
                name
            ));
            loop {
                match b.rx.try_recv() {
                    Ok(Ok(())) => {
                        sys::out::info(&format!("Downloaded: {}", b.dest));
                        break;
                    }
                    Ok(Err(e)) => {
                        sys::out::warn(&format!("Background download failed: {}", e));
                        break;
                    }
                    Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                        sys::out::warn("Background download thread ended unexpectedly.");
                        break;
                    }
                    Err(std::sync::mpsc::TryRecvError::Empty) => {
                        pump_pending(self.main);
                        std::thread::sleep(std::time::Duration::from_millis(200));
                    }
                }
            }
        }
    }
}

/// Progress-bar (range-max, position) for byte counts, in megabytes:
/// PBM_SETRANGE32/PBM_SETPOS take 32-bit ints, so a ~3 GB byte total wraps
/// negative and the bar reads complete at ~1%. Pure so the scaling is
/// unit-testable - the live control is unreachable headless.
pub(crate) fn bar_units(done: u64, total: u64) -> (i32, i32) {
    let max = ((total / sys::MB).max(1)).min(i32::MAX as u64) as i32;
    let pos = (done / sys::MB).min(total / sys::MB).min(max as u64) as i32;
    (max, pos)
}

impl crate::nofmt::WriteUi for WorkingUi {
    fn set_status(&self, msg: &str) {
        self.set_status(msg);
    }
    fn set_progress(&self, done: u64, total: u64) {
        self.set_progress(done, total);
    }
    fn show_progress(&self, visible: bool) {
        self.raw_show(self.dl, visible);
        self.raw_show(self.dlbar, visible);
    }
    fn pump(&self) {
        self.pump();
    }
}

fn set_wnd_text(h: usize, text: &str) {
    use winapi::um::winuser::SetWindowTextW;
    if !is_window(h) {
        return;
    }
    let wide: Vec<u16> = text.encode_utf16().chain(std::iter::once(0)).collect();
    unsafe {
        SetWindowTextW(h as winapi::shared::windef::HWND, wide.as_ptr());
    }
}

fn repaint(h: usize) {
    use winapi::um::winuser::{InvalidateRect, UpdateWindow};
    if !is_window(h) {
        return;
    }
    unsafe {
        InvalidateRect(h as winapi::shared::windef::HWND, std::ptr::null(), 1);
        UpdateWindow(h as winapi::shared::windef::HWND);
    }
}

fn is_window(h: usize) -> bool {
    use winapi::um::winuser::IsWindow;
    h != 0 && unsafe { IsWindow(h as winapi::shared::windef::HWND) != 0 }
}

/// Dispatch pending messages, keeping WM_QUIT in the queue (re-post it):
/// the outer nwg dispatch loop must still see it after the working phase
/// closes the window, or run_gui would hang.
fn pump_pending(main: usize) {
    use winapi::um::processthreadsapi::GetCurrentThreadId;
    use winapi::um::winuser::{
        DispatchMessageW, PeekMessageW, PostThreadMessageW, TranslateMessage, MSG, PM_REMOVE,
    };
    if !is_window(main) {
        return;
    }
    const WM_QUIT: u32 = 0x0012;
    let mut msg: MSG = unsafe { std::mem::zeroed() };
    unsafe {
        // Bound the batch: a continuously-reposted message (e.g. WM_PAINT
        // from a busy window) would otherwise keep this loop spinning and
        // starve the caller's own checks (the FINISHED-page modal loop's
        // Escape/Enter PeekMessage never ran on the Win95 VM - the guest sat
        // at ~80% CPU and ignored keys).
        let mut n = 0;
        while n < 100 && PeekMessageW(&mut msg, std::ptr::null_mut(), 0, 0, PM_REMOVE) != 0 {
            n += 1;
            if msg.message == WM_QUIT {
                PostThreadMessageW(GetCurrentThreadId(), WM_QUIT, msg.wParam, msg.lParam);
                break;
            }
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
}

pub fn run_gui(
    wsl_vhdx_pre: &[String],
    flatpak_extra: &[String],
    iso_arg: &str,
    mint_version: &str,
    download_dir: &str,
    write_mode_pre: &str,
    on_confirm: &mut dyn FnMut(GuiResult, &WorkingUi) -> GuiWork,
) -> Option<(GuiResult, GuiWork)> {
    // Must init common controls before building ANY control; otherwise the
    // builds fail silently (we `let _ =` them) and the first setter panics
    // with "not yet bound to a winapi object".
    nwg::init().expect("Failed to init Native Windows GUI");

    let confirmed = Rc::new(Cell::new(false));
    let cancelled = Rc::new(Cell::new(false));
    let page = Rc::new(Cell::new(0usize));
    // FINISHED/FAILED page: finish-button HWND + its "clicked" latc.
    let sum_btn_h: Rc<Cell<usize>> = Rc::new(Cell::new(0));
    let sum_back_h: Rc<Cell<usize>> = Rc::new(Cell::new(0));
    let back_clicked: Rc<Cell<bool>> = Rc::new(Cell::new(false));
    let final_done: Rc<Cell<bool>> = Rc::new(Cell::new(false));
    // extra summary-page buttons: copy the body to the clipboard, and (on
    // failure) open the first manual-download URL in the browser.
    let sum_copy_h: Rc<Cell<usize>> = Rc::new(Cell::new(0));
    let sum_open_h: Rc<Cell<usize>> = Rc::new(Cell::new(0));
    let copy_clicked: Rc<Cell<bool>> = Rc::new(Cell::new(false));
    let open_clicked: Rc<Cell<bool>> = Rc::new(Cell::new(false));
    // boot-choice page clicks (wired in the button-click handler below)
    let boot_usb: Rc<Cell<bool>> = Rc::new(Cell::new(false));
    let boot_adv: Rc<Cell<bool>> = Rc::new(Cell::new(false));
    let boot_fw: Rc<Cell<bool>> = Rc::new(Cell::new(false));
    let boot_none: Rc<Cell<bool>> = Rc::new(Cell::new(false));

    let (tx, rx) = mpsc::channel::<HwMsg>();

    // background ISO downloads (started when a distro radio is clicked;
    // joined after the wizard confirms)
    let bg_downloads: Rc<std::cell::RefCell<Vec<BgDl>>> =
        Rc::new(std::cell::RefCell::new(Vec::new()));

    // hardware rows as they stream in (background thread) + sort state for
    // the clickable column headings: (column, direction: 1 asc / -1 desc)
    let hw_rows: Rc<std::cell::RefCell<Vec<HwRow>>> =
        Rc::new(std::cell::RefCell::new(Vec::new()));
    let hw_sort: Rc<std::cell::Cell<(usize, i32)>> =
        Rc::new(std::cell::Cell::new((1, 1))); // default: Support, A first

    // layout cells (shared with the scroll handlers + the resize handler)
    let fw_cell: Rc<Cell<i32>> = Rc::new(Cell::new(0));
    let iso_off: Rc<Cell<i32>> = Rc::new(Cell::new(0));
    let fp_off: Rc<Cell<i32>> = Rc::new(Cell::new(0));
    let sys_off: Rc<Cell<i32>> = Rc::new(Cell::new(0));
    let wifi_off: Rc<Cell<i32>> = Rc::new(Cell::new(0));
    let install_off: Rc<Cell<i32>> = Rc::new(Cell::new(0));
    let iso_geom: Rc<Cell<(i32, i32, i32, i32, i32)>> = Rc::new(Cell::new((0, 0, 0, 0, 0)));
    let fp_geom: Rc<Cell<(i32, i32, i32, i32, i32)>> = Rc::new(Cell::new((0, 0, 0, 0, 0)));
    let sys_geom: Rc<Cell<(i32, i32, i32, i32, i32)>> = Rc::new(Cell::new((0, 0, 0, 0, 0)));
    let wifi_geom: Rc<Cell<(i32, i32, i32, i32, i32)>> = Rc::new(Cell::new((0, 0, 0, 0, 0)));
    let install_geom: Rc<Cell<(i32, i32, i32, i32, i32)>> = Rc::new(Cell::new((0, 0, 0, 0, 0)));
    let fp_content: Rc<Cell<i32>> = Rc::new(Cell::new(0));
    // re-entrancy guard: resizing a CHILD during relayout makes nwg dispatch
    // Event::OnResize for that child straight back into our handler (nwg
    // subclasses every child), which would re-enter relayout while page-item
    // RefCells are still borrowed. Nested passes are no-ops; the outer pass
    // completes the whole layout.
    let in_relayout: Rc<Cell<bool>> = Rc::new(Cell::new(false));

    let wifi_names = crate::wifi::wifi_profile_names();

    // ---- controls ----
    let mut window: nwg::Window = Default::default();
    let mut lbl_sb: nwg::Label = Default::default();
    let mut font_bold: nwg::Font = Default::default();
    // nwg::Timer is deprecated upstream in favor of AnimationTimer, but the
    // winapi timer's exact dispatch semantics are what the GUI pump relies
    // on (Win95-vendored nwg; unmigratable without a Windows test rig).
    #[allow(deprecated)]
    let mut timer: nwg::Timer = Default::default();

    // page 0: hardware
    let mut frame_hw: nwg::Frame = Default::default();
    let mut lbl_hw: nwg::Label = Default::default();
    let mut lv_hw: nwg::ListView = Default::default();

    // page 1: ISO — scrollable item list (shared storage, single owner)
    let mut frame_iso: nwg::Frame = Default::default();
    let mut lbl_rec: nwg::Label = Default::default();
    let mut lbl_rec_help: nwg::Label = Default::default();
    let mut sb_iso: nwg::ScrollBar = Default::default();
    let mut btn_everything: nwg::Button = Default::default();
    let iso_items: PageItems = Rc::new(std::cell::RefCell::new(Vec::new()));

    // page 2: flatpaks — scrollable grid + extras (same shared storage)
    let mut frame_fp: nwg::Frame = Default::default();
    let mut lbl_fp: nwg::Label = Default::default();
    let mut sb_fp: nwg::ScrollBar = Default::default();
    let fp_items: PageItems = Rc::new(std::cell::RefCell::new(Vec::new()));

    // page 3: system — scrollable single column (same shared storage)
    let mut frame_sys: nwg::Frame = Default::default();
    let mut sb_sys: nwg::ScrollBar = Default::default();
    let sys_items: PageItems = Rc::new(std::cell::RefCell::new(Vec::new()));

    // page 4: wifi — master switch + per-network list
    let mut frame_wifi: nwg::Frame = Default::default();
    let mut sb_wifi: nwg::ScrollBar = Default::default();
    let wifi_items: PageItems = Rc::new(std::cell::RefCell::new(Vec::new()));

    // page 5: INSTALL NOW — USB write method + target USB picker.
    // The Rufus / built-in choice lives HERE and only here: no
    // write-method radio may appear on any earlier page (the
    // win-install-page GUI test asserts that).
    let mut frame_install: nwg::Frame = Default::default();
    let mut sb_install: nwg::ScrollBar = Default::default();
    let install_items: PageItems = Rc::new(std::cell::RefCell::new(Vec::new()));

    // nav
    let mut btn_back: nwg::Button = Default::default();
    let mut btn_next: nwg::Button = Default::default();
    let mut btn_cancel: nwg::Button = Default::default();

    // ---- window + shared labels ----
    // NOTE: no VISIBLE flag - the window is created hidden so the user never
    // sees the intermediate states (all five page frames are built stacked on
    // top of each other; wine paints each CreateWindow immediately, real
    // Windows can flush queued paints mid-build). It is shown after the
    // pages are laid out and pages 1-4 are hidden.
    let _ = nwg::Window::builder()
        .flags(nwg::WindowFlags::MAIN_WINDOW)
        .size((DEF_CW, DEF_CH))
        .center(true)
        .title(&format!(
            "lsl-usb installer {}",
            std::fs::read_to_string("VERSION")
                .map(|s| s.trim().to_string())
                .unwrap_or_default()
        ))
        .build(&mut window);
    #[allow(deprecated)]
    let _ = nwg::Timer::builder()
        .interval(120)
        .parent(&window)
        .build(&mut timer);

    // Clamp the window to the work area and center it there: a 640x480 Win9x
    // desktop offers only ~632x~413 of client space under the taskbar, and
    // the default 880x760 would run off-screen (it needs >=1024x768).
    let (wa_l, wa_t, wa_r, wa_b) = work_area();
    let _ = WORK_AREA.set((wa_l, wa_t, wa_r, wa_b));
    let (waw, wah) = (wa_r - wa_l, wa_b - wa_t);
    let (mut cw, mut ch) = (DEF_CW, DEF_CH);
    if let Some(hwnd) = window.handle.hwnd() {
        let (ew, eh) = window_chrome(hwnd);
        let _ = CHROME.set((ew, eh));
        if cw + ew > waw || ch + eh > wah {
            cw = cw.min(waw - ew).max(200);
            ch = ch.min(wah - eh).max(200);
            window.set_size(cw as u32, ch as u32);
        }
        window.set_position(wa_l + (waw - (cw + ew)) / 2, wa_t + (wah - (ch + eh)) / 2);
    }

    // bold face for section headings (built from the system default family)
    if let Err(e) = nwg::Font::builder().weight(700).build(&mut font_bold) {
        glog(&format!("bold font build error: {e:?}"));
    }

    let sb_text = format!(
        "Secure Boot: {}",
        match crate::boot::secure_boot_status() {
            sys::SecBoot::Enabled => "Enabled - Mint's signed shim usually boots fine; you may see a one-time 'MOK management' screen (choose Enroll MOK).",
            sys::SecBoot::Disabled => "Disabled - no Secure Boot issues expected.",
            sys::SecBoot::Unknown => "Unknown - could not query (BIOS firmware, or run as Administrator for a firmware-level query).",
        }
    );
    let _ = nwg::Label::builder()
        .text(&sb_text)
        .position((MARGIN, 10))
        .size((DEF_CW - 2 * MARGIN, 20))
        .parent(&window)
        .build(&mut lbl_sb);

    // ---- page 0: hardware compatibility ----
    let _ = nwg::Frame::builder()
        .position((MARGIN, 88))
        .size((DEF_CW - 2 * MARGIN, DEF_CH - 88 - NAV_H))
        .parent(&window)
        .build(&mut frame_hw);
        let frame_hw = Rc::new(frame_hw);
    let _ = nwg::Label::builder()
        .text("Linux hardware compatibility (linux-hardware.org LKDDb): rating devices...")
        .position((10, 6))
        .size((820, 20))
        .parent(&*frame_hw)
        .build(&mut lbl_hw);
    let _ = nwg::ListView::builder()
        .position((10, 30))
        .size((830, 560))
        .list_style(nwg::ListViewStyle::Detailed)
        .parent(&*frame_hw)
        .build(&mut lv_hw);
    // nwg defaults to NO_HEADER (headers hidden) — headings are required
    lv_hw.set_headers_enabled(true);
    // Full-row select: without it, clicks past a cell's text (e.g. the short
    // www globe) hit-test to no item (iItem = -1) and row clicks in the www
    // column would never open the URL.
    {
        use winapi::um::commctrl::LVS_EX_FULLROWSELECT;
        if let Some(hwnd) = lv_hw.handle.hwnd() {
            const LVM_SETEXTENDEDLISTVIEWSTYLE: u32 = 0x1036; // LVM_FIRST + 0x36
            unsafe {
                winapi::um::winuser::SendMessageW(
                    hwnd,
                    LVM_SETEXTENDEDLISTVIEWSTYLE,
                    0,
                    LVS_EX_FULLROWSELECT as isize,
                );
            }
        }
    }
    install_hw_custom_draw(&lv_hw, &*frame_hw);
    for (i, (text, width)) in [
        ("Category", 110),
        ("Support", 250),
        ("Device", 314),
        ("ID", 100),
        ("www", 64),
    ].iter().enumerate() {
        lv_insert_column_direct(&lv_hw, i, text, *width);
    }
    let mut btn_reboot: nwg::Button = Default::default();
    let _ = nwg::Button::builder()
        .text("Reboot")
        .position((8, 706))
        .size((90, 28))
        .parent(&window)
        .build(&mut btn_reboot);
    let btn_reboot = Rc::new(btn_reboot);

    // ---- page 1: ISO selection (all checkboxes, one column, scrollbar) ----
    let _ = nwg::Frame::builder()
        .position((MARGIN, 88))
        .size((DEF_CW - 2 * MARGIN, DEF_CH - 88 - NAV_H))
        .parent(&window)
        .build(&mut frame_iso);
        let frame_iso = Rc::new(frame_iso);
    let (rec_title, rec_help) = recommendation_text();
    let have_mint_hint = find_matching_local_iso(
        &format!("linuxmint-{}-cinnamon-64bit.iso", mint_version),
        MIN_ISO_SIZE,
    );
    let rec_help = if have_mint_hint.is_some() {
        format!(
            "{} An up-to-date Mint ISO is already on this machine - it will be reused (no download needed).",
            rec_help
        )
    } else {
        rec_help
    };
    let _ = nwg::Label::builder()
        .text(&rec_title)
        .position((10, 4))
        .size((800, 18))
        .parent(&*frame_iso)
        .build(&mut lbl_rec);
    // the "Linux Mint Cinnamon is the recommended option." line stands out
    lbl_rec.set_font(Some(&font_bold));
    let _ = nwg::Label::builder()
        .text(&rec_help)
        .position((10, 22))
        .size((800, 46))
        .parent(&*frame_iso)
        .build(&mut lbl_rec_help);

    let mut y = 72i32; // scroll-space y cursor
    let mint_url = format!(
        "https://mirrors.kernel.org/linuxmint/stable/{}/linuxmint-{}-cinnamon-64bit.iso",
        mint_version, mint_version
    );
    let distro_urls: Vec<String> = DISTRO_OPTIONS
        .iter()
        .enumerate()
        .map(|(i, (_, u))| if i == 0 { mint_url.clone() } else { u.to_string() })
        .collect();
    let rec = recommended_distro();
    // bold section heading inside the scroll space
    let add_label = |label: &str, y: &mut i32| {
        let mut l: Box<nwg::Label> = Box::default();
        let _ = nwg::Label::builder()
            .text(label)
            .position((10, *y))
            .size((800, 18))
            .parent(&*frame_iso)
            .build(&mut l);
        l.set_font(Some(&font_bold));
        iso_items.borrow_mut().push(PageItem {
            ctl: PageCtl::Lbl(l, 0),
            x: 10,
            y: *y,
            w: -20,
            h: 18,
            idx: 0,
        });
        *y += 22;
    };
    // plain (non-bold) text row for "(none found)" placeholders
    let add_plain = |label: &str, y: &mut i32| {
        let mut l: Box<nwg::Label> = Box::default();
        let _ = nwg::Label::builder()
            .text(label)
            .position((26, *y))
            .size((780, 18))
            .parent(&*frame_iso)
            .build(&mut l);
        iso_items.borrow_mut().push(PageItem {
            ctl: PageCtl::Lbl(l, 0),
            x: 26,
            y: *y,
            w: -20,
            h: 18,
            idx: 0,
        });
        *y += 22;
    };
    // radio row (kind: 0=distro, 1=local iso, 2=existing usb).
    // `group` marks the FIRST radio of a section: it carries WS_GROUP, which
    // ends the previous section's group and starts this one, so Win32's
    // auto-uncheck keeps every section mutually exclusive on its own.
    let add_radio = |text: &str, checked: bool, kind: u8, group: bool, y: &mut i32| {
        let mut rb: Box<nwg::RadioButton> = Box::default();
        let _ = nwg::RadioButton::builder()
            .flags(if group {
                nwg::RadioButtonFlags::VISIBLE | nwg::RadioButtonFlags::GROUP
            } else {
                nwg::RadioButtonFlags::VISIBLE
            })
            .text(text)
            .position((10, *y))
            .size((780, 20))
            .parent(&*frame_iso)
            .build(&mut rb);
        if checked {
            rb.set_check_state(nwg::RadioButtonState::Checked);
        }
        iso_items.borrow_mut().push(PageItem {
            ctl: PageCtl::Radio(rb, kind),
            x: 10,
            y: *y,
            w: -20,
            h: 20,
            idx: 0,
        });
        *y += 24;
    };

    // an existing, up-to-date, right-sized Mint ISO beats a fresh download:
    // pre-select it (the harvest re-checks this at Install time too)
    let mint_iso_name = format!("linuxmint-{}-cinnamon-64bit.iso", mint_version);
    let have_mint = find_matching_local_iso(&mint_iso_name, MIN_ISO_SIZE);
    add_label("Download Fresh (Ram required/recommend):", &mut y);
    for (i, (name, _url)) in DISTRO_OPTIONS.iter().enumerate() {
        add_radio(name, i == rec && have_mint.is_none(), 0, i == 0, &mut y);
    }
    add_label("Use Already Downloaded ISO:", &mut y);
    let found_isos = {
        let mut v = crate::lslfiles::find_everything_isos();
        if v.is_empty() {
            v = crate::lslfiles::find_local_isos();
        }
        v
    };
    // Arch consistency: a 64-bit ISO is never "recommended" (nor
    // pre-selected) on a 32-bit-only machine - the header above says antiX
    // there, and a 64-bit live USB would not boot. Unknown-arch ISOs are
    // left alone (treated as compatible).
    let cpu64 = is_64bit_capable();
    for (n, iso) in found_isos.iter().take(10).enumerate() {
        let sz = sys::file_size(iso).unwrap_or(0);
        let is_the_mint = have_mint.as_deref() == Some(iso.as_str());
        let too_new = !cpu64 && iso_arch_64(iso) == Some(true);
        let mut label = format!("{}  ({:.2} GB)", iso, sz as f64 / sys::GB as f64);
        if too_new {
            label.push_str("  <- 64-bit: will NOT boot this 32-bit machine");
        } else if is_the_mint {
            label.push_str("  <- recommended (up-to-date, reuse instead of downloading)");
        }
        add_radio(&label, is_the_mint && !too_new, 1, n == 0, &mut y);
    }
    if found_isos.is_empty() {
        add_plain("(none found)", &mut y);
    }
    add_label("Use an existing Live USB (skips ISO download + Rufus):", &mut y);
    let existing_usbs: Vec<sys::Volume> = {
        let mut v = sys::find_usb_volumes("", &[]);
        v.retain(|v| v.has_casper_squashfs());
        v
    };
    for (n, u) in existing_usbs.iter().enumerate() {
        add_radio(&format!("{}:  {}  ({:.1} GB)", u.letter, u.label, u.size_gb()), false, 2, n == 0, &mut y);
    }
    if existing_usbs.is_empty() {
        add_plain("(none found)", &mut y);
    }
    let iso_content = y + 10;

    // NOTE: the USB write-method radios used to live here; they moved to
    // page 5 (INSTALL NOW) so the choice is made at install time, like
    // install.ps1 - and so no Rufus radio appears before the INSTALL page.

    if let Err(e) = nwg::ScrollBar::builder()
        .flags(nwg::ScrollBarFlags::VERTICAL | nwg::ScrollBarFlags::VISIBLE)
        .position((826, 4))
        .size((18, 588))
        .parent(&*frame_iso)
        .build(&mut sb_iso)
    {
        glog(&format!("scrollbar build error: {e:?}"));
    }

    // fixed controls at the bottom of the page
    let _ = nwg::Button::builder()
        .text("Install Everything (voidtools)")
        .position((10, 566))
        .size((400, 26))
        .parent(&*frame_iso)
        .build(&mut btn_everything);
        let btn_everything = Rc::new(btn_everything);
    if !crate::lslfiles::everything_path().is_empty() {
        btn_everything.set_text("Everything already installed (search ready)");
    }

    // ---- page 2: flatpaks (scrollable checkbox grid + extras) ----
    let _ = nwg::Frame::builder()
        .position((MARGIN, 88))
        .size((DEF_CW - 2 * MARGIN, DEF_CH - 88 - NAV_H))
        .parent(&window)
        .build(&mut frame_fp);
        let frame_fp = Rc::new(frame_fp);
    let _ = nwg::Label::builder()
        .text("Flatpak apps to preload (checked = installed from Windows):")
        .position((10, 6))
        .size((560, 18))
        .parent(&*frame_fp)
        .build(&mut lbl_fp);
    let sugg = crate::hardware::flatpak_suggestions();
    for (i, (app, _id, matched)) in sugg.iter().enumerate() {
        let mut cb: Box<nwg::CheckBox> = Box::default();
        let _ = nwg::CheckBox::builder()
            .text(app)
            .position((10, 30))
            .size((275, 20))
            .parent(&*frame_fp)
            .build(&mut cb);
        if *matched {
            cb.set_check_state(nwg::CheckBoxState::Checked);
        }
        fp_items.borrow_mut().push(PageItem {
            ctl: PageCtl::Check(cb, 0),
            x: 10,
            y: 30,
            w: 275,
            h: 20,
            idx: i,
        });
    }
    // extras (reflowed below the grid by relayout_fp)
    {
        let mut cb: Box<nwg::CheckBox> = Box::default();
        let _ = nwg::CheckBox::builder()
            .text("FSearch (Everything-style file search)")
            .position((10, 240))
            .size((560, 20))
            .parent(&*frame_fp)
            .build(&mut cb);
        cb.set_check_state(nwg::CheckBoxState::Checked);
        fp_items.borrow_mut().push(PageItem {
            ctl: PageCtl::Check(cb, 1),
            x: 10,
            y: 240,
            w: -20,
            h: 20,
            idx: 0,
        });
        let mut l: Box<nwg::Label> = Box::default();
        let _ = nwg::Label::builder()
            .text("Extra flatpak IDs (comma-separated):")
            .position((10, 270))
            .size((560, 18))
            .parent(&*frame_fp)
            .build(&mut l);
        fp_items.borrow_mut().push(PageItem {
            ctl: PageCtl::Lbl(l, 1),
            x: 10,
            y: 270,
            w: -20,
            h: 18,
            idx: 0,
        });
        let mut e: Box<nwg::TextBox> = Box::default();
        let _ = nwg::TextBox::builder()
            .flags(multiline_edit_flags())
            .position((10, 290))
            .size((560, 76))   // 4 lines deep
            .text(&flatpak_extra.join(", "))
            .parent(&*frame_fp)
            .build(&mut e);
        // (Win10/11) re-assert the height: a multiline edit can otherwise
        // auto-size to its content and squash to a few pixels.
        e.set_size(560, 76);
        fp_items.borrow_mut().push(PageItem {
            ctl: PageCtl::Edit(e, 1),
            x: 10,
            y: 290,
            w: -20,
            h: 76,
            idx: 0,
        });
    }
    if let Err(e) = nwg::ScrollBar::builder()
        .flags(nwg::ScrollBarFlags::VERTICAL | nwg::ScrollBarFlags::VISIBLE)
        .position((826, 4))
        .size((18, 588))
        .parent(&*frame_fp)
        .build(&mut sb_fp)
    {
        glog(&format!("scrollbar build error: {e:?}"));
    }

    // ---- page 3: system (scrollable single column) ----
    // Single column so the page works at any width (two columns need ~800
    // px); wifi lives on its own page now, so the VHDX box gets the
    // freed space.
    let _ = nwg::Frame::builder()
        .position((MARGIN, 88))
        .size((DEF_CW - 2 * MARGIN, DEF_CH - 88 - NAV_H))
        .parent(&window)
        .build(&mut frame_sys);
        let frame_sys = Rc::new(frame_sys);
    {
        let push_lbl = |sys: &mut Vec<PageItem>, text: &str, x: i32, y: i32, w: i32, h: i32, bold: bool| {
            // Final width mirrors layout_page's formula (w<0 = fill the
            // frame). Bare SS_LEFT statics do not reliably re-wrap when
            // resized, so pre-wrap the text to the final width — otherwise
            // long notes render as one clipped line ("...uses that").
            let final_w = if w > 0 { w } else { (850 - 10 + w - x).max(60) };
            let per_line = (((final_w - 8) / 9).max(10)) as usize;
            let mut l: Box<nwg::Label> = Box::default();
            let _ = nwg::Label::builder()
                .text(&wrap_text(text, per_line))
                .position((x, y))
                .size((final_w, h))
                .parent(&*frame_sys)
                .build(&mut l);
            if bold {
                l.set_font(Some(&font_bold));
            }
            sys.push(PageItem { ctl: PageCtl::Lbl(l, 0), x, y, w, h, idx: 0 });
        };
        let push_check = |sys: &mut Vec<PageItem>, text: &str, x: i32, y: i32, kind: u8, checked: bool| {
            let mut cb: Box<nwg::CheckBox> = Box::default();
            let _ = nwg::CheckBox::builder()
                .text(text)
                .position((x, y))
                .size((560, 20))
                .parent(&*frame_sys)
                .build(&mut cb);
            if checked {
                cb.set_check_state(nwg::CheckBoxState::Checked);
            }
            sys.push(PageItem { ctl: PageCtl::Check(cb, kind), x, y, w: -20, h: 20, idx: 0 });
        };
        let mut sys = sys_items.borrow_mut();
        push_lbl(&mut sys, "WSL VHDX paths (one per line):", 10, 6, -20, 18, false);
        let mut vhdx: Box<nwg::TextBox> = Box::default();
        let _ = nwg::TextBox::builder()
            .flags(multiline_edit_flags())
            .position((10, 26))
            .size((410, 160))
            .text(&{
                let found = crate::detect::wsl_vhdx_paths(wsl_vhdx_pre);
                if found.is_empty() {
                    "(none found)".to_string()
                } else {
                    found.join("\r\n")
                }
            })
            .parent(&*frame_sys)
            .build(&mut vhdx);
        // (Win10/11) re-assert the height (see multiline_edit_flags).
        vhdx.set_size(410, 160);
        sys.push(PageItem { ctl: PageCtl::Edit(vhdx, 1), x: 10, y: 26, w: -20, h: 160, idx: 0 });
        push_lbl(&mut sys, "LSL_DATA_DIR (Linux path, e.g. /mnt/c/Users/you/lsl-usb):", 10, 192, -20, 18, false);
        let default_data = format!(
            "/mnt/c/Users/{}/lsl-usb",
            sys::env_var("USERNAME").unwrap_or_default()
        );
        let mut data: Box<nwg::TextInput> = Box::default();
        let _ = nwg::TextInput::builder()
            .position((10, 212))
            .size((290, 22))
            .text(&default_data)
            .parent(&*frame_sys)
            .build(&mut data);
        sys.push(PageItem { ctl: PageCtl::EditLine(data, 2), x: 10, y: 212, w: -134, h: 22, idx: 0 });
        let mut browse: Box<nwg::Button> = Box::default();
        let _ = nwg::Button::builder()
            .text("Browse...")
            .position((760, 211))
            .size((90, 24))
            .parent(&*frame_sys)
            .build(&mut browse);
        sys.push(PageItem { ctl: PageCtl::Btn(browse, 3), x: -124, y: 211, w: 90, h: 24, idx: 0 });
        push_check(&mut sys, "Export Everything index for Linux file browsing (can be large)", 10, 242, 4, true);
        push_check(&mut sys, "Preload Linux drivers for this PC network hardware", 10, 264, 5, true);
        let drv_needs = crate::hardware::resolve_driver_needs(&crate::hardware::network_hardware());
        let drv_text = if drv_needs.is_empty() {
            "No special network drivers needed (ISO kernel covers this machine).".to_string()
        } else {
            format!(
                "Detected: {}",
                drv_needs
                    .iter()
                    .map(|(_, t)| t.chip)
                    .collect::<Vec<_>>()
                    .join(", ")
            )
        };
        push_lbl(&mut sys, &drv_text, 20, 284, -30, 20, false);
        push_check(&mut sys, "Copy Linux squashfs layers to your NTFS drive for faster boot", 10, 306, 6, true);
        push_check(&mut sys, "Reclaim Windows pagefile.sys + WSL2 swapfile as compressed swap", 10, 328, 7, false);
        push_lbl(&mut sys, PAGEFILE_NOTE, 20, 350, -30, 76, false);
        push_check(&mut sys, "Preload Rust CLI tools for the selected distro (fd / bat / zoxide)", 10, 430, 8, false);
    }
    if let Err(e) = nwg::ScrollBar::builder()
        .flags(nwg::ScrollBarFlags::VERTICAL | nwg::ScrollBarFlags::VISIBLE)
        .position((826, 4))
        .size((18, 588))
        .parent(&*frame_sys)
        .build(&mut sb_sys)
    {
        glog(&format!("scrollbar build error: {e:?}"));
    }

    let sys_content = 430 + 20 + 10;

    // ---- page 4: wifi (master switch + per-network list) ----
    let _ = nwg::Frame::builder()
        .position((MARGIN, 88))
        .size((DEF_CW - 2 * MARGIN, DEF_CH - 88 - NAV_H))
        .parent(&window)
        .build(&mut frame_wifi);
        let frame_wifi = Rc::new(frame_wifi);
    {
        let mut wifi = wifi_items.borrow_mut();
        let mut master: Box<nwg::CheckBox> = Box::default();
        let _ = nwg::CheckBox::builder()
            .text("Copy Wifi Settings to LSL")
            .position((10, 6))
            .size((560, 20))
            .parent(&*frame_wifi)
            .build(&mut master);
        master.set_check_state(nwg::CheckBoxState::Checked);
        wifi.push(PageItem { ctl: PageCtl::Check(master, 9), x: 10, y: 6, w: -20, h: 20, idx: 0 });
        let mut cap: Box<nwg::Label> = Box::default();
        let _ = nwg::Label::builder()
            .text("Networks to copy (checked = include in wifi.sh):")
            .position((10, 30))
            .size((560, 18))
            .parent(&*frame_wifi)
            .build(&mut cap);
        cap.set_font(Some(&font_bold));
        wifi.push(PageItem { ctl: PageCtl::Lbl(cap, 0), x: 10, y: 30, w: -30, h: 18, idx: 0 });
        if wifi_names.is_empty() {
            let mut none: Box<nwg::Label> = Box::default();
            let _ = nwg::Label::builder()
                .text("No saved wifi profiles found.")
                .position((20, WIFI_Y0))
                .size((560, 20))
                .parent(&*frame_wifi)
                .build(&mut none);
            wifi.push(PageItem { ctl: PageCtl::Lbl(none, 0), x: 20, y: WIFI_Y0, w: -30, h: 20, idx: 0 });
        }
    }
    if let Err(e) = nwg::ScrollBar::builder()
        .flags(nwg::ScrollBarFlags::VERTICAL | nwg::ScrollBarFlags::VISIBLE)
        .position((826, 4))
        .size((18, 588))
        .parent(&*frame_wifi)
        .build(&mut sb_wifi)
    {
        glog(&format!("scrollbar build error: {e:?}"));
    }

    // wifi networks (below the wifi items; they scroll with the page)
    let wifi_checks: std::rc::Rc<std::cell::RefCell<Vec<Box<nwg::CheckBox>>>> =
        std::rc::Rc::new(std::cell::RefCell::new(Vec::with_capacity(
            wifi_names.len().min(10),
        )));
    for name in wifi_names.iter().take(10) {
        let mut cb: Box<nwg::CheckBox> = Box::default();
        let _ = nwg::CheckBox::builder()
            .text(name)
            .position((20, WIFI_Y0 + (wifi_checks.borrow().len() as i32) * 20))
            .size((540, 20))
            .parent(&*frame_wifi)
            .build(&mut cb);
        cb.set_check_state(nwg::CheckBoxState::Checked);
        wifi_checks.borrow_mut().push(cb);
    }
    let wifi_content = WIFI_Y0 + (wifi_checks.borrow().len() as i32).max(1) * 20 + 10;

    // ---- page 5: INSTALL NOW (USB write method + target USB picker) ----
    let _ = nwg::Frame::builder()
        .position((MARGIN, 88))
        .size((DEF_CW - 2 * MARGIN, DEF_CH - 88 - NAV_H))
        .parent(&window)
        .build(&mut frame_install);
        let frame_install = Rc::new(frame_install);
    {
        let mut items = install_items.borrow_mut();
        let mut iy = 6i32;
        // title (bold) - the win-install-page GUI test keys on this text
        let mut title: Box<nwg::Label> = Box::default();
        let _ = nwg::Label::builder()
            .text("INSTALL NOW")
            .position((10, iy))
            .size((560, 24))
            .parent(&*frame_install)
            .build(&mut title);
        title.set_font(Some(&font_bold));
        items.push(PageItem { ctl: PageCtl::Lbl(title, 0), x: 10, y: iy, w: -20, h: 24, idx: 0 });
        iy += 28;
        let mut help: Box<nwg::Label> = Box::default();
        let _ = nwg::Label::builder()
            .text("Choose how to write the live image to the USB, then click Install.")
            .position((10, iy))
            .size((560, 18))
            .parent(&*frame_install)
            .build(&mut help);
        items.push(PageItem { ctl: PageCtl::Lbl(help, 0), x: 10, y: iy, w: -20, h: 18, idx: 0 });
        iy += 26;
        // write-method radios (kind 3): one group, exactly one checked
        // Rufus (any version, incl. the Win7-compatible 3.22) requires
        // Windows 7 or later. On older Windows the radio is greyed out with
        // an explanatory tooltip and the default falls back to the built-in
        // non-destructive write.
        let rufus_ok = !matches!(
            sys::os_ver(),
            sys::OsVer::Win9x
                | sys::OsVer::Nt4
                | sys::OsVer::Win2000
                | sys::OsVer::Xp
                | sys::OsVer::Vista
        );
        let effective_pre = if !rufus_ok && write_mode_pre == "rufus" {
            "nofmt"
        } else {
            write_mode_pre
        };
        let mut rufus_tt: Option<&'static mut nwg::Tooltip> = None;
        let methods = [
            ("Rufus (recommended - well tested, UEFI + BIOS; rewrites the stick)", "rufus"),
            ("Built-in non-destructive (less tested - no reformat, keeps existing files; BIOS + UEFI)", "nofmt"),
            ("Skip - I will write the USB myself (like --skip-rufus)", "skip"),
        ];
        for (n, (text, mode)) in methods.iter().enumerate() {
            let mut rb: Box<nwg::RadioButton> = Box::default();
            let _ = nwg::RadioButton::builder()
                .flags(if n == 0 {
                    nwg::RadioButtonFlags::VISIBLE | nwg::RadioButtonFlags::GROUP
                } else {
                    nwg::RadioButtonFlags::VISIBLE
                })
                .text(*text)
                .position((10, iy))
                .size((780, 20))
                .parent(&*frame_install)
                .build(&mut rb);
            if *mode == "rufus" && !rufus_ok {
                rb.set_enabled(false);
                if rufus_tt.is_none() {
                    let mut tt: nwg::Tooltip = Default::default();
                    let _ = nwg::Tooltip::builder().build(&mut tt);
                    rufus_tt = Some(Box::leak(Box::new(tt)));
                }
                rufus_tt.as_mut().unwrap().register(
                    rb.as_ref(),
                    "Rufus requires Windows 7 or later - use the built-in non-destructive write instead.",
                );
            } else if effective_pre == *mode {
                rb.set_check_state(nwg::RadioButtonState::Checked);
            }
            items.push(PageItem { ctl: PageCtl::Radio(rb, 3), x: 10, y: iy, w: -20, h: 20, idx: 0 });
            iy += 24;
        }
        // BIOS/UEFI boot checkboxes (Check kinds 5/6): on by default when
        // the selected stick supports them, greyed out with the reason in
        // the label when not (e.g. GPT disables BIOS, NTFS/exFAT or a
        // missing loader disables UEFI). Refreshed on target clicks.
        let mut bios_tt: nwg::Tooltip = Default::default();
        let _ = nwg::Tooltip::builder().build(&mut bios_tt);
        let mut uefi_tt: nwg::Tooltip = Default::default();
        let _ = nwg::Tooltip::builder().build(&mut uefi_tt);
        for (kind, text) in [(5u8, "BIOS/CSM boot (grub4dos MBR, no reformat)"), (6u8, "UEFI boot (BOOTX64.EFI, Secure Boot off)")] {
            let mut cb: Box<nwg::CheckBox> = Box::default();
            let _ = nwg::CheckBox::builder()
                .text(text)
                .position((10, iy))
                .size((780, 20))
                .parent(&*frame_install)
                .build(&mut cb);
            cb.set_check_state(nwg::CheckBoxState::Checked);
            if kind == 5 {
                bios_tt.register(cb.as_ref(), "grub4dos boots via BIOS/CSM firmware from the MBR boot code + sectors 1-15. Needs FAT/NTFS on an MBR-partitioned stick.");
            } else {
                uefi_tt.register(cb.as_ref(), "UEFI boot needs a FAT32 stick plus a BOOTX64.EFI loader (vendored assets/BOOTX64.EFI at build time, or --uefi-bootx64). NTFS/GPT+NTFS single-partition sticks cannot UEFI-boot without a separate FAT32 ESP - that is also how Windows does it.");
            }
            items.push(PageItem { ctl: PageCtl::Check(cb, kind), x: 10, y: iy, w: -20, h: 20, idx: 0 });
            iy += 24;
        }
        // This-machine firmware line (Lbl kind 7): refreshed whenever the
        // BIOS/UEFI checkboxes or the target change. Board detection says
        // what THIS motherboard can boot; the stick may target another PC,
        // so this warns, never blocks.
        let mut fwline: Box<nwg::Label> = Box::default();
        let _ = nwg::Label::builder()
            .text("")
            .position((10, iy))
            .size((780, 20))
            .parent(&*frame_install)
            .build(&mut fwline);
        items.push(PageItem { ctl: PageCtl::Lbl(fwline, 7), x: 10, y: iy, w: -20, h: 20, idx: 0 });
        iy += 24;
        // Whole-USB surface check (Check kind 8): off by default (slow -
        // fills free space with PRNG data and reads it back uncached).
        // Runs after the write for Rufus AND built-in alike.
        let mut check_tt: nwg::Tooltip = Default::default();
        let _ = nwg::Tooltip::builder().build(&mut check_tt);
        {
            let mut cb: Box<nwg::CheckBox> = Box::default();
            let _ = nwg::CheckBox::builder()
                .text("Check whole USB after writing (slow: fills free space, verifies, cleans up)")
                .position((10, iy))
                .size((780, 20))
                .parent(&*frame_install)
                .build(&mut cb);
            check_tt.register(cb.as_ref(), "Adds a DeleteMe folder, fills free space with 4 GB pseudo-random chunks, reads every byte back with OS caching DISABLED (bad/fake sticks cannot hide), then deletes DeleteMe. Catches dying and fake-capacity flash.");
            items.push(PageItem { ctl: PageCtl::Check(cb, 8), x: 10, y: iy, w: -20, h: 20, idx: 0 });
            iy += 24;
        }
        // Skip-verify checkbox (Check kind 9): off by default (verification
        // stays on unless the user opts out; skipped copies are size-match
        // only and corruption shows up at boot, not here).
        {
            let mut cb: Box<nwg::CheckBox> = Box::default();
            let _ = nwg::CheckBox::builder()
                .text("Skip USB copy verification (faster; corruption would only show at boot)")
                .position((10, iy))
                .size((780, 20))
                .parent(&*frame_install)
                .build(&mut cb);
            items.push(PageItem { ctl: PageCtl::Check(cb, 9), x: 10, y: iy, w: -20, h: 20, idx: 0 });
            iy += 24;
        }
        let mut note: Box<nwg::Label> = Box::default();
        let note_text = if rufus_ok {
            "Rufus launches with the ISO pre-selected (you click START there). Built-in copies the image files with no format."
        } else {
            "Rufus requires Windows 7 or later and is disabled here - use the built-in non-destructive write (or Skip)."
        };
        let _ = nwg::Label::builder()
            .text(note_text)
            .position((10, iy))
            .size((560, 18))
            .parent(&*frame_install)
            .build(&mut note);
        items.push(PageItem { ctl: PageCtl::Lbl(note, 0), x: 10, y: iy, w: -20, h: 18, idx: 0 });
        iy += 26;
        // target USB picker (kind 4): removable volumes, first pre-checked
        let mut cap: Box<nwg::Label> = Box::default();
        let _ = nwg::Label::builder()
            .text("Target USB (for the non-destructive copy):")
            .position((10, iy))
            .size((560, 18))
            .parent(&*frame_install)
            .build(&mut cap);
        cap.set_font(Some(&font_bold));
        items.push(PageItem { ctl: PageCtl::Lbl(cap, 0), x: 10, y: iy, w: -20, h: 18, idx: 0 });
        iy += 22;
        let mut targets: Vec<sys::Volume> = sys::list_volumes()
            .into_iter()
            .filter(|v| v.removable && !v.cdrom && !v.letter.is_empty())
            .collect();
        targets.sort_by(|a, b| a.letter.cmp(&b.letter));
        if targets.is_empty() {
            let mut none: Box<nwg::Label> = Box::default();
            let _ = nwg::Label::builder()
                .text("[No removable USB drives detected]")
                .position((26, iy))
                .size((560, 20))
                .parent(&*frame_install)
                .build(&mut none);
            items.push(PageItem { ctl: PageCtl::Lbl(none, 0), x: 26, y: iy, w: -20, h: 20, idx: 0 });
            iy += 24;
        }
        for (n, u) in targets.iter().enumerate() {
            let mut rb: Box<nwg::RadioButton> = Box::default();
            let _ = nwg::RadioButton::builder()
                .flags(if n == 0 {
                    nwg::RadioButtonFlags::VISIBLE | nwg::RadioButtonFlags::GROUP
                } else {
                    nwg::RadioButtonFlags::VISIBLE
                })
                .text(&format!("{}:  {}  {}  ({:.1} GB)", u.letter, u.label, u.fs, u.size_gb()))
                .position((10, iy))
                .size((780, 20))
                .parent(&*frame_install)
                .build(&mut rb);
            if n == 0 {
                rb.set_check_state(nwg::RadioButtonState::Checked);
            }
            items.push(PageItem { ctl: PageCtl::Radio(rb, 4), x: 10, y: iy, w: -20, h: 20, idx: 0 });
            iy += 24;
        }
        // default the BIOS/UEFI checkboxes to the preselected stick
        let first_letter = targets.first().map(|u| u.letter.clone()).unwrap_or_default();
        drop(items); // release the borrow_mut above: apply re-borrows
        apply_boot_caps(&install_items, &first_letter, "", true);
    }
    let install_content = {
        let items = install_items.borrow();
        items.iter().map(|it| it.y + it.h).max().unwrap_or(0) + 10
    };
    if let Err(e) = nwg::ScrollBar::builder()
        .flags(nwg::ScrollBarFlags::VERTICAL | nwg::ScrollBarFlags::VISIBLE)
        .position((826, 4))
        .size((18, 588))
        .parent(&*frame_install)
        .build(&mut sb_install)
    {
        glog(&format!("scrollbar build error: {e:?}"));
    }
    let sb_install = Rc::new(sb_install);

    // ---- nav buttons ----
    let _ = nwg::Button::builder()
        .text("< Back")
        .position((660, 706))
        .size((90, 28))
        .parent(&window)
        .build(&mut btn_back);
        let btn_back = Rc::new(btn_back);
    btn_back.set_enabled(false);
    let _ = nwg::Button::builder()
        .text("Next >")
        .position((756, 706))
        .size((96, 28))
        .parent(&window)
        .build(&mut btn_next);
        let btn_next = Rc::new(btn_next);
    let _ = nwg::Button::builder()
        .text("Cancel")
        .position((562, 706))
        .size((90, 28))
        .parent(&window)
        .build(&mut btn_cancel);
        let btn_cancel = Rc::new(btn_cancel);

    // persistent ISO download progress: the label owns the full-width band
    // above the nav buttons, the bar rides the button row between Cancel
    // and Back (see relayout, which positions both from the live client
    // size so they never overlap the pages above or the buttons below).
    // Parented to the WINDOW so the progress stays visible on every page.
    let mut lbl_dl: nwg::Label = Default::default();
    let mut pb_dl: nwg::ProgressBar = Default::default();
    let _ = nwg::Label::builder()
        .text("")
        .position((12, 696))
        .size((856, 20))
        .parent(&window)
        .build(&mut lbl_dl);
    let _ = nwg::ProgressBar::builder()
        .position((114, 727))
        .size((552, 14))
        .parent(&window)
        .build(&mut pb_dl);
    lbl_dl.set_visible(false);
    pb_dl.set_visible(false);

    // working-phase status: big centered text shown after the Install click
    // while the ISO is resolved and Rufus is fetched/launched - the window
    // stays visible instead of vanishing before Rufus appears
    let mut lbl_working: nwg::Label = Default::default();
    let _ = nwg::Label::builder()
        .text("Preparing the USB install...")
        .position((60, 320))
        .size((760, 100))
        .parent(&window)
        .build(&mut lbl_working);
    lbl_working.set_font(Some(&font_bold));
    lbl_working.set_visible(false);

    // ---- FINISHED / FAILED summary page ----
    // A dedicated frame + heading + readonly body + one button, all hidden
    // until the working phase ends. The body is a readonly multiline textbox
    // (copyable) so a long SUMMARY / automation command line can be read.
    // nwg control ownership stays here; WorkingUi only holds their HWNDs.
    let mut sum_frame: nwg::Frame = Default::default();
    let mut sum_heading: nwg::Label = Default::default();
    let mut sum_body: nwg::TextBox = Default::default();
    let mut sum_btn: nwg::Button = Default::default();
    let _ = nwg::Frame::builder()
        .position((MARGIN, 78))
        .size((DEF_CW - 2 * MARGIN, DEF_CH - 78 - NAV_H))
        .parent(&window)
        .build(&mut sum_frame);
    let _ = nwg::Label::builder()
        .text("")
        .position((MARGIN + 10, 84))
        .size((800, 22))
        .parent(&window)
        .build(&mut sum_heading);
    sum_heading.set_font(Some(&font_bold));
    let _ = nwg::TextBox::builder()
        .text("")
        .position((MARGIN + 10, 112))
        .size((820, 500))
        .flags(summary_body_flags())
        .readonly(true)
        .parent(&window)
        .build(&mut sum_body);
    let _ = nwg::Button::builder()
        .text("Finish")
        .position((DEF_CW - MARGIN - 96, 706))
        .size((96, 28))
        .parent(&window)
        .build(&mut sum_btn);
    // extra summary-page buttons: copy the body (the automation command / the
    // error text) to the clipboard, and open the first manual-download URL.
    let mut sum_copy: nwg::Button = Default::default();
    let mut sum_open: nwg::Button = Default::default();
    let _ = nwg::Button::builder()
        .text("Copy")
        .position((DEF_CW - MARGIN - 96 - 96 - 8, 706))
        .size((90, 28))
        .parent(&window)
        .build(&mut sum_copy);
    let _ = nwg::Button::builder()
        .text("Open manual download")
        .position((MARGIN, 706))
        .size((150, 28))
        .parent(&window)
        .build(&mut sum_open);
    sum_frame.set_visible(false);
    sum_body.set_visible(false);
    sum_heading.set_visible(false);
    sum_btn.set_visible(false);
    sum_copy.set_visible(false);
    sum_open.set_visible(false);
    sum_btn_h.set(sum_btn.handle.hwnd().map(|h| h as usize).unwrap_or(0));
    sum_copy_h.set(sum_copy.handle.hwnd().map(|h| h as usize).unwrap_or(0));
    sum_open_h.set(sum_open.handle.hwnd().map(|h| h as usize).unwrap_or(0));
    // FAILED-page escape hatch: back to the INSTALL page to pick another
    // method (e.g. Rufus) instead of only closing with an error code.
    let mut sum_back: nwg::Button = Default::default();
    let _ = nwg::Button::builder()
        .text("< Back to install options")
        .position((MARGIN, 706))
        .size((170, 28))
        .parent(&window)
        .build(&mut sum_back);
    sum_back.set_visible(false);
    sum_back_h.set(sum_back.handle.hwnd().map(|h| h as usize).unwrap_or(0));

    // ---- first relayout pass (everything now exists) ----
    relayout(
        &LayoutCtx {
            lbl_sb: &lbl_sb,
            sb_text: &sb_text,
            frame_hw: &*frame_hw,
            frame_iso: &*frame_iso,
            frame_fp: &*frame_fp,
            frame_sys: &*frame_sys,
            frame_wifi: &*frame_wifi,
            frame_install: &*frame_install,
            lbl_hw: &lbl_hw,
            lv_hw: &lv_hw,
            lbl_rec: &lbl_rec,
            lbl_rec_help: &lbl_rec_help,
            rec_help_text: &rec_help,
            lbl_fp: &lbl_fp,
            sb_iso: &sb_iso,
            sb_fp: &sb_fp,
            sb_sys: &sb_sys,
            sb_wifi: &sb_wifi,
            sb_install: &*sb_install,
            btn_everything: &*btn_everything,
            btn_back: &*btn_back,
            btn_next: &*btn_next,
            btn_cancel: &*btn_cancel,
            btn_reboot: &*btn_reboot,
            lbl_dl: &lbl_dl,
            pb_dl: &pb_dl,
            iso: &iso_items,
            fp: &fp_items,
            sys: &sys_items,
            wifi_items: &wifi_items,
            install: &install_items,
            wifi: &wifi_checks,
            fw: &fw_cell,
            iso_off: &iso_off,
            fp_off: &fp_off,
            sys_off: &sys_off,
            wifi_off: &wifi_off,
            install_off: &install_off,
            iso_geom: &iso_geom,
            fp_geom: &fp_geom,
            sys_geom: &sys_geom,
            wifi_geom: &wifi_geom,
            install_geom: &install_geom,
            fp_content: &fp_content,
            guard: &in_relayout,
            iso_content: iso_content,
            sys_content: sys_content,
            wifi_content: wifi_content,
            install_content: install_content,
        },
        cw,
        ch,
    );

    // Hide pages 1-5 only AFTER all controls exist (their children were built
    // while the frame was visible, which wine requires). Only now, with all
    // six pages positioned and five of them hidden, is the window shown -
    // so the user only ever sees page 0, never the build-time stack.
    frame_iso.set_visible(false);
    frame_fp.set_visible(false);
    frame_sys.set_visible(false);
    frame_wifi.set_visible(false);
    frame_install.set_visible(false);
    window.set_visible(true);

    // ---- background hardware rating (starts immediately) ----
    let bundle_dir = std::env::current_exe()
        .map(|p| {
            let s = p.to_string_lossy().into_owned();
            match s.rfind('\\') {
                Some(i) => s[..i].to_string(),
                None => ".".into(),
            }
        })
        .unwrap_or_else(|_| ".".into());
    spawn_hw_rating(tx.clone(), bundle_dir);

    // ---- scroll handlers (raw, one per scrollable page) ----
    // NOTE: these must outlive this scope — dropping them drops the closures
    // and their moved state. The ScrollBars themselves stay in this scope
    // (their Drop impl DESTROYS the window); only HWND copies go in here.
    let _scroll_handlers = (
        bind_page_scroll(
            &*frame_iso,
            0x4C56_01usize,
            sb_iso.handle.hwnd(),
            iso_items.clone(),
            iso_geom.clone(),
            iso_off.clone(),
            fw_cell.clone(),
        ),
        bind_page_scroll(
            &*frame_fp,
            0x4C56_02usize,
            sb_fp.handle.hwnd(),
            fp_items.clone(),
            fp_geom.clone(),
            fp_off.clone(),
            fw_cell.clone(),
        ),
        bind_page_scroll(
            &*frame_sys,
            0x4C56_03usize,
            sb_sys.handle.hwnd(),
            sys_items.clone(),
            sys_geom.clone(),
            sys_off.clone(),
            fw_cell.clone(),
        ),
        bind_page_scroll(
            &*frame_wifi,
            0x4C56_04usize,
            sb_wifi.handle.hwnd(),
            wifi_items.clone(),
            wifi_geom.clone(),
            wifi_off.clone(),
            fw_cell.clone(),
        ),
        bind_page_scroll(
            &*frame_install,
            0x4C56_05usize,
            sb_install.handle.hwnd(),
            install_items.clone(),
            install_geom.clone(),
            install_off.clone(),
            fw_cell.clone(),
        ),
    );

    // click-routing: HWND copies for controls living in the shared storage
    let master_hwnd = ctl_hwnd(&wifi_items, 9).unwrap_or(0);
    let browse_hwnd = ctl_hwnd(&sys_items, 3).unwrap_or(0);
    // the main closure moves `window`, so keep only an HWND copy for relayout
    let win_hwnd = window.handle.hwnd();

    // ---- events ----
    let c2 = cancelled.clone();
    let f2 = confirmed.clone();
    let p2 = page.clone();
    let working = Rc::new(Cell::new(false));
    let ui_cell: Rc<std::cell::RefCell<Option<WorkingUi>>> =
        Rc::new(std::cell::RefCell::new(None));
    let g_cell: Rc<std::cell::RefCell<Option<GuiResult>>> =
        Rc::new(std::cell::RefCell::new(None));
    let working2 = working.clone();
    let ui_cell2 = ui_cell.clone();
    let g_cell2 = g_cell.clone();
    let iso_arg2 = iso_arg.to_string();
    let browse_data_sys = sys_items.clone();
    let _handlers = nwg::full_bind_event_handler(&window.handle, {
        // clones for the move closure; the outer harvest still uses the Rc originals
        let boot_usb_c = boot_usb.clone();
        let boot_adv_c = boot_adv.clone();
        let boot_fw_c = boot_fw.clone();
        let boot_none_c = boot_none.clone();
        let wifi_checks = wifi_checks.clone();
        let iso_items = iso_items.clone();
        let fp_items = fp_items.clone();
        let sys_items = sys_items.clone();
        let wifi_items = wifi_items.clone();
        let install_items = install_items.clone();
        let bg_downloads = bg_downloads.clone();
        let download_dir = download_dir.to_string();
        let distro_urls = distro_urls.clone();
        let fw_cell = fw_cell.clone();
        let iso_off = iso_off.clone();
        let fp_off = fp_off.clone();
        let sys_off = sys_off.clone();
        let wifi_off = wifi_off.clone();
        let install_off = install_off.clone();
        let iso_geom = iso_geom.clone();
        let fp_geom = fp_geom.clone();
        let sys_geom = sys_geom.clone();
        let wifi_geom = wifi_geom.clone();
        let install_geom = install_geom.clone();
        let fp_content = fp_content.clone();
        let in_relayout = in_relayout.clone();
        let sb_text_ref = sb_text.clone();
        let rec_help_ref = rec_help.clone();
        let iso_content = iso_content;
        let sys_content = sys_content;
        let wifi_content = wifi_content;
    let frame_hw_c = frame_hw.clone();
    let frame_iso_c = frame_iso.clone();
    let frame_fp_c = frame_fp.clone();
    let frame_sys_c = frame_sys.clone();
    let frame_wifi_c = frame_wifi.clone();
    let frame_install_c = frame_install.clone();
    let sb_install_c = sb_install.clone();
    let btn_back_c = btn_back.clone();
    let btn_next_c = btn_next.clone();
    let btn_cancel_c = btn_cancel.clone();
    let btn_everything_c = btn_everything.clone();
    let btn_reboot_c = btn_reboot.clone();
    let working_c = working.clone();
    // Ctrl+Alt+B hotkey registration (see INSTALL_HOTKEY_ID): a real
    // RegisterHotKey, because focus usually sits on a child control whose
    // keystrokes never reach the window proc. Raw WM_HOTKEY handler jumps
    // to the INSTALL page; ignored once the working phase owns the window.
    if let Some(hwnd) = window.handle.hwnd() {
        use winapi::um::winuser::{RegisterHotKey, MOD_ALT, MOD_CONTROL};
        unsafe { RegisterHotKey(hwnd, INSTALL_HOTKEY_ID, (MOD_CONTROL | MOD_ALT) as u32, 0x42) };
    }
    let _install_hotkey = nwg::bind_raw_event_handler(
        &window.handle,
        0x48_4B_42usize,
        {
            let page = page.clone();
            let working = working.clone();
            let frame_hw = frame_hw.clone();
            let frame_iso = frame_iso.clone();
            let frame_fp = frame_fp.clone();
            let frame_sys = frame_sys.clone();
            let frame_wifi = frame_wifi.clone();
            let frame_install = frame_install.clone();
            let btn_back = btn_back.clone();
            let btn_next = btn_next.clone();
            let btn_reboot = btn_reboot.clone();
            let install_items = install_items.clone();
            move |_, msg, w, _| {
                use winapi::um::winuser::WM_HOTKEY;
                if msg != WM_HOTKEY || w as usize != INSTALL_HOTKEY_ID as usize {
                    return None;
                }
                if working.get() {
                    return None; // working/final phase: wizard pages are gone
                }
                glog("hotkey: jump to INSTALL");
                page.set(INSTALL_PAGE);
                frame_hw.set_visible(false);
                frame_iso.set_visible(false);
                frame_fp.set_visible(false);
                frame_sys.set_visible(false);
                frame_wifi.set_visible(false);
                frame_install.set_visible(true);
                btn_back.set_enabled(true);
                btn_next.set_enabled(true);
                btn_reboot.set_visible(false);
                btn_next.set_text(nav_label(INSTALL_PAGE));
                // ...with the built-in non-destructive method preselected,
                // so the hotkey lands ready to Install (programmatic check
                // needs the explicit uncheck - BM_SETCHECK has no group
                // exclusivity, only clicks do).
                for it in install_items.borrow().iter() {
                    if let PageCtl::Radio(rb, 3) = &it.ctl {
                        let builtin = write_mode_from_label(&rb.text()) == "nofmt";
                        rb.set_check_state(if builtin {
                            nwg::RadioButtonState::Checked
                        } else {
                            nwg::RadioButtonState::Unchecked
                        });
                    }
                }
                Some(0)
            }
        },
    )
    .expect("bind install hotkey handler");
        move |event, data, handle| {
        use nwg::Event;
        match event {
            Event::OnResize | Event::OnWindowMaximize => {
                if let Some(hwnd) = win_hwnd {
                    let (cw, ch) = client_size(hwnd);
                    relayout(&LayoutCtx {
                        lbl_sb: &lbl_sb,
                        sb_text: &sb_text_ref,
                        frame_hw: &*frame_hw_c,
                        frame_iso: &*frame_iso_c,
                        frame_fp: &*frame_fp_c,
                        frame_sys: &*frame_sys_c,
                        frame_wifi: &*frame_wifi_c,
                        frame_install: &*frame_install_c,
                        lbl_hw: &lbl_hw,
                        lv_hw: &lv_hw,
                        lbl_rec: &lbl_rec,
                        lbl_rec_help: &lbl_rec_help,
                        rec_help_text: &rec_help_ref,
                        lbl_fp: &lbl_fp,
                        sb_iso: &sb_iso,
                        sb_fp: &sb_fp,
                        sb_sys: &sb_sys,
                        sb_wifi: &sb_wifi,
                        sb_install: &*sb_install_c,
                        btn_everything: &*btn_everything_c,
                        btn_back: &*btn_back_c,
                        btn_next: &*btn_next_c,
                        btn_cancel: &*btn_cancel_c,
                        btn_reboot: &*btn_reboot_c,
                        lbl_dl: &lbl_dl,
                        pb_dl: &pb_dl,
                        iso: &iso_items,
                        fp: &fp_items,
                        sys: &sys_items,
                        wifi_items: &wifi_items,
                        install: &install_items,
                        wifi: &wifi_checks,
                        fw: &fw_cell,
                        iso_off: &iso_off,
                        fp_off: &fp_off,
                        sys_off: &sys_off,
                        wifi_off: &wifi_off,
                        install_off: &install_off,
                        iso_geom: &iso_geom,
                        fp_geom: &fp_geom,
                        sys_geom: &sys_geom,
                        wifi_geom: &wifi_geom,
                        install_geom: &install_geom,
                        fp_content: &fp_content,
                        guard: &in_relayout,
                        iso_content: iso_content,
                        sys_content: sys_content,
                        wifi_content: wifi_content,
                        install_content: install_content,
                    }, cw, ch);
                }
            }
            Event::OnMinMaxInfo => {
                // keep the window within the work area (640x452 on a
                // 640x480 desktop): no shrinking below usable, no growing
                // (or maximizing) past the taskbar
                let mm = data.on_min_max();
                let (wa_l, wa_t, wa_r, wa_b) = WORK_AREA.get().copied().unwrap_or((0, 0, 640, 480));
                let (ew, eh) = CHROME.get().copied().unwrap_or((8, 40));
                let (waw, wah) = (wa_r - wa_l, wa_b - wa_t);
                mm.set_min_size(MIN_CW.min(waw - ew).max(0), MIN_CH.min(wah - eh).max(0));
                mm.set_max_size(waw - ew, wah - eh);
                mm.set_maximized_size(waw, wah);
                mm.set_maximized_pos(wa_l, wa_t);
            }
            Event::OnListViewClick => {
                let (row, col) = data.on_list_view_item_index();
                glog(&format!("listview item click row={} col={}", row, col));
                // www column: open the device's linux-hardware.org page
                if col == 4 && (row as usize) < hw_rows.borrow().len() {
                    let url = hw_rows.borrow()[row as usize].url.clone();
                    if !url.is_empty() {
                        glog(&format!("open {}", url));
                        let diag = sys::open_url(&url);
                        glog(&format!("open-url diag: {}", diag));
                    }
                }
            }
            Event::OnButtonClick => {
                glog("click");
                let click_hwnd = handle.hwnd().map(|h| h as usize).unwrap_or(0);
                // FINISHED / FAILED summary-page button: dismiss it. This is the
                // only action available once the working phase has ended.
                if sum_btn_h.get() != 0 && click_hwnd == sum_btn_h.get() {
                    final_done.set(true);
                    glog("click finish/close on final page");
                }
                if sum_copy_h.get() != 0 && click_hwnd == sum_copy_h.get() {
                    copy_clicked.set(true);
                    glog("click copy on final page");
                }
                if sum_open_h.get() != 0 && click_hwnd == sum_open_h.get() {
                    open_clicked.set(true);
                    glog("click open-manual-download on final page");
                }
                if sum_back_h.get() != 0 && click_hwnd == sum_back_h.get() {
                    back_clicked.set(true);
                    glog("click back-to-options on failed page");
                }
                // boot-choice page (ask_boot_choice): same HWNDs, separate
                // cells - the summary loop ignores these and vice versa.
                if sum_btn_h.get() != 0 && click_hwnd == sum_btn_h.get() {
                    boot_usb_c.set(true);
                    glog("click boot-usb");
                }
                if sum_copy_h.get() != 0 && click_hwnd == sum_copy_h.get() {
                    boot_adv_c.set(true);
                    glog("click boot-advanced");
                }
                if sum_open_h.get() != 0 && click_hwnd == sum_open_h.get() {
                    boot_fw_c.set(true);
                    glog("click boot-firmware");
                }
                if sum_back_h.get() != 0 && click_hwnd == sum_back_h.get() {
                    boot_none_c.set(true);
                    glog("click boot-none");
                }
                // master wifi switch: toggling it checks/unchecks every network
                if click_hwnd == master_hwnd {
                    let mut st = nwg::CheckBoxState::Unchecked;
                    for it in wifi_items.borrow().iter() {
                        if let PageCtl::Check(b, 9) = &it.ctl {
                            st = b.check_state();
                        }
                    }
                    for cb in wifi_checks.borrow().iter() {
                        cb.set_check_state(st);
                    }
                }
                if handle == btn_next_c.handle {
                    glog("click next");
                    let cur = p2.get();
                    if cur < INSTALL_PAGE {
                        p2.set(cur + 1);
                        frame_hw_c.set_visible(p2.get() == 0);
                        frame_iso_c.set_visible(p2.get() == 1);
                        frame_fp_c.set_visible(p2.get() == 2);
                        frame_sys_c.set_visible(p2.get() == 3);
                        frame_wifi_c.set_visible(p2.get() == 4);
                        frame_install_c.set_visible(p2.get() == INSTALL_PAGE);
                        btn_back_c.set_enabled(p2.get() > 0);
                        btn_next_c.set_text(nav_label(p2.get()));
                        btn_reboot_c.set_visible(p2.get() == 0);
                    } else {
                        // ---- Install clicked: enter the working phase ----
                        // The window STAYS VISIBLE (status text + progress)
                        // while main() resolves the ISO and launches Rufus;
                        // it only closes once Rufus is up (or the chosen
                        // write path needs no Rufus).
                        glog("click install");
                        f2.set(true);
                        working_c.set(true);
                        let g = harvest_gui_result(
                            &iso_arg2,
                            &distro_urls,
                            &iso_items,
                            &fp_items,
                            &sys_items,
                            &wifi_items,
                            &install_items,
                            &wifi_checks,
                        );
                        g_cell.replace(Some(g));
                        frame_hw_c.set_visible(false);
                        frame_iso_c.set_visible(false);
                        frame_fp_c.set_visible(false);
                        frame_sys_c.set_visible(false);
                        frame_wifi_c.set_visible(false);
                        frame_install_c.set_visible(false);
                        sb_iso.set_visible(false);
                        sb_fp.set_visible(false);
                        sb_sys.set_visible(false);
                        sb_wifi.set_visible(false);
                        sb_install_c.set_visible(false);
                        btn_back_c.set_enabled(false);
                        btn_next_c.set_enabled(false);
                        btn_cancel_c.set_enabled(false);
                        btn_everything_c.set_enabled(false);
                        btn_reboot_c.set_visible(false);
                        lbl_dl.set_visible(false);
                        pb_dl.set_visible(false);
                        lbl_working.set_visible(true);
                        let ui = WorkingUi {
                            main: window.handle.hwnd().map(|h| h as usize).unwrap_or(0),
                            status: lbl_working.handle.hwnd().map(|h| h as usize).unwrap_or(0),
                            bg: bg_downloads.clone(),
                            sum_frame: sum_frame.handle.hwnd().map(|h| h as usize).unwrap_or(0),
                            sum_heading: sum_heading.handle.hwnd().map(|h| h as usize).unwrap_or(0),
                            sum_body: sum_body.handle.hwnd().map(|h| h as usize).unwrap_or(0),
                            sum_btn: sum_btn.handle.hwnd().map(|h| h as usize).unwrap_or(0),
                            sum_copy: sum_copy.handle.hwnd().map(|h| h as usize).unwrap_or(0),
                            sum_open: sum_open.handle.hwnd().map(|h| h as usize).unwrap_or(0),
                            nav_back: btn_back_c.handle.hwnd().map(|h| h as usize).unwrap_or(0),
                            nav_next: btn_next_c.handle.hwnd().map(|h| h as usize).unwrap_or(0),
                            nav_cancel: btn_cancel_c.handle.hwnd().map(|h| h as usize).unwrap_or(0),
                            dl: lbl_dl.handle.hwnd().map(|h| h as usize).unwrap_or(0),
                            dlbar: pb_dl.handle.hwnd().map(|h| h as usize).unwrap_or(0),
                            done: final_done.clone(),
                            copy_clicked: copy_clicked.clone(),
                            open_clicked: open_clicked.clone(),
                            sum_back: sum_back_h.get(),
                            back_clicked: back_clicked.clone(),
                            boot_usb: boot_usb.clone(),
                            boot_adv: boot_adv.clone(),
                            boot_fw: boot_fw.clone(),
                            boot_none: boot_none.clone(),
                        };
                        ui_cell.replace(Some(ui));
                        // The callback (main's on_confirm) runs right after
                        // the dispatch loop ends - the window stays visible
                        // the whole time and the callback pumps it through
                        // WorkingUi::pump.
                        nwg::stop_thread_dispatch();
                    }
                } else if handle == btn_back_c.handle {
                    glog("click back");
                    let cur = p2.get();
                    if cur > 0 {
                        p2.set(cur - 1);
                        frame_hw_c.set_visible(p2.get() == 0);
                        frame_iso_c.set_visible(p2.get() == 1);
                        frame_fp_c.set_visible(p2.get() == 2);
                        frame_sys_c.set_visible(p2.get() == 3);
                        frame_wifi_c.set_visible(p2.get() == 4);
                        frame_install_c.set_visible(p2.get() == INSTALL_PAGE);
                        btn_back_c.set_enabled(p2.get() > 0);
                        btn_next_c.set_enabled(true);
                        btn_next_c.set_text(nav_label(p2.get()));
                        btn_reboot_c.set_visible(p2.get() == 0);
                    }
                } else if handle == btn_cancel_c.handle {
                    glog("click cancel");
                    c2.set(true);
                    nwg::stop_thread_dispatch();
                } else if click_hwnd == browse_hwnd {
                    // Folder picker -> convert to the /mnt/<drive>/... form
                    if let Some(wpath) = sys::browse_folder("Choose the LSL_DATA_DIR folder (a Windows path)") {
                        for it in browse_data_sys.borrow_mut().iter() {
                            match &it.ctl {
                                PageCtl::Edit(b, 2) => b.set_text(&sys::win_to_wsl_path(&wpath)),
                                PageCtl::EditLine(b, 2) => b.set_text(&sys::win_to_wsl_path(&wpath)),
                                _ => {}
                            }
                        }
                    }
                } else if handle == btn_everything_c.handle {
                    if crate::lslfiles::everything_path().is_empty() {
                        btn_everything_c.set_enabled(false);
                        btn_everything_c.set_text("Installing Everything... (index building in background)");
                        let tx2 = tx.clone();
                        std::thread::spawn(move || {
                            let es = crate::lslfiles::install_everything();
                            let _ = tx2.send(HwMsg::EverythingDone(!es.is_empty()));
                        });
                    }
                } else if handle == btn_reboot_c.handle {
                    glog("click reboot");
                    match crate::boot::show_boot_choice_dialog() {
                        crate::boot::BootChoice::Usb => {
                            if !crate::boot::set_next_boot_usb().is_empty() {
                                crate::boot::reboot("/r /t 0");
                            } else {
                                crate::boot::reboot(crate::boot::reboot_args());
                            }
                            std::process::exit(0);
                        }
                        crate::boot::BootChoice::Adv => {
                            crate::boot::reboot("/r /o /f /t 0");
                            std::process::exit(0);
                        }
                        crate::boot::BootChoice::Fw => {
                            crate::boot::reboot(crate::boot::reboot_args());
                            std::process::exit(0);
                        }
                        crate::boot::BootChoice::None => {}
                    }
                } else {
                    // ISO-page radios: selecting a "Download Fresh" distro
                    // starts the ISO download immediately (like the PS
                    // version) so it runs while the user configures the
                    // remaining pages.
                    let mut clicked: Option<(u8, String)> = None;
                    for it in iso_items.borrow().iter() {
                        if let PageCtl::Radio(rb, k) = &it.ctl {
                            if rb.handle.hwnd().map(|h| h as usize) == Some(click_hwnd) {
                                glog(&format!(
                                    "radio click kind={} checked={} text={}",
                                    k,
                                    rb.check_state() == nwg::RadioButtonState::Checked,
                                    rb.text()
                                ));
                                clicked = Some((*k, rb.text()));
                                break;
                            }
                        }
                    }
                    // INSTALL-page target click: refresh the BIOS/UEFI
                    // checkboxes for the newly selected stick (grey out +
                    // reason when unsupported).
                    for it in install_items.borrow().iter() {
                        if let PageCtl::Radio(rb, 4) = &it.ctl {
                            if rb.handle.hwnd().map(|h| h as usize) == Some(click_hwnd) {
                                let letter = rb.text().split(':').next().unwrap_or("").trim().to_string();
                                apply_boot_caps(&install_items, &letter, "", false);
                                break;
                            }
                        }
                    }
                    // INSTALL-page BIOS/UEFI checkbox toggle: refresh the
                    // this-machine firmware line for the new selection.
                    for it in install_items.borrow().iter() {
                        if let PageCtl::Check(cb, k) = &it.ctl {
                            if (*k == 5 || *k == 6)
                                && cb.handle.hwnd().map(|h| h as usize) == Some(click_hwnd)
                            {
                                refresh_fw_note(&install_items);
                                break;
                            }
                        }
                    }
                    if let Some((0, text)) = clicked {
                        glog(&format!("distro radio clicked: {text}"));
                        if let Some((_, (_n, url))) = distro_urls
                            .iter()
                            .zip(DISTRO_OPTIONS.iter())
                            .find(|(_, (n, _))| *n == text)
                        {
                            let name = url
                                .rsplit('/')
                                .next()
                                .filter(|s| s.ends_with(".iso"))
                                .unwrap_or("downloaded.iso")
                                .to_string();
                            start_bg_download(&bg_downloads, url, &name, &download_dir, tx.clone());
                        }
                    }
                }
            }
            Event::OnTimerTick => {
                // drain the hardware-rating channel (one tick may carry
                // several cached results)
                loop {
                    let msg = match rx.try_recv() {
                        Ok(m) => m,
                        Err(_) => break,
                    };
                    match msg {
                        HwMsg::Row { class, support, rating, name, id, url } => {
                            // the URL must keep its scheme (ShellExecute
                            // treats a bare domain as a relative path and
                            // fails with ERROR_FILE_NOT_FOUND)
                            let url = if url.is_empty() { String::new() } else { format!("https://linux-hardware.org/?id={}", url.split("id=").nth(1).unwrap_or("")) };
                            let row = HwRow { class, rating, support, name, id, url: url.clone() };
                            hw_rows.borrow_mut().push(row.clone());
                            // Plain-ASCII "link" text (Win95's ANSI listview
                            // cannot carry the U+1F310 emoji); the custom-draw
                            // handler paints it blue + underlined.
                            let link = if url.is_empty() { String::new() } else { "link".to_string() };
                            lv_hw.insert_items_row(
                                None,
                                &[row.class, row.support, row.name, row.id, link],
                            );
                        }
                        HwMsg::UpdateRow { id, support, rating, name, url } => {
                            let url = if url.is_empty() { String::new() } else { format!("https://linux-hardware.org/?id={}", url.split("id=").nth(1).unwrap_or("")) };
                            let link = if url.is_empty() { String::new() } else { "link".to_string() };
                            let mut rows = hw_rows.borrow_mut();
                            for (i, row) in rows.iter_mut().enumerate() {
                                if row.id == id {
                                    row.rating = rating;
                                    row.support = support.clone();
                                    row.name = name.clone();
                                    row.url = url.clone();
                                    lv_hw.update_item(i, nwg::InsertListViewItem { column_index: 1, text: Some(support.clone()), ..Default::default() });
                                    lv_hw.update_item(i, nwg::InsertListViewItem { column_index: 2, text: Some(name.clone()), ..Default::default() });
                                    lv_hw.update_item(i, nwg::InsertListViewItem { column_index: 4, text: Some(link.clone()), ..Default::default() });
                                }
                            }
                        }
                        HwMsg::Progress(text) => {
                            lbl_hw.set_text(&text);
                        }
                        HwMsg::Done { a, c, d, u } => {
                            lbl_hw.set_text(&format!(
                                "Summary: A={} (in-kernel)  C={} (out-of-tree)  D={} (no driver)  U={} (unknown)",
                                a, c, d, u
                            ));
                        }
                        HwMsg::DistroResolved { url, name, dir } => {
                            start_direct_download(&bg_downloads, &url, &name, &dir);
                        }
                        HwMsg::EverythingDone(ok) => {
                            btn_everything_c.set_enabled(true);
                            btn_everything_c.set_text(if ok {
                                "Everything installed - index building in background"
                            } else {
                                "Everything install failed - see console"
                            });
                        }
                    }
                }
                // Persistent ISO download progress: parented to the window,
                // so it stays visible on EVERY page while a background
                // download (distro radio click) is running. Once the working
                // phase starts the bar is hidden (wait_downloads drives the
                // same info through the big status label).
                if !working2.get() {
                    let bgs = bg_downloads.borrow();
                    let active = bgs
                        .iter()
                        .find(|b| !b.finished.load(std::sync::atomic::Ordering::Relaxed));
                    if let Some(b) = active {
                        let done = b.prog.load(std::sync::atomic::Ordering::Relaxed);
                        let total = b.total.load(std::sync::atomic::Ordering::Relaxed);
                        let name = b.dest.rsplit('\\').next().unwrap_or("").to_string();
                        if !pb_dl.visible() {
                            pb_dl.set_visible(true);
                            lbl_dl.set_visible(true);
                        }
                        if total > 0 {
                            pb_dl.set_range(0..total as u32);
                            pb_dl.set_pos(done.min(total) as u32);
                            lbl_dl.set_text(&format!(
                                "Downloading {} - {} of {} MB ({}%)",
                                name,
                                done / sys::MB,
                                total / sys::MB,
                                done * 100 / total
                            ));
                        } else {
                            pb_dl.set_range(0..1000);
                            pb_dl.set_pos((done / (1024 * 1024)) as u32 % 1000);
                            lbl_dl.set_text(&format!("Downloading {} - {} MB", name, done / sys::MB));
                        }
                    } else {
                        pb_dl.set_visible(false);
                        lbl_dl.set_visible(false);
                    }
                }
            }
            Event::OnListViewColumnClick => {
                let (row, col) = data.on_list_view_item_index();
                glog(&format!("column click row={} col={}", row, col));
                let (prev_col, prev_dir) = hw_sort.get();
                let dir = if col == prev_col { -prev_dir } else { 1 };
                hw_sort.set((col, dir));

                hw_rows.borrow_mut().sort_by(|a, b| {
                    let ord = match col {
                        1 => rating_key(a.rating)
                            .cmp(&rating_key(b.rating))
                            .then_with(|| a.support.to_lowercase().cmp(&b.support.to_lowercase())),
                        2 => a.name.to_lowercase().cmp(&b.name.to_lowercase()),
                        3 => a.id.cmp(&b.id),
                        4 => a.url.cmp(&b.url),
                        _ => a.class.to_lowercase().cmp(&b.class.to_lowercase()),
                    };
                    if dir > 0 { ord } else { ord.reverse() }
                });

                lv_hw.clear();
                let rows = hw_rows.borrow();
                for r in rows.iter() {
                    // Same "link" text as the insert path above (sort repopulation).
                    lv_hw.insert_items_row(None, &[r.class.clone(), r.support.clone(), r.name.clone(), r.id.clone(), if r.url.is_empty() { String::new() } else { "link".to_string() }]);
                }
                for c in 0..5 {
                    lv_hw.set_column_sort_arrow(c, None);
                }
                lv_hw.set_column_sort_arrow(
                    col,
                    if dir > 0 {
                        Some(nwg::ListViewColumnSortArrow::Up)
                    } else {
                        Some(nwg::ListViewColumnSortArrow::Down)
                    },
                );
            }
            Event::OnWindowClose => {
                glog("close");
                if let Some(hwnd) = win_hwnd {
                    use winapi::um::winuser::UnregisterHotKey;
                    unsafe { UnregisterHotKey(hwnd, INSTALL_HOTKEY_ID); }
                }
                c2.set(true);
                nwg::stop_thread_dispatch();
            }
            _ => {}
        }
        }
    });

    timer.start();
    nwg::dispatch_thread_events();
    glog("dispatch end");
    timer.stop();

    // The harvest ran in the Install-click handler (working phase); the
    // window is still alive here (the event handler keeps the control
    // handles), so main's callback can resolve the ISO + launch Rufus while
    // the user sees the status text and the live progress bar.
    //
    // FAILED pages offer "Back to install options": then on_confirm
    // returns GuiWork::back() and the wizard resumes on the INSTALL page
    // for another attempt (e.g. Rufus after a nofmt refusal) instead of
    // exiting. The hw-rating timer is spent by then; a retry runs without
    // live row updates (cached rows stay on screen).
    loop {
        let Some(g) = g_cell2.borrow_mut().take() else {
            return None; // cancelled or closed without Install
        };
        let Some(ui) = ui_cell2.borrow_mut().take() else {
            return None;
        };
        let work = on_confirm(g.clone(), &ui);
        if !work.back {
            return Some((g, work));
        }
        glog("back to install options");
        ui.hide_summary();
        frame_install.set_visible(true);
        sb_install.set_visible(true);
        // show_final hid the nav buttons via raw ShowWindow; enabling alone
        // leaves them invisible, i.e. a button-less window. Re-show first.
        btn_back.set_visible(true);
        btn_next.set_visible(true);
        btn_cancel.set_visible(true);
        btn_back.set_enabled(true);
        btn_next.set_enabled(true);
        btn_cancel.set_enabled(true);
        btn_everything.set_enabled(true);
        btn_reboot.set_visible(false);
        page.set(INSTALL_PAGE);
        frame_hw.set_visible(false);
        frame_iso.set_visible(false);
        frame_fp.set_visible(false);
        frame_sys.set_visible(false);
        frame_wifi.set_visible(false);
        btn_next.set_text(nav_label(INSTALL_PAGE));
        confirmed.set(false);
        working.set(false);
        nwg::dispatch_thread_events();
        glog("dispatch end (retry)");
    }
}

/// The wizard's harvest: turn the checked radios/checks/edits into a
/// GuiResult. Runs inside the Install-click handler while the window is still
/// alive (the working phase), NOT after the loop.
#[allow(clippy::too_many_arguments)]
fn harvest_gui_result(
    iso_arg: &str,
    distro_urls: &[String],
    iso_items: &PageItems,
    fp_items: &PageItems,
    sys_items: &PageItems,
    wifi_items: &PageItems,
    install_items: &PageItems,
    wifi_checks: &Rc<std::cell::RefCell<Vec<Box<nwg::CheckBox>>>>,
) -> GuiResult {
    // Checkbox precedence: existing USB > existing ISO > fresh download.
    let mut reuse_usb: Option<String> = None;
    let mut chosen_iso: Option<String> = None;
    let mut download_iso: Option<(String, String)> = None;
    let mut distro_arch: Option<&'static str> = None;
    for it in iso_items.borrow().iter() {
        let (cb, kind) = match &it.ctl {
            PageCtl::Radio(cb, k) => (cb, *k),
            _ => continue,
        };
        if cb.check_state() != nwg::RadioButtonState::Checked {
            continue;
        }
        let text = cb.text();
        match kind {
            2 => {
                if reuse_usb.is_none() {
                    reuse_usb = Some(text.split(':').next().unwrap_or("").trim().to_string());
                }
            }
            1 => {
                if chosen_iso.is_none() {
                    chosen_iso = Some(text.split("  (").next().unwrap_or("").trim().to_string());
                }
            }
            _ => {
                if download_iso.is_none() {
                    for (i, (_name, _url)) in DISTRO_OPTIONS.iter().enumerate() {
                        if text.starts_with(_name.split(' ').next().unwrap_or("")) {
                            // the tools must match the DISTRO's arch, not the
                            // host's: antiX / Tiny CorePlus are 32-bit
                            distro_arch = if _name.contains("i386") || _name.contains("32-bit") {
                                Some("i686")
                            } else {
                                Some("x86_64")
                            };
                            let url = distro_urls[i].clone();
                            let name = url
                                .rsplit('/')
                                .next()
                                .filter(|s| s.ends_with(".iso"))
                                .unwrap_or("downloaded.iso")
                                .to_string();
                            download_iso = Some((url, name));
                            break;
                        }
                    }
                }
            }
        }
    }
    chosen_iso = chosen_iso.filter(|s| !s.is_empty() && s != "[None found]");
    reuse_usb = reuse_usb.filter(|s| !s.is_empty());

    // Fresh download selected, but an up-to-date, right-sized local copy of
    // the same ISO exists? Reuse it instead of re-downloading (only when the
    // user did not explicitly pick another ISO).
    let download_iso = match download_iso {
        Some((url, name)) => {
            if chosen_iso.is_none() {
                if let Some(existing) = find_matching_local_iso(&name, MIN_ISO_SIZE) {
                    chosen_iso = Some(existing);
                    None
                } else {
                    Some((url, name))
                }
            } else {
                Some((url, name))
            }
        }
        None => None,
    };

    // NOTE: joining a still-running background ISO download happens in
    // WorkingUi::wait_downloads (called by main's working-phase callback),
    // which pumps the GUI so the progress bar stays live - this harvest
    // runs inside the click handler and must not block with sleeps.

    // flatpaks: grid apps (kind 0), FSearch (kind 1), extra IDs (Edit kind 1)
    let mut flatpak_ids: Vec<String> = Vec::new();
    let mut fsearch = false;
    let mut extra_text = String::new();
    for it in fp_items.borrow().iter() {
        match &it.ctl {
            PageCtl::Check(cb, 0) => {
                if cb.check_state() == nwg::CheckBoxState::Checked {
                    let t = cb.text();
                    if let Some((_, id)) = crate::hardware::FLATPAK_MAP.iter().find(|(app, _)| *app == t) {
                        flatpak_ids.push(id.to_string());
                    }
                }
            }
            PageCtl::Check(cb, 1) => {
                fsearch = cb.check_state() == nwg::CheckBoxState::Checked;
            }
            PageCtl::Edit(b, 1) => {
                extra_text = b.text();
            }
            _ => {}
        }
    }
    if fsearch {
        flatpak_ids.push("io.github.cboxdoerfer.FSearch".to_string());
    }
    let extra: Vec<String> = extra_text
        .split(|c| c == ',' || c == '\n' || c == '\r')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();

    // system page: Edit 1=vhdx, Edit 2=data dir, Checks 4..8
    let mut vhdx_text = String::new();
    let mut data_text = String::new();
    let mut efu = false;
    let mut drivers = false;
    let mut sfs = false;
    let mut reclaim = false;
    let mut rust_tools = false;
    for it in sys_items.borrow().iter() {
        match &it.ctl {
            PageCtl::Edit(b, 1) => vhdx_text = b.text(),
            PageCtl::Edit(b, 2) => data_text = b.text(),
            PageCtl::EditLine(b, 2) => data_text = b.text(),
            PageCtl::Check(b, k) => {
                let on = b.check_state() == nwg::CheckBoxState::Checked;
                match *k {
                    4 => efu = on,
                    5 => drivers = on,
                    6 => sfs = on,
                    7 => reclaim = on,
                    8 => rust_tools = on,
                    _ => {}
                }
            }
            _ => {}
        }
    }
    // wifi page: Check 9=master switch
    let mut wifi = false;
    for it in wifi_items.borrow().iter() {
        if let PageCtl::Check(b, 9) = &it.ctl {
            wifi = b.check_state() == nwg::CheckBoxState::Checked;
        }
    }
    let wsl_vhdx: Vec<String> = vhdx_text
        .lines()
        .map(|l| l.trim().to_string())
        .filter(|l| !l.is_empty() && l != "(none found)")
        .collect();

    let wifi_networks: Vec<String> = wifi_checks
        .borrow()
        .iter()
        .filter(|cb| cb.check_state() == nwg::CheckBoxState::Checked)
        .map(|cb| cb.text())
        .collect();

    let iso_path = if !iso_arg.is_empty() {
        iso_arg.to_string()
    } else {
        chosen_iso.unwrap_or_default()
    };

    GuiResult {
        iso_path,
        flatpak_ids: [flatpak_ids, extra].concat(),
        wsl_vhdx,
        data_dir: data_text,
        wifi,
        wifi_networks,
        efu,
        drivers,
        sfs_hdd: sfs,
        rust_tools,
        distro_arch,
        reclaim_win_swap: reclaim,
        download_iso,
        use_existing_usb: reuse_usb,
        write_mode: {
            // the INSTALL page's write-method radio section (kind 3);
            // exactly one is always selected, so the wizard always
            // expresses a choice and the console never needs to re-ask
            let mut mode = String::from("rufus");
            for it in install_items.borrow().iter() {
                if let PageCtl::Radio(rb, 3) = &it.ctl {
                    glog(&format!(
                        "harvest write-mode radio '{}' checked={}",
                        rb.text(),
                        rb.check_state() == nwg::RadioButtonState::Checked
                    ));
                    if rb.check_state() == nwg::RadioButtonState::Checked {
                        mode = write_mode_from_label(&rb.text()).to_string();
                        break;
                    }
                }
            }
            Some(mode)
        },
        target_usb: {
            // the INSTALL page's target-USB radio section (kind 4);
            // drive letter of the checked entry, if any stick is plugged in
            let mut target: Option<String> = None;
            for it in install_items.borrow().iter() {
                if let PageCtl::Radio(rb, 4) = &it.ctl {
                    if rb.check_state() == nwg::RadioButtonState::Checked {
                        let letter = rb.text().split(':').next().unwrap_or("").trim().to_string();
                        if !letter.is_empty() {
                            target = Some(letter);
                        }
                        break;
                    }
                }
            }
            target
        },
        bios_boot: {
            // INSTALL-page BIOS checkbox (kind 5); default on when the
            // control is missing (console-equivalent default)
            let mut on = true;
            for it in install_items.borrow().iter() {
                if let PageCtl::Check(cb, 5) = &it.ctl {
                    on = cb.check_state() == nwg::CheckBoxState::Checked;
                    break;
                }
            }
            on
        },
        uefi_boot: {
            // INSTALL-page UEFI checkbox (kind 6)
            let mut on = true;
            for it in install_items.borrow().iter() {
                if let PageCtl::Check(cb, 6) = &it.ctl {
                    on = cb.check_state() == nwg::CheckBoxState::Checked;
                    break;
                }
            }
            on
        },
        check_usb: {
            // INSTALL-page whole-USB check (kind 8); default off
            let mut on = false;
            for it in install_items.borrow().iter() {
                if let PageCtl::Check(cb, 8) = &it.ctl {
                    on = cb.check_state() == nwg::CheckBoxState::Checked;
                    break;
                }
            }
            on
        },
        skip_verify: {
            // INSTALL-page skip-verify checkbox (kind 9); default off
            let mut on = false;
            for it in install_items.borrow().iter() {
                if let PageCtl::Check(cb, 9) = &it.ctl {
                    on = cb.check_state() == nwg::CheckBoxState::Checked;
                    break;
                }
            }
            on
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bottom_bands_never_overlap() {
        // the "Downloading ..." label band touches neither the scrollable
        // pages above nor the button row below, at any client height -
        // so no glyph (not even a 'g' descender) can paint over a neighbour.
        // label_h stays a full 20px line (codebase single-line metric: 18).
        for ch in [300, 380, 413, 500, 760, 900, 1200] {
            let (pages_end, ly, lh, bary, barh, btny, btnh) = bottom_bands(ch);
            assert!(pages_end <= ly, "pages above label @ ch={ch}");
            assert!(ly + lh <= btny, "label above buttons @ ch={ch}");
            assert!(
                bary >= btny && bary + barh <= btny + btnh,
                "bar inside button row @ ch={ch}"
            );
            assert!(lh >= 20, "label fits descenders @ ch={ch}");
            assert!(ly >= pages_end + 2, "air above label @ ch={ch}");
            assert!(btny >= ly + lh + 2, "air below label @ ch={ch}");
        }
    }

    #[test]
    fn nav_button_says_next_before_install_page() {
        // the button LEADING to the install page must read "Next >", never
        // "Install" (win-install-page GUI test asserts the live button)
        for page in 0..INSTALL_PAGE {
            assert_eq!(nav_label(page), "Next >", "page {}", page);
        }
    }

    #[test]
    fn recommendation_matrix() {
        // true 32-bit-only hardware -> antiX, and the 64-bit warning stands
        let (title, body) = recommendation_for(false, false, 8.0);
        assert!(title.contains("antiX"));
        assert!(body.contains("does not support 64-bit"));
        // 32-bit Windows on 64-bit CPU: full 64-bit recommendation PLUS the
        // note (this is the case IsWow64Process gets wrong on its own)
        let (title, body) = recommendation_for(true, false, 8.0);
        assert!(title.contains("Cinnamon"));
        assert!(body.contains("32-bit"));
        assert!(!body.contains("does not support 64-bit"));
        // 64-bit Windows: same recommendation, no note
        let (title2, body2) = recommendation_for(true, true, 8.0);
        assert_eq!(title, title2);
        assert!(!body2.contains("32-bit"));
        // low RAM on 64-bit hardware still goes light, note or not
        let (title, _) = recommendation_for(true, false, 0.5);
        assert!(title.contains("antiX"));
        let (title, _) = recommendation_for(true, true, 1.5);
        assert!(title.contains("Lubuntu"));
    }

    #[test]
    fn iso_arch_markers() {
        assert_eq!(iso_arch_64("linuxmint-22.3-cinnamon-64bit.iso"), Some(true));
        assert_eq!(iso_arch_64("lubuntu-24.04-desktop-amd64.iso"), Some(true));
        assert_eq!(iso_arch_64("debian-live-13.6.0-amd64-xfce.iso"), Some(true));
        assert_eq!(iso_arch_64("ubuntu-24.04-x86_64.iso"), Some(true));
        assert_eq!(iso_arch_64("antiX-26_386-full.iso"), Some(false));
        assert_eq!(iso_arch_64("antix-26-i386.iso"), Some(false));
        assert_eq!(iso_arch_64("CorePlus-current.iso"), None);
        assert_eq!(iso_arch_64("mystery-respin.iso"), None);
    }

    #[test]
    fn multiline_labels_fit_their_height() {
        // Regression: the vendored label's WM_NCCALCSIZE hook sized every
        // label's client area to ONE line, so only the first line of any
        // multi-line label painted (rec-help body, pagefile note). The hook
        // now sizes for all wrapped lines (vendor nc_tests); this test pins
        // OUR half of the contract for every shipped multi-line text: it
        // really wraps to several lines, and its allocated height fits the
        // rendered breaks (text_h uses the same greedy loop as wrap_text,
        // so the two cannot disagree).
        let per_line = 86; // push_lbl/relayout width at the default frame
        let bodies = [
            (recommendation_for(true, true, 8.0).1, 78), // Cinnamon help
            (recommendation_for(false, false, 8.0).1, 78), // antiX help
            (recommendation_for(true, false, 0.5).1, 78), // antiX + WOW note
            (PAGEFILE_NOTE.to_string(), 76),              // sys-page note
        ];
        for (body, height) in bodies {
            let wrapped = wrap_text(&body, per_line);
            let rendered: Vec<&str> = wrapped.split("\r\n").collect();
            assert!(rendered.len() > 1, "expected multi-line body: {:?}...", &body[..40.min(body.len())]);
            assert_eq!(wrap_line_count(&body, per_line), rendered.len());
            // height rule shared with text_h: lines * 18 + 6
            let need = rendered.len() as i32 * 18 + 6;
            assert!(
                height >= need,
                "label height {} clips {} rendered lines (need {})",
                height,
                rendered.len(),
                need
            );
        }
    }

    #[test]
    fn nav_button_says_install_on_install_page() {
        assert_eq!(nav_label(INSTALL_PAGE), INSTALL_LABEL);
        assert_eq!(nav_label(INSTALL_PAGE), "Install");
    }

    #[test]
    fn write_mode_labels_map() {
        assert_eq!(
            write_mode_from_label("Rufus (recommended - well tested, UEFI + BIOS; rewrites the stick)"),
            "rufus"
        );
        assert_eq!(
            write_mode_from_label("Built-in non-destructive (less tested - no reformat, keeps existing files; BIOS + UEFI)"),
            "nofmt"
        );
        assert_eq!(
            write_mode_from_label("Skip - I will write the USB myself (like --skip-rufus)"),
            "skip"
        );
        // case-insensitive, like the harvest path
        assert_eq!(write_mode_from_label("SKIP everything"), "skip");
        assert_eq!(write_mode_from_label("NON-DESTRUCTIVE copy"), "nofmt");
        // unknown labels fall back to Rufus, never to an empty/invalid mode
        assert_eq!(write_mode_from_label("???"), "rufus");
    }

    #[test]
    fn progress_bar_units_survive_iso_sizes() {
        // ~3 GB ISO at 1%: the max must stay a positive i32 (the old
        // byte-scale max wrapped negative and pinned the bar at 100%).
        let total = 3_100_000_000u64;
        let (max, pos) = bar_units(31_000_000, total);
        assert!(max > 0, "range max wrapped: {}", max);
        assert_eq!(max, (total / sys::MB) as i32);
        assert_eq!(pos, (31_000_000u64 / sys::MB) as i32);
        assert!(pos < max, "1% must not read complete");
        // degenerate + complete cases stay sane
        assert_eq!(bar_units(0, 0), (1, 0));
        let (max2, pos2) = bar_units(total, total);
        assert_eq!((max2, pos2), (max, max));
    }

    #[test]
    fn first_url_finds_http_and_https() {
        assert_eq!(
            first_url("Download manually:\n  https://rufus.ie/downloads/rufus-4.6.exe\nand save it."),
            Some("https://rufus.ie/downloads/rufus-4.6.exe".to_string())
        );
        assert_eq!(
            first_url("see http://example.com/a b"),
            Some("http://example.com/a".to_string())
        );
        assert_eq!(first_url("no url here"), None);
        assert_eq!(first_url(""), None);
    }
}
