# FRAGILE_HOME.md — the `/home` persistence mode is inferred three different ways

**Status:** root cause fixed (see [Fix](#fix--what-changed)) and the follow-up
inventory closed (see [TODO](#todo)); this document stays because the *class* of
bug is still one careless `lsl_is_usb_mode` call away.

This is a post-mortem of a real data-loss bug observed on 2026-09-28, plus an
inventory of every place the same mistake can be made again. Read this before
touching anything that mounts, flushes, or grows `/home`.

---

## Summary

On a boot that was **not** the "no persistence" entry, `/home` silently became a
tmpfs overlay and ~23 minutes of first-boot work was dropped on reboot.

The operator's boot selection was correct. The cause was that **lsl-usb decides
"is `/home` persistent?" three different ways, and they disagree during first
boot**:

| Mechanism | Answers | Trustworthy? |
|---|---|---|
| `lsl_is_usb_mode()` — resolve `LSL_DATA_DIR` | *"where would persistence go **if it were set up now**?"* | No — it is a **prediction**, and it changes mid-boot |
| `/run/lsl-usb.state` (`LSL_MODE=…`) written by `lsl-mount-home.sh` | *"how was `/home` **actually** mounted this boot?"* | **Yes — authoritative** |
| `findmnt -o FSTYPE --target /home` | *"is it literally tmpfs?"* | Partly — sees RAM-only, blind to overlay-on-tmpfs |

Only the second one describes reality. The first one is a forecast, and on the
first boot it is a forecast that **becomes wrong while the boot proceeds**.

---

## The failure, step by step

Reproduced from `/proc/cmdline`, `/run/lsl-usb.state`, and the journal:

**1. Boot entry is the persistent one.** `/proc/cmdline` contains no
`lsl_home=tmpfs`:

```
BOOT_IMAGE=/_ISO/linuxmint-22.3-cinnamon-64bit/vmlinuz boot=casper \
  layerfs-path=/cdrom/casper/filesystem.z0.squashfs rootdelay=15 quiet splash
```

So `LSL_EPHEMERAL_HOME` stays `0` and the RAM-only branch never runs. Nothing
here is the operator's fault.

**2. The data dir is not reachable yet.** `mount_all.sh` → `wsl-boot-setup`
needs `hivexregedit` to map Windows drive letters. On a fresh image it is not
installed:

```
lsl-mount-home.sh[1476]: Error: 'hivexregedit' is required but not installed.
```

`/mnt/c` never mounts, so `/mnt/c/Users/lsl-usb` (the HDD data dir) is not on a
persistent volume.

**3. `lsl-mount-home.sh` takes the fallback branch — correctly.** Its logic is
sound: rather than write a `home.btrfs` into volatile RAM, it uses a temporary
tmpfs overlay and warns.

```
lsl: HDD data dir /mnt/c/Users/lsl-usb not on a persistent volume yet; retrying drive mount...
lsl: WARNING: data dir still not persistent; using a temporary tmpfs-overlay /home for this boot (changes lost on reboot).
Creating /cdrom/home-linuxmint.sfs from live /home (first boot)...
Created /cdrom/home-linuxmint.sfs (32K).
```

**4. …but it recorded the wrong mode.** The fallback path wrote
`LSL_MODE=usb` — **byte-identical to a real USB stick**. This is the origin of
the bug. A transient accident was recorded as a deliberate configuration.

```
$ cat /run/lsl-usb.state
LSL_HOME_LOWER=/run/lsl-home-lower
LSL_HOME_UPPER=/run/lsl-home-overlay/upper
LSL_HOME_WORK=/run/lsl-home-overlay/work
LSL_MODE=usb          # <-- a fallback, not a stick
```

**5. Firstboot runs for 23 minutes (02:42 → 03:05)** and — this is the trap —
*installs the very packages that fix the mount problem*, including
`hivex-tools`. It then builds the layer and calls the final flush:

```
[2026-09-28 03:05:21] Flushing /home to its permanent location (/cdrom/bin/uphome)...
```

**6. `uphome` re-derives the mode and gets a different answer.** By now
`/mnt/c` has mounted, so `lsl_is_usb_mode` resolves `/mnt/c/Users/lsl-usb` and
returns **false** → "HDD mode":

```
HDD mode: syncing btrfs…
home/cache btrfs sync complete.
```

That `btrfs filesystem sync /home` ran against a **tmpfs overlay**, so it was a
no-op, and `uphome` **exited 0**. Firstboot logged `Final home flush OK.` The
home changes existed only in `/run` and were lost on reboot.

**7. The two scripts contradicted each other in the same run.** `uphome` printed
`HDD mode: syncing btrfs…`, then `exec`'d into `lsl-flush-home.sh`, which read
the stale state file and printed `USB mode: flushing merged /home…`. Two
components, one boot, opposite conclusions about the same mount — and nobody
noticed, because both exited successfully.

### Damage

- **Lost:** the `/home` half of first boot — anything written to `/home` after
  03:05, plus whatever the fallback overlay held.
- **Survived:** the layer, `filesystem.z0.20260928025844.squashfs` (763 MB) —
  packages and flatpaks are safe.
- **Near miss:** `lsl-flush-home.sh` would have overwritten the good per-distro
  `home.sfs` with the near-empty overlay. It only did not because the fallback
  overlay happened to be freshly seeded and nothing else had been written.

### Why it is so hard to spot

- Both paths **exit 0** and both log success. There is no error anywhere.
- The only symptom is a `tmpfs`/`overlay` `/home` on an entry the operator
  believes is persistent.
- `/run` is RAM, so the misleading `LSL_MODE=usb` **evaporates on reboot**. The
  next boot looks clean, and the incident leaves no residue to debug.
- `/cdrom/casper/lsl-firstboot.done` is written regardless, so firstboot does not
  re-run and the lost home is not rebuilt.

---

## Root cause

> `lsl-mount-home.sh` recorded a **fallback** with the same value it uses for a
> **real USB-mode overlay**, and `uphome` / `lsl-flush-home.sh` trusted a
> **re-resolved prediction** (`lsl_is_usb_mode`) instead of the recorded fact.

The general rule this breaks:

> **Anything that writes to persistence must branch on how `/home` was actually
> mounted, never on a fresh `lsl_is_usb_mode` resolve.**

`lsl_is_usb_mode` is only valid *before* `/home` is mounted (in
`lsl-mount-home.sh` itself) or when the answer cannot have changed since.

---

## Fix — what changed

All four files were byte-identical between the repo and the deployed stick, so
these apply to the next build.

### 1. `bin/lsl-common.sh` — `lsl_effective_home_mode()`

New helper. Reads `LSL_MODE` from the state file `lsl-mount-home.sh` wrote —
the authoritative record — falling back to the live mount type only when there
is no state file. Returns `ram` | `usb` | `usb-fallback` | `hdd` (empty when
unknown).

```bash
_ehm="$(lsl_effective_home_mode)"
```

### 2. `bin/lsl-mount-home.sh` — record the fallback honestly

The fallback branch no longer masquerades as a stick:

```bash
_lsl_state_mode=usb
if [ "${LSL_FALLBACK_USB_HOME:-0}" = "1" ]; then
    _lsl_state_mode=usb-fallback
fi
```

`LSL_MODE` is now written from `$_lsl_state_mode`, so a transient fallback is
distinguishable from a deliberate USB configuration. `ram` and `hdd` unchanged.

### 3. `bin/uphome` — branch on the effective mode, fail loudly

- `ram` → exit 0 (nothing to persist), unchanged.
- `usb` → flush to the stick's `home.sfs`, unchanged.
- **`usb-fallback` → `exit 1`** with an explicit "its contents WILL BE LOST on
  reboot" message. A non-zero exit makes `misc/lsl-firstboot.sh` log
  `WARNING: final home flush failed` instead of `Final home flush OK.`
- `hdd` → btrfs sync, unchanged.

The loud failure is the important part: the previous behaviour was a *silent
success* on a no-op, which is what made this invisible.

### 4. `bin/lsl-flush-home.sh` — refuse to clobber `home.sfs`

Guards the destructive direction: a fallback overlay must never be written over
a good per-distro `home.sfs`.

```bash
_ehm="$(lsl_effective_home_mode)"
if [ "$_ehm" = "usb-fallback" ]; then
    echo "lsl-flush-home.sh: /home is a FALLBACK tmpfs overlay; refusing to overwrite" >&2
    echo "  $HOME_SFS with it. Reboot with the data dir mounted and retry." >&2
    exit 1
fi
```

### 5. Follow-up (the TODOs below) — predicates, firstboot failure, hivex pre-seed

- **`bin/lsl-common.sh`**: added `lsl_effective_home_is_usb` and
  `lsl_effective_home_is_hdd` — thin, testable wrappers over
  `lsl_effective_home_mode` that fall back to `lsl_is_usb_mode` only when there is
  no state file. `lsl-home-flushd`, `lsl-btrfs-growd` and `lsl-shutdown-gui` now
  branch on these instead of `lsl_is_usb_mode`.
- **`misc/lsl-firstboot.sh`**: `flush_home_final` now fails loudly (non-blocking)
  on `usb-fallback` — ERROR log, failed phase/detail in the live dialog, a
  persistent `/cdrom/casper/lsl-firstboot.home-failed[.reason]` marker, and the
  new `misc/lsl-firstboot-home-failed.sh` warning *before* the reboot-approval
  dialog.
- **Hivex pre-seed (the ordering gap of rule 7)**: the Windows installer stages
  `libhivex0` / `libhivex-bin` / `libwin-hivex-perl` `.debs` to `<USB>:\pkgs\`;
  `lsl_ensure_hivex_tools` installs them (offline) before `/home` mounts in
  `onboot.sh` / `lsl-mount-home.sh`; `mount_all.sh` names the missing-`hivexregedit`
  defect and marks `/run/lsl-usb.mount-missing-hivex`; `bin/squashfs_config.sh`
  installs the staged `.debs` early in the chroot as a second line of defence.

### Backward compatibility

`usb-fallback` is only ever produced by the new `lsl-mount-home.sh`. An older
stick writing plain `LSL_MODE=usb` still reads as `usb` and still flushes, so a
mixed-version stick does not break — it just keeps the old (lossy) behaviour
until the stick is updated. This is deliberate: changing the meaning of an
existing value would break sticks in the field.

### Verification

- `bash -n` clean on all four files.
- `tests/lsl-common.tests.sh`: 9 new cases pinning `lsl_effective_home_mode` —
  all four modes round-tripping, the real four-key fallback state file, CRLF
  trimming, last-`LSL_MODE`-wins, both no-state-file fallbacks
  (overlay→empty, tmpfs→ram), and legacy `LSL_MODE=usb` still reading as `usb`.
  Suite: **59 passed, 0 failed**.
- Writing those tests caught a real defect in the first cut of the helper: it did
  not strip CR, so a state file with CRLF endings would have returned
  `usb-fallback\r` and matched **no** branch — silently falling through to the
  HDD no-op that caused the original data loss. `tr -d '\r'` added. This is the
  same CRLF class of bug that already broke `LSL_DATA_DIR` detection once (see
  the CRLF regression cases in `tests/lsl-common.tests.sh`).
- `lsl_is_usb_mode` and `lsl_data_dir_is_persistent` semantics are unchanged, so
  the existing `tests/lsl-common.tests.sh` cases still hold.

---

## Inventory: every consumer of the mode, and its risk

The fix covers the home-persistence path. These are the remaining callers, with
the risk each carries. **This table is the reason the file is called
`FRAGILE_HOME.md`** — the same confusion is latent everywhere.

| Caller | Uses | Safe? | Notes |
|---|---|---|---|
| `lsl-mount-home.sh:115` | `lsl_is_usb_mode` | **Yes** | Runs *before* `/home` is mounted — the only place the prediction is the right question. |
| `lsl-mount-home.sh:53,73,78` | `lsl_is_usb_mode` | **Yes** | Same, pre-mount. |
| `uphome` | `lsl_effective_home_mode` | **Fixed** | Was the data-loss site. |
| `lsl-flush-home.sh` | `lsl_effective_home_mode` | **Fixed** | Was the clobber site. |
| `lsl-home-flushd` | `lsl_effective_home_is_usb` | **Fixed** | Migrated: stops watching unless `/home` is a real stick overlay. |
| `lsl-btrfs-growd` | `lsl_effective_home_is_hdd` | **Fixed** | Migrated: the 60 s loop can no longer be flipped by a mid-boot resolve. |
| `lsl-shutdown-gui` | `lsl_effective_home_is_hdd` / `lsl_effective_home_mode` | **Fixed** | Wording + bind unmounts now reflect the mode `/home` was mounted with. |
| `lsl-toram.sh` | neither | n/a | Stops persistence services before pivoting to RAM. |

### Cache consumers (the `LSL_CACHE_MOUNT` re-audit)

`LSL_CACHE_MOUNT` (`/mnt/lsl-cache`) is written to the state file only in the HDD
branch of `lsl-mount-home.sh`. Its consumers, audited for the same
prediction-vs-fact shape:

| Caller | Uses | Safe? | Notes |
|---|---|---|---|
| `uphome` | `mountpoint -q /mnt/lsl-cache` | **Yes (fact)** | A live mount probe, not a prediction. |
| `lsl-nix-doctor.sh:30` | `mountpoint -q ${LSL_CACHE_MOUNT}` | **Yes (fact)** | Same. |
| `lsl-btrfs-growd` | `${LSL_CACHE_MOUNT}` + `lsl_cache_btrfs_path` | **Fixed** | The whole daemon now gates on `lsl_effective_home_is_hdd`, so it never grows a cache on a non-HDD boot. |
| `lsl-shutdown-gui` | unmount `/mnt/lsl-cache` | **Fixed** | Gated on `lsl_effective_home_is_hdd` with the other HDD binds. |
| `lsl-toram.sh` | `lsl_cache_btrfs_path` | **Harmless** | Only enumerates images to detach; no persistence write. |

Rule: **gate a cache persistence write on `lsl_effective_home_is_hdd`**, exactly as
`/home` writes gate on `lsl_effective_home_mode`.

### Caveat that used to apply to `lsl-btrfs-growd` (now closed)

It used to exit when `lsl_is_usb_mode` was true, re-resolving the mode **every 60
seconds** in its loop (`while true; do lsl_load_config; if lsl_is_usb_mode; then
exit 0; fi; …`). If `/mnt/c` mounted *while the daemon was running* — exactly what
happened at 02:42 during firstboot — the prediction flipped underneath it
mid-loop. It now branches on `lsl_effective_home_is_hdd`, which cannot flip: a
fallback boot records `usb-fallback` once at mount and the daemon exits.

### Why the daemons were migrated last

`lsl-home-flushd` and `lsl-btrfs-growd` are not the callers losing data — the two
files that actually write `/home` (or overwrite its image) were fixed first. The
daemons were migrated afterwards, behaviour-preservingly, because a daemon that
re-resolves is the clearest case of a prediction that can change under a running
process. Both now use the `lsl_effective_home_is_*` predicates.

---

## Rules for future changes

1. **Never branch a persistence write on `lsl_is_usb_mode`.** Use
   `lsl_effective_home_mode`.
2. **`lsl_is_usb_mode` is only valid before `/home` is mounted.** If the answer
   could have changed since, it is the wrong question.
3. **Record what you did, not what you intended.** When a mount path deviates
   from configuration (fallbacks, degradation, retries), write a state value
   that says so. Reusing the value for the normal case makes the deviation
   invisible.
4. **A persistence no-op must not exit 0.** `uphome` "syncing btrfs" against a
   tmpfs overlay was a silent success; that is what turned a warning into data
   loss. If there is nothing to persist and that is unexpected, fail.
5. **Cross-check the pair.** `uphome` and `lsl-flush-home.sh` printing `HDD mode`
   and `USB mode` in the same run should have been impossible to miss. Assert
   the mode agrees with the state file.
6. **`/run` is invisible after reboot.** Any diagnostic that would explain a
   transient `/home` must be flushed to the stick (as `lsl-diag.sh` does), or it
   is gone exactly when it is needed.
7. **A boot-time ordering gap is a defect, not a warning.** The fallback existed
   only because `mount_all.sh` needed `hivexregedit` on the same boot in which
   firstboot was going to install it. Removing the gap (stage the `.debs`, install
   them before `/home` mounts) is a real fix; logging the warning is not. When a
   tool is needed *earlier* than the step that provides it, move the provision,
   don't paper over the miss.

---

## Related

- **`WHYFAIL9.md`** — the incident write-up: the question asked, the evidence
  chain, the reproduce/verify commands, and what is not yet in effect on a
  booting stick. This file is the generalisation; that one is the report.
- **`WHYFAIL7.md`** — the first occurrence of the same symptom (CRLF in
  `lsl-usb.env`). Read together: WHYFAIL7 fixed why the fallback was *entered*,
  WHYFAIL9 fixed *what the fallback recorded*.
- **`WHYFAIL6.md` §5** — `hiberfil.sys` / Fast Startup, the separate
  Windows-side setup gap.

---

## TODO

All closed.

- [x] Migrate `lsl-home-flushd` and `lsl-btrfs-growd` to the effective mode via
      new `lsl_effective_home_is_usb` / `lsl_effective_home_is_hdd` predicates
      (behaviour-preserving; the growd's 60 s loop can no longer be flipped).
- [x] Make `lsl-shutdown-gui` report the *effective* mode, so it cannot promise a
      btrfs sync that did not happen (and only unmounts HDD binds on an HDD boot).
- [x] Add tests to `tests/lsl-common.tests.sh` pinning `lsl_effective_home_mode`
      for all four modes, the fallback state file, and CRLF handling.
- [x] Fail the firstboot `home` task loudly (non-blocking) when the flush reports
      `usb-fallback`: `flush_home_final` now logs an ERROR, sets a failed
      phase/detail in the live dialog, writes `/cdrom/casper/lsl-firstboot.home-failed`
      + `.reason`, and shows `misc/lsl-firstboot-home-failed.sh` *before* the
      reboot-approval dialog.
- [x] Treat missing `hivexregedit` as a **first-boot ordering defect**, not a
      warning: `mount_all.sh` names it and marks `/run/lsl-usb.mount-missing-hivex`;
      the Windows installer stages `libhivex0`/`libhivex-bin`/`libwin-hivex-perl`
      `.debs` to `<USB>:\pkgs\` and `lsl_ensure_hivex_tools` installs them offline
      before `/home` mounts (so a stock first boot no longer falls back).
- [x] Re-audit other "prediction vs fact" pairs (`LSL_CACHE_MOUNT`): recorded
      above; cache writes gate on `lsl_effective_home_is_hdd`.

**Not in this change:** `install-xp.hta` (the legacy XP installer) does not yet
stage the hivex `.debs`; and the `z0` layer / deployed stick still need a rebuild
for the `misc/` changes to take effect.
