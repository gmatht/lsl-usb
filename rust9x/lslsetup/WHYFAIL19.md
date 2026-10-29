# WHYFAIL19 — every secondary initrd panicked: ORDER sourced files it didn't pack

Reported from the field 2026-10-29: sticks written with the HDD-mirror initrd
(`casper/initrd.hddmirror.gz`) and sticks written with the F2FS provisioning
initrd (`casper/initrd.f2fs.gz`) both died at boot with

```
Kernel panic - not syncing: Attempted to kill init! exitcode=0x00000000
```

Short answer: **one shared `ORDER` body names four hooks, but each initrd packs
only two of them.** The other two dot-source lines reference files that do not
exist in that initrd. Under casper's `set -e` shell a failed `.` (dot) command
is fatal to PID 1 — POSIX requires a non-interactive shell to exit when `.`
fails to open its file — and `2>/dev/null || true` does NOT save it. The boot
therefore panicked before any hook ran. (The Boot-to-RAM initrd,
`initrd.ramclone.gz`, shares the same constant and was broken the same way.)

This is the companion to `WHYFAIL18.md`: that one was an `exit` *inside* a hook
that killed PID 1; this one is the `ORDER` *around* the hooks killing PID 1
before any hook executes. Both read as the same panic on the console.

---

## 1. What the operator saw

Two different stick flavors, same immediate panic, no desktop, no installer
error — both sticks were written successfully. The hddmirror stick panicked on
a normal boot; the f2fs stick panicked on first boot with
`lsl_f2fs_provision=<GiB>` on the cmdline.

## 2. What was actually true

All three secondary initrds are built from ONE constant,
`CASPER_PREMOUNT_ORDER` in `rust9x/lslsetup/src/lslfiles.rs`. It ends with four
bare sources:

```sh
. /scripts/casper-premount/zz_lsl_hdd_mirror "$@" 2>/dev/null || true
. /scripts/casper-premount/9990-live-ramclone "$@" 2>/dev/null || true
. /scripts/casper-premount/zz_lsl_f2fs_provision "$@" 2>/dev/null || true
. /scripts/casper-premount/zz_lsl_f2fs_scrub "$@" 2>/dev/null || true
```

But each initrd packs only two hook members:

| initrd | packs | ORDER also sources (absent) |
|---|---|---|
| `initrd.hddmirror.gz` | `zz_lsl_hdd_mirror`, `zz_lsl_f2fs_scrub` | `9990-live-ramclone`, `zz_lsl_f2fs_provision` |
| `initrd.f2fs.gz` | `zz_lsl_f2fs_provision`, `zz_lsl_f2fs_scrub` | `zz_lsl_hdd_mirror`, `9990-live-ramclone` |
| `initrd.ramclone.gz` | `9990-live-ramclone`, `zz_lsl_f2fs_scrub` | `zz_lsl_hdd_mirror`, `zz_lsl_f2fs_provision` |

Casper's `run_scripts` **sources** `scripts/casper-premount/ORDER` into its own
shell (PID 1, running under `set -e`). POSIX (2018 §2.14, "Dot") says: if `.`
fails to open the file in a non-interactive shell, *the shell shall exit*.
`|| true` never runs because `set -e`'s own rule for `.` fires first — the
special-builtin failure is fatal before the list can recover. (BusyBox ash,
which is what the initramfs actually runs, implements exactly this: `cmdsource`
returns `EXERROR`, and `set -e` aborts the sourced script, hence PID 1.)

Two details made this easy to miss:

- **The guard looked sufficient.** `2>/dev/null || true` is the file's idiom for
  "never fail", and it works for ordinary commands. `.` is a POSIX
  *special builtin* with its own exit-the-shell rule; the guard pattern does
  not apply to it. Reviewers (and the mid2 bisection note — "guarded by
  `2>/dev/null || true`") read the suffix and moved on.
- **The comment said the shape was safe.** The constant's own doc comment said
  "Both hooks self-guard on the kernel cmdline, so listing both is safe
  whichever secondary initrd is loaded." The *hooks* do self-guard — but the
  guard only matters if the hook file exists to be sourced. The missing file
  kills the shell before the hook's first line runs.

## 3. Bisection — five initrds, no ISO needed

`tools/make-mid*.py` carve slices out of the real `initrd.f2fs.gz`
(single-member cpio+gzip archives loaded as secondary initrds on an
otherwise-stock boot) and record each verdict in the script header:

- `empty.gz` (no members) **boots** → the mechanism works, the payload kills.
- `mid.gz` (provision + scrub + ORDER, byte-identical) **panics** → hook/ORDER.
- `mid2.gz` (scrub + ORDER) **panics** → scrub or ORDER.
- `mid3.gz` (ORDER only, 499 bytes) **panics** → ORDER itself.
- `mid4.gz` (ORDER's for-loop half, dot-sources dropped) **boots** → the
  for-loop/case/glob is innocent; the four dot-source lines are guilty.
- `mid5.gz` (same loop + 4x `if [ -e ... ]; then . ...; fi`, still ORDER-only,
  no hook members) **boots** → confirms the diagnosis AND validates the fix
  shape in one shot: a false `[ -e ]` as an `if` condition never triggers
  `set -e`.

mid3 is the surprising one: a 499-byte ORDER with no hooks at all still
panics, because it sources two files that are not there.

## 4. Fix

The guarded form, byte-identical to the booted mid5 ORDER (provision still
before scrub — that ordering is load-bearing, the provision hook creates the
partition the scrub cleans):

```sh
if [ -e /scripts/casper-premount/zz_lsl_hdd_mirror ]; then . /scripts/casper-premount/zz_lsl_hdd_mirror "$@" 2>/dev/null || true; fi
if [ -e /scripts/casper-premount/9990-live-ramclone ]; then . /scripts/casper-premount/9990-live-ramclone "$@" 2>/dev/null || true; fi
if [ -e /scripts/casper-premount/zz_lsl_f2fs_provision ]; then . /scripts/casper-premount/zz_lsl_f2fs_provision "$@" 2>/dev/null || true; fi
if [ -e /scripts/casper-premount/zz_lsl_f2fs_scrub ]; then . /scripts/casper-premount/zz_lsl_f2fs_scrub "$@" 2>/dev/null || true; fi
```

One constant builds all three initrds, so one edit fixes every gz the
installer creates. The installed ORDER (756 bytes) was verified byte-identical
to the booted mid5 ORDER before commit. `build.sh`'s base-initrd path needs no
change: there the hook file always exists beside its ORDER line.

Sticks already written carry the bad ORDER inside their gz files and cannot be
patched in place — reinstalling with a fixed `lslsetup.exe` rewrites the
initrds.

## 5. Regression tests

- **Rust** (`lslfiles.rs`): `order_dot_sources_are_existence_guarded` asserts
  every line containing `. /scripts/` starts with `if [ -e ` (exactly 4 such
  lines). A future bare source fails the build, not a future boot.
- **Shell** (`tests/f2fs-order-prepend.tests.sh`): the Rust-parity greps were
  updated for the new line shape (match `. /scripts/...` anywhere in the line,
  not a leading `. `), and a new check asserts no unguarded dot-source exists
  in the constant.
- **Field proof**: mid5.gz itself — booted on real hardware with the full
  guarded shape and no hook members present.

## 6. Related

- **`WHYFAIL18.md`** — the other "Attempted to kill init": an `exit` inside
  `lsl_wait_for_boot_disk` (before the park guard was armed). Same panic text,
  different layer: fix the hook vs fix the ORDER that sources it.
- **Commit `539da00`** ("Park with diagnostics instead of panicking PID 1") —
  protects the destructive window *inside* the provision hook; orthogonal to
  this (the ORDER kills PID 1 before the hook runs).
- **`DESIGN-F2FS-PERSISTENCE.md` §2.4** — the sourced-vs-executed table. Still
  correct (hooks must be sourced for exports/`return` to reach casper); the
  missing row was "the sourced file must *exist*".
- **`lslfiles.rs` `CASPER_PREMOUNT_ORDER` doc comment** — now records the guard
  requirement so the next hook added to the ORDER gets the `if` form.

## The rule worth keeping

> **A bare `. <file>` under `set -e` is fatal when the file is absent —
> `|| true` does not save it.** (POSIX special-builtin rule; ash implements
> it.) In a sourced ORDER shared across initrds that pack different members,
> every source line must be `if [ -e ... ]; then . ...; fi`. And when one
> constant ships in N artifacts with different contents, the constant must be
> valid for the *intersection* of what they carry, not the union of what it
> names.
