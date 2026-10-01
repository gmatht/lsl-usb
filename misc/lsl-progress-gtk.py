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
      reboot approval dialog with Reboot now / Reboot later buttons; writes
      reboot-now or reboot-cancel into the flag dir (the root firstboot
      service only reboots after reboot-now - there is no timer and no
      automatic reboot; closing the window counts as Reboot later). The
      SECONDS value is accepted for compatibility and ignored.

  choice mode (--choice --options "A|B|C" [--preselect N]): single-choice
      radiolist dialog (used where zenity --list --radiolist would be, but
      Mint ships no zenity out of the box); prints the chosen label, exit 0.
      Dismissal prints nothing and exits 1.

  ramclone mode (--ramclone [--status-bin PATH] [--eject-bin PATH]
      [--detach-allowed 0|1]): Boot-to-RAM dialog. Shows the dm-clone
      hydration progress reported by lsl-ramclone-status and, once the copy is
      complete, offers a "Detach USB" button that runs lsl-ramclone-eject (via
      pkexec/sudo) and then reports that the stick can be removed.

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
import shutil
import subprocess
import sys
import time

# Same trace targets as lsl-firstboot-progress.sh (dialog_log): /tmp and the
# journal are RAM-only, so the root firstboot service also keeps a persistent
# trace in /run/lsl-firstboot/dialog-trace.log that it flushes to the stick and
# lsl-diag.sh captures. The GTK path used to write NOTHING here - which is why
# two post-mortems ("was the progress dialog even shown?", 2026-09-15/16 and
# 2026-09-21) could not see this backend at all. Keep the two backends equally
# observable: every entry/exit path below logs.
DIALOG_LOG = os.environ.get("LSL_DIALOG_LOG", "/tmp/lsl-firstboot-dialog.log")
DIALOG_TRACE = os.environ.get("LSL_DIALOG_TRACE", "/run/lsl-firstboot/dialog-trace.log")


def dialog_log(msg):
    """Best-effort append to the dialog log + trace (never raises)."""
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    line = "%s %s\n" % (ts, msg)
    for path in (DIALOG_LOG, DIALOG_TRACE):
        try:
            with open(path, "a", encoding="utf-8", errors="replace") as f:
                f.write(line)
        except OSError:
            pass


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
    countdown = 0
    flag_dir = "/run/lsl-firstboot"
    status_bin = "/cdrom/bin/lsl-ramclone-status"
    eject_bin = "/cdrom/bin/lsl-ramclone-eject"
    detach_allowed = True
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
                    countdown = max(0, int(argv[i]))
                except ValueError:
                    pass
        elif a.startswith("--reboot-countdown="):
            mode = "reboot"
            try:
                countdown = max(0, int(a.split("=", 1)[1]))
            except ValueError:
                pass
        elif a == "--flag-dir" and i + 1 < len(argv):
            i += 1
            flag_dir = argv[i] or flag_dir
        elif a.startswith("--flag-dir="):
            flag_dir = a.split("=", 1)[1] or flag_dir
        elif a == "--choice":
            mode = "choice"
        elif a == "--ramclone":
            mode = "ramclone"
        elif a == "--status-bin" and i + 1 < len(argv):
            i += 1
            status_bin = argv[i] or status_bin
        elif a.startswith("--status-bin="):
            status_bin = a.split("=", 1)[1] or status_bin
        elif a == "--eject-bin" and i + 1 < len(argv):
            i += 1
            eject_bin = argv[i] or eject_bin
        elif a.startswith("--eject-bin="):
            eject_bin = a.split("=", 1)[1] or eject_bin
        elif a.startswith("--detach-allowed="):
            detach_allowed = a.split("=", 1)[1].strip() not in ("0", "no", "false", "")
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
        elif a.startswith("--title="):
            title = a.split("=", 1)[1] or title
        elif a == "--text" and i + 1 < len(argv):
            i += 1
            if mode == "warn":
                body = argv[i]
            else:
                text = argv[i]
        elif a.startswith("--text="):
            _v = a.split("=", 1)[1]
            if mode == "warn":
                body = _v or body
            else:
                text = _v or text
        elif a == "--width":
            i += 1  # accepted for zenity-parity, ignored
        elif a.startswith("--width="):
            pass  # accepted for zenity-parity, ignored
        elif a == "--status-file" and i + 1 < len(argv):
            i += 1
            status_file = argv[i]
        elif a.startswith("--status-file="):
            status_file = a.split("=", 1)[1] or status_file
        elif a == "--stamp" and i + 1 < len(argv):
            i += 1
            stamp = argv[i]
        elif a.startswith("--stamp="):
            stamp = a.split("=", 1)[1] or stamp
        elif a == "--poll" and i + 1 < len(argv):
            i += 1
            try:
                poll = max(0.2, float(argv[i]))
            except ValueError:
                pass
        elif a.startswith("--poll="):
            try:
                poll = max(0.2, float(a.split("=", 1)[1]))
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
        status_bin,
        eject_bin,
        detach_allowed,
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
        status_bin,
        eject_bin,
        detach_allowed,
    ) = parse_args(sys.argv[1:])
    try:
        import gi
        gi.require_version("Gtk", "3.0")
        from gi.repository import Gtk, GLib
    except (ImportError, ValueError) as e:
        sys.stderr.write("lsl-progress-gtk: Gtk unavailable (%s)\n" % e)
        dialog_log("gtk fallback: Gtk unavailable (%s) - progress invisible" % e)
        return 42

    if mode == "reboot":
        return run_reboot_countdown(Gtk, GLib, title, text, countdown, flag_dir)

    if mode == "choice":
        return run_choice(Gtk, GLib, title, text, choice_options, choice_preselect)

    if mode == "ramclone":
        return run_ramclone(Gtk, GLib, title, text, status_bin, eject_bin, detach_allowed, poll)

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

    win.show_all()
    win.present()

    # A window that never rendered and one that rendered then vanished look
    # identical in the trace ("starting" ... nothing). Record the backend, the
    # display and the effective stamp path so an early exit is attributable.
    dialog_log(
        "gtk fallback: window shown (mode=%s display=%s stamp=%s status=%s)"
        % (mode, os.environ.get("DISPLAY", "none"), stamp or "(fallbacks)", status_file or "(stdin)")
    )

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
    state = {"done_quit": False, "last": "", "ticks": 0}

    def refresh():
        if os.getppid() == 1:
            # Parent (the shell caller) is gone - there is nobody left to show
            # this to. Logged, because a bare "starting" line with no matching
            # "finished" was one of the two historic post-mortem mysteries.
            dialog_log(
                "gtk fallback: parent gone (reparented to init) - closing after %d ticks, last=%s"
                % (state["ticks"], state["last"] or "(nothing rendered)")
            )
            Gtk.main_quit()
            return False
        if stamp_present(stamp):
            finish_ui("Done - waiting for reboot approval")
            if not state["done_quit"]:
                state["done_quit"] = True
                # Log once: refresh() keeps ticking through the 1.5s grace
                # period, and one line per tick made the trace look alarming.
                dialog_log(
                    "gtk fallback: stamp present - closing after %d ticks, last=%s"
                    % (state["ticks"], state["last"] or "(nothing rendered)")
                )
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
        # Heartbeat: remember what the window last showed so any exit (stamp,
        # parent death, window close) can report it instead of vanishing.
        state["ticks"] += 1
        state["last"] = "step %d/%d (%d%%) task=%s" % (idx + 1, n, overall_pct, task or "?")
        if state["ticks"] == 1:
            dialog_log("gtk fallback: first render - %s" % state["last"])
        return True

    def finish_ui(text_done):
        # The stamp means "root-side setup returned", NOT "everything worked".
        # lsl-firstboot.sh writes the stamp before it blocks in
        # schedule_reboot_on_approval(), and it also stamps on the failure and
        # no-uproot paths (and with LSL_HOME_FAILED=1 when this boot's /home
        # will be lost). Blanket "Done — 100%" here painted a full green bar
        # over a phase that literally starts with "failed -" and over a done
        # list that does not cover every task (observed 2026-09-29: the `stick`
        # task never completed, phase='failed - setup complete but /home not
        # persisted', and the dialog still showed 100%). Report what the status
        # file actually says: 100% only for a clean, complete firstboot.
        data = read_status(status_file)
        tasks = parse_tasks(data)
        done = parse_done(data)
        phase = (data.get("phase", "") or "").strip()
        labels = {tid: label for tid, label in tasks}
        clean = not phase.lower().startswith("failed") and all(
            tid in done for tid, _ in tasks
        )
        for tid, (sym, txt, _h) in rows.items():
            label = labels.get(tid, tid)
            if tid in done:
                sym.set_markup('<span fgcolor="#2e7d32">✔</span>')
                txt.set_markup('<span fgcolor="#555555">%s</span>' % GLib.markup_escape_text(label))
            else:
                # Not completed (or never reached): keep it visibly pending
                # instead of stamping a tick over it.
                sym.set_markup('<span fgcolor="#c62828">✖</span>')
                txt.set_markup(
                    '<span fgcolor="#c62828">%s (not completed)</span>'
                    % GLib.markup_escape_text(label)
                )
        if clean:
            overall.set_fraction(1.0)
            overall.set_text("Done — 100%")
            current_bar.set_fraction(1.0)
            detail.set_text(text_done)
        else:
            # Finished, but with a problem. Do NOT claim 100%: hold the bar at
            # the last real value (never above 99) and let the detail line carry
            # the failure, which is the one thing the operator must not miss
            # before rebooting.
            fail_text = (data.get("detail", "") or "").strip() or phase or text_done
            overall.set_fraction(0.99)
            overall.set_text("Finished with problems — see below")
            current_bar.set_fraction(0.0)
            detail.set_text(fail_text[:320])
        dialog_log(
            "gtk fallback: finish_ui clean=%s phase=%s done=%s"
            % (clean, phase or "(none)", data.get("done", "") or "(none)")
        )

    def on_destroy(_w=None):
        dialog_log(
            "gtk fallback: window closed by user after %d ticks, last=%s"
            % (state["ticks"], state["last"] or "(nothing rendered)")
        )
        Gtk.main_quit()

    win.connect("destroy", on_destroy)

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
    """End-of-firstboot reboot approval: wait indefinitely for the user to
    choose Reboot now / Reboot later. Writes flag_dir/reboot-now or
    reboot-cancel; the root firstboot service only reboots after reboot-now,
    so every exit path here is safe (reboot, defer, or crash-and-keep-
    waiting for a fresh login to re-show this dialog). Closing the window
    counts as Reboot later - a surprise reboot is worse than a deferred one
    (the stamped layer activates on the next boot anyway). The countdown
    value is ignored: there is no timer and no automatic reboot."""
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

    waiting = Gtk.Label()
    waiting.set_xalign(0.5)
    waiting.set_markup(
        "<big><b>Waiting for your approval</b></big>\n"
        "<span fgcolor=\"#555555\">No timer - the system will not reboot until you choose.</span>"
    )
    box.pack_start(waiting, False, False, 0)

    buttons = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
    box.pack_start(buttons, False, False, 0)
    reboot_btn = Gtk.Button(label="Reboot now")
    cancel_btn = Gtk.Button(label="Reboot later")
    buttons.pack_start(reboot_btn, True, True, 0)
    buttons.pack_start(cancel_btn, True, True, 0)

    state = {"over": False}

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

    win.show_all()
    win.present()
    Gtk.main()
    return 0


def run_ramclone(Gtk, GLib, title, text, status_bin, eject_bin, detach_allowed, poll):
    """Boot-to-RAM dialog: show dm-clone hydration progress, then (when the copy
    is complete and every layer is RAM-backed) offer a "Detach USB" button that
    runs lsl-ramclone-eject and reports that the stick can be removed."""
    win = Gtk.Window(title=title)
    win.set_default_size(560, -1)
    win.set_border_width(12)
    win.set_position(Gtk.WindowPosition.CENTER)
    win.set_wmclass("lsl-ramclone", "lsl-ramclone")
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
    win.add(box)

    header = Gtk.Label(label=text)
    header.set_line_wrap(True)
    header.set_xalign(0.0)
    box.pack_start(header, False, False, 0)

    bar = Gtk.ProgressBar()
    bar.set_show_text(True)
    box.pack_start(bar, False, False, 0)

    detail = Gtk.Label(label="")
    detail.set_line_wrap(True)
    detail.set_xalign(0.0)
    detail.set_max_width_chars(72)
    box.pack_start(detail, False, False, 0)

    buttons = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
    box.pack_start(buttons, False, False, 0)
    detach_btn = Gtk.Button(label="Detach USB")
    later_btn = Gtk.Button(label="Later")
    buttons.pack_start(detach_btn, True, True, 0)
    buttons.pack_start(later_btn, True, True, 0)

    win.connect("destroy", Gtk.main_quit)
    state = {"busy": False}

    def status_pct():
        """(pct, complete) from lsl-ramclone-status; (-1, False) on error."""
        try:
            p = subprocess.run([status_bin], capture_output=True, text=True, timeout=15)
        except Exception:
            return -1, False
        lines = (p.stdout or "").strip().splitlines()
        pct = -1
        if lines:
            try:
                pct = int(lines[0].strip())
            except ValueError:
                pct = -1
        return pct, (p.returncode == 0)

    def show_done():
        bar.set_fraction(1.0)
        bar.set_text("100%")
        header.set_text("Live system copied to RAM")
        if not detach_allowed:
            detail.set_text(
                "Some layers are still read from the USB stick, so it cannot be "
                "detached automatically here — use the shutdown menu before "
                "unplugging it."
            )
            buttons.set_visible(False)
            return
        detail.set_text("You can now detach the USB stick.")
        detach_btn.set_label("Detach USB")
        detach_btn.set_sensitive(True)
        later_btn.set_sensitive(True)
        buttons.set_visible(True)

    def poll_status():
        if state["busy"]:
            return True
        pct, complete = status_pct()
        if complete or pct >= 100:
            show_done()
            return False
        if pct >= 0:
            bar.set_fraction(max(0.01, min(0.99, pct / 100.0)))
            bar.set_text("%d%%" % pct)
            detail.set_text("Copying the live system into RAM…")
        else:
            detail.set_text("Waiting for the copy to start…")
        return True

    def run_eject():
        if os.geteuid() == 0:
            cmd = [eject_bin]
        elif shutil.which("pkexec"):
            cmd = ["pkexec", eject_bin]
        elif shutil.which("sudo"):
            cmd = ["sudo", eject_bin]
        else:
            return False, "No pkexec/sudo available."
        try:
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
        except Exception as e:  # noqa: BLE001
            return False, str(e)
        if p.returncode != 0:
            return False, (p.stderr or p.stdout or "eject failed").strip()
        return True, ""

    def on_detach(_btn=None):
        if state["busy"]:
            return
        state["busy"] = True
        detach_btn.set_sensitive(False)
        later_btn.set_sensitive(False)
        detail.set_text("Detaching the USB stick…")
        while Gtk.events_pending():
            Gtk.main_iteration_do(False)
        ok, err = run_eject()
        state["busy"] = False
        if ok:
            header.set_text("It is now safe to remove your stick.")
            detail.set_text("The session is now running entirely from RAM.")
            buttons.set_visible(False)
        else:
            header.set_text("Could not detach the USB")
            detail.set_text(err[:300])
            detach_btn.set_label("Retry detach")
            detach_btn.set_sensitive(True)
            later_btn.set_sensitive(True)

    def on_later(_btn=None):
        Gtk.main_quit()

    detach_btn.connect("clicked", on_detach)
    later_btn.connect("clicked", on_later)

    win.show_all()
    buttons.set_visible(False)
    win.present()

    pct, complete = status_pct()
    if complete or pct >= 100:
        show_done()
    else:
        GLib.timeout_add(int(max(0.5, poll) * 1000), poll_status)
        poll_status()

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
            # EOF means the feeder died (or closed the pipe). Log it: this is
            # the GTK-path equivalent of the zenity SIGPIPE failure, and the
            # old code closed the window here without a trace.
            dialog_log("gtk fallback: stdin EOF (feeder gone) - closing window")
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
