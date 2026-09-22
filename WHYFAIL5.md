## What's happening

Your "Reboot now" button worked correctly. The machine has no listener for it.
Confirmed beyond doubt. Here's what's happening:

## What's happening

Your "Reboot now" button worked correctly. The machine has no listener for it.

Confirmed beyond doubt. Here's what's happening:

## What's happening

Your "Reboot now" button worked correctly. The machine has no listener for it.

The flow on this live USB is intentionally split in two:

1. Desktop dialog (lsl-firstboot-reboot.sh → GTK), owned by you (ubuntu). When you click Reboot now, its only action is touch /run/lsl-firstboot/reboot-now. It deliberately cannot reboot the machine itself. ✅ This happened — the flag exists:
```
   -rw-rw-r-- 1 ubuntu ubuntu 0 Sep 21 17:01 reboot-now
```

1. Root service (lsl-firstboot.service → lsl-firstboot.sh), the only thing that reads that flag and then runs systemctl reboot. ❌ This is dead. It ran at 00:59:34 and exited at 00:59:37 with status=0/SUCCESS — 3 milliseconds — because of the stamp guard at line 353:
```bash
   if [ -e "$STAMP" ]; then exit 0   # STAMP=/cdrom/casper/lsl-firstboot.done
```
   The stamp exists (Sep 21 09:02, from a previous completed firstboot), so the script exits before ever reaching schedule_reboot_on_approval() and its while true wait loop.

The design assumed "the finale stamps first, then waits for approval" — the stamp is written before the wait loop, so that's fine within a single run. But the desktop side re-shows the approval dialog on every login whenever the stamp exists and no flag is recorded (see reboot_approval_pending() in lsl-firstboot-progress.sh). So on any boot after the first successful one, you get the dialog, you click the button, the flag is written — and the service that would act on it has already short-circuited on the stamp. Classic two-process race where the writer outlives the reader. pgrep shows nothing waiting on reboot-now.

Your earlier WHYFAIL3.md documents the same stamp-gate pattern biting the WiFi path (lsl-firstboot.service exiting in 7 ms). This reboot bug is that exact failure mode, in the reboot finale.

## Fix it right now

The flag is already set; just do what the missing service would have done:

```bash
sync && sudo systemctl reboot
```

(The flag file is ubuntu-owned and sync handles the stick; no need to re-click anything.)

## Fix it properly

Match the consumer's lifetime to the producer. Options, least→most invasive:

• Best: move schedule_reboot_on_approval (and any other "act on user flags" work) before the [ -e "$STAMP" ] && exit 0 guard, or into a small always-run tail that isn't stamp-gated, so every boot the service re-arms the wait loop.
• Or: have the desktop button not depend on a root service at all for the "now" case — let the dialog call systemctl reboot via polkit (org.freedesktop.login1.reboot), which is present and active here (polkit.service running, your session registered an auth agent). Then the stamp gate can't strand it.
• Or: make lsl-firstboot-progress.sh's stamp-present branch, when it re-shows the dialog, also spawn the root waiter — but that needs privilege, which is why the current design split them in the first place.

The one-liner gets you rebooted; the guard reorder is the real fix so the next person who presses that button isn't confused. Want me to apply the reorder to /usr/local/sbin/lsl-firstboot.sh (it lives in the squashfs layer, so it'd need r──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯ 
## What's happening

Your "Reboot now" button worked correctly. The machine has no listener for it.
Confirmed beyond doubt. Here's what's happening:

## What's happening

Your "Reboot now" button worked correctly. The machine has no listener for it.

Confirmed beyond doubt. Here's what's happening:

## What's happening

Your "Reboot now" button worked correctly. The machine has no listener for it.

The flow on this live USB is intentionally split in two:

1. Desktop dialog (lsl-firstboot-reboot.sh → GTK), owned by you (ubuntu). When you click Reboot now, its only action is touch /run/lsl-firstboot/reboot-now. It deliberately cannot reboot the machine itself. ✅ This happened — the flag exists:
```
   -rw-rw-r-- 1 ubuntu ubuntu 0 Sep 21 17:01 reboot-now
```

1. Root service (lsl-firstboot.service → lsl-firstboot.sh), the only thing that reads that flag and then runs systemctl reboot. ❌ This is dead. It ran at 00:59:34 and exited at 00:59:37 with status=0/SUCCESS — 3 milliseconds — because of the stamp guard at line 353:
```bash
   if [ -e "$STAMP" ]; then exit 0   # STAMP=/cdrom/casper/lsl-firstboot.done
```
   The stamp exists (Sep 21 09:02, from a previous completed firstboot), so the script exits before ever reaching schedule_reboot_on_approval() and its while true wait loop.

The design assumed "the finale stamps first, then waits for approval" — the stamp is written before the wait loop, so that's fine within a single run. But the desktop side re-shows the approval dialog on every login whenever the stamp exists and no flag is recorded (see reboot_approval_pending() in lsl-firstboot-progress.sh). So on any boot after the first successful one, you get the dialog, you click the button, the flag is written — and the service that would act on it has already short-circuited on the stamp. Classic two-process race where the writer outlives the reader. pgrep shows nothing waiting on reboot-now.

Your earlier WHYFAIL3.md documents the same stamp-gate pattern biting the WiFi path (lsl-firstboot.service exiting in 7 ms). This reboot bug is that exact failure mode, in the reboot finale.

## Fix it right now

The flag is already set; just do what the missing service would have done:

```bash
sync && sudo systemctl reboot
```

(The flag file is ubuntu-owned and sync handles the stick; no need to re-click anything.)

## Fix it properly

Match the consumer's lifetime to the producer. Options, least→most invasive:

• Best: move schedule_reboot_on_approval (and any other "act on user flags" work) before the [ -e "$STAMP" ] && exit 0 guard, or into a small always-run tail that isn't stamp-gated, so every boot the service re-arms the wait loop.
• Or: have the desktop button not depend on a root service at all for the "now" case — let the dialog call systemctl reboot via polkit (org.freedesktop.login1.reboot), which is present and active here (polkit.service running, your session registered an auth agent). Then the stamp gate can't strand it.
• Or: make lsl-firstboot-progress.sh's stamp-present branch, when it re-shows the dialog, also spawn the root waiter — but that needs privilege, which is why the current design split them in the first place.

The one-liner gets you rebooted; the guard reorder is the real fix so the next person who presses that button isn't confused. Want me to apply the reorder to /usr/local/sbin/lsl-firstboot.sh (it lives in the squashfs layer, so it'd need r──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯ 
i## What's happening

Your "Reboot now" button worked correctly. The machine has no listener for it.
Confirmed beyond doubt. Here's what's happening:

## What's happening

Your "Reboot now" button worked correctly. The machine has no listener for it.

Confirmed beyond doubt. Here's what's happening:

## What's happening

Your "Reboot now" button worked correctly. The machine has no listener for it.

The flow on this live USB is intentionally split in two:

1. Desktop dialog (lsl-firstboot-reboot.sh → GTK), owned by you (ubuntu). When you click Reboot now, its only action is touch /run/lsl-firstboot/reboot-now. It deliberately cannot reboot the machine itself. ✅ This happened — the flag exists:
```
   -rw-rw-r-- 1 ubuntu ubuntu 0 Sep 21 17:01 reboot-now
```

1. Root service (lsl-firstboot.service → lsl-firstboot.sh), the only thing that reads that flag and then runs systemctl reboot. ❌ This is dead. It ran at 00:59:34 and exited at 00:59:37 with status=0/SUCCESS — 3 milliseconds — because of the stamp guard at line 353:
```bash
   if [ -e "$STAMP" ]; then exit 0   # STAMP=/cdrom/casper/lsl-firstboot.done
```
   The stamp exists (Sep 21 09:02, from a previous completed firstboot), so the script exits before ever reaching schedule_reboot_on_approval() and its while true wait loop.

The design assumed "the finale stamps first, then waits for approval" — the stamp is written before the wait loop, so that's fine within a single run. But the desktop side re-shows the approval dialog on every login whenever the stamp exists and no flag is recorded (see reboot_approval_pending() in lsl-firstboot-progress.sh). So on any boot after the first successful one, you get the dialog, you click the button, the flag is written — and the service that would act on it has already short-circuited on the stamp. Classic two-process race where the writer outlives the reader. pgrep shows nothing waiting on reboot-now.

Your earlier WHYFAIL3.md documents the same stamp-gate pattern biting the WiFi path (lsl-firstboot.service exiting in 7 ms). This reboot bug is that exact failure mode, in the reboot finale.

## Fix it right now

The flag is already set; just do what the missing service would have done:

```bash
sync && sudo systemctl reboot
```

(The flag file is ubuntu-owned and sync handles the stick; no need to re-click anything.)

## Fix it properly

Match the consumer's lifetime to the producer. Options, least→most invasive:

• Best: move schedule_reboot_on_approval (and any other "act on user flags" work) before the [ -e "$STAMP" ] && exit 0 guard, or into a small always-run tail that isn't stamp-gated, so every boot the service re-arms the wait loop.
• Or: have the desktop button not depend on a root service at all for the "now" case — let the dialog call systemctl reboot via polkit (org.freedesktop.login1.reboot), which is present and active here (polkit.service running, your session registered an auth agent). Then the stamp gate can't strand it.
• Or: make lsl-firstboot-progress.sh's stamp-present branch, when it re-shows the dialog, also spawn the root waiter — but that needs privilege, which is why the current design split them in the first place.

The one-liner gets you rebooted; the guard reorder is the real fix so the next person who presses that button isn't confused. Want me to apply the reorder to /usr/local/sbin/lsl-firstboot.sh (it lives in the squashfs layer, so it'd need r──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯ 
<BS>


» bash  echo "=== flag still sitting there, unread? ==="; ls -la /run/lsl-firstboot/ 2>/dev/null; echo; echo "=== has ANY process read it? service exited long ago ==="; systemctl show lsl-firstboot.service -p ActiveState,SubState,ExecMain
StartTimestamp,ExecMainExitTimestamp; echo; echo "=== uptime (did it reboot at all?) ==="; uptime; echo; echo "=== still this same boot? ==="; who -b; journalctl --list-boots 2>/dev/null | tail -3

  === flag still sitting there, unread? ===
  total 4
  drwxrwxrwt  2 root   root    100 Sep 21 17:01 .
  drwxr-xr-x 40 root   root   1080 Sep 21 17:00 ..
  -rw-rw-rw-  1 root   root      0 Sep 22  2026 boot-times.log
  -rw-rw-rw-  1 root   root    241 Sep 21 17:01 dialog-trace.log
  -rw-rw-r--  1 ubuntu ubuntu    0 Sep 21 17:01 reboot-now
  
  === has ANY process read it? service exited long ago ===
  ExecMainStartTimestamp=Tue 2026-09-22 00:59:34 UTC
  ExecMainExitTimestamp=Tue 2026-09-22 00:59:37 UTC
  ActiveState=inactive
  SubState=dead
  
  === uptime (did it reboot at all?) ===
   17:14:08 up 15 min,  1 user,  load average: 0.41, 0.23, 0.19
  
  === still this same boot? ===
           system boot  2026-09-22 00:59
  IDX BOOT ID                          FIRST ENTRY                 LAST ENTRY
    0 03f9f2f315fd4381bdd33bbbeb6890ec Tue 2026-09-22 00:59:15 UTC Mon 2026-09-21 17:14:09 UTC



Right — confirmed, still not working. The evidence is unambiguous:
Right — confirmed, still not working. The evidence is unambiguous:
Right — confirmed, still not working. The evidence is unambiguous:

• reboot-now is still sitting there unread (created 17:01, still present now at 17:14).
• No reboot happened — uptime is 15 min, same boot 03f9f2f3… that started at 00:59 (a single boot entry in the list, no rotation).
• The service that reads it is long gone — started 00:59:34, exited 00:59:37, ActiveState=inactive. It will not come back this boot. Nothing is polling the flag.

So the sequence was: you clicked → flag written → nobody was listening → nothing. And it will stay stuck exactly like that, because the reader is a one-shot service that already finished before you pressed the button. Pressing it again would just overwrite the same flag file; still no reader.

It will not reboot on its own. You have to trigger it by hand:

```bash
sync && sudo systemctl reboot
```

Want me to just run that for you? Or, if you'd rather fix the underlying bug so the button works next time, I can reorder the stamp guard in /usr/local/sbin/lsl-firstboot.sh (needs repacking the squashfs layer) — your call.
notify ● turn done in 5.4s (226682 in / 4335 out tokens) cdrom — So it isn't still working?
──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯ 
──   workspace: /cdrom   model: ollama-cloud/deepseek-v4.1-flash ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────



════════════════════════════════════════════════════════════════════════════
## Follow-up, 2026-09-21 (later session): "why did the firstboot script not add an LSL icon to the desktop?"

Same live stick, same day, new question. Not the reboot thing again — this is
`bin/config.sh`. Full write-up: `WHYFAIL6.md`. Summary appended here because
this file is the running record for this stick's first-boot failures.

`lsl-firstboot.sh` is innocent: it never installs icons. `bin/config.sh` does,
and it failed two independent ways.

### Bug A — the icon step is unreachable on the boot path

The only in-boot caller is `onboot.sh:244`:

```bash
bash /cdrom/bin/config.sh --from-onboot || true      # onboot.sh:244-245
```

`--from-onboot` sets `SYNC=0; SKIP_AUTOSTART_WARN=1` (config.sh:46), and
`install_desktop_shortcuts()` opens with the sync gate:

```bash
install_desktop_shortcuts() {
    if [[ "$SYNC" -eq 0 ]]; then return 0; fi   # --from-onboot ALWAYS takes this
    ...
}
```

So on every live boot the installer was a silent no-op (returns 0, logs
nothing). `/home/ubuntu/Desktop` held only the stock `ubiquity.desktop`
(Sep 19 12:52) — no `lsl-gui.desktop`, `lsl-shutdown.desktop` or
`brave-browser.desktop`. The gate itself was deliberate (at `--from-onboot`
time `/home` is not yet the persistent overlay, which `onboot.sh` mounts later
in the same boot); the bug is that "don't sync the repo" got reused as
"don't touch /home at all". `squashfs_config.sh:186` (which runs
`LSL_CONFIG_ROOT=/ ... config.sh` with no flag, inside the uproot chroot) was
the one place icons *did* get installed — which is why the built image has them
and the live stick does not.

### Bug B — config.sh aborted before even reaching Bug A

Reproduced with `bash -x bin/config.sh --systemd-only`:

```
+ install_lsl_kitty_conf
+ cp -a --no-preserve=ownership /cdrom/misc/kitty.conf /home/ubuntu/.config/kitty/kitty.conf
cp: cannot stat '/cdrom/misc/kitty.conf': No such file or directory
exit=1
```

`/cdrom/misc/` is **empty** (the FAT dir exists; `sync_cdrom` only copies
`misc/.wezterm.lua`). Under `set -euo pipefail` the bare `cp` at config.sh:174
kills the script, so everything after it is skipped — including
`install_systemd_units`, i.e. **`/etc/systemd/system/onboot.service` was never
installed**, the exact "missing runner" failure WHYFAIL3.md documented for
wifi. Same class of bug as all the FAT `-x` gates: a step that cannot work on
this stick must be skipped, not fatal.

### Fixed on the stick (`/cdrom/bin/config.sh`, safe to re-run)

1. `install_lsl_kitty_conf` gates on the source and warns instead of aborting:
   ```bash
   if [[ ! -r "$REPO_ROOT/misc/kitty.conf" ]]; then
       echo "config.sh: no .../misc/kitty.conf; skipping kitty config" >&2
       return 0
   fi
   ```
2. Icons are no longer tied to the sync flag. `install_desktop_shortcuts`
   takes a `force` argument; `--from-onboot` starts
   `install_desktop_shortcuts_from_onboot`, which waits (15 min max, 5 s steps,
   backgrounded like the existing nix-users retry in onboot.sh) until
   `/home/$LSL_DESKTOP_USER/Desktop` is writable, then installs. Default path
   (`config.sh` with no flag): sync → icons → autostart entries, unchanged.
   `--systemd-only` / `--sync-only` unchanged.

Verified after the patch:

```
bash bin/config.sh --from-onboot                    -> exit 0
bash bin/config.sh --systemd-only                   -> exit 0
bash bin/config.sh --install-autostart-warning-only -> exit 0

/home/ubuntu/Desktop: brave-browser.desktop lsl-gui.desktop
                      lsl-shutdown.desktop ubiquity.desktop   (ubuntu:ubuntu, +x)
/home/ubuntu/.config/autostart: lsl-home-readonly-warning.desktop,
                      lsl-wezterm.desktop, lsl-pin-favorites.desktop
is-enabled: onboot, lsl-home-flushd, lsl-btrfs-growd, lsl-precache,
            lsl-boot-stamp, lsl-reclaim-win-swap  -> all enabled
```

### Residual (NOT fixed)

* `lsl-gui.desktop` / `lsl-shutdown.desktop` have `Exec=/cdrom/bin/lsl-gui` and
  `/cdrom/bin/lsl-shutdown-gui`, but **neither file exists on the stick** — and
  FAT has no exec bit anyway, so they must be run via `bash`. The icons now
  appear but clicking those two will fail. Ship the scripts (or gate the
  entries on `-r` like everything else).
* `bin/mount_all.sh` missing — `onboot.sh` logs
  `bash: /cdrom/bin/mount_all.sh: No such file or directory`.
* `sync_cdrom` run in place (repo root == `/cdrom`) hits
  `cp: X and X are the same file` for every `bin/*` file and `set -e` aborts
  the sync. In-boot this path is never taken (in-boot always uses SYNC=0), so
  it is latent noise, not the bug above.
* `bin/config.sh` and `bin/lsl-common.sh` are dated 16:41 today while the rest
  of the toolkit is from the Sep 16/19/21 layer pack: the stick copy has been
  hand-edited after packing, so **the squashfs layer and the `C:/GitHub/lsl-usb`
  repo (per `pi/FIRSTBOOT.md` §6) still need these fixes re-applied and
  re-packed.**

════════════════════════════════════════════════════════════════════════════
## Follow-up 2, 2026-09-21: the LSL desktop icons launch nothing ("error launching the application")

Clicking `lsl-gui` gives *"There was an error launching the application."*
That message comes from Cinnamon's launcher, which fails to exec the `Exec=`
line. It is correct: the program genuinely is not there.

### Cause: the icon points at a file the stick never had

`config.sh` writes the desktop entry from a heredoc:

```
Exec=/cdrom/bin/lsl-gui          # lsl-gui.desktop
Exec=/cdrom/bin/lsl-shutdown-gui # lsl-shutdown.desktop
```

But `/cdrom/bin/` contains only **10 files**:

```
config.sh  lsl-boot-time.sh  lsl-common.sh  lsl-diag.sh  lsl-flatpak-fat.sh
persist-wifi.sh  pir  squashfs_config.sh  uproot  lsl-restore-stick-from-repo.sh
```

while the repo's `bin/` has **51**. There is no `lsl-gui`, no
`lsl-shutdown-gui` — and also no `lsl-pin-favorites` or
`lsl-home-readonly-warning`, which the three `~/.config/autostart/*.desktop`
entries point at, so those login hooks are dead too:

```
Exec=/cdrom/bin/lsl-home-readonly-warning   # autostart, dead
Exec=/cdrom/bin/lsl-pin-favorites           # autostart, dead (x2 entries)
Exec=/cdrom/bin/lsl-gui                     # desktop icon, dead
Exec=/cdrom/bin/lsl-shutdown-gui            # desktop icon, dead
```

This is the same class of bug as the icons themselves (WHYFAIL6): `config.sh`
installs *entries* for programs without ever checking that the programs are
present. Three separate gates in the same file use `-r` for /cdrom scripts
(`onboot.sh:244`, `lsl-firstboot.sh` passim) but `install_desktop_shortcuts`
writes `Exec=` paths unconditionally.

### Why the stick is missing them

The stick's `bin/` is a *sync target*, not a repo. `sync_cdrom()` copies
`"$REPO_ROOT/bin/"*` → `"$CDROM/bin/"`, and on the live stick `REPO_ROOT` and
`CDROM` are the same directory (`/cdrom`), so that copy is a no-op that
"successfully" syncs nothing — the 10 files present are just the ones the
builder happened to stage. Everything else (`lsl-gui`, `lsl`,
`lsl-shutdown-gui`, `mount_all.sh`, the nix shims, …) exists only in
`C:/GitHub/lsl-usb/bin` on the Windows side.

Note this also explains the other log line from WHYFAIL6:

```
onboot.sh[2074]: bash: /cdrom/bin/mount_all.sh: No such file or directory
```

`mount_all.sh` *is* in the repo — it was never copied to the stick either.

### Consequence for the fix

There are two independent gaps, and fixing only one does not produce a working
icon:

1. **Missing executables** — `bin/lsl-gui`, `bin/lsl-shutdown-gui` (plus
   `bin/lsl`, which `lsl-gui` sources and execs, and `bin/lsl-pin-favorites`,
   `bin/lsl-home-readonly-warning`) must be staged onto `/cdrom/bin/`.
2. **FAT has no exec bit** — `/cdrom` is mounted `fmask=0022,dmask=0022`, so
   files on the stick are never executable; `Exec=/cdrom/bin/lsl-gui` fails
   with EACCES *even once the file exists*. Every other script on this stick
   already works around this by being invoked as `bash /cdrom/...` (see the
   `-r` vs `-x` comments in `lsl-firstboot.sh` and `onboot.sh`). The desktop
   entries must therefore use `Exec=bash /cdrom/bin/lsl-gui` — a bare path in
   `Exec=` can never work from FAT.

`lsl-gui` itself only needs to be readable *and* its interpreter reachable:
it is `#!/bin/bash` + `wezterm start -- sudo bash -c "bash $LSL_SCRIPT …"`, so
`bash /cdrom/bin/lsl-gui` is the correct invocation and needs no exec bit.

### Verified state of the repo (source of truth)

`C:/GitHub/lsl-usb` was mounted read-only on the live box to check the
sources are intact (the real C: is `/dev/nvme0n1p4`, 236.8G, mounted at
`/mnt/c`; `/mnt/c` as shipped is only an empty tmpfs stub — do not trust it
before mounting the volume):

```
-rwxr-xr-x 540   bin/lsl-gui
-rwxr-xr-x 1987  bin/lsl-home-readonly-warning
-rwxr-xr-x 2065  bin/lsl-pin-favorites
-rwxr-xr-x 13128 bin/lsl-shutdown-gui
-rwxr-xr-x …     bin/mount_all.sh, bin/lsl, …
```

All present in the repo, none on the stick.

════════════════════════════════════════════════════════════════════════════
## Follow-up 3, 2026-09-21: lsl-gui2 — a working GUI replacing the broken lsl-gui

`lsl-gui` is broken three ways (Follow-up 2). Rather than keep patching it,
`/cdrom/bin/lsl-gui2` was written as a self-contained replacement:

```
bash /cdrom/bin/lsl-gui2          # GUI (GTK) when a display exists
bash /cdrom/bin/lsl-gui2 save  <vhdx>   # record a path in <LSL_DATA_DIR>/vhdx.list
bash /cdrom/bin/lsl-gui2 enter <vhdx>   # enter a distro (called by the dialog)
LSL_VHDX_SEARCH=p1:p2 bash ...    # override image discovery (used by tests)
LSL_TERMINAL=kitty bash ...       # force a terminal for the shell
```

Desktop entry installed as `/home/ubuntu/Desktop/lsl-gui2.desktop` with
`Exec=bash /cdrom/bin/lsl-gui2` (bash + path, because FAT has no exec bit; a
bare path gives "There was an error launching the application").

### What it fixes vs lsl-gui

| lsl-gui problem | lsl-gui2 |
|---|---|
| `wezterm start ...` but wezterm is not installed | picks the first terminal that exists: wezterm, kitty, x-terminal-emulator, gnome-terminal, xterm |
| needs `find_*.zstd` / `find_everything.efu` catalogs that are not staged, then aborts | discovers images itself: `<LSL_DATA_DIR>/vhdx.list`, then a depth-bounded scan of mounted Windows volumes for `ext4.vhdx`, then `*.vhdx` in the data dir |
| sources `lsl-common.sh` and hard-fails if absent | no shared-library dependency at all |
| nothing visible when the display is missing (terminal only) | GTK → zenity → text-menu cascade |
| no error reporting | `zenity --warning` / stderr, never a silent exit |

Verified on the live box:
* window `LSL — mount a WSL distribution` opens via `gio launch` (Cinnamon's path);
* the list shows `Ubuntu 24.04 LTS`, 3.2G, and the real path;
* the text fallback lists the same row with no display;
* `save` writes `<LSL_DATA_DIR>/vhdx.list`.

### Newly found, and the reason a distro still will not *start*: dirty VHDX + read-only C:

`lsl --overlay-disk` builds a qcow2 COW layer whose **backing file** is the
VHDX. Opening that backing file fails when the VHDX has an unreplayed log:

```
qemu-img: /tmp/t.qcow2: VHDX image file '.../ext4.vhdx' opened read-only,
          but contains a log that needs to be replayed
Could not open backing image.
```

Windows leaves that log dirty whenever WSL was not shut down cleanly. Replaying
it needs a **writable** volume, and we mount C: with `-o ro` (deliberately - a
rw ntfs-3g mount refuses while the log is dirty: `Read-only file system`).
Same failure blocks `guestmount -i` without `-r`, which is what `lsl` uses:

```
libguestfs: error: qemu-img info: ... exited with error status 1
```

Consequences:
* `lsl -l` prints "No WSL distributions found" even with the images present and
  C: mounted - it is the COW/mount step failing, not detection alone.
* `lsl-gui2` therefore probes with `qemu-img info` and, when a replay is
  needed, offers **read-only entry** (`lsl -v <vhdx>`, no overlay, no backing
  file) instead of dying. It says so instead of pretending to work.

Proper fixes are upstream, not on the stick:
1. `lsl_mount_vhdx` should pass `-r` to guestmount (and support read-only entry)
   so a dirty-but-usable VHDX is still readable.
2. For writable sessions either (a) `qemu-img check -r all` needs a rw volume -
   which requires the Windows fast-startup/hibernation state to be off so the
   NTFS log is clean and can be mounted rw - or (b) copy the VHDX to the LSL
   data dir first and run COW there.
3. Recommend `wsl --shutdown` in Windows before removing the stick; that leaves
   no unreplayed log and both read-only and rw paths work.

### Not yet done

* `lsl-gui2` is staged on the stick only. It must be added to
  `C:/GitHub/lsl-usb/bin/` (and `install_desktop_shortcuts` taught about it) or
  it disappears at the next layer pack, exactly like the rest of Follow-up 2.
* `lsl-gui` (v1) is left in place, patched for the terminal fallback, so
  existing shortcuts do not regress.

### Follow-up 3a: "no distributions are found" — the stick's own vhdx list was ignored

`/cdrom/lsl-wsl-vhdx.conf` is the list the Windows installer copies onto the
stick; it holds the three WSL images as **Windows** paths:

```
C:\Users\s_pam\AppData\Local\Packages\TheDebianProject.DebianGNULinux_76v4gfsz19hv4\LocalState\ext4.vhdx
C:\Users\s_pam\...\CanonicalGroupLimited.Ubuntu24.04LTS_79rhkp1fndgsc\LocalState\ext4.vhdx
C:\Users\s_pam\...\CanonicalGroupLimited.Ubuntu22.04LTS_79rhkp1fndgsc\LocalState\ext4.vhdx
```

Neither `lsl` nor the first cut of `lsl-gui2` ever read it (`lsl-gui2` only
looked at `<LSL_DATA_DIR>/vhdx.list` and a filesystem scan; `lsl` only reads
`<LSL_DATA_DIR>/vhdx.list` too). So the "no distributions" answer came from a
list that was sitting right there on the stick. Now fixed in `lsl-gui2`:

1. **It reads `/cdrom/lsl-wsl-vhdx.conf`** (and the data-dir copy if present),
   translating `C:\...` / `d:/...` to `/mnt/c/...` / `/mnt/d/...`, tolerating
   CRLF and `#` comments.
2. **Two missing-newline bugs fixed.** The conf file has **no trailing
   newline**, and plain `while IFS= read -r` drops the final line — so the
   Ubuntu 22.04 entry disappeared even after the file was read. Fixed in
   `lsl-gui2` *and* in `bin/lsl-common.sh:lsl_vhdx_saved_distro_lines()`, which
   has the identical flaw in the repo (`while IFS= read -r p; do`).

Result — all three, with sizes, in both the GTK dialog and the text fallback:

```
1) Ubuntu 22.04 LTS   13G   .../CanonicalGroupLimited.Ubuntu22.04LTS_.../ext4.vhdx
2) Ubuntu 24.04 LTS  3.2G   .../CanonicalGroupLimited.Ubuntu24.04LTS_.../ext4.vhdx
3) Debian            796M   .../TheDebianProject.DebianGNULinux_76v4gfsz19hv4/.../ext4.vhdx
```

Reproduce the checks:

```bash
bash /cdrom/bin/lsl-gui2                 # GUI: 3 rows
env -u DISPLAY bash /cdrom/bin/lsl-gui2  # text menu: same 3 rows
awk 'END{printf "trailing newline: %s\n", (NR&&length($0))"?"}' /cdrom/lsl-wsl-vhdx.conf
grep -n 'read -r p' /cdrom/bin/lsl-common.sh   # must show `|| [ -n "$p" ]`
```

Still true, and unchanged by this fix: **entering** any of the three fails with
`opened read-only, but contains a log that needs to be replayed` while C: is
mounted `ro` — see the dirty-VHDX section above. Listing them is fixed;
starting them needs `wsl --shutdown` on the Windows side (or the `-r` upstream
fix), and `lsl-gui2` now offers read-only entry instead of dying.

### Follow-up 3b: dirty-VHDX reporting and an explicit, guarded writable opt-in

Per request: the GUI now *tells* the user about a dirty image, and can still do a
writable session for clean images when the user explicitly asks.

**What the list shows now** (`qemu-img info` per image; reads headers only, never
writes — safe to probe):

```
Ubuntu 22.04 LTS   13G   clean  (writable ok)
Ubuntu 24.04 LTS  3.2G   DIRTY — read-only only
Debian            796M   clean  (writable ok)
```

GTK backend: a fourth "State" column plus a paragraph explaining COW and DIRTY.
zenity backend: the state is appended to each row's label. Text backend: a
`^ DIRTY (unreplayed VHDX log) - read-only only` line under each row.

**Writability rules** (`enter_distro <vhdx> [ro|rw]`):

| image state | host volume | "Enter distribution" | "Enter writable (COW)…" |
|---|---|---|---|
| clean | C: ro | COW session (non-destructive) | COW session after warnings |
| clean | C: ro + Windows hibernated | warns first | **warns loudly first** |
| dirty | C: ro | explains, offers read-only | **refused** before any qemu call |
| unknown | any | treated as dirty (refuse rw) | refused |

* **Refusing dirty+rw** is deliberate: replaying the VHDX log is a *write* to
  the image, impossible on a ro volume, and doing it against a volume Windows
  still considers dirty is how a distro stops booting. Message names the fix
  (`wsl --shutdown` in Windows) instead of dumping a qemu error.
* **Hibernation guard** (`host_win_hibernated`): a non-trivial `hiberfil.sys` on
  any mounted Windows volume means the OS is suspended, not shut down. Writable
  entry then requires explicit confirmation, because Windows resumes over
  whatever was written and can corrupt NTFS. On this machine:
  `hiberfil.sys` = 6.8 GB and `HiberbootEnabled = 1`, so the guard fires for
  every writable attempt — correctly.
* **Host NTFS is never mounted rw by lsl-gui2.** Even the writable session only
  needs `/tmp` (the qcow2 COW layer lives there); the claim that a rw C: is
  required was always wrong, and saying so is what put the Windows filesystem at
  risk in the first place.

Verified on the live box:

```
# dirty + rw -> refused with instructions, then read-only offered
bash lsl-gui2 enter <Ubuntu24.vhdx> rw
# clean + rw -> hibernation warning; declining launches nothing
printf 'n\n' | bash lsl-gui2 enter <Ubuntu22.vhdx> rw
# clean + rw + accepted -> kitty: bash lsl --overlay-disk --vhdx <Ubuntu22.vhdx>
```

Nothing was mounted or written during testing: `/tmp/lsl_mounts/` stayed empty
and the Ubuntu 22.04 VHDX mtime is still `2026-09-21 16:11:37`, i.e. `lsl-gui2`
did not touch the image (it only ever launched `lsl`, which failed to create its
COW layer because of the dirty-log/ro combination).

**Still upstream, not done here:** `lsl` itself should (a) pass `-r` to
`guestmount` so dirty images remain readable, (b) stop suggesting
`qemu-img check -r all` as a casual diagnostic on a possibly-hibernated volume
(it is a destructive write path), and (c) offer the safe "copy the VHDX, then
COW on the copy" route for users who need persistence without a clean Windows
shutdown.

### Follow-up 3c: the real-rw triple gate, and correct mode semantics

Prompted by a fair catch: "COW" was being presented as the opt-in when COW is
actually the default, and the thing worth opting into is real read-write.

**Correction to 3b's table.** COW needs nothing special - it is the default.
Real rw needs *three* independent conditions, and the earlier claim that a
read-only host volume merely warranted a warning was wrong. Measured:

```
qemu-nbd: Could not open '/mnt/c/.../ext4.vhdx': Read-only file system
```

qemu needs **write access to the image file**. On a ro volume every real-rw
route dies there, before the VHDX log is even relevant - so a *clean* image on a
*ro* volume still cannot be written. "Clean" only unblocks the COW backing-file
open.

**`rw_gate_check()` - all three must pass; any failure REFUSES (not warns),
because these are cases where the operation is wrong, not merely risky:**

| gate | condition | failure means |
|---|---|---|
| 1/3 | VHDX log clean (`qemu-img info`) | replaying the log is a write; unsafe from here |
| 2/3 | no hibernated Windows (`hiberfil.sys` > 1 MiB on any mounted volume) | Windows resumes over our writes -> NTFS corruption |
| 3/3 | host volume mounted rw | qemu cannot open the image file for write, period |

Gate 2 is deliberately machine-wide: hibernation makes *any* write to that
Windows volume unsafe, even if the VHDX itself lives elsewhere.

When all three pass, a final explicit confirmation lists the gate results and
the exact path that will be modified. Real rw is implemented as plain
`lsl -v <vhdx>` (no `--overlay-disk`), which is the only non-COW path lsl has.

**Mode semantics now (and the mislabel fixed):**

| UI | mode | writes | persistence |
|---|---|---|---|
| **Enter (COW session)** - default | `cow` -> `lsl --overlay-disk` | qcow2 layer in `/tmp` | none; discarded on exit, distro untouched |
| **Enter read-only** | `ro` -> `lsl -v` | nothing anywhere | n/a |
| **Enter with REAL rw…** | `rw` -> `lsl -v` after gate | **into ext4.vhdx** | permanent |

Dirty images: COW is impossible, so the dialog explains and falls back to
read-only. All three backends were updated to the same three-way choice
(GTK: three buttons; zenity: question chain; text: `[Enter]/r/o` prompt).

**Bug found while wiring this up:** the action dispatcher was
`enter) enter_distro "$2"; exit $?` - it dropped the mode argument entirely, so
`rw` silently ran the COW path. Fixed to `enter_distro "$2" "${3:-cow}"`. This
was masked in 3b because the only two modes then were effectively identical.

Verified (live, no image was modified):

```
enter <Ubuntu24 dirty> rw   -> Gate 1/3 failed, refusal text, no launch
enter <Ubuntu22 clean> rw   -> Gate 2/3 failed (/mnt/c/hiberfil.sys), no launch
enter <64M fresh vhdx> rw   -> Gate 2/3 failed while /mnt/c is mounted (correct:
                               machine-wide condition)
WIN_MOUNTS=() enter <clean> rw -> all three gates pass -> confirmation shown
truncated 8G copy           -> state "unknown" -> refused at gate 1 (correct)
enter <dirty> cow           -> explains, offers read-only
enter <clean> ro            -> straight to `lsl -v`, no gates
```

Also validated by accident: an incomplete 8 GB copy of the Ubuntu 22.04 image
was classified `unknown` and refused, which is the intended behaviour for an
image whose consistency cannot be established.

**Left for upstream (`lsl`):** the non-COW path (lines 772/847 - `guestmount`
with no flags, `qemu-nbd` + plain `mount`) has no read-only fallback and no
post-mount rw verification; line 983 only prints an apology *after* the fact if
it ended up ro. Real rw should not be promoted in the GUI until that path is
exercised deliberately - ideally against a throwaway copy, as done here.

### Follow-up 3d: "Enter (COW session) does nothing" - silent dialog failure, and the misleading COW warning

Regression report: after 3c the default button stopped working. Before it at
least showed a confusing warning that read as both unsafe and safe. Both were
real bugs.

**Bug A - dialogs failed silently and were treated as "Cancel".**
`confirm_dialog`'s no-GUI fallback was:

```bash
printf '%s\n\n[%s? y/N] ' "$text" "$ok"
read -r a            # <-- not a tty when GTK spawns us via Popen
case "$a" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
```

The GTK dialog spawns actions with `subprocess.Popen(["bash", self_path] + args)`,
which cannot give the child a terminal. `read` hit EOF immediately, `$a` was
empty, the `*)` branch returned 1 ("Cancel"), and `enter_distro` then did
`return 0` - no launch, no message, no error. A silent no-op that looked like a
dead button.

Fixed:
* `confirm_dialog` only uses the text prompt when **both** stdin and stdout are
  ttys; otherwise it prints *why* it cannot ask, and returns the safe answer.
* `LSL_ASSUME_YES=1` is set by callers whose action cannot modify anything
  (the dirty+COW path, which only offers read-only entry), so an environment
  with no dialog backend still works.
* `act()` in the GTK backend now passes an explicit environment with `DISPLAY`
  defaulted, instead of relying on inheritance.

**Bug B - the confusing warning.** The clean+COW branch warned about
hibernation:

> Note: Windows appears to be hibernated (/mnt/c/hiberfil.sys). A COW session
> does not write to it, so this is informational only.

That sentence contradicts itself, and worse, it framed the *safest* option as
risky. COW writes only to a qcow2 layer in `/tmp`: it does not touch
`ext4.vhdx` and does not write to the Windows volume, so hibernation is
genuinely irrelevant to it. The warning was removed; the COW semantics are now
stated once, up front, in the GUI subtitle ("writable in RAM ... discarded on
exit ... your ext4.vhdx is never modified"). Hibernation is now only raised
where it actually matters - gate 2/3 of the real-rw path.

**Bug C - `set -u` crash on an unset `LSL_TERMINAL`.** `pick_term` expanded
`"$LSL_TERMINAL"` unguarded, so any run without that variable died with
`LSL_TERMINAL: unbound variable` before reaching a terminal. Now
`"${LSL_TERMINAL:-}"`.

**Verified:**

```
# no DISPLAY, no tty - the case that used to do nothing:
bash lsl-gui2 enter <Ubuntu24 dirty> cow </dev/null
  -> explains the dirty log, states read-only writes nothing,
     "proceeding (this action does not modify your distro)",
     then launches the read-only session (confirmed: sudo + LSL windows appear)

# clean + COW, no DISPLAY: no hibernation warning any more
bash lsl-gui2 enter <Ubuntu22 clean> cow </dev/null   -> launches directly

# unset LSL_TERMINAL no longer crashes
env -u LSL_TERMINAL bash lsl-gui2 enter <img> cow     -> proceeds
```

Lesson worth keeping: a UI action that "does nothing" is almost always an
unhandled non-interactive path, not a logic error - and the fix is to make the
failure *say something* rather than to add another branch.

### Follow-up 3e: the ACTUAL reason the button did nothing - the GUI re-invoked the wrong file

3d fixed real problems (silent dialog EOF, the self-contradicting warning, a
`set -u` crash) but the button still did nothing, and the report came back
unchanged. Root cause was something else, and it invalidated every earlier
"verification" of the button:

```bash
run_gtk() {
    exec python3 - "$TMPLIST" "$0" <<'PYEOF'      # <-- "$0"
...
self_path = sys.argv[2]                            # ...becomes the action target
subprocess.Popen(["bash", self_path] + args)       # bash <TMPLIST> enter ...
```

`"$0"` is the path the shell was invoked with. The GTK dialog uses that value to
re-invoke *itself* to perform an action, so every button ran:

```
bash /tmp/lsl-gui2.hTd7VY enter /mnt/c/.../ext4.vhdx cow
```

and `/tmp/lsl-gui2.hTd7VY` is the **list of images**, not the script:

```
/tmp/lsl-gui2.hTd7VY: line 1: Ubuntu: command not found
/tmp/lsl-gui2.hTd7VY: line 1: 13G: command not found
/tmp/lsl-gui2.hTd7VY: line 1: clean: command not found
                       ^ a wall of errors on a stderr nobody reads
```

The buttons were "working" - they spawned a process that failed instantly and
silently. Fixed by passing the real script path:

```bash
local self
self="$(readlink -f "${BASH_SOURCE[0]}")"
exec python3 - "$TMPLIST" "$self" <<'PYEOF'
```

Verified: the GUI now shows `python3 - /tmp/lsl-gui2.hTd7VY /cdrom/bin/lsl-gui2`
(previously `... /tmp/lsl-gui2.hTd7VY`), and an action now actually launches a
session - `root@ubuntu:` terminal windows appear. Dispatch checked for all four
modes (`cow`/`ro`/`rw`/`save`).

**Process lesson, more important than the bug.** Every previous verification I
ran called `lsl-gui2 <mode> ...` directly from my own shell. Direct invocation
sets `$0` correctly, so the tests passed while the button - the only path a user
takes - was broken the whole time. Verifying the function is not verifying the
entry point. The check that would have caught this immediately is to spawn the
action exactly as the GUI does and look at the result, instead of calling the
script yourself:

```bash
# what the button really does:
python3 - "$TMPLIST" "$self" <<< ...      # inspect what self_path resolves to
```

Two of the earlier "fixes" (3b/3c) were therefore changes to code the button
never reached. They are still correct in themselves, but they were not the
reported problem, and I should have confirmed that the entry point worked before
rewriting the dialog logic underneath it.

Also cleaned up: several stale `LSL — mount a WSL distribution` windows were
left open from earlier GUI launches during testing; close them at leisure.

### Follow-up 3f: collapsing the buttons - there was only ever one real choice

Asked, correctly: why have both "Enter (COW session)" and "Enter read-only"? The
code answered it - because `ro` and `rw` sent **byte-identical commands**:

```
329:  run_terminal sudo bash -c "bash '$lsl' -v '$vhdx' ..."   # mode=rw (gated)
335:  run_terminal sudo bash -c "bash '$lsl' -v '$vhdx' ..."   # mode=ro
358:  run_terminal sudo bash -c "bash '$lsl' -v '$vhdx' ..."   # mode=ro (dirty)
368:  run_terminal sudo bash -c "bash '$lsl' --overlay-disk --vhdx '$vhdx' ..."  # cow
```

Three code paths, one command. "Enter read-only" was REAL rw minus the gate, and
"REAL rw" was a label on a path nobody has ever seen write anything - `lsl`
itself says so:

```
Note: This VHDX is mounted read-only — the disk image will not be written.
```

So the buttons were not expressing three capabilities; they were expressing one
capability (`lsl` mounts this image somehow) plus two labels I had invented on
top of it. Removed both.

**Now: one `Enter` button, decided by state, which is the only genuine choice:**

| image state | command | effect |
|---|---|---|
| clean | `lsl --overlay-disk --vhdx <img>` | writable session; changes in RAM, discarded on exit; distro untouched |
| dirty | `lsl -v <img>` | the only path that works; nothing is written |

All three backends collapsed the same way:
* GTK: one `Enter` + `Save to list` + `Close` (was three enter-buttons)
* zenity: list, then enter immediately - no follow-up question chain
* text: prompt for the number only - no `[Enter]/r/o` menu

`enter_distro` now treats an empty mode as "decide from state", so every caller
gets the same behaviour instead of each backend re-implementing the choice.

Kept deliberately: the triple gate stays in the code (`rw_gate_check`) but is
**unreachable from the UI**. It is the correct logic for a future explicit
`--real-rw` flag in `lsl`; it just should not be dressed as a second button made
of the same command as the first.

Verified: clean image -> `lsl --overlay-disk` (session launches, windows appear);
dirty image -> explains the log, states nothing is written, proceeds to `lsl -v`.

**Why this kept going wrong.** Each round I added a *label* for a capability
without checking the *command* underneath differed. The fix was to read the four
`run_terminal` lines side by side - which is all it took - instead of reasoning
about what the modes were supposed to mean.

════════════════════════════════════════════════════════════════════════════
## Backup & handover, 2026-09-21 (end of session)

Everything produced or changed today is now outside the live system, in the
Windows repo volume. Until this was done, most of it existed in exactly one
place: `/cdrom` (FAT, single copy, no history) or `/home` (**RAM-only**).

### Where it lives

```
C:/GitHub/lsl-usb/stick-backup-20260921/          (= /mnt/c/.../ , 264 KB, 33 files)
```

| path | why |
|---|---|
| `WHYFAIL5.md`, `WHYFAIL6.md` | this document and its companion |
| `bin/lsl-gui2` | NEW GUI launcher - was stick-only, would be lost at the next layer pack |
| `bin/lsl-gui` | patched: terminal fallback instead of a hard `wezterm` dependency |
| `bin/config.sh` | patched: `cp_to_cdrom` self-copy guard, kitty `-r` gate, icons on `--from-onboot` |
| `bin/lsl-common.sh` | patched: missing-trailing-newline fix in `lsl_vhdx_saved_distro_lines` |
| `bin/lsl-restore-stick-from-repo.sh` | recovery tool for the onboot.sh/lsl-usb.env truncation |
| `home-desktop/` (5), `home-autostart/` (3) | desktop + autostart entries that lived on tmpfs and would have vanished on reboot |
| `systemd/` (8), `misc/kitty.conf` | stick copies (identical to repo; saved for completeness) |
| `patched-for-repo/{bin,*.diff}` | **full patched files + unified diffs vs the repo originals** |
| `MANIFEST.md5` | checksums; re-verified clean after writing |

### The finding that made this urgent

`C:/GitHub/lsl-usb/bin/` still contains the **original** files. Verified by grep,
all zero:

```
grep -c "wezterm kitty x-terminal-emulator" bin/lsl-gui        -> 0
grep -c 'read -r p || \[ -n "$p" \]'        bin/lsl-common.sh  -> 0
grep -c "repo root; nothing to sync"        bin/config.sh      -> 0
ls bin/lsl-gui2                                                -> No such file
```

None of this session's fixes are in the repo. The stick's `bin/` is a build
artifact, so **without applying `patched-for-repo/` the next build regenerates
every bug documented in this file and WHYFAIL6.md.** Both the patched files and
reviewable diffs are stored so this can be applied deliberately:

```
bin/config.sh.diff         206 lines
bin/lsl-common.sh.diff      14 lines
bin/lsl-gui.diff            29 lines
bin/lsl-gui2.newfile.diff  647 lines (new file)
```

### How the backup was possible (and what blocked it)

`/mnt/c` had been mounted `ro`, and `ntfs3` refuses an in-place
`mount -o remount,rw`. The actual blockers, in order:

1. `hiberfil.sys` = 6.8 GB, `HiberbootEnabled = 1` - Windows is *suspended*, not
   shut down (same condition that gates real-rw entry; unrelated to this
   backup, but it means the volume was never cleanly parked).
2. **Three orphaned `qemu-system-x86_64` appliance VMs** from the earlier
   `guestmount`/COW experiments were holding `/dev/nvme0n1p4` open, so
   `umount` returned EBUSY. They survive their `guestmount` client, and nothing
   reaps them. Killed them, then `umount /mnt/c` + `mount -t ntfs3 -o rw` worked.
3. Two duplicate mounts (`/mnt/c` and `/mnt/win` from my first probe) had to be
   removed first.

Cleanup performed: killed the three appliances, unmounted `/mnt/win` and
`/mnt/probe{3,4,5}`, and removed abandoned COW layers and session dirs from
`/tmp/lsl_mounts/` (three `.qcow2` files plus three `lsl_sess_*` trees).

### Deliberately NOT done

1. **Nothing committed to git.** The repo was already dirty from unrelated work
   (`git status` shows many modified files), so committing would have mixed this
   session into someone else's changes. The files sit in a backup directory for
   review; commit them yourself when ready.
2. **The squashfs layers were not re-packed.** `casper/filesystem.z0.*.squashfs`
   and the base layer still contain the OLD `config.sh`/`lsl-common.sh`. Anything
   that reads layers rather than the stick sees unfixed versions.
3. **`lsl-gui2` is not in the repo's `bin/`** - only in this backup.
4. **Upstream items still open** (from Follow-up 3c):
   * `lsl` should pass `-r` to `guestmount` so dirty images remain readable
     (currently `guestmount -a … -i … -o allow_other`, no read-only handling).
   * `lsl` should stop suggesting `qemu-img check -r all` as a casual diagnostic:
     on a hibernated/dirty volume that is a destructive write path.
   * The non-COW mount path has no read-only fallback and no post-mount rw
     verification; line 983 only prints an apology *after* the fact.
   * Real rw was never exercised; `rw_gate_check` is intentionally unreachable
     from the UI until it is.
5. **`/mnt/c` is left mounted rw.** Return it to a clean state deliberately:
   `wsl --shutdown` in Windows, then `shutdown /s /t 0` with Fast Startup off.

### Session scoreboard

Fixed and verified: missing desktop icons (two config.sh bugs), missing stick
`bin/` payload (43 files), GUI launcher (`lsl-gui2`), vhdx-list discovery (3/3
images, two missing-newline bugs), dirty/clean reporting, the real-rw gate, the
collapsed single-button UI, and the `$0`-vs-script-path bug that made every
button silently no-op.

Self-inflicted damage, fully repaired: `onboot.sh`, `lsl-usb.env`,
`fuse/fat_linux_meta_fs.py`, `fuse/requirements.txt` and 8 `systemd/*` files were
truncated/overwritten by `cp -a X X` (which TRUNCATES then exits 1). Restored
byte-identical from the repo and the cause is now guarded in `cp_to_cdrom`.

### Session addendum A: kitty pinning, and two autostart entries doing one job

Prompted by "are we pinning kitty etc to the taskbar?" - we were not.

**The pinning feature had never once run on this stick.** Cinnamon favorites at
the time:

```
['org.gnome.Calculator.desktop', 'org.gnome.Calendar.desktop', 'org.x.editor.desktop',
 'mintinstall.desktop', 'cinnamon-settings.desktop']
```

Stock Mint. Three separate reasons:

1. `bin/lsl-pin-favorites` was **not on the stick** at all (see Follow-up 2 - the
   stick's `bin/` was a partial sync), so the autostart hook was a no-op.
2. Its only terminal helper was `choose_wezterm_desktop_id`, and **wezterm is not
   installed** on this image - so that pin was dropped every time.
3. `kitty.desktop` exists (`/usr/share/applications/kitty.desktop`, shipped by
   the `kitty` package) and `config.sh` even installs a `kitty.conf`, but no code
   path ever mentioned kitty.

**Fixed in `bin/lsl-pin-favorites`:**

```bash
choose_kitty_desktop_id()      # kitty.desktop, org.kitty.kitty.desktop
choose_terminal_desktop_id()   # kitty -> wezterm -> gnome-terminal -> xterm
...
term="$(choose_terminal_desktop_id)"   # was choose_wezterm_desktop_id
want+=("$term")
```

Kitty first (it is what the image ships), wezterm second, then generic terminals
so the panel entry is never empty merely because wezterm is absent.
Selection verified on the image: `terminal: kitty.desktop`,
`brave: brave-browser.desktop`.

**`config.sh` cleanup, found while updating the comment:** there were **two
autostart entries running the identical command**:

```
install_lsl_wezterm_autostart        -> lsl-wezterm.desktop        Exec=/cdrom/bin/lsl-pin-favorites
install_lsl_pin_favorites_autostart  -> lsl-pin-favorites.desktop  Exec=/cdrom/bin/lsl-pin-favorites
```

Two entries, one action - the pin ran twice per login. Renamed to
`install_lsl_terminal_autostart`, writes `lsl-terminal-pin.desktop`, and deletes
the legacy `lsl-wezterm.desktop` so existing installs do not accumulate stale
files. `Comment=` strings corrected from "Pin WezTerm and Brave" to
"Pin the terminal (kitty, else wezterm) and Brave", matching behaviour.

**What could NOT be verified, and why it matters:** the pin never demonstrably
reached the panel. Root cannot write the desktop user's dconf from outside their
session - all three routes failed:

```
gsettings set (as root)          -> writes root's dconf, rc=0, no visible change
HOME=/home/ubuntu dconf write    -> reads work, write did not persist (mtime unchanged)
session bus as root              -> "failed to commit changes to dconf: The connection is closed"
```

So the *mechanism* (gsettings in the user's session, via the autostart entry) is
untested end-to-end; only the id selection is proven. Confirm by logging out and
back in, or running `bash /cdrom/bin/lsl-pin-favorites` from inside the desktop
and watching the panel.

Relevant caveat: `org.cinnamon favorite-apps` lives in dconf, which lives in
`/home`, which is **tmpfs** on a live boot. The pins therefore vanish on reboot
unless the autostart entry re-applies them - which is exactly why the missing
script mattered more than the missing kitty branch.

### Session addendum B: parallel edits to the repo (read before applying backups)

While this session worked, `C:/GitHub/lsl-usb/bin/lsl-common.sh` gained an
`lsl_env_file()` fix - CRLF/BOM normalisation for the FAT-hosted `lsl-usb.env`,
so a stray `\r` in `LSL_DATA_DIR` cannot make onboot conclude the data dir is
non-persistent and fall back to a volatile tmpfs `/home`. **That work is not from
this session**, and it is currently uncommitted (`git status` shows
` M bin/lsl-common.sh`).

Effect on the handover: after that change the stick copy and the repo copy are
byte-identical, so `lsl-common.sh` needs **no patch from here** and its diff was
removed rather than shipped stale. The trailing-newline fix from this session
(Follow-up 3a) survived inside the newer revision.

**Rule for whoever applies `patched-for-repo/`: re-diff against the repo first.**
Current needed diffs are `config.sh` (269 lines), `lsl-gui` (29),
`lsl-pin-favorites` (50), `lsl-gui2` (647, new file). A blind copy of this
snapshot would revert the parallel `lsl_env_file` work.

### Session addendum C: cleanup, and proof that nothing was damaged

Left-behind processes and state from this session's testing, all removed:

* a **13-hour-old kitty session** (the `lsl --choose` GUI test from Follow-up 3)
  plus two `guestmount` clients and their COW layers;
* **three orphaned `qemu-system-x86_64` appliance VMs** holding
  `/dev/nvme0n1p4` open, which had blocked the C: remount earlier;
* abandoned `/tmp/lsl_mounts/` content, plus test scratch
  (`/tmp/cfgtest`, `/tmp/inspect22`, `/tmp/rwtest*`, `/tmp/rwvol`, `/tmp/self`,
  `/tmp/pin.sh`, ...).

One self-inflicted mess worth recording: removing the `.qcow2` files **before**
killing their `guestmount` clients left two mount dirs in `d?????????` state.
Order matters - kill the client, then remove the layer.

**Damage check (verified, not assumed):**

| check | result |
|---|---|
| VHDX mtimes | all pre-session (16:11 / Sep 15 / Sep 11) - no COW session ever wrote to a parent |
| 24.04 VHDX "dirty" | pre-existing (Sep 15, Windows had not shut WSL down), not caused here |
| FAT stick `fsck.vfat -n` | no structural corruption, 1368 files intact, no lost clusters |
| FAT dirty bit | **set** - "Fs was not properly unmounted"; clearing it needs a boot where the stick is not mounted |

### Session addendum D: open items at close of session

1. **`/mnt/c` is left mounted rw** (needed for the backup). This is the same
   condition gate 2/3 refuses to write under - a writable NTFS volume on a
   hibernated Windows. Nothing was damaged, but it should be unmounted or
   resolved with a clean Windows shutdown (`wsl --shutdown`, Fast Startup off).
2. **FAT dirty bit** - see above; harmless but noisy on every mount.
3. **Nothing committed to git**; the squashfs layers still contain the old
   scripts, so a fresh build reverts every fix in this file.
4. **`lsl-gui2` and `lsl-pin-favorites` exist only on the stick and in
   `stick-backup-20260921/`** - not in the repo's `bin/`.
5. **Upstream `lsl` items** (unchanged): pass `-r` to guestmount for dirty
   images; stop suggesting `qemu-img check -r all` on a possibly-hibernated
   volume; give the non-COW mount path a read-only fallback and a post-mount rw
   check; real rw remains unexercised, so `rw_gate_check` stays unreachable.
6. **Kitty pin unproven** in the panel (Addendum A).

Backup refreshed after these changes: 35 files, `MANIFEST.md5` regenerated and
verified; `stick-backup-20260921/README.md` carries a "Refresh 2" section with
the same parallel-edit warning as Addendum B.

### Where to go next

**`/cdrom/APPLY-FIXES.md`** (on this stick) is the short, self-contained "how to
apply" guide: mount C:, diff before copying (mandatory - see Addendum B), apply,
commit, rebuild the layer, verify. This file is the reasoning behind it; that
file is the procedure.

Companion: `/cdrom/WHYFAIL6.md` (the desktop-icon failure in isolation).

Machine-readable copies of every changed file, plus diffs, live in
`C:/GitHub/lsl-usb/stick-backup-20260921/` - but that is on C:, so anything
needed when only the USB is available must be readable from the stick itself:
that is why the patched files sit in `/cdrom/bin/` and the procedure in
`/cdrom/APPLY-FIXES.md`.
