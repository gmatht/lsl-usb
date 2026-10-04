# WHYFAIL17 — "kitty won't start": the config was fixed but the .exe still carried the old one

**Date:** 2026-10-01
**Symptom:** kitty does not start. In practice it *does* start and immediately
shows **"Errors parsing configuration"**, which for a user is indistinguishable
from "the terminal is broken".

## 1. Root cause

`misc/kitty.conf` carried an option kitty rejects:

```
tab_powerline_style no      # only angled/round/slanted are valid
```

kitty treats an invalid value as fatal: configuration parsing aborts and the
window never becomes usable.

The fix (removing that line, translating the Windows-Terminal-isms to real kitty
options, `padding_*` -> `window_padding_width`, `active_tab_title_format` ->
`active_tab_title_template`, `zero` -> `0`) is **present in the repo**:

```
$ grep -n 'tab_powerline_style no' misc/kitty.conf
(none)
$ sha256sum misc/kitty.conf
b763e0531ce58bdab8ff8e917276b21f1fb4c1d3330356a2554751be0ebe5d7a
```

That hash **matches** `assets/toolkit_sources.sha256`, so `build.rs` is satisfied
and the embedded copy is correct.

**The bug is that the shipped binary predates the fix:**

```
dist/lslsetup-win95.exe   2026-09-22 05:55
misc/kitty.conf           2026-10-01 02:55    <- 9 days newer
```

`lslsetup.exe` embeds `misc/kitty.conf` via `include_str!` and writes it to the
stick. The committed `.exe` was built **9 days before** the config was fixed, so it
still embeds the fatal version and still ships it. The fix is real but unshipped —
**this is the same class as WHYFAIL13** (every shipped `.exe` embedded a broken
`bin/lsl-pin-favorites` while the fix sat in `bin/`).

## 2. Why it stayed invisible

Three independent silences, all of which had to be defeated:

1. **`install_lsl_kitty_conf` skips quietly.** `config.sh:336` returns 0 with a
   message only if the file is *absent* — an unreadable or stale file is copied
   without comment. A user sees kitty fail, not "config skipped".
2. **`build.rs` cannot see a stale *binary*.** It re-hashes each source in
   `assets/toolkit_sources.sha256` and fails the build on drift — so it guarantees
   the *next* build embeds a current `kitty.conf`. It says nothing about an `.exe`
   that was already built and committed. The guard covers the compile, not the
   artifact.
3. **The fatal value was in a value position, not a typo.** `tab_powerline_style no`
   is a well-formed line naming a real option with an invalid choice, so it survives
   every syntax-level check and only fails inside kitty.

## 3. The test does not catch this either

`toolkit_ships_a_kitty_config_that_parses` asserts against the **embedded source**,
which is correct. It cannot observe the committed `.exe`. So the suite is green
while the shipped artifact is wrong — consistent with the failure being invisible.

Two latent weaknesses in that test, worth recording though not currently biting:

- **It greps raw text including comments.** `padding_left` etc. are checked as bare
  substrings, so a *comment* explaining the migration ("we no longer use
  `padding_left`") would trip the assertion and fail the build for a non-bug. Today
  no such occurrence exists (verified), so it passes for the right reason — but the
  check cannot distinguish an option from a mention of one.
- **It only covers one of the two shipping paths.** `config.sh:126` also
  `cp_to_cdrom`s `misc/kitty.conf` to the stick, and `config.sh:340` installs from
  `$REPO_ROOT`, not `$CDROM`. On a normal boot `REPO_ROOT == /cdrom` so those
  coincide; they diverge when config.sh runs from a repo checkout. Nothing tests
  that the two copies agree.

## 4. Fix

Rebuild and recommit the `.exe` so it embeds the current `misc/kitty.conf`:

```
misc/build-toolkit-manifest.sh      # confirm no drift (already in sync)
cargo build --release               # build.rs re-hashes every toolkit source
```

The source needs no change — `misc/kitty.conf` is already correct and already
matches its manifest hash. **This is a shipping step, not a code change**, which is
why it recurred: nothing in the workflow forces an artifact rebuild when an embedded
source changes.

## 5. The rule worth keeping

> **A passing test on the source is not a statement about the artifact.** Every
> assertion here was green while the shipped `.exe` embedded a config that makes
> kitty refuse to render. When a binary *embeds* its inputs, the unit under test is
> the binary, and nothing was testing it.

> **A guard on the build is not a guard on the release.** `build.rs` fails the build
> if a source drifts — genuinely good, and it did its job. But it cannot fail a
> release that ships a stale `.exe`, because the staleness lives in a file the build
> never reads. Same shape as WHYFAIL13: the fix existed, the path from fix to stick
> did not.

> **"Won't start" deserves to be checked against the log before it is believed.**
> kitty started every time. It printed the reason and exited, and the reason was in
> the config. Reading the error rather than the symptom is what turns an unfixable
> "terminal is broken" into a one-line config fix.
