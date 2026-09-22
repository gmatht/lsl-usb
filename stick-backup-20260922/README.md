# lsl-backup-20260922 — session backup (WHYFAIL7)

Snapshot of every file changed in the WHYFAIL7 session (persistent-home CRLF bug
+ squashfs layer accumulation). **Read `WHYFAIL7.md` first** — it explains the
bugs, the fixes, and what is *not* yet in effect.

Repo is `C:/GitHub/lsl-usb` (`/mnt/c/GitHub/lsl-usb` when the Windows volume is
mounted). Nothing from this session was committed or pushed.

## Layout

This directory deliberately mirrors the repo layout, because
`tests/lsl-common.tests.sh` resolves its subjects relative to the repo root
(`../bin/lsl-common.sh`, `onboot.sh`, `misc/lsl-firstboot.sh`). Flattening it
breaks the suite — verified: a flat copy gave 35/39, this layout gives 39/39.

```
lsl-backup-20260922/
  .gitattributes            <- ROOT-CAUSE FIX: lsl-usb.env/*.env/*.bats -> eol=lf
  CHANGELOG.md              <- both fixes under Unreleased -> Fixed
  WHYFAIL7.md               <- this session's write-up (also at /cdrom/WHYFAIL7.md)
  WHYFAIL6.md               <- §5 documents the hiberfil.sys / powercfg /h off finding
  lsl-usb.env               <- renormalised to LF
  onboot.sh                 <- LSL_ENV_FILE exported before sourcing + mode logging
  bin/lsl-common.sh         <- CRLF/BOM-safe config load, env-file precedence
  bin/uproot                <- prune_superseded_layers(), wired into append
  misc/lsl-firstboot.sh     <- success-path layer prune (NOT on the FAT partition)
  tests/lsl-common.tests.sh <- 13 new tests; 39 passed / 0 failed
```

## Already on the stick root (the live copies)

These are at `/cdrom/<path>` and byte-identical to the repo:

| Stick path | Repo path | Live on boot? |
|---|---|---|
| `bin/lsl-common.sh` | `bin/lsl-common.sh` | yes |
| `bin/uproot` | `bin/uproot` | yes — **prune fix already active** |
| `onboot.sh` | `onboot.sh` | yes |
| `lsl-usb.env` | `lsl-usb.env` | yes |
| `WHYFAIL7.md` | `WHYFAIL7.md` | n/a |
| `WHYFAIL6.md` (backup dir only) | `WHYFAIL6.md` | pre-existing file; §5 was added this session |

## NOT yet in effect (the one gap)

`misc/lsl-firstboot.sh` ships **inside `casper/filesystem_z0_firstboot.squashfs`**
— it is not on the FAT partition, so this backup copy is the only updated one.
The success-path layer prune will not run on a boot until that layer is rebuilt.
The `uproot`-side prune needs no rebuild.

## Verify

```bash
# 1. Config load: expects dir=/mnt/c/Users/lsl-usb, mode=hdd, persistent=yes
env -u LSL_ENV_FILE bash -c '. /cdrom/bin/lsl-common.sh; lsl_load_config
  echo "dir=[$(lsl_resolve_data_dir)]"
  lsl_is_usb_mode && echo "mode=usb" || echo "mode=hdd"
  lsl_data_dir_is_persistent && echo "persistent=yes" || echo "persistent=no"'

# 2. Regression suite — run from THIS directory (layout matters)
cd /cdrom/lsl-backup-20260922 && bash tests/lsl-common.tests.sh
# expect: RESULT: 39 passed, 0 failed

# 3. Every layerfs-path in the boot config must resolve to a real file
for f in $(grep -o 'layerfs-path=[^ ]*' /cdrom/menu.lst | sed 's/layerfs-path=//' | sort -u); do
    [ -f "$f" ] && echo "OK  $f" || echo "MISSING $f"
done
```

## Re-applying after a fresh Windows checkout

If the repo is re-checked out and picks up CRLF again:

```bash
git add --renormalize .          # updates the index, NOT the working tree
rm -f tests/*.sh tests/*.bats tests/extract_fn.py lsl-usb.env
git checkout -- tests/ lsl-usb.env
file lsl-usb.env                 # want "UTF-8 text", NOT "with CRLF line terminators"
```

## State at backup time

```
/dev/sda1  /cdrom   29G   3.5G   26G   13%     (6.4G before the 2.9 GB reclaim)
casper/filesystem.squashfs                     2.4 GB  base
casper/filesystem.z0.squashfs                   28 KB  firstboot stub layer
casper/filesystem.z0.20260921085616.squashfs   761 MB  <- the only appended layer
casper/filesystem.z0.20260921085616.sh         9.5 KB  companion config snapshot
casper/lsl-firstboot.done                      exists  (firstboot completed)
```

Four inert layers were deleted this session; `menu.lst` names only
`...085616`, and it was verified present after the reclaim.
