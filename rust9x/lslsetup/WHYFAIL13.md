# WHYFAIL13 — Why does "Preparing your USB system" sit at 100% forever?

Asked 2026-09-30, during a live first boot. Short answer: **the percentage was
never wrong — the window never closed.** `zenity` does not exit on the `100`
sentinel the feeder emits, and it does not exit on EOF either; the feeding shell
then parks in `do_wait` on the pipeline, so the finished progress dialog stays on
screen indefinitely. On this boot it outlived the setup by **2 hours 3 minutes**
and was still up *on top of* the reboot-approval dialog.

The operator's second question — *"I have only ever seen the one bar, never the
stages"* — has a separate cause: **GTK is the only backend that renders the task
list, and it was gated behind `zenity` being absent.** zenity arrives *mid-boot*
via the firstboot `apt` step, so the good UI was unreachable exactly when it was
needed.

This documents both, plus four wrong turns taken while diagnosing it, because
the wrong turns are the instructive part.

---

## 1. What the operator saw

During first boot, a dialog reading:

```
lsl-usb first boot
Preparing your USB system (first boot)...
[==================== 100% ====================]  Cancel
```

Live evidence captured while the dialog was still on screen (window
`0x02c00003`, process 3477, elapsed **02:03:51**):

```
3477  Sl  02:03:51  zenity --progress --auto-kill --title=lsl-usb first boot \
                      --text=Preparing your USB system (first boot)... --width=480
3420  S   do_wait    /usr/local/bin/lsl-firstboot-progress.sh
```

The feeder (pid 3476) was **gone**, and zenity's stdin was **gone with it**:

```
$ ls /proc/3477/fd/
1 -> /dev/null   2 -> /tmp/lsl-firstboot-dialog.log   3 -> socket:[16374]   ...
# no fd 0 at all
```

Meanwhile the boot had finished long before:

```
/run/lsl-firstboot-status
  phase=done - waiting for reboot approval
  task=done    done=wifi,network,flatpak,packages,layer,home    pct=100

/cdrom/casper/lsl-firstboot.done   (0 bytes, created 12:26)

$ DISPLAY=:0 wmctrl -l
0x02c00003  ubuntu  lsl-usb first boot           <- STALE, 2h03m
0x03200003  ubuntu  lsl-usb first boot complete  <- the reboot dialog
```

Two dialogs, stacked, the finished progress window underneath/over the reboot
prompt.

## 2. What the operator's "always 100%" actually means

The `pct=100` was **honest**. The service finale writes it last:

```bash
rm -f "$STATUS"      # status file DELETED
touch "$STAMP"       # then the stamp appears
```

so a finished boot leaves no status file and a stamp, and `pct=100` was real at
12:26. The dialog's own label agreed (`100 # Done - waiting for reboot
approval`). **The number was correct; the window simply never went away.** That
is why it "always showed 100%": the only state of this window anyone ever sees
is a finished one that failed to close.

## 3. Root cause

### 3a. `zenity` does not close on `100`, and does not close on EOF

`feed_zenity`'s contract, per its own comment, was:

> `# 100 closes the zenity window; it must only be sent when the boot really finished cleanly.`

Measured 2026-09-30 on the image's `zenity 3.44`, testing the **real zenity PID**
(a previous attempt captured the subshell's PID instead and produced a bogus
"exits in ~0s" result — see §6):

| writer behaviour | zenity result |
|---|---|
| emits `100`, writer then **exits** (no flags) | **STILL ALIVE after 8s** |
| holds the pipe open at `100` (no flags) | STILL ALIVE after 8s |
| emits `100`, writer exits, `--auto-close` | exited rc=0 after ~0.4s |
| writer killed **by PID** | exits rc=143 — **the only reliable close** |

So `100` is not a close signal. And because the writer is the left side of a
pipeline whose shell (`lsl-firstboot-progress.sh`) stays alive, the window is
never reaped: shell 3420 sat in `do_wait` for the full 2h03m.

The confusing part, and what makes this look impossible at first: zenity's
stdin was **closed** (no fd 0) and the producer had already exited, so the
pipeline was effectively at EOF — yet zenity still did not act on it. "The
writer is gone" is not sufficient; zenity only goes away when it is killed.

### 3b. The stage list was gated behind zenity's absence

```bash
# before
if command -v zenity >/dev/null 2>&1; then
    DIALOG_PROG=zenity          # single bar, one text line, never closes
elif ... python3 -c 'import gi' ...; then
    DIALOG_PROG=gtk             # full task list — unreachable in practice
fi
```

`misc/lsl-progress-gtk.py` is the only backend with a task list
(`--status-file` mode renders done / current / pending rows per `WORK_STAGES`).
Its own header says python3-gi ships with Cinnamon while *"zenity only arrives
via firstboot apt — after (or, offline, never) the dialog is needed."* That
reasoning was written down and then contradicted by the branch order: **zenity
appearing mid-boot flips the backend**, so the same stick can show zenity early
and GTK late, and in the common case shows only zenity.

## 4. Fix

### `misc/lsl-firstboot-progress.sh` — GTK is now preferred

```bash
if gtk_available; then
    DIALOG_PROG=gtk
elif command -v zenity >/dev/null 2>&1; then
    DIALOG_PROG=zenity
fi
```

The GTK dialog polls the status file itself, renders the whole task list, and
**exits on its own** ~1.5s after the stamp appears (`refresh()` →
`finish_ui()` → `Gtk.main_quit`) — so there is no window to close by PID and no
stale dialog left over the reboot approval.

### `misc/lsl-firstboot-progress.sh` — zenity closes by PID

The zenity branch no longer relies on the `100` sentinel. It keeps zenity as its
own process, polls until the stamp (or Cancel), then **kills it by PID**:

```bash
feed_zenity | zenity --progress --auto-kill ... &
ZENITY_PID=$!
while ! stamp_present; do
    kill -0 "$ZENITY_PID" 2>/dev/null || break
    sleep 1
done
if kill -0 "$ZENITY_PID" 2>/dev/null; then
    kill "$ZENITY_PID" 2>/dev/null
fi
wait "$ZENITY_PID" 2>/dev/null
```

Two traps avoided here, both of which bit during development:

- `wait "$ZENITY_PID"` must **not** be called while the writer may still be
  alive: for `a | b &`, `wait` blocks until **both** pipeline ends exit, so a
  stalled writer hangs the caller. Hence the poll-then-kill.
- `${?}` immediately after `wait` is the rc only if `wait` is the previous
  command; the original code read `PIPESTATUS` *after* an intervening statement
  and so logged a meaningless value.

## 5. Verification

`bash -n misc/lsl-firstboot-progress.sh` clean.

The GTK dialog was exercised against a synthetic status file (the `pct=44`,
step-5/8 state the operator saw):

```
gtk fallback: window shown (mode=progress display=:0 stamp=... status=...)
gtk fallback: finish_ui clean=False phase=installing packages and packing layer...
gtk fallback: stamp present - closing after 0 ticks
```

It read the status file, correctly judged the boot **not** clean (so it did
**not** paint 100% over a partial run — the `finish_ui` guard works), and exited
by itself on the stamp.

Also confirmed: `Gtk` + `python3-gi` import fine as the desktop user on this
image, and the GTK script is already what renders the reboot-approval dialog
(pid 168999, `--reboot-countdown 0`), so the code path is known-good in this
session.

**Not verified:** that the GTK *stage-list window actually paints* on screen.
The probe could not be completed without `su` to the desktop user (declined),
and every attempt self-closed for a legitimate reason — `stamp_present()` also
checks `/cdrom/casper/lsl-firstboot.done`, which exists from the finished run.
Treat the visual assertion as untested.

The stale window seen in §1 was killed (pids 3477 / 3420) as cleanup.

## 6. Four wrong turns (the instructive part)

Each of these was asserted confidently and then disproved. They are recorded
because the same traps will catch the next person.

1. **"The stamp is a premature sentinel — the feeder stops on the stamp rather
   than on a finished status file."**
   False. The service writes the stamp *last*, after `rm -f "$STATUS"`. The
   stamp is a faithful end-of-work marker.

2. **"zenity ignores `100` *and* EOF, so it is stuck at 100% forever."**
   Half-true, from a bad experiment: the test wrote to a pipe and **never closed
   the write end**, so the writer was holding it open by construction. That is a
   writer-holding-the-pipe result, not a zenity result. The corrected finding —
   zenity still does not exit on EOF in the real pipeline arrangement (§3a) —
   happens to agree, but the reasoning that produced it was invalid.

3. **"There is no bug at all; the bar was just stale."**
   Also wrong, and worse: it nearly closed the ticket. `pct` *is* stale during
   long silent steps (it only advances at task boundaries — the status file's
   `mtime` was **20:06:52** while `apt install` kept running), but staleness was
   not the defect. The window genuinely outlived the boot by two hours.

A fourth, self-inflicted one, since it produced a number quoted above:

4. **`hold.sh` "measured" zenity exiting in ~0s** because it captured
   `$( ... & echo $! )` — the PID of the **subshell**, not of zenity. `kill -0`
   then tested the wrong process and reported success. Always confirm the
   target PID with `ps -o cmd -p "$PID"` before trusting a liveness check.

## 7. The `lslsetup` changes made in the same session

These are **unrelated to the first-boot dialog above** — they were written
because the investigation began in the wrong tree (the string
*"Preparing your USB system (first boot)..."* sent me to `rust9x/lslsetup`, where
it does not appear). They are kept because they fix a real defect found while
auditing the same class of bug: a progress bar that reports completion that has
not happened.

### `src/gui.rs` — `bar_units()` and the reserved `max == 100` range

`bar_units()` built its comctl32 range from `total / MB`:

```rust
// before
let max = ((total / sys::MB).max(1)).min(i32::MAX as u64) as i32;
let pos = (done / sys::MB).min(total / sys::MB).min(max as u64) as i32;
```

For any transfer whose size rounds to **≤ 100 MB**, `max` lands on or under 100
— and `(0, 100)` is the progress bar's *reserved indeterminate range*, so the
control paints **100% full regardless of position**. A sub-100 MB stage
therefore read 100% from its first chunk. `max` is now scaled off that value,
both range ends scaled identically so the ratio (and the rendered fill) is
preserved exactly, and the position is clamped to `max - 1` so a **running** bar
can never read complete:

```rust
// after
let scale: u64 = if mb_total == 1 { 1000 }
                 else if mb_total == 100 { 10 }
                 else if mb_total < 100 { 100 }
                 else { 1 };
let cap = if max_u > 1 { max_u - 1 } else { 0 };
let pos = (mb_done * scale).min(cap).min(max as u64) as i32;
```

Supporting changes:

| item | purpose |
|---|---|
| `bar_units_done()` | the sole `(1000, 1000)` full bar; only `set_stage_done()` uses it |
| `set_bar_units_raw()` | sets explicit control units, rewriting any `max == 100` |
| `set_stage_skipped()` | a *skipped* stage empties its bar instead of claiming completion |
| `wait_until_closed()` | pumps until the window is really destroyed |
| FAILED page "Close" | no longer destroys the window — the reason stays readable |

### `src/main.rs`

- The five `set_stage_progress(stage, 1, 1)` "skipped" markers now call
  `set_stage_skipped` (a full bar for work that never ran is the same lie).
- `fatal_gui()` waits for a real window close instead of `exit(1)`-ing behind a
  live dialog, so the failure reason is not destroyed on dismissal.

### Verification status — READ THIS

**The `lslsetup` changes are uncompiled and untested.** This box is plain Linux
(`Linux 6.14.0-37-generic`, not WSL) and the only toolchain present is the
Windows `rust9x` one (`cargo.exe` / `rustc.exe`, PE32+), with no `wine`, so
`cargo +rust9x test` cannot run here.

What *was* checked:

- The `bar_units` logic was simulated faithfully over 26 cases including the
  exact boundaries that broke. All invariants hold: `max > 0`, `pos < max`,
  `max != 100`; and the ratio is preserved
  (`30 MB @ 50% → (3000, 1500)`, `100 MB @ 50% → (1000, 500)`).
- **That simulation caught two bugs in the first two attempts** — a total of
  exactly 100 MB, and sub-megabyte totals, both still produced `max == 100`.
  Both are fixed and re-verified.
- Both edited files are brace/paren/bracket balanced (checked with a
  Rust-aware lexer, not a naive counter), all new symbols resolve, and CRLF line
  endings were preserved (0 bare LF).

Still required from a Windows host:

```
cargo +rust9x test --target i686-rust9x-windows-msvc
```

Note that `progress_bar_units_survive_iso_sizes` had its assertions changed and
`running_bar_never_reads_complete` was added — green is expected but unverified.

## 8. What is NOT yet in effect

- The fix lives in `misc/lsl-firstboot-progress.sh`. The stick runs
  `/usr/local/bin/lsl-firstboot-progress.sh` (md5 `63fbab54…`), so **nothing
  changes until the layer is rebuilt**.
- `rust9x/lslsetup` carries unrelated edits from the same session (§7). They fix
  a genuine comctl32 `max == 100` trap but have nothing to do with this dialog,
  and they are **uncompiled/untested** — no Rust toolchain is runnable on this
  box.

## 9. Related

- **`WHYFAIL11.md`** — same family of error: a graceful *signal* (there, an exit
  code; here, a progress percentage) mistaken for the state that matters. The
  caller re-reads live state and does not care what was printed.
- **`misc/lsl-progress-gtk.py`** header — already documented that zenity is
  absent when the dialog is first needed. The backend order simply failed to
  honour its own note.
- **`WHYFAIL8.md`** — the earlier SIGPIPE investigation that led to
  `--auto-close` being removed. Removing it was right; the replacement — "the
  writer emits 100 to close the window" — was never true and was what shipped.

## TL;DR

The bar was honest; the **window never closed**. `zenity 3.44` does not exit on
the `100` sentinel, nor on stdin EOF in this pipeline arrangement, and the
feeding shell then blocks in `do_wait` — so a *finished* first-boot dialog stayed
on screen for **2h03m**, on top of the reboot dialog, looking like a hang stuck
at 100%. Fixed by preferring the GTK backend (which renders the task list *and*
self-exits on the stamp) and by closing zenity **by PID**. Needs a layer rebuild
to reach the stick.

## The rule worth keeping

> **A progress percentage is not a lifecycle event.**
> `100` does not mean "done" and it certainly does not mean "close the window".
> The renderer must be told, by an event it actually honours — and the only
> close that survived measurement was `kill "$PID"`.
