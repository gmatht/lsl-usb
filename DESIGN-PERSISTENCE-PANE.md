# DESIGN — Persistence pane

**Status: BACKEND SELECTION IMPLEMENTED 2026-10-01; the other controls are not.**
Built: the backend radio (all four backends), a trackbar size slider, and the
cache-on-tmpfs policy, at page 4 between "system" and "wifi". `INSTALL_PAGE`
moved 5 → 6. The settings reach Linux through `LSL_PERSIST` /
`LSL_HOME_BTRFS_MIB` / `LSL_CACHE_TMPFS` in `lsl-usb.env`, and the matching
`--persist` / `--persist-mib` / `--cache-tmpfs` flags exist so the FINISHED page's
command line reproduces them.

> **A GUI page can pass every unit test and still be visibly broken.** The first
> build of this pane did: its items were absent from `relayout()`'s `pages` array,
> so they never passed through `layout_page()` and kept the raw builder geometry —
> including the negative widths that mean "fill the width" everywhere else in the
> file. The "Persistence space:" label simply did not render. No test asserted on
> page layout, and the crate's tests run headless, so nothing caught it; it was
> found by launching the wizard. **Adding a page means adding it to `pages` as
> well as to `show_page()` — the two lists are separate and only one of them
> controls whether the controls are positioned.**

**Not built, deliberately:**

- **§2.2 random-write capability check.** Not implemented. It is the least-proven
  control in this design and there is **no calibrated threshold** — the document's
  own recommendation is "ship advisory-only, and calibrate before it does
  anything else", and there is nothing to calibrate against yet. A wrong threshold
  turns away a working stick, so shipping it uncalibrated would be worse than
  shipping nothing.
- **§2.8 `eatmydata`.** Not implemented, and the hard constraint in §2.8 stands
  if it ever is: it enables `libeatmydata` and **nothing else** — never
  partitioning, formatting, erasing, or any disk write. §2.6 removed the only
  control that could have given a destructive "prank" somewhere to hide.
- **§2.3-2.4 the space slider proper.** Built as a **trackbar** (the Win32
  slider, in comctl32 and therefore available on Windows 95) stepping 1–64 GiB.
  What it is *not* yet is the design's continuous FAT/persistence **split**:
  there is no stick-size probe in this pane, and one cannot be added until the
  selected target's size is known — which only happens on the INSTALL page,
  after this one. So the slider is a bounded size chooser, and the binding limit
  (FAT32's 4 GiB single-file cap on a btrfs image) is stated in the label rather
  than discovered at write time.
- **An earlier draft used a combo box**, on the stated grounds that the vendored
  `nwg` had no slider. That was wrong: `nwg` exports `TrackBar`, and it is the
  Win32 control this design wanted all along. Corrected.

**Related:** `DESIGN-F2FS-PERSISTENCE.md` (the scrub/regenerate mechanism this pane
drives), `DESIGN-BOOT-TO-RAM-VARIANTS.md` §11 (what the block layer can and
cannot do), `WHYFAIL12.md` (why identity files must be scrubbed), `FINDINGS-COMPRESSION.md`
(compression levels, not covered here).

---

## 1. Where it fits

### 1.1 Today's wizard

Six pages (`gui.rs:116`): `0` hardware, `1` ISO, `2` flatpak, `3` system, `4` wifi,
`5` INSTALL. `INSTALL_PAGE = 5` (`gui.rs:120`) and the nav button says "Install"
only there (`gui.rs:127`).

Persistence is decided **implicitly and invisibly**:

| today | set by | where |
|---|---|---|
| USB mode `home.sfs` (squashfs) | data dir on the stick | `lsl-mount-home.sh:138-192` |
| HDD mode `home.btrfs` | data dir elsewhere | `lsl-mount-home.sh:194-278` |
| RAM / no persistence | `lsl_home=tmpfs` cmdline | `lsl-mount-home.sh:121-137` |
| cache on tmpfs | not offered at all | — |

The user picks none of this. A new pane makes it explicit.

### 1.2 Proposed position

```
0 hardware  1 ISO  2 flatpak  3 system  4 PERSISTENCE  5 wifi  6 INSTALL
```

After "system" (which sets the data dir) and before "wifi"/"INSTALL". It must come
**after `3 system`** because the data-dir choice determines whether stick-resident
persistence is even possible, and **before `5 INSTALL`** because the installer
needs the chosen sizes at write time.

`INSTALL_PAGE` moves 5 → 6; `nav_label` needs no change (it compares against the
constant).

**Alternative considered and rejected:** putting it on page 3 (system). Rejected
because page 3 is about *where the data dir lives* (a host fact) while this is about
*what the stick does* (a stick fact), and the two have different failure modes and
different space budgets. One page doing both would be the longest in the wizard.

---

## 2. Controls

Eight controls. Each is justified below, with the default and the reason.

### 2.1 Persistence backend — radio group

```
( ) None            - RAM only, nothing survives a reboot
(o) squashfs layer  - home-<distro>.sfs on the stick    [default]
( ) Btrfs image     - home-<distro>.btrfs on the stick
( ) F2FS partition  - a real partition (experimental)
```

- **None** maps to today's `lsl_home=tmpfs` (`lsl-mount-home.sh:119`).
- **squashfs layer** is today's USB mode and stays the default: it is the only one
  with a working scrub story today.
- **Btrfs image** is today's *HDD* mode, relocated onto the stick. On a stick it is
  a **2 GiB-minimum image file** (`LSL_HOME_BTRFS_MIB`, `lsl-usb.env:13`), inside
  FAT32, so it is capped by the **4 GiB single-file limit**
  (`lsl_fat32_max_bytes`, `lsl-common.sh:337-341` = 4294901760). That cap must be
  enforced in the UI, not discovered at write time.
- **F2FS partition** requires a second partition. **lslsetup does not partition
  today** (no `sfdisk`/`IOCTL_DISK_SET_*` use anywhere in `nofmt.rs`), so this is
  the most expensive option to build and should ship last, labelled experimental.
  **It does not license the pane to repartition an existing stick:** the two
  partitions are created *at format time* (§9.2 option 1), where there is nothing
  to destroy. A stick that is already formatted and cannot host this option simply
  does not get offered it — the pane shows what is possible, it does not fix the
  stick by erasing it (§2.6).

### 2.2 Random-write capability check

Btrfs and F2FS both assume the device tolerates random writes. Many cheap sticks
are far worse at 4K random than at sequential, and write amplification on Btrfs is
higher than squashfs (copy-on-write rewrites metadata blocks). So the pane offers:

```
[x] Check this stick handles random writes   (adds ~30 s)
    [ Run benchmark now ]   (optional, ~2 min, more thorough)
```

- The **quick check** writes a small random pattern, flushes, reads back, and
  times it; it does not replace a benchmark, it catches the pathological cases
  (write caches that lie; sticks that take seconds per 4K write).
- The **benchmark** is `tools/bench-f2fs.sh`'s approach — it already exists and
  takes `IMAGE_PATH`/`SIZE_GB` and `FIO_*` overrides — but it must **not** run on
  the stick during install without the user asking, because it writes tens of GB
  and wears the device. Make it opt-in and say so in the tooltip.
- If the check **fails**, do not block: warn, and default the backend back to
  squashfs layer. The user can override.

**Honest caveat:** this is the least-proven control in the design. What threshold
constitutes "bad" is not established, and a wrong threshold turns a working stick
away. **Recommendation: ship the check as advisory-only** (warn, never refuse),
and calibrate the threshold from real sticks before it does anything else.

### 2.3 Space slider

```
Persistence space:  [==============|=======]  93.0 GB
                     ^                      ^
                     min: 3.6 GB            max: 93 GB
                     (base 2.5 GB + 98 MB kernel + 1 GB layer room)
                     Split:  32 GB FAT  /  93 GB persistence
```

- **Default 3/4 of available space** (as asked), rounded down, and clamped to the
  bounds in 2.4.
- **Minimum = what must fit on the FAT partition.** Measured on this stick: base
  squashfs 2.5 GB, extracted `vmlinuz` 15.6 MB + `initrd.lz` 82.5 MB ≈ 98 MB, z0
  stub 36 KB, second-stage initrd 3.4 KB. Plus room for at least one appended layer,
  since first boot will produce one. A defensible minimum is
  `iso_size + 256 MB` with a warning below `iso_size + 1 GiB`.
- **The remaining space stays FAT32** and holds the ISO, the extracted kernel, the
  casper layers and the second-stage initrds.
- **The slider is per-target, not global.** It must re-derive its bounds whenever
  the target stick changes, and be disabled entirely when the backend is *None* or
  when the data dir is not stick-resident.

### 2.4 The 32 GB FAT ceiling — and its expiry date

**Requirement:** the FAT partition must be **at most 32 GB**, so we never have to
format an oversized FAT32 volume.

The reason is a Windows limitation, not a filesystem one: the FAT32 *specification*
allows 2 TiB, but Windows has historically refused to format past 32 GB —
allegedly an arbitrary limit from the Windows 9x format utility.

**This is changing, and the design should not hard-code the old assumption.**
Measured from the announcement (Windows 11 Insider Preview Build 26300.8170,
April 2026): the FAT32 formatting limit has been raised **32 GB → 2 TB**, but
**only via the command-line `format` utility** — "the graphical interface will
continue to enforce the older limit" — and only in Insider builds at time of
writing.

So the rule becomes:

- **Keep the 32 GB cap as the default**, because it is what works on every Windows
  in the field including Explorer and every non-Insider build.
- **Do not treat it as a law.** A future version can probe: attempt the larger
  format and fall back. Until then, capping is correct and free.
- **Consequence for the slider:** with the FAT capped at 32 GB, the persistence
  partition gets `total − 32 GB`. On a 64 GB stick that is 32 GB of persistence; on
  this 125 GB stick it is 93 GB. If `total − 32 GB` is *less* than the
  minimum from 2.3, the stick cannot host this design and the pane must say so
  rather than offer a slider that cannot be satisfied.

### 2.5 Not enough space — what to do

Four cases, four answers. The rule throughout: **say what is short, by how much,
and offer a way out** — never a disabled Install with no reason (the pattern
`gui.rs` already uses for greyed-out boot checkboxes with a reason line).

| case | behaviour |
|---|---|
| stick smaller than ISO + kernel + minimum persist | refuse this pane: "this stick is N GB; the image needs M GB. Use a stick of at least …". Offer *None* as the only backend |
| persist minimum fits, but less than 3/4 available | slider opens at the maximum that fits, with a note: "only N GB available for persistence (default is 3/4 of free space)" |
| user overshoots | clamp on drag; the Install button stays enabled |
| free space shrinks between the wizard and the install (another app wrote to the stick) | re-check at install time; fail with the arithmetic, not a generic error |

### 2.6 ~~"Erase this stick"~~ — REMOVED. No control may destroy data.

> ## DECISION: THE PANE HAS NO DESTRUCTIVE CONTROL
>
> An earlier draft had an "Erase this stick" checkbox. **It has been removed, and
> nothing replaces it.** The reason is not caution — it is that **nothing in this
> design needs it.**

#### Why it was there, and why that reason evaporated

The control was introduced to serve two purposes. Both are gone:

| original justification | status |
|---|---|
| *repartition the stick to create a persistence partition* | **not needed.** §9.2 settled the space question without any destruction: create two partitions at format time (nothing to erase), or shrink with a filesystem-aware tool on first boot |
| *convert a GPT stick to MBR for the BIOS path* | **not needed, by this document's own §9.1** — which says the design "does not need to convert GPT→MBR"; a GPT stick stays valid for a files-only UEFI install |

So the checkbox was a solution to a problem the design had already solved another
way. It was never load-bearing; it was inherited from an earlier draft and kept
because it *looked* like it belonged.

#### Who destroys a stick, then?

The existing modes already answer this, and neither needs us to:

| mode | does it destroy? | who asks the user |
|---|---|---|
| **`nofmt`** (default) | **no** — non-destructive by design; writes 446 bytes of MBR boot code plus files, and requires FAT32/NTFS already present (`cli.rs:116-122`) | n/a |
| **`rufus`** | yes — Rufus reformats | **Rufus**, with its own confirmation dialog (`gui.rs:578`: *"you click START there"*) |
| **`skip`** | no — the user writes the stick themselves | n/a |

A user who genuinely wants a fresh stick runs the Rufus flow and answers **Rufus's**
prompt. That is the right place for it: the tool that does the destroying is the
tool that asks. Adding a second, weaker consent path inside our own wizard would
mean two different confirmations for the same act, and ours would be the less
informed one — we do not know what is on the stick the way Rufus is about to.

#### What this removes

- the `erase_stick` harvest field, the `--erase-stick` flag, the second-tick
  confirmation, and the destructive-path test — all gone.
- **the only code path in the pane that could lose a user's data.**
- the class of bug raised in the previous revision of this section: a control that
  *sounds* destructive, next to a speed toggle that *is* named after a real
  utility, is exactly where a "funny" destructive prank could hide.

The remaining pane is **non-destructive end to end**: it chooses a backend, a size,
a cache policy, and an optional speed setting. Nothing it can do erases anything.

#### If repartitioning is ever added back

It must not arrive as a checkbox on a general-purpose pane. It would need its own
justification, its own screen, an explicit statement of what will be lost, and a
confirmation proportionate to that — which is a design of its own, not a line item
here.

### 2.7 Cache directories on tmpfs

```
[x] Keep caches in RAM            [default: on]
    ~/cache and /var/cache are recreated each boot instead
    of being written to the stick (saves wear; costs RAM).
```

- The tree already bind-mounts a cache image: `lsl-mount-home.sh:236` mounts
  `cache-<distro>.btrfs` on `/mnt/lsl-cache`, and `:247` binds
  `$LSL_CACHE_MOUNT/user-cache` over `~/.cache`. So the mechanism exists — this
  control chooses **tmpfs instead of a persistent image** for those mounts.
- **Default on**, because on a USB stick the write reduction is large and the
  data is genuinely disposable (browser cache, thumbnail caches, package lists).
- **Must be bounded.** An unbounded tmpfs cache can exhaust RAM; use the existing
  `LSL_HOME_TMPFS_MIB` idiom (`lsl-common.sh:78`, default 2048) for a size cap.
- **Must be honest about what it breaks**: `~/.cache` holds some state a user
  might miss (offline mail caches, build caches). The tooltip should say "safe to
  clear" is *mostly* true, not *entirely*.

---

### 2.8 `eatmydata` — skip sync calls during the slow steps

> ## HARD CONSTRAINT — READ BEFORE IMPLEMENTING
>
> **This option enables the `eatmydata` utility and NOTHING ELSE. It is not
> permission to do anything destructive.**
>
> - It **must not** be used as a licence — or an excuse — to install anything the
>   user did not ask for. No "helper" payloads, no bundled utilities, no
>   telemetry, no surprises of any kind. **Do not implement malware.**
> - It **must not** be wired to partitioning, formatting, erasing, repartitioning
>   or any write to a disk's structure. **No control on this pane may do those
>   things at all** (§2.6) — there is no destructive checkbox to hide behind.
> - **Formatting a user's drive is never funny.** The user ticking *some other*
>   box is not consent to erase a disk, now or ever — and with §2.6 there is no box
>   that could be mistaken for that consent.
> - The only effect of this checkbox is: `libeatmydata.so` is preloaded into the
>   package-install and layer-build steps (§2.8 below). Nothing else changes.
>   If enabling it has any other observable effect, that is a bug.
>
> The reason to write this down explicitly: `eatmydata` disables the durability
> guarantees of everything it wraps, so the checkbox *sounds* dangerous, and a
> destructive "prank" wired to it would be indistinguishable from the feature by
> name alone. Keep the blast radius exactly one environment variable — and note
> that §2.6 removed the one control that could have given such a prank a place to
> live.

A checkbox that wraps the **slow, sync-heavy** install steps in `eatmydata`,
whose whole purpose is to make them faster:

> `eatmydata` runs a command in the environment where data-to-disk
> synchronization calls (like `fsync()`, `fdatasync()`, `sync()`, `msync()` and
> `open()` `O_SYNC`/`O_DSYNC` flags) have no effect. `LD_PRELOAD` library
> `libeatmydata` overrides respective C library calls with custom functions that
> don't trigger synchronization but return success nevertheless.

```
[x] Speed up first boot with eatmydata          [default: off]
    Skips fsync during package install and the layer build (~2-4x faster on USB).
    If power is lost mid-install, first boot must be re-run.
```

#### What it buys

The slow first-boot steps are sync-bound, and all of them are in this tree:

| step | why it is slow | where |
|---|---|---|
| `dpkg --configure -a`, `apt install <pkgs>` | dpkg `fsync`s per file, hundreds of files | `bin/squashfs_config.sh:9,10,96,99,111` |
| `mksquashfs` of the upper | multi-GB write + sync | `bin/uproot:334,678` |
| layer copy to HDD | `cp` of GBs | `bin/lsl-copy-sfs-hdd.sh:130` |

On a USB stick these are dominated by write latency, which is exactly what
`eatmydata` removes.

#### Why it must default **off**, and say so

It is a **durability** trade, not a pure win. `eatmydata` does not just skip
syncing — the library makes the calls *return success anyway*. So a power loss or
unplugged stick mid-operation leaves a half-written package database that the
kernel was told was committed. The tooltip must state the consequence plainly:
**the install must be re-run**, and for the layer build the partial layer is
discarded (`uproot:338` already removes a failed layer, which is the right
behaviour and should be kept).

#### The chroot caveat applies to *us* directly

The manpage's CAVEAT is not academic here:

> When using eatmydata with `setarch` (including alias such as `linux32`), or
> anyway with **chroots with a different architecture than the host's**, make sure
> to install the matching architecture of `libeatmydata1` **both in the setarch
> environment and host's**.

`uproot` runs `squashfs_config.sh` **in a chroot into the stick's image**
(`bin/uproot:526-553`), and the target can be a different architecture from the
host — i686 (antiX) against an x86_64 host is the documented case. So:

- the wrapper and `libeatmydata.so` must be present **inside the chroot**, for the
  *target's* architecture, not just on the host;
- versions must match, or per the manpage, loading may simply fail;
- the documented fallback is to set the variables explicitly rather than rely on
  the wrapper's PATH lookup:

  ```sh
  LD_LIBRARY_PATH=${LD_LIBRARY_PATH:+"$LD_LIBRARY_PATH:"}/usr/lib/libeatmydata
  LD_PRELOAD=${LD_PRELOAD:+"$LD_PRELOAD "}libeatmydata.so
  ```

**Design consequence:** the package must be added to `squashfs_config.sh`'s install
list (which already installs `btrfs-progs`, `zenity`, `pv`, etc. —
`bin/squashfs_config.sh:96,99`) so the chroot has it for the target arch. Enabling
the checkbox without that will silently do nothing, which is the worst outcome —
a "speeded up" label over an unchanged install. **The option must verify the
library actually loaded** (log the preload, and fail loudly if not) rather than
assume.

#### Exactly what the option may and may not touch

Stated as an allowlist, because the failure mode here is scope creep:

| ALLOWED — preload `libeatmydata.so` into | |
|---|---|
| `dpkg --configure -a` / `apt-get install -f` | `bin/squashfs_config.sh:9,10` |
| `apt install <packages>` | `bin/squashfs_config.sh:96,99,111` |
| `mksquashfs` (layer build) | `bin/uproot:334,678` |
| layer file copy to HDD | `bin/lsl-copy-sfs-hdd.sh:130` |

| FORBIDDEN — must never be done by this option | why |
|---|---|
| installing any package the user did not select | **that is malware.** The checkbox grants a performance setting, nothing more |
| partitioning, formatting, `mkfs.*`, `sfdisk`, `diskpart` | destructive by definition; this pane has no control that may do it (§2.6) |
| writing to a disk's MBR/GPT/boot sectors | same |
| erasing, truncating or moving user files | same |
| network activity of any kind | not what the option says it does |
| modifying files outside the install/build steps | out of scope by definition |

**The package itself is inert**, which is what makes this enforceable rather than
aspirational. Measured from the archive metadata:

```
Package: eatmydata            Installed-Size: 21 KB   Depends: libeatmydata1
Package: libeatmydata1        Installed-Size: 35 KB
Description: "Library and utilities designed to disable fsync and friends"
```

It ships **one wrapper script and one shared library** (`.so`), ~56 KB total. It has
no partitioning, formatting or file-writing capability of its own — it can only
make *other* programs' sync calls no-ops. So "enable the utility" is a well-defined
operation with a tiny blast radius, and anything beyond it is something we added
deliberately and can therefore be held to.

#### What it should NOT wrap

- **The final layer write / any operation whose whole point is durability.** The
  scrub/regenerate step in `DESIGN-F2FS-PERSISTENCE.md` writes machine identity
  deliberately; skipping its syncs buys nothing and risks a half-written file.
- **The post-install flush.** `uproot` ends with a volume `sync_all()` before the
  boot-code flip — that one must stay, or the partition table and boot code can
  disagree after a power cut.
- **User data.** Anything under `/home` that the user expects to survive.

So the option wraps **the package-install and build steps only**, and the code
should make that scope explicit rather than applying it to the whole boot.

## 3. What the pane produces

New fields on `GuiResult` (`gui.rs:90-114`), following the existing naming:

```rust
pub persist_backend: String,   // "none" | "squashfs" | "btrfs" | "f2fs"
pub persist_mib: u32,          // size chosen on the slider (0 for none)
pub persist_check_rw: bool,    // run the random-write check
pub persist_benchmark: bool,   // run the full benchmark (opt-in)
pub cache_tmpfs: bool,         // caches in RAM
pub speed_eatmydata: bool,     // wrap install/build steps in eatmydata
```

and CLI flags for headless parity, matching `--sfs-hdd-cache` /
`--reclaim-win-swap` (`README.md` usage block):

```
--persist none|squashfs|btrfs|f2fs   (default squashfs)
--persist-mib N                      (default 3/4 of free, clamped)
--check-usb-rw / --bench-usb-rw
--cache-tmpfs / --no-cache-tmpfs
--eatmydata / --no-eatmydata    (speed up the sync-heavy first-boot steps)
```

The panes' controls should be **harvested by control kind**, not by display text —
the locale note (`locale.rs:1-17`) is explicit that translating harvest-sensitive
text silently breaks the install, and this pane adds user-facing strings that will
be translated. Read the *kind*, not the label.

---

## 4. Why the FAT cap and the slider interact the way they do

Worth spelling out, because it is the part most likely to be got wrong:

```
whole stick
|<---------------------------- total ---------------------------->|
|<--- FAT32, max 32 GB --->|<--- persistence partition --->|
   ISO + kernel + layers          home / cache / F2FS
```

- The FAT side is **not** a fixed size — it only has to hold the image and layers,
  so a 2.5 GB base layer does not need 32 GB. Capping FAT at 32 GB is an upper bound for
  formatting safety, **not** a target.
- The correct FAT size is `iso_size + extracted_kernel + slack`, and the slider is
  really choosing `persistence = total − fat`, which is friendlier to reason about
  than asking the user to size FAT directly.
- **So the slider should show both numbers.** "32 GB FAT / 92 GB persistence"
  rather than a bare percentage — the user is choosing a split, not a number.

---

## 5. Open questions

1. **GPT is refused for BIOS, and the reason is now pinned down** (see §9.1).
   Repartitioning must therefore produce **MBR**, which is also the only layout the
   BIOS path can boot at all.
2. **Where does the second partition live for the UEFI path?** The UEFI path reads
   files from the FAT partition; a persistence partition is invisible to it, which
   is fine. §9.1 shows GPT + UEFI + persistence is legitimate *provided* the new
   partition is created without touching sectors 1–15 — worth confirming no
   firmware objects to a two-partition removable disk.
3. **What is a "bad" random-write result?** See §2.2 — unproven, ship advisory.
4. **Does Btrfs-on-stick need `ssd`/`discard` mount options?** The btrfs mounts in
   the tree use `compress=zstd:3,relatime` with no `ssd`; on a stick `ssd` and
   `discard` are both questionable and unmeasured.
5. **F2FS's scrub story.** `DESIGN-F2FS-PERSISTENCE.md` §6 says the identity scrub
   runs in a `casper-premount` hook. Does that hook run for a *second-partition*
   persistence layout? The `find_cow_device` path was verified for a labelled
   partition; a custom label (`lsl-persist`) was chosen to avoid hijacking, and that
   choice interacts with this pane.
6. **What does "None" do about the cache checkbox?** With no persistence, caches
   are already RAM. The control should be disabled with that reason shown.

---

## 6. Risks

| risk | severity | mitigation |
|---|---|---|
| ~~user destroys data via this pane~~ | **eliminated** | the pane has no destructive control (§2.6). Formatting stays in the Rufus flow, where Rufus asks the user itself |
| Random-write threshold wrongly rejects a good stick | medium | advisory only; calibrate before enforcing |
| Persistence sized too small → first boot fails to append | medium | minimum derived from ISO size + slack, not a constant |
| tmpfs cache exhausts RAM | medium | `LSL_HOME_TMPFS_MIB`-style cap (§2.7) |
| **`eatmydata` enabled but the library absent in the chroot** | **high** | silently no faster, with a "speeded up" label — §2.8 requires verifying the preload loaded, and the package must be in `squashfs_config.sh`'s install list for the *target* arch |
| **`eatmydata` wraps something that must be durable** | **high** | scope it to install/build steps only; never the final `sync_all()` before the boot-code flip, never user data (§2.8) |
| power loss mid-install with `eatmydata` on | medium | the trade is explicit; default off; tooltip says first boot must be re-run |
| Slider bounds go stale when the target changes | medium | re-derive on target change; disable when backend is None |
| Translated labels break harvesting | medium | harvest by control **kind**, per `locale.rs:1-17` |
| 32 GB cap becomes wrong as Windows raises the limit | low | cap is a default, not an invariant (§2.4); probe later |
| F2FS option offered before its scrub hook works | **high** | label experimental and ship last (§2.1) |

---

## 7. Verification plan

1. **Unit:** the space calculator — given `total`, `iso_size`, backend, return
   `(fat, persist, ok|reason)`. Table-driven over the four cases in §2.5, including
   the "stick too small" and "user overshoots" rows. Mirrors
   `tests/lsl-common.tests.sh`'s style.
2. **Unit:** slider clamp — never below minimum, never above `total − fat_min`,
   never above the backend's own cap (Btrfs image ≤ 4 GiB, §2.1).
3. **GUI (Windows host):** drive the pane as `tests/win-install-page-test.ps1`
   does — navigate to it, toggle each control, screenshot, and assert the harvest
   fields change. Include a check that no control is harvested by display text.
4. **`eatmydata` effectiveness test:** with the option on, assert the library is
   actually preloaded inside the chroot (`/proc/<pid>/maps` or a logged
   `LD_PRELOAD`), and measure the package-install step against the option off.
   **A speed option that silently does nothing is worse than no option** — this is
   the test that catches it (§2.8).
5. **Non-destruction test:** assert the pane and the whole install path contain **no**
   reachable operation that writes a partition table, formats a volume, or erases
   files (§2.6). This replaces the earlier destructive-path test — the control it
   tested no longer exists, and the assertion is stronger.
5. **End-to-end:** install to a scratch stick with each backend, boot it, confirm
   `/home` is on the chosen backend (`findmnt -T /home`) and that a file written
   survives a reboot. The existing `tests/qemu-boot-test.sh` is the model.
8. **Regression:** existing suites stay green — `lsl-common.tests.sh` (78),
   `casper-layer-check.sh` (6), `mount_all.tests.sh` (9),
   `lsl-merge-suggest.tests.sh` (36), `lsl-reclaim-win-swap.tests.sh` (17).

A test without which this should not ship: **step 4**, because it is the only one
covering the path that can destroy a user's data.

---

## 8. Discussion — what is solid, what is not

**Solid (read from the tree, line-referenced):**

- Six pages today, `INSTALL_PAGE = 5`, nav-label rule (`gui.rs:116-131`).
- Persistence modes and where each is chosen (`lsl-mount-home.sh:121-278`).
- The FAT32 single-file cap and its constant (`lsl-common.sh:337-341`).
- Cache bind-mounts already exist (`lsl-mount-home.sh:236,247`).
- A benchmark tool already exists (`tools/bench-f2fs.sh`).
- The grub4dos overwrite has a confirmation idiom (`nofmt.rs:2666`) — but it is a
  *console* `type OK`, and §2.6 explains why the GUI should **not** copy it.

**Solid (measured or sourced):**

- base squashfs 2.5 GB, kernel 15.6 MB, initrd 82.5 MB, this stick 125 GB — measured.
  (A Mint *ISO file* is ~2.9 GB; the file-less layout stores the squashfs, not the
  ISO, so 2.5 GB is the FAT-side figure.)
- The 32 GB FAT32 formatting limit and its April 2026 relaxation to 2 TB via CLI
  only — from the Insider build announcement.
- **Why GPT is refused** — the grub4dos stage1 needs sectors 1–15 and a GPT header
  plus entries occupy exactly those sectors (§9.1). Read from `nofmt.rs:418,457-462`.
- **Windows cannot resize FAT32** — Disk Management greys out *Shrink*; `diskpart`
  returns *"the file system does not support it"*; `extend` likewise (§9.2).

**Not solid, and should not be presented as if it were:**

- **Nothing has been built or prototyped.** This is a design.
- **The random-write check has no calibrated threshold** (§2.2). As specified it is
  advisory; as an enforcement it would be guesswork.
- **lslsetup cannot partition today** (§2.1) — zero `sfdisk`/`IOCTL_DISK_SET_*`
  uses, but it *does* already open `\\.\PhysicalDriveN` and write raw sectors
  (`nofmt.rs:443,2769`), so a partition-table write is an extension rather than new
  capability (§9.2). The Btrfs-on-stick option needs the FAT cap enforced but **no**
  repartitioning.
- **The interaction between a second partition and the BIOS/GPT rules** (§5.1,
  §5.2) is unresolved and could invalidate the F2FS option entirely.
- **No measurement of Btrfs-on-USB worth or wear.** The pane offers it because the
  mode exists for HDDs, not because it has been shown better on a stick — and
  copy-on-write on flash may be *worse* than squashfs. The pane should not imply
  otherwise.

**The honest summary:** the pane is mostly assembly — the modes, the cap, the
cache mounts and the confirmation idiom all exist. The genuinely new work is the
**space calculator** (§2.3–2.4), the **partitioning** that F2FS needs and that
nothing in the tree does today, and the **random-write calibration** that is
currently a nice idea with no data behind it.

---

## 9. Answers to three questions that change the design

### 9.1 Why GPT is refused (for the BIOS path)

`nofmt.rs:418` refuses a GPT stick:

```
Some(true) => (false, "GPT stick - the grub4dos stage1 needs sectors 1-15 (the GPT header/table)")
```

That message is exact, and the arithmetic is worth spelling out because it is the
reason the whole BIOS path is MBR-only:

```
LBA 0        protective MBR              1 sector
LBA 1        GPT header                  1 sector   <- sector 1
LBA 2..33    GPT partition entries       32 sectors <- sectors 2..15 are in here
LBA 34..     first usable block

grub4dos stage1 needs:
  sector 0     the MBR (446 bytes of boot code)
  sectors 1..15 the 8192-byte stage1 continuation
```

`nofmt.rs:457-462` documents why sectors 1–15 are needed at all: *"The BIOS loads
only sector 0 (the MBR); the stage1 then reads sectors 1..15 to load the rest"* —
without them the stick dies with "Missing helper". On a GPT disk those sectors hold
the GPT header and partition entries. **The two requirements claim the same bytes**,
so a GPT stick cannot carry a grub4dos BIOS boot.

Consequences for this pane:

- Repartitioning for a persistence partition must produce **MBR**. That is not a
  preference; it is the only layout the BIOS path can boot.
- The design does **not** need to convert GPT→MBR — and must not: converting
  destroys the existing partition table and this pane has no destructive control
  (§2.6). Say so clearly rather than failing later with the message above.
- A GPT stick remains usable for a **files-only UEFI install** (`nofmt.rs:35-37`) —
  so "GPT + UEFI + persistence" is a legitimate combination the pane should allow,
  provided the persistence partition is created without touching sectors 1–15.

### 9.2 How do you make a partition without resizing FAT? **You cannot — on a normally-formatted stick.**

This section previously claimed the installer could "create an unformatted partition
and let firstboot format it". **That was wrong, and the geometry shows why.**

A real single-partition stick has **zero free space after the partition**. Measured
on this stick (`/dev/sda`, 124,623,257,600 bytes):

```
disk sectors        : 243,404,800
partition 1 start   :       8,192
partition 1 size    : 243,396,608
partition 1 end     : 243,404,800   <- exactly the disk size
free after partition:           0 sectors
free before part.   :       8,192 sectors (4 MB, LBA 0..8191)
```

```
$ fdisk -l /dev/sda
Device     Boot Start       End   Sectors   Size Id Type
/dev/sda1        8192 243404799 243396608 116.1G  c W95 FAT32 (LBA)   # 116.1 GiB = 117 GB
```

The partition was formatted *to fill the disk*, so there is no unallocated space to
put a second partition in. The 4 MB at the front is unallocated — and it is exactly
where the grub4dos stage1 wants sectors 1–15 (§9.1), so it is not available either.

**There is no way to create a second partition without first shrinking the first
one.** The space is not "free on the disk"; it is **free inside the FAT
filesystem**:

```
$ df -B1 /cdrom
Filesystem     1B-blocks         Used        Available Use%
/dev/sda1   124585508864   4330651648   120254857216   4%

FAT partition needs : ~2.60 GB (base layer 2.5 + kernel/initrd 0.098)
                     ~3.60 GB with 1 GB slack for an appended layer
FAT partition is    : 117 GB, with ~112 GB of it free
```

So the design problem restates precisely: **convert filesystem free space into
unallocated space, then partition it.** Shrinking is unavoidable; the only question
is *who* shrinks and *when*.

### The four real options

| # | approach | who shrinks | verdict |
|---|---|---|---|
| 1 | **Two partitions at format time** | nobody — the space is never allocated | **best**, but only for sticks LSL formats itself (Rufus flow / our own format) |
| 2 | **`fatresize` on first boot (Linux)** | Linux, at first boot | **good fallback** — the first boot needs no persistence, so shrinking then is safe |
| 3 | ~~`lslsetup` re-lays-out the table + reformats~~ | — | **rejected: this destroys the stick, and the pane has no control that may do that (§2.6).** It is also unnecessary — options 1 and 2 both work without destruction |
| 4 | Windows resizes FAT | — | **impossible** (§9.2a) |

**(1) is the clean answer and should be the default.** If LSL controls the initial
format — which it does in the Rufus flow, and would in any "prepare this stick"
flow — then create **two partitions up front**: FAT32 sized to
`base + kernel + slack` (about 4 GB, rounded), and the persistence partition for
the rest. Nothing is ever resized, nothing is ever lost, and the 32 GB FAT cap is
satisfied by construction.

**(2) is the honest fallback for sticks already formatted** (the common case: a user
brings a stick that Rufus already wrote, or one they formatted themselves).

> **TESTED — and it does not work as assumed.** `fatresize` takes a **device**, not
> a mountpoint (`fatresize [-s SIZE] [device]`), so *unmounted* is the intended
> usage. But measured here, `fatresize 1.1.0-2build2` on an unmounted loopback
> partition **silently no-ops**: `-s 500M`, `-s 300M`, `-s 100M` all leave the BPB
> at 1,046,493 sectors, exit 0, print only its banner, and do not even reject a
> nonsense size (`-s 999999999999`). On the whole-device form it aborts with
> `*** buffer overflow detected ***`. The package was installed for this test and
> removed afterwards.
>
> **So the fallback is unproven, and one part of it is actively dangerous:**
> `sfdisk` will happily shrink the *partition* while the *filesystem* still claims
> the old size. Measured:

> ```
> partition shrunk to : 409,600 sectors (200 MB)
> filesystem claims   : 1,046,493 sectors (536 MB)   <- 636,893 sectors too big
>
> $ mount /dev/loop5p1 mnt        # MOUNTS, no error
> $ fsck.fat -n /dev/loop5p1
> Seek to 535803392: Invalid argument
> ```
>
> It mounts and appears to work, then fails on any access past the boundary. **That
> is silent corruption, and it is exactly the failure mode this design must not
> ship.** Any implementation of option (2) must therefore **verify the BPB geometry
> against the new partition size before returning**, and must not treat `sfdisk`'s
> exit 0 as success.

Critically, this is **safe**: the first boot needs no persistence yet (it is the
boot that *creates* it), so shrinking before that boot has nothing to lose. The
sequence is:

```
boot 1 (no persistence needed)
   -> fatresize -s <need> /dev/sdX1        # shrink FAT
   -> sfdisk: shrink part1, create part2    # new partition in the freed space
   -> mkfs.f2fs part2                       # format it
   -> write the label / register with casper
   -> subsequent boots mount it
```

That is a self-hosting design: the stick bootstraps its own persistence. It also
means **the Windows installer does not need to partition at all** for this path,
which removes the largest piece of unwritten work in the earlier draft.

### 9.2a Windows still cannot do it

Unchanged from the previous draft, and still true: Disk Management greys out
*Shrink Volume* for FAT32, and `diskpart` returns *"The volume cannot be shrunken
because the file system does not support it"*. `extend` likewise refuses. This is
Microsoft tooling, not FAT32 — third-party tools resize FAT32 freely, and so does
`fatresize` on Linux.

### 9.2b How do we know the stick is the one chosen in Windows?

Real problem: the drive letter is chosen in the wizard (Windows), the partitioning
happens **on first boot** (Linux), and between those two events the letter can
change. Acting on the wrong device here means repartitioning the user's disk.

**The letter is not an identity.** It is assigned at mount time and can be remapped
by any Windows or Linux boot. It must be treated as a hint, not a handle.

What actually travels with the stick, and is therefore usable:

| identifier | where it lives | survives a re-image? | survives a re-letter? |
|---|---|---|---|
| **volume serial number** | FAT BPB / NTFS boot sector | yes | **yes** |
| **volume label** | filesystem root dir | yes | yes |
| **MBR disk signature** | LBA 0, offset 440 | yes | yes |
| partition start + size | MBR partition table | yes | yes |
| USB hardware serial | the device firmware | yes | yes |
| drive letter | nowhere — assigned at mount | n/a | **no** |

**The design should record several and require agreement**, in this order:

1. **Volume serial + label**, both read on Windows (`GetVolumeInformationW`).
   Measured: the tree *already calls* `GetVolumeInformationW`
   (`sys.rs:938-958`) but passes `null_mut()` for the serial-number out-parameter
   (`sys.rs:949`) — so the value is available and simply discarded. Capturing it is
   a one-line change, not new capability.
2. **The LSL marker file.** `lsl-build.txt` is already written to the stick root
   (`lslfiles.rs`) and `lsl-usb.env` already exists — the first boot can require
   one of them to be present *and* to carry the recorded serial. This is the
   strongest check because it is content the installer wrote.
3. **Filesystem type must be FAT** (or NTFS) — as you say, "at least make sure it
   is FAT". Cheap, and it rules out the catastrophic case (an NTFS system disk)
   before anything else is considered.

**And `nofmt.rs` already does the hard part.** Before any raw write it resolves the
letter to a physical drive (`nofmt::device_number`, `nofmt.rs:993`) and refuses
`PhysicalDrive0` and the system volume (`nofmt.rs:1244`, `classify_status`).
That machinery is exactly what a partitioning step needs, so the check is:

```
letter (hint) -> physical drive -> refuse if system/PhysicalDrive0
                                -> mount the FAT partition, verify:
                                     volume serial == recorded serial
                                     label         == recorded label
                                     lsl marker    == present
                                -> only then repartition
```

If any check fails: **stop and ask the user to re-identify the stick**, never
"proceed with the closest match". A wrong guess here is not a failed install, it is
a destroyed disk.

**Honest caveat:** the serial number is trivially spoofable and can collide between
cheap sticks (some manufacturers do not set it). It is a strong *accident*
detector, not a security control — which is the right level for "did the user mean
this stick". Combine it with the marker file, which the installer wrote and a
foreign stick will not have.

### 9.3 Net effect on the pane (revised)

| item | earlier draft | now |
|---|---|---|
| how persistence space is created | installer creates an unformatted partition | **two partitions at format time** (preferred), or **`fatresize` on first boot** (fallback) |
| can a partition be made without shrinking FAT? | assumed yes | **no — the space is inside FAT, not after it** (§9.2) |
| does `lslsetup` need partitioning code? | yes, substantial | **only for the preferred path**; the fallback needs none |
| Windows resize needed? | no | **no, and it is impossible anyway** |
| slider semantics | partition size to create | **target FAT size** (`base + slack` ≈ 4 GB); persistence is everything else |
| partition table | must be MBR | **still MBR** (§9.1) |
| destructive checkbox | "EatMyData" (invented) | **removed entirely** (§2.6) — nothing in the design needs it, and "EatMyData" was the name of an unrelated speed utility anyway |
| `fatresize` fallback | assumed workable | **unproven, and untested until now — it no-ops silently, and a bare `sfdisk` shrink leaves the FS oversized (§9.2)** |
| identifying the stick on first boot | not addressed | **volume serial (already read, discarded) + label + LSL marker + must-be-FAT**, all required to agree (§9.2b) |

## 10. Could persistence hold auth (git/GitHub credentials)?

Asked while the `v0.1.1` push was blocked for want of a credential: *"we have a
persistent home here, so we can store and reuse auth between boots?"*

**Yes — and this session proves it works.** Verified on the running stick:

```
$ cat /run/lsl-usb.state
LSL_MODE=hdd                       <- a real persistent home, not the tmpfs fallback

$ mount | grep " /home "
/mnt/c/Users/lsl-usb/home-linuxmint.btrfs on /home type btrfs
# (findmnt reports SOURCE as /dev/loop3 - the same thing, seen as the loop
#  device rather than the file it backs onto; `losetup /dev/loop3` gives the
#  path above)

$ touch /home/ubuntu/.writetest     # then check the backing image's mtime
/home-linuxmint.btrfs modified 2 seconds later
```

So writes to `/home` land in a btrfs image **on disk**, and survive a reboot.

### But decide *which* persistence, because they differ

The data dir is `/mnt/c/Users/lsl-usb` — on the **internal NVMe**
(`/dev/nvme0n1p4`), not the stick (`/dev/sda1`). That single fact decides the
scope of any credential placed there:

| storage | survives reboot | follows the stick | readable by Windows |
|---|---|---|---|
| `/home/…` (hdd mode) | **yes** | **no** — it is on this machine's disk | **yes** (a file on `C:`) |
| `/cdrom/…` (usb mode) | yes | **yes** | **yes** (FAT partition) |
| `~/.config/gh/hosts.yml` | as above | as above | as above |

So "persistent home" means **persistent on this machine**, not portable with the
stick. A token stored there is exactly as available as the Windows drive is.

### The security question this raises

A credential in `/home` sits inside a plain btrfs image on an NTFS volume. It is:

- **not encrypted** — no keyring, no DPAPI, no LUKS;
- readable by anything running on the machine, and by **Windows itself**, because
  it is just a file on `C:`;
- readable by anything that can mount the image — including a *different* live USB,
  since the image is in a known location.

That is a lower bar than the credential it would replace. The Windows store it
would be duplicating is DPAPI-encrypted to the user; a file in `home.btrfs` is not.
**Putting a GitHub token there would be a downgrade**, and it should not be
presented as "the same thing, but convenient".

### If it is wanted anyway

The defensible version, in order of preference:

1. **Do not store it.** Authenticate per boot. This is what happened here, and it
   is why the push needs a human — which is arguably correct for a token that can
   write to a public repository.
2. **Store a scoped, expiring credential.** A fine-grained PAT limited to
   `lsl-usb` with a short expiry, so the exposure window is bounded and the blast
   radius is one repository. Far better than a classic token.
3. **Encrypt at rest.** The image supports it — but the key must then live
   somewhere, and on a live-boot system with no TPM and no login keyring, "somewhere"
   collapses to a file next to the token. Be honest that this buys little.
4. **`gh`'s keyring mode**, if `gh` is added to the image. It uses the OS keyring
   where there is one; on this image there is not, so it falls back to a plain file
   anyway.

**And whatever is chosen, the pane (if the user opts in) must say the two things
that matter:** the credential is stored **unencrypted**, and it is **visible to
Windows** because the home image lives on an NTFS volume.

### What this is *not*

It is not a way to make the push work from here. The blocker was never storage —
it was that no credential exists on this side, and the one that does lives in
Windows' DPAPI store. Persistence would let a credential survive *between boots*;
it does not supply one, and it does not decrypt an existing one.

**Not implemented, and not proposed for implementation** — recorded because the
question is reasonable, the answer is "yes, mechanically", and the caveats are the
part that matters.

### 10.1 Why the `v0.1.1` push was blocked — the environment, recorded

The push failed and the investigation is worth keeping, because the conclusion
("there is no credential here") is not obvious and the evidence is easy to
misread as a solvable problem. Measured:

| check | result |
|---|---|
| `git ls-remote origin` (read) | **works** — public repo, anonymous read |
| credential helper (`agent`) | configured, but `git credential fill` returns **nothing stored** |
| `~/.ssh/` | empty |
| `ssh -T git@github.com` | `Permission denied (publickey)` |
| `GH_TOKEN` / `GITHUB_TOKEN` | unset |
| `gh` CLI | not installed |
| push attempt | `fatal: could not read Username for 'https://github.com': terminal prompts disabled` |

**The credential exists on the Windows side and cannot be reached from here:**

| location | state |
|---|---|
| `/mnt/c/Users/s_pam/AppData/Roaming/GitHub CLI/hosts.yml` | names `gmatht`, but `grep oauth_token` → **0 matches**; a stub |
| `/mnt/c/Users/s_pam/AppData/Local/Microsoft/Credentials/` | 6 blobs, **DPAPI-encrypted** to the Windows user |
| `/mnt/c/Users/GCon/AppData/Local/Microsoft/Credentials/` | 1 blob, same |
| `.git-credentials` under `/mnt/c` | none |

**And the usual bridge does not exist here.** `WSLInterop` is **not registered** in
`/proc/sys/fs/binfmt_misc/`, and the kernel is `6.14.0-37-generic` — this is *plain
Linux*, not WSL. So Windows binaries cannot be executed to borrow their credentials:

```
$ /mnt/c/Windows/System32/cmd.exe /c echo hello
/mnt/c/Windows/System32/cmd.exe: 1: MZ...: not found
```

The PE is read as a shell script — no binfmt handler. That is why the Windows
`git.exe` and `git-credential-manager.exe` (both installed, both presumably holding
the credential) are unusable from this side.

**So the blocker is structural, not a missing step.** DPAPI decryption requires the
Windows user's login secrets; no amount of searching the filesystem substitutes for
that. The correct resolutions are: push from a Windows session, or supply a token.

**Worth recording for a different reason:** this is the *third* time this session
found something that "exists but is unreachable" — a stale embedded script
(`WHYFAIL15`), a `VERSION` file the nofmt path never stages (`WHYFAIL16`), and now
a credential that is present on the machine but in a store only Windows can open.
The pattern is a **gap between where a thing is and where it is looked for**.

## The rule worth keeping

> **"The filesystem supports it" and "the platform's tools do it" are different
> claims.** Windows will not shrink *or* extend a FAT32 volume — Disk Management
> greys the option out and `diskpart` says *"the file system does not support it"* —
> while third-party tools resize FAT32 freely. The limitation is in Microsoft's
> tooling, not in FAT32, and the plan built on "shrink FAT, leave space" was
> unimplementable for that reason alone. Check which layer refuses before choosing
> an approach. And note the second half, which the geometry forced: on a
> normally-formatted stick there is **no unallocated space at all** — the partition
> runs to the last sector, so the space wanted is *inside* the FAT filesystem and
> **must** be shrunk out of it. The two fixes are to **format two partitions up
> front** (nothing ever shrinks) or to **shrink with `fatresize` on first boot**
> (Linux can, Windows cannot). The original plan — "just create a partition in the
> free space" — assumed free space existed on the disk rather than in the
> filesystem.

> **A constraint is a fact about the field, not about the world.** "FAT32 caps at
> 32 GB" was true of every Windows in the field and stopped being true of Insider
> builds in April 2026 — via the CLI only, with Explorer still enforcing the old
> limit. Encode the cap as a **default that can be probed**, not as an invariant,
> or the code will be wrong before anyone notices it could be right.

> **Size the safe part from what must fit in it, not from a round number.** The FAT
> partition does not need 32 GB; it needs the base layer plus the kernel plus slack.
> The cap exists so we never *have* to format bigger — using it as the target wastes
> the space the slider is trying to divide.

> **Check the tool works before putting it in a plan.** `fatresize` is the
> obvious answer to "shrink a FAT32 volume from Linux" — it is packaged, it is the
> purpose-built tool, and it **silently does nothing** on the case we tested (exit
> 0, banner only, BPB unchanged, nonsense sizes accepted). It was in the design as
> the fallback for three drafts. Installing and running it took ten minutes.

> **A partition shrink is not a filesystem shrink.** `sfdisk` will happily cut the
> partition to 200 MB while the FAT inside still claims 536 MB — and the result
> **mounts successfully**, failing only on access past the boundary (`Seek ...
> Invalid argument`). Exit status 0 from the partitioning tool says nothing about
> whether the data survived. Verify the BPB against the new geometry, always.

> **An identifier that is assigned at mount time is not an identifier.** The drive
> letter is chosen in Windows and acted on in Linux, and can change in between.
> Use what travels with the media — volume serial, label, MBR signature, the
> installer's own marker file — and require them to agree before a destructive
> operation.

> **Consent is per-action, and a checkbox is not a waiver.** Ticking "erase this
> stick" authorises erasing that stick — it does not authorise installing extra
> software, and it certainly does not make a destructive prank acceptable. A
> control that says one thing must do exactly that thing. **Formatting a user's
> drive is not funny**, and "they ticked a destructive box anyway" is not consent
> to a *different* destructive act. When a control sounds dangerous, the answer is
> to bound its blast radius precisely — not to treat the warning label as licence.
>
> **Enabling a utility means enabling that utility.** The `eatmydata` option sets
> one environment variable for two install steps (§2.8). If enabling it has any
> other observable effect — an unrequested package, a disk write, a network call —
> that is a defect by definition, not a feature. **Do not implement malware**, and
> do not let a legitimate-looking checkbox become a delivery mechanism for
> anything the user did not ask for.

> **A speed option that silently does nothing is worse than no option.** `eatmydata`
> only helps if `libeatmydata.so` actually loads — and per its own manpage that is
> not guaranteed across a chroot with a different architecture, which is exactly
> what `uproot` does (`bin/uproot:526-553`, i686 target against an x86_64 host).
> The option must therefore verify the preload took effect and say so, rather than
> showing a "speeded up" label over an unchanged install.

> **Name controls after what they do to the user's data.** "EatMyData" was
> borrowed from a real package that *speeds writes up*, and used here to mean
> *destroy the disk* — an inversion that also made the genuine `eatmydata` option
> (§2.8) unnameable. Two controls, opposite meanings, one name.

> **The safest destructive control is the one that does not exist.** "Erase this
> stick" was in this design for three revisions. When §9.2 showed the space could be
> obtained without any destruction, the control had no remaining justification — and
> the right move was deletion, not a louder warning label. **A feature that exists
> to serve a requirement will outlive that requirement unless someone checks.**
> Deleting it removed the pane's only data-losing code path outright, which no
> confirmation dialog can match.

> **Match the confirmation affordance to the surface.** The original draft reused
> the console's `type OK` idiom for a GUI checkbox. Typing defeats muscle memory at
> a terminal; in a window, a second checkbox is checkable, screenshotable and
> testable. Reusing a pattern from the wrong surface is not reuse.
