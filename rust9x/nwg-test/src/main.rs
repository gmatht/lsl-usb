//! Tiny GUI test app for rust9x + native-windows-gui (nwg).
//!
//! A 300x150 window with a label and two buttons. One button updates the
//! label, the other opens a modal message box, and closing the window ends
//! the message loop. Nothing here needs anything newer than Win9x-era APIs.
//!
//! Win95 notes:
//! - Uses `#![no_main]` + own `main` instead of the normal `main` so that
//!   `std::rt` initialization (which hangs inside the rust9x std on
//!   Windows 95) is skipped entirely. The GUI code needs no rt services:
//!   no threads, no filesystem, no unwinding (`panic = "abort"`).
//! - Target is `i586-rust9x-windows-msvc`: Win95 never enables CR4.OSFXSR,
//!   so any SSE instruction faults regardless of the CPU model.
//! - The vendored native-windows-gui uses the ANSI (Win95-safe) API
//!   variants; see vendor/native-windows-gui/README-WIN95.md.

#![windows_subsystem = "windows"]
#![no_main]

use native_windows_gui as nwg;
use std::cell::Cell;

mod float_shim;

/// Overrides the rustc `lang_start` shim: the CRT startup calls
/// `main` directly, so `std::rt` initialization is never run.
#[unsafe(no_mangle)]
pub extern "C" fn main() -> i32 {
    // (Patch-Win95) No stderr on Win95: surface panics in a MessageBox.
    std::panic::set_hook(Box::new(|info| {
        use winapi::um::winuser::{MB_ICONERROR, MB_OK, MessageBoxA};
        let mut msg: Vec<u8> = format!(
            "panic: {}\r\nat: {}",
            info,
            info.location().map(|l| l.to_string()).unwrap_or_default()
        )
        .bytes()
        .collect();
        msg.push(0);
        unsafe {
            MessageBoxA(
                0 as _,
                msg.as_ptr() as *const _,
                b"nwg-test panic\0".as_ptr() as *const _,
                MB_OK | MB_ICONERROR,
            );
        }
    }));
    run();
    0
}

fn run() {
    nwg::init().expect("Failed to init Native Windows GUI");

    let mut window: nwg::Window = Default::default();
    let mut label: nwg::Label = Default::default();
    let mut hello_btn: nwg::Button = Default::default();
    let mut about_btn: nwg::Button = Default::default();
    let mut frame: nwg::Frame = Default::default();
    let mut frame_label: nwg::Label = Default::default();
    let mut bold_label: nwg::Label = Default::default();
    let mut font_bold: nwg::Font = Default::default();
    let mut frame2: nwg::Frame = Default::default();
    let mut moved_label: nwg::Label = Default::default();
    let mut settext_label: nwg::Label = Default::default();
    let mut bold2_label: nwg::Label = Default::default();

    // (probe v3) edit-control style matrix — which EDIT styles are editable
    // on Win95? Tab order = creation order; the driver script tabs through
    // the four probes and types one marker word into each.
    //   P1 tb_default   : TextBox, default flags (multiline + V/HSCROLL +
    //                     AUTOVSCROLL/AUTOHSCROLL + WANTRETURN) — the FP
    //                     extras box style that reportedly can't be edited
    //   P2 tb_noscroll  : TextBox without V/HSCROLL (multiline still forced)
    //   P3 ti_ex_multi  : TextInput + ES_MULTILINE via ex_flags
    //   P4 ti_plain     : TextInput (single line) — the LSL_DATA_DIR fix,
    //                     known editable; control for the probe
    let mut tb_default: nwg::TextBox = Default::default();
    let mut tb_noscroll: nwg::TextBox = Default::default();
    let mut ti_ex_multi: nwg::TextInput = Default::default();
    let mut ti_plain: nwg::TextInput = Default::default();
    let mut lbl_p1: nwg::Label = Default::default();
    let mut lbl_p2: nwg::Label = Default::default();
    let mut lbl_p3: nwg::Label = Default::default();
    let mut lbl_p4: nwg::Label = Default::default();

    let _ = nwg::Font::builder().weight(700).build(&mut font_bold);

    let _ = nwg::Font::builder().weight(700).build(&mut font_bold);

    let _ = nwg::Window::builder()
        .size((640, 480))
        .position((0, 0))
        .title("nwg-test on rust9x")
        .build(&mut window);

    let _ = nwg::Label::builder()
        .text("Hello from rust9x!")
        .position((20, 15))
        .size((260, 25))
        .parent(&window)
        .build(&mut label);

    // (probe) frame + label-in-frame + bold-font label — lsl-install parity
    let _ = nwg::Frame::builder()
        .position((10, 100))
        .size((270, 90))
        .parent(&window)
        .build(&mut frame);
    let _ = nwg::Label::builder()
        .text("label inside frame")
        .position((10, 6))
        .size((240, 20))
        .parent(&frame)
        .build(&mut frame_label);
    let _ = nwg::Label::builder()
        .text("bold-font label in window")
        .position((20, 75))
        .size((260, 20))
        .parent(&window)
        .build(&mut bold_label);
    bold_label.set_font(Some(&font_bold));

    let _ = nwg::Button::builder()
        .text("Say hello")
        .position((20, 50))
        .size((120, 30))
        .parent(&window)
        .build(&mut hello_btn);

    let _ = nwg::Button::builder()
        .text("About")
        .position((20, 425))
        .size((120, 30))
        .parent(&window)
        .build(&mut about_btn);

    // (probe v2) lsl-install-style label operations
    let _ = nwg::Frame::builder()
        .position((150, 100))
        .size((460, 80))
        .parent(&window)
        .build(&mut frame2);
    let _ = nwg::Label::builder()
        .text("will be moved + resized")
        .position((10, 6))
        .size((400, 20))
        .parent(&frame2)
        .build(&mut moved_label);
    moved_label.set_position(10, 30);
    moved_label.set_size(420, 20);
    let _ = nwg::Label::builder()
        .text("initial text")
        .position((20, 195))
        .size((400, 20))
        .parent(&window)
        .build(&mut settext_label);
    settext_label.set_text("after set_text()");
    let _ = nwg::Label::builder()
        .text("initial bold text")
        .position((20, 225))
        .size((400, 20))
        .parent(&window)
        .build(&mut bold2_label);
    bold2_label.set_font(Some(&font_bold));
    bold2_label.set_text("after set_font + set_text");

    // (probe v3) the edit-control matrix, 2x2 grid, y=260..410
    let _ = nwg::Label::builder()
        .text("P1 TextBox default (multiline+scroll)")
        .position((20, 260))
        .size((280, 18))
        .parent(&window)
        .build(&mut lbl_p1);
    let _ = nwg::TextBox::builder()
        .position((20, 280))
        .size((280, 44))
        .text("P1 seed")
        .parent(&window)
        .build(&mut tb_default);
    let _ = nwg::Label::builder()
        .text("P2 TextBox no scrollbars")
        .position((330, 260))
        .size((280, 18))
        .parent(&window)
        .build(&mut lbl_p2);
    let _ = nwg::TextBox::builder()
        .flags(nwg::TextBoxFlags::VISIBLE | nwg::TextBoxFlags::TAB_STOP | nwg::TextBoxFlags::AUTOHSCROLL)
        .position((330, 280))
        .size((280, 44))
        .text("P2 seed")
        .parent(&window)
        .build(&mut tb_noscroll);
    let _ = nwg::Label::builder()
        .text("P3 TextInput + ES_MULTILINE (ex_flags)")
        .position((20, 340))
        .size((280, 18))
        .parent(&window)
        .build(&mut lbl_p3);
    // TextInput builder has no ex_flags wrapper for ES styles in the flags
    // enum; pass the raw style bits via ex_flags on top of the defaults.
    const ES_MULTILINE_RAW: u32 = 0x0004;
    const ES_WANTRETURN_RAW: u32 = 0x1000;
    let _ = nwg::TextInput::builder()
        .ex_flags(ES_MULTILINE_RAW | ES_WANTRETURN_RAW)
        .position((20, 360))
        .size((280, 44))
        .text("P3 seed")
        .parent(&window)
        .build(&mut ti_ex_multi);
    let _ = nwg::Label::builder()
        .text("P4 TextInput plain (control)")
        .position((330, 340))
        .size((280, 18))
        .parent(&window)
        .build(&mut lbl_p4);
    let _ = nwg::TextInput::builder()
        .position((330, 360))
        .size((280, 44))
        .text("P4 seed")
        .parent(&window)
        .build(&mut ti_plain);

    let clicks = Cell::new(0u32);

    let _handlers = nwg::full_bind_event_handler(&window.handle, move |event, _data, handle| {
        match event {
            nwg::Event::OnButtonClick => {
                if handle == hello_btn.handle {
                    let n = clicks.get() + 1;
                    clicks.set(n);
                    label.set_text(&format!("Hello #{}", n));
                } else if handle == about_btn.handle {
                    nwg::modal_info_message(
                        &window.handle,
                        "About nwg-test",
                        "Tiny GUI test built with rust9x + native-windows-gui",
                    );
                }
            }
            nwg::Event::OnWindowClose => {
                nwg::stop_thread_dispatch();
            }
            _ => {}
        }
    });

    nwg::dispatch_thread_events();
}
