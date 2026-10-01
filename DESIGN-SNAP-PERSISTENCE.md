# DESIGN — Persisting snaps on the stick

**Status:** design only. No code written. Every claim about the tree is
line-referenced; every claim about snapd's layout is from its own documentation and
checked against this running system.

**Question:** how do we permanently install snaps on the stick, so they survive a
reboot?

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
| **FAT (`/cdrom/snapd`)** | stick size | reboot, and travels with the stick | FAT has no permissions/ownership, no symlinks — **snapd stores symlinks and expects ownership**; high risk |
| **F2FS partition** (`DESIGN-F2FS-PERSISTENCE.md`) | partition size | reboot | a real POSIX filesystem; **the only option that is actually correct** |

**FAT is the tempting choice and probably wrong.** snapd's state includes symlinks
(`/snap/<name>/current`) and files it expects to own. FAT cannot represent either.
That is a strong argument that snap persistence belongs **after** the F2FS work,
not before it.

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

## The rule worth keeping

> **Find the precedent before inventing the mechanism.** Flatpaks had this exact
> problem — gigabytes of app data that must not go into a 4 GiB-capped layer — and
> the tree already solved it by keeping the bulk on FAT and publishing only a
> three-line config. The *principle* transfers to snaps even though flatpak's
> `--installation` mechanism does not. Look at how the neighbouring subsystem
> solved it first.

> **A comment describing a capability is not the capability.** `squashfs_config.sh:104`
> says the installer "can preload .snap files onto the USB (`/cdrom/snaps/`)". It
> cannot — nothing writes that directory, and nothing installs from it. The comment
> is an intent that was never implemented, and it reads as a description of working
> code. Verify the thing a comment claims exists.

> **Check the filesystem can represent what you are storing.** FAT cannot hold
> symlinks or ownership; snapd's state needs both. The capacity question ("is there
> room?") is the one people ask; the representability question ("can this filesystem
> express it?") is the one that decides.
