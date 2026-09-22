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
