# btrfs-growd: does online growth work? (attempt log, 2026-09-14; revised 2026-10-01)

TODO asked: *"growing the file doesn't seem to grow the loop-device, can we fix?"*
Short answer: the core mechanism (`losetup -c` on a mounted loop) **works**
(proven below); the script had discovery/targeting gaps that made growth silently
miss. **Two rounds were needed**: §3 (Sept 2026) fixed two targeting gaps, and
§3b (2026-10-01) fixed four more found by re-reading the code afterwards — most
importantly that only the *first* attached loop device was ever refreshed, which
is the mechanism the report was actually about. What remains is kernel-version
coverage, which needs a live system (see §5).

## 1. Proven live (WSL2, kernel 6.18.33.2-microsoft-standard-WSL2, util-linux 2.39.3)

`losetup -c` on a **mounted** loop device picks up a `truncate`d-larger
backing file, online, no unmount:

```
blockdev before: 209715200
truncate -s +100M growtest.img  ->  file now: 314572800
losetup -c /dev/loop0            ->  exit 0
blockdev after: 314572800
resize2fs                        ->  exit 0, 172M -> 266M live
```

(`btrfs filesystem resize max` on a mounted fs is standard and undisputed;
ext4 stood in for the loop-capacity question, which is fs-independent.)

## 2. Proven live: mount-stack discovery behavior

With an overlay bind-mounted over a loop mount (the session-overlay shape),
`findmnt -n -o SOURCE <mp>` prints **every** layer:

```
/dev/loop0 ext4    /tmp/lowm
overlay    overlay /tmp/lowm
```

so the existing `grep -E '^/dev/loop'` still finds the device (order held
here, but it is not contractual). And the fallback pieces check out:

```
losetup -j /tmp/low.img   ->  /dev/loop0: [2096]:2047 (/tmp/low.img)
findmnt -rn -o TARGET -S /dev/loop0   ->  /tmp/lowm
```

i.e. `losetup -j <canonical-path> | cut -d: -f1` + `findmnt -S` reliably
recover (device, fs-mount) with no kernel cooperation needed.

## 3. Gaps found by review (fixed in `bin/lsl-btrfs-growd`, Sept 2026)

**a) Resize targeted the wrong mount.** `btrfs filesystem resize max`
and the post-grow re-check used `$mp` (`/home`). When a session overlay
is bound over `/home`, that resizes the *overlay* — a silent no-op while
the btrfs underneath stays full (and the backing file keeps getting
`truncate`d bigger every 60 s). The script now resolves the mount where
the loop device itself sits (`findmnt -rn -o TARGET -S`) and resizes +
re-checks there. Identical to `$mp` in the normal direct-mount case.

**b) No fallback when findmnt shows no loop line.** Old findmnt, or `$mp`
buried under another mount, yielded no device: `-c`, resize verification
and the mismatch warning were all skipped. Now falls back to
`losetup -j` on the `readlink -f`-canonicalized image (canonicalizing
first answers the old objection to `-j`).

Both are covered by new bats cases (mocked findmnt/losetup/blockdev);
the pre-existing tests are untouched and still green.

## 3b. A second round, on the gaps §3 left behind (fixed 2026-10-01)

The TODO line — *"growing the file doesn't seem to grow the loop-device"* — was
still open after §3, because §3 fixed *targeting* while the report was really
about *the loop not being refreshed at all*. Four residual defects:

**c) Only the first loop device was refreshed.** `findmnt … | head -1` picked one
device. §2 of this document proves findmnt emits several stacked lines for one
path, and `bin/lsl-home-session-overlay` stacks a real second layer on `/home`. A
stale loop left over from a crashed boot keeps the old size cached, so refreshing
one device misses it — while the file grows every 60 s regardless.
`lsl_refresh_image_loops` (already in `onboot.sh`, correct) refreshes **every**
attached loop; it is now the shared implementation in `bin/lsl-common.sh`, used
by both `onboot.sh` and the daemon instead of two near-duplicates.

**d) `losetup -c` failures were discarded.** `2>/dev/null || true` meant a kernel
that ignores the call left no trace, and the very next line's
`btrfs filesystem resize max` then exits 0 with no growth. The helper now
surfaces stderr.

**e) The verification that would have caught it was triple-gated** — behind a
known loop device *and* `[ -b ]` *and* `command -v blockdev`. When it did not
run, the cycle ended in a bare `df -h` with **no warning at all**. It now runs
whenever a loop device is known, and reports "unconfirmed" rather than staying
silent when the device size cannot be read.

**f) The recovery path reintroduced §3(a).** The re-loop resized `"$mp"` instead
of `"$fs_mp"`, and re-mounted with `-o loop` on the *file*, which can attach a
**second** loop device and strand the first. It now mounts the device it just
created and resizes the same mountpoint as the primary path.

Tests: `tests/btrfs-growd.tests.sh` no longer hand-rolls the sequence (it called
the real shared helper instead, so it can no longer drift from the daemon) and
now asserts the loop device's size matches the grown file — the assertion that
would have caught this. A bats case covers the two-loops-one-image case.

## 4. Deliberately NOT changed

- Boot-time unmounted growth (`lsl_grow_btrfs_image` in `onboot.sh`)
  stays the reliable path; the daemon is mid-session top-up only.
- Busy-mount handling and the persistent grow marker are unchanged in
  substance: when the kernel genuinely cannot apply the growth online, a reboot
  (or unmount) is still the answer, and it is still logged.
- No sparse-overprovision redesign (pre-truncate to max): it would dodge
  `-c` entirely, but NTFS-3G/exFAT sparse semantics + a behavior change
  this big needs the live verification in §5 first.
- No loop-device name is recorded in `/run/lsl-usb.state` at mount time. It
  would remove the discovery heuristics entirely, and is the natural next step
  if this recurs; it was left out because it also changes
  `bin/lsl-mount-home.sh`, which is embedded and hash-pinned.

## 5. Still unverified (needs a live stick or QEMU, not WSL)

- `losetup -c` efficacy on older kernels (Mint 22.x live ≈ 6.8; 32-bit
  antiX-era ≈ 5.x). The script already treats silent-ignore as a normal
  case (re-loop → reboot note), so a negative result degrades gracefully.
- `truncate -s +1G` on NTFS-3G (the real backing fs) under memory
  pressure / near-full volume.
- Whether the original report was (a)/(b) above, an old kernel, or the
  overlaid-`/home` resize miss: all three now behave identically well
  except old-kernel silent-ignore, which keeps the reboot note.
- That (c)–(f) close it on real hardware. Each was found by reading, not by
  reproducing: none has an observed "it still did not grow" trace.

## 5. Still unverified (needs a live stick or QEMU, not WSL)

- `losetup -c` efficacy on older kernels (Mint 22.x live ≈ 6.8; 32-bit
  antiX-era ≈ 5.x). The script already treats silent-ignore as a normal
  case (re-loop → reboot note), so a negative result degrades gracefully.
- `truncate -s +1G` on NTFS-3G (the real backing fs) under memory
  pressure / near-full volume.
- Whether the original report was (a)/(b) above, an old kernel, or the
  overlaid-`/home` resize miss: all three now behave identically well
  except old-kernel silent-ignore, which keeps the reboot note.

Suggested live check: boot HDD mode, fill home past the threshold,
watch `lsl-btrfs-grow.log` + `blockdev --getsize64` vs the `.btrfs` file
size across one 60 s cycle.
