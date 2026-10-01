# FINDINGS — Compression settings in lsl-usb

**Status:** measurements only, plus what they imply. No code changed. Every number
below was produced on this stick (Mint 22.3, mksquashfs 4.6.1, libzstd from the
distro) and the command used is quoted beside it.

**Why this exists:** the tree has **six `mksquashfs` call sites with three
different settings**, one of which passes a value the tool's own help says is out
of range. That is worth writing down before anyone tunes it.

---

## 1. What is configured today

| site | setting | role |
|---|---|---|
| `bin/uproot:334` (append layer) | `-comp zstd -Xcompression-level 22` | baked into the stick; boot-critical |
| `bin/uproot:678` (merge layer) | `-comp zstd -Xcompression-level 22` | same |
| `bin/lsl-copy-sfs-hdd.sh:130` | `-comp zstd -Xcompression-level 22` | HDD mirror; boot-critical |
| `bin/lsl-win-backup.sh:264,285` | `-comp zstd -Xcompression-level 22` | streamed Windows backup |
| `bin/lsl-flush-home.sh:68` | `-comp zstd -b 512K` (**no level**) | home snapshot at shutdown |
| `bin/lsl-mount-home.sh:153` | `-comp zstd` (**no level, no `-b`**) | first-boot `home.sfs` seed |
| `misc/build-z0.sh:72` | `-comp zstd` (**no level**) | 12 KB stub, build-time |

Everything else in the tree is **btrfs** (`compress=zstd:3`), which is a different
mechanism entirely and is not touched here:

```
bin/lsl-btrfs-growd:96      mount -o loop,compress=zstd:3
bin/lsl-mount-home.sh:219   mount -o loop,compress=zstd:3   (home.btrfs)
onboot.sh:182,209,223,288   btrfs loop,compress=zstd:3      (persist/home/cache)
```

## 2. `-Xcompression-level 22` is outside the documented range

```
$ mksquashfs -help | grep -A2 Xcompression-level
    -Xcompression-level <compression-level>
        <compression-level> should be 1 .. 9 (default 9)
```

The tree passes **22**. Three things to establish: whether it is accepted, whether
it is honoured, and whether 9 and 22 differ.

**Accepted.** No error, no warning, exit 0.

**Honoured — it is not clamped to 9.** Measured on a 12.3 MB compressible payload
(`text`, a `bash` binary, and redundant binary data):

| level | size (bytes) |
|---|---|
| 1 | 3,457,024 |
| 3 | 3,252,224 |
| 5 | 3,104,768 |
| 7 | 3,039,232 |
| 9 | 3,022,848 |
| 12 | 3,002,368 |
| 15 | 2,711,552 |
| 19 | 2,695,168 |
| 22 | 2,695,168 |

Sizes keep falling past 9, so `-Xcompression-level` is passed through to libzstd,
whose own range is 1–19 with `--ultra` extending to 22. **The mksquashfs help text
is simply stale for zstd** (it reads as if the range were the gzip one). 22 is
legal zstd; whether it is *useful* is §4.

**19 vs 22 are byte-different but size-identical** on this payload, i.e. 22 buys
nothing over 19 here.

## 3. The level curve flattens hard, and the cost is super-linear

Same payload; the last column scales the measured time to the size of a real
appended layer on this stick (**739 MB**):

| level | size (MB) | vs level 9 | est. time @739 MB |
|---|---|---|---|
| 1 | 3.3 | +14.4 % | 1.2 s |
| 3 | 3.1 | +7.6 % | 0.6 s |
| 5 | 3.0 | +2.7 % | 1.8 s |
| 7 | 2.9 | +0.5 % | 2.4 s |
| **9** | **2.9** | **—** | **3.0 s** |
| 12 | 2.9 | −0.7 % | 7.8 s |
| 15 | 2.6 | −10.3 % | 18.0 s |
| 19 | 2.6 | −10.8 % | 42.7 s |
| 22 | 2.6 | −10.8 % | 47.5 s |

**Reading:** from 9 to 19 you buy ~11 % size for ~14× the time. From 19 to 22 you
buy **nothing** and pay ~11 % more time.

## 4. At realistic scale, on real layer content

The table above is a synthetic payload. Rebuilding an actual 1.6 GB slice of a real
layer (16,580 files — `/boot/initrd…`, `/etc`, `/usr`), `tar`-free, direct:

```
mksquashfs . out.sqfs -comp zstd -Xcompression-level <N> -noappend -no-progress
```

| level | size (bytes) | vs level 9 |
|---|---|---|
| 3 | 600,932,352 | +5.9 % |
| **9** | **567,738,368** | **—** |
| 15 | 535,416,832 | −5.7 % |
| 19 | 531,365,888 | −6.4 % |

(Level 22 did not complete within the measurement window — consistent with §3's
estimate that it is the slowest and buys nothing over 19.)

So on **real** content the 9→19 saving is **~6 %**, not the ~11 % the synthetic
payload suggested. A 6 % smaller layer is ~44 MB on a 739 MB append, in exchange
for tens of seconds of CPU on the machine doing the append — which is the user's
laptop, during first boot, on battery, while a progress dialog is on screen.

## 5. What this implies (not implemented)

1. **`-Xcompression-level 22` should become 9** at the four call sites that use 22.
   It is outside the documented range, buys nothing over 15–19, and costs the most
   time of any setting in the tree. If a *deliberate* choice of "maximum" is
   wanted, 19 is the honest ceiling — but see (2).
2. **The default (no `-Xcompression-level`) is 9 per the help text.** The three
   sites that omit it are already at the level the four others should use. That is
   the argument for standardising on **9**: it is the documented default, it is
   what the omitted-setting sites already do, and the measurable gain above it is
   ~6 % for a large time cost.
3. **Standardise, so the settings are reviewable.** Six sites, three settings, no
   shared constant. Whatever value is chosen should live in one place.
4. **`-b 512K` at `lsl-flush-home.sh:68` is a separate decision.** Block size
   affects compression ratio little on typical data and increases memory use
   during decompression; worth measuring on `home.sfs` specifically before
   touching, and out of scope here.
5. **The z0 stub is 12 KB.** Its level is irrelevant; the build-time call can keep
   whatever it has.

## 6. What was NOT measured

Stated plainly, because the table above could be mistaken for a full picture:

- **Decompression speed.** Higher zstd levels cost more time to *read back*, and
  the layer is decompressed on **every boot**. A 6 % smaller layer that costs boot
  time is a bad trade for a USB stick. This is the single most important missing
  measurement and it points the *opposite* way to the size tables: it is an
  argument for **lower** levels than 9, not higher.
- **Memory.** zstd's high levels need a large window; `mksquashfs` warns that
  decompression memory scales with block size and level. On a live boot with a RAM
  budget, this matters and is unmeasured.
- **The actual layer's full 739 MB** at each level — §4 is a 1.6 GB *subset* of a
  layer's contents, not the layer itself.
- **`-b 512K` vs default block size**, on either ratio or boot-time memory.
- **Whether the appended layer's content is representative at all.** §4's file-type
  census (`gz`, `pm`, `vim`, `xml`, `so`, `txt`, `h`) is from one stick's tree; a
  different workload could compress differently.

## 7. The honest summary

The tree asks for level 22 in the four places that matter most, while the tool
documents 1–9 and the three places that do not specify a level already get 9.
Measured, 22 buys **nothing** over 19 and 19 buys **~6 %** over 9 on real content
for a large time cost — and none of that accounts for boot-time decompression,
which is likely the real constraint. **The defensible change is to use the
documented default (9) everywhere and to measure decompression before going
higher.** That is a smaller change than the numbers in §3 first suggest, because
§3's headline saving shrinks by half when measured on real data.

---

## The rule worth keeping

> **A tool's help text and its accepted input are different things.** `mksquashfs`
> says `1 .. 9` for `-Xcompression-level` and happily takes 22, passing it to
> libzstd whose real range is 1–19 (+`--ultra` to 22). Reading only the help would
> have said "22 is a bug, it is out of range". Testing said "22 works and is
> pointless". Check which claim you actually need.

> **Measure on the content you ship, not a payload you built.** The synthetic
> sweep showed an 11 % saving for 9→19; real layer content showed 6 %. Same
> setting, same tool, half the benefit — because the ratio depends on the data, and
> the data is the one thing a synthetic benchmark does not have.

> **Compression level is a ratio/time knob for the *writer* and a *reader* cost
> forever.** Every layer is decompressed on every boot. Sizing the decision on
> write-side time and size alone optimises the half that happens once.
