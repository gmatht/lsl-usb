//! Tiny GUI test app for rust9x + native-windows-gui (nwg).
//!
//! A 300x150 window with a label and two buttons. One button updates the
//! label, the other opens a modal message box, and closing the window ends
//! the message loop. Nothing here needs anything newer than Win9x-era APIs.

#![windows_subsystem = "windows"]

use native_windows_gui as nwg;
use std::cell::Cell;

mod float_shim;

fn main() {
    nwg::init().expect("Failed to init Native Windows GUI");

    let mut window: nwg::Window = Default::default();
    let mut label: nwg::Label = Default::default();
    let mut hello_btn: nwg::Button = Default::default();
    let mut about_btn: nwg::Button = Default::default();

    let _ = nwg::Window::builder()
        .size((300, 150))
        .position((300, 300))
        .title("nwg-test on rust9x")
        .build(&mut window);

    let _ = nwg::Label::builder()
        .text("Hello from rust9x!")
        .position((20, 15))
        .size((260, 25))
        .parent(&window)
        .build(&mut label);

    let _ = nwg::Button::builder()
        .text("Say hello")
        .position((20, 50))
        .size((120, 30))
        .parent(&window)
        .build(&mut hello_btn);

    let _ = nwg::Button::builder()
        .text("About")
        .position((20, 90))
        .size((120, 30))
        .parent(&window)
        .build(&mut about_btn);

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
