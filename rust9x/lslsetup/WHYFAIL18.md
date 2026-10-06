# WHYFAIL18 — "Attempted to kill init" on first boot of an F2FS stick

Reported from the field: a stick installed with the F2FS persistence
backend panics during boot with

```
Kernel panic - not syncing: Attempted to kill init! exitcode=0x00000000
```

Short answer: **`lsl_wait_for_boot_disk` in
`initramfs/lsl_f2fs_provision.sh` exited casper's shell.** The hook is
*sourced* into that shell, the shell is PID 1, and an `exit` in a
sourced file exits PID 1 — which the kernel reports exactly as above.
The exit fired on the *normal* case the function exists to handle: a
disk whose partition node has not appeared yet.

This is the companion to commit `539da00` ("Park with diagnostics
instead of panicking PID 1"): that fix armed a park guard for the
*destructive* window, but the fatal line runs **before** the guard is
armed, so the panic survived it.

---

## 1. What the operator saw

A first boot that dies immediately after the initramfs hands over to
userspace, with the kernel panic above on the console. No desktop, no
error message from the installer — the stick was written successfully.

The panic is not rare in the strict sense: it needs a disk to be
visible to the hook at a moment when its partition node is missing.
That is the *normal* state of a USB stick during enumeration (the disk
node appears before its partitions — measured 50 ms apart under virtio,
far wider on real USB hardware), and the *permanent* state of any disk
without a partition table. Real boots hit it whenever the target stick
(or a second disk) is mid-enumeration when the hook scans.

## 2. What was actually true

The hook's own header documents the contract:

> This file is SOURCED into casper's init shell … every designed
> outcome must `return`, never `exit` — an `exit` would kill PID 1.

and the wait function's comment explains why it polls at all:

> The kernel can register a disk node before its partition nodes
> (the USB enumeration race) … so the hook polls for the partition.

But the poll loop's body was:

```bash
for _lsl_p in "${_lsl_d}"?* "${_lsl_d}"p?*; do
    [ -b "$_lsl_p" ] && return 0 2>/dev/null || exit 0
done
```

`&&` and `||` are **left-associative**, so that line parses as

```bash
( [ -b "$_lsl_p" ] && return 0 ) || exit 0
```

The `|| exit 0` therefore fires exactly when `[ -b "$_lsl_p" ]` is
**false** — i.e. when the partition node is absent. That is the case
the loop exists to *wait for*. On the first poll of a disk whose
partitions have not appeared, the hook exits the shell it was sourced
into. Casper's shell is PID 1: kernel panic.

Two details made this easy to miss:

- **The park guard cannot catch it.** `lsl_park_arm` is called at the
  read-layout step, which runs *after* `lsl_wait_for_boot_disk` returns.
  The fatal exit happens before the guard exists. This is why the
  "park instead of panic" fix (`539da00`) did not stop the panic — the
  two mechanisms protect different code regions and this line was in
  neither.
- **The `2>/dev/null` was in the wrong place** even for the intended
  semantics: it suppressed the `[ -b ]` test's own error output, not
  anything the `return` produced — a hint that the line was written
  for a different parse than the one shell actually performs.

The static contract checks in `tests/f2fs-provision-hook.tests.sh`
("no bare exit", "opt-out gate uses the safe if-form") passed, because
the trap is a *combination* (`&& return` with `|| exit`), not a bare
`exit`. The scrub suite already bans that combination; the provision
hook's suite did not.

## 3. Reproduction — QEMU, no ISO needed

`tests/qemu-panic-repro.sh` builds a minimal initramfs from the Ubuntu
archive (kernel, the f2fs module **and its real dependency closure**,
busybox) plus the partitioning tools from the local rootfs, and boots it
under QEMU/KVM against a **blank virtio disk**:

- `/init` sources the hook exactly the way casper's `run_scripts`
  sources `ORDER`, then parks.
- The blank disk has `/dev/vda` but never a `/dev/vda1` — the
  deterministic form of the enumeration race. No timing luck required.

With the buggy hook the serial console ends at

```
lsl-f2fs-provision: tools ready: sfdisk/fatresize/mkfs.f2fs on PATH
[    1.104186] Kernel panic - not syncing: Attempted to kill init! exitcode=0x00000000
```

and QEMU exits 1 (the guest is configured `panic=-1 -no-reboot`, so the
panic terminates the run — that is the assertion).

Two smaller proofs pin the mechanism before any VM is involved:

- **dash proof** — a sourced function containing the one-liner, called
  with a missing node: the shell prints "before call", never prints
  "after call".
- **WSL2-level repro** — sourcing the real hook with a fake disk list
  containing a partitionless node: the marker after the source is never
  printed, and the log ends at "tools ready", the last line before the
  wait function is called.

(Repro-harness notes, for whoever reruns it: f2fs is a *module* in the
Ubuntu kernel and needs `kernel/lib/lz4/lz4_compress.ko` +
`lz4hc_compress.ko` for `LZ4_compress_default/HC` — the `crypto/lz4`
module does **not** export those, so a hand-picked module list loads
f2fs into "unknown symbol" and the hook no-ops instead of panicking.
The repro resolves the closure from a full `depmod` over every module
in the packages. It also stages the modules unzstd'd as plain `.ko`
because kmod in the minimal tree cannot decompress the `.ko.zst`
container itself.)

## 4. Fix

The `if` form, matching the safe idiom the rest of the file already
uses — the absent-node case falls through to the next poll instead of
exiting:

```bash
for _lsl_p in "${_lsl_d}"?* "${_lsl_d}"p?*; do
    if [ -b "$_lsl_p" ]; then
        return 0
    fi
done
```

With the fix, the same QEMU boot logs

```
lsl-f2fs-provision: REFUSING: could not identify the boot medium by content; refusing to guess which disk to shrink.
lsl-f2fs-provision: refused (not fatal, boot continues): disk=<none> ...
=== HOOK RETURNED (rc=0) - PID 1 still alive ===
```

— the hook waits out its 60 polls, finds nothing, refuses safely, and
the boot continues.

## 5. Regression tests

`tests/f2fs-provision-hook.tests.sh` gained two checks:

- **Static**: no one-liner may combine `&& return` with `|| exit`
  (mirroring the scrub suite's banned-pattern check, comments stripped
  so the prose cannot trip it).
- **Behavioural (part 1d, root)**: `lsl_wait_for_boot_disk` is driven
  at two `mknod`'d block nodes — one with no partition nodes (the
  panic shape) followed by one with a partition node. An unbacked
  block-device node passes the hook's `[ -b ]` test (the test is on
  the node type, not a live driver), so with the old code the sourcing
  shell dies on the first node; with the fix it falls through to the
  second node's partition and returns. The test asserts the shell
  survives by printing markers before and after the call.

## 6. Related

- **Commit `539da00`** ("Park with diagnostics instead of
  panicking PID 1") — the park guard that protects the
  *destructive* window. It is real and still valuable; it just
  does not cover this line, which runs before it is armed.
- **`WHYFAIL15.md`** — scripts are embedded in `lslsetup` with
  `include_str!`, so a fixed hook reaches a stick only via a
  rebuilt `lslsetup.exe`. This fix needs the same rebuild to
  ship.
- **`tests/qemu-f2fs-provision-test.sh`** — the ISO-based boot
  test that originally reached the "hook runs at 3.4 s, medium
  unmounted" conclusion. It never caught this because its victim
  disk is a real FAT stick whose partition node exists by the
  time the hook scans.

## The rule worth keeping

> **In a sourced file, `CMD && return 0 || exit 0` is
> `( CMD && return 0 ) || exit 0` — the exit fires when CMD is
> false.** A wait loop's *normal* case is the false case. Write the
> branch as an `if`, and ban the combination outright. And when a
> "safe" failure path is added to a sourced hook, check *where* it is
> relative to every guard: a park trap armed later does not protect
> earlier code.
