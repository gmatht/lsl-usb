//! Installer GUI (Show-InstallerGui replacement) — native Win32 common
//! controls via nwg, so the same wizard works on Windows 95 -> 11 (the PS
//! version needs .NET WinForms).
//!
//! Mirrors the original wizard (now 5 pages; wifi split off system):
//!   page 0  hardware compatibility (LKDDb ratings, streamed in by a
//!           background thread so the 10s crawl-delay never blocks the UI)
//!   page 1  ISO selection (fresh-download radios, local ISOs, USB reuse)
//!   page 2  flatpak preloads (+ recommended FSearch + extra IDs)
//!   page 3  system: WSL VHDX, data dir, EFU, drivers, HDD cache, swap
//!           reclaim
//!   page 4  wifi networks (master switch + per-network list)
//! Heavy work (download, Rufus, file copy) runs on the console afterwards,
//! and the boot-choice dialog finishes the flow.
//!
//! Layout: everything is positioned from the live CLIENT size in one place
//! (`relayout`). The window opens at the default 880x760 client — clamped to
//! the work area, so a 640x480 Win9x box (work area 640x452, client
//! ~632x~413 after title bar + borders) gets a window that fits instead of
//! running off-screen — and is fully resizable: WM_SIZE relayouts every
//! page, and WM_GETMINMAXINFO clamps dragging/maximizing to the work area.
//! Pages 1-4 scroll (page 0's ListView scrolls natively), so every size
//! works and enlarging the window genuinely shows more.

use native_windows_gui as nwg;

use crate::sys;

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
    pub write_mode: Option<String>,             // "rufus" | "nofmt" | "skip" (GUI radio choice)
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
    let is64 = is_64bit_os();
    let ram_gb = ram as f64 / sys::GB as f64;
    if !is64 || ram_gb < 1.0 {
        3 // antiX
    } else if ram_gb < 2.0 {
        1 // Lubuntu
    } else {
        0 // Mint Cinnamon
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
    let is64 = is_64bit_os();
    let ram_gb = ram_bytes as f64 / sys::GB as f64;
    if !is64 {
        (
            "antiX 26 is the recommended option.".into(),
            "Your machine does not support 64-bit and will not be able to run Cinnamon. We recommend antiX 26, which runs on old hardware that doesn't support 64-bit and has as little as 0.25 GB of RAM.".into(),
        )
    } else if ram_gb >= 4.0 {
        (
            "Linux Mint Cinnamon is the recommended option.".into(),
            format!(
                "Your machine supports 64-bit and has {:.0} GB of RAM, meeting Cinnamon's recommended 4 GB spec. There is no need to use the minimalist 0.25 GB antiX.",
                ram_gb
            ),
        )
    } else if ram_gb >= 2.0 {
        (
            "Linux Mint Cinnamon is the recommended option.".into(),
            format!(
                "Your machine supports 64-bit and has {:.0} GB of RAM, meeting Cinnamon's minimum requirements of 2 GB, but not the recommended 4 GB. Consider enabling the experimental pagefile.sys swap. Your machine may be slow, but we still recommend Cinnamon over the minimalist 0.25 GB antiX.",
                ram_gb
            ),
        )
    } else if ram_gb >= 1.0 {
        (
            "Lubuntu 24.04 is the recommended option (Xubuntu 24.04 also viable).".into(),
            format!(
                "Your machine supports 64-bit and has {:.0} GB of RAM (1-2 GB). We recommend Lubuntu 24.04, which is light enough for 1 GB. Xubuntu 24.04 is also a viable option on 1 GB, but it is a bit heavier and should still run.",
                ram_gb
            ),
        )
    } else {
        (
            "antiX 26 is the recommended option.".into(),
            format!(
                "Your machine supports 64-bit, but only has {:.1} GB of RAM. We recommend the minimalist 0.25 GB antiX distro.",
                ram_gb
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
    Progress(String),
    Done {
        a: u32,
        c: u32,
        d: u32,
        u: u32,
    },
    EverythingDone(bool),
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
        _ => 3,
    }
}

fn support_text(rating: char) -> &'static str {
    match rating {
        'A' => "in-kernel (works out of the box)",
        'C' => "needs out-of-tree driver",
        'D' => "no driver",
        _ => "unknown (no data)",
    }
}

fn spawn_hw_rating(tx: mpsc::Sender<HwMsg>, bundle_dir: String) {
    std::thread::spawn(move || {
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
        for dev in devices {
            let url = crate::hardware::lhw_url(&dev);
            let r = crate::hardware::linux_compat_rating(&dev, &bundle_dir, (6, 8));
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
        }
        let _ = tx.send(HwMsg::Done { a, c, d, u });
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


/// Custom-draw subclass for the hardware ListView: paints the www column
/// (subitem 4) in royal blue, like install.ps1's owner-drawn globe.
unsafe extern "system" fn hw_custom_draw_proc(
    hwnd: winapi::shared::windef::HWND,
    msg: winapi::shared::minwindef::UINT,
    w: winapi::shared::minwindef::WPARAM,
    l: winapi::shared::minwindef::LPARAM,
    _id: usize,
    _data: winapi::shared::basetsd::DWORD_PTR,
) -> winapi::shared::minwindef::LRESULT {
    use winapi::um::commctrl::{
        CDDS_ITEMPREPAINT, CDDS_PREPAINT, CDDS_SUBITEM, CDRF_DODEFAULT, CDRF_NEWFONT,
        CDRF_NOTIFYSUBITEMDRAW, NM_CUSTOMDRAW, NMLVCUSTOMDRAW,
    };
    use winapi::um::commctrl::DefSubclassProc;
    use winapi::um::winuser::WM_NOTIFY;
    if msg == WM_NOTIFY {
        let nmh = &*(l as *const winapi::um::winuser::NMHDR);
        // Only handle notifications from the hardware listview itself (the
        // header control sends its own NM_CUSTOMDRAW that must be left alone)
        if nmh.hwndFrom as usize == *LV_HW_HWND.get().unwrap_or(&0) && nmh.code == NM_CUSTOMDRAW {
            // NOTE: CDDS_ITEMPREPAINT|CDDS_SUBITEM is the VALUE 0x30000 — it
            // must be compared, not used as an or-pattern (which would match
            // either constant alone and never the combined stage).
            let nmcd = &*(l as *const NMLVCUSTOMDRAW);
            let stage = nmcd.nmcd.dwDrawStage;
            if stage == CDDS_PREPAINT {
                return CDRF_NOTIFYSUBITEMDRAW as _;
            }
            if stage == (CDDS_ITEMPREPAINT | CDDS_SUBITEM) {
                if nmcd.iSubItem == 4 {
                    // RoyalBlue (COLORREF = 0x00BBGGRR)
                    (*(l as *mut NMLVCUSTOMDRAW)).clrText = 0x00E1_6941;
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
    DefSubclassProc(hwnd, msg, w, l)
}

static LV_HW_HWND: std::sync::OnceLock<usize> = std::sync::OnceLock::new();

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
const NAV_H: i32 = 62; // bottom strip: gap + nav buttons (28) + margin
const DEF_CW: i32 = 880; // default client size (the old fixed size)
const DEF_CH: i32 = 760;
const MIN_CW: i32 = 600; // smallest usable client (fits 640x480 boxes)
const MIN_CH: i32 = 380;

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

/// Wrapped height for a label showing `text` in width `w` (~8 px per char
/// at the system 8pt font — measured; 17 px per line). Must stay consistent
/// with wrap_text's per-char estimate or the label will clip its last line.
fn text_h(text: &str, w: i32) -> i32 {
    // 9px/char is deliberately conservative — the real average width of the
    // dialog font is ~8.5px, and an optimistic estimate makes the wrapped
    // label re-wrap into a line that does not fit the computed height
    // (observed: the rec-help text clipped after "There is").
    let per_line = (((w - 8) / 9).max(10)) as usize;
    let lines: usize = text
        .split('\n')
        .map(|l| (l.chars().count() + per_line - 1) / per_line)
        .sum::<usize>()
        .max(1);
    (lines as i32 * 18 + 6).max(18)
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

/// One control on a scrollable page. Built straight into the Box so the
/// win32 control has exactly one owner (nwg's Drop DESTROYS the window, so
/// nwg controls must never be cloned-and-kept — see the ScrollBar note in
/// run_gui).
enum PageCtl {
    Lbl(Box<nwg::Label>, u8),
    Check(Box<nwg::CheckBox>, u8),
    Radio(Box<nwg::RadioButton>, u8),
    Edit(Box<nwg::TextBox>, u8),
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
struct PageItem {
    ctl: PageCtl,
    x: i32,
    y: i32, // base y in scroll space (before offset/shift)
    w: i32,
    h: i32,
    idx: usize, // FP grid slot (column-major index); 0 elsewhere
}

type PageItems = Rc<std::cell::RefCell<Vec<PageItem>>>;

fn ctl_kind(ctl: &PageCtl) -> u8 {
    match ctl {
        PageCtl::Lbl(_, k) | PageCtl::Check(_, k) | PageCtl::Radio(_, k) | PageCtl::Edit(_, k) | PageCtl::Btn(_, k) => *k,
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
            it.h = 22;
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
    btn_everything: &'a nwg::Button,
    btn_back: &'a nwg::Button,
    btn_next: &'a nwg::Button,
    btn_cancel: &'a nwg::Button,
    iso: &'a PageItems,
    fp: &'a PageItems,
    sys: &'a PageItems,
    wifi_items: &'a PageItems,
    wifi: &'a std::cell::RefCell<Vec<Box<nwg::CheckBox>>>,
    fw: &'a Cell<i32>,
    iso_off: &'a Cell<i32>,
    fp_off: &'a Cell<i32>,
    sys_off: &'a Cell<i32>,
    wifi_off: &'a Cell<i32>,
    iso_geom: &'a Cell<(i32, i32, i32, i32, i32)>,
    fp_geom: &'a Cell<(i32, i32, i32, i32, i32)>,
    sys_geom: &'a Cell<(i32, i32, i32, i32, i32)>,
    wifi_geom: &'a Cell<(i32, i32, i32, i32, i32)>,
    fp_content: &'a Cell<i32>,
    guard: &'a Cell<bool>,
    iso_content: i32,
    sys_content: i32,
    wifi_content: i32,
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
    for f in [c.frame_hw, c.frame_iso, c.frame_fp, c.frame_sys, c.frame_wifi] {
        f.set_position(MARGIN, top);
        f.set_size(fw as u32, fh.max(60) as u32);
    }

    // nav strip: Next bottom-right, Back left of it, Cancel left of Back
    let ny = ch - MARGIN - 28;
    c.btn_next.set_position(cw - MARGIN - 96, ny);
    c.btn_next.set_size(96, 28);
    c.btn_back.set_position(cw - MARGIN - 96 - 96, ny);
    c.btn_back.set_size(90, 28);
    c.btn_cancel.set_position(cw - MARGIN - 96 - 96 - 96, ny);
    c.btn_cancel.set_size(90, 28);

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


    // scrollable pages 1-4: geometry, scrollbar, items
    // (top = fixed strip above the scroll area, bot = fixed strip below)
    let iso_top = (22 + rec_h + 10).max(72);
    let iso_shift = (iso_top - 72).max(0); // push items below a taller help text
    let pages = [
        (c.sb_iso, c.iso, c.iso_off, c.iso_geom, c.iso_content, iso_top, iso_bot, iso_shift),
        (c.sb_fp, c.fp, c.fp_off, c.fp_geom, c.fp_content.get(), 30, 12, 0),
        (c.sb_sys, c.sys, c.sys_off, c.sys_geom, c.sys_content, 4, 12, 0),
        (c.sb_wifi, c.wifi_items, c.wifi_off, c.wifi_geom, c.wifi_content, 4, 12, 0),
    ];
    for (sb, items, off, geom, content, top, bot, shift) in pages {
        let (vis, max_off, top, bot_edge, shift) = page_geom(fh, top, bot, content, shift);
        geom.set((vis, max_off, top, bot_edge, shift));
        off.set(off.get().min(max_off));
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
    url: String,
    dest: String,
    prog: std::sync::Arc<std::sync::atomic::AtomicU64>,
    total: std::sync::Arc<std::sync::atomic::AtomicU64>,
    finished: std::sync::Arc<std::sync::atomic::AtomicBool>,
    rx: std::sync::mpsc::Receiver<Result<(), String>>,
}

/// Start downloading `url` to <download_dir>\<name> in a background thread.
/// No-ops when the ISO is already on disk or there is no HTTP transport.
fn start_bg_download(
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
    // a directory/page URL (Lubuntu/Xubuntu/antiX/Zorin) is not directly
    // downloadable - the console flow opens it in the browser instead
    if !url.ends_with(".iso") {
        return;
    }
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
        url: url.to_string(),
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
}

/// Raw-HWND facade over the wizard window while the working phase runs.
pub struct WorkingUi {
    main: usize,
    status: usize,
    bg: Rc<std::cell::RefCell<Vec<BgDl>>>,
}

impl WorkingUi {
    pub fn set_status(&self, text: &str) {
        set_wnd_text(self.status, text);
        repaint(self.status);
    }

    /// Dispatch all pending messages so the window keeps painting while
    /// blocking work runs on this (the GUI) thread.
    pub fn pump(&self) {
        pump_pending(self.main);
    }

    pub fn close(&self) {
        if is_window(self.main) {
            use winapi::um::winuser::DestroyWindow;
            unsafe { DestroyWindow(self.main as winapi::shared::windef::HWND) };
        }
    }

    fn is_open(&self) -> bool {
        is_window(self.main)
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
        while PeekMessageW(&mut msg, std::ptr::null_mut(), 0, 0, PM_REMOVE) != 0 {
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
    let iso_geom: Rc<Cell<(i32, i32, i32, i32, i32)>> = Rc::new(Cell::new((0, 0, 0, 0, 0)));
    let fp_geom: Rc<Cell<(i32, i32, i32, i32, i32)>> = Rc::new(Cell::new((0, 0, 0, 0, 0)));
    let sys_geom: Rc<Cell<(i32, i32, i32, i32, i32)>> = Rc::new(Cell::new((0, 0, 0, 0, 0)));
    let wifi_geom: Rc<Cell<(i32, i32, i32, i32, i32)>> = Rc::new(Cell::new((0, 0, 0, 0, 0)));
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
    let _ = nwg::Label::builder()
        .text("Linux hardware compatibility (linux-hardware.org LKDDb): rating devices...")
        .position((10, 6))
        .size((820, 20))
        .parent(&frame_hw)
        .build(&mut lbl_hw);
    let _ = nwg::ListView::builder()
        .position((10, 30))
        .size((830, 560))
        .list_style(nwg::ListViewStyle::Detailed)
        .parent(&frame_hw)
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
    install_hw_custom_draw(&lv_hw, &frame_hw);
    for (i, (text, width)) in [
        ("Category", 110),
        ("Support", 250),
        ("Device", 314),
        ("ID", 100),
        ("www", 64),
    ].iter().enumerate() {
        lv_insert_column_direct(&lv_hw, i, text, *width);
    }

    // ---- page 1: ISO selection (all checkboxes, one column, scrollbar) ----
    let _ = nwg::Frame::builder()
        .position((MARGIN, 88))
        .size((DEF_CW - 2 * MARGIN, DEF_CH - 88 - NAV_H))
        .parent(&window)
        .build(&mut frame_iso);
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
        .parent(&frame_iso)
        .build(&mut lbl_rec);
    // the "Linux Mint Cinnamon is the recommended option." line stands out
    lbl_rec.set_font(Some(&font_bold));
    let _ = nwg::Label::builder()
        .text(&rec_help)
        .position((10, 22))
        .size((800, 46))
        .parent(&frame_iso)
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
            .parent(&frame_iso)
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
            .parent(&frame_iso)
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
            .parent(&frame_iso)
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
    for (n, iso) in found_isos.iter().take(10).enumerate() {
        let sz = sys::file_size(iso).unwrap_or(0);
        let is_the_mint = have_mint.as_deref() == Some(iso.as_str());
        let mut label = format!("{}  ({:.2} GB)", iso, sz as f64 / sys::GB as f64);
        if is_the_mint {
            label.push_str("  <- recommended (up-to-date, reuse instead of downloading)");
        }
        add_radio(&label, is_the_mint, 1, n == 0, &mut y);
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
    add_label("USB write method (how the ISO gets onto the stick):", &mut y);
    add_radio("Rufus (recommended - well tested, UEFI + BIOS; rewrites the stick)", write_mode_pre == "rufus", 3, true, &mut y);
    add_radio("Built-in non-destructive (less tested - no reformat, keeps existing files; BIOS boot)", write_mode_pre == "nofmt", 3, false, &mut y);
    add_radio("Skip - I will write the USB myself (like --skip-rufus)", write_mode_pre == "skip", 3, false, &mut y);
    let iso_content = y + 10;

    if let Err(e) = nwg::ScrollBar::builder()
        .flags(nwg::ScrollBarFlags::VERTICAL | nwg::ScrollBarFlags::VISIBLE)
        .position((826, 4))
        .size((18, 588))
        .parent(&frame_iso)
        .build(&mut sb_iso)
    {
        glog(&format!("scrollbar build error: {e:?}"));
    }

    // fixed controls at the bottom of the page
    let _ = nwg::Button::builder()
        .text("Install Everything (voidtools)")
        .position((10, 566))
        .size((400, 26))
        .parent(&frame_iso)
        .build(&mut btn_everything);
    if !crate::lslfiles::everything_path().is_empty() {
        btn_everything.set_text("Everything already installed (search ready)");
    }

    // ---- page 2: flatpaks (scrollable checkbox grid + extras) ----
    let _ = nwg::Frame::builder()
        .position((MARGIN, 88))
        .size((DEF_CW - 2 * MARGIN, DEF_CH - 88 - NAV_H))
        .parent(&window)
        .build(&mut frame_fp);
    let _ = nwg::Label::builder()
        .text("Flatpak apps to preload (checked = installed from Windows):")
        .position((10, 6))
        .size((560, 18))
        .parent(&frame_fp)
        .build(&mut lbl_fp);
    let sugg = crate::hardware::flatpak_suggestions();
    for (i, (app, _id, matched)) in sugg.iter().enumerate() {
        let mut cb: Box<nwg::CheckBox> = Box::default();
        let _ = nwg::CheckBox::builder()
            .text(app)
            .position((10, 30))
            .size((275, 20))
            .parent(&frame_fp)
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
            .parent(&frame_fp)
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
            .parent(&frame_fp)
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
            .position((10, 290))
            .size((560, 22))
            .text(&flatpak_extra.join(", "))
            .parent(&frame_fp)
            .build(&mut e);
        fp_items.borrow_mut().push(PageItem {
            ctl: PageCtl::Edit(e, 1),
            x: 10,
            y: 290,
            w: -20,
            h: 22,
            idx: 0,
        });
    }
    if let Err(e) = nwg::ScrollBar::builder()
        .flags(nwg::ScrollBarFlags::VERTICAL | nwg::ScrollBarFlags::VISIBLE)
        .position((826, 4))
        .size((18, 588))
        .parent(&frame_fp)
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
                .parent(&frame_sys)
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
                .parent(&frame_sys)
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
            .parent(&frame_sys)
            .build(&mut vhdx);
        sys.push(PageItem { ctl: PageCtl::Edit(vhdx, 1), x: 10, y: 26, w: -20, h: 160, idx: 0 });
        push_lbl(&mut sys, "LSL_DATA_DIR (Linux path, e.g. /mnt/c/Users/you/lsl-usb):", 10, 192, -20, 18, false);
        let default_data = format!(
            "/mnt/c/Users/{}/lsl-usb",
            sys::env_var("USERNAME").unwrap_or_default()
        );
        let mut data: Box<nwg::TextBox> = Box::default();
        let _ = nwg::TextBox::builder()
            .position((10, 212))
            .size((300, 22))
            .text(&default_data)
            .parent(&frame_sys)
            .build(&mut data);
        sys.push(PageItem { ctl: PageCtl::Edit(data, 2), x: 10, y: 212, w: -114, h: 22, idx: 0 });
        let mut browse: Box<nwg::Button> = Box::default();
        let _ = nwg::Button::builder()
            .text("Browse...")
            .position((760, 211))
            .size((90, 24))
            .parent(&frame_sys)
            .build(&mut browse);
        sys.push(PageItem { ctl: PageCtl::Btn(browse, 3), x: -104, y: 211, w: 90, h: 24, idx: 0 });
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
        push_lbl(&mut sys, "Renames pagefile.sys and each WSL2 swapfile.vhdx (after a clean-shutdown check) and uses that space as compressed swap. Used only if Windows was shut down normally (no Fast Startup / hibernate) - otherwise the reclaim is skipped entirely.", 20, 350, -30, 76, false);
        push_check(&mut sys, "Preload Rust CLI tools for the selected distro (fd / bat / zoxide)", 10, 430, 8, false);
    }
    if let Err(e) = nwg::ScrollBar::builder()
        .flags(nwg::ScrollBarFlags::VERTICAL | nwg::ScrollBarFlags::VISIBLE)
        .position((826, 4))
        .size((18, 588))
        .parent(&frame_sys)
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
    {
        let mut wifi = wifi_items.borrow_mut();
        let mut master: Box<nwg::CheckBox> = Box::default();
        let _ = nwg::CheckBox::builder()
            .text("Copy Wifi Settings to LSL")
            .position((10, 6))
            .size((560, 20))
            .parent(&frame_wifi)
            .build(&mut master);
        master.set_check_state(nwg::CheckBoxState::Checked);
        wifi.push(PageItem { ctl: PageCtl::Check(master, 9), x: 10, y: 6, w: -20, h: 20, idx: 0 });
        let mut cap: Box<nwg::Label> = Box::default();
        let _ = nwg::Label::builder()
            .text("Networks to copy (checked = include in wifi.sh):")
            .position((10, 30))
            .size((560, 18))
            .parent(&frame_wifi)
            .build(&mut cap);
        cap.set_font(Some(&font_bold));
        wifi.push(PageItem { ctl: PageCtl::Lbl(cap, 0), x: 10, y: 30, w: -30, h: 18, idx: 0 });
        if wifi_names.is_empty() {
            let mut none: Box<nwg::Label> = Box::default();
            let _ = nwg::Label::builder()
                .text("No saved wifi profiles found.")
                .position((20, WIFI_Y0))
                .size((560, 20))
                .parent(&frame_wifi)
                .build(&mut none);
            wifi.push(PageItem { ctl: PageCtl::Lbl(none, 0), x: 20, y: WIFI_Y0, w: -30, h: 20, idx: 0 });
        }
    }
    if let Err(e) = nwg::ScrollBar::builder()
        .flags(nwg::ScrollBarFlags::VERTICAL | nwg::ScrollBarFlags::VISIBLE)
        .position((826, 4))
        .size((18, 588))
        .parent(&frame_wifi)
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
            .parent(&frame_wifi)
            .build(&mut cb);
        cb.set_check_state(nwg::CheckBoxState::Checked);
        wifi_checks.borrow_mut().push(cb);
    }
    let wifi_content = WIFI_Y0 + (wifi_checks.borrow().len() as i32).max(1) * 20 + 10;

    // ---- nav buttons ----
    let _ = nwg::Button::builder()
        .text("< Back")
        .position((660, 706))
        .size((90, 28))
        .parent(&window)
        .build(&mut btn_back);
    btn_back.set_enabled(false);
    let _ = nwg::Button::builder()
        .text("Next >")
        .position((756, 706))
        .size((96, 28))
        .parent(&window)
        .build(&mut btn_next);
    let _ = nwg::Button::builder()
        .text("Cancel")
        .position((562, 706))
        .size((90, 28))
        .parent(&window)
        .build(&mut btn_cancel);

    // persistent ISO download progress: sits on the nav strip LEFT of the
    // buttons, parented to the WINDOW so it is visible on every page
    let mut lbl_dl: nwg::Label = Default::default();
    let mut pb_dl: nwg::ProgressBar = Default::default();
    let _ = nwg::Label::builder()
        .text("")
        .position((14, 710))
        .size((530, 14))
        .parent(&window)
        .build(&mut lbl_dl);
    let _ = nwg::ProgressBar::builder()
        .position((14, 726))
        .size((530, 8))
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

    // ---- first relayout pass (everything now exists) ----
    relayout(
        &LayoutCtx {
            lbl_sb: &lbl_sb,
            sb_text: &sb_text,
            frame_hw: &frame_hw,
            frame_iso: &frame_iso,
            frame_fp: &frame_fp,
            frame_sys: &frame_sys,
            frame_wifi: &frame_wifi,
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
            btn_everything: &btn_everything,
            btn_back: &btn_back,
            btn_next: &btn_next,
            btn_cancel: &btn_cancel,
            iso: &iso_items,
            fp: &fp_items,
            sys: &sys_items,
            wifi_items: &wifi_items,
            wifi: &wifi_checks,
            fw: &fw_cell,
            iso_off: &iso_off,
            fp_off: &fp_off,
            sys_off: &sys_off,
            wifi_off: &wifi_off,
            iso_geom: &iso_geom,
            fp_geom: &fp_geom,
            sys_geom: &sys_geom,
            wifi_geom: &wifi_geom,
            fp_content: &fp_content,
            guard: &in_relayout,
            iso_content: iso_content,
            sys_content: sys_content,
            wifi_content: wifi_content,
        },
        cw,
        ch,
    );

    // Hide pages 1-4 only AFTER all controls exist (their children were built
    // while the frame was visible, which wine requires). Only now, with all
    // five pages positioned and four of them hidden, is the window shown -
    // so the user only ever sees page 0, never the build-time stack.
    frame_iso.set_visible(false);
    frame_fp.set_visible(false);
    frame_sys.set_visible(false);
    frame_wifi.set_visible(false);
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
            &frame_iso,
            0x4C56_01usize,
            sb_iso.handle.hwnd(),
            iso_items.clone(),
            iso_geom.clone(),
            iso_off.clone(),
            fw_cell.clone(),
        ),
        bind_page_scroll(
            &frame_fp,
            0x4C56_02usize,
            sb_fp.handle.hwnd(),
            fp_items.clone(),
            fp_geom.clone(),
            fp_off.clone(),
            fw_cell.clone(),
        ),
        bind_page_scroll(
            &frame_sys,
            0x4C56_03usize,
            sb_sys.handle.hwnd(),
            sys_items.clone(),
            sys_geom.clone(),
            sys_off.clone(),
            fw_cell.clone(),
        ),
        bind_page_scroll(
            &frame_wifi,
            0x4C56_04usize,
            sb_wifi.handle.hwnd(),
            wifi_items.clone(),
            wifi_geom.clone(),
            wifi_off.clone(),
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
        let wifi_checks = wifi_checks.clone();
        let iso_items = iso_items.clone();
        let fp_items = fp_items.clone();
        let sys_items = sys_items.clone();
        let wifi_items = wifi_items.clone();
        let bg_downloads = bg_downloads.clone();
        let download_dir = download_dir.to_string();
        let distro_urls = distro_urls.clone();
        let fw_cell = fw_cell.clone();
        let iso_off = iso_off.clone();
        let fp_off = fp_off.clone();
        let sys_off = sys_off.clone();
        let wifi_off = wifi_off.clone();
        let iso_geom = iso_geom.clone();
        let fp_geom = fp_geom.clone();
        let sys_geom = sys_geom.clone();
        let wifi_geom = wifi_geom.clone();
        let fp_content = fp_content.clone();
        let in_relayout = in_relayout.clone();
        let sb_text_ref = sb_text.clone();
        let rec_help_ref = rec_help.clone();
        let iso_content = iso_content;
        let sys_content = sys_content;
        let wifi_content = wifi_content;
        move |event, data, handle| {
        use nwg::Event;
        match event {
            Event::OnResize | Event::OnWindowMaximize => {
                if let Some(hwnd) = win_hwnd {
                    let (cw, ch) = client_size(hwnd);
                    relayout(&LayoutCtx {
                        lbl_sb: &lbl_sb,
                        sb_text: &sb_text_ref,
                        frame_hw: &frame_hw,
                        frame_iso: &frame_iso,
                        frame_fp: &frame_fp,
                        frame_sys: &frame_sys,
                        frame_wifi: &frame_wifi,
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
                        btn_everything: &btn_everything,
                        btn_back: &btn_back,
                        btn_next: &btn_next,
                        btn_cancel: &btn_cancel,
                        iso: &iso_items,
                        fp: &fp_items,
                        sys: &sys_items,
                        wifi_items: &wifi_items,
                        wifi: &wifi_checks,
                        fw: &fw_cell,
                        iso_off: &iso_off,
                        fp_off: &fp_off,
                        sys_off: &sys_off,
                        wifi_off: &wifi_off,
                        iso_geom: &iso_geom,
                        fp_geom: &fp_geom,
                        sys_geom: &sys_geom,
                        wifi_geom: &wifi_geom,
                        fp_content: &fp_content,
                        guard: &in_relayout,
                        iso_content: iso_content,
                        sys_content: sys_content,
                        wifi_content: wifi_content,
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
                if handle == btn_next.handle {
                    glog("click next");
                    let cur = p2.get();
                    if cur < 4 {
                        p2.set(cur + 1);
                        frame_hw.set_visible(p2.get() == 0);
                        frame_iso.set_visible(p2.get() == 1);
                        frame_fp.set_visible(p2.get() == 2);
                        frame_sys.set_visible(p2.get() == 3);
                        frame_wifi.set_visible(p2.get() == 4);
                        btn_back.set_enabled(p2.get() > 0);
                        if p2.get() == 4 {
                            btn_next.set_text("Install");
                        } else {
                            btn_next.set_text("Next >");
                        }
                    } else {
                        // ---- Install clicked: enter the working phase ----
                        // The window STAYS VISIBLE (status text + progress)
                        // while main() resolves the ISO and launches Rufus;
                        // it only closes once Rufus is up (or the chosen
                        // write path needs no Rufus).
                        glog("click install");
                        f2.set(true);
                        working.set(true);
                        let g = harvest_gui_result(
                            &iso_arg2,
                            &distro_urls,
                            &iso_items,
                            &fp_items,
                            &sys_items,
                            &wifi_items,
                            &wifi_checks,
                        );
                        g_cell.replace(Some(g));
                        frame_hw.set_visible(false);
                        frame_iso.set_visible(false);
                        frame_fp.set_visible(false);
                        frame_sys.set_visible(false);
                        frame_wifi.set_visible(false);
                        sb_iso.set_visible(false);
                        sb_fp.set_visible(false);
                        sb_sys.set_visible(false);
                        sb_wifi.set_visible(false);
                        btn_back.set_enabled(false);
                        btn_next.set_enabled(false);
                        btn_cancel.set_enabled(false);
                        btn_everything.set_enabled(false);
                        lbl_dl.set_visible(false);
                        pb_dl.set_visible(false);
                        lbl_working.set_visible(true);
                        let ui = WorkingUi {
                            main: window.handle.hwnd().map(|h| h as usize).unwrap_or(0),
                            status: lbl_working.handle.hwnd().map(|h| h as usize).unwrap_or(0),
                            bg: bg_downloads.clone(),
                        };
                        ui_cell.replace(Some(ui));
                        // The callback (main's on_confirm) runs right after
                        // the dispatch loop ends - the window stays visible
                        // the whole time and the callback pumps it through
                        // WorkingUi::pump.
                        nwg::stop_thread_dispatch();
                    }
                } else if handle == btn_back.handle {
                    glog("click back");
                    let cur = p2.get();
                    if cur > 0 {
                        p2.set(cur - 1);
                        frame_hw.set_visible(p2.get() == 0);
                        frame_iso.set_visible(p2.get() == 1);
                        frame_fp.set_visible(p2.get() == 2);
                        frame_sys.set_visible(p2.get() == 3);
                        frame_wifi.set_visible(p2.get() == 4);
                        btn_back.set_enabled(p2.get() > 0);
                        btn_next.set_enabled(true);
                        btn_next.set_text(if p2.get() == 4 { "Install" } else { "Next >" });
                    }
                } else if handle == btn_cancel.handle {
                    glog("click cancel");
                    c2.set(true);
                    nwg::stop_thread_dispatch();
                } else if click_hwnd == browse_hwnd {
                    // Folder picker -> convert to the /mnt/<drive>/... form
                    if let Some(wpath) = sys::browse_folder("Choose the LSL_DATA_DIR folder (a Windows path)") {
                        for it in browse_data_sys.borrow_mut().iter() {
                            if let PageCtl::Edit(b, 2) = &it.ctl {
                                b.set_text(&sys::win_to_wsl_path(&wpath));
                            }
                        }
                    }
                } else if handle == btn_everything.handle {
                    if crate::lslfiles::everything_path().is_empty() {
                        btn_everything.set_enabled(false);
                        btn_everything.set_text("Installing Everything... (index building in background)");
                        let tx2 = tx.clone();
                        std::thread::spawn(move || {
                            let es = crate::lslfiles::install_everything();
                            let _ = tx2.send(HwMsg::EverythingDone(!es.is_empty()));
                        });
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
                            start_bg_download(&bg_downloads, url, &name, &download_dir);
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
                            const GLOBE: &str = "\u{1F310}\u{FE0E}"; // globe + text-presentation selector
                            lv_hw.insert_items_row(
                                None,
                                &[row.class, row.support, row.name, row.id, GLOBE.to_string()],
                            );
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
                        HwMsg::EverythingDone(ok) => {
                            btn_everything.set_enabled(true);
                            btn_everything.set_text(if ok {
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
                    const GLOBE2: &str = "\u{1F310}\u{FE0E}";
                    lv_hw.insert_items_row(None, &[r.class.clone(), r.support.clone(), r.name.clone(), r.id.clone(), if r.url.is_empty() { String::new() } else { GLOBE2.to_string() }]);
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
    let Some(g) = g_cell2.borrow_mut().take() else {
        return None; // cancelled or closed without Install
    };
    let Some(ui) = ui_cell2.borrow_mut().take() else {
        return None;
    };
    let work = on_confirm(g.clone(), &ui);
    Some((g, work))
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
        .split(',')
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
            // the USB-write-method radio section (kind 3); exactly one is
            // always selected, so the wizard always expresses a choice and
            // the console never needs to re-ask
            let mut mode = String::from("rufus");
            for it in iso_items.borrow().iter() {
                if let PageCtl::Radio(rb, 3) = &it.ctl {
                    glog(&format!(
                        "harvest write-mode radio '{}' checked={}",
                        rb.text(),
                        rb.check_state() == nwg::RadioButtonState::Checked
                    ));
                    if rb.check_state() == nwg::RadioButtonState::Checked {
                        let t = rb.text();
                        let tl = t.to_lowercase();
                        mode = if tl.contains("non-destructive") {
                            "nofmt".to_string()
                        } else if tl.starts_with("skip") {
                            "skip".to_string()
                        } else {
                            "rufus".to_string()
                        };
                        break;
                    }
                }
            }
            Some(mode)
        },
    }
}
