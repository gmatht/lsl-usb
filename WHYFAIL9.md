# WHYFAIL9 — Why did first boot lose the home changes, when I did not select "no persistence"?

Asked 2026-09-28. Short answer: **`lsl-mount-home.sh` wrote `LSL_MODE=usb`
for a *fallback* tmpfs overlay — the same value a real USB stick produces — and
`uphome` then trusted a fresh `lsl_is_usb_mode` resolve instead of that recorded
fact. On the first boot the resolve flips from "not persistent" to "persistent"
*while the boot proceeds* (because firstboot installs the very tool that mounts
the drive), so `uphome` took the HDD branch, ran a no-op `btrfs filesystem sync`
against a tmpfs overlay, and exited 0. Firstboot logged `Final home flush OK.`
The home changes existed only in `/run` and were dropped on reboot.**

This is WHYFAIL7 again — same symptom, same fallback branch, different
mechanism. WHYFAIL7's trigger was CRLF in the env file breaking
`LSL_DATA_DIR`; that one is fixed. This one needs no misconfiguration at all:
it fires on a **stock first boot**.

See also **`FRAGILE_HOME.md`**, which turned this incident into a standing
hazard inventory (every call site that asks "is /home persistent?", and the risk
each carries).

---

## 1. What the operator saw

`/home` was transient on a boot entry that is supposed to be persistent. The
natural suspicion is the "Boot to RAM, no persistence" menu entry. That entry
was **not** selected, and `/proc/cmdline` proves it — there is no `lsl_home=tmpfs`:

```
BOOT_IMAGE=/_ISO/linuxmint-22.3-cinnamon-64bit/vmlinuz boot=casper \
  layerfs-path=/cdrom/casper/filesystem.z0.squashfs rootdelay=15 quiet splash
```

`lsl_home=tmpfs` is what `bin/lsl-mount-home.sh` greps for to set
`LSL_EPHEMERAL_HOME=1`. It is absent, so the RAM-only branch never ran.
The `LSL_MODE=ram` path was never taken.

What the state file said instead:

```
$ cat /run/lsl-usb.state
LSL_HOME_LOWER=/run/lsl-home-lower
LSL_HOME_UPPER=/run/lsl-home-overlay/upper
LSL_HOME_WORK=/run/lsl-home-overlay/work
LSL_MODE=usb
```

`LSL_MODE=usb` — so `/home` *was* deliberately kept transient, just not by the
operator, and not by the RAM branch.

---

## 2. Root cause

### 2a. The fallback records a lie of omission

`lsl-mount-home.sh` is careful, and its fallback logic is correct: when HDD mode
cannot confirm a persistent data dir, it must not write `home.btrfs` into
volatile RAM, so it uses a temporary tmpfs overlay and warns.

```
lsl: mounting /home: env=/cdrom/lsl-usb.env data_dir=/mnt/c/Users/lsl-usb user=ubuntu
lsl: HDD data dir /mnt/c/Users/lsl-usb not on a persistent volume yet; retrying drive mount...
lsl-mount-home.sh[1476]: Error: 'hivexregedit' is required but not installed.
lsl: WARNING: data dir still not persistent; using a temporary tmpfs-overlay /home for this boot (changes lost on reboot).
```

But that branch and the real USB branch **share one exit**:

```bash
elif lsl_is_usb_mode || [ "${LSL_FALLBACK_USB_HOME:-0}" = "1" ]; then
    ...
    {   echo "LSL_HOME_LOWER=$LSL_HOME_LOWER"
        echo "LSL_HOME_UPPER=$LSL_HOME_UPPER"
        echo "LSL_HOME_WORK=$LSL_HOME_WORK"
        echo "LSL_MODE=usb"          # <-- also used for the fallback
    } > /run/lsl-usb.state
```

So a transient accident is recorded as a deliberate configuration. Downstream
cannot tell them apart.

### 2b. The tool that fixes the mount problem is installed by the boot that needs it

This is the trap that makes it a first-boot-only failure. `hivexregedit` is
required by `mount_all.sh` → `wsl-boot-setup` to map Windows drive letters, so
`/mnt/c` never mounts, so the data dir is not persistent, so the fallback runs.

Then firstboot runs for **23 minutes (02:42 → 03:05)** and installs
`hivex-tools` — along with packages and flatpaks — and finally calls the flush:

```
[2026-09-28 03:05:21] Flushing /home to its permanent location (/cdrom/bin/uphome)...
```

By that moment `/mnt/c` **is** mounted. The condition that caused the fallback
has healed itself. The fallback's consequences have not.

### 2c. `uphome` re-derives the mode instead of reading it

```bash
if lsl_is_usb_mode; then
    echo "USB mode: flushing merged /home to the stick's per-distro home image…"
    exec "$SCRIPT_DIR/lsl-flush-home.sh"
fi
echo "HDD mode: syncing btrfs…"
btrfs filesystem sync /home 2>/dev/null || true
```

`lsl_is_usb_mode` resolves `LSL_DATA_DIR` and asks *"is the data dir under
`/cdrom`/`/persist`?"* — i.e. **"where would persistence go if it were set up
now?"** It is a *prediction*, and by 03:05 the prediction has changed. It returns
**false** → "HDD mode" → `btrfs filesystem sync /home` against a **tmpfs
overlay**. That is a no-op, and `uphome` exits **0**:

```
HDD mode: syncing btrfs…
home/cache btrfs sync complete.
```

`misc/lsl-firstboot.sh` therefore logs `Final home flush OK.`

### 2d. The two persistence writers contradicted each other in the same run

`uphome` printed `HDD mode: syncing btrfs…`, then `exec`'d into
`lsl-flush-home.sh`, which read the stale `usb` from the state file and printed:

```
USB mode: flushing merged /home to the stick's per-distro home image…
```

Two components, one boot, opposite conclusions about the same mount — and neither
noticed, because **both exited 0**.

### 2e. Why it left no trace

- Both paths exit 0 and both log success. No error, no warning.
- The only symptom is a `tmpfs`/`overlay` `/home` on an entry believed persistent.
- `/run` is RAM, so the misleading `LSL_MODE=usb` **evaporates on reboot**. The
  next boot looks clean and there is nothing left to debug.
- `/cdrom/casper/lsl-firstboot.done` is written regardless of the flush outcome,
  so firstboot does not re-run and the lost home is never rebuilt.

That last point is what makes this unrecoverable-by-retry: the stamp is written
even though the home flush was a no-op.

---

## 3. Damage

| | |
|---|---|
| **Lost** | The `/home` half of first boot — anything written to `/home` after 03:05, plus the fallback overlay's contents. |
| **Survived** | The layer, `filesystem.z0.20260928025844.squashfs` (763 MB). Packages and flatpaks are safe. |
| **Near miss** | `lsl-flush-home.sh` would have overwritten the good per-distro `home.sfs` with the near-empty overlay. It only did not because the fallback overlay was freshly seeded (`Created /cdrom/home-linuxmint.sfs` → 16 KB). |

An **inverse** variant is worse and was one step away: a fallback overlay
*holding* real work being flushed over a *good* `home.sfs`. The refusal guard
below closes that direction too.

---

## 4. Fixes

All four files were byte-identical between the repo and the deployed stick, so
these apply to the next build. Nothing is committed or pushed.

| Where | Change |
|---|---|
| `bin/lsl-common.sh` | new `lsl_effective_home_mode()` — reads the `LSL_MODE` that `lsl-mount-home.sh` actually recorded (authoritative), falling back to the live mount type only when there is no state file. Returns `ram\|usb\|usb-fallback\|hdd`. |
| `bin/lsl-mount-home.sh` | the fallback branch now records `LSL_MODE=usb-fallback` instead of masquerading as `usb`. `ram` and `hdd` unchanged. |
| `bin/uphome` | branches on the **effective** mode. `usb-fallback` now **`exit 1`** with an explicit "its contents WILL BE LOST on reboot" message, so firstboot logs `WARNING: final home flush failed` instead of `Final home flush OK`. |
| `bin/lsl-flush-home.sh` | refuses to write a `usb-fallback` overlay to `home.sfs`, so a good image cannot be clobbered. |
| `tests/lsl-common.tests.sh` | 9 new cases pinning `lsl_effective_home_mode`. |
| `CHANGELOG.md` | Unreleased → Fixed entry. |
| `FRAGILE_HOME.md` | new — post-mortem plus the full call-site inventory. |

### The rule this establishes

> **Anything that writes to persistence must branch on how `/home` was actually
> mounted, never on a fresh `lsl_is_usb_mode` resolve.**

`lsl_is_usb_mode` is only valid *before* `/home` is mounted (i.e. inside
`lsl-mount-home.sh` itself) or where the answer provably cannot have changed.

### A defect my own fix had, caught by the tests

The first cut of `lsl_effective_home_mode` did not strip CR, so a state file with
CRLF endings returned `usb-fallback\r`, matched **no** branch, and fell through to
the HDD no-op — reproducing the original data loss. `tr -d '\r'` added.

This is the **same CRLF class of bug** as WHYFAIL7 §1, which is why the repo
carries `lsl-usb.env text eol=lf` in `.gitattributes`. The value was fixed; the
*class* keeps recurring. Any new state/config value read on the guest deserves
the same suspicion.

### Backward compatibility

`usb-fallback` is only produced by the new `lsl-mount-home.sh`. A stick still
running the old script writes plain `LSL_MODE=usb`, which reads as `usb` and
still flushes — a mixed-version stick keeps the old (lossy) behaviour until the
stick is updated. This is deliberate: redefining an existing value would break
sticks in the field.

---

## 5. Reproduce / verify

```bash
# The regression suite (run from the repo)
bash tests/lsl-common.tests.sh        # RESULT: 59 passed, 0 failed

# Mode detection, on the live system
cat /run/lsl-usb.state                # LSL_MODE=… is what /home was mounted with
. /cdrom/bin/lsl-common.sh
echo "prediction (lsl_is_usb_mode): $(lsl_is_usb_mode && echo usb || echo hdd)"
echo "fact       (effective mode): $(lsl_effective_home_mode)"

# Confirm the boot entry is the persistent one (no lsl_home=tmpfs)
grep -o 'lsl_home=[^ ]*' /proc/cmdline || echo "persistent entry (correct)"

# Was the home flush a silent no-op? A btrfs sync against an overlay is one.
findmnt -no SOURCE,FSTYPE --target /home
```

The second command is the whole bug in two lines: when the prediction and the
fact disagree, the prediction is wrong.

---

## 6. What is NOT yet in effect (important)

- **The fixes are in the repo, not on the booting stick.** The stick still runs
  the old `uphome` / `lsl-mount-home.sh`, so a fallback boot **today** still
  reports `Final home flush OK` and still loses the home. It needs a rebuild.
- **The already-lost home is gone.** `/run` is RAM; nothing to recover.
- **Firstboot will not re-run.** `/cdrom/casper/lsl-firstboot.done` exists, so a
  reboot goes straight to a normal boot. On the next boot `/mnt/c` should mount
  (now that `hivex-tools` is on the layer), so `/home` gets a real `home.btrfs`
  — the *going-forward* fix is simply to reboot.
- Nothing was committed or pushed to the `C:/GitHub/lsl-usb` repo.

---

## 7. Related

- **`WHYFAIL7.md`** — the same symptom (`LSL_MODE=usb` written by the fallback
  branch, persistent `/home` never mounted) from a different cause: CRLF in
  `lsl-usb.env`. Read together, §2a here is the *unfixed* half of WHYFAIL7: the
  fallback still wrote `usb`; WHYFAIL7 only fixed why the fallback was *entered*.
- **`FRAGILE_HOME.md`** — this incident generalised: the three ways lsl-usb
  answers "is `/home` persistent?", the 8 call sites, which are safe and why, and
  six rules for future changes. Includes the open TODOs (migrating
  `lsl-home-flushd` / `lsl-btrfs-growd`, making the firstboot `home` task *fail*
  rather than warn, and pre-seeding `hivex-tools` so the fallback never triggers
  on a first boot).
- **`WHYFAIL6.md` §5** — `hiberfil.sys` / Fast Startup, the separate
  Windows-side setup gap.

## TL;DR

`/home` went transient on a persistent boot entry because the fallback tmpfs
overlay recorded itself as `LSL_MODE=usb`, and `uphome` trusted a *re-resolved
prediction* (`lsl_is_usb_mode`) rather than that record. Between the mount and
the flush, firstboot installed `hivex-tools` — the tool whose absence caused the
fallback — so the prediction flipped to `hdd` and `uphome` ran a no-op btrfs
sync, exited 0, and let firstboot log success while the home changes evaporated
with `/run`. Fixed by recording `usb-fallback` distinctly, adding
`lsl_effective_home_mode()` as the authoritative source, making `uphome` fail
loudly instead of silently succeeding, and refusing to overwrite a good
`home.sfs` with a fallback overlay. The same class of bug bit this fix once
(CRLF), which is why it is now pinned by 9 tests.
