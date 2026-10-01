# DESIGN NOTE — Boot-to-RAM variants, and the block-layer options for them

**Status:** design note and critique. No code, no promises. Written after reading
the kernel's dm-clone documentation and measuring this live stick; every number
below is from the running system.

**Origin:** a proposal to add three Boot-to-RAM entries once F2FS persistence
exists — *vanilla Mint*, *Mint + firstboot*, and *everything* (firstboot plus a
clone of the F2FS layer via dm-clone, or `tar -cf /dev/null /`, or partclone, to
"fetch all used blocks").

> **STATUS — sections 1-10 were written from documentation and contain several
> claims that testing disproved. §11 records what was measured and supersedes
> them.** Where the two disagree, §11 is correct. In particular: dm-clone *does*
> work with a sparse destination (§11.5), *does* work as a RAM upper (§11.7),
> dm-cache *does* promote on read (§11.10), and the "used data" set *is*
> enumerable, at 0.38 GiB rather than the 4.2 GiB `du` reports (§11.12).

---

## 1. Summary judgement

| part of the proposal | verdict |
|---|---|
| Several Boot-to-RAM variants | **good idea**, and cheaper than it sounds — the menu plumbing already supports N variants |
| "vanilla" vs "+firstboot" split | **workable**, but "vanilla" is the expensive variant, not the cheap one (§3) |
| `dm-clone` the F2FS layer to RAM | **partly works** — the size objection was withdrawn after testing (a *sparse* tmpfs destination costs only what is written, §11.5); what remains is that reads are not copied, so the source must stay attached (§4a, §4c) |
| `dm-clone` in `no_hydration` mode to copy only accessed blocks | **no** — reads are served from the source and not copied; only writes hydrate (§11.1). Confirmed in the driver source: the read branch of `clone_map()` returns before the hydration call, and there is no on-demand message (§11.8). Still makes it a good **scratch** mode: RAM cost tracks bytes written (§11.5) |
| **configure dm-clone to promote on reads** | **not possible** — no option, message, or code path. Reads bypass hydration entirely (§11.8) |
| **trigger hydration explicitly** | **not a thing** — hydration is a *background sweep* over the whole device, started automatically (`do_hydration`, §11.9). You do not trigger it; you either `no_hydration`-disable it or accept a full device copy. Measured: 512 MB copied into RAM in ~2 s with zero application I/O |
| `dm-cache` then pivot the origin to `/dev/zero` | **no** — the cache may be small, but the origin must stay authoritative: a pivot corrupts every non-resident block (§11.2b). And you cannot pre-load by reading, because scans do not promote (§11.10) |
| **user-mode block device (NBD) with promote-on-read + a computed pivot** | **viable — revised in §11.12.** The plumbing exists (`nbd` module; the ioctl is simple). The pivot condition is **computable**: walk the tree, `FIEMAP` each file, skip `UNWRITTEN` extents — implemented, and it enumerated this stick's live data at **0.38 GiB** where `du` reports 4.2 GiB. Detach once every enumerated extent is read. My three objections to this (§11.11) were wrong; see §11.12 |
| **the "used data" figure itself** | **0.38 GiB, not 4.2 GiB** — walk + `FIEMAP` minus `FIEMAP_EXTENT_UNWRITTEN` (`0x800`). Neither `du --apparent-size` (4.2 GiB) nor `du`/`st_blocks` (4.2 GiB) shows this (§11.12) |
| **`dm-cache` as a speed optimisation** | **verified mechanism, fits our problem** — it *does* promote hot blocks on read (`read_promote_level`; measured 187/200 hits on one block) and deliberately skips sequential scans (0/1510). Sits below the filesystem, so it needs no change to the persistence design. Hot F2FS metadata in RAM, cold data on the stick. **Not** a RAM mode — the origin stays attached (§11.10) |
| swap the clone's source to `/dev/zero` to detach the stick | **tested: silently corrupts** — unhydrated regions read as zeros, `dmsetup load` succeeds with no warning, and reading the whole device hydrates nothing (§11.6) |
| **dm-clone over a read-only F2FS as a RAM upper** | **tested: yes, and it is the right tool for the *scratch* variant** — rw-mount a F2FS on the clone, writes land in RAM (28 KB for a text file), source stays byte-identical (§11.7). Does not persist or detach by itself |
| `tar -cf /dev/null /` to "fetch used blocks" | **does not do that**, and never could (§5) — though it *is* a valid page-cache warm, which is probably the actual want (§11.3) |
| partclone → "used blocks only" | **right idea, wrong premise here** — this device reports no discard support (§6) |

The variant idea is worth pursuing. The clone idea is **partly viable and was
tested and read at the source level**:

- §11.5 — a *sparse* tmpfs destination works and costs only the bytes written,
  withdrawing my size objection. dm-clone is a good **scratch/disposable** RAM mode.
- §11.6 — the "swap the source to `/dev/zero`" detach trick **silently corrupts**
  every unhydrated region, and reads cannot pre-hydrate them. Not usable.

- §11.7 — used the other way round (F2FS as the never-written source, RAM as the
  destination), dm-clone is a working **RAM upper**: an rw-mounted F2FS whose
  writes stay in RAM while the source stays byte-identical. That *is* the
  disposable-RAM variant, and it costs only what is written.
- §11.8 — read the driver source: **reads are never promoted**, by design. The
  read branch of `clone_map()` returns before the hydration call, and there is no
  on-demand message. Not a configuration gap — there is nothing to configure.

So: dm-clone is genuinely usable for a **scratch/disposable RAM session**. It does
not persist on its own (no region map to copy back — §11.6) and cannot detach the
stick (needs full hydration).

---

## 2. What Boot to RAM means today

Two entries already exist, generated in `rust9x/lslsetup/src/nofmt.rs:2246-2251`:

```rust
let variants = [
    (format!("{base} (Boot to RAM)"), user_params.clone()),
    (format!("{base} (Boot to RAM, no persistence)"),
     format!("{} lsl_home=tmpfs", user_params)),
];
```

- **"(Boot to RAM)"** — loads the *squashfs layers* into RAM (`ramclone`); `/home`
  still mounts normally, so changes persist.
- **"(Boot to RAM, no persistence)"** — the same, plus `lsl_home=tmpfs`, which
  `bin/lsl-mount-home.sh:119` reads to set `LSL_EPHEMERAL_HOME=1`, giving a RAM
  `/home` so nothing touches `home.sfs`/`home.btrfs`.

So "boot to RAM" already means *the root layers* come from RAM. The proposal
would extend the idea to cover the two other things a boot can choose to keep or
discard: the firstboot step, and the persistent home/upper.

---

## 3. The variant idea — worthwhile, with a naming caveat

A clean three-way split maps onto three independent booleans the boot already
has:

| entry | root layers | firstboot runs | home/upper |
|---|---|---|---|
| Vanilla | RAM (from ISO) | no | tmpfs — discarded |
| Mint + firstboot | RAM (base + z0 stub) | yes | tmpfs — discarded |
| Everything | RAM (base + z0 + appends) | as configured | **F2FS — persistent** |

The caveat is that **"vanilla Mint" is not currently reachable by a menu flag.**
`ramclone` loads whatever layer stack the kernel cmdline globs; skipping the z0
stub is not a matter of a flag but of which layers are named. Two ways:

1. **Skip the stub by not globbing it.** `lsl-firstboot.service` really is in
   the z0 stub (`misc/build-z0.sh:49,61` installs and enables it there), so
   "firstboot does not run" is equivalent to "the stub is not stacked". But this
   is *not* a flag today: casper globs `*.squashfs` and stacks whatever it finds,
   so a stub sitting in `/cdrom/casper` is always stacked. Excluding exactly one
   layer means either
   - reintroducing `layerfs-path=` (naming the wanted leaf) — which WHYFAIL14
     deliberately removed, because it forced a boot-config rewrite on every
     append; or
   - keeping the stub out of `/cdrom/casper` and naming it only from the entries
     that want it — i.e. a second directory and a path parameter;
   - or a cmdline flag firstboot honours (option 2 below).

   So "vanilla" is the *expensive* variant here, not the cheap one. Worth costing
   before promising it.
2. **A cmdline flag that firstboot honours** (`lsl_skip_firstboot=1`), leaving
   the stub stacked. Cheaper, but it stacks a layer whose service then declines
   to run — the "inert layer" smell WHYFAIL14 warns about. Prefer (1).

Also worth deciding up front: **the existing two entries plus three new ones is
five menu items**, and the GRUB/grub4dos menus are already long. If the variants
multiply, a submenu or a single entry with a cmdline editor is kinder. Not a
blocker; a design question for whoever builds this.

---

## 4. dm-clone: what it does and does not do (partly revised in §11.5)

From the kernel documentation (`admin-guide/device-mapper/dm-clone`), verbatim on
the constructor:

```
clone <metadata dev> <destination dev> <source dev> <region size> [...]
```

- **source dev** — "Read only device containing the data that gets cloned"
- **destination dev** — "The destination device, where the source will be cloned"
- **metadata dev** — "Fast device holding the persistent metadata"

### Blockers (one withdrawn after testing — see §11.5)

**(a) dm-clone clones *devices*, not directories.** Our F2FS persistence layer is
a *directory tree* inside a partition:

```
/dev/sdb1  f2fs  mounted at /f2fs     <- the device
/f2fs/ubuntu/...                       <- the layer we actually care about
```

dm-clone has no concept of "clone this subdirectory". You would have to clone the
whole 59 GB partition to get at a 4.9 GB tree.

**(b) ~~The destination must be at least the size of the source.~~ WITHDRAWN.**
The requirement is real — *"The size of the destination device must be at least
equal to the size of the source device"* — but it is a **size** requirement, not
an **allocation** requirement. A sparse file satisfies it at zero cost, and I
verified that dm-clone accepts a sparse tmpfs destination and only consumes RAM
for regions actually written. See §11.5, where this is measured. My original
objection below was wrong:

> ~~A 59 GB destination does not fit in 15 GB of RAM.~~

**(c) dm-clone gives you a RAM write-buffer, not a RAM load.** With
`no_hydration`, reads come from the source and are not copied; only writes hydrate
(§11.1). So a session's RAM footprint tracks what it *writes* — which is a real
and useful property — but the source must stay attached for cold reads, and the
doc's "swap in a linear table" step presumes hydration completed. There is no
"detach the source" step while regions are unhydrated. (This is the objection that
survives §11.5.)

There is also a practical gap: **`dmclone` (the userspace CLI) is not installed**
— only `dmsetup` and the module. The target *can* be driven via `dmsetup create`
(the module loads and the target registers as `clone v1.0.0`), but nothing here
does that today.

### The one piece of dm-clone that *is* relevant

The docs' own example is instructive:

> Mount the device and trim the file system. dm-clone interprets the discards
> sent by the file system and it will not hydrate the unused space.

That is the "only used blocks" idea — but dm-clone gets it from **discard**, not
from reading the filesystem. Which leads directly to §6.

---

## 5. `tar -cf /dev/null /` does not do what is being asked

This one is a misunderstanding worth correcting explicitly, because it sounds
plausible:

- `tar` reads **files**, via the VFS. It never touches a block device.
- It therefore has no way to know which *filesystem blocks* are used, and
  **cannot** "fetch all used blocks". It reads file *contents*.
- It deliberately does not read sparse regions, deleted files, or free space —
  so it is not a superset of "used blocks" either; it is a different set.
- `-cf /dev/null` throws the data away. What it *does* achieve is pulling data
  into the page cache (a warm-cache effect), which is presumably the intent.

If the goal is "make the session's data resident in RAM", the honest tools are:

| goal | tool |
|---|---|
| warm the page cache from files | reading the files (tar to /dev/null *does* work here) |
| **copy** used blocks of a filesystem | `partclone.<fstype>` — reads only allocated blocks |
| clone a block device | `dd`, `dm-clone`, `partclone.dd` |
| know which blocks are unused | the filesystem's own discard/fstrim path |

**`partclone.f2fs` is not installed** (only the `partclone` package exists in the
archive, not on the image), so this would be a new dependency.

---

## 6. The "used blocks only" premise fails on this hardware

This is the finding that matters most, and it was measured, not assumed:

```
$ fstrim -v /f2fs
fstrim: /f2fs: the discard operation is not supported

$ lsblk -D /dev/sdb
NAME   DISC-ALN DISC-GRAN DISC-MAX DISC-ZERO
sdb           0        0B       0B         0

$ findmnt -no OPTIONS /f2fs
rw,relatime,lazytime,background_gc=on,nogc_merge,nodiscard,...
```

The USB device advertises **zero discard support** (`discard_granularity 0B`,
`discard_max_bytes 0`). Consequences:

- **`fstrim` cannot mark free space**, so a filesystem-level "used blocks" map
  cannot be produced by discard on this hardware.
- The mount already carries **`nodiscard`**, so F2FS is not even attempting
  online discard.
- dm-clone's own efficiency argument ("interpret discards, do not hydrate unused
  space") therefore **does not apply here** — with no discard, it would hydrate
  the entire device.
- `partclone.f2fs` would still work, because it parses F2FS metadata directly
  rather than relying on discard — but it copies to *another filesystem*, not
  into RAM as a block device, and it is not installed.

**The general point:** "copy only the used blocks" assumes the storage stack can
tell you which blocks are used. On this USB device, at the block layer, it
cannot. Any design here must either parse the filesystem (partclone-style) or
give up on the optimisation and copy whole devices.

---

## 7. What would actually deliver the intent

The underlying wish seems to be: *"a menu entry that gives me a fully-loaded,
firstboot-complete session that runs from RAM — and optionally lets me keep the
result."* Two designs deliver that; neither is dm-clone.

### Option A — RAM upper with an explicit "commit" action

Closest to the existing architecture and the cheapest to build:

1. Boot with the F2FS upper **not** mounted; mount a tmpfs upper instead (exactly
   what `LSL_EPHEMERAL_HOME=1` already does, `bin/lsl-mount-home.sh:121-137`).
2. Run firstboot as normal.
3. Offer `bin/uphome`-style **commit**: rsync/overlay-merge the tmpfs upper onto
   the F2FS layer, then unmount.

This gives "everything in RAM, keep it only if I say so", with no new kernel
machinery, reusing `uphome` (already the "save my home" path) and the existing
overlay plumbing. The cost is a copy at commit time rather than at boot.

### Option B — a snapshot of the *directory*, not the device

If a pre-loaded RAM session genuinely must be materialised quickly, snapshot the
**tree**, not the block device: `mksquashfs` (already used throughout) or `rsync`
of the F2FS layer's contents. This sidesteps all three dm-clone blockers in §4
because it operates on files, not devices, and its size is the *data* size
(4.9 GB measured) rather than the device size (59 GB).

### Option C — if a block-level clone is really wanted

Then the source must be a **purpose-sized** read-only device, not a shared 59 GB
partition. That means either a dedicated, tightly-sized partition for the
persistent home, or an F2FS *image file* used via loopback (which reintroduces
the FAT32 4 GiB ceiling that WHY_FAIL documents). This is a real design, but it
is a different storage layout from the one in
`DESIGN-F2FS-PERSISTENCE.md`, and it should be evaluated on its own.

**Recommendation:** Option A. It delivers the user-visible behaviour with the
least new machinery, and it composes with the persistence design already written.

---

## 8. Open questions

1. Does "vanilla Mint" mean *without the z0 stub stacked*, or *with the stub
   present but firstboot disabled*? (§3 argues for the former, and it changes
   whether this is a menu change or a service change.)
2. Is the goal RAM *speed* or RAM *disposability*? They suggest different designs
   — a warm cache is enough for one, a tmpfs upper is required for the other.
3. Four variants × (BIOS/UEFI) × (persistent/tmpfs) is starting to be a lot of
   menu. Is a submenu acceptable?
4. Does "everything" mean "firstboot has already been applied to the RAM copy",
   or "run firstboot now"? Those are different boots (one needs a cached result).
5. If Option A is chosen, what is the failure mode when commit fails (USB
   removed, full)? `uphome` already has language for this; it should be reused.

---

## 9. Risks (revised after testing — §11 supersedes the pre-test rows)

| risk | severity | why |
|---|---|---|
| ~~Destination too small~~ | **withdrawn** | tested: a *sparse* tmpfs destination satisfies "dest ≥ source" at zero allocation cost (§11.5) |
| Cloning a directory is not possible | medium | dm-clone operates on block devices only, so the unit is the partition — workable, but coarser than the layer we care about |
| No discard support | medium | "used blocks only" is unavailable *at the block layer*; the filesystem can still enumerate it (§11.12) |
| `dmclone` CLI absent | low | workable via `dmsetup` — done in §11.5/§11.7 |
| Writes land on the destination, not the source | **by design** | with `no_hydration` this is the desired behaviour; the source is never written (§11.7) |
| Background sweep copies the whole device | **high** | without `no_hydration` the destination fills with the entire source at creation — measured 512 MB in ~2 s (§11.9) |
| Pivoting the source away | **fatal** | measured: unhydrated regions read as zeros, silently (§11.6) |
| New dependency (`partclone`) on a live image | low | not present today; not needed given FIEMAP (§11.12) |

---

## 10. Discussion

**What is solid:** the menu plumbing genuinely supports N variants
(`nofmt.rs:2246-2251` builds an array), the RAM-home mechanism already exists
(`lsl_home=tmpfs` → `LSL_EPHEMERAL_HOME`), and the three proposed variants are a
sensible decomposition of "what is kept across a boot". The variant half of the
proposal is a good idea and mostly assembly.

**What is not solid, stated plainly:**

- **`dm-clone` cannot do this**, for three independent reasons that are each
  sufficient on their own (§4). This is a property of the target's interface, not
  a tuning problem.
- **`tar -cf /dev/null /` cannot "fetch used blocks"** — it reads files, and it
  discards what it reads. The idea rests on a category error (§5).
- **The "used blocks" optimisation is unavailable on this hardware** at the block
  layer, because the device advertises no discard support (§6). This was
  measured, and it surprised me.
- **Nothing here has been prototyped.** No variant has been added, no clone has
  been attempted, no commit path has been written.

**The honest summary:** the multi-variant part is worth building and is largely
already plumbed. The clone part needs to be replaced — with a *directory*-level
snapshot or a RAM-upper-plus-commit (§7) — before it is worth spending design
effort on, because as specified the block-level tools cannot express it.

---

## 11. Follow-up: "only accessed blocks" via dm-clone, dm-cache, or a pivot

The question after §4 was: *can dm-clone be told to copy only accessed blocks?
And if not, could dm-cache do it, then pivot the origin to `/dev/zero` once
everything has been read?* Short answers, from the two targets' own
documentation.

### 11.1 dm-clone: it already has the mode, but "accessed" is not what it tracks

`no_hydration` is the closest thing, and it exists:

> **no_hydration** — Create a dm-clone instance with background hydration
> disabled.
>
> A read to a not yet hydrated region is serviced directly from the source
> device. A write to a not yet hydrated region will be delayed until the
> corresponding region has been hydrated and the hydration of the region starts
> immediately.

So the behaviour is:

| event | dm-clone (`no_hydration`) |
|---|---|
| background copy | none |
| **read** of a cold region | served from source, **not copied** |
| **write** to a cold region | forces hydration (copy source→dest), then writes |

**A read does not trigger a copy.** So `no_hydration` gives you
"copy-on-**write**", not "copy-on-**access**" — a session that only reads data
would leave that data on the USB, defeating the point of a RAM boot.

*(Corrected: an earlier draft added "and the destination must be ≥ the source,
which does not fit in RAM". That objection was tested and withdrawn — a sparse
tmpfs destination satisfies the size requirement at zero cost. See §11.5.)*

There is no knob to make reads trigger hydration. The doc's "Known issues" says
as much from the other direction:

> We redirect reads, to not-yet-hydrated regions, to the source device. If
> reading the source device has high latency and the user repeatedly reads from
> the same regions, this behaviour could degrade performance. **We should use
> these reads as hints to hydrate the relevant regions sooner. Currently, we rely
> on the page cache.**

So "reads as hydration hints" is listed as a *future improvement*, not a feature.
**Answer: no, there is no way to tell dm-clone to copy only accessed blocks** —
confirmed at the source level in §11.8 (the read branch of `clone_map()` returns
before reaching the hydration code, and there is no on-demand hydrate message).

### 11.2 dm-cache: the direction is right, the pivot is not

dm-cache's shape *does* match the intuition better than dm-clone's:

> An **origin** device — the big, slow one.
> A **cache** device — the small, fast one.

That is exactly RAM-as-cache over F2FS-as-origin — 16.5 GB cached against 63.3 GB
of origin. But three facts break the pivot plan:

**(a) dm-cache promotes on read — but only for *hot* blocks, never for a scan.**
*Corrected in §11.10 after testing:* there is an explicit `read_promote_level` in
`smq`, and a repeated read of one block does get promoted (measured: 187 hits out
of 200 reads, one 32 KB cache block). What does **not** promote is a sequential
scan — measured 0 promotions across 5 × 8 MB sequential reads. So the conclusion
holds, but for a sharper reason than I first gave: it is not that dm-cache cannot
promote on read, it is that it **deliberately declines to** for exactly the access
pattern a "load everything" pass produces. "Pivot once all blocks are read" still
has no reliable moment.

**(b) The origin must remain authoritative.**
> The origin device always contains a copy of the logical block, which may be out
> of date or kept in sync with the copy on the cache device (depending on policy).

Repointing the origin at `/dev/zero` would make every block that is **not** in the
cache read back as zeros — instant filesystem corruption. There is no
"swap origin and cache" operation; the target has no such message (the documented
messages are policy tuning and `invalidate_cblocks`).

**(c) The cache is explicitly a subset, not a copy.** Even at `writeback`, only
promoted blocks exist on the cache. The cache device is *supposed* to be small;
that is the design — so, unlike `dm-clone`, **dm-cache has no "cache ≥ origin"
requirement**, and my earlier §4 sizing objection does not apply to it (§11.5).

### 11.3 What would actually work — and it is not a device-mapper target

The intent is "load the persistent layer into RAM, then stop needing the stick".
Two mechanisms do that, both already in this tree:

**(i) Page-cache warm (what `tar -cf /dev/null` was reaching for).** Reading the
files pulls them into RAM; the kernel then serves them without touching the USB.
It is not a *guarantee* (the cache can evict under pressure) and it is not a
*disconnect* (the device must stay attached). But it is free, needs no new
machinery, and `bin/lsl-precache.sh` already exists for exactly this.

**(ii) Copy the data into a RAM filesystem.** `cp -a` / `rsync` the F2FS layer
into a tmpfs, remount over it, then the stick can go. Sized by *data* (4.2 GB
measured on this stick), not by device (63.3 GB). This is the honest version of
"boot to RAM everything", and it composes with the RAM-upper-plus-commit design
in §7 Option A.

If a copy is unacceptable at boot time, the remaining option is **`overlayfs` with
a tmpfs upper over the F2FS lower** — i.e. exactly what the current USB mode does
with `home.sfs`, with the F2FS layer as the lower instead of a squashfs. Reads come
from the F2FS (which is already fast — it is the same USB), writes go to RAM, and
"commit" is a `rsync` back. No device-mapper involvement at all.

### 11.4 Why the device-mapper route keeps looking attractive and is not

It promises to make the *block device itself* be the RAM copy, so nothing at the
filesystem layer needs to know. That is genuinely elegant. It fails here on three
concrete points:

| requirement | dm-clone | dm-cache |
|---|---|---|
| copy on **read** | no (reads bypass; writes hydrate) | by policy only, and sequential reads are excluded |
| destination fits RAM | **yes, if sparse** — the ≥source requirement is about addressing, not allocation (§11.5) | yes — cache may be small |
| detach the source afterwards | no (writes need the source for hydration) | **no** — origin must stay authoritative |
| operates on our *directory* | no — block devices only | no — block devices only |

dm-cache gets further than dm-clone (it at least has the right size asymmetry),
but "detach the origin" is not something either target offers, and (c) above means
the pivot would corrupt anything not yet promoted.

### 11.5 Correction, with the idea actually tested: a *sparse* destination makes dm-clone viable

The two challenges — *"it only promotes data actually read, so why 64 GB for 4 GB
of data?"* and *"we can easily have a 64 GB sparse file in RAM with only 4 GB
used"* — are both right, and **the second one is testable, so I tested it.**

#### The test (run on this box, results verbatim)

```sh
# sparse destination + metadata on tmpfs; 64 GB apparent, 0 B actual
truncate -s 64G /dev/shm/d2      # du: 0
truncate -s 4G  /dev/shm/m2      # du: 0
DEST=$(losetup -f --show /dev/shm/d2)
META=$(losetup -f --show /dev/shm/m2)

dmsetup create ct2 --table \
  "0 $(blockdev --getsz /dev/loop6) clone $META $DEST /dev/loop6 8 1 no_hydration"
```

It **accepted the table** — dm-clone does not care that the destination is
sparse, or that it is on tmpfs.

| measurement | result |
|---|---|
| destination apparent size | 64 GB |
| destination **actual** RAM before any write | **0 B** |
| metadata actual RAM | 2.3 MB |
| cold read (region never written) through the clone | **served correctly from the source** — md5 matched the source exactly |
| destination RAM after that read-only pass | **still 0 B** |
| after writing 8 MB at offset 20 GB | 8 MB |
| after writing 16 MB at offset 40 GB | 24 MB |
| metadata after all of the above | 2.3 MB |

So:

- Spareness survives the loop device — writing 1 MB at offset 100 MB allocated
  1 MB, not 100 MB.
- **A read does not allocate destination space**, confirming §11.1's reading of
  the docs, and it is served from the source correctly.
- **Total RAM cost tracks bytes *written*, not device size.** 24 MB written →
  24 MB resident.

**My earlier "63.3 GB does not fit in 16.5 GB of RAM" objection was wrong**, and
so was the framing of §11.5 as merely "the constraint belongs to another target".
The correct statement is stronger: *dm-clone does not need the destination to be
materialised, only sized.* A sparse tmpfs file satisfies the size requirement at
essentially zero cost. The `§4` blocker (b) is withdrawn.

#### What that changes, and what it does not

The remaining facts from §11.1 and §11.2(a) still stand, and they are what limit
the design:

| fact | consequence |
|---|---|
| reads are served from the source and **not** copied (no_hydration) | a read-only pass leaves everything on the USB — no RAM speedup, and the stick cannot be removed |
| a **write** to a cold region hydrates it (copy source→dest, then write) | RAM grows with the *write* set, which is what we want for a writable session |
| destination is a **copy of written regions**, not of the device | the source must stay attached and readable for cold reads |
| the doc's "replace the table with `linear $DEST`" step presumes **hydration completed** | it is not available while regions are unhydrated — so there is no built-in "detach the source" step |
| hydration is region-granular (4 KB here) | a session that rewrites the whole tree costs a full copy anyway |

So the honest characterisation of dm-clone-with-sparse-dest is:

> **A RAM write-buffer over the persistent layer, with the stick still required
> for cold reads.** RAM usage is proportional to bytes written (excellent), and a
> fresh boot starts from the stick's content (correct). It is *not* "load the
> layer into RAM and detach", because reads are not copied and unhydrated regions
> have no other home.

#### Persisting afterwards — the genuinely open problem

If the session is disposable, this design is complete: writes hit RAM, source is
untouched, reboot discards. That is a genuinely nice "Boot to RAM (scratch)"
entry, and it is **cheap**: the destination costs only what is written.

If the session must be *kept*, there is no clean path:

1. **No writeback API.** dm-clone exposes `enable_hydration`/`disable_hydration`,
   `hydration_threshold`, `hydration_batch_size`, and the doc's linear-table swap
   — nothing that means "flush my dirty regions to the source". The source is
   read-only by contract.
2. **`dmsetup suspend` + `linear $DEST`** would work only once every region is
   hydrated — i.e. after a full 64 GB copy, which defeats the sparse trick.
3. **Userspace copy** (`rsync`/`mksquashfs` from a mounted clone, then restore) is
   the only correct route, and at that point the dm-clone layer is doing the work
   of an `overlayfs` upper that the kernel already provides — see §7 Option A.

**Recommendation, revised:** dm-clone-with-sparse-dest is worth prototyping as the
**scratch/disposable** RAM mode — it is simpler than a tmpfs copy and costs only
what is written. For *persistent* RAM sessions, `overlayfs` with a tmpfs upper over
the F2FS lower (§7 Option A) is still the better fit, because it has a natural
commit path (`rsync` back) that dm-clone lacks.

### 11.6 Tested: swapping the source to a zero device corrupts unhydrated regions

The follow-up proposal was: *"can we just swap the backing device with `/dev/zero`
— if `tar /` doesn't touch a block it isn't used, and zeroing it out should be
fine?"*

**Tested on this box. The swap is mechanically possible, but it is not safe, and
the failure is exactly the silent data loss the reasoning assumes away.**

#### Setup

Two regions of a 4 GB source, both readable through the clone:

```
source @10 MB   : 03ee7accb43da013630d6830e2e9f7b6
source @2000 MB : 385b5a2554a633d2c2e5d6a6aba2db35
```

Then hydrate **only** the first (write to it — `no_hydration`, so a write is the
only thing that copies):

```
$ dd if=/dev/zero of=/dev/mapper/ct3 bs=1M count=1 seek=10 conv=notrunc
dest RAM: 1.0M          # exactly the written region
status  : 256/1048576 regions hydrated
```

#### The swap

`/dev/zero` is a **character** device and dm rejects it:

```
device-mapper: reload ioctl on ct3 failed: Block device required
```

So a zero *block* device is needed (here, a loop over a zero-filled sparse file).
Once that is in place the table reload **succeeds** — `dmsetup load` + `resume`,
no error. That is the trap: nothing tells you anything is wrong.

#### The result

```
region @10 MB   (was written, lives in DEST) : b6d81b36... = zeros   <- correct
region @2000 MB (never touched)              : b6d81b36... = zeros   <- WRONG
```

The data at 2000 MB was `385b5a25…` before the swap. Afterwards the clone returns
**zeros** for it. Confirmed with `echo 3 > /proc/sys/vm/drop_caches` and re-read —
not a stale-cache artifact. And the data is still intact in the original source
(`dd if=/dev/loop7 … skip=2000` → `385b5a25…`); it is simply unreachable through
the clone now.

**The filesystem is silently corrupted**: every unhydrated region reads as zeros.
A mounted filesystem would see zeroed metadata and either fail to mount or, worse,
mount with plausible-looking damage.

#### The premise is also wrong: reading does not hydrate

The idea assumed that "touching" the blocks (`tar /`) would pull them into the
destination first, so that afterwards nothing is left unhydrated. Tested directly:

```
read the ENTIRE 4 GB device through the clone:
  4294967296 bytes copied in 1.8 s
status before: 256/1048576 regions hydrated
status after : 256/1048576 regions hydrated      <- UNCHANGED
dest RAM     : 1.0M                              <- UNCHANGED
```

Reading **everything** hydrated **nothing**. This is the same `no_hydration`
semantics from §11.1 — reads are served from the source and never copied. So
"read it all first, then swap" cannot work: there is no sequence of reads that
populates the destination.

#### Why this is the dangerous kind of failure

- `dmsetup load` **succeeds**. There is no I/O error, no warning, no status flag.
- The clone's status line looks identical before and after.
- Reads return plausible zeros rather than failing.
- The loss is only discovered when the filesystem is mounted — after the real
  source has been released/removed.

If the goal is "detach the stick", the swap must be **conditional on full
hydration** (`#hydrated == #total`, which the status line reports as the second
field — `1048576/1048576`), and that only happens after a complete device copy,
which is what the sparse destination was avoiding in the first place.

#### What this leaves

| goal | verdict |
|---|---|
| RAM write-buffer, stick stays attached | **works** (§11.5) — RAM tracks bytes written |
| detach the stick via a zero-source swap | **no** — silently zeroes every unhydrated region, and reads cannot pre-hydrate them |
| detach the stick at all | requires full hydration first — i.e. a complete copy, so use a userspace copy or `overlayfs` instead (§7) |

### 11.7 Tested: yes — dm-clone works as a RAM upper over a read-only F2FS lower

The question was: *"if we never write to the F2FS it is effectively read-only, so
can we use dm-clone?"* — and the answer is **yes**, which is a different result
from everything above. Tested end to end on this box.

#### Why this is a different design from §11.5

§11.5 cloned the F2FS device and got a RAM *write-buffer* whose cold reads came
from the stick. This variation is stronger and simpler, because **the "source" in
this arrangement is the persistent layer, and we never intend to write it during
the session at all**:

```
source  = the F2FS partition / device   (never written; genuinely read-only for this purpose)
dest    = sparse tmpfs (RAM)            (writes land here)
meta    = small file on RAM
result  = a block device you mount rw, whose changes live in RAM
```

#### The test (results verbatim)

```sh
mkfs.f2fs /dev/shm/rof2fs.img                 # a stand-in F2FS
LOOP=$(losetup -f --show /dev/shm/rof2fs.img)

dmsetup create roclone --table \
  "0 $(blockdev --getsz $LOOP) clone $META $DEST $LOOP 8 1 no_hydration"

mount -t f2fs /dev/mapper/roclone /mnt/cloned   # mounts RW
echo hello-from-clone > /mnt/cloned/testfile    # write succeeds
```

| check | result |
|---|---|
| rw-mount a F2FS **on the clone** | **works** |
| write a file | **works** |
| destination RAM consumed | **28 KB** (of a 256 MB device) |
| regions hydrated | 9 → 16 (only the written ones) |
| bytes differing between source and clone | **287** — exactly our file |
| first differing offset | 4194305 (where the file landed) |

So: **writes land in RAM; the source device is byte-identical to before.** That is
a functional "RAM upper over a persistent lower", at the block layer, with RAM
cost proportional to bytes written.

#### Why "read-only" is satisfied here, and why that matters

The earlier objection was that our F2FS is a *directory* on a *shared* partition,
so the source would have to be the whole 63 GB device (§4a). That still holds —
**dm-clone clones devices, so the unit is the partition, not the directory.** But
your point removes the other half of the objection:

- dm-clone's source must not change underneath it. It does not require a
  hardware read-only device — it requires that nothing writes it.
- **We control that**: we simply do not mount the F2FS rw during the session. The
  clone's device is the only thing mounted, and it is the thing the session
  writes.
- Verified: the source device was byte-identical after writes went through.

There is one ordering constraint, measured: **the source must be unmounted while
the clone is created** — `dmsetup create` with the source mounted fails with
`Device or resource busy`. So the sequence is *unmount → clone → mount the clone*,
which is exactly the order a boot-time hook would use anyway.

#### What it does not solve

Everything from §11.6 stands, and it is worth restating because this design looks
so much like a solution:

- **The stick is never updated.** Writes are in RAM. To persist, you must copy
  back — and there is no region map, only a count (the status line's
  `#hydrated/#total`). So persistence is a userspace filesystem copy, at which
  point `overlayfs` with a tmpfs upper does the same job more simply.
- **The zero-source swap still corrupts** (§11.6). Detaching is only safe at full
  hydration.
- **RAM is not free**: 28 KB for a text file is excellent, but a session that
  rewrites the filesystem's metadata heavily will hydrate far more (F2FS
  checkpoints, GC, SIT/NAT — all *inside* the device, all written through the
  clone).
- **`no_hydration` is required, not optional.** Without it the background sweep
  (§11.9) copies the *entire source device* into RAM at creation — measured: a
  512 MB device filled the destination in ~2 s with no application I/O at all.
  The 28 KB result above depends entirely on that feature flag.

#### Verdict

| use | does dm-clone fit? |
|---|---|
| **scratch session** — RAM writes, discard on reboot | **yes, and it is a good fit** — costs only what is written, no userspace copy |
| **persistent session** — keep the changes | **no better than overlayfs** — needs a userspace copy back either way, and overlayfs has a natural one |
| **detach the stick mid-session** | **no** — needs full hydration (§11.6) |

So the answer to *"can we use dm-clone?"* is **yes, for the disposable-RAM
variant** — which is the one place in this whole design space where it is
genuinely the right tool, because "throw the writes away" is exactly what a
device whose destination is RAM and whose source is never written gives you for
free.

### 11.8 Can dm-clone promote on reads? No — verified in the target's source

Short answer: **no, and it is not a configuration gap.** There is no option, no
message, and no code path that hydrates on a read. This is now confirmed from the
driver source, not just the docs.

#### The decision is one `if`/`else if` in `clone_map()`

`drivers/md/dm-clone-target.c` (v6.14), the whole read/write policy:

```c
region_nr = bio_to_region(clone, bio);
if (dm_clone_is_region_hydrated(clone->cmd, region_nr)) {
        remap_and_issue(clone, bio);
        return DM_MAPIO_SUBMITTED;
} else if (bio_data_dir(bio) == READ) {
        remap_to_source(clone, bio);      /* READ -> source, no hydration */
        return DM_MAPIO_REMAPPED;
}

remap_to_dest(clone, bio);
hydrate_bio_region(clone, bio);           /* WRITE -> hydrate */
```

The read branch **returns before** reaching `hydrate_bio_region`. It is not that
reads fail to trigger hydration — reads are routed away from the hydration code
entirely.

#### `hydrate_bio_region` has exactly one call site

```
$ grep -n "hydrate_bio_region" dm-clone-target.c
874:static void hydrate_bio_region(struct clone *clone, struct bio *bio)
1368:	hydrate_bio_region(clone, bio);
```

Line 1368 is the write path above. The other `hydration_copy()` call (line 1006)
is inside `__batch_hydration()` — the *background* sweep, which copies regions
sequentially and has nothing to do with I/O.

#### And there is no on-demand message

The complete `clone_message()` set is:

```
enable_hydration | disable_hydration | hydration_threshold | hydration_batch_size
```

— four knobs, all about the *background* sweep. Nothing like
`hydrate_region <n>`. So you cannot even ask for a region to be promoted from
userspace after noticing it was read.

#### The full configuration surface, for completeness

| layer | option | effect on read-promotion |
|---|---|---|
| create-time feature | `no_hydration` | stops the background sweep |
| create-time feature | `no_discard_passdown` | discards only |
| core args | `hydration_threshold`, `hydration_batch_size` | background sweep tuning |
| module param | `clone_hydration_throttle` (100) | background percentage |
| messages | the four above | background sweep control |
| **anything** | — | **nothing promotes on read** |

#### What this means for the design

The consequence is the one already recorded in §11.1, now on firm ground:

- **Reads are never copied.** A read-heavy session keeps its working set on the
  USB. The page cache may hide this (that is the doc's "we rely on the page
  cache"), but the *destination* stays empty — verified in §11.6, where reading
  the entire 4 GB device hydrated 0 regions.
- **Therefore the stick cannot be detached** on a read-only workload, and
  "prime it by reading everything first" cannot work.
- **But the write path is exactly what a writable session wants**: RAM grows with
  what you *change*, and everything else stays on the stick. That is §11.7's
  result, and it is the useful mode.

If genuine read-promotion is wanted, dm-clone is the wrong target — `dm-cache`
does promote on read, but by *policy*, not by "whatever was touched" (§11.2).

### 11.9 How hydration is *actually* triggered: a background sweep, not demand

The question — *"how are we meant to trigger hydration if not by reads?"* — exposes
that §11.8 answered the wrong half. I described what does **not** trigger hydration
(reads). The actual trigger is a **sequential background sweep that needs no
trigger at all**, and it was in the source I had already fetched.

#### The mechanism (`do_hydration()`, dm-clone-target.c:1061)

```c
offset = clone->hydration_offset;
while (likely(!test_bit(DM_CLONE_HYDRATION_SUSPENDED, &clone->flags)) &&
       !atomic_read(&clone->ios_in_flight) &&
       test_bit(DM_CLONE_HYDRATION_ENABLED, &clone->flags) &&
       offset < nr_regions) {
        current_volume = atomic_read(&clone->hydrations_in_flight);
        current_volume += batch.nr_batched_regions;
        if (current_volume > READ_ONCE(clone->hydration_threshold))
                break;
        offset = __start_next_hydration(clone, offset, &batch);
}
...
if (offset >= nr_regions) offset = 0;    /* wrap: it walks the WHOLE device */
clone->hydration_offset = offset;
```

Read plainly:

- It starts at `hydration_offset` and walks regions **in order**, batching
  adjacent ones.
- `hydration_threshold` paces **concurrently in-flight** hydrations, not the total
  volume — so it is a rate limiter, not an extent.
- It **wraps to 0** and keeps going until every region is done. There is no
  "hydrate this region" entry point; the sweep is the only mechanism.
- It **pauses** while application I/O is in flight (`!ios_in_flight`) and resumes
  from `do_waker`, a 1-second delayed work item (`COMMIT_PERIOD HZ`).

So hydration is **push**, not pull: the target copies the device to the
destination in the background unless you turn it off. Reads and writes are
irrelevant to *whether* it happens.

#### Measured (512 MB device, 4 KB regions)

| mode | activity | time | destination RAM |
|---|---|---|---|
| default (sweep enabled) | **none** — no application I/O at all | ~2 s | **512 MB — fully copied** |
| `no_hydration` | none | 3 s+ | **0 B** |

The first row is the answer to the question: with the default feature set, you do
not trigger hydration. It runs on its own, immediately, and copies everything.
`no_hydration` is what *stops* it.

#### Why this reframes the whole section

This is the missing piece that makes the earlier results coherent:

| behaviour | why |
|---|---|
| a plain read does not hydrate | the read branch of `clone_map()` bypasses hydration (§11.8) — but the **sweep** will get to that region anyway, eventually |
| `no_hydration` never copies anything | the sweep is the *only* copier; disable it and nothing else can trigger a copy |
| writes hydrate | `hydrate_bio_region()` is the one **synchronous, on-demand** path, so a cold write cannot wait for the sweep to arrive |
| the sparse-destination test (§11.5) needed `no_hydration` | without it the sweep would have filled the 64 GB destination and defeated the sparseness |
| reading the whole device hydrated 0 regions (§11.6) | consistent — reads do not hydrate, and that instance was `no_hydration` |

#### What it means for our design

There are exactly **two** copy policies, and they are the whole choice:

| | `no_hydration` | default (sweep) |
|---|---|---|
| background copy | none | copies the entire device |
| RAM cost | bytes **written** | size of the **device** |
| first cold write | copies that one region first | likely already copied |
| fits a RAM budget | yes — proportional to change | only if the device fits in RAM |
| our use | **the RAM-upper mode** (§11.7) | pointless for us — it is just "copy the F2FS into RAM at boot", which a `cp`/`rsync` does more cheaply and without device-mapper |

So for the writable-scratch variant, `no_hydration` is not an optimisation — it is
**required**, and §11.7's result (28 KB for a text file) depends on it. With the
default, the same test would have consumed the full partition size in RAM the
instant the target was created.

The middle ground one might want — "copy on read, never in the background" — does
not exist in this target. That is the honest answer to "how do we trigger
hydration": **you do not trigger it; you either disable it or accept the full
background copy.**

### 11.10 dm-cache revisited: it *does* promote on read — measured, and the condition is the point

§11.2 dismissed dm-cache partly on the claim that "promotion is policy-driven, and
sequential full reads are what the policies exclude." That claim is half right, and
the half I got wrong matters. Tested properly:

#### Read-promotion happens — from the source

`dm-cache-policy-smq.c`:

```c
static enum promote_result should_promote(struct smq_policy *mq, struct entry *hs_e,
                                          int data_dir, bool fast_promote)
{
        if (data_dir == WRITE) {
                if (!allocator_empty(&mq->cache_alloc) && fast_promote)
                        return PROMOTE_TEMPORARY;
                return maybe_promote(hs_e->level >= mq->write_promote_level);
        } else
                return maybe_promote(hs_e->level >= mq->read_promote_level);
}
```

There is an explicit **`read_promote_level`**, and the read branch consults it. So
dm-cache promotes on read *by design* — unlike dm-clone, which bypasses hydration
entirely (§11.8). The condition is that the block's hotspot **level** has climbed
to the threshold, i.e. the block is *repeatedly* accessed.

#### Measured

Same dm-cache target both times (256 MB origin, 64 MB RAM cache, 32 KB blocks,
`smq`):

| workload | read hits | read misses | promotions | cache used |
|---|---|---|---|---|
| **200 reads of the *same* 32 KB block** | **187** | 1593 | **1** | 16/4096 = 32 KB |
| 5 × sequential scan of 8 MB | 0 | 1510 | 0 | 0 |

The first row is the answer: after one miss, 187 subsequent reads were **hits**,
and one cache block (32 KB) held the hot data. **dm-cache promotes on read.**

The second row is the half of my §11.2 claim that was right: a sequential scan
promotes **nothing**. That is smq's design — it separates sequential streams from
random access precisely so a backup or a `cat` does not evict the working set.

#### What this actually means

| question | answer |
|---|---|
| Does dm-cache promote on read? | **Yes** — `read_promote_level`, measured (187/200 hits) |
| Does reading *everything* promote everything? | **No** — sequential streams are excluded by design (0/1510) |
| So can "read it all then detach" work? | **No** — and now for a *better* reason than before: it is not that dm-cache fails to promote, it is that it deliberately declines to, for exactly the access pattern a "load everything" pass produces |

So §11.2(a) should be restated: dm-cache promotes on read **only for hot blocks**.
The design implication is unchanged (you cannot use it to load a device into RAM),
but the mechanism is different from what I wrote, and the difference matters if
anyone ever wants a *speed* optimisation rather than a load-everything feature.

#### And the pivot is still dead

The other half of §11.2 stands untouched, and it is the substantive objection:

> The origin device always contains a copy of the logical block.

dm-cache is a **cache**, not a snapshot. It writes dirty blocks back to the origin
and requires the origin to stay authoritative and attached. Repointing the origin
at `/dev/zero` corrupts every non-resident block — the same failure measured for
dm-clone in §11.6.

#### Where dm-cache is genuinely useful for us

Because read-promotion works, dm-cache is a credible **speed** option that is now
worth stating concretely:

- **hot F2FS metadata in RAM, cold data on the stick.** F2FS rewrites its SIT/NAT/
  SSA and checkpoint packs constantly; those are small, repeatedly accessed, and
  exactly the shape smq promotes. The cache could hold a few hundred MB of them
  and cut USB traffic substantially.
- **It requires no change to the persistence design.** dm-cache sits *below* the
  filesystem: mount F2FS on the cache device, and everything above is unchanged.
- **It is not a RAM mode.** The origin must stay attached, dirty blocks must be
  written back, and cold reads still hit the USB. It makes the USB faster; it does
  not remove the USB.

That is a different goal from the Boot-to-RAM variants this document is about, and
it is the one place dm-cache fits.

### 11.11 User-mode block device (NBD/CUSE) with promote-on-read and a pivot

The proposal: *a user-mode block device we control, which promotes the regions it
actually reads into RAM, and which we pivot away from once it has finished reading
the used data.*

This is the most promising of the block-layer ideas, and it differs from
dm-clone/dm-cache in one way that matters — but the hard part is not the plumbing.

#### What is available (checked on this box)

| piece | status | note |
|---|---|---|
| `nbd` kernel module | present, loadable | `/dev/nbd0` appears; `nbds_max` default 16 |
| `qemu-nbd` | present | serves a *pre-existing file*; not programmable |
| `nbd-client` | **absent** | but the kernel side is a simple ioctl (`NBD_SET_SOCK`/`NBD_DO_IT`), drivable from any language |
| `cuse` module | present | character devices only — not usable for a block device |
| `fuse` | in `/proc/filesystems` | filesystem-level, a different (and easier) design — §7 Option A |

So part (a) — a programmable block device — is genuinely available. **A prototype
was attempted and abandoned**: driving NBD's negotiation by hand from a shell
session proved fragile in this environment, and per §11.11's own rule the *design*
question does not need a working prototype to answer. The plumbing is the easy part
and is not where this design succeeds or fails.

#### Why the pivot is easier here than for dm-clone — and why that is not enough

dm-clone and dm-cache pivot by **swapping a table** (`dmsetup load` a `linear`
table). Between the swap and the next access, an unhydrated region has no data
source, which is exactly the silent-zeroing failure measured in §11.6.

A user-mode server has strictly better properties, because it stays in the loop:

- it can **decline to pivot** until it has confirmed its own state;
- it can keep serving un-promoted regions from the backing file *after* a
  "pivot", because the pivot is its own internal decision, not a kernel table;
- it can **fail loudly** (`EIO`) on a region it cannot serve, rather than
  returning zeros.

That is a real improvement over both kernel targets. But it does not solve the
binding problem:

> **A block device cannot know when it has read "all the used data".**

It sees sector offsets. It does not see:

1. **which sectors are live vs free** — that is filesystem metadata, one layer up;
2. **when the filesystem has finished** — there is no "done" event, and files are
   opened lazily (a config file read at hour three is indistinguishable from one
   never read);
3. **which regions are needed later** — pages can be evicted from the page cache
   and re-read, so "already read" does not mean "will not be read again".

So a pivot conditioned on "everything used has been read" is conditioned on a fact
the device cannot observe. Tracked heuristically (e.g. "the reads have gone quiet"),
it is the same class of bug as §11.6: a decision made on an assumption rather than
a verifiable precondition.

#### The resolution: do not pivot — remove the *file* from the critical path

There is a version of this design that is correct, and it drops the pivot entirely.

The stated goal is presumably "the session no longer depends on the USB". That does
not require detaching a device — it requires that **the backing store the server
reads from is itself in RAM**. Then:

- the server promotes on read (part b, which works);
- regions it has not read are still served — but from a RAM copy of the backing
  file, not from the USB;
- there is no pivot, no table swap, no "are we done" question, and therefore no
  silent-corruption failure mode;
- the USB can be removed once the *copy* completes, which is a state the system can
  actually observe (`sync` finished, file sizes match).

Measured size for that copy on this stick: **4.2 GB** (`/f2fs/ubuntu`) against
16.5 GB of RAM. Data-sized, not device-sized — the same distinction that decided
§11.5.

Which leads somewhere worth saying plainly:

**If the backing is already a RAM copy, the block device is not needed at all.**
The design collapses into §7 Option A — a tmpfs copy (or an `overlayfs` tmpfs upper
over the F2FS lower), which is simpler, has a natural commit path, and needs no
NBD server, no ioctl plumbing, and no promote tracking.

#### What the user-mode device *would* be good for

The promotion machinery is not wasted; it is just aimed at a different goal:

| goal | does the user-mode device help? |
|---|---|
| remove the USB from the working path | **indirectly — but a straight copy does it better and simpler** |
| **reduce USB read traffic on a large dataset** | **yes** — promote-on-read is exactly a demand-paged cache, and unlike dm-cache's smq we control the policy (no sequential-scan exclusion) |
| a dataset too large to fit in RAM | **yes** — this is the case where "copy it all" fails and demand paging wins |
| detach the stick safely | no — needs the copy, at which point the device is unnecessary |

So the honest summary: a user-mode promote-on-read block device is a legitimate
**paging/caching** design for a dataset that does not fit in RAM, and it is more
controllable than dm-cache. It is **not** a route to a detachable RAM session,
because the detach condition is unobservable from that layer — and where the data
*does* fit in RAM, copying it directly is simpler than any of this.

> **SUPERSEDED — see §11.12.** All three claims in the paragraph above (and the
> eviction argument, and the "copy is simpler" claim) are wrong. The used set *is*
> enumerable (walk + `FIEMAP`), "booted to RAM" means nothing can evict, and a
> copy *does* hold up the boot. The pivot condition is computable and the design is
> viable.

#### Why the prototype was abandoned rather than debugged

Recorded because it is the kind of thing worth being honest about: the NBD
negotiation was driven by hand, the kernel accepted the socket, and the device
sized to 0. Rather than spend the session debugging a hand-rolled NBD server, the
design question was answered analytically — and the analysis shows the prototype
would have proved nothing that changes the conclusion, because **part (a) was never
the uncertainty.** The uncertainty was part (c), and that is a question about what a
block layer can observe, not about whether NBD connects.

### 11.12 Correction: I was wrong on all three counts — and the enumeration works

The objection was to three claims in §11.11. Checking them properly:

> "page-cache eviction means 'read once' ≠ 'never read again'"

**Wrong.** If the session is booted to RAM — a tmpfs upper, no swap — there is
nothing to evict *to*. Pages read into RAM stay in RAM. The page-cache argument
was imported from a disk-backed context where it does not apply.

> "a straight copy does it better"

**Wrong**, for the reason given: **a copy holds up the boot**. Copying 4.2 GB (or
however much is actually live) before the session starts is a boot-time stall. The
whole appeal of the promote-on-read design is that the session starts immediately
and the data arrives as it is used.

> "once `tar /` has read the used pages, it should be safe to detach"

**Wrong in my reasoning, right in the conclusion** — and this is the important one.
I claimed a block layer cannot know which regions are *used*. It cannot **at the
block layer**, but that is the wrong place to ask. The **filesystem** knows, and
enumerates it directly.

#### Enumerating used data properly (implemented and run)

Walk the tree, `FIEMAP` each file, take the extents. On this stick:

```
files mapped : 2541 (skipped 1)
used blocks  : 98,355
used bytes   : 402,862,080 (0.38 GiB)
```

`FIEMAP` **works on F2FS**. An earlier note of mine said it failed — that was wrong
too: `filefrag /etc/hostname` failed because `/etc` is on the *overlay*, which has
no physical mapping. On the F2FS mount it works:

```
$ filefrag -v /f2fs/ubuntu/fio-test.fio
Filesystem type is: f2f52010
 ext:     logical_offset:        physical_offset: length:   expected: flags:
   0:        0..     833:  400691564.. 400692397:    834:             last,not_aligned,inline,eof
```

#### And it found something neither `du` nor `st_blocks` shows

The four 1 GB fio files report:

| measure | value |
|---|---|
| `st_size` (apparent) | 1.000 GiB |
| `st_blocks` (allocated) | 1.001 GiB |
| **FIEMAP extents that hold data** | **fio-test.0.0: 0.134 GiB, fio-test.2.0: 0.017 GiB** |

The difference is `FIEMAP_EXTENT_UNWRITTEN` (flag `0x800`) — *"space allocated, but
not written"*. F2FS allocated a gigabyte of block addresses for a sparse write and
never put data in most of them. Those regions read as zeros and **do not need to be
copied**.

So "used data" has three plausible meanings and only the third is what a
read-the-used-data plan wants:

| meaning | this stick | source |
|---|---|---|
| apparent size | 4.2 GiB | `du --apparent-size` |
| allocated blocks | 4.2 GiB | `du` / `st_blocks` |
| **blocks holding data** | **0.38 GiB** | walk + FIEMAP, minus `UNWRITTEN` |

That is an order of magnitude the other two measures do not reveal, and it is
exactly the number such a design needs.

#### What this means for the proposal

The design becomes coherent, and my §11.11 rejection does not stand:

1. **Enumerate** the used-data extents (walk + FIEMAP, skip `UNWRITTEN`).
2. **Read exactly those** into RAM — a bounded, finishable operation, not "wait and
   hope the session touches everything".
3. **Detach** once every enumerated extent has been read. That is a *verifiable
   precondition*, which is what §11.11 said was missing — it was missing from the
   block layer, not from the system.

The remaining engineering questions are real but ordinary: what about files created
or written during the session (those must be persisted separately, or the session
is RAM-only by intent); what about extents that change underneath; and the
enumeration must run against a **quiesced** filesystem or it races the writer.

So: **the user-mode block device is viable, and the pivot condition is
computable.** My three objections were one wrong (eviction), one wrong (copy
blocks the boot), and one right-in-conclusion-but-wrong-in-reason (the used set is
knowable — just not from the block layer).

### 11.13 Summary

| question | answer |
|---|---|
| Can dm-clone copy only accessed blocks? | **No.** `no_hydration` skips background copy, but reads still come from the source; only writes hydrate. "Reads as hydration hints" is listed as a *future* improvement in the kernel docs. |
| Can dm-cache do it, then pivot to `/dev/zero`? | **No.** The origin must stay authoritative; repointing it corrupts every non-promoted block. Promotion is policy-driven and excludes the sequential reads a "load everything" pass generates. |
| Is there any dm target that does copy-on-access-then-detach? | Not among those available (`clone v1.0.0`, `mirror`, `striped`, `linear`, `error`). |
| What actually works? | Filesystem-level: page-cache warm (`lsl-precache.sh`), tmpfs copy (4.2 GB, data-sized), or overlay-with-tmpfs-upper over the F2FS lower. |

## The rule worth keeping

> **A cache copies what it decides to; it does not copy what you hope it will.**
> Both block-layer answers here fail on the same point: `dm-clone` hydrates on
> *write*, not on read, and `dm-cache` promotes by *policy*, which deliberately
> excludes the sequential full-read a "load everything" pass produces. Wanting a
> device-mapper target to mean "copy whatever gets touched, then detach the
> source" is asking for a semantic neither target implements — and "detach the
> source" is impossible for both, because each requires its source to stay
> authoritative.

> **A constraint is only an argument against the target that has it.** I used
> dm-clone's "dest ≥ source" to dismiss dm-cache, whose cache device is *designed*
> to be small. Carrying a rule across targets is how a correct fact becomes a
> wrong conclusion — and here it became two: §11.5 then showed even dm-clone is
> fine with a sparse destination.

> **"Requires N GB" and "allocates N GB" are different claims — test the
> second.** I rejected dm-clone three times on size: first "the destination must
> be ≥ 63 GB", then "63 GB does not fit in RAM", then "that is dm-clone's problem
> not dm-cache's". A sparse tmpfs file is 64 GB by `stat` and 0 B by `du`, and
> dm-clone takes it happily — a write of 8 MB at offset 20 GB allocated 8 MB.
> Reading the requirement was not enough; it took five minutes at a shell to
> discover the requirement is about *addressing*, not *storage*.

> **A silent-success operation is more dangerous than a failing one.** Swapping
> dm-clone's source to a zero block device: `dmsetup load` returns success, the
> status line is unchanged, reads return plausible zeros, and every unhydrated
> region is gone. The correct design move is to check the **condition** the swap
> depends on — `#hydrated == #total` in the status line — not to trust that the
> reload succeeded. If the operation cannot fail loudly, assert the precondition
> explicitly.

> **"Touching" data and "copying" data are different operations.** The zero-swap
> plan assumed reads would pull blocks into the destination first. Measured:
> reading the entire device hydrated **nothing** (256/1048576 regions before and
> after). A design that depends on a side effect must verify the side effect
> happens — the page cache being warm is not the destination being populated.

> **Ask the layer that has the answer.** I argued three times that "which regions
> are used" is unknowable — because a *block device* cannot know it. True, and
> irrelevant: the **filesystem** knows, and `FIEMAP` exposes it per file. The
> question was never unanswerable, only unanswerable *where I was looking*. When a
> design seems to require information no layer has, check the layer above before
> concluding the design is impossible.

> **`du` measures allocation, not data.** On this stick the same tree is 4.2 GiB by
> `du` and `du --apparent-size`, and **0.38 GiB** of extents that actually hold
> bytes — the rest is `FIEMAP_EXTENT_UNWRITTEN`. Any design about "copying the used
> data" has to pick the right one of those three, and the difference here is more
> than 10x.

> **Before building the mechanism, check the mechanism is the uncertainty.**
> I started hand-rolling an NBD server to test this proposal, got a socket bound
> and a device sized to 0, and stopped. The parts that were failing (negotiation
> plumbing) were never in doubt — and the part that decides the design ("can the
> device know when it has read everything used?") is a question about what a block
> layer can *observe*, answerable by reasoning. Prototyping the easy part is a way
> of avoiding the hard question.

> **A pivot needs a precondition you can verify, not one you can hope for.** All
> three block-layer proposals now fail on the same point: the moment to switch away
> from the backing store is defined by information that layer does not have (which
> regions are live, when the filesystem is finished, whether a page will be needed
> again). Where a correct condition does exist — "the copy completed" — the copy is
> the whole solution and the switching machinery is unnecessary.

> **A policy that declines to act is not a policy that cannot act.** I wrote off
> dm-cache's read-promotion as "policy-driven, and scans are excluded" — collapsing
> two different facts. The policy *does* promote on read; it declines for one
> access pattern. The distinction decides whether dm-cache is useless for our
> problem or a plausible speed optimisation, and it took one targeted test
> (200 reads of a single block: 187 hits) to find out. Test the behaviour you are
> using to reject something.

> **Ask what *starts* an operation, not just what it reacts to.** Having
> established that reads do not hydrate, I answered "can we promote on reads?" and
> stopped — leaving the obvious follow-on ("so what does?") unasked. The answer was
> in the same file: a background sweep that needs no trigger at all and copies the
> entire device. Two questions were needed, and I only asked one. When told a
> mechanism *doesn't* fire on some event, the next question is always what it
> fires on.

> **"Is there an option for X?" is answered by the source, not the summary.**
> The docs described read-passthrough as a *Known issue* with a note that reads
> "should" be hydration hints someday — which reads like an unimplemented
> optimisation. The `clone_map()` function shows it is stronger than that: reads
> are routed *away* from the hydration path, and no message can request one. Ten
> minutes reading one function settled a question three rounds of documentation
> reading could not.

> **A constraint can often be satisfied by the arrangement rather than the
> hardware.** dm-clone's source must be "read-only". I read that as *the device
> must be read-only*, which our F2FS on a shared partition is not — and dismissed
> the whole approach. It actually means *nothing writes it*, which we control by
> simply not mounting it rw: clone the device, mount the **clone** rw, and the
> source stays byte-identical (verified: 287 differing bytes, all ours). Check
> whether a requirement is a property of the device or of the usage.

> **Check the interface of the tool before designing around it.** `dm-clone`
> clones *block devices* — so a *directory* cannot be selected, and that part of
> the objection survives. Its sparse-copy efficiency comes from *discard*, which
> this device does not report (§6). The size objection did **not** survive
> testing. Two of three mismatches were real; the third was mine.

> **"Only the used blocks" presumes the layer can tell you which those are.**
> Here the block layer cannot (no discard support). Measure the premise before
> building on it.

> **`tar -cf /dev/null` measures nothing about a filesystem.** It reads file
> contents and throws them away. It is a cache-warming trick, not an
> allocation-aware copy — worth stating once so it is not proposed again.
