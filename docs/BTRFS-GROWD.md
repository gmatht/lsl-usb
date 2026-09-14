# btrfs-growd: does online growth work? (attempt log, 2026-09-14)

TODO asked: *"growing the file doesn't seem to grow the loop-device, can we fix?"*
Short answer: the core mechanism (`losetup -c` on a mounted loop) **works**
(proven below); the script had two discovery/targeting gaps that made growth
silently miss, both fixed + unit-tested. What remains is kernel-version
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

## 4. Deliberately NOT changed

- Boot-time unmounted growth (`lsl_grow_btrfs_image` in `onboot.sh`)
  stays the reliable path; the daemon is mid-session top-up only.
- The re-loop fallback, busy-mount handling, and persistent grow marker
  are unchanged.
- No sparse-overprovision redesign (pre-truncate to max): it would dodge
  `-c` entirely, but NTFS-3G/exFAT sparse semantics + a behavior change
  this big needs the live verification in §5 first.

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
