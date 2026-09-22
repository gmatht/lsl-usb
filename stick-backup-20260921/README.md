# stick-backup-20260921 — what this is

Backup of everything produced/changed on the live USB during the 2026-09-21
session, written to the Windows repo volume (`C:/GitHub/lsl-usb`) because
`/cdrom` was a single copy and `/home` was RAM-only.

Taken while C: was mounted **rw** (`ntfs3`); it had been `ro`, which also
blocked the `lsl -v` writable path (see WHYFAIL5.md gate 3/3).

## Contents

| path | why it matters |
|---|---|
| `WHYFAIL5.md`, `WHYFAIL6.md` | the write-ups; WHYFAIL5 is the running record (Follow-ups 1–3f) |
| `bin/lsl-gui2` | NEW working GUI launcher (was stick-only) |
| `bin/lsl-gui` | patched: terminal fallback instead of hard `wezterm` |
| `bin/config.sh` | patched: `cp_to_cdrom` self-copy guard, kitty `-r` gate, icon install on `--from-onboot` |
| `bin/lsl-common.sh` | patched: missing-trailing-newline fix in `lsl_vhdx_saved_distro_lines` |
| `bin/lsl-restore-stick-from-repo.sh` | recovery tool for the onboot.sh/lsl-usb.env truncation |
| `home-desktop/`, `home-autostart/` | desktop + autostart entries that lived in RAM and would vanish on reboot |
| `systemd/`, `misc/` | stick copies (identical to repo; saved for completeness) |
| `patched-for-repo/` | **the important part** — see below |
| `MANIFEST.md5` | checksums of everything above |

## patched-for-repo/ — the repo does NOT have any of this

Verified: `C:/GitHub/lsl-usb/bin/` still contains the *original* files. None of
this session's fixes are in the repo, so without applying these the next build
regenerates every bug documented in WHYFAIL5/6.

```
patched-for-repo/bin/{config.sh,lsl-common.sh,lsl-gui,lsl-gui2}   full patched files
patched-for-repo/{config.sh,lsl-common.sh,lsl-gui}.diff            unified diffs vs repo
patched-for-repo/lsl-gui2.newfile.diff                            new file (647 lines)
```

Apply by copying the `bin/*` files over the repo's, or `patch -p0` the diffs.

## Still NOT done (deliberately, needs a decision)

1. **Nothing was committed to git.** `git status` shows the repo dirty from
   other work; these changes are unstaged files in the working tree only.
2. **The squashfs layer was not re-packed.** `casper/filesystem.z0.*.squashfs`
   and the base layer still hold the *old* `/cdrom/bin/config.sh` etc. Anything
   reading them (rather than the stick) sees the unfixed versions.
3. **Upstream items from WHYFAIL5 that remain open:**
   * `lsl` should pass `-r` to guestmount so dirty images stay readable.
   * `lsl` should stop suggesting `qemu-img check -r all` on a possibly
     hibernated volume (destructive write path offered as a diagnostic).
   * The non-COW mount path (`guestmount` no-flags / `qemu-nbd` + plain
     `mount`) has no read-only fallback and no post-mount rw verification.
   * Real rw was never exercised; `rw_gate_check` stays unreachable in the UI
     until it is.
4. **`lsl-gui2` is not in the repo's `bin/`** — only here. Add it, or it is lost
   at the next layer pack.

## Note on C: mount state

The volume was mounted `rw` to take this backup. If the machine is returned to
Windows, a clean shutdown (`shutdown /s /t 0`, Fast Startup off) is still
required before any real-rw work, because `hiberfil.sys` (6.8 GB) means the
Windows kernel image is suspended.

---

## Refresh 2, 2026-09-21 20:xx — kitty pinning, config.sh cleanup, lsl-common.sh

Updated files: `bin/config.sh`, `bin/lsl-pin-favorites` (new here),
`bin/lsl-common.sh`, `bin/lsl-gui2`, `bin/lsl-gui`, both write-ups,
`home-desktop/`, `home-autostart/`, and all `patched-for-repo/` diffs.
Manifest regenerated and verified (35 entries).

### What changed in this refresh

* **`bin/lsl-pin-favorites`** — now prefers **kitty** over wezterm
  (`choose_kitty_desktop_id` + `choose_terminal_desktop_id`, falling back to
  gnome-terminal/xterm). The base image ships kitty, NOT wezterm, so the old
  wezterm-only pin silently pinned nothing and the panel stayed stock Mint.
* **`bin/config.sh`** — `install_lsl_wezterm_autostart` →
  `install_lsl_terminal_autostart`; it writes `lsl-terminal-pin.desktop` instead
  of `lsl-wezterm.desktop` and **deletes the legacy duplicate**. There were two
  autostart entries running the identical `Exec=/cdrom/bin/lsl-pin-favorites`,
  i.e. the pin ran twice per login. `Comment=` strings corrected.

### Parallel edits to the repo — read this before applying anything

While this session was working, `C:/GitHub/lsl-usb/bin/lsl-common.sh` gained an
`lsl_env_file()` fix (CRLF/BOM normalisation for the FAT-hosted `lsl-usb.env`,
so a `\r` in `LSL_DATA_DIR` cannot make onboot fall back to a tmpfs `/home`).
It is **not** from this session, it is currently uncommitted (`git status` shows
` M bin/lsl-common.sh`), and after it landed the stick copy and the repo copy
became **byte-identical** — so `lsl-common.sh` needs no patch from here and its
diff was removed. Note the trailing-newline fix from this session survived
inside that newer revision.

Consequence: before applying `patched-for-repo/`, re-diff against the repo. Some
of these files may already have moved on, and a blind copy would revert the
parallel work. Always take a fresh `diff -u`, never assume this snapshot is
current.

### Still true from the first pass

Nothing is committed to git; the squashfs layers still hold the old scripts;
`lsl-gui2` and (now) `lsl-pin-favorites` exist only here plus the stick; the four
upstream `lsl` items remain open; `/mnt/c` is left mounted rw.
