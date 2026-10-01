# WHYFAIL16 — Every build trace is blank: the version is read from a file the stick never gets

Asked 2026-10-01: *"What is the current version of lsl-usb?"*

Short answer: **it is `0.1.0`, and a stick cannot tell you that.** Both places a
booting system looks for its build identity are empty:

```
$ cat /cdrom/lsl-build.txt          # exists, but the version line is blank
                                     # <- nothing here
Built: 2026-09-30 10:57:31 UTC

$ cat /cdrom/VERSION
cat: /cdrom/VERSION: No such file or directory
```

`bin/lsl-diag.sh:75` reads **both** of them:

```sh
echo "=== lsl-build ==="; cat /cdrom/lsl-build.txt 2>/dev/null; echo; cat /cdrom/VERSION 2>/dev/null
```

So the one diagnostic whose job is "which build is failing?" prints an empty
section, on every stick, silently.

---

## 1. The mechanism

`rust9x/lslsetup/src/lslfiles.rs:336-339`:

```rust
    let build_ver = std::fs::read_to_string(format!("{}\\VERSION", bundle_dir))
        .map(|s| s.trim().to_string())
        .unwrap_or_default();
```

`read_to_string` fails when `{bundle_dir}\VERSION` is absent, and
`unwrap_or_default()` turns that failure into **an empty string**. No error, no
warning, no log line. The stamp is then written from that value:

```rust
    let stamp = format!("{}\nBuilt: {}\n", build_ver, chrono_compat_utc());
    let _ = std::fs::write(format!("{}lsl-build.txt", root), stamp);
```

Hence the blank first line in the file above.

## 2. Why `bundle_dir\VERSION` is always absent in the default path

There are two install paths and neither puts a `VERSION` where this code looks:

| path | where VERSION would have to be | reality |
|---|---|---|
| **bundle / Rufus flow** | `<bundle>\VERSION` beside the exe | `build.sh:145` *does* copy it into the bundle — but only for builds that ship a bundle |
| **nofmt** (the default) | `<bundle_dir>\VERSION` | **there is no bundle at all** — `nofmt` works from the exe plus embedded assets, so the file cannot exist |

Measured on the stick that produced the stamp above: the nofmt path was used, and
`/cdrom/VERSION` does not exist. Neither does anything else write one — `VERSION`
appears in exactly one `cp` (`build.sh:145`) and is never among the files
`install_lsl_files` copies to the stick root (the `copied.push(...)` list covers
`filesystem_z0_firstboot.squashfs`, `bin/`, `systemd/`, `initramfs/`, `onboot.sh`,
`lsl-usb.env`, `resolve-powershell.ps1`, the initrds, `lsl-build.txt`,
`md5sum.txt` — not `VERSION`).

So in the default path the version is **structurally unknowable**, not
occasionally missing.

## 3. Why this matters more than a cosmetic blank

`lsl-build.txt` exists *for traceability* — the comment above the code says so:
*"Stamp the build for traceability (captured by lsl-diag.sh on failure)."* The
failure mode it is meant to serve is exactly the one where nobody can attach a
debugger: a stick that boots wrong on someone else's machine, where the first
question is "which build is this and what changed since?".

It currently answers that question with an empty string, and it does so
**quietly**. That is the same defect class as two others documented in this tree:

- **`WHYFAIL15`** — a fix that was committed and then not present in the shipped
  artifact.
- **`fatresize`** (`DESIGN-PERSISTENCE-PANE.md` §9.2) — a tool that exits 0 and
  does nothing.

All three are a *silent* success where the caller has no way to notice. The
`unwrap_or_default()` is the specific mechanism here: it converts "the file I need
is missing" into "the value is empty", which is indistinguishable from a
legitimately empty value.

## 4. What is in effect

| | value | source |
|---|---|---|
| repo `VERSION` | `0.1.0` | `VERSION` |
| `lslsetup` crate | `0.1.0` | `rust9x/lslsetup/Cargo.toml` |
| git | `v0.1.0-112-g6cccb91` | 112 commits past the `v0.1.0` tag |
| **on a stick** | **blank** | `lsl-build.txt` line 1; `/cdrom/VERSION` absent |

There is also **no `--version` flag** on `lslsetup` (`cli.rs` has none), so the exe
cannot be asked either.

## 5. Fix (not implemented)

Three changes, smallest first:

1. **Fall back to the compiled-in version.** `env!("CARGO_PKG_VERSION")` is always
   available and is already `0.1.0` — it needs no file, works in the nofmt path,
   and cannot be empty. This alone fixes the blank line.
2. **Write `VERSION` to the stick root**, so `/cdrom/VERSION` exists for
   `lsl-diag.sh:75` and for a user who looks. It is 7 bytes.
3. **Make the missing-file case visible.** Log it rather than silently defaulting:
   an empty version is a fact worth a line in the log, precisely because the file
   exists to be read during a failure.

Optionally add `--version` to the CLI, which is cheap and makes the exe
self-describing without a stick.

Worth deciding at the same time: whether the stamp should also carry the **git
revision**. `v0.1.0-112-g6cccb91` is far more informative than `0.1.0` for the
"what changed since this stick was made?" question, and `build.rs` could embed it
the way the z0 manifest already pins content hashes.

**Nothing above is in effect.** No code was changed; this document is the finding.

## 6. Not verified

- Whether a *bundle* build (the Rufus flow) currently produces a correct stamp. The
  code path allows it — `build.sh:145` puts `VERSION` in the bundle — but no bundle
  was built here to confirm, and the nofmt path (the default, and the one on the
  stick) cannot.
- Whether anything else consumes `lsl-build.txt`. Grepped: only `lsl-diag.sh:48,75`.

## The rule worth keeping

> **`unwrap_or_default()` on a required file is a silent lie.** It converts "the
> input I depend on is missing" into "the value is empty", and the two are not the
> same thing to whoever reads the output. Use it where empty is a legitimate
> outcome, never where the file's whole purpose is to carry a value.

> **A build stamp that cannot be produced is worse than none.** Its absence is
> invisible — the file exists, the format looks right, the diagnostic runs — so
> nobody investigates. A missing file at least fails loudly. Prefer a value that
> cannot be empty (the compiled-in version) over one that depends on a file being
> staged correctly by every install path.

> **Check the default install path, not the convenient one.** The bundle path could
> work; the nofmt path — the default — structurally cannot. Testing the flow that
> happens to have the file would have hidden this indefinitely.
