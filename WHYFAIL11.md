# WHYFAIL11 — Why is `/home` still transient after the WHYFAIL10 fix?

Asked 2026-09-29, one boot after WHYFAIL10 was believed to have closed the
issue. Short answer: **WHYFAIL10 fixed the wrong half of *this* problem. It made
`mount_all.sh` *return* 0 when `/mnt/c` could not be mounted read-write, but
`mount_all.sh` still left `/mnt/c` **unmounted**. The caller does not care about
the exit code — it re-checks `lsl_data_dir_is_persistent`, which is a property of
the *live mount table*, not of a return value. So the fallback still fires and
`/home` is still a RAM overlay.**

This is the fourth WHYFAIL with the same symptom (7, 9, 10, 11) and the third in
a row where the diagnosis was right and the fix was incomplete.

---

## 1. What the operator saw

`/home` transient on the persistent boot entry. `/proc/cmdline` has no
`lsl_home=tmpfs`:

```
BOOT_IMAGE=/_ISO/linuxmint-22.3-cinnamon-64bit/vmlinuz boot=casper \
  layerfs-path=/cdrom/casper/filesystem.z0.squashfs rootdelay=15 quiet splash
```

```
$ cat /run/lsl-usb.state
LSL_MODE=usb-fallback
```

## 2. What was actually already fixed (do not re-litigate these)

Checked on the live stick this boot, and all **true**:

| Claim | Evidence |
|---|---|
| WHYFAIL9's `usb-fallback` recording is deployed | `LSL_MODE=usb-fallback` in the state file |
| WHYFAIL9's guards are active | `onboot.sh`: `/home already set up this boot (LSL_MODE=usb-fallback); skipping.` |
| WHYFAIL10's hivex staging shipped | `/cdrom/lsl-pkgs.txt` lists 3 staged `.debs`; `/cdrom/pkgs/*.deb` present |
| hivex is installed before `/home` mounts | journal `03:42:26 lsl-mount-home.sh: hivexregedit missing; installing staged .debs from /cdrom/pkgs ...` |
| the hivex failure marker is absent | `/run/lsl-usb.mount-missing-hivex` does not exist |

**`lslsetup` is not at fault.** It staged all three packages. WHYFAIL10's
Windows-side half is done and verified.

## 3. The unchanged chain — and the one link WHYFAIL10 missed

```
mount_all.sh cannot mount /mnt/c rw
  -> (WHYFAIL10) it now *returns 0* anyway          <- the "fix"
  -> but /mnt/c is still NOT MOUNTED
  -> lsl_data_dir_is_persistent = false             <- re-checks the mount table
  -> lsl-mount-home.sh: "data dir still not persistent; using a temporary
                        tmpfs-overlay /home for this boot (changes lost on reboot)"
  -> /home is transient          <-- the symptom
```

Boot journal, this boot:

```
03:42:37 lsl-mount-home.sh[1428]: lsl: HDD data dir /mnt/c/Users/lsl-usb not on a persistent volume yet; retrying drive mount...
03:42:37 ntfs-3g[1811]: Mounted /dev/nvme0n1p4 (Read-Only)
03:42:37 kernel: nvme0n1p4: Can't mount, would change RO state
03:42:37 lsl-mount-home.sh[1428]: lsl: WARNING: data dir still not persistent; using a temporary tmpfs-overlay /home for this boot (changes lost on reboot).
```

The retry *ran*. It scanned, it found `/dev/nvme0n1p4`. Then the mount itself
failed, and **nothing checked**.

### 3a. The old mount code, and why it fails silently

```bash
mkdir -p /mnt/c
if ntfs_is_dirty "$best_part"; then
    mount "$best_part" -t ntfs3 -o ro /mnt/c || mount "$best_part" -t ntfs-3g -o ro /mnt/c
else
    mount "$best_part" -t ntfs3 /mnt/c          # <-- no fallback, no check
fi
```

Three defects in five lines:

1. **The rw branch has exactly one attempt and no `ntfs-3g` fallback.** The
   kernel `ntfs3` driver refuses this volume (`Can't mount, would change RO
   state` — Windows Fast Startup / dirty state, the WHYFAIL6 §5 class). The FUSE
   driver mounts the very same volume happily, which is why `onboot.sh` later
   succeeds where this path did not. The code does not know that.
2. **No verification.** `mount` can return nonzero *or* return 0 while the
   kernel logged a refusal. The script never asks `mountpoint -q /mnt/c`.
3. **The dirty probe can be wrong.** `ntfs_is_dirty` grepped `ntfsfix -n` output
   for `dirty|hibernat|corrupt`. On an already-rw-mounted device `ntfsfix` prints
   `Refusing to operate on read-write mounted device` and **exits 0** — no match,
   so a device that could not be checked was reported *clean*, and the code then
   attempted an rw mount on it.

### 3b. The exit-status contract that was documented but never implemented

WHYFAIL10 §5a claims:

> the script exits 0 whenever `/mnt/c` is mounted, even if drive-letter mapping
> was skipped.

The `for i in {C..Z}` loop calling `parse_drive` was the last statement, so the
script's status was whatever `parse_drive Z` returned — normally **1**, because
`Z:` is usually unmapped. `lsl-mount-home.sh` masks this with `|| true`, so the
cost was a misleading status rather than a failure — but the documented contract
was not real, which is exactly the mistake WHYFAIL10 itself named:

> **A commented contract is not an implemented one.**

---

## 4. Root cause

> `mount_all.sh` mounted with a single `mount -t ntfs3` and ignored the failure,
> so `/mnt/c` was left unmounted; the caller re-derives persistence from the live
> mount table and therefore still falls back. WHYFAIL10 made the *exit code*
> graceful without making the *mount* succeed.

The general rule this breaks:

> **A fallback that fixes an exit code is not a fix.** Verify the state the
> caller actually observes — `mount_all.sh` must leave `/mnt/c` *mounted*, not
> merely return 0.

---

## 5. Fix

### `bin/mount_all.sh` — new `mount_ntfs()` + real exit contract

```bash
mount_ntfs() {                      # dev, mountpoint
    # rw before ro (a ro data dir cannot host the btrfs home image), but
    # ntfs3 then ntfs-3g (the kernel driver is the one that refuses volumes),
    # and verify with mountpoint -q after every attempt.
    # already-mounted is a no-op success (a second mount would EBUSY and be
    # misreported as "could not mount").
    # returns 0 only when $mnt is REALLY a mountpoint.
}
```

- **Driver fallback:** `ntfs3` → `ntfs-3g` (`ntfs-3g` is present on the image:
  `/usr/sbin/mount.ntfs-3g`), then the same pair read-only. A read-only
  `/mnt/c` still makes the data dir *persistent*, which is the point; an
  unmounted `/mnt/c` is what loses the home.
- **Verification:** every rung is confirmed with `mountpoint -q`; a lying exit
  status cannot be mistaken for success.
- **Already-mounted** short-circuits to success.
- **Caller now fails loudly:** if `/mnt/c` genuinely cannot be mounted,
  `mount_all.sh` prints `Error: could not mount ... /home will not be
  persistent` and exits 1. Previously this was silent.
- **Exit contract made real:** the script ends with
  `mountpoint -q /mnt/c && exit 0 || exit 1`, so the status means "C: is
  mounted", not "Z: happened to be mapped". The WHYFAIL10 §5a claim is now true.

### `bin/mount_all.sh` — `ntfs_is_dirty()` hardened

`Refusing to operate on read-write mounted device` is now recognised and treated
as **not dirty** (the kernel already accepted the volume, so the rw/ro decision
was made) instead of being silently grepped into a false "clean" verdict.

### `bin/mount_all.sh` — cleanup trap can no longer unmount `/mnt/c`

```bash
if [ "$needs_unmount" = true ] && [ -n "$best_mount" ] && [ "$best_mount" != "/mnt/c" ]; then
```

`best_mount` is normally a `mktemp` probe dir, but it *is* `/mnt/c` when the
volume was already mounted at scan time — and unmounting `/mnt/c` in the exit
trap would undo the one thing the script exists to establish.

### `tests/mount_all.tests.sh` — 6 new cases

Pinning exactly the defects above: ntfs3→ntfs-3g rw fallback; rw→ro fallback;
`rc=0` but unmounted must fail loudly; already-mounted is a no-op; the
`refusing to operate` text is not dirt; a genuine dirty report is still caught.

---

## 6. Verification

Live, on the stick, from a boot-like state (`/mnt/c` unmounted):

```
$ umount -l /mnt/c
$ findmnt -no SOURCE /mnt/c || echo "not mounted (mimics boot)"
not mounted (mimics boot)

$ . /cdrom/bin/lsl-common.sh; lsl_data_dir_is_persistent && echo yes || echo no
no

$ bash /cdrom/bin/mount_all.sh ; echo EXIT=$?
[1/3] Scanning for Windows installations...
    Found most recently booted Windows on: /dev/nvme0n1p4
    mounted /dev/nvme0n1p4 at /mnt/c (ntfs3)
EXIT=0

$ findmnt -no SOURCE,FSTYPE,OPTIONS /mnt/c
/dev/nvme0n1p4 ntfs3 rw,relatime,uid=0,gid=0,iocharset=utf8

$ . /cdrom/bin/lsl-common.sh; lsl_data_dir_is_persistent && echo yes || echo no
yes
```

And the caller's actual retry block, replayed:

```
before: persistent=no
lsl: HDD data dir /mnt/c/Users/lsl-usb not on a persistent volume yet; retrying drive mount...
lsl: data dir now on a persistent volume: /mnt/c/Users/lsl-usb
RESULT: would mount real home.btrfs, NOT usb-fallback
```

| Test | Result |
|---|---|
| `bash -n bin/mount_all.sh` | clean |
| sourceable guard (tests still work) | loads, `mount_ntfs`/`ntfs_is_dirty` callable |
| `tests/mount_all.tests.sh` | **9 passed, 0 failed** (was 3) |
| `tests/overlay-merge.tests.sh` | 13 passed, 0 failed |
| `tests/btrfs-growd.tests.sh` | 2 passed, 0 failed |
| `tests/lsl-common.tests.sh` | 67 passed, **1 failed — pre-existing, unrelated** |

The one `lsl-common` failure is `ensure_hivex_tools: absent + no pkgs -> fail`,
in the hivex section of `lsl-common.sh` — a file this change does not touch
(`md5sum`-identical to the deployed copy before the edit). It is independent of
`mount_all.sh`; flagged here rather than silently absorbed.

---

## 7. What is NOT yet in effect

- **The deployed stick still has the old `mount_all.sh` until it is updated** —
  this session edited `/cdrom/bin/mount_all.sh` (the live stick), so the *next*
  boot on this stick uses the fix, but any other stick needs the rebuild.
- **`/run` is RAM, so this boot's evidence is gone after reboot.** The state
  file and journal lines quoted above must be read *now* or not at all.
- **This boot's `/home` is still lost.** The mount was already taken when the
  fix was applied.
- **The `z0` layer still needs a rebuild** for the change to reach a fresh image.
- **WHYFAIL10's Rust patch** (`rust9x/lslsetup`, staging the hivex `.debs`) is
  present in the repo and evidently shipped to the stick, but the `lslsetup`
  patch file in `/cdrom/whyfail/` should still be confirmed against the build
  that produced this stick.

---

## 8. Related

- **`WHYFAIL10.md`** — the hivex-staging half. Correct about the producer
  (lslsetup) being unimplemented; incorrect in claiming `mount_all.sh`'s
  read-only fallback closed the loop. It closed the *status*, not the *mount*.
- **`WHYFAIL9.md`** — fixed the *trust* half (`uphome` believing a
  re-resolved prediction). Still correct and still active.
- **`FRAGILE_HOME.md`** — the standing inventory. Add: "a graceful exit code
  from a mount step is not evidence that the mount happened".
- **`WHYFAIL7.md`** — CRLF in `lsl-usb.env`; the same symptom from a third cause.
- **`WHYFAIL6.md` §5** — Windows Fast Startup / `hiberfil.sys`. This is the
  *reason* the kernel `ntfs3` driver refuses the volume, and therefore the
  upstream cause of the mount failure that this fix now routes around.

## TL;DR

`lslsetup` did its job — the hivex `.debs` were staged and installed before
`/home` mounted, and the WHYFAIL9/10 guards are all live and working. `/home` is
transient because **`mount_all.sh` failed to mount `/mnt/c` and nobody noticed**:
the kernel `ntfs3` driver refused the volume (`Can't mount, would change RO
state`, the Fast Startup class), the rw branch had no `ntfs-3g` fallback, and
the script never verified the mount. WHYFAIL10 had already made the *exit code*
graceful, which is precisely why the failure was invisible: the caller re-checks
`lsl_data_dir_is_persistent` against the live mount table, not the return value.
Fixed with a `mount_ntfs()` that tries `ntfs3` then `ntfs-3g`, then read-only,
verifies with `mountpoint -q` at every rung, fails loudly if `/mnt/c` is not
mounted, and an exit contract that finally means "C: is mounted". Pinned by 6 new
unit tests (9/9 pass).

## The rule worth keeping

> **A fallback that fixes an exit code is not a fix.**
> Verify the state the caller actually observes. `mount_all.sh` must leave
> `/mnt/c` *mounted*, not merely return 0 — because "persistent" is read from
> the mount table, and a mount table does not care what a script printed.
