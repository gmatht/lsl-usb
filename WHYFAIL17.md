# WHYFAIL17 — The panel lost every pinned app, including kitty

Asked 2026-10-01, immediately after the reboot that was supposed to deliver the
kitty panel icon: *"Why is there an lsl-usb first boot complete reboot request? I
already rebooted. Shouldn't I be in full LSL now... and so why isn't there a
kitty terminal icon in the taskbar?"*

Short answer: **the reboot worked, and kitty was installed, pinned and running.**
The icon was missing because `bin/lsl-pin-favorites` — the script that writes the
pin — had corrupted Cinnamon's favorites list into a form the panel cannot read.
It replaced the whole list with one bogus entry, so *every* pinned app
disappeared, not just kitty.

This is the companion to `rust9x/lslsetup/WHYFAIL15.md`: that one explains why
the *fix* needed a rebuild to ship; this one explains the bug that needed fixing.

---

## 1. What the operator saw

No kitty icon in the panel taskbar (the `favorites@cinnamon.org` applet), on a
boot that had otherwise completed first-boot successfully.

The expected story was well documented: `config.sh` installs an autostart entry
which runs `bin/lsl-pin-favorites` at login, that script pins the terminal, and
`WHYFAIL13` had already established that kitty only becomes *available* on the
second boot (it lands in an appended layer). So "reboot and the icon appears" was
the predicted behaviour.

## 2. What was actually true

Every link in that chain except the last was fine:

```
/proc/mounts  lowerdir=/filesystem_z20260930192536.squashfs:filesystem_z0_firstboot.squashfs:filesystem.squashfs
              ^ the merged layer IS loaded this boot

/usr/bin/kitty                       exists
/usr/share/applications/kitty.desktop exists
/usr/share/icons/hicolor/.../kitty.{png,svg} exists

/home/ubuntu/.config/autostart/lsl-pin-favorites.desktop   exists, and RAN
syslog: ... systemd-xdg-autostart-generator[2860]: Configuration file
        /home/ubuntu/.config/autostart/lsl-pin-favorites.desktop is marked executable
        ... Proceeding anyway.        (02:41:49)

ps: cinnamon --replace (3840) alive, favorites@cinnamon.org applet loaded
```

And the pin *had* been written — `kitty.desktop` was in the favorites list. The
problem was what else was in it:

```bash
$ gsettings get org.cinnamon favorite-apps
['org.gnome.Calculator.desktop org.gnome.Calendar.desktop org.x.editor.desktop
 mintinstall.desktop cinnamon-settings.desktop org.gnome.Terminal.desktop
 org.gnome.Terminal.desktop',
 'kitty.desktop',
 'brave-browser.desktop']
```

**The first element is a single quoted string containing the entire original
list**, space-separated. It is not seven entries; it is one entry that names no
desktop file. `XApp.Favorites` resolves each element as a desktop-file id, so it
silently drops that element — taking Calculator, Calendar, xed, mintinstall,
cinnamon-settings and the terminal with it. kitty and brave *were* appended, but
as entries 2 and 3 of a list whose first entry is garbage.

So the symptom "no kitty icon" was really "the favorites applet has almost
nothing to show", and the panel's own original five icons were gone too.

## 3. Root cause — a parser that splits on the wrong character

`gsettings get` prints a string-array (`as`) on a **single line**:

```
['a.desktop', 'b.desktop', 'c.desktop']
```

The script stripped the brackets, quotes and commas, then read the result
**line by line**:

```bash
# bin/lsl-pin-favorites, before
cur_raw="$(gsettings get org.cinnamon favorite-apps 2>/dev/null || true)"
cur_raw="${cur_raw#[}"
cur_raw="${cur_raw%]}"
cur_raw="${cur_raw//\'/}"
cur_raw="${cur_raw//,/}"          # commas removed, but not SPLIT on

cur=()
while IFS= read -r tok; do        # <-- one line in, one token out
    tok="${tok#"${tok%%[![:space:]]*}"}"
    tok="${tok%"${tok##*[![:space:]]}"}"
    [ -n "$tok" ] && cur+=("$tok")
done <<<"$cur_raw"
```

Because `gsettings` emits one line, that loop produced exactly **one** token: the
entire comma-stripped list, with the entries now separated by spaces. The script
then appended its two new apps and wrote the array back out — so the corruption
was **persistent**: each run re-read the broken value and preserved it.

Reproduced directly:

```bash
$ gsettings get org.cinnamon favorite-apps
['org.gnome.Calculator.desktop', 'org.gnome.Calendar.desktop', ...]
$ # after the strip-and-readline above:
TOKEN: <org.gnome.Calculator.desktop org.gnome.Calendar.desktop ... kitty.desktop>
```

This is the same class of error as the recorded preference about `gsettings`
output: **the value is one line, so line-oriented parsing collapses it.** The
`as` type is comma-delimited, and nothing about its printed form is
line-delimited.

Why it was not caught earlier: the script is only exercised at desktop login on a
real stick, and its failure mode is *silent* — `gsettings set` succeeds, the
script exits 0, and Cinnamon drops the unresolvable element without a word.

## 4. Fix

`bin/lsl-pin-favorites` gained a `parse_gsettings_array()` that splits on
**commas**, and the write-back path is unchanged:

```bash
parse_gsettings_array() {
    local raw="$1"
    raw="${raw#[}"; raw="${raw%]}"
    raw="${raw//\'/}"
    local tok
    local IFS=','
    for tok in $raw; do
        tok="${tok#"${tok%%[![:space:]]*}"}"
        tok="${tok%"${tok##*[![:space:]]}"}"
        [ -n "$tok" ] && printf '%s\n' "$tok"
    done
}
```

A **self-heal** was added as well, because sticks in the field already carry the
corrupted value and a fixed script must repair it rather than preserve it: an
element containing a space cannot be a desktop-file id, so those are split on
spaces before the append/dedupe:

```bash
healed=()
for tok in "${cur[@]}"; do
    if [[ "$tok" == *" "* ]]; then
        for sub in $tok; do [ -n "$sub" ] && healed+=("$sub"); done
    else
        healed+=("$tok")
    fi
done
```

Verified on the live system (the corrupted value above, with the applet watching
the `changed` signal, so no reboot was needed):

```
healthy:    ['org.gnome.Calculator.desktop', 'org.x.editor.desktop', 'kitty.desktop']
corrupt:    ['org.gnome.Calculator.desktop', 'org.x.editor.desktop',
             'org.gnome.Terminal.desktop', 'kitty.desktop', 'brave-browser.desktop']
empty:      ['kitty.desktop']
single:     ['kitty.desktop']
dupe-guard: ['kitty.desktop', 'brave-browser.desktop']
```

and idempotent against an already-healthy list (a re-run changes nothing).

A regression test was added to `tests/bash.tests.bats`
(`parse_gsettings_array splits on commas, not newlines`), including the empty
array case.

## 5. Why rebooting could not have fixed it

The corruption lived in `~/.config/dconf/user`, which is on the **persistent**
home. A reboot re-ran the same broken script at login, which re-read the
corrupted value and wrote it back. The bug was stable, not transient — the second
reboot would have shown the same empty panel.

(It also explains a detail worth noting: `dconf`'s file is only flushed when the
session writes, so the corruption is visible at the *next* login even if the
running session still looked right.)

## 6. Related

- **`rust9x/lslsetup/WHYFAIL15.md`** — the same fix could not reach a stick
  without rebuilding `lslsetup.exe`, because the script is embedded with
  `include_str!` and every built exe still carried the old copy. The two documents
  are a pair: 15 is *"the fix did not ship"*; this is *"the bug it fixes"*.
- **`WHYFAIL13.md`** (`rust9x/lslsetup/`) — the first-boot dialog; it established
  that kitty arrives in an appended layer and needs a reboot. True, and not the
  reason the icon was missing.
- **`WHYFAIL5.md`** — the earlier `gsettings`-as-root investigation. Same tool,
  same class of trap: `gsettings` is session-scoped, and its output format is not
  what line-based tooling assumes.

## The rule worth keeping

> **`gsettings get` prints an `as` array on one line; split on commas.**
> A line-oriented loop over a comma-delimited value does not fail loudly — it
> produces exactly one token, the whole list, and every write-back makes the
> damage permanent. When the format is declarative (an array literal), parse the
> declaration; do not guess at its line structure.
