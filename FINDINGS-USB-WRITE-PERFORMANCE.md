# FINDINGS — Is this USB drive fast enough for the root overlay?

**Status:** measurements and an interpretation. No code changed.

**Question:** given `randwrite-4k` at 98 IOPS / 2.8 MiB/s, how well can the drive
handle all the writes to the root overlay (`/cow/upper`) during a boot and first
boot?

**Short answer: yes, comfortably — because the boot's write load is mostly *not*
4K-random.** The single number quoted (98 IOPS) is the worst case and applies to a
minority of the work. Measured on the same drive, sequential write is ~4x faster
and sequential read ~40x, and the largest single operation (packing the appended
layer) is sequential in both directions.

---

## 1. The measurements

All on `/dev/sdb` — "Flash Disk 3.0", 59 GB, the F2FS partition
(`/f2fs`). The fio figures are the operator's; the `dd` figures were taken here
for the gap they fill.

| test | result | note |
|---|---|---|
| `randwrite-4k`, 8 jobs, iodepth 32 | **98 IOPS, 2824 KiB/s** | the quoted figure |
| `seqread-1m`, 8 jobs | **112 MiB/s** | 7037 MiB in 63 s |
| `seq write 1m`, `O_DIRECT` | **10.9 MiB/s** | 256 MiB in 24.7 s — *measured here* |
| `seq write 1m`, buffered | 1.2 GB/s | **the cache, not the device** — ignore |

Two things about the fio run worth reading past the headline number:

```
bw (KiB/s): min=2028, max=23941, avg=6469.78, stdev=813.55
iops      : min=14,   max=1398,  avg=202.83,  stdev=59.38
```

The **variance is large** — a peak of 1398 IOPS against a minimum of 14. That is
typical of consumer flash with garbage collection: it is not a steady 98 IOPS, it
is "usually more, sometimes much less". The averages are pulled down by the slow
periods, and boot-time work is bursty rather than sustained, so the device will
mostly run nearer the average than the floor.

`util=97.55%` confirms the device was **saturated** during the test — these are the
drive's real limits, not an artifact of too little load.

## 2. What the boot actually asks of it

The mistake would be to multiply total bytes by the 4K-random rate. The work splits
by access pattern:

| what | volume | pattern | applies | time |
|---|---|---|---|---|
| `/etc` and config writes this boot | ~14 MB | 4K random | 2.8 MiB/s | **5 s** |
| firstboot `apt install` (unpack) | ~500 MB | small writes | 2.8 MiB/s | **~3.0 min** |
| writing the appended layer | ~739 MB | **sequential** | 10.9 MiB/s | **~1.1 min** |
| reading the upper for `mksquashfs` | ~739 MB | **sequential** | 112 MiB/s | **~7 s** |

The upper contents are measured, not assumed:

```
$ lsl-upper-changes -q
  modified files : 478
  apparent size  : 15449405 bytes (~14 MB)
```

**So the random-write-bound part of a boot is about 3 minutes**, dominated by `apt`
unpacking — and that is the *first* boot only. An ordinary boot writes ~14 MB, which
is **5 seconds** at the worst measured rate.

## 3. But: the overlay is not on this drive

This is the part worth being careful about, and it is easy to get wrong.

The root overlay's upper is **`/cow` — a tmpfs, i.e. RAM** (`WHYFAIL12` §8). The
`/f2fs` partition measured above is *not* where the overlay writes today; it is a
separate experiment. So the question "can it handle the writes to upper?" depends
on **which** upper:

| upper | backing | the 98 IOPS figure applies? |
|---|---|---|
| `/cow/upper` (today) | **RAM** | **no** — RAM is orders of magnitude faster; this drive is irrelevant |
| `uproot`'s config overlay | RAM | no |
| a future F2FS-backed upper | this drive | **yes — and that is the real question** |

So the measurement matters for exactly the design in
`DESIGN-F2FS-PERSISTENCE.md`: if the overlay upper moves onto this drive, the
numbers above are what a session would feel. The answer there is:

- **ordinary boot: fine.** ~14 MB of writes, 5 s at the floor.
- **first boot: acceptable.** ~3 min dominated by `apt`, which is also writing
  *through* to a RAM overlay today, so it is not a new cost — it is the same cost
  on a slower device.
- **appending a layer: fine.** Sequential both ways, and the read side is fast.

The pattern that would hurt is **sustained random 4K writes** — a database, a
browser profile with heavy cache churn, a compile with many small outputs. At
98 IOPS that is painful; at the 1398 IOPS peak it is tolerable but spiky. Nothing in
the normal boot path looks like that.

## 4. What is *not* covered

Stated because the numbers above could be read as more complete than they are:

- **Write amplification.** F2FS is log-structured and rewrites segments; a 4K write
  can cost more than 4K of device traffic, and the extra is not visible to fio from
  above. The `util=97.55%` suggests the device was busy far beyond the goodput.
- **Endurance.** 98 IOPS sustained is a lot of erase cycles. On a cheap stick this
  is the real constraint, not speed — and nothing here measures wear.
- **`fsync` behaviour.** fio's `--fsync` setting is not shown; a workload that
  syncs per write would be dramatically slower than these figures, because the
  drive's latency spikes then land in the critical path.
- **The `seq write` figure is a single 256 MB run**, `O_DIRECT`, no queue depth.
  It is a floor, not a well-characterised number.
- **`/f2fs` is nearly full in one sense and empty in another** — 5.1 GB used of
  59 GB. A drive that is 90% full behaves differently, and none of this was
  measured near capacity.
- **The `apt` figure (~500 MB) is an estimate** from package sizes in the running
  image, not a measurement of what firstboot actually writes.

## 5. The honest summary

The quoted `98 IOPS` is the worst case, and it applies to the smallest part of the
work. For the boot paths that exist today the relevant rate is **sequential**
(10.9 MiB/s write, 112 MiB/s read), and the biggest operation — packing the
appended layer — is sequential in both directions and takes about a minute. The
only meaningfully random-bound step is `apt` unpacking on **first boot**, and that
is already happening today.

**If the F2FS upper is built, this drive is adequate for normal operation and
acceptable for first boot.** The thing to watch is not throughput but *latency
spikes* — the 14-IOPS minimum is the number that would be felt as a stutter, and it
is not visible in any average.

---

## The rule worth keeping

> **One benchmark number is one access pattern.** "98 IOPS" was read as "this drive
> does 98 operations per second", when it means "this drive does 98 *4K random*
> operations per second, and 112 MiB/s sequentially". The boot's largest and
> longest operations are sequential. Picking the applicable row from a table is the
> whole analysis; averaging the rows is the error.

> **Check which device the question is about.** The overlay upper is `/cow` — RAM —
> so this drive's numbers do not apply to it at all today. They apply to the
> *proposed* F2FS upper. Measuring a disk and then reasoning about a tmpfs is an
> easy and entirely silent mistake.

> **Averaged throughput hides the latency that users feel.** `min=14 IOPS` against
> `max=1398` behind an average of 203 means the user-visible behaviour is spikes,
> not the mean. For interactive work the minimum matters more than the average, and
> no single fio summary line reports it as such.
