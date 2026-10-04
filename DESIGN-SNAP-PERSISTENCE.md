# DESIGN — Persisting snaps on the stick

**Status:** IMPLEMENTED, in the on-demand + lazy-cache form. Superseded in part
by this document's own §9. Every claim about the tree is line-referenced.

**Question:** how do we permanently install snaps on the stick, so they survive a
reboot?

**Answer (shipped):** the stick stores a small **list** of snap names
(`/cdrom/snaps.txt`) plus a lazy **cache** of the `.snap` payloads under
`/cdrom/casper/snapcache/`. `snapd` installs them on first boot from that cache
(or from the store, once), and each is cached so later boots install from disk
instead of re-downloading. snapd's own state is deliberately **not** made
persistent — see §9 for why the FAT objection below is stale and what actually
blocks it. Making snapd's state persistent remains Option B/F2FS, and is
machine-local.

**Companion:** `DESIGN-PERSISTENCE-PANE.md` (the wizard page), `DESIGN-F2FS-PERSISTENCE.md`
(a real persistent filesystem — the only option that scales), `WHY_FAIL.md` (the
4 GiB layer ceiling this collides with).

---

## 1. The problem, measured

snapd keeps **all** of its state on paths that, on this system, are on the casper
**RAM overlay** — so everything vanishes on reboot:

```
$ findmnt -T /var/lib/snapd -o TARGET,SOURCE,FSTYPE -n
/    /cow   overlay

$ for d in /var/lib/snapd /var/snap /snap; do findmnt -T $d -o SOURCE -n; done
/cow
/cow
/cow
```

| path | what lives there |
|---|---|
| `/var/lib/snapd/` | state.json, assertions, the seed, the cache |
| `/var/lib/snapd/snaps/` | **the actual `.snap` squashfs files** (loop-mounted) |
| `/snap/<name>/current` | symlinks into the mounted revisions |
| `/var/snap/<name>/common` | per-snap system data (`SNAP_COMMON`) |
| `/home/<user>/snap/` | per-snap **user** data (`SNAP_USER_COMMON`) — **this one already persists**, because `/home` is the btrfs image |

Measured size on a freshly-booted stick: `/var/lib/snapd` is only **236 KB** —
because nothing has been installed yet. That is the point: the moment a snap is
installed, hundreds of MB land on the RAM overlay and are lost.

**And the tree does not currently install snaps at all.** `bin/squashfs_config.sh:104-105`
says:

```sh
# Enable snap support: Mint ships /etc/apt/preferences.d/nosnap.pref which blocks
# snapd. lsl's Windows installer can preload .snap files onto the USB
# (/cdrom/snaps/), so remove the pin and install snapd to allow offline installs.
```

But **nothing writes `/cdrom/snaps/`** — grepping `rust9x/lslsetup/src/*.rs` and
`install.ps1` for it returns nothing — and **nothing installs `.snap` files** from
it. `/cdrom/snaps/` does not exist on the live stick. So the comment describes an
intent, and `snapd` is installed and working (`snap 2.76.3+ubuntu24.04`) with no
way to use it persistently.

---

## 2. Why the obvious answer does not scale

The root overlay *is* packed by `uproot` into an appended layer, so
`/var/lib/snapd` **would** be captured by the existing mechanism — and it would
work, for a while. The problem is the ceiling `WHY_FAIL.md` already documents:

```
FAT32 single-file cap : 4,294,901,760 bytes (4 GiB)  -- lsl-common.sh:337-341
current append layer  : 0.8 GB
```

Real snap sizes make this fail quickly:

| snap | size |
|---|---|
| core22 / core24 / gnome-42-2204 (dependencies) | ~80 MB each |
| chromium | ~250 MB |
| firefox | ~280 MB |
| code (VS Code) | ~330 MB |
| libreoffice | ~600 MB |
| steam (+ runtime) | ~700 MB+ |

Three or four snaps plus their base snaps is **1–2 GB**, on top of whatever else
the layer carries. `WHY_FAIL.md` records this exact failure at 7.2 GiB: *"the
appended layer would be ~7.24 GiB, over the 4 GiB FAT32 single-file limit, so
`uproot` refused to write it."*

So the layer is a valid answer for **one or two small snaps** and a dead end past
that. It should not be the primary mechanism.

---

## 3. The precedent that already works: flatpaks

The tree already solved this exact problem for flatpaks, and the solution is worth
copying rather than reinventing. `misc/lsl-firstboot.sh:636` `install_flatpaks_fat()`:

- the apps live **as direct files on the FAT stick** (`/cdrom/flatpak`), exposed
  through a FUSE view at `/run/lsl-fat/flatpak`;
- **nothing is baked into the layer** — only a tiny
  `/etc/flatpak/installations.d/lsl-fat.conf` (a few lines, lands in the overlay);
- the comment states the reasoning explicitly: *"refusing to bake GBs into the
  4 GiB-capped layer"* (`misc/lsl-firstboot.sh:654`).

**This works because flatpak supports multiple named *installations*** (`--installation=lsl-fat`).
**snapd has no equivalent** — there is exactly one snapd state directory, hardcoded.
So the mechanism cannot be copied directly; only the *principle* can: **keep the
bulk out of the layer.**

---

## 4. The three workable approaches

### Option A — bind-mount snapd's state onto persistent storage (recommended)

Keep the bulk on a real filesystem and bind it into place before `snapd` starts:

```
/cdrom/snapd/          (or the F2FS partition, or a btrfs image)
  ├── lib-snapd/       -> bind to /var/lib/snapd
  ├── var-snap/        -> bind to /var/snap
  └── snaps/           -> the .snap files, also reachable at /var/lib/snapd/snaps
```

- **Ordering matters**: `snapd.service` must not start before the binds exist, or
  it will populate a fresh state directory on the RAM overlay and then be
  shadowed. This needs a `Before=snapd.service` unit or an ordering hook in
  `onboot.sh` — and `onboot.sh` already mounts things early for exactly this class
  of reason (the mount-ordering history in `FRAGILE_HOME.md`).
- **`/snap` is a mount point, not storage** — snapd manages it, so it should not be
  persisted, only its contents re-established by snapd on start.
- **User data already persists** (`/home/<user>/snap`), which is a useful head
  start: `SNAP_USER_COMMON` survives today.

**Where should it live?** Two sub-options, and this is the real decision:

| backing | capacity | survives | notes |
|---|---|---|---|
| **FAT (`/cdrom/snapd`)** | stick size | reboot, and travels with the stick | ~~FAT has no permissions/ownership, no symlinks~~ — **see §9: this objection is stale.** The FUSE meta-layer supplies all of it. Blocked for other reasons. |
| **F2FS partition** (`DESIGN-F2FS-PERSISTENCE.md`) | partition size | reboot | a real POSIX filesystem; **the only option that is actually correct** |

**FAT is the tempting choice and the reasoning here was wrong** — see §9. snapd's
state does not belong on FAT, but not for the reason given above.

### Option B — a btrfs image on the data dir (works today, machine-local)

The tree already creates and mounts `home-<distro>.btrfs` and
`cache-<distro>.btrfs` (`bin/lsl-mount-home.sh:194-236`). The same machinery could
carry a `snapd-<distro>.btrfs`:

- **btrfs is a real filesystem** — permissions, symlinks, ownership all correct;
- it lives on the data dir (`/mnt/c/Users/lsl-usb`), so it is **machine-local**,
  not stick-portable (same caveat as `DESIGN-PERSISTENCE-PANE.md` §10);
- **this is the smallest change that actually works**: one more image, one more
  mount, and the bind.

This is probably the right first implementation — it reuses existing code paths
(`lsl_grow_btrfs_image`, defined in `onboot.sh`, the loop mount, the
`LSL_HOME_BTRFS_MIB` idiom) rather
than adding a filesystem.

### Option C — accept the layer, and cap it

Let `uproot` capture `/var/lib/snapd` in the appended layer, and refuse (as it
already does) when the result would exceed 4 GiB.

- **Works today with no new code** for one or two small snaps.
- Fails loudly at the cap (`uproot:320-322`), which is the correct behaviour.
- **Should be documented as a limitation, not offered as a feature**: "you can have
  a couple of snaps, and past that the install refuses".

---

## 5. What installing a snap offline actually requires

Whatever the storage answer, the install path needs the snap **and its assertions**
or `snapd` will refuse it. Two ways:

1. **`snap download <name>`** on a networked machine produces `<name>_<rev>.snap`
   **plus** `<name>_<rev>.assert` — both are required for `snap ack` + `snap
   install --offline`. Staging only the `.snap` file is the common mistake and it
   fails.
2. **`snap install --dangerous <file>`** bypasses assertions entirely — works
   offline with only the `.snap`, but skips signature verification and the snap is
   *not* from the store, so it cannot be refreshed normally.

The `squashfs_config.sh` comment says "preload .snap files", which is only half the
requirement for the verified path. **The design should name which it means**, and
the pane/tooling should say so.

Size note for the preload: the same 4 GiB ceiling does not apply to files *on the
FAT stick* — only to a layer. So `Option A`'s FAT backing would hold the files
fine; it is the *permissions and symlinks* that make FAT wrong, not the capacity.

---

## 6. Risks

| risk | severity | why |
|---|---|---|
| snapd starts before the bind, populating a fresh RAM state dir | **high** | ordering; needs `Before=snapd.service` and a boot-time check |
| FAT backing loses symlinks/permissions | **high** | `/snap/<name>/current` is a symlink; ownership matters. This is why Option B (btrfs) beats Option A-on-FAT |
| a stale state dir after a failed boot poisons future boots | medium | the same class as `WHY_FAIL.md`'s crash-loop; a marker file and a clean path are needed |
| layer approach hits 4 GiB | medium | already handled — `uproot` refuses with a clear message rather than corrupting |
| snap auto-refresh while offline | medium | snapd will retry and fail; consider `snap refresh --hold` |
| the machine-local (Option B) is mistaken for stick-portable | medium | same caveat as auth — document it where the user chooses |
| `.snap` staged without its `.assert` | medium | install fails with a confusing error; the docs must say both are needed |

---

## 7. Verification plan

1. **Ordering test (QEMU):** install a snap, reboot, confirm it is still listed and
   runnable (`snap list`, then run the app). The existing
   `tests/qemu-hdd-mirror-test.sh` is the model for a boot-and-check harness.
2. **Bind-order test:** assert the bind exists *before* `snapd.service` starts —
   check `systemctl show -p ActiveEnterTimestamp snapd.service` against the mount.
3. **Negative test:** with the persistent backing absent, confirm a boot still
   succeeds (snapd falls back to a fresh state dir) rather than hanging.
4. **Cap test:** push the layer approach past 4 GiB and confirm `uproot` refuses
   with its existing message instead of writing a partial layer.
5. **Offline-install test:** stage `.snap` + `.assert`, boot with no network, and
   confirm `snap ack` + `snap install --offline` succeeds.

A test without which this should not ship: **step 1** — "it installed" is not the
claim; "it survived a reboot" is.

---

## 8. Discussion — what is solid, what is not

**Solid (read from the tree or measured here):**

- snapd's state paths are on the RAM overlay and therefore ephemeral (measured).
- `snapd` is installed and functional; `/cdrom/snaps/` does not exist.
- The tree installs snapd but has **no** snap preload and **no** snap install
  path — the comment at `squashfs_config.sh:104-105` describes intent only.
- The flatpak precedent works by keeping bulk off the layer, and flatpak can do
  that because it supports named installations (`misc/lsl-firstboot.sh:636-690`).
- **snapd has no equivalent concept**, so the mechanism cannot be copied directly.
- The 4 GiB layer cap is real and already documented as a failure (`WHY_FAIL.md`).

**Not solid, and should not be presented as if it were:**

- **Nothing has been prototyped.** No bind mount, no btrfs image, no install.
- **Whether snapd survives having `/var/lib/snapd` bind-mounted** is unverified. It
  should be — snapd validates its state directory and may object to a replaced
  mount under it. This is the single biggest unknown and it invalidates Option A
  entirely if it fails.
- **Whether FAT can hold snapd's state at all** is argued from first principles
  (no symlinks, no ownership) rather than tested. It is probably correct and is
  the reason Option B is preferred, but "probably" is doing work there.
- **Sizes are from general knowledge**, not from snaps downloaded on this machine.
  The 1–2 GB estimate should be replaced with measured numbers before it is used
  to justify anything.
- **No estimate of how long a boot-time bind + snapd start adds.** The session
  already has a first-boot budget; snaps add to it and nobody has measured by how
  much.

**The honest summary:** the problem is clear and the mechanism is understood, but
the cheapest correct implementation is **Option B** (a btrfs image on the data
dir, reusing `home.btrfs`'s code), and the only one that scales to many snaps is
**the F2FS partition** from the persistence design. The layer approach works today
for one or two small snaps and should be documented as a limitation rather than a
feature. Everything above is unverified.

---

## 9. What actually shipped, and the correction to §3/§4

**Status: implemented** (see `bin/lsl-snap-fat.sh`, `misc/lsl-firstboot.sh`
`ensure_snaps_fat`, `src/lslfiles.rs` `write_snap_list`, `src/hardware.rs`
`SNAP_MAP`).

### The correction

**The FAT objection in §3/§4 above is stale, and it was wrong.** It rejects FAT
for snapd's state because "FAT has no permissions/ownership, no symlinks". That
was true when written. It is no longer true, and the reason it stopped being
true is *in this same repo*:

`fuse/fat_linux_meta_fs.py` is a FUSE passthrough that stores mode/uid/gid,
symlinks, hardlinks, FIFOs and device nodes in a sidecar JSON file, because the
underlying FAT cannot (`fat_linux_meta_fs.py:3, 13-15, 1033, 1057, 1073, 1089,
1128`). It is what makes the flatpak-on-FAT scheme in §3 work at all. So
"can this filesystem express it?" has already been answered *yes* for this
filesystem — the question was asked of bare FAT when the question should have
been asked of the FUSE layer above it.

The conclusion (don't put snapd's state on FAT) still holds. The reasons are
different, and they are about *concurrency and mounting*, not representation:

1. **Locking.** `fat_linux_meta_fs.py:886-892` — `lock()` is an intentional
   no-op: *"Advisory locks are a no-op here... Correct for our single-writer
   flows (builder fetch, firstboot install): never run two writers against the
   same backing tree concurrently."* snapd is **not** single-writer — snapd,
   snap-confine, AppArmor and the store client all touch its state. An unlocked
   multi-writer on a sidecar-JSON metadata store is corruption, not slowness.
2. **Loop mounts.** snapd `squashfs`-loop-mounts the `.snap` files out of its
   state directory on every refresh. The backing file is a FUSE passthrough, and
   squashfs over a FUSE fd is not a reliable loop source.
3. **Mount ordering.** `/snap/<name>/current` is a symlink that must resolve
   *after* the bind, and `snapd.service` must not start first or it will
   populate a fresh RAM state dir that the bind then shadows. This is the
   `Before=snapd.service` requirement in §4, still unproven.

So the rule at the end of this document needs a correction of its own: the
representability question is real, but **it was already answered, and the
question that actually decides is whether the filesystem can support the
access pattern the daemon uses** — concurrent writers, loop mounts, mount
ordering.

### The design that shipped

Not a persistent state dir at all. snapd was **already installed**
(`bin/squashfs_config.sh:103-112` removes Mint's `nosnap.pref`), so the only
missing pieces were *which* snaps, and re-applying that list each boot.

| what persists | where | size |
|---|---|---|
| the list of wanted snaps | `/cdrom/snaps.txt` | a few hundred bytes |
| the `.snap` payloads | `/cdrom/casper/snapcache/` | only for snaps actually used, only after first use |

- `/cdrom/casper/`, **not** `/cdrom/` — `onboot.sh:256` remounts `/cdrom`
  read-only, and on iso-scan boots `/cdrom` is the ISO loop while
  `/cdrom/casper` is the bind-mounted writable stick. Same reason
  `lsl-appimages.sh` uses `/cdrom/casper/appimages`.
- A `.snap` is a plain file, written once and read back. No symlinks, no state
  dir, no loop mount off FAT. The 4 GiB FAT32 single-file cap does not apply —
  it applies to the squashfs *layer* (§2), which is why flatpaks and snaps both
  stay off it.
- **Lazy**: nothing is written until a snap is actually used, so a fresh stick is
  still empty, and only the *first* use pays the download.
- `bin/lsl-snap-fat.sh ensure` is idempotent — it skips anything already in
  `snap list`, so a snap the user deliberately removed stays removed.

### Costs, honestly

- **Installed snaps live on `/cow/upper`, which is tmpfs** — i.e. RAM, not the
  stick (`FINDINGS-USB-WRITE-PERFORMANCE.md:81`). 1-2 GB of snaps is 1-2 GB of
  RAM for the life of the session.
- A snap is **300-700 MB**, plus base snaps snapd pulls as dependencies. On a
  cache miss this is download-bound every time the cache is lost.
- **A cached snap is installed VERIFIED.** `snap ack` registers the cached
  `<name>_<rev>.snap.assert`, then `snap install --offline` verifies the snap
  against it — no store contact, full signature checking. Both files come from
  `snap download --revision=N <name>`, pinned to the revision actually
  installed, so the pair cannot disagree. (This is why caching re-fetches with
  `snap download` instead of copying out of `/var/lib/snapd/snaps/`: snapd keeps
  assertions in a content-hashed DB under `/var/lib/snapd/assertions/` with no
  name link back to the snap, so the `.assert` is not recoverable from the state
  dir.) `--dangerous` remains only as a degraded fallback for a cache written
  before this existed, and says so in the log when it is used.

### Still not done

Option B/F2FS — making snapd's *own* state persistent — is untouched, and is
still the only answer that survives many snaps without re-downloading anything.
It is machine-local, which is why it was not done here.

---

## The rule worth keeping

> **Find the precedent before inventing the mechanism.** Flatpaks had this exact
> problem — gigabytes of app data that must not go into a 4 GiB-capped layer — and
> the tree already solved it by keeping the bulk on FAT and publishing only a
> three-line config. The *principle* transfers to snaps even though flatpak's
> `--installation` mechanism does not. Look at how the neighbouring subsystem
> solved it first.

> **A comment describing a capability is not the capability.** `squashfs_config.sh:104`
> said the installer "can preload .snap files onto the USB (`/cdrom/snaps/`)". It
> could not — nothing wrote that directory and nothing installed from it. The
> comment has now been corrected to say what actually happens (a *list* is written;
> the stick fetches the payloads on first use). Verify the thing a comment claims
> exists, and fix the comment when you implement or refute it.

> **Ask whether the filesystem can express it, and then whether it can support the
> access pattern — in that order.** The first version of this document rejected
> FAT on expressibility grounds and was wrong, because a FUSE layer in the same
> repo had already answered it. The real blockers were concurrency (a no-op
> `lock()`), loop mounts, and mount ordering — none of which are expressibility
> questions. Note also that the cheapest answer to "how do we persist X" may be to
> persist X's *manifest* and let the machine refetch X once, rather than
> persisting X itself.
