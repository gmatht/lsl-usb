# RULES — the engineering lessons, collected

**What this is.** Every WHYFAIL and design document in this tree ends with a
"rule worth keeping" — the generalisable lesson, separated from the incident that
produced it. They are useful individually and more useful together, because the
same mistake keeps reappearing in different clothes. This file collects them so
they can be read in one place, and so the next person does not have to find them
scattered across nine documents.

**Status:** reference only. The rules are the *conclusions*; each cites the
document that carries the evidence. **Where a rule and a document disagree, the
document is authoritative** — several of the rules below are corrections of the
first answer given, and the documents record both.

**Count:** the source documents carry 69 rule blocks; the **53 collected here** are
those with a generalisable lesson (status notices and superseded-by markers are
dropped). Sources: `WHYFAIL5/6/7/9/11/12/17` (repo root), `WHYFAIL13/14/15/16`
(`rust9x/lslsetup/`), `DESIGN-F2FS-PERSISTENCE`, `DESIGN-PERSISTENCE-PANE`,
`DESIGN-BOOT-TO-RAM-VARIANTS`, `DESIGN-SNAP-PERSISTENCE`, `FINDINGS-COMPRESSION`,
`FRAGILE_HOME`.

---

## 1. Measurement — test the premise, not the documentation

These came from a single long session that got the *same class* of thing wrong
repeatedly: reasoning from a specification instead of running it.

> **A tool's help text and its accepted input are different things.** `mksquashfs`
> says `1 .. 9` for `-Xcompression-level` and happily takes 22, passing it to
> libzstd whose real range is 1–19 (+`--ultra` to 22). Reading only the help would
> have said "22 is a bug"; testing said "22 works and is pointless".
> — `FINDINGS-COMPRESSION.md`

> **"Requires N GB" and "allocates N GB" are different claims — test the second.**
> dm-clone's destination must be ≥ the source (63 GB). A sparse tmpfs file is 64 GB
> by `stat` and 0 B by `du`, and dm-clone takes it happily; a write of 8 MB at
> offset 20 GB allocated 8 MB. The requirement is about *addressing*, not storage.
> — `DESIGN-BOOT-TO-RAM-VARIANTS.md` §11.5

> **Ask the layer that has the answer.** "Which regions are used" is unknowable
> from a *block device* — and knowable from the *filesystem*, via `FIEMAP`. The
> question was never unanswerable, only unanswerable where I was looking.
> — §11.12

> **`du` measures allocation, not data.** The same tree is 4.2 GiB by `du` and
> `du --apparent-size`, and **0.38 GiB** of extents that actually hold bytes — the
> rest is `FIEMAP_EXTENT_UNWRITTEN`. More than 10× apart. — §11.12

> **"Is there an option for X?" is answered by the source, not the summary.** The
> docs described read-passthrough as a *Known issue* with a "should someday" note,
> which reads like an unimplemented optimisation. `clone_map()` shows reads are
> routed *away* from the hydration path and no message can request one.
> — §11.8

> **Check the tool works before putting it in a plan.** `fatresize` is the
> purpose-built tool for "shrink FAT32 from Linux"; it is packaged, and it
> **silently does nothing** (exit 0, banner only, BPB unchanged, nonsense sizes
> accepted). It sat in the design as the fallback for three drafts. Installing and
> running it took ten minutes. — `DESIGN-PERSISTENCE-PANE.md` §9.2

> **A policy that declines to act is not a policy that cannot act.** dm-cache
> "policy-driven promotion" was read as "won't work"; the policy *does* promote on
> read (measured 187/200 hits on one block) and merely declines for sequential
> scans. — `DESIGN-BOOT-TO-RAM-VARIANTS.md` §11.10

> **Measure on the content you ship, not a payload you built.** The synthetic
> sweep showed an 11 % saving for level 9→19; real layer content showed 6 %.
> — `FINDINGS-COMPRESSION.md`

> **`tar -cf /dev/null` measures nothing about a filesystem.** It reads file
> contents and throws them away. It is a cache-warming trick, not an
> allocation-aware copy. — `DESIGN-BOOT-TO-RAM-VARIANTS.md` §5

> **"Touching" data and "copying" data are different operations.** The zero-swap
> plan assumed reads would pull blocks into the destination first. Measured:
> reading the entire 4 GB device hydrated **nothing**. A design that depends on a
> side effect must verify the side effect happens.
> — §11.6

> **"Only the used blocks" presumes the layer can tell you which those are.** Here
> the block layer cannot (no discard support — `DISC-GRAN 0B`). Measure the premise
> before building on it. — §6

---

## 2. Reading the tool — interfaces, constraints, and what they actually mean

> **Check the interface of the tool before designing around it.** dm-clone clones
> *block devices*, so a *directory* cannot be selected. Two of three objections
> were real; the third was mine. — `DESIGN-BOOT-TO-RAM-VARIANTS.md` §4

> **A constraint is only an argument against the target that has it.** dm-clone's
> "dest ≥ source" was used to dismiss dm-cache, whose cache device is *designed* to
> be small. Carrying a rule across targets is how a correct fact becomes a wrong
> conclusion. — §11.5

> **A constraint can often be satisfied by the arrangement rather than the
> hardware.** dm-clone's source must be "read-only" — read as *the device must be*,
> which our shared F2FS is not. It means *nothing writes it*, which we control by
> not mounting it rw: clone the device, mount the **clone** rw, source stays
> byte-identical. — §11.7

> **A cache copies what it decides to; it does not copy what you hope it will.**
> dm-clone hydrates on *write*; dm-cache promotes by *policy*. Wanting either to
> mean "copy whatever gets touched, then detach the source" asks for a semantic
> neither implements. — §11.10 (rule) and §11.1

> **Ask what *starts* an operation, not just what it reacts to.** Having
> established reads do not hydrate, the obvious follow-on — "so what does?" — went
> unasked. It was in the same file: a background sweep that needs no trigger.
> — §11.9

> **"The filesystem supports it" and "the platform's tools do it" are different
> claims.** Windows will not shrink *or* extend FAT32 (Disk Management greys it
> out; `diskpart` says *"the file system does not support it"*), while third-party
> tools resize FAT32 freely. The limitation is in Microsoft's tooling.
> — `DESIGN-PERSISTENCE-PANE.md` §9.2

> **A constraint is a fact about the field, not about the world.** "FAT32 caps at
> 32 GB" was true of every Windows in the field, and stopped being true of Insider
> builds in April 2026 — CLI only, Explorer still enforcing the old limit. Encode
> it as a default that can be probed, not an invariant.
> — `DESIGN-PERSISTENCE-PANE.md` §2.4

---

## 3. Failure modes — the dangerous ones are quiet

> **A silent-success operation is more dangerous than a failing one.** Swapping
> dm-clone's source to a zero block device: `dmsetup load` returns success, the
> status line is unchanged, reads return plausible zeros, and every unhydrated
> region is gone. Assert the precondition, do not trust the reload.
> — `DESIGN-BOOT-TO-RAM-VARIANTS.md` §11.6

> **A partition shrink is not a filesystem shrink.** `sfdisk` will cut the
> partition to 200 MB while the FAT inside still claims 536 MB — and the result
> **mounts successfully**, failing only on access past the boundary. Exit 0 from
> the partitioning tool says nothing about whether the data survived.
> — `DESIGN-PERSISTENCE-PANE.md` §9.2

> **A pivot needs a precondition you can verify, not one you can hope for.** All
> three block-layer proposals failed on the same point: the moment to switch away
> from the backing store is defined by information that layer does not have.
> — `DESIGN-BOOT-TO-RAM-VARIANTS.md` §11.11

> **A speed option that silently does nothing is worse than no option.**
> `eatmydata` only helps if `libeatmydata.so` actually loads — not guaranteed
> across a chroot with a different architecture, which is exactly what `uproot`
> does. Verify the preload took effect. — `DESIGN-PERSISTENCE-PANE.md` §2.8

> **Before building the mechanism, check the mechanism is the uncertainty.** NBD
> negotiation was failing; NBD connecting was never in doubt. Prototyping the easy
> part is a way of avoiding the hard question.
> — `DESIGN-BOOT-TO-RAM-VARIANTS.md` §11.11

> **Find the precedent before inventing the mechanism.** Flatpaks had this exact
> problem — gigabytes of app data that must not go into a 4 GiB-capped layer — and
> the tree already solved it by keeping the bulk on FAT and publishing only a
> three-line config. The *principle* transfers to snaps even though flatpak's
> `--installation` mechanism does not. — `DESIGN-SNAP-PERSISTENCE.md`

> **A comment describing a capability is not the capability.**
> `squashfs_config.sh:104` says the installer "can preload .snap files onto the USB
> (`/cdrom/snaps/`)". It cannot — nothing writes that directory and nothing installs
> from it. The comment is an intent that was never implemented, and it reads as a
> description of working code. — `DESIGN-SNAP-PERSISTENCE.md`

> **Check the filesystem can represent what you are storing.** FAT cannot hold
> symlinks or ownership; snapd's state needs both. The capacity question ("is there
> room?") is the one people ask; the representability question ("can this
> filesystem express it?") is the one that decides. — `DESIGN-SNAP-PERSISTENCE.md`

> **`unwrap_or_default()` on a required file is a silent lie.** It converts "the
> input I depend on is missing" into "the value is empty", and the two are not the
> same thing to whoever reads the output. The build stamp on every shipped stick
> has a blank version line for exactly this reason. Use it where empty is a
> legitimate outcome, never where the file's whole purpose is to carry a value.
> — `rust9x/lslsetup/WHYFAIL16.md`

> **A build stamp that cannot be produced is worse than none.** Its absence is
> invisible — the file exists, the format looks right, the diagnostic runs — so
> nobody investigates. Prefer a value that cannot be empty (the compiled-in
> version) over one that depends on a file being staged correctly by every install
> path. — `WHYFAIL16.md`

> **Check the default install path, not the convenient one.** The bundle path could
> produce a version; the nofmt path — the default — structurally cannot. Testing
> the flow that happens to have the file would have hidden this indefinitely.
> — `WHYFAIL16.md`

> **An identifier that is assigned at mount time is not an identifier.** The drive
> letter is chosen in Windows and acted on in Linux, and can change in between. Use
> what travels with the media — volume serial, label, MBR signature, the installer's
> own marker file. — `DESIGN-PERSISTENCE-PANE.md` §9.2b

---

## 4. Persistence — snapshot, identity, and the upper

> **A layer is a snapshot, so machine identity becomes machine state.** An
> exclusion list chosen for *size* will never catch a problem about *identity*.
> Before persisting a path, ask what else that directory describes — `/etc`
> describes the machine, not the user. — `WHYFAIL12.md`

> **Scrubbing an upper unmasks the lower — you must regenerate, not just delete.**
> `rm upper/etc/hostname` reveals the previous image's copy. Every scrubbed path
> needs a per-boot regenerator. — `WHYFAIL12.md` §6

> **Never write machine identity to a persistent filesystem.** Masking afterwards
> is strictly weaker: it makes the file *unreadable or empty* rather than
> *correct*. — `WHYFAIL12.md` §6

> **Check whether you are the thing you are blaming.** The initrd was dismissed as
> something that "mounts `/` before any script of ours runs". We *build* that
> initrd and already inject hooks into `scripts/casper-premount`.
> — `WHYFAIL12.md` §6

> **A progress percentage is not a lifecycle event.** `100` does not mean "done"
> and does not mean "close the window". The renderer must be told, by an event it
> actually honours. — `WHYFAIL13.md` (referenced from `WHYFAIL12`)

> **`include_str!` protects the rebuild, not the artifact.** A source-embedded
> file makes "edit and rebuild" correct and makes "ship the binary you built last
> week" silently wrong. Every `lslsetup.exe` on the box embedded a stale copy of a
> fixed script. **Pin the bytes, not the path** — the release must be able to say
> *which* revision its bytes came from. — `rust9x/lslsetup/WHYFAIL15.md`

> **`gsettings get` prints an `as` array on one line; split on commas.** A
> line-oriented loop over a comma-delimited value does not fail loudly - it
> produces exactly one token, the whole list, and every write-back makes the
> damage permanent (the Cinnamon panel lost every pinned app this way). When the
> format is declarative, parse the declaration. — `WHYFAIL17.md`

> **A prediction is not a record.** `FRAGILE_HOME.md` — the three ways this tree
> answers "is `/home` persistent?", and why a fresh resolve must never override what
> was actually done. — `FRAGILE_HOME.md`

> **A name you must rewrite in a boot config is a design smell.** If order can live
> in the filename, it should. — `WHYFAIL14.md`

> **A loose glob over "all the things of kind X" will eventually match the one X
> that is special.** `filesystem_z[0-9]*` matched the firstboot stub and the prune
> deleted it. — `WHYFAIL14.md`

> **Fetch the consumer's source before you call a design wrong.**
> `layerfs-path=` was real upstream, parsed in `parse_cmdline()`, and the
> dot-suffix walk was upstream's own mechanism. — `WHYFAIL14.md`

> **Never invent a username.** `[ -n "$u" ] || u="mint"` turned "there is no
> desktop user in this context" into "write to `/home/mint`".
> — `bin/lsl-common.sh` / `WHYFAIL13.md`

---

## 5. Consent, safety, and not being clever

> **The safest destructive control is the one that does not exist.** "Erase this
> stick" was in the design for three revisions; when the requirement it served was
> solved another way, the right move was deletion, not a louder warning label. A
> feature that exists to serve a requirement will outlive that requirement unless
> someone checks. — `DESIGN-PERSISTENCE-PANE.md` §2.6

> **Consent is per-action, and a checkbox is not a waiver.** Ticking "erase this
> stick" authorises erasing that stick — not installing extra software, and not
> making a destructive prank acceptable. **Formatting a user's drive is not funny.**
> — `DESIGN-PERSISTENCE-PANE.md` §2.8

> **Enabling a utility means enabling that utility.** The `eatmydata` option sets
> one environment variable for two install steps. If enabling it has any other
> observable effect — an unrequested package, a disk write, a network call — that
> is a defect by definition. **Do not implement malware.**
> — `DESIGN-PERSISTENCE-PANE.md` §2.8

> **Name controls after what they do to the user's data.** "EatMyData" was borrowed
> from a real package that *speeds writes up*, and used for a checkbox meaning
> *destroy the disk* — an inversion that also made the genuine `eatmydata` option
> unnameable. — `DESIGN-PERSISTENCE-PANE.md` §2.6

> **Match the confirmation affordance to the surface.** The console's `type OK`
> idiom was reused for a GUI checkbox. Typing defeats muscle memory at a terminal;
> in a window it is just friction. Reusing a pattern from the wrong surface is not
> reuse. — `DESIGN-PERSISTENCE-PANE.md` §2.6

> **Size the safe part from what must fit in it, not from a round number.** The FAT
> partition does not need 32 GB; it needs the base layer plus the kernel plus slack.
> — `DESIGN-PERSISTENCE-PANE.md` §4

---

## 6. Process — how to keep the above from being relearned

> **A rule worth keeping belongs in a document, not in a session.** These 56 rules
> were scattered across nine files until this one existed. If you finish an
> investigation and the only place the lesson lives is your summary, it will be
> relearned by the next person — usually by making the same mistake.

> **Record what was *withdrawn*, not just what was concluded.** Every design
> document here marks its superseded sections in place (`§11.5`, `§11.12`,
> `§2.6`) rather than quietly rewriting them. The wrong answer is often the more
> instructive half — and it is the half that tells a future reader why the
> remaining answer is trusted.

> **Say what is not in effect.** `WHYFAIL` documents carry an explicit "what is
> NOT yet in effect" section: fixes that live in the repo but not on a booting
> stick, and conclusions that were never tested. `DESIGN-*` documents carry an
> equivalent. Without it, a reader cannot tell a verified claim from a plausible
> one — which is how the `fatresize` fallback survived three drafts.

---

## Index of source documents

| document | what it holds |
|---|---|
| `WHYFAIL5/6/7/9/11/12.md` | live-boot post-mortems: symptom, evidence, cause, fix, what is not yet in effect |
| `WHYFAIL17.md` | **the panel lost every pinned app (kitty included)** — `gsettings get` prints an `as` array on one line, and a line-wise parse collapsed the whole favorites list into one unresolvable entry |
| `rust9x/lslsetup/WHYFAIL13.md` | the zenity/`100`-sentinel post-mortem — **note: a second WHYFAIL series lives in this subtree** |
| `rust9x/lslsetup/WHYFAIL14.md` | casper layer naming: `layerfs-path=` and the dot-walk |
| `rust9x/lslsetup/WHYFAIL16.md` | **every build trace is blank** — the version is read from a file the nofmt path never puts on the stick, and `unwrap_or_default()` hides it |
| `rust9x/lslsetup/WHYFAIL15.md` | **the fix was in `bin/`, but every shipped exe embedded the old copy** — `include_str!` protects the rebuild, not the artifact |
| `FRAGILE_HOME.md` | every call site that asks "is `/home` persistent?" and the risk each carries |
| `DESIGN-F2FS-PERSISTENCE.md` | persisting `/home` on F2FS: provisioning, the identity scrub, regenerators |
| `DESIGN-PERSISTENCE-PANE.md` | the wizard page that would drive it |
| `DESIGN-BOOT-TO-RAM-VARIANTS.md` | Boot-to-RAM variants and every block-layer option; §11 supersedes §1–10 |
| `FINDINGS-COMPRESSION.md` | the six `mksquashfs` call sites and what levels actually buy |

### Known documentation gaps

Found while assembling this file. Recording them rather than leaving them to be
rediscovered.

**1. There are two WHYFAIL series, and the index only knew about one.** The root
holds `WHYFAIL5/6/7/9/11/12/17`; `rust9x/lslsetup/` holds `WHYFAIL13/14/15/16`.
Nothing in either `README` says so, so the numbering looks like it has holes
(1–4, 8, 10 are absent from *both*) when the real structure is one series split
across two directories.

**2. `WHYFAIL8.md` and `WHYFAIL10.md` are cited but exist nowhere.**
`CHANGELOG.md:422` says *"see `WHYFAIL8.md` — not yet written"* for the zenity
`--auto-close`/SIGPIPE bug; `WHYFAIL10` is cited from `CHANGELOG.md:371,378,389`
for the z0-blob freshness work, and `build.rs:59,115` refers to it too. The rule
attributed to `WHYFAIL8` in this file is taken from the CHANGELOG, not from a
primary write-up, because there isn't one.

**3. `WHYFAIL3.md` is cited but absent** — `WHYFAIL5.md:31,83` refers to it for
the "stamp-gate" pattern in `lsl-firstboot.service`.

**4. Numbering has unexplained gaps** (1–4, 8, 10) with no record of whether those
numbers were used and the files removed, or never used. A line in `README.md`
would stop the sequence being mistaken for a gap in coverage.

**5. Until this change, `README.md`'s post-mortem index skipped `WHYFAIL5/6/11/12`
entirely** — a reader following the index would have missed the two most recent
post-mortems. Now fixed, but it drifted for months without anyone noticing, which
is itself the point of a rule: **an index nobody validates is a list of
assumptions.**

**6. `WHYFAIL15` is directly load-bearing for anything that changes an embedded
file — including this session's `misc/kitty.conf` change.** It found that every
built `lslsetup.exe` on the box (`target/debug`,
`target/i586-rust9x-windows-msvc/{debug,release}`, `dist/lslsetup-win95.exe`)
embedded a **stale** copy of `bin/lsl-pin-favorites`, so the fix was committed and
the shipped binaries still carried the bug. The same applies to the kitty config:
there are exes dated Sep 22–29 that predate the Oct 1 fix, and a stick built from
any of them ships the old, non-parsing `kitty.conf`. **`include_str!` protects the
rebuild, not the artifact** — a rebuild is required before any of this reaches a
stick.
