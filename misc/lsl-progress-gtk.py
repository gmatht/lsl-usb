#!/usr/bin/env python3
"""lsl-progress-gtk: task-list progress dialog (zenity --progress fallback).

The firstboot progress/error dialogs need *some* GUI, but zenity is not in
the base image - it only arrives via firstboot apt, i.e. after (or never,
if offline) the dialogs are needed. python3-gi ships with the Cinnamon
desktop itself, so this is the backend that is actually present.

Two progress modes:

  status-file mode (preferred, used by lsl-firstboot-progress.sh):
      poll --status-file every --poll seconds and render the full task
      list (done / current / pending), overall progress, current-task
      progress, and detail text. Quits shortly after the stamp appears.

  stdin mode (legacy fallback): read "PCT # text" lines from stdin, pulse
      the bar and show the text; quit on PCT 100, on EOF, or window close.

  warn mode (--warn): show a one-shot warning dialog, exit on close.

  reboot mode (--reboot-countdown SECONDS [--flag-dir DIR]): end-of-firstboot
      reboot timer with a live MM:SS countdown and Reboot now / Cancel
      buttons; writes reboot-now or reboot-cancel into the flag dir (the root
      firstboot service owns the actual reboot and fires on timeout; closing
      the window counts as Cancel).

  choice mode (--choice --options "A|B|C" [--preselect N]): single-choice
      radiolist dialog (used where zenity --list --radiolist would be, but
      Mint ships no zenity out of the box); prints the chosen label, exit 0.
      Dismissal prints nothing and exits 1.

Status file format (written atomically by lsl-firstboot.sh):
  phase=  human-readable phase (legacy)
  tasks=  id:label|id:label|... (full ordered task list)
  task=   current task id
  done=   comma-separated completed task ids
  pct=    0..100 progress through the CURRENT task
  detail= human-readable detail for the current task

Exits 42 when Gtk is unavailable so the shell caller degrades loudly
instead of hanging on a dead pipe.
"""
import os
import sys
import time

# KEEP IN SYNC with LSL_TASKS in misc/lsl-firstboot.sh.
TASK_ORDER = [
    ("stick", "Find USB stick"),
    ("wifi", "Stage Wi-Fi"),
    ("network", "Wait for network"),
    ("flatpak", "Install Flatpaks"),
    ("packages", "Install packages"),
    ("layer", "Pack USB layer"),
    ("home", "Back up home"),
    ("done", "Finish & reboot"),
]

STAMP_FALLBACKS = (
    "/isodevice/casper/lsl-firstboot.done",
    "/cdrom/casper/lsl-firstboot.done",
)


def parse_args(argv):
    mode = "progress"
    choice_options = []
    choice_preselect = 1
    title = "lsl-usb first boot"
    text = "Preparing your USB system (first boot)..."
    body = ""
    status_file = ""
    stamp = ""
    poll = 0.5
    countdown = 600
    flag_dir = "/run/lsl-firstboot"
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--warn":
            mode = "warn"
        elif a == "--reboot-countdown":
            mode = "reboot"
            if i + 1 < len(argv):
                i += 1
                try:
                    countdown = max(1, int(argv[i]))
                except ValueError:
                    pass
        elif a.startswith("--reboot-countdown="):
            mode = "reboot"
            try:
                countdown = max(1, int(a.split("=", 1)[1]))
            except ValueError:
                pass
        elif a == "--flag-dir" and i + 1 < len(argv):
            i += 1
            flag_dir = argv[i] or flag_dir
        elif a.startswith("--flag-dir="):
            flag_dir = a.split("=", 1)[1] or flag_dir
        elif a == "--choice":
            mode = "choice"
        elif a == "--options" and i + 1 < len(argv):
            i += 1
            choice_options = [o for o in argv[i].split("|")]
        elif a.startswith("--options="):
            choice_options = [o for o in a.split("=", 1)[1].split("|")]
        elif a == "--preselect" and i + 1 < len(argv):
            i += 1
            try:
                choice_preselect = max(1, int(argv[i]))
            except ValueError:
                pass
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
        elif a == "--status-file" and i + 1 < len(argv):
            i += 1
            status_file = argv[i]
        elif a == "--stamp" and i + 1 < len(argv):
            i += 1
            stamp = argv[i]
        elif a == "--poll" and i + 1 < len(argv):
            i += 1
            try:
                poll = max(0.2, float(argv[i]))
            except ValueError:
                pass
        i += 1
    return (
        mode,
        title,
        text,
        body,
        status_file,
        stamp,
        poll,
        countdown,
        flag_dir,
        choice_options,
        choice_preselect,
    )


def read_status(path):
    """Read the key=value status file into a dict (last wins)."""
    data = {}
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.rstrip("\n\r")
                if not line or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                data[k.strip()] = v.strip()
    except OSError:
        pass
    return data


def parse_tasks(data):
    """Return [(id, label)] from the tasks= line, else the canonical order."""
    raw = data.get("tasks", "")
    if not raw:
        return list(TASK_ORDER)
    out = []
    for entry in raw.split("|"):
        entry = entry.strip()
        if not entry:
            continue
        if ":" in entry:
            tid, _, label = entry.partition(":")
            tid, label = tid.strip(), label.strip()
        else:
            tid, label = entry, entry
        if tid:
            out.append((tid, label or tid))
    return out or list(TASK_ORDER)


def parse_done(data):
    return {d.strip() for d in data.get("done", "").split(",") if d.strip()}


def parse_pct(data):
    try:
        return max(0, min(100, int(data.get("pct", "0").strip())))
    except ValueError:
        return 0


def stamp_present(stamp):
    for p in [stamp] + list(STAMP_FALLBACKS) if stamp else list(STAMP_FALLBACKS):
        if p and os.path.exists(p):
            return True
    return False


def main():
    (
        mode,
        title,
        text,
        body,
        status_file,
        stamp,
        poll,
        countdown,
        flag_dir,
        choice_options,
        choice_preselect,
    ) = parse_args(sys.argv[1:])
    try:
        import gi
        gi.require_version("Gtk", "3.0")
        from gi.repository import Gtk, GLib
    except (ImportError, ValueError) as e:
        sys.stderr.write("lsl-progress-gtk: Gtk unavailable (%s)\n" % e)
        return 42

    if mode == "reboot":
        return run_reboot_countdown(Gtk, GLib, title, text, countdown, flag_dir)

    if mode == "choice":
        return run_choice(Gtk, GLib, title, text, choice_options, choice_preselect)

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
    win.set_default_size(560, -1)
    win.set_border_width(12)
    win.set_position(Gtk.WindowPosition.CENTER)
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
    win.add(box)

    header = Gtk.Label(label=text)
    header.set_line_wrap(True)
    header.set_xalign(0.0)
    box.pack_start(header, False, False, 0)

    overall = Gtk.ProgressBar()
    overall.set_show_text(True)
    box.pack_start(overall, False, False, 0)

    task_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
    box.pack_start(task_box, False, False, 0)

    current_bar = Gtk.ProgressBar()
    current_bar.set_show_text(False)
    box.pack_start(current_bar, False, False, 0)

    detail = Gtk.Label(label="starting…")
    detail.set_line_wrap(True)
    detail.set_xalign(0.0)
    detail.set_max_width_chars(72)
    box.pack_start(detail, False, False, 0)

    win.connect("destroy", Gtk.main_quit)
    win.show_all()
    win.present()

    if not status_file:
        return run_stdin_mode(Gtk, GLib, detail, current_bar, win)

    # Status-file mode: poll and render the full task list.
    rows = {}  # task id -> (symbol_label, text_label)
    for tid, label in TASK_ORDER:
        h = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        sym = Gtk.Label()
        sym.set_width_chars(3)
        txt = Gtk.Label()
        txt.set_xalign(0.0)
        h.pack_start(sym, False, False, 0)
        h.pack_start(txt, True, True, 0)
        task_box.pack_start(h, False, False, 0)
        rows[tid] = (sym, txt, h)
    task_box.show_all()
    state = {"done_quit": False}

    def refresh():
        if os.getppid() == 1:
            Gtk.main_quit()
            return False
        if stamp_present(stamp):
            finish_ui("Done - rebooting")
            if not state["done_quit"]:
                state["done_quit"] = True
                GLib.timeout_add(1500, Gtk.main_quit)
            return True
        data = read_status(status_file)
        tasks = parse_tasks(data)
        done = parse_done(data)
        task = data.get("task", "").strip()
        pct = parse_pct(data)
        detail_text = data.get("detail", "").strip() or data.get("phase", "").strip() or "working…"

        # Ensure rows exist for any task ids the service advertises that we
        # have never seen (forward-compat if LSL_TASKS grows).
        for tid, label in tasks:
            if tid not in rows:
                h = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
                sym = Gtk.Label()
                sym.set_width_chars(3)
                txt = Gtk.Label()
                txt.set_xalign(0.0)
                h.pack_start(sym, False, False, 0)
                h.pack_start(txt, True, True, 0)
                task_box.pack_start(h, False, False, 0)
                h.show_all()
                rows[tid] = (sym, txt, h)

        # Current-task index (unknown id -> first pending).
        idx = next((i for i, (tid, _) in enumerate(tasks) if tid == task), -1)
        if idx < 0:
            idx = next(
                (i for i, (tid, _) in enumerate(tasks) if tid not in done),
                0,
            )
            task = tasks[idx][0] if tasks else ""
        n = max(1, len(tasks))
        overall_pct = (idx * 100 + pct) // n
        overall_pct = max(1, min(99, overall_pct))

        # Hide rows for tasks no longer advertised (defensive; keeps the
        # window stable if the service ever shrinks the list).
        advertised = {tid for tid, _ in tasks}
        for tid, (sym, txt, h) in rows.items():
            h.set_visible(tid in advertised)

        for i, (tid, label) in enumerate(tasks):
            sym, txt, _h = rows[tid]
            if tid in done or i < idx:
                sym.set_markup('<span fgcolor="#2e7d32">✔</span>')
                txt.set_markup(
                    '<span fgcolor="#555555">%s</span>' % GLib.markup_escape_text(label)
                )
            elif i == idx:
                sym.set_markup('<span fgcolor="#1565c0">➜</span>')
                txt.set_markup(
                    '<b>%s</b> <span fgcolor="#555555">(%d%%)</span>'
                    % (GLib.markup_escape_text(label), pct)
                )
            else:
                sym.set_markup('<span fgcolor="#9e9e9e">○</span>')
                txt.set_markup(
                    '<span fgcolor="#9e9e9e">%s</span>' % GLib.markup_escape_text(label)
                )

        overall.set_fraction(overall_pct / 100.0)
        overall.set_text("Step %d/%d — %d%%" % (idx + 1, n, overall_pct))
        current_bar.set_fraction(pct / 100.0)
        detail.set_text(detail_text[:320])
        return True

    def finish_ui(text_done):
        for tid, (sym, txt, _h) in rows.items():
            label = next((l for t, l in parse_tasks(read_status(status_file)) if t == tid), tid)
            sym.set_markup('<span fgcolor="#2e7d32">✔</span>')
            txt.set_markup('<span fgcolor="#555555">%s</span>' % GLib.markup_escape_text(label))
        overall.set_fraction(1.0)
        overall.set_text("Done — 100%")
        current_bar.set_fraction(1.0)
        detail.set_text(text_done)

    GLib.timeout_add(int(poll * 1000), refresh)
    refresh()
    Gtk.main()
    return 0


def run_choice(Gtk, GLib, title, text, options, preselect):
    """Single-choice radiolist dialog: the GTK replacement for
    `zenity --list --radiolist` (Mint ships no zenity out of the box).
    Prints the chosen label to stdout, exit 0. Dismissal (Cancel, Escape,
    window close) prints nothing and exits 1. Empty options exits 1."""
    if not options:
        return 1
    if preselect < 1 or preselect > len(options):
        preselect = 1

    win = Gtk.Window(title=title)
    win.set_default_size(560, -1)
    win.set_border_width(12)
    win.set_position(Gtk.WindowPosition.CENTER)
    win.set_wmclass("lsl-choice", "lsl-choice")
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
    win.add(box)

    header = Gtk.Label(label=text)
    header.set_line_wrap(True)
    header.set_xalign(0.0)
    box.pack_start(header, False, False, 0)

    radios = []
    group = None
    for label in options:
        if group is None:
            rb = Gtk.RadioButton.new_with_label_from_widget(None, label)
            group = rb
        else:
            rb = Gtk.RadioButton.new_with_label_from_widget(group, label)
        box.pack_start(rb, False, False, 0)
        radios.append(rb)
    radios[preselect - 1].set_active(True)

    buttons = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
    box.pack_start(buttons, False, False, 0)
    ok_btn = Gtk.Button(label="Choose")
    cancel_btn = Gtk.Button(label="Cancel")
    buttons.pack_start(ok_btn, True, True, 0)
    buttons.pack_start(cancel_btn, True, True, 0)

    state = {"choice": None}

    def finish_ok(_btn=None):
        for rb in radios:
            if rb.get_active():
                state["choice"] = rb.get_label()
                break
        Gtk.main_quit()

    def finish_cancel(_btn=None):
        Gtk.main_quit()

    ok_btn.connect("clicked", finish_ok)
    cancel_btn.connect("clicked", finish_cancel)
    win.connect("destroy", finish_cancel)

    win.show_all()
    win.present()
    Gtk.main()
    if state["choice"] is None:
        return 1
    try:
        sys.stdout.write(state["choice"] + "\n")
        sys.stdout.flush()
    except OSError:
        return 1
    return 0


def run_reboot_countdown(Gtk, GLib, title, text, seconds, flag_dir):
    """End-of-firstboot reboot timer: live MM:SS countdown with Reboot now /
    Cancel buttons. Writes flag_dir/reboot-now or reboot-cancel; the root
    firstboot service owns the actual reboot and fires on timeout, so every
    exit path here is safe (proceed, cancel, or crash-and-reboot-on-time).
    Closing the window counts as Cancel - a surprise reboot is worse than a
    deferred one (the stamped layer activates on the next boot anyway)."""
    try:
        os.makedirs(flag_dir, exist_ok=True)
    except OSError:
        pass

    def touch(name):
        try:
            with open(os.path.join(flag_dir, name), "a", encoding="utf-8"):
                pass
        except OSError:
            pass

    win = Gtk.Window(title=title)
    win.set_default_size(520, -1)
    win.set_border_width(12)
    win.set_position(Gtk.WindowPosition.CENTER)
    win.set_wmclass("lsl-firstboot", "lsl-firstboot")
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
    win.add(box)

    header = Gtk.Label(label=text)
    header.set_line_wrap(True)
    header.set_xalign(0.0)
    box.pack_start(header, False, False, 0)

    countdown = Gtk.Label()
    countdown.set_xalign(0.5)
    box.pack_start(countdown, False, False, 0)

    bar = Gtk.ProgressBar()
    bar.set_show_text(False)
    box.pack_start(bar, False, False, 0)

    buttons = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
    box.pack_start(buttons, False, False, 0)
    reboot_btn = Gtk.Button(label="Reboot now")
    cancel_btn = Gtk.Button(label="Cancel automatic reboot")
    buttons.pack_start(reboot_btn, True, True, 0)
    buttons.pack_start(cancel_btn, True, True, 0)

    state = {"over": False}
    deadline = time.monotonic() + seconds

    def render(left):
        mm, ss = divmod(max(0, left), 60)
        countdown.set_markup(
            "<big><b>%d:%02d</b> until automatic reboot</big>" % (mm, ss)
        )
        bar.set_fraction(max(0.0, min(1.0, 1.0 - left / float(seconds))))

    def finish_reboot(_btn=None):
        if state["over"]:
            return
        state["over"] = True
        touch("reboot-now")
        Gtk.main_quit()

    def finish_cancel(_btn=None):
        if state["over"]:
            return
        state["over"] = True
        touch("reboot-cancel")
        Gtk.main_quit()

    reboot_btn.connect("clicked", finish_reboot)
    cancel_btn.connect("clicked", finish_cancel)
    win.connect("destroy", finish_cancel)

    def tick():
        if state["over"]:
            return False
        left = int(deadline - time.monotonic())
        if left <= 0:
            countdown.set_markup("<big><b>Rebooting now…</b></big>")
            bar.set_fraction(1.0)
            state["over"] = True
            GLib.timeout_add(1200, Gtk.main_quit)
            return False
        render(left)
        return True

    render(seconds)
    win.show_all()
    win.present()
    GLib.timeout_add(250, tick)
    Gtk.main()
    return 0


def run_stdin_mode(Gtk, GLib, label, bar, win):
    """Legacy fallback: pulse while "PCT # text" lines arrive on stdin."""

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
                # Strip the " || task=..;done=..;.." metadata suffix if a
                # newer feeder ever pipes it here; zenity shows it raw.
                label.set_text(msg.split(" || ")[0])
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
