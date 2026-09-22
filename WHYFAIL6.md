# WHYFAIL6 — Why did the firstboot script not add an LSL icon to the desktop?

Asked 2026-09-21. Short answer: **the icons are installed by `bin/config.sh`,
and on this stick `config.sh` never reached the icon step — in fact the icon
step was unreachable by design on the boot path.** Two independent bugs, both
in `/cdrom/bin/config.sh`.

## 1. The only caller that runs in a boot is `--from-onboot`, and it skips the icons

`onboot.sh:244` (run by `onboot.service` on every boot, and before firstboot's
own network wait) is the only in-boot caller:

```bash
bash /cdrom/bin/config.sh --from-onboot || true        # onboot.sh:244-245
```

`--from-onboot` sets `SYNC=0; SKIP_AUTOSTART_WARN=1` (config.sh:46). The icon
function is gated on the *sync* flag, not on the reason it was written:

```bash
install_desktop_shortcuts() {
    if [[ "$SYNC" -eq 0 ]]; then return 0; fi   # <- --from-onboot always takes this
    ...
}
```

and the main body guarded it with the same flag:

```bash
sync_cdrom
install_desktop_shortcuts          # old: called unconditionally, but self-gated
if [[ "$SKIP_AUTOSTART_WARN" -eq 0 ]]; then
    install_lsl_autostart_warning ...
fi
```

So on every live boot the shortcut installer was a no-op. `/home/ubuntu/Desktop`
contained only the stock `ubiquity.desktop` (timestamp Sep 19 12:52); no
`lsl-gui.desktop`, no `lsl-shutdown.desktop`, no `brave-browser.desktop`.
Nothing was logged — the function returns 0 — which is why this looked like a
silent "firstboot forgot the icons".

The `SYNC=0` gate is not silly: `--from-onboot` runs very early, and `/home` is
only made persistent later in the same boot (`onboot.sh` mounts/flushes the
persistent `/home` after calling config.sh). The bug is that "don't sync the
repo" was reused as "don't touch /home at all".

Side note: `install_desktop_shortcuts` also ran *before* the `SYNC`-gated
autostart block in the non-`--from-onboot` path, i.e. the author's intent was
for icons to be part of the sync; the two callers simply never overlapped on
the live stick. `squashfs_config.sh:186` (`LSL_CONFIG_ROOT=/ ... config.sh`,
no flag) was the one place icons *were* installed — inside the uproot chroot
after the package install, which is why the repo-built image has them and the
live stick does not.

## 2. Even if it had run, `config.sh` died before that — missing `misc/kitty.conf`

Reproduced with `bash -x bin/config.sh --systemd-only`:

```
+ install_lsl_kitty_conf
+ cp -a --no-preserve=ownership /cdrom/misc/kitty.conf /home/ubuntu/.config/kitty/kitty.conf
cp: cannot stat '/cdrom/misc/kitty.conf': No such file or directory
exit=1
```

`/cdrom/misc/` is **empty** on this stick (the FAT `misc/` dir exists, the file
was never synced: `sync_cdrom` only copies `misc/.wezterm.lua`, and
`misc/kitty.conf` is expected to arrive from the repo side). Under `set -euo
pipefail` that bare `cp` kills the script (`config.sh:174`), so everything after
`install_lsl_kitty_conf` is skipped:

* `install_systemd_units` — **`/etc/systemd/system/onboot.service` was not
  installed at all**, which is exactly the missing-runner bug WHYFAIL3.md
  documented for wifi ("the *runner* was missing"). It was installed at
  16:41 today by hand / by a later run, which is why it is loaded now.
* any icon install in the non-onboot path.

Same class of bug as the FAT `-x` gates: a command that cannot work on this
stick is fatal instead of skipped.

## 3. What was fixed on the stick (`/cdrom/bin/config.sh`, safe to re-run)

1. `install_lsl_kitty_conf` now gates on the source:
   ```bash
   if [[ ! -r "$REPO_ROOT/misc/kitty.conf" ]]; then
       echo "config.sh: no .../misc/kitty.conf; skipping kitty config" >&2
       return 0
   fi
   ```
   so a missing misc/ file warns instead of aborting the whole script.
2. Icons are no longer tied to the sync flag. `install_desktop_shortcuts` takes
   an explicit `force` argument, and `--from-onboot` now starts
   `install_desktop_shortcuts_from_onboot`, which waits (up to 15 min, 5 s
   steps, backgrounded like the existing nix-users retry in onboot.sh) until
   `/home/$LSL_DESKTOP_USER/Desktop` is writable, then calls
   `install_desktop_shortcuts 1`. The default path (`config.sh`,
   no flag) is unchanged: sync, then icons, then autostart entries.
   `--systemd-only` / `--sync-only` keep their old behavior.

Verified after the patch:

```
bash bin/config.sh --from-onboot                    -> exit 0
bash bin/config.sh --systemd-only                   -> exit 0
bash bin/config.sh --install-autostart-warning-only -> exit 0

/home/ubuntu/Desktop:
  brave-browser.desktop  lsl-gui.desktop  lsl-shutdown.desktop  ubiquity.desktop
  (all ubuntu:ubuntu, +x)
/home/ubuntu/.config/autostart: lsl-home-readonly-warning.desktop,
  lsl-wezterm.desktop, lsl-pin-favorites.desktop
systemctl is-enabled onboot/lsl-home-flushd/lsl-btrfs-growd/lsl-precache/
  lsl-boot-stamp/lsl-reclaim-win-swap -> all enabled
```

## 4. Residual issues found on the way (NOT fixed here)

* **`lsl-gui.desktop` / `lsl-shutdown.desktop` point at executables that are not
  on the stick.** `Exec=/cdrom/bin/lsl-gui` and `/cdrom/bin/lsl-shutdown-gui`,
  but `/cdrom/bin/` has no such files (only `config.sh`, `lsl-boot-time.sh`,
  `lsl-common.sh`, `lsl-diag.sh`, `lsl-flatpak-fat.sh`, `persist-wifi.sh`,
  `pir`, `squashfs_config.sh`, `uproot`). Clicking those two icons will fail
  (`/cdrom` is also mounted without exec bits, so they must be invoked via
  `bash`). Either ship `lsl-gui`/`lsl-shutdown-gui` in `bin/` or gate the
  desktop entries on `-r` the way the rest of the scripts do.
* **`bin/mount_all.sh` is missing** — `onboot.sh:2074` logs
  `bash: /cdrom/bin/mount_all.sh: No such file or directory`.
* `sync_cdrom` logs `cp: X and X are the same file` for every `bin/*` file
  when `config.sh` is run from `/cdrom` itself (repo root == destination), and
  `set -e` aborts the sync there — harmless in-boot (nobody calls it that way)
  but noisy and it breaks `config.sh` run in place.
* `bin/config.sh` and `bin/lsl-common.sh` are dated 16:41 today while the rest
  of the toolkit is from the Sep 16/19/21 layer pack — the stick copy has been
  hand-edited after the layer was built, so the squashfs layer (and the
  `C:/GitHub/lsl-usb` repo per `pi/FIRSTBOOT.md` §6) still needs these two
  fixes re-applied/re-packed.

## 5. `hiberfil.sys`, Fast Startup, and why the installer should offer `powercfg /h off`

Found while auditing the reclaim feature (`bin/lsl-reclaim-win-swap.sh`) after
the persistent-home bugs. Recorded here because it is a Windows-side setup gap,
not a boot-script bug.

### What is on this machine

```
C:\hiberfil.sys    6.8 GB   mtime 2026-09-21 09:19   header: all zeros
C:\pagefile.sys     10 GB   mtime 2026-09-21 09:20
C:\swapfile.sys     16 MB   mtime 2026-09-21 09:20
RAM: 15.4 GiB
WSL2 swapfile.vhdx: none found
```

`hiberfil.sys` exists ⇒ **Fast Startup (or hibernate) is enabled**. The 6.8 GB is
≈40% of RAM — the default `powercfg` allocation, i.e. reserved scratch space, not
a saved session. The header is all zeros, so the last shutdown wrote no resume
image (a real one starts with a `hibr`/`HIBR` signature).

### Why this matters to LSL

1. **It blocks the reclaim feature.** `bin/lsl-reclaim-win-swap.sh:326` skips any
   volume where `hiberfil.sys` is present, because its presence is the cheap
   proxy for "the last shutdown may have been hibernate-like, so
   `pagefile.sys` contents may still be live". On this machine that means
   `LSL_RECLAIM_WIN_SWAP=1` does nothing at all — the only reclaim candidate is
   the 10 GB `pagefile.sys`, and there is no WSL2 `swapfile.vhdx` here.
2. **Fast Startup is the dangerous case for our own writes.** With Fast Startup,
   Windows hibernates the *kernel session* at shutdown. Booting Linux and
   mounting `/mnt/c` read-write then lets both sides hold divergent NTFS state;
   Windows resumes and writes back its stale view → filesystem corruption. This
   is the case `mount_all.sh`'s `ntfsfix -n` → read-only fallback exists for. A
   *zeroed* hiberfil is harmless; a *populated* one paired with an rw mount is
   not.
3. **Deleting `hiberfil.sys` from Linux frees nothing permanently.** Windows
   re-creates it at the next shutdown while hibernate remains enabled. Worse,
   deleting it *removes the gate* in (1) without making the shutdown clean, so a
   later reclaim run could rename a still-live `pagefile.sys`.

### The correct fix: `powercfg /h off` (from Windows)

```
powercfg /h off      # disables hibernate + Fast Startup AND deletes hiberfil.sys
powercfg /h /size 0  # alternative: shrink rather than remove (keeps Fast Startup)
```

`powercfg /h off` frees the 6.8 GB **permanently**, makes every subsequent
shutdown genuinely clean for Linux (no resume image, no stale kernel session),
and un-blocks the reclaim path so `pagefile.sys` can legitimately be reused.
Trade-off: loses Fast Startup and hibernate. For a dual-boot Linux stick that is
normally a win — Fast Startup is a frequent cause of dirty NTFS volumes and
"mounted read-only" surprises.

### Proposal: offer it as a checkbox in `lslsetup.exe`

The installer already has the right pattern for this — the reclaim checkbox at
`install.ps1:2271-2287` (`$chkReclaim` at 2271, `Checked` default `$false` at 2275, tooltip 2283, result object `ReclaimWinSwap` at 2828) writes `LSL_RECLAIM_WIN_SWAP=1` into
`lsl-usb.env` (`install.ps1:3139-3154`). Add a sibling on the same page:

- **Checkbox:** "Turn off Windows Fast Startup / hibernate (`powercfg /h off`)"
  - Default **unchecked** (it changes Windows power behaviour), with a tooltip
    explaining: frees ~6.8 GB, removes dirty-NTFS/read-only-mount surprises when
    dual-booting, and is required for the reclaim option above to do anything.
  - Enable/disable (or annotate) the reclaim checkbox based on it: reclaim is a
    no-op while `hiberfil.sys` exists, and the two options are naturally used
    together.
- **Action:** run `powercfg /h off` during install, guarded by:
  - admin check (the installer already elevates),
  - `Test-Path "$env:SystemDrive\hiberfil.sys"` to skip when already off,
  - capture `$LASTEXITCODE` and warn rather than abort on failure.
- **Reporting:** log the size freed and the resulting `hiberfil.sys` state, so
  the outcome is visible rather than silent — the same failure mode as the
  icon/`misc/kitty.conf` bugs in §2 above (a step that quietly did nothing).
- **Reversibility:** document `powercfg /h on` in the tooltip/summary text so the
  user knows it is undoable.

This is worth doing because today the two features are silently incompatible:
a user can tick "reclaim pagefile.sys" and get nothing, with no explanation, on
exactly the machines (Fast Startup on by default) where they'd most likely tick
it.

## TL;DR

`lsl-firstboot.sh` is not the culprit — it never installs icons. `bin/config.sh`
is, twice over: (1) its `install_desktop_shortcuts` is gated on `SYNC=1`, while
the only in-boot caller (`onboot.sh` → `config.sh --from-onboot`) always runs
with `SYNC=0`, so the icons were never installed on the live stick; and (2) the
kitty-config step aborts the script with `set -e` because `/cdrom/misc/` is
empty, which also cost the systemd-unit install (including `onboot.service`,
the same missing-runner failure as WHYFAIL3). Both fixed in
`/cdrom/bin/config.sh`; desktop icons and autostart entries now install on
`--from-onboot` runs, verified.

§5 adds a separate Windows-side finding: **Fast Startup is enabled on this
machine** (a 6.8 GB, all-zero `hiberfil.sys`), which silently makes the
`LSL_RECLAIM_WIN_SWAP=1` option a no-op — its clean-shutdown gate skips any
volume with `hiberfil.sys` present, and the only reclaim candidate here is the
10 GB `pagefile.sys` (there is no WSL2 `swapfile.vhdx`). The fix is
`powercfg / h off` from Windows: it frees the space permanently, makes every
shutdown genuinely clean for Linux, and un-blocks the reclaim. Recommend
exposing it as an installer checkbox next to the existing reclaim option
(`install.ps1:2271`).
