# WHYFAIL12 — Machine identity in the upper: where it lives, and what would leak it

Asked 2026-10-01, inspecting `/cow/upper` on a running stick: *"Are there files that
would, if persisted, cause booting the stick on a new machine with different
hardware to fail?"*

Short answer: **the machine-identity files are real and are in `/cow/upper`; what
saves us today is that `uproot` packs a *different* upper, and nothing writes
those files through it.** `uproot`'s append path runs
`mksquashfs /tmp/squashfs/upper` with only three exclusions (flatpak, apt
archives, apt lists) — all size-motivated — so there is no *guarantee* identity
files stay out, only the accident that today's writers do not put them there.
See §0 for which overlay is which; that distinction is the whole answer. §6
works out what an F2FS persistence layer actually is (an overlay upper) and how
to scrub it before the overlay mounts.

The stick inspected was `linuxmint-22.3-cinnamon-64bit` (its own `/proc/cmdline`:
`BOOT_IMAGE=/_ISO/linuxmint-22.3-cinnamon-64bit/vmlinuz boot=casper rootdelay=15
quiet splash`), and it booted as `user=ubuntu` — see the sibling finding on the
live-session username, which is the same root cause family: casper's defaults
leaking into persistent state.

---

## 0. Which overlay, exactly — this is two different things

There are **two** uppers on a running stick and only one is packed into a layer.
Conflating them is the mistake this section exists to prevent.

| overlay | upperdir | mounted by | packed into a layer? | can we scrub pre-mount? |
|---|---|---|---|---|
| casper's **root** overlay | `/cow/upper` | initramfs (`scripts/casper:683`) | no — RAM, discarded | **yes** — a `casper-premount` hook runs first (`:926`, §6) |
| uproot's **config** overlay | `/tmp/squashfs/upper` | `bin/uproot` | **yes** (`mksquashfs`) | n/a — empty by construction |

`uproot` mounts a *fresh, empty* overlay over the same lowerdirs at
`/tmp/squashfs/root` (`bin/uproot:437-464`), runs `squashfs_config.sh` in a chroot
into it, and then packs **that** upper. Files land in it only when something
writes *through* that mount.

So the honest question is not "what is in `/cow/upper`" (that is where §1's files
were observed, and none of them are packed) but **"what does anything write
through `/tmp/squashfs/root`"**. Today that is a much shorter list:

| written through the config overlay | by |
|---|---|
| `/etc/resolv.conf` | `uproot:516-518` (explicit, for chroot DNS) |
| `/etc/bash.bashrc` (`export PATH=/cdrom/bin:$PATH`) | `config.sh:418-427` |
| `/etc/systemd/system/*` | `config.sh` — **intended payload** |
| apt/dpkg side-effects under `/etc` | the chroot package install |

§1's files (`fstab`, `netplan`, `hostname`, `machine-id`, `lightdm.conf`) are
**not** written through it, so with today's design they do not reach a layer. They
would matter the moment anything began persisting `/` more directly — which is
exactly the F2FS question §6 answers.

The lesson is still the one in the closing rule, but it has to be aimed
correctly: **the risk is not "the whole of `/etc` is packed" (it is not); it is
that nothing yet *guarantees* identity files stay out.** An exclusion list built
for size will not hold that line, because it was never asked to.

## 1. What is actually in the upper

Every path below had a *fresh* mtime from this boot, i.e. it is a copy-up in the
upper rather than a file from the read-only squashfs base:

| file | written | verdict on new hardware |
|---|---|---|
| `/etc/fstab` | 2026-10-01 02:41 | **stale UUIDs, but self-corrects** |
| `/etc/netplan/90-NM-a6561bcf-….yaml` | 2026-10-01 02:41 | **breaks the Wi-Fi profile** |
| `/etc/hostname` | 2026-10-01 02:41 | wrong identity |
| `/etc/hosts` | 2026-10-01 02:41 | `127.0.1.1 ubuntu` |
| `/etc/lightdm/lightdm.conf` | 2026-10-01 02:41 | **autologin to a user that may not exist** |
| `/etc/machine-id` | 2026-09-30 19:23 | shared identity across machines |
| `/etc/resolv.conf` | 2026-09-30 19:10 | this LAN's router |
| `/etc/ssl/certs/ssl-cert-snakeoil.pem` + key | 2026-10-01 02:41 | one snakeoil for every machine |
| `/etc/apt/sources.list.d/brave-browser-release.sources` | 2026-09-30 19:24 | benign |
| `/etc/flatpak/installations.d/lsl-fat.conf` | 2026-10-01 02:41 | intentional (the FAT flatpak install) |
| `/boot/initrd.img-6.14.0-37-generic` | 2026-09-30 19:24 | regenerated here (82 MB) |

## 2. The two that actually break a boot

### 2a. `/etc/netplan/90-NM-a6561bcf-….yaml` — pinned to this laptop's NIC

```yaml
network:
  version: 2
  wifis:
    NM-a6561bcf-a6b9-4357-b6c0-6c79d5edb605:
      renderer: NetworkManager
      match:
        name: "wlp0s20f3"
      dhcp4: true
      access-points:
        "Bezos Rocket":
          auth:
            key-management: "psk"
            password: "JumpingJack12"
```

Two failures in one file:

1. **`match: name: "wlp0s20f3"` is a PCI-slot-derived name.** On another machine
   the Wi-Fi interface is `wlp2s0`, `wlan0`, … The `match` never fires, so the
   profile is silently inert and the machine comes up with no Wi-Fi.
2. **The WPA passphrase is in cleartext**, in a file that gets compressed into a
   world-readable squashfs on a FAT stick. That is a credential leak independent
   of any hardware question.

Nothing regenerates or removes this file. The *intended* Wi-Fi persistence path is
different and device-agnostic: `bin/persist-wifi.sh` records
`nmcli device wifi connect "<ssid>" password "<psk>"` into `/cdrom/wifi.sh`, to be
replayed on the next boot. The netplan file is an unintended by-product of
nmcli/netplan integration that got swept into the layer.

### 2b. `/etc/lightdm/lightdm.conf` — autologin to a name that may not exist

```
[SeatDefaults]
allow-guest=false
autologin-guest=false
autologin-user=ubuntu
autologin-user-timeout=0
```

This is casper's default identity (`USERNAME="ubuntu"` in `/etc/casper.conf`,
which is *also* in the upper) written into a persistent file. If the stick is
later re-imaged or re-parameterised so the live user is `mint`, lightdm autologins
`ubuntu` while the home that exists is `/home/mint`. That is precisely the
greeter-relogin loop FRAGILE_HOME.md documents — a session that dies and drops
back to the greeter.

## 3. `/etc/fstab` — stale, but self-correcting

```fstab
# BEGIN lsl-usb fstab
# Maintained by onboot.sh (lsl_merge_fstab); edit only outside this block.
UUID=4A21-0000 /cdrom vfat defaults,ro,nofail 0 0
UUID=9070DA9A70DA867E /mnt/c ntfs3 defaults,nofail 0 0
/mnt/c/Users/lsl-usb/home-linuxmint.btrfs /home btrfs loop,compress=zstd:3,relatime,nofail 0 0
/mnt/c/Users/lsl-usb/cache-linuxmint.btrfs /mnt/lsl-cache btrfs loop,compress=zstd:3,relatime,nofail 0 0
# END lsl-usb fstab
```

`UUID=9070DA9A70DA867E` is **this PC's** `nvme0n1p4`, and `UUID=4A21-0000` is this
stick's FAT partition — confirmed against `blkid` on the running system:

```
/dev/nvme0n1p4: UUID="9070DA9A70DA867E" TYPE="ntfs"
/dev/sda1:      LABEL="Lexar" UUID="4A21-0000" TYPE="vfat"
```

Neither exists on another machine. This one is the least severe of the set
because `onboot.sh`'s `lsl_merge_fstab()` **rewrites the whole block every boot**
and `nofail` is set on every line — so a stale block is replaced, not honoured.
Worth recording anyway: if that rewrite ever fails, the stale UUIDs are what the
boot would fall back to.

## 4. Why the layer-pack path has no identity rule

```bash
# bin/uproot — write_append_layer()
mksquashfs /tmp/squashfs/upper "$layer" -comp zstd -Xcompression-level 22 \
    -wildcards -e "var/lib/flatpak/*" "var/cache/apt/archives/*" "var/lib/apt/lists/*"

# bin/uproot — the merge path
(cd /tmp/squashfs/root && mksquashfs . "$new" ... \
    -wildcards -e "home/*" "var/cache/apt/archives/*" "var/lib/apt/lists/*")
```

The exclusion lists exist to keep the layer under the FAT32 4 GiB cap and to keep
flatpak's content-addressed store out. **They are size-motivated, not
identity-motivated.** Nothing in either list says "this file describes *this*
machine". What keeps identity files out today is simply that no writer puts them
into *this* upper (§0) — not any rule here.

The generalisation worth keeping: *exclusions chosen for **size** will never
catch a problem about **identity**.* Note also that this list only exists because
there is a **pack step** here; the overlay-upper case (§6) has none and needs a
different instrument entirely — a scrub of the upper directory.

## 5. Severity, honestly

**Today: a latent hazard, not a live bug.** None of these paths is written
through `uproot`'s config overlay (§0), so with the current design they are not
packed into a layer and a stick carrying them is only carrying them in RAM. The
severity is about what happens when persistence changes.

- **Not** a boot-blocker even then: the stick would still boot — with the wrong
  identity and no Wi-Fi.
- The netplan file is the worst of the set: silently no Wi-Fi on new hardware,
  plus a cleartext PSK inside a world-readable squashfs on a removable stick.
- `lightdm` + `casper.conf` is the one that produces a *visible* failure (the
  greeter loop FRAGILE_HOME.md documents) — and only when the live-user name
  changes between images.
- `machine-id` is harmless functionally, but makes journald/dbus dedupe wrongly
  across machines.
- `/etc/fstab` is already handled: `onboot.sh`'s `lsl_merge_fstab()` rewrites the
  block every boot.

What makes it worth writing down *now* is that F2FS persistence is on the
roadmap. An F2FS persistence layer is an *overlay upper* (§6), so the fix is a
scrub of that directory before the overlay mounts — not the squashfs exclusions
this section describes.

## 6. The F2FS question: scrub the upper in the initrd, before casper mounts it

The question was: *if we set up F2FS persistence, how could we remove these
modifications from the upper before mounting the overlay?*

**Answer: in the initrd, via a `casper-premount` hook — which we already do for
another purpose.** Read from the actual initrd on this stick
(`unmkinitramfs /cdrom/_ISO/linuxmint-22.3-cinnamon-64bit/initrd.lz`):

| what | where | line |
|---|---|---|
| casper creates the upper | `scripts/casper:551-583` — mounts the cow device at `/cow`, `mkdir -p /cow/upper` | 551-583 |
| casper mounts the root overlay | `scripts/casper:683` — `mount -t overlay -o upperdir=/cow/upper,…` | 683 |
| **our hook point** | `scripts/casper:926` — `run_scripts /scripts/casper-premount` | 926 |

`mountroot()` (line 901) runs `run_scripts /scripts/casper-premount` at **line
926**; `setup_overlay()` (which contains the `/cow/upper` creation at 551-583 and
the overlay mount at 683) is reached later, from `mount_images_in_directory`
(line 139-145). So a premount hook runs **before the upper exists**, let alone
before it is mounted.

### "But the initramfs mounts / before we run" — that was my error

I claimed the root overlay is unreachable because the initramfs mounts it before
userspace. Two things are wrong with that:

1. **We are in the initramfs.** `build.sh:154` `repack_initrd()` unpacks
   casper's initrd, injects our `scripts/casper-premount/zz_lsl_hdd_mirror` (and
   the live-boot/antiX equivalents), updates the `ORDER` file, and repacks. `lslsetup`
   does the same in Rust (`lslfiles.rs:1724 repack_initrd`), shipping the hook as
   the secondary `initrd.hddmirror.gz`. We are not a late-boot guest observing
   casper — we are patching casper.
2. **The mount order is the opposite of what I assumed.** `/cow` is created at
   551-583 inside a function only reached at 139-145, which is *after* the
   premount hook at 926. There is no race and no inaccessible window.

So the ordering problem I invented does not exist. This is the easy case, not the
hard one.

### What the hook would do

```sh
# scripts/casper-premount/zz_lsl_scrub_identity  (injected by repack_initrd)
# Runs BEFORE setup_overlay creates /cow/upper, so the cow device is not yet
# mounted at /cow. Mount it ourselves read-write, scrub, unmount.
cowdev="$(find_cow_device "$(root_persistence_label)")"   # casper's own helper
[ -b "$cowdev" ] || exit 0                                 # not persistent -> nothing to do
mkdir -p /mnt/lsl-scrub
mount -t "$(get_fstype "$cowdev")" -o rw,noatime "$cowdev" /mnt/lsl-scrub || exit 0
rm -rf /mnt/lsl-scrub/upper/etc/hostname \
       /mnt/lsl-scrub/upper/etc/machine-id \
       /mnt/lsl-scrub/upper/etc/netplan \
       /mnt/lsl-scrub/upper/etc/NetworkManager/system-connections \
       /mnt/lsl-scrub/upper/etc/lightdm/lightdm.conf \
       /mnt/lsl-scrub/upper/etc/casper.conf \
       /mnt/lsl-scrub/upper/etc/ssl/certs/ssl-cert-snakeoil.pem \
       /mnt/lsl-scrub/upper/etc/ssl/private/ssl-cert-snakeoil.key
umount /mnt/lsl-scrub
```

`find_cow_device` / `root_persistence_label` / `get_fstype` are casper's own
premount functions, already in scope when a premount hook is sourced — the same
way `lsl_hdd_mirror.sh` already uses `get_backing_device` and exports
`LAYERFS_PATH` into casper's shell.

The hook must follow the existing convention (`initramfs/lsl_hdd_mirror.sh`):
sourced, never `panic`, never `exit`, and a no-op when anything is unexpected —
a scrub that fails must not cost the user a boot.

### Scrub alone is not enough — regenerate after

Deleting `upper/etc/hostname` unmasks the **lower** (`home-<distro>.sfs`), i.e.
the previous image's copy. So the pairing is:

1. **scrub** in the premount hook (upper only, before the overlay exists);
2. **regenerate** in `lsl-mount-home.sh`/`onboot.sh` after `/home` is up, using
   `$LSL_DESKTOP_USER` (already resolved) for hostname/hosts/lightdm, `/run` for
   `resolv.conf`, `systemd-machine-id-setup` for `machine-id`, and the existing
   `wifi.sh` replay instead of a netplan file.

### How other USB writers do persistence (same shape, different plumbing)

Stock casper supports this natively and our design is a variation on it:

- **`persistent` on the cmdline** makes casper look for a partition or file
  labelled **`casper-rw`** (root) and **`home-rw`** (home) —
  `scripts/casper:517,558,689` via `find_cow_device`, labels set at the top of
  the script (`root_persistence_label`, `home_persistence="home-rw"`).
- That device is mounted **at `/cow`** (`:568`) and *becomes the overlay upper*
  (`:683`). `casper-rw` is conventionally **ext4**; there is no requirement it be
  any particular filesystem, which is exactly why an F2FS upper is a natural
  fit rather than an exotic one.
- `persistent-path=` (`:41`) relocates the persistency files into a subdirectory.
- The well-known tools (mkusb, Rufus' "persistent partition", pendrivelinux'
  casper-rw creator) all do the same thing: create a partition/file, label it
  `casper-rw`, and let casper mount it as `/cow`.
- Casper also supports **snapshots** (`:517-541`) — a copy of the upper synced
  back on shutdown, written to `/etc/casper.conf` for resync on halt. That is
  the mechanism `uproot`'s squashfs append generalises.

**The relevance to this document:** in every one of those designs the persistent
state is the *overlay upper*, and in every one it survives reboots. So the
"machine identity in the upper" problem is not specific to our F2FS idea — it is
inherent to persistence, and every persistent live USB has it. The standard
answer is the one above: put per-machine files on a per-boot path, or scrub and
regenerate around the overlay.

### Option list, corrected

> **Full design:** `DESIGN-F2FS-PERSISTENCE.md` works this out properly —
> provisioning, the scrub hook, the per-boot regenerators, open questions and a
> verification plan. This section is the reasoning; that document is the
> proposal.

| option | applies to | verdict |
|---|---|---|
| **scrub the upper in a `casper-premount` hook** | any casper-booted stick incl. F2FS | **the answer** — we already own this hook point |
| regenerate per boot after `/home` is up | the `hostname`/`resolv.conf`/`machine-id` class | required *in addition*, always |
| `mksquashfs -e` identity list | squashfs *pack* steps only | valid there, irrelevant to F2FS |
| tmpfs mask over identity paths | if we ever cannot scrub | weaker — empty, not correct |


## The rule worth keeping

> **Check whether you are the thing you are blaming.** I twice dismissed the
> initrd as something that "mounts / before any script of ours runs". We *build*
> that initrd (`build.sh:154 repack_initrd`, and `lslfiles.rs:1724` in Rust) and
> already inject hooks into `scripts/casper-premount`. Reading casper's own
> `scripts/casper` settled both the ownership and the ordering in about ten
> lines: the premount hook runs at `:926`, `/cow/upper` is created at `:551-583`,
> and the root overlay is mounted at `:683`.

> **Establish what the persistence mechanism *is* before proposing where to
> filter.** Wrong twice here: first a `mksquashfs -e` list for a mechanism with
> no pack step, then an assertion that F2FS means "no overlay" when it is an
> overlay *upper*. Both came from reasoning about the design instead of reading
> the scripts.

> **Match the instrument to the step.** A filesystem that is *packed* is filtered
> at pack time. A filesystem that is *an overlay upper* is scrubbed as a
> directory before the overlay is mounted — and for casper that window is a
> `casper-premount` hook, which is a thing we already ship for another purpose.

> **Scrubbing an upper unmasks the lower — you must regenerate, not just
> delete.** `rm upper/etc/hostname` reveals the previous image's copy from
> `home-<distro>.sfs`. Every scrubbed path needs a per-boot regenerator (the
> `onboot.sh` `lsl_merge_fstab` pattern), or the same staleness arrives through
> the other door.

> **This is inherent to persistence, not to our design.** Stock casper mounts a
> `casper-rw` device as `/cow` and uses it as the upper; mkusb, Rufus and
> pendrivelinux all do the same. Any persistent live USB carries machine
> identity forward unless it is scrubbed or regenerated — worth knowing before
> treating it as a bug in one particular filesystem choice.
