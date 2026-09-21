# Why first boot failed on this boot (2026-09-15)

**Short answer:** it did *not* fail on network this time. It got network, ran the
entire install, then died at the **last** step: the appended layer would be
~7.24 GiB, over the 4 GiB FAT32 single-file limit, so `uproot` refused to write
it and the service exited 1. A stale overlay from that failure keeps the service
crash-looping.

## Evidence

1. **Network DID come up** (contradicts FIRSTBOOT.md §2's "blocker").
   `firstboot-20260915160907.log`:
   ```
   [16:10:18] Network is 'limited' (captive portal or no Internet).
   [16:10:23] Network 'limited' but no portal page found; apt may still fail
   [16:10:23] Network up.
   ```
   Wifi `eero` is connected now. The "limited" verdict is a false negative from
   NetworkManager's connectivity check; apt worked fine regardless.

2. **The install ran to completion.** `squashfs_config.sh` finished `exit 0`,
   ending with `Installation complete! Start Brave Browser`. Brave installed;
   most flatpaks were already present from earlier attempts.

3. **It died on the append.**
   `casper/uproot-logs/uproot-20260915082933.log`:
   ```
   User selected: append
   Refusing to write layer: 7772163982 bytes exceeds FAT32 limit 4294901760.
   ```
   The 08:24 run failed identically at `7772210302 bytes`.
   Guard lives at `/cdrom/bin/uproot:187-192`.

4. **Why 7.2 GiB of changes?** The overlay upperdir is dominated by flatpak:
   ```
   5.2G  /tmp/squashfs/upper/var/lib/flatpak   (3.6G repo/objects + 1.7G app)
   0.46G /tmp/squashfs/upper/opt/brave.com
   1.1G  /tmp/squashfs/upper/usr/lib
   ```
   The two attempts differ by only 46 KB — a stable, saturated size, not growth.

## Secondary bug: the poisoned overlay crash loop

The failed run never cleaned up. `/tmp/squashfs/root` is **still** an overlay
mount with `upperdir=/tmp/squashfs/upper/`, and that upperdir still holds all
7.2 GiB (it lives on the live `/cow` overlay, so it survives the service exit).
Every retry therefore:

- silently reuses the existing overlay (`reuse_existing_overlay=1`; `--auto-append`
  never prompts),
- sees flatpaks `already installed` and Brave `already the newest version`,
- fails the same size check again, identically.

Observed: `NRestarts=27`, `status=219/CGROUP`, `RestartSec=300`. The upperdir is
permanently over the limit and nothing prunes it, so this can never succeed.
`casper/lsl-firstboot.attempts` is stuck at `2` because the no-network path and
the uproot-failure path use separate budgets.

## The design flaw

`filesystem.z0.squashfs` is a **12,288-byte stub**, but the appended layer is
built from the *entire* upperdir — including flatpak's `repo/objects` (3.6 G) and
`app` (1.7 G). Non-flatpak changes total only ~2.04 GiB, comfortably under the
4 GiB cap.

`uproot`'s **merge** path excludes `home/*` and apt caches; the **append** path
has no equivalent exclusion list, so flatpak's content-addressed object store
gets baked into a layer that can never fit on FAT32.

## Unstick this boot

```bash
# 1. Kill the loop and clear the poisoned upperdir
sudo systemctl stop lsl-firstboot
sudo umount -R /tmp/squashfs/root 2>/dev/null
sudo rm -rf /tmp/squashfs/upper/* /tmp/squashfs/work/*

# 2. Re-run the install step
sudo bash /cdrom/bin/uproot --auto-append
```

Or just **reboot**: a fresh live boot resets the RAM `/cow`, so the upperdir
starts empty and `squashfs_config.sh` reinstalls cleanly. It will still hit the
4 GiB cap unless flatpak data is excluded or pre-seeded into the base image.

## Permanent fixes (for the `lsl-usb` repo)

1. In `uproot`'s `write_append_layer`, mirror the merge path's exclusions: drop
   `var/lib/flatpak/repo/*` and `var/lib/flatpak/app/*` from the appended layer
   (ship flatpaks in the base image, or install them to a separate data dir).
2. Make the failure path tear down and clear `/tmp/squashfs/{root,upper,work}`
   so a retry starts fresh instead of reusing a poisoned overlay.
3. Treat an over-limit layer as a **deterministic** failure, not transient: write
   `lsl-firstboot.FAILED` + reason and stop retrying every 300 s forever.
4. Correct FIRSTBOOT.md §2 — network worked this boot; the real blocker is the
   FAT32 4 GiB layer cap.

Why no dialog

Did it try to use notify rather than zenity?

root@ubuntu:/cdrom/pi# notify
Command 'notify' not found, but can be installed with:
apt install ruby-notify
root@ubuntu:/cdrom/pi# zenity
You must specify a dialog type. See 'zenity --help' for details
B
A
A
A
A
root@ubuntu:/cdrom/pi# 
