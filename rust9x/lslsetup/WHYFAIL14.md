# WHYFAIL14 — Reading upstream casper first: `layerfs-path` is real, and the dot-walk is upstream's design

Asked 2026-09-30, during an audit of WHYFAIL13 that wandered into layer naming.
This document exists because **I got it wrong first**, and the correction is the
useful part.

I asserted that the nested `filesystem.z0.<ts>` layer names were "never a
design" — an invented scheme, defended by comments, that should be replaced by
plain alphabetical stacking. I then fetched upstream casper's `scripts/casper`
and found **every one of those claims was false**. `layerfs-path=` is real
upstream, it is parsed in `parse_cmdline()`, and the dot-suffix upward walk is
upstream's own multi-layer mechanism. The repo's design is upstream's design.

The one real defect I found before checking upstream survives the correction,
and it is a good one. It is in §5.

---

## 1. The mistake, and what corrected it

The claim rested on two repo documents that looked authoritative:

| where | what it said |
|---|---|
| `VALIDATION.md:23-29` | casper globs `filesystem*.squashfs`, stacks lexically, greatest on top — "VERIFIED against `linuxmint-22.3-cinnamon-64bit.iso`" |
| `CHANGELOG.md:58-64`, `bin/uproot:298-305` | casper stacks **only the chain the cmdline NAMES**, stripping dot-suffixes upward from `layerfs-path=` |

I treated these as contradictory and picked the first, concluding the second was
a hallucination. Both are true. They describe **two different branches of the
same script**:

```sh
# Multi-layer filesystem
if [ -n "$LAYERFS_PATH" ]; then
    ...
    parent_layer_name=${layer_name%.*}
    if [ "${parent_layer_name}" = "${layer_name}" ]; then
        break
    fi
    layer_name=${parent_layer_name}
done
...
# Non multi-layer cases
else
    for image_type in "ext2" "squashfs" "dir" ; do
        for image in "${image_directory}"/*."${image_type}"; do
```

`layerfs-path` set → dot-walk. Unset → alphabetical glob. The repo sets
`layerfs-path`, so the dot-walk branch is what runs, and the documented
behaviour is the documented behaviour.

**The generalisable error:** I had the consumer's source in reach and reasoned
from second-hand comments instead. Three Markdown files agreeing with each other
is not evidence when they may all descend from the same unverified note —
exactly the failure §8 warns about. Fetch it.

---

## 2. What the dot-walk actually does, traced

`setup_overlay()` takes `LAYERFS_PATH`, splits it into directory / stem /
extension, then repeatedly strips the last dot-segment, accumulating layers
**prepended** (so the deepest ends up topmost in `lowerdir`):

```
LAYERFS_PATH=/cdrom/casper/filesystem.z0.20260921085616.squashfs

  filesystem.z0.20260921085616.squashfs   <- named (top of overlay)
  filesystem.z0.squashfs                  <- parent, stripped
  filesystem.squashfs                     <- parent, stripped; no dot -> break
```

Three consequences, all load-bearing:

1. **Every layer in the walk must exist**, or casper panics:
   `panic "File system layers are missing:${layer_err})"`. That is the source of
   the `File system layers are missing` brick in `CHANGELOG.md:120-133` — and
   it is real, upstream behaviour, not a self-inflicted fiction.
2. **The name must contain dots to reach anything.** Traced:
   `filesystem_z0_firstboot.squashfs` has no dot, so `parent == name` and the
   walk breaks after one layer — the overlay gets a layer with no `/sbin/init`,
   and the boot drops to an initramfs shell. This is precisely what
   `bin/uproot:298-305` says, and it is correct. **The underscore name can
   never be a multi-layer entry point.**
3. Therefore the dotted names are **required by the mechanism**, not decorative.

---

## 3. Why "just sort alphabetically" cannot replace it

This was the core of my bad recommendation, and it fails for a mechanical reason.

In the alphabetical branch, the glob is `*.squashfs` and casper prepends each
match, so the **lexically-greatest lands on top**. Measured:

```
 1  filesystem.squashfs                     base
 2  filesystem.z0.<ts>.squashfs             appended layer   <- sorts BELOW the stub
 3  filesystem.z0.squashfs                  firstboot stub
```

`'.' = 0x2E` < `'s' = 0x73`, so `filesystem.z0.2026…` sorts *before*
`filesystem.z0.squashfs`. Under alphabetical stacking the appended layer is
**buried beneath the stub it is supposed to override**. The dotted names do not
merely fail to help — under a glob they invert the stack.

So dropping `layerfs-path=` would require renaming to `filesystem_z<ts>.squashfs`
*and* removing the dotted twin *and* inverting the stub's ordinal. That is a
real, viable alternative — and it is a **rewrite of the boot contract**, not a
simplification. It trades the dot-walk for lexical order, and in exchange gets
alphabetical fragility as the only ordering invariant: under a glob there is no
`panic` if a layer is missing, it just silently stacks whatever it finds.

**On renaming the stub to `filesystem.0`:** under a glob this sorts *below* the
base (`'0' = 0x30` < `'s' = 0x73`), burying the stub under the distro image. It
is not a fix for either scheme. Under the dot-walk it is meaningless — the
ordinal is never read; only dot-segment structure is.

---

## 4. The filename-length cost is real, and inherent

Point 3 above means each additional layer in the stack **must** add another dot
segment, because that segment is the only thing the walk can strip:

```
filesystem.z0.<ts1>.squashfs                      28 chars
filesystem.z0.<ts1>.<ts2>.squashfs               43 chars
filesystem.z0.<ts1>.<ts2>.<ts3>.squashfs         58 chars
filesystem.z0.<ts1>.<ts2>.<ts3>.<ts4>.squashfs   73 chars
```

+15 characters and one more 761 MB blob per append. Measured worst case on this
stick: five layers, 3.6 GB (WHYFAIL7 §2). This is the genuine ergonomic price
of upstream's design, and it is **not** avoidable while using the dot-walk — the
name length is the chain depth. Worth knowing before anyone tries to shorten it.

---

## 5. The one real defect: stem selection is lexical where it must be structural

`bin/uproot:307` picks which chain to extend:

```sh
prev="$(ls -1 /cdrom/casper/filesystem.z0.*.squashfs 2>/dev/null | sort | tail -n1)"
if [ -n "$prev" ]; then
    stem="$(basename "${prev%.squashfs}")"
fi
layer="/cdrom/casper/${stem}.${ts}.squashfs"
```

On a **single-link** chain this is correct — the glob requires a non-empty
segment between `z0.` and `.squashfs`, so `filesystem.z0.squashfs` (the stub) is
**excluded**. Verified: with only the stub plus one appended layer on disk, the
glob matches the appended layer alone and `tail -n1` returns it. The stub cannot
be selected by accident.

On a **multi-link** chain it is wrong. The deepest link sorts *lowest*, because
a longer name extending a prefix is compared at the next character and `'2'`
(0x32) < `'s'` (0x73):

```
 1  filesystem.z0.20260921085616.20260930120000.squashfs   dots=3  <- correct stem
 2  filesystem.z0.20260921085616.squashfs                  dots=2  <- tail -n1 picks THIS
```

`tail -n1` returns the shallower link. The new layer is then appended as a
**dot-sibling** of it rather than an extension, so casper's walk never reaches
it — the layer is inert on the very boot it was created for, and the previous
chain is orphaned. This reproduces the WHYFAIL7 "five inert layers" state from
a different cause, and it is the mechanism that fills a stick with 761 MB dead
weight.

Selection must be **structural**: pick the file with the greatest number of dot
segments (tie-break lexically), not the lexically greatest.

This is untested. `tests/lsl-common.tests.sh` has seven prune regressions but
none cover multi-link chain selection, which is why it survived.

**Severity, stated honestly:** on the common path — one stub plus one appended
layer — this code is correct, and every successful first boot in WHYFAIL7's
evidence used it. The bug needs a **second** append on a stick that already
carries a one-link chain. That is the third boot after a re-image, not a routine
run, which is why it can sit unnoticed.

---

## 6. Second real defect: a wrong comment in the HDD-mirror hook

`initramfs/lsl_hdd_mirror.sh:9` states:

> casper's layer discovery reads LAYERFS_PATH (**an absolute dir holding the
> layers**)

and lines 92-93 do:

```sh
ADOPT="$sfs/filesystem.z0.squashfs"
export LAYERFS_PATH="$ADOPT"
```

I flagged this as "a file where a directory is required" — **wrong**. Upstream
treats `LAYERFS_PATH` as a layer *file* path (it splits on the last `/` and the
last `.`), and explicitly supports a relative path resolved against the image
directory. **The code is correct; the comment is the defect.** It should be
rewritten to describe the dot-walk contract, because a reader who believes it
will "fix" working code.

---

## 7. Claims I checked and withdrew

- *"`tests/casper-layer-check.sh:42` is a tautology."* **False** — it compares
  two different names and passes meaningfully.
- *"`VALIDATION.md:27` states the invariant wrongly."* **False** — `'0' < '2'`,
  so `filesystem_z0_firstboot` < `filesystem_z<ts>` is right.
- *"The appended layer sorts below the stub it should stack on."* **True, and
  fatal — but only under the glob branch**, which this repo does not use. It
  becomes true the moment `layerfs-path=` is dropped.
- *"`LAYERFS_PATH` is a file where a directory is required."* **False** (§6).

---

## 8. What was changed anyway (2026-09-30, after this document)

The dot-walk is **load-bearing and correct**, but it was bought at a price: a
filename that grows 15 characters per layer, a boot config that must be
rewritten on every append, and two failure modes that only exist because a
layer is *named* rather than *ordered*. A deliberate decision was taken to move
the normal boot path to casper's glob branch and keep the filename as the sole
carrier of layer order. This section records what that means, because the
rationale in §1-§7 argues against it.

**Normal boots** (`boot=casper`, no `layerfs-path=`) now use the glob branch:

| rank | name | role |
|---|---|---|
| 1 | `filesystem.squashfs` | base |
| 2 | `filesystem_z0_firstboot.squashfs` | first-boot stub |
| 3+ | `filesystem_z<ts>.squashfs` | appends, newest last |

**What was removed**

- `layerfs-path=` from every menu template in `nofmt.rs` (8 sites) and its tests
  inverted to assert its absence.
- The dotted twin `filesystem.z0.squashfs` — `lslfiles.rs` now writes exactly
  one stub name. That twin existed *only* to be nameable by `layerfs-path=`, and
  under a glob it sorted into the wrong slot.
- `active_layer_path()` (replaced by `latest_append_layer()`, which asks "which
  layer sorts highest" — the same question casper asks).
- Chain extension in `write_append_layer()`: no `stem`, no `prev`, no inherited
  name. The new layer is just `filesystem_z<ts>.squashfs`.
- `repoint_layerfs_refs()` no longer repoints. It is kept as a shim for
  mid-upgrade sticks and now **strips** a stale `layerfs-path=`, which would
  otherwise panic casper with "File system layers are missing".

**What was kept, and why it is now different**

The HDD mirror still uses `LAYERFS_PATH`, because it must: casper's glob branch
reads `<mountpoint>/<LIVE_MEDIA_PATH>/*.squashfs`, and `mountpoint` is a casper
script variable (`/cdrom`) that a premount hook cannot repoint. `LAYERFS_PATH`
is the only input that accepts an absolute layer path on another device.

But a dot-free name resolves to exactly ONE layer — there is no chain left to
walk — so the mirror layer must be self-contained. `bin/lsl-copy-sfs-hdd.sh`
therefore now **overlays every layer into one** `filesystem_zmerged.squashfs`
and refuses to publish it unless the merged tree contains `/sbin/init`. The
initrd hook verifies that file and points `LAYERFS_PATH` at it.

`initramfs/lsl_liveboot_mirror.sh` is unaffected: live-boot (Debian) really does
scan block devices, so it keeps the separate layers and `LIVE_MEDIA_PATH=sfs`.

**Defects fixed on the way**

- The prune glob `filesystem_z[0-9]*` also matched `filesystem_z0_firstboot`
  and **deleted the stub** — caught by the new tests, fixed by pinning the
  14-digit timestamp width everywhere. This is the trap worth remembering: a
  loose glob over layer names will eventually eat the one layer that is not
  an append.
- `sort | tail -n1` as "which layer is newest" (§5) is gone; `latest_append_layer`
  compares basenames explicitly.

**Verified:** `cargo +rust9x test` 105 passed / 0 failed; `bash tests/lsl-common.tests.sh`
78 passed; `tests/casper-layer-check.sh` 6 passed (with a negative control);
`bash tests/mount_all.tests.sh` 9 passed; `bats tests/bash.tests.bats` 130 passed.
One pre-existing unrelated failure remains (`lsl-btrfs-growd: honors
LSL_BTRFS_GROW_INTERVAL_SEC`, from the `lsl_effective_home_is_hdd` change in
this session's other work).

**Not verified:** no real boot. The merge path, the ramclone glob branch, and
the mirror hook's behaviour on a live stick all need hardware or QEMU.

## 9. TL;DR

Both casper branches are real: `layerfs-path=` selects a dot-suffix upward walk
with a `panic` on a missing layer, and its absence selects a lexical glob. The
old design used the dot-walk, which is why the names had to be nested and why a
boot config had to be rewritten on every append — and why two of its own failure
modes (inert layers, a pruned live chain) existed at all.

The change moves normal boots to the glob branch, where layer order is carried
by the filename alone, and keeps `LAYERFS_PATH` only for the HDD mirror, where
it is the sole mechanism that can root off `/cdrom`. §5 and §6 record the two
real defects that were live in the old scheme; §7 records the claims that
measurement disproved.

## The rule worth keeping

> **Fetch the consumer's source before you call a design wrong.**
> I overturned a confident, well-evidenced, entirely wrong recommendation by
> reading 60 lines of `scripts/casper` that were one fetch away. Three
> Markdown files agreeing is not corroboration when they may share one
> unverified ancestor.
>
> Two follow-ons this change earned the hard way:
>
> 1. **A name you must rewrite in a boot config is a design smell**, even when
>    the mechanism is upstream's own. If order can live in the filename, it
>    should.
> 2. **A loose glob over "all the things of kind X" will eventually match the
>    one X that is special.** `filesystem_z[0-9]*` matched the firstboot stub
>    and the prune deleted it. Pin the discriminating characters — the 14-digit
>    timestamp width — and test that the special case survives.