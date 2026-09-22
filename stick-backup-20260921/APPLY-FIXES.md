# APPLY-FIXES.md — how to land this stick's fixes into the repo/build

Companion to `WHYFAIL5.md` (full rationale) and `WHYFAIL6.md`. Everything below
is on **this stick**. Read the "BEFORE YOU START" box first.

```
BEFORE YOU START — re-diff, do not blind-copy
  bin/lsl-common.sh on this stick became byte-identical to the repo during the
  last session because SOMEONE ELSE (not this session) added lsl_env_file()
  there, currently uncommitted. A blind copy of any file from here can revert
  their work. Always run the diff step below and eyeball it first.
```

## What needs applying, and why

| file on this stick | state | why it matters |
|---|---|---|
| `bin/config.sh` | patched | missing desktop icons + a `set -e` abort that killed the systemd install |
| `bin/lsl-gui` | patched | hard `wezterm` dependency; wezterm is not in the image |
| `bin/lsl-gui2` | **new** | working GUI (wezterm-free, catalog-free, dirty-aware) |
| `bin/lsl-pin-favorites` | patched | prefers kitty (installed) over wezterm (absent) |
| `bin/lsl-common.sh` | see warning | trailing-newline fix; the repo may already be ahead |
| `bin/lsl-restore-stick-from-repo.sh` | new | recovery tool (see WHYFAIL5 "collateral damage") |

Repo path is `C:/GitHub/lsl-usb` (on Linux, `/mnt/c/GitHub/lsl-usb`).

## 1. Mount the Windows volume (if not already)

```bash
sudo mkdir -p /mnt/c
sudo mount -t ntfs3 -o ro /dev/nvme0n1p4 /mnt/c      # read-only is enough to diff
```

The real C: is `/dev/nvme0n1p4`. `/mnt/c` as shipped is an empty tmpfs stub — do
not trust it before mounting the volume. If Windows is hibernated
(`hiberfil.sys` present), do **not** mount rw; see WHYFAIL5 gate 2/3.

## 2. Diff first (mandatory)

```bash
R=/mnt/c/GitHub/lsl-usb
for f in config.sh lsl-common.sh lsl-gui lsl-pin-favorites; do
    echo "=== $f"; diff -u "$R/bin/$f" "/cdrom/bin/$f" | head -60
done
ls -la "$R/bin/lsl-gui2" 2>&1      # expect: No such file (it is new)
```

If a diff is *empty*, that file is already current — skip it. If a diff shows
something you did not expect (e.g. `lsl_env_file`), stop and check `git log` /
`git status` in the repo.

## 3. Apply

```bash
R=/mnt/c/GitHub/lsl-usb
cp -p /cdrom/bin/config.sh          "$R/bin/config.sh"
cp -p /cdrom/bin/lsl-gui            "$R/bin/lsl-gui"
cp -p /cdrom/bin/lsl-pin-favorites  "$R/bin/lsl-pin-favorites"
cp -p /cdrom/bin/lsl-gui2           "$R/bin/lsl-gui2"        # NEW file
cp -p /cdrom/bin/lsl-restore-stick-from-repo.sh "$R/bin/"
# only if step 2 showed a diff for lsl-common.sh:
diff -q "$R/bin/lsl-common.sh" /cdrom/bin/lsl-common.sh && cp -p /cdrom/bin/lsl-common.sh "$R/bin/lsl-common.sh"
```

Then review and commit (nothing was committed from the live session):

```bash
cd "$R" && git status --porcelain bin/ && git diff --stat bin/
git add bin/config.sh bin/lsl-gui bin/lsl-pin-favorites bin/lsl-gui2 bin/lsl-common.sh
git commit -m "lsl-gui2: working GUI; config.sh icon/systemd fixes; kitty pinning"
```

## 4. Rebuild the layer (otherwise a fresh build reverts everything)

`casper/filesystem.z0.*.squashfs` and the base layer still contain the **old**
scripts. Anything reading layers rather than the stick sees unfixed versions.
Re-pack through the normal build path (`build.sh` / `uproot`); do not hand-patch
a squashfs.

## 5. Verify after applying

```bash
# desktop icons install on the boot path
bash /cdrom/bin/config.sh --from-onboot; echo "rc=$?"   # expect 0
ls /home/$USER/Desktop/                                  # lsl-gui2.desktop etc.

# the GUI opens (and no longer no-ops on click)
gio launch /home/$USER/Desktop/lsl-gui2.desktop

# the pin selects kitty
bash -c 'source /cdrom/bin/lsl-pin-favorites; choose_terminal_desktop_id'
# expect: kitty.desktop
```

## Known-open, do not mistake for fixed

* `lsl` should pass `-r` to `guestmount` (dirty images are unreadable otherwise)
  and should stop suggesting `qemu-img check -r all` on a hibernated volume.
* The non-COW mount path has no read-only fallback nor post-mount rw check.
* Real rw was never exercised; `rw_gate_check` is intentionally unreachable.
* The kitty **pin** was never confirmed in the panel (root cannot write the
  desktop user's dconf from outside their session).
* `/cdrom/bin/lsl-gui` and `-shutdown-gui` icons now launch, but expect a
  terminal window — the WinForms-style GUI in `lsl-gui` is deliberately stubbed
  to the CLI chooser.
