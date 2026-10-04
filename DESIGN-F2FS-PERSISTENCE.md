# DESIGN — F2FS persistence with a boot-time identity scrub

**Status: P1 + P1b + P2 + P3 IMPLEMENTED (Linux side), 2026-10-03. P1b booted
in a real casper (QEMU/KVM, Mint 22.3); the carve itself has still only run
against a loopback disk.** Every claim about casper is quoted from the initrd on
the actual stick
(`unmkinitramfs /cdrom/_ISO/linuxmint-22.3-cinnamon-64bit/initrd.lz`), and every
claim about our own code is line-referenced to the tree it is written from.

| part | what | where |
|---|---|---|
| **P1** provision | format an already-present partition by label; never repartitions | `bin/lsl-f2fs-provision` |
| **P1b** create | shrink the FAT partition and CREATE the F2FS one, on first boot | `initramfs/lsl_f2fs_provision.sh` + `casper/initrd.f2fs.gz` |
| **P2** scrub | remove identity from the persistent upper before the overlay mounts | `initramfs/lsl_f2fs_scrub.sh`, injected by `build.sh` and `rust9x/lslsetup/src/lslfiles.rs` |
| **P3** regenerate | rewrite identity for THIS boot after `/home` is up | `bin/lsl-regen-identity`, called from `onboot.sh` |

**What is NOT done**, and is not claimed:

- **The full carve has not run inside casper.** It is proven on a loopback
  disk (geometry, f2fs format, mount, idempotence — §4.3) and the hook's
  *timing and injection* are proven in a real casper boot (§4.5), but the two
  have not been observed in the SAME boot: the QEMU run reached the driver
  gate before it could carve. §4.5 records exactly how far it got.
- **The denylist's completeness** (§7, §11). It removes the identity we know
  about, not machine identity. This is unchanged by the implementation and is
  the honest weak point.

**Scope:** how to make a persistent `/home` (or persistent root) on an F2FS
filesystem, while removing machine-specific files from the persistent upper
*before* the overlay is mounted — so the stick does not carry one machine's
identity onto another.

**Companion reading:** WHYFAIL12 (why the problem exists), WHYFAIL13 (the
"never invent a username" rule this design depends on), WHYFAIL14 (layer naming,
which this design deliberately does not touch).

---

## 1. Goal and non-goals

### Goal

1. A persistent writable layer on F2FS.
2. Machine-specific files (`netplan`/NM profile, `hostname`, `hosts`,
   `machine-id`, `resolv.conf`, `lightdm.conf`, `casper.conf`, snakeoil TLS)
   are **not** carried from one machine to the next.
3. Files that *must* exist get a correct per-boot value, not merely an absent one.
4. Failure is never fatal: any problem falls back to the current behaviour
   (tmpfs upper, changes lost) with a clear warning.

### Non-goals

- Replacing the squashfs layer stack, `home.sfs`, or `home.btrfs`. F2FS is a
  fourth mode, additive.
- Scrubbing the *root* filesystem's application state generally. Only the
  enumerated identity paths are in scope; anything else we cannot classify is
  left alone (see §7, "what this does not fix").
- Encrypting the persistent layer. Worth its own design; noted as a risk in §9.

---

## 2. Background: what the pieces actually are

### 2.1 The overlay upper is a directory

Today, USB mode (`bin/lsl-mount-home.sh`):

```
LSL_HOME_LOWER=/run/lsl-home-lower          # where home-<distro>.sfs is mounted
LSL_HOME_UPPER=/run/lsl-home-overlay/upper  # the writable layer
LSL_HOME_WORK=/run/lsl-home-overlay/work
...
mount -t tmpfs -o size=2048M tmpfs /run/lsl-home-overlay        # :141
...
mount -t overlay overlay \
  -o lowerdir=$LSL_HOME_LOWER,upperdir=$LSL_HOME_UPPER,workdir=$LSL_HOME_WORK \
  /home                                                          # :173
```

The upper is a plain directory on tmpfs, which is exactly why changes are lost on
reboot. **This design keeps the overlay and changes only what backs the upper.**

### 2.2 Casper's own persistence is the same shape

Stock casper already supports a persistent upper; ours is a variation, not an
invention. From `scripts/casper` and `scripts/casper-helpers` in the initrd:

| fact | source |
|---|---|
| persistence label defaults to `writable`, falling back to `casper-rw` | `casper-helpers:260-268` |
| the cow device is mounted **at `/cow`** | `casper:568` |
| `/cow/upper` is created there, existing content moved up | `casper:572-583` |
| the root overlay is mounted `upperdir=/cow/upper` | `casper:683` |
| `find_cow_device` probes **vfat only** for *file-backed* persistence | `casper-helpers` `find_cow_device` |
| if no labelled partition exists, casper can create one — **as ext4** | `casper-helpers:281-306` (`mkfs.ext4 -q -L ...`) |

Two consequences for this design:

- **A partition-labelled F2FS upper is the natural fit.** `find_cow_device`
  returns `/dev/disk/by-label/<label>` first, before any vfat scanning, so a
  properly labelled F2FS partition is used directly. The vfat-only restriction
  applies to *file*-backed persistence (`casper-rw` as a loop file), which this
  design does not use.
- **Casper's auto-create path hardcodes ext4.** We must therefore create and
  label the F2FS partition ourselves; we cannot delegate to casper.

### 2.3 The hook window is real and already ours

| what | where |
|---|---|
| our hook point (`run_scripts /scripts/casper-premount`) | `scripts/casper:926` |
| `/cow` created, `/cow/upper` made | `scripts/casper:551-583` |
| root overlay mounted | `scripts/casper:683` |

`mountroot()` (901) runs the premount hook at 926; `setup_overlay()` — containing
both 551-583 and 683 — is reached later via `mount_images_in_directory`
(139→145). The hook is therefore **strictly before** the upper exists.

`casper-helpers` is sourced at `casper:26`, so `find_cow_device`,
`root_persistence_label`, `get_fstype`, `get_backing_device`, `setup_loop` and
`where_is_mounted` are **already in scope** when a premount hook runs.

### 2.4 How a premount hook is actually invoked (measured)

`run_scripts` **sources the ORDER file** — it does not exec it:

```sh
# scripts/functions:126
run_scripts()
{
    initdir=${1}
    [ ! -d "${initdir}" ] && return
    shift
    . "${initdir}/ORDER"
}
```

and casper's own ORDER contains **executed** paths:

```
/scripts/casper-premount/10driver_updates "$@"
[ -e /conf/param.conf ] && . /conf/param.conf
/scripts/casper-premount/20iso_scan "$@"
```

Our existing hook is added differently — `build.sh:218` appends a **dot-prefixed**
line (` . /scripts/casper-premount/zz_lsl_hdd_mirror "$@"`), which is what makes
its `export LAYERFS_PATH` reach casper's shell.

Measured difference (a script that sets a variable and `return`s):

| ORDER line | hook ran? | variable visible after ORDER? |
|---|---|---|
| `./hook.sh "$@"` (executed) | yes | **no** — subshell |
| `. ./hook.sh "$@"` (sourced) | yes | **yes** |

Consequences for this design:

- The scrub hook **must be dot-sourced** for the same reason the HDD-mirror hook
  is: it needs to run in casper's shell, and it uses `return`, which is only
  valid in a sourced context. An executed script calling `return` would error.
- It must be defensive: it runs inside casper's shell, so a `set -e`-style abort
  or an unexpected `exit` would take the boot down with it. Every branch must
  `return 0` (never `exit`).
- The ORDER is sourced **before** `setup_overlay` runs, so ordering is guaranteed
  by position in the file, not by timing.

We already inject a hook into this directory (`build.sh:205-222`; the Rust
equivalent is `lslfiles.rs:1724 repack_initrd`), and `initramfs/lsl_hdd_mirror.sh`
is the working precedent — including its hard-won convention: **sourced, never
`panic`, never `exit`**.

---

## 3. Design overview

```
  BIOS/UEFI
      |
  initrd (we repack it)
      |
      +-- casper:926  run_scripts /scripts/casper-premount
      |     |
      |     +-- zz_lsl_hdd_mirror      (existing: points LAYERFS_PATH at HDD copy)
      |     +-- zz_lsl_f2fs_scrub      (NEW: mounts the F2FS cow, scrubs, unmounts)
      |
      +-- casper:551-583  /cow + /cow/upper  (our device, if we claimed the label)
      +-- casper:683      mount root overlay
      |
  userspace
      |
      +-- onboot.sh / lsl-mount-home.sh   (regenerate what was scrubbed)
      +-- session
```

The design has four parts:

- **P1 — Provision**: format the F2FS partition by label, once, if one exists
  (the userspace operator path, `bin/lsl-f2fs-provision`).
- **P1b — Create**: shrink the stick's FAT partition and CREATE the F2FS one,
  from the initrd on first boot (§4.3). This is the path that makes f2fs work
  for an ordinary user, because Windows cannot create the partition at all.
- **P2 — Scrub**: in the initrd, before the overlay, remove identity paths from
  the persistent upper.
- **P3 — Regenerate**: in userspace, after `/home` (or `/`) is up, write correct
  per-boot values for the paths that must exist.

P2 without P3 is not a fix: deleting `upper/etc/hostname` does not produce a
correct file, it *unmasks the lower* — revealing the previous image's copy from
`home-<distro>.sfs`. Both halves are required.

---

## 4. P1 — Provision the F2FS partition

### 4.1 Layout

```
/dev/sdX1   FAT32   the stick (existing, holds /cdrom)
/dev/sdX2   F2FS    label "lsl-persist", mounted at /persist
```

`/persist` is already a first-class concept in this repo: `lsl_is_usb_mode()`
treats `/persist` and `/persist/*` as the "USB" (i.e. stick-resident) case
(`bin/lsl-common.sh:179-186`), and `onboot.sh:182` already emits a
`/cdrom/persist.btrfs /persist btrfs loop,...` fstab line. Using the label
`lsl-persist` and the existing `/persist` mountpoint keeps this inside the
existing vocabulary rather than inventing a parallel one.

Why a **partition** and not a file: `find_cow_device` only accepts file-backed
persistence on vfat, and an F2FS image file on FAT32 would hit the same 4 GiB
ceiling that WHY_FAIL documents for appended layers.

### 4.2 Who creates it

| path | mechanism | notes |
|---|---|---|
| Windows (Rufus flow) | Rufus "persistent partition" size, then relabel + `mkfs.f2fs` | Rufus creates the partition; we set the label. Needs a `mkfs.f2fs` we cannot run on Windows without shipping one — **open question, §8** |
| Windows (nofmt flow) | `lslsetup` creates a partition + label | `lslsetup` already writes raw sectors and manages partitions; F2FS *formatting* is the gap |
| Linux (existing stick) | `bin/lsl-*` helper, opt-in | simplest to build and test first; no Windows tooling required |

**Recommendation: build the Linux-side provisioner first.** It is the only one we
can test in QEMU, and it makes the scrub (P2) testable immediately. Windows-side
provisioning is a follow-on gated on the `mkfs.f2fs` question in §8.

### 4.3 P1b — creating the partition at boot (what actually shipped)

P1 above can only format a partition that already exists, and Windows cannot
create one: shrinking FAT32 has no API (Disk Management greys out Shrink
Volume; diskpart refuses). So §8.1's recommendation is what ships — **format on
first boot from Linux** — and P1b is the path that does it.

```
install time (Windows)          first boot (initrd)               userspace
──────────────────────          ────────────────────              ─────────────
PERSISTENCE page picks f2fs →   casper/initrd.f2fs.gz      →     lsl-mount-home.sh
  + a size                        zz_lsl_f2fs_provision         mounts lsl-persist
appends initrd.f2fs.gz           reads lsl_f2fs_provision=<GiB>  lsl-regen-identity
writes the cmdline flag          repartitions ONCE              rewrites identity
                                  zz_lsl_f2fs_scrub scrubs
```

**Why the size travels on the kernel cmdline.** It cannot come from
`lsl-usb.env`: that file lives on the very medium the hook repartitions, and it
is read in userspace by `lsl-common.sh`, long after this window. The cmdline is
the only channel that survives. (`install_from_iso`'s `f2fs_gib` = 0 means
"not requested", and then every boot entry is byte-for-byte unchanged.)

**Why the hook is inert by default.** It returns immediately unless
`lsl_f2fs_provision=<GiB>` is present, so shipping it in the initrd is safe for
every backend — but the initrd is only *installed* when the PERSISTENCE page
chose f2fs, because this hook repartitions the boot medium and must never ride
along on a boot that did not ask for it. The scrub rides in the same initrd,
sourced immediately after the provision hook, because it cleans what provision
creates.

**The two invariants that are not stylistic.** Both were measured, and both are
recorded at `bin/lsl-f2fs-resize:16-25`, which remains the userspace operator
tool for a stick that is already partitioned:

- shrink the **filesystem before the partition**. `sfdisk` will cut the
  partition while the filesystem still claims the old size; the result mounts
  with no error and then fails on any access past the boundary.
- **verify the FAT BPB** after `fatresize`, because `fatresize` was measured to
  exit 0, print a banner, and leave the BPB untouched.

**The safety gate.** A wrong resize is unrecoverable data loss, so the hook
requires three independent proofs before writing a byte: the boot medium is
unmounted, it has been identified *by content* (never by assuming `/dev/sda`),
and no loopback still pins it. Any failure is a logged no-op. It also refuses a
stick that already has a Linux partition (§8.2 — never hijack).

Note what the gate does **not** do: it never unmounts the boot medium to "free"
it. A lazy `umount -l` detaches the namespace while writeback may still be in
flight, which is exactly how you corrupt the filesystem you are about to shrink;
and casper needs `/cdrom` *after* this hook, so taking it away would break the
boot outright. Both outcomes are worse than no persistence, so the hook refuses.

**Tools.** casper's initrd ships `mkfs.ext4` but not `sfdisk`, `fatresize` or
`mkfs.f2fs`, and the live root does not exist yet at `casper-premount` time. They
are staged from the ISO's own `casper/filesystem.squashfs` by
`scripts/extract-f2fs-tools.sh` into `f2fs-tools.tar.gz` (binaries + `ldd`
closure) and unpacked into `/run` at boot by `initramfs/lsl-f2fs-tools.sh`. No
download, no vendored binary, no version skew with the kernel's f2fs driver.
Missing tools degrade to a no-op with a console line, never a failed install.

> **MEASURED (2026-10-03, WSL2 + loopback, util-linux 2.37).** The hook ran
> end-to-end against a real block device: 12 GiB FAT carved to 10 GiB + a
> 2 GiB f2fs partition labelled `lsl-persist`, which then mounted and accepted
> an `upper/`, and a second run changed nothing. `tests/f2fs-provision-hook.tests.sh`
> asserts all of that, including the corruption check (filesystem smaller than
> its partition) and idempotence.
>
> Three facts that test had to establish, each of which had been assumed:
>
> - **`sfdisk` `size=` is in SECTORS**, in both the input we write and the
>   output we read (`10240` means 5 MiB, not 10). Both directions agreeing is
>   what makes the hook's arithmetic correct; had one been KiB the carve would
>   silently produce a filesystem 1024x larger than its partition.
> - **Partition node naming is not `<disk>N`.** A loop device's first
>   partition is `/dev/loop0p1`, not `/dev/loop01` — so the hook resolves the
>   node by probing (`lsl_part_node`) instead of concatenating.
> - **An f2fs `-o ro` mount does refuse writes.** §8.3's open question is
>   answered for the clean case: `rm` on an existing file returns non-zero
>   ("Read-only file system") and the file survives. Only the *dirty*-f2fs
>   case remains unmeasured.

> **MEASURED, and it moved the goalposts (2026-10-03, QEMU/KVM, Mint 22.3).**
> A real casper boot with this hook injected proves the TIMING premise and
> surfaces two things the earlier design had wrong:
>
> - **The premise holds.** The hook runs inside `/scripts/nfs-premount` at
>   ~3.4 s, and at that instant the boot medium is **not mounted**: no `/cdrom`
>   or `vda1` mount appears before it. casper's own `loop0` (the squashfs) is
>   created *afterwards* (3.82 s). So `casper-premount` really is early enough
>   to repartition the stick, and the whole "hook first" decision is sound.
> - **f2fs is NOT builtin in the Mint kernel — it is a module.** The ISO ships
>   `boot/grub/*/f2fs.mod` (a builtin filesystem has no `.mod`), and
>   `f2fs.ko.zst` lives in the initrd's `early3` cpio at
>   `usr/lib/modules/6.14.0-37-generic/kernel/fs/f2fs/`. The first QEMU boot
>   logged `no f2fs driver in this kernel` and skipped — the hook had not tried
>   to load the module sitting right there. It now calls `modprobe f2fs` (kmod
>   is in the `main` cpio and decompresses the `.zst` itself), and a re-run
>   logged `modprobe f2fs: loaded`.
> - **`fatresize` and `mkfs.f2fs` are NOT on the Mint ISO** — not in the rootfs,
>   not in `pool/`. Only `sfdisk` (util-linux, with its `ldd` closure) can be
>   staged from the image. `DESIGN-PERSISTENCE-PANE.md` §6.1's tooling table is
>   **WRONG** on this point: it lists `mkfs.f2fs` as present, having checked the
>   live root of a machine where `f2fs-tools` had been installed. A stock Mint
>   ISO does not carry it.
>
> **Consequence — the design does not yet work end-to-end.** The boot now loads
> the driver and stages `sfdisk`, but cannot shrink FAT (no `fatresize`) or
> format F2FS (no `mkfs.f2fs`). The hook degrades exactly as designed — a logged
> no-op, boot unaffected — but the feature is not functional until those two
> binaries are sourced. Options, none free:
>
> 1. **Ship the two binaries** in the bundle (adds ~200 KB plus `f2fs-tools`
>    licensing to check) — contradicts the design's "no shipping a mkfs.f2fs".
> 2. **`apt-get install` them from the ISO's own `pool/`** — they are not there
>    either, so this needs network on first boot, which the hook cannot assume.
> 3. **Pre-install them into the stick** at build time (the z0 layer or
>    `bin/`), so the initrd mounts them off the medium — but the medium is what
>    we are about to repartition, so they must be staged to `/run` first.
>
> Option 3 keeps "no binaries in git" and needs no network; it is the one the
> evidence points at. **Do not treat P1b as working until this is resolved.**

> **STILL OPEN: the carve has not run inside casper.** The hook now reaches the
> tool check in a real boot, but `fatresize`/`mkfs.f2fs` are absent from the ISO
> so it stops there. The geometry (loopback), the timing and the driver load
> (QEMU) are each proven; the three have not yet been observed working
> **together** in one boot. Until they are, P1b is not functional — only safe.

### 4.4 Enabling it

New env knob, following the existing `lsl-usb.env` / `lsl-common.sh:73-81`
pattern:

```
LSL_PERSIST=0            # 0 = off (default), 1 = F2FS upper when available
LSL_PERSIST_LABEL=lsl-persist
LSL_PERSIST_SCRUB=1      # run the identity scrub (P2); 0 to disable
LSL_PERSIST_REGEN=1      # run the per-boot regenerators (P3)
```

Default **off**. A new persistence mode that changes where a user's data lives
must be opt-in; the current tmpfs behaviour stays the default until this is
proven on real hardware.

---

## 5. P2 — The scrub, in the initrd

### 5.1 Where it runs and why that is safe

The hook runs at `casper:926`, before `setup_overlay` (`casper:551-583`) creates
`/cow/upper`. At that moment the cow device is **not mounted**, so the hook
mounts it itself, scrubs, and unmounts — leaving casper to mount it normally
afterwards.

```
scripts/casper-premount/zz_lsl_f2fs_scrub
```

must be **sourced** (dot-prefixed in `ORDER`, exactly as `build.sh:218` does for
`zz_lsl_hdd_mirror`) — verified in §2.4: an executed hook runs in a subshell, so
its exports would not reach casper and its `return` would be an error. It runs
**inside casper's shell**, so it must never `panic` or `exit`; every failure path
is `return 0`, degrading to "no scrub this boot", never to no boot.

### 5.2 Sketch

```sh
#!/bin/sh
# zz_lsl_f2fs_scrub - remove machine-specific files from the persistent upper
# before casper mounts it. Runs as a casper-premount hook (SOURCED, never exit).
#
# Failure policy: ANY problem -> do nothing, log, return. The boot proceeds with
# the persistent upper unscrubbed (today's behaviour without this hook).

[ "${LSL_PERSIST:-0}" = "1" ] || return 0
[ "${LSL_PERSIST_SCRUB:-1}" = "1" ] || return 0

_lsl_scrub_dev="$(find_cow_device "$(root_persistence_label)" 2>/dev/null)"
[ -b "$_lsl_scrub_dev" ] || { echo "lsl-scrub: no persistent cow device"; return 0; }

_lsl_scrub_mnt=/mnt/lsl-scrub
mkdir -p "$_lsl_scrub_mnt"

# Read-only first: we can inspect without risking a journal replay on a
# filesystem that might be dirty. Only remount rw if there is something to do.
if ! mount -t "$(get_fstype "$_lsl_scrub_dev")" -o ro "$_lsl_scrub_dev" "$_lsl_scrub_mnt"; then
    echo "lsl-scrub: cannot mount $_lsl_scrub_dev; skipping"
    return 0
fi

# The upper may be at the mount root (fresh, casper moves it) or under upper/.
# Handle both, and treat "neither" as nothing to do rather than an error.
_lsl_upper="$_lsl_scrub_mnt/upper"
[ -d "$_lsl_upper" ] || _lsl_upper="$_lsl_scrub_mnt"

_lsl_found=0
for _p in \
    etc/netplan \
    etc/NetworkManager/system-connections \
    etc/hostname etc/hosts etc/machine-id etc/resolv.conf \
    etc/casper.conf etc/lightdm/lightdm.conf \
    etc/ssl/certs/ssl-cert-snakeoil.pem \
    etc/ssl/private/ssl-cert-snakeoil.key
do
    [ -e "$_lsl_upper/$_p" ] && _lsl_found=1
done

if [ "$_lsl_found" = "1" ]; then
    # Remount read-write ONLY now (nothing to do -> never touch the device).
    mount -o remount,rw "$_lsl_scrub_mnt" 2>/dev/null || {
        echo "lsl-scrub: cannot remount rw; skipping"
        umount "$_lsl_scrub_mnt" 2>/dev/null
        return 0
    }
    for _p in \
        etc/netplan \
        etc/NetworkManager/system-connections \
        etc/hostname etc/hosts etc/machine-id etc/resolv.conf \
        etc/casper.conf etc/lightdm/lightdm.conf \
        etc/ssl/certs/ssl-cert-snakeoil.pem \
        etc/ssl/private/ssl-cert-snakeoil.key
    do
        rm -rf "$_lsl_upper/$_p"
    done
    sync
    echo "lsl-scrub: scrubbed identity paths from $_lsl_upper"
fi

umount "$_lsl_scrub_mnt" 2>/dev/null
return 0
```

### 5.3 Design notes on the scrub

- **Read-only probe first.** The device may be dirty or foreign; inspecting
  before any write means a filesystem we do not understand is never modified.
- **`rm -rf` on directories, not `dir/*`.** Removing `etc/netplan` removes the
  directory; removing only its contents leaves an empty directory that some
  tools treat as "no config" and others as "unreadable". Verified behaviour in
  the mksquashfs case (WHYFAIL12 §6); for the overlay the same reasoning applies.
- **Delete the *upper's* copy, never touch the lower.** `home-<distro>.sfs` and
  the squashfs layers are read-only and shared; only the writable layer is ours.
- **Do not fail the boot.** Every branch `return 0`.
- **`sync` before unmount** — the scrub must be durable before casper mounts the
  same device, or a lazy write could land after casper's mount and reintroduce
  the file.

### 5.4 Two ways to wire the upper, and a preference

| option | how | trade-off |
|---|---|---|
| **(a) claim casper's label** | label the F2FS partition `writable` (or `casper-rw`) so casper itself mounts it as `/cow`; we only scrub | casper owns the mount, we get its snapshot/log handling free; but casper then *also* uses it as the root upper, so root-state persists too |
| **(b) our own `/persist`** | keep `LSL_PERSIST_LABEL=lsl-persist`, mount it ourselves and point `LSL_HOME_UPPER` at it in userspace | narrower blast radius: only `/home` persists; root stays ephemeral as it is today |

**Preference: (b).** Option (a) would make `/etc` persistent *for the whole
system*, which is precisely the problem WHYFAIL12 documents, and it would hand
the mount to casper before our userspace regenerators can run. Option (b) keeps
the persistent surface to one directory tree — the smallest thing that delivers
the user-visible benefit ("my files survive a reboot") — and keeps the
regeneration step in `lsl-mount-home.sh`/`onboot.sh` where the resolved desktop
user and the existing Wi-Fi replay already live.

---

## 6. P3 — Regenerate after the overlay is up

Scrubbing unmasks the lower. Each scrubbed path needs an owner:

| path | owner | mechanism |
|---|---|---|
| `hostname`, `hosts` | `lsl-mount-home.sh` | from `$LSL_DESKTOP_USER` (`lsl_desktop_user`, already resolved) |
| `lightdm.conf` | `config.sh` | `autologin-user=$LSL_DESKTOP_USER` — replaces the hardcoded `ubuntu` |
| `casper.conf` | `config.sh` | `USERNAME`/`HOST` from the live session, not a captured value |
| `machine-id` | `onboot.sh` | `systemd-machine-id-setup` (or leave absent and let systemd create it) |
| `resolv.conf` | `onboot.sh` | already written per boot by NetworkManager; ensure it is not persisted |
| snakeoil TLS | `onboot.sh` | `make-ssl-cert generate-default-snakeoil --force-overwrite` |
| netplan/NM Wi-Fi | `persist-wifi.sh` | already records `nmcli device wifi connect …` to `/cdrom/wifi.sh`; replay instead of persisting the profile |

`onboot.sh`'s `lsl_merge_fstab()` (`onboot.sh:139-233`) is the **pattern to
copy**: it rewrites a delimited block on every boot, is idempotent, and is
already the reason `/etc/fstab` is the one item in WHYFAIL12 that is safe.

### 6.1 Tooling availability (checked on the real image, not assumed)

| tool | needed for | present? |
|---|---|---|
| `systemd-machine-id-setup` | regenerate `machine-id` | yes — `/usr/bin/`, from `systemd` |
| `make-ssl-cert` | regenerate snakeoil | yes — `/usr/sbin/` |
| `mkfs.f2fs` | P1 provisioning (Linux side) | **NO — see the correction below** |
| `fatresize` | shrinking FAT32 from Linux | **NO — see the correction below** |
| `sfdisk` | repartitioning | yes — `/usr/sbin/` |
| kernel `f2fs` driver | mounting the layer | **as a MODULE, not builtin** — `f2fs.ko.zst` in the initrd; needs `modprobe f2fs` |

> **CORRECTION (2026-10-03, measured).** This table was checked against a
> machine's LIVE ROOT, where `f2fs-tools` and `fatresize` happened to be
> installed. A **stock Mint 22.3 ISO carries neither**: its rootfs has no
> `mkfs.f2fs` or `fatresize`, and its `pool/` has no `f2fs-tools` or `fatresize`
> `.deb` either. Only `sfdisk` (from util-linux) can be staged out of the image.
> Worse, f2fs is a loadable module rather than builtin — the ISO ships
> `boot/grub/*/f2fs.mod`, and the `.ko.zst` lives in the initrd, so the hook must
> `modprobe f2fs` before it can even format. Both facts were found by booting
> the real initrd, not by reading it.

So P3 needs no new dependencies on the image, but P1's Linux-side path **does**:
`fatresize` and `mkfs.f2fs` must be sourced from somewhere (see §4.3 for the
options). `systemd-machine-id-setup` also takes `--root=PATH`, which is useful
if the regeneration ever needs to target the overlay's root from outside it.

---

## 7. What this design does not fix

Stated plainly so it is not mistaken for a complete solution:

1. **Anything under `/home` that is machine-specific.** This scrubs `/etc`
   paths; a user's `~/.config` may hold its own machine facts (monitor layouts,
   GPU settings, recent-device lists). Out of scope here — `/home` is the
   *point* of the persistence.
2. **Applications we do not control** that write machine identity elsewhere
   (anywhere in `/var/lib`, for instance). The enumeration is a denylist, and
   denylists are incomplete; see §9.
3. **Credentials.** Scrubbing does not help if the *lower* carries a PSK, or if
   the persistent upper holds one we did not enumerate.
4. **The root filesystem**, in option (b). Deliberate: root stays ephemeral.
5. **First-boot correctness on the very machine that created the layer.** The
   scrub is a no-op there by definition; it only matters on the *second* machine.

---

## 8. Open questions

1. **How do we format F2FS on Windows?** `lslsetup` targets Windows 95+ with no
   external tools. Options: ship a `mkfs.f2fs` (licensing/size), have the
   *first boot* format it from Linux (simplest, defers the problem), or require
   a pre-formatted partition from Rufus. **Recommendation: format on first boot
   from Linux**, with the Windows side only creating and labelling the
   partition — which it can already do.

   > **RESOLVED, and the recommendation's last clause was WRONG.** "With the
   > Windows side only creating and labelling the partition" is not possible:
   > creating that partition requires *shrinking* the existing FAT partition,
   > and Windows has no API for that (Shrink Volume is greyed out; diskpart
   > returns "the volume cannot be shrunken because the file system does not
   > support it"). So the Windows side creates nothing and labels nothing — it
   > writes only the INTENT, `lsl_f2fs_provision=<GiB>` on the kernel cmdline,
   > and `initramfs/lsl_f2fs_provision.sh` does the shrink, the repartition and
   > the format from the initrd on first boot (§4.3). The installer creates no
   > partition of its own.
   >
   > This also settles the tools question that gated it: there is no need to
   > ship a Windows `mkfs.f2fs`, because the formatting happens in the initrd,
   > where `mkfs.f2fs` is taken from the ISO's own rootfs.
2. **Which label?** `lsl-persist` (ours, option b) vs `writable`/`casper-rw`
   (casper's, option a). Recommendation is (b), but a machine that already has a
   `casper-rw` from another tool must not be hijacked — the hook should refuse
   to use a device it did not create.
3. **F2FS dirty-state behaviour.** F2FS has no `fsck` equivalent to ext4's
   journal replay, and a `ro` mount of a dirty filesystem may fail. Is `-o ro`
   the right probe? Needs measurement on a power-cut image.

   > **PARTLY ANSWERED (2026-10-03).** On a cleanly-unmounted f2fs, `-o ro`
   > **does** enforce read-only: `rm` on an existing file fails with "Read-only
   > file system" and the file survives, so the scrub's inspect-then-remount-rw
   > pattern is safe here. What is still unmeasured is the DIRTY case — whether
   > a filesystem that lost power refuses the `ro` mount outright, which would
   > mean "scrub did not run". That remains the safe direction, and it is
   > logged rather than silent (`lsl_f2fs_scrub.sh:85`). Reproducing a dirty
   > f2fs needs a power-cut image, not a loopback test.
4. **Where does the scrub list live?** Currently duplicated in the heredoc above.
   It is baked into the initrd, so it only changes with a repack — meaning a
   stick built before a list change keeps the old list. Acceptable, but the
   version should be logged (e.g. `lsl-scrub: list-v3`) so a stale stick is
   diagnosable.
5. **Does `/persist` already have an owner conflict?** `onboot.sh:182` emits a
   `/cdrom/persist.btrfs /persist` line and `bin/uproot:503` has a commented-out
   `/persist` bind. These need reconciling before a second meaning is assigned
   to the same mountpoint.

---

## 9. Risks

| risk | severity | mitigation |
|---|---|---|
| Scrub deletes something a user relied on | medium | start read-only; denylist is small and enumerated; `LSL_PERSIST_SCRUB=0` escape hatch |
| Scrub fails and the stick silently carries identity anyway | medium | log loudly; consider a visible marker on the desktop when the scrub did not run |
| A stick from another tool (mkusb, Rufus `casper-rw`) gets hijacked | medium | refuse to use a label we did not create (open question 2) |
| Persistent upper grows without bound | medium | F2FS partition is fixed-size; need a free-space warning, mirroring `lsl_ensure_cdrom_space` |
| Denylist incompleteness (a machine-specific path we did not think of) | **high** | this is the honest weak point; see "rule worth keeping" |
| PSK in cleartext on a removable medium | **high** | out of scope here, but should not ship without consideration — encryption is its own design |
| Repacked initrd diverges from upstream casper | low | `initrd.safe.lz` is preserved and a "(safe)" boot entry offered, already implemented |
| A future casper release renames `find_cow_device`/moves the hook point | medium | the hook must be defensive: if helpers are missing, log and return 0. Verify on each new Mint/Ubuntu base. |

---

## 10. Verification plan

Nothing here is verifiable on this box (no F2FS-capable QEMU harness for this
flow yet, and the scrub runs in an initrd). The plan, in dependency order:

1. **Unit (Linux):** a shell test that builds a throwaway F2FS image, populates
   an `upper/` with each identity path plus a control file, runs the scrub
   logic, and asserts (a) identity paths gone, (b) control file present,
   (c) idempotent on a second run, (d) exit status 0 on every failure branch
   (missing device, unreadable fs, read-only remount failure). This mirrors how
   `tests/lsl-common.tests.sh` covers `lsl_merge_fstab`.
2. **Ordering (QEMU):** assert the hook really runs before the overlay — the
   repo already has `tests/qemu-boot-test.sh` and the HDD-mirror tests to model
   this on. A cheap proxy: have the hook echo a marker into the cow device and
   assert casper's later mount sees it.
3. **Two-machine simulation:** boot once in QEMU with one "machine identity"
   seeded, then boot the same image with a *different* seeded identity and
   assert the second boot does not see the first's values. This is the actual
   user-visible property.
4. **Real hardware:** build on a spare stick, boot on two physical machines,
   confirm `/home` persists and `hostname`/Wi-Fi follow the *current* machine.
5. **Regression:** the existing suites must stay green
   (`lsl-common.tests.sh`, `casper-layer-check.sh`, `mount_all.tests.sh`,
   `lsl-merge-suggest.tests.sh`, `lsl-reclaim-win-swap.tests.sh`).

A test *without* which this design should not ship: **step 3**, because step 1
tests the scrub in isolation and would pass even if the hook never ran at the
right moment.

---

## 11. Discussion — what is solid, what is not

**Solid, because it is read from the source rather than assumed:**

- The hook point exists and is ours (`casper:926`, before `casper:551-583`).
- The helpers are in scope (`casper-helpers` sourced at `casper:26`).
- The upper is an ordinary directory, so the operation is ordinary file removal.
- The pattern already ships: `zz_lsl_hdd_mirror` is injected the same way.

**Not solid, and should not be presented as if it were:**

- **No part of this has been run.** Not the scrub, not the provisioning, not the
  regeneration.
- **The denylist is the weak point.** This design removes files we *thought of*.
  WHYFAIL12 listed them by inspecting one machine; a different workload will
  write machine facts we did not enumerate, and there is no mechanism here that
  would notice. A stronger design would invert it — persist an *allowlist* of
  paths known to be machine-independent — but that is a much larger change to
  what `home.sfs`/the upper contains and is out of scope for this document.
- **Formatting F2FS on Windows is unresolved** (§8.1), and that is the difference
  between "works on a stick we prepared by hand" and "works for a user".
- **The read-only probe is unproven on a dirty F2FS** (§8.3). If `-o ro` fails on
  a filesystem that was not cleanly unmounted, the failure mode is "scrub never
  runs", which is the *safe* direction but silently defeats the feature.

**The honest summary:** the mechanism is straightforward and the hook point is
genuinely ours, so P2 is low-risk and testable. P1 (provisioning, especially on
Windows) and the denylist's completeness are where the real work and the real
risk are.

---

## The rule worth keeping

> **Related:** `DESIGN-PERSISTENCE-PANE.md` designs the wizard page that would
> offer this (backend choice, space slider, EatMyData, cache-on-tmpfs).
> `DESIGN-BOOT-TO-RAM-VARIANTS.md` examines the follow-on proposal
> (multiple Boot-to-RAM entries, and cloning the F2FS layer with dm-clone).
> Short version: the extra variants are worth building; the clone idea does not
> work as specified, for reasons visible in dm-clone's own documentation.

> **A scrub is a denylist, and a denylist is a promise you cannot keep.**
> This design removes machine identity we enumerated by inspecting one machine.
> It is worth building because the enumerated set covers the boot-critical
> cases (Wi-Fi, hostname, autologin), but it should be described as
> "removes the machine identity we know about", never as "removes machine
> identity".

> **Scrubbing unmasks; regenerating fixes.** A delete is half an operation —
> it reveals the lower's stale copy. Any scrub must be paired with a
> regenerate step or it relocates the staleness rather than removing it.

> **Check whether the code you are relying on already exists before writing it.**
> The hook point, the helpers, the injection mechanism and even the
> "rewrite a block every boot" pattern (`lsl_merge_fstab`) were all already in
> this tree. The design is mostly assembly, not invention.
