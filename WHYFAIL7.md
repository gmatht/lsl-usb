# WHYFAIL7 — Why did the bootscripts not mount a persistent home?

Asked 2026-09-21. Short answer: **the stick's `lsl-usb.env` had CRLF line
endings, so `LSL_DATA_DIR` arrived in bash with a trailing `\r`. That path
matched neither `/cdrom` nor `/persist` and could not be resolved by `findmnt`,
so `onboot.sh` concluded the data dir was not persistent and fell back to a
volatile tmpfs/overlay `/home` — silently, with nothing in any log.**

A second, independent finding came out of the same session: **five successful
firstboots had left 5×761 MB of squashfs layers on the stick (3.6 GB), four of
them inert**, because nothing pruned the layer chain on the success path. That
is WHYFAIL7 §2.

This file documents what was wrong, what was changed, and — importantly — what
is **not** yet in effect on a booting stick.

---

## 1. Persistent home not mounted (CRLF in the env file)

### Root cause

`/cdrom/lsl-usb.env` had CRLF endings (FAT stick, editable from Windows). Bash
sourced it raw, so the value became:

```
LSL_DATA_DIR=/mnt/c/Users/lsl-usb\r      (0d as the last byte — verified with od)
```

Consequences, in order:

1. `lsl_is_usb_mode` compared the path against `/cdrom*` and `/persist*` — no
   match, so it (correctly) reported **not** USB mode. HDD mode was intended.
2. `lsl_data_dir_is_persistent` asked `findmnt -T "/mnt/c/Users/lsl-usb\r"`,
   got nothing, and reported "not persistent".
3. `onboot.sh` sets `LSL_FALLBACK_USB_HOME=1` when HDD mode can't confirm a
   persistent volume, and the later branch test
   (`if lsl_is_usb_mode || [ "$LSL_FALLBACK_USB_HOME" = 1 ]`) then took the
   **tmpfs-overlay** path instead of creating/loop-mounting `home.btrfs`.

So `/run/lsl-usb.state` said `LSL_MODE=usb` — not because USB mode was selected,
but because the fallback writes that same state file.

### Why it was invisible

Nothing logged the chosen env file, data dir, or mode. The only symptom was a
non-persistent `/home`.

### Deeper cause found in the repo

`lsl-usb.env` **is tracked in git with LF endings**, but `.gitattributes` had no
rule for it. Every other guest-executed file is pinned (`bin/**`, `misc/**`,
`*.sh`, `*.service`, `onboot.sh`, …) and the env file was simply missed, so it
took the platform default — **CRLF on a Windows checkout**. This was not a
one-off edit; it is what the repo produced on every Windows checkout.

The same gap explained a cluster of test failures: `tests/mount_all.tests.sh`,
`lsl-merge-suggest.tests.sh`, `overlay-merge.tests.sh`,
`lsl-reclaim-win-swap.tests.sh`, `overlayfs-whiteout.tests.sh` all died with
`syntax error near unexpected token $'\r'` from stale CRLF working-tree files.

### Fixes (all in `bin/lsl-common.sh`, `onboot.sh`, `.gitattributes`)

| Where | Change |
|---|---|
| `.gitattributes` | `lsl-usb.env`, `*.env`, `*.bats` pinned to `eol=lf` — fixes the cause |
| `lsl_load_config` | normalises CRLF/BOM into a temp copy before sourcing; **must** be sourced in the current shell (a `. <(sed …)` process substitution runs in a subshell and silently discards every assignment — verified, it was my first attempt) |
| `lsl_env_file` (new) | an explicit `LSL_ENV_FILE` wins; otherwise `/cdrom/lsl-usb.env` is preferred over a stale `$HOME/lsl-usb.env`, which used to shadow it |
| `lsl_load_config` | no longer clobbers an `LSL_DATA_DIR` the caller set explicitly (`lsl_resolve_data_dir` calls it, so the override was being discarded) |
| `lsl_resolve_data_dir` | trims CR/whitespace from the path |
| `onboot.sh` | exports `LSL_ENV_FILE` **before** sourcing `lsl-common.sh`; logs `env=… data_dir=… mode=…` and warns when HDD mode can't confirm a persistent volume |

### One unexplained detail (recorded honestly)

`"${VAR%$'\r'}"` behaved wrongly **inside that particular function body** — it
matched the empty string instead of a CR, leaving the value untouched. The same
expression works at top level and in an extracted copy of the same function, and
the source bytes are correct (`%$'\r'`). I could not explain the mechanism, so
the fix uses `tr -d '\r'` and a comment warns against reintroducing the `$'…'`
form there. Treat that comment as *empirically verified on this system*, not as a
settled root cause.

---

## 2. Layers never reaped on the success path

### What was found

`/cdrom/casper/` held five appended layers, 3.6 GB total:

```
filesystem.z0.20260916164712.squashfs   761 MB
filesystem.z0.20260919045856.squashfs   761 MB
filesystem.z0.20260919175925.squashfs   761 MB
filesystem.z0.20260920184749.squashfs   761 MB
filesystem.z0.20260921085616.squashfs   761 MB   <- the only one menu.lst named
```

### They were NOT failed attempts

This is the part that looks like a bug but isn't. Each one came from a run that
completed and rebooted — every log ends with `First-boot setup complete`:

```
firstboot-20260916163725.log  Layer written. Reboot…  "First-boot setup complete"
firstboot-20260919125253.log  Layer written. Reboot…  "First-boot setup complete"
firstboot-20260920014635.log  Layer written. Reboot…  "First-boot setup complete"
firstboot-20260921023929.log  Layer written. Reboot…  "First-boot setup complete"
firstboot-20260921164535.log  Layer written. Reboot…  "First-boot setup complete"
```

All five verify as intact (`unsquashfs -l`), there was no `lsl-firstboot.FAILED`
and no `.attempts` file.

### Why they accumulated

Two things, both needed:

1. **The stamp suppresses firstboot after the first success.** The first run
   wrote a layer *and* stamped `casper/lsl-firstboot.done`. Every later boot
   exits early on that stamp. The only cleanup,
   `lsl_firstboot_drop_prior_appended_layers`, lives on the **retry** branch —
   reachable only while the stamp is *missing*. So it never ran.
2. **The boot config names only the newest layer.** `menu.lst` had
   `layerfs-path=/cdrom/casper/filesystem.z0.20260921085616.squashfs`. Casper
   stacks by walking dot-suffixes upward **from the named file**, so the four
   older layers were inert — unread dead weight. `bin/uproot` already documents
   this failure mode in a comment.

### Fixes

- **`bin/uproot`**: new `prune_superseded_layers()`, called from
  `write_append_layer()` immediately after `repoint_layerfs_refs`. Every layer
  write now reaps what it orphaned.
- **`misc/lsl-firstboot.sh`**: `lsl_firstboot_prune_orphan_layers()` at the
  finale, as a belt-and-braces pass on the success path.
- Both use the same **fail-safe rule**: delete nothing unless the layer the boot
  config names can be positively resolved; never remove that layer, its
  dot-ancestors (casper reads those), or the base layers.

### A boot-bricking bug I introduced and caught

The first version pruned by **negation** — "remove everything that isn't a
keeper" — and `active_layer_path()` hardcoded `/cdrom` while `STICK_DIR` pointed
elsewhere. It failed to match, treated every layer as an orphan, and **deleted
the layer `menu.lst` pointed at**. A sandbox test case exposed it. The helper now
honours `STICK_DIR` (normalising `/cdrom/…` references onto it) and refuses to
act when: there is no keeper, the keeper is outside the stick, or no
`layerfs-path` reference exists.

Seven regression tests cover the prune, including the named-layer-survives case
and four fail-safe paths (`tests/lsl-common.tests.sh`).

### Layer cleanup actually performed on this stick

The four inert layers were deleted; `filesystem.z0.20260921085616` (the one
`menu.lst` names), its `.sh`, and both base layers were kept:

```
before: /dev/sda1 29G 6.4G 23G 22%      after: 29G 3.5G 26G 13%   (freed 2.9 GB)
```

Verified afterwards that every `layerfs-path=` in `menu.lst` still resolves to a
file that exists.

---

## 3. What is NOT yet in effect (important)

- **`misc/lsl-firstboot.sh` exists only inside
  `casper/filesystem_z0_firstboot.squashfs`** — it is *not* on the FAT
  partition. The success-path prune therefore **needs that layer rebuilt** before
  it runs on a boot. The repo copy is correct; the booting copy is not updated.
- **`bin/uproot` IS on the stick** and is in sync, so the uproot-side prune is
  live now.
- Nothing was committed or pushed to the `C:/GitHub/lsl-usb` repo.

---

## 3b. Where everything is backed up

- **`/cdrom/lsl-backup-20260922/`** — complete snapshot of every file this session
  changed, in repo layout so `tests/lsl-common.tests.sh` runs from it
  (verified: `RESULT: 39 passed, 0 failed`). Mirrored to
  `C:/GitHub/lsl-usb/stick-backup-20260922/` (byte-identical).
- **Live copies on the stick root**: `bin/lsl-common.sh`, `bin/uproot`,
  `onboot.sh`, `lsl-usb.env`, `WHYFAIL7.md`.
- **Repo**: the same files plus `misc/lsl-firstboot.sh`,
  `tests/lsl-common.tests.sh`, `.gitattributes`, `CHANGELOG.md`.
  Nothing committed or pushed.

## 3c. Related: `hiberfil.sys` / Fast Startup (documented in WHYFAIL6 §5)

Auditing the reclaim path turned up a Windows-side setup gap that is **not** part
of the persistent-home bug, so it is written up in **`WHYFAIL6.md` §5**:

- This machine has Fast Startup enabled — a 6.8 GB, **all-zero** `hiberfil.sys`
  (mtime 2026-09-21 09:19; a real resume image starts with `hibr`/`HIBR`). RAM is
  15.4 GiB, so the size is the default ~40% `powercfg` allocation, not saved state.
- `bin/lsl-reclaim-win-swap.sh:326` skips any volume where `hiberfil.sys` exists,
  so `LSL_RECLAIM_WIN_SWAP=1` is a **silent no-op here**. The only reclaim
  candidate is the 10 GB `pagefile.sys`; there is no WSL2 `swapfile.vhdx`.
- Deleting `hiberfil.sys` from Linux frees nothing permanently (Windows
  re-creates it) and removes that clean-shutdown gate without making the shutdown
  clean. The correct fix is `powercfg / h off` **from Windows**.
- Proposed an installer checkbox next to the existing reclaim option
  (`install.ps1:2271`) to run it — see WHYFAIL6 §5 for the full proposal.

## 4. Files changed

On the stick (`/cdrom`) and in the repo (`C:/GitHub/lsl-usb`), kept byte-identical:

| File | Change |
|---|---|
| `bin/lsl-common.sh` | CRLF/BOM-safe config load; env-file precedence; CR trimming; caller-preset preservation |
| `bin/uproot` | `prune_superseded_layers()` + `active_layer_path()`, wired into `write_append_layer` |
| `onboot.sh` | `LSL_ENV_FILE` exported before sourcing; mode/data-dir logging + warning |
| `lsl-usb.env` | renormalised to LF |

Repo only:

| File | Change |
|---|---|
| `.gitattributes` | `lsl-usb.env`, `*.env`, `*.bats` → `eol=lf` |
| `misc/lsl-firstboot.sh` | `lsl_firstboot_prune_orphan_layers()` at the finale |
| `tests/lsl-common.tests.sh` | 13 new tests (env/CRLF and layer prune); also unset the `ls`/`getent`/`df` mocks that leaked into every later test. 39 passed / 0 failed |
| `CHANGELOG.md` | both fixes recorded under Unreleased → Fixed |
| 5 × `tests/*.sh`, `tests/extract_fn.py` | renormalised to LF (content unchanged) |

---

## 5. Reproduce / verify

```bash
# Config load: expects dir=/mnt/c/Users/lsl-usb, mode=hdd, persistent=yes
env -u LSL_ENV_FILE bash -c '. /cdrom/bin/lsl-common.sh; lsl_load_config
  echo "dir=[$(lsl_resolve_data_dir)]"; lsl_is_usb_mode && echo "mode=usb" || echo "mode=hdd"'

# The whole regression suite (run from the repo)
bash tests/lsl-common.tests.sh        # RESULT: 39 passed, 0 failed

# Dry-run the layer prune without deleting anything
grep -o 'layerfs-path=[^ ]*' /cdrom/menu.lst
ls /cdrom/casper/filesystem.z0.*.squashfs
```

## TL;DR

`onboot.sh` never mounted a persistent `/home` because a Windows-style CRLF
checkout of `lsl-usb.env` put a trailing `\r` in `LSL_DATA_DIR`, so the script
couldn't confirm the volume was persistent and silently took the tmpfs-overlay
fallback. Fixed at the source (`.gitattributes`), in the loader (CRLF/BOM
normalisation, env-file precedence), and in `onboot.sh` (ordering + logging).
Separately, five *successful* firstboots had each orphaned a layer because
cleanup only ran on the retry path that never fired; `uproot` and firstboot now
prune on success with fail-safe guards, and the four inert layers (2.9 GB) were
reclaimed from this stick.
