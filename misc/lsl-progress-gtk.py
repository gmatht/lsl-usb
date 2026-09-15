#!/usr/bin/env python3
"""lsl-progress-gtk: stdin-fed progress dialog (zenity --progress fallback).

The firstboot progress/error dialogs need *some* GUI, but zenity is not in
the base image - it only arrives via firstboot apt, i.e. after (or never,
if offline) the dialogs are needed. python3-gi ships with the Cinnamon
desktop itself, so this is the backend that is actually present.

Protocol (same lines the zenity feeder emits, so callers are unchanged):
  progress mode (no --warn): read "PCT # text" lines from stdin, pulse the
      bar and show the text; quit on PCT 100, on EOF, or window close.
  warn mode (--warn): show a one-shot warning dialog, exit on close.

Exits 42 when Gtk is unavailable so the shell caller degrades loudly
instead of hanging on a dead pipe.
"""
import sys


def parse_args(argv):
    mode = "progress"
    title = "lsl-usb first boot"
    text = "Preparing your USB system (first boot)..."
    body = ""
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--warn":
            mode = "warn"
        elif a == "--title" and i + 1 < len(argv):
            i += 1
            title = argv[i]
        elif a == "--text" and i + 1 < len(argv):
            i += 1
            if mode == "warn":
                body = argv[i]
            else:
                text = argv[i]
        elif a == "--width":
            i += 1  # accepted for zenity-parity, ignored
        i += 1
    return mode, title, text, body


def main():
    mode, title, text, body = parse_args(sys.argv[1:])
    try:
        import gi
        gi.require_version("Gtk", "3.0")
        from gi.repository import Gtk, GLib
    except (ImportError, ValueError) as e:
        sys.stderr.write("lsl-progress-gtk: Gtk unavailable (%s)\n" % e)
        return 42

    if mode == "warn":
        dlg = Gtk.MessageDialog(
            parent=None,
            flags=0,
            message_type=Gtk.MessageType.WARNING,
            buttons=Gtk.ButtonsType.OK,
            text=title,
        )
        if body:
            dlg.format_secondary_text(body)
        dlg.set_wmclass("lsl-firstboot", "lsl-firstboot")
        dlg.run()
        dlg.destroy()
        return 0

    win = Gtk.Window(title=title)
    win.set_default_size(480, -1)
    win.set_border_width(12)
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
    win.add(box)
    label = Gtk.Label(label=text)
    label.set_line_wrap(True)
    box.pack_start(label, True, True, 0)
    bar = Gtk.ProgressBar()
    box.pack_start(bar, False, False, 0)
    win.connect("destroy", Gtk.main_quit)
    win.show_all()

    def pulse():
        bar.pulse()
        return True

    GLib.timeout_add(100, pulse)

    def on_input(source, _cond):
        line = source.readline()
        if not line:
            Gtk.main_quit()
            return False
        line = line.rstrip("\n")
        if "#" in line:
            pct, _, msg = line.partition("#")
            msg = msg.strip()
            if msg:
                label.set_text(msg)
            try:
                if int(pct.strip()) >= 100:
                    Gtk.main_quit()
                    return False
            except ValueError:
                pass
        else:
            label.set_text(line)
        return True

    GLib.io_add_watch(sys.stdin, GLib.IO_IN | GLib.IO_HUP, on_input)
    Gtk.main()
    return 0


if __name__ == "__main__":
    sys.exit(main())
