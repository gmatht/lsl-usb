#!/usr/bin/env bats
# tests/bash.tests.bats - regression tests for the Linux-side bash scripts.
# Run: bats tests/bash.tests.bats   (or via CI)

setup() {
    export TMPDIR_TEST="$(mktemp -d)"
}
teardown() {
    rm -rf "$TMPDIR_TEST"
}

# --- detect-wsl: win_path_to_linux (single/double backslashes, slashes) ---
@test "win_path_to_linux: single backslashes" {
    eval "$(sed -n '/^win_path_to_linux()/,/^}/p' bin/detect-wsl)"
    run win_path_to_linux 'C:\Users\alice\ext4.vhdx'
    [ "$status" -eq 0 ]
    [ "$output" = "/mnt/c/Users/alice/ext4.vhdx" ]
}

@test "win_path_to_linux: doubled backslashes (hivexregedit form)" {
    eval "$(sed -n '/^win_path_to_linux()/,/^}/p' bin/detect-wsl)"
    run win_path_to_linux 'C:\\Users\\bob\\x\\ext4.vhdx'
    [ "$status" -eq 0 ]
    [ "$output" = "/mnt/c/Users/bob/x/ext4.vhdx" ]
}

@test "win_path_to_linux: forward slashes" {
    eval "$(sed -n '/^win_path_to_linux()/,/^}/p' bin/detect-wsl)"
    run win_path_to_linux 'D:/WSL/Ubuntu2404/ext4.vhdx'
    [ "$status" -eq 0 ]
    [ "$output" = "/mnt/d/WSL/Ubuntu2404/ext4.vhdx" ]
}

@test "win_path_to_linux: invalid path fails" {
    eval "$(sed -n '/^win_path_to_linux()/,/^}/p' bin/detect-wsl)"
    run win_path_to_linux 'not-a-path'
    [ "$status" -ne 0 ]
}

# --- lsl-precache: mode decision + memory floor ---
@test "lsl-precache: no list -> no-op exit 0" {
    run env PRECACHE_LIST="$TMPDIR_TEST/missing" bash bin/lsl-precache.sh
    [ "$status" -eq 0 ]
}

@test "lsl-precache: LIST mode warms the hot files" {
    printf '/etc/os-release\n/bin/bash\n' > "$TMPDIR_TEST/list"
    run env PRECACHE_LIST="$TMPDIR_TEST/list" PRECACHE_TARGETS="" bash bin/lsl-precache.sh
    [ "$status" -eq 0 ]
    [[ "$output" == *"hot files"* ]]
}

@test "lsl-precache: FULL mode when image < 50% RAM, memory floor stops it" {
    printf '/etc/os-release\n' > "$TMPDIR_TEST/list"
    run env PRECACHE_LIST="$TMPDIR_TEST/list" PRECACHE_TARGETS="/bin/bash" \
        PRECACHE_MIN_FREE_PCT=100 bash bin/lsl-precache.sh
    [ "$status" -eq 0 ]
    [[ "$output" == *"FULL"* ]]
}

# --- lsl-boot-time: mark / desktop / view ---
@test "lsl-boot-time: mark + desktop + view" {
    run env LSL_BOOT_STATE="$TMPDIR_TEST/state" LSL_BOOT_LOG="$TMPDIR_TEST/log" \
        bash bin/lsl-boot-time.sh --mark
    [ "$status" -eq 0 ]
    run env LSL_BOOT_STATE="$TMPDIR_TEST/state" LSL_BOOT_LOG="$TMPDIR_TEST/log" \
        LSL_PRECACHE_LIST="$TMPDIR_TEST/missing" bash bin/lsl-boot-time.sh --desktop
    [ "$status" -eq 0 ]
    run env LSL_BOOT_LOG="$TMPDIR_TEST/log" bash bin/lsl-boot-time.sh
    [ "$status" -eq 0 ]
    [[ "$output" == *"desktop"* ]]
}

# --- lsl-rusttools / lsl-appimages: list parsing ---
@test "rusttools.list: well-formed (5 tab-separated fields)" {
    while IFS=$'\t' read -r name repo pat binname equiv; do
        [ -n "$name" ] && [ -n "$repo" ] && [ -n "$pat" ] && [ -n "$binname" ] && [ -n "$equiv" ]
    done < bin/rusttools.list
}

@test "appimages.list: well-formed (4 tab-separated fields)" {
    while IFS=$'\t' read -r name type src pat; do
        [ -n "$name" ] && [ -n "$type" ] && [ -n "$src" ]
    done < bin/appimages.list
}

# --- squashfs_config.sh (the first-boot recipe) ---
@test "squashfs_config.sh: syntax" {
    bash -n bin/squashfs_config.sh
}

@test "squashfs_config.sh: referenced scripts exist" {
    for ref in lsl-appimages.sh lsl-rusttools.sh; do
        grep -q "$ref" bin/squashfs_config.sh
    done
}

# --- lsl-find: EFU search ---
@test "lsl-find: searches the EFU index, handles commas, skips header" {
    printf 'Filename,Size,Date Modified,Date Created,Attributes\n"C:\\a\\file, with comma.txt",123,1,,0\n"D:\\WSL\\ext4.vhdx",456,1,,0\n' > "$TMPDIR_TEST/find.efu"
    run env LSL_EFU="$TMPDIR_TEST/find.efu" bash bin/lsl-find vhdx
    [ "$status" -eq 0 ]
    [ "$output" = 'D:\WSL\ext4.vhdx' ]
    run env LSL_EFU="$TMPDIR_TEST/find.efu" bash bin/lsl-find comma
    [ "$output" = 'C:\a\file, with comma.txt' ]
}

# --- lsl-toram: guard (not a live session) ---
@test "lsl-toram: refuses when /cdrom is not mounted" {
    MOCKS="$TMPDIR_TEST/bin"
    mkdir -p "$MOCKS"
    printf '#!/bin/bash\necho 0\n' > "$MOCKS/id"
    chmod +x "$MOCKS"*
    run env PATH="$MOCKS:$PATH" bash bin/lsl-toram.sh
    [ "$status" -eq 1 ]
    [[ "$output" == *"not look like a live session"* ]]
}

# --- lsl-toram: --progress protocol (the zenity "PCT # text" feed) ---
@test "lsl-toram: rejects an unknown option" {
    run bash bin/lsl-toram.sh --bogus
    [ "$status" -eq 2 ]
    [[ "$output" == *"Unknown option"* ]]
}

@test "lsl-toram: --progress emits the protocol and closes at 100" {
    mkdir -p "$TMPDIR_TEST/bin" "$TMPDIR_TEST/run"
    printf '#!/bin/bash\necho 0\n' > "$TMPDIR_TEST/bin/id"
    chmod +x "$TMPDIR_TEST/bin/id"
    # Rewrite /run paths to the temp dir (as the in-flight-write test does), then
    # take the already-running early exit - the only path reachable off a live
    # root, but it exercises arg parsing, say()/progress() and the 100 close.
    sed "s#/run/#$TMPDIR_TEST/run/#g" bin/lsl-toram.sh > "$TMPDIR_TEST/toram.sh"
    chmod +x "$TMPDIR_TEST/toram.sh"
    : > "$TMPDIR_TEST/run/lsl-toram.done"
    run env PATH="$TMPDIR_TEST/bin:$PATH" bash "$TMPDIR_TEST/toram.sh" --progress
    [ "$status" -eq 0 ]
    [[ "$output" == *"100 #"* ]]
}

@test "lsl-toram: without --progress keeps the human output (no protocol)" {
    mkdir -p "$TMPDIR_TEST/bin" "$TMPDIR_TEST/run"
    printf '#!/bin/bash\necho 0\n' > "$TMPDIR_TEST/bin/id"
    chmod +x "$TMPDIR_TEST/bin/id"
    sed "s#/run/#$TMPDIR_TEST/run/#g" bin/lsl-toram.sh > "$TMPDIR_TEST/toram.sh"
    chmod +x "$TMPDIR_TEST/toram.sh"
    : > "$TMPDIR_TEST/run/lsl-toram.done"
    run env PATH="$TMPDIR_TEST/bin:$PATH" bash "$TMPDIR_TEST/toram.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already running from RAM"* ]]
    [[ "$output" != *"100 #"* ]]
}

# --- lsl-flatpak-fat: usage + guard ---
@test "lsl-flatpak-fat: usage without args" {
    run bash bin/lsl-flatpak-fat.sh
    [ "$status" -eq 1 ]
    [[ "$output" == *"usage"* ]]
}

# --- uproot: --auto-append arg parsing ---
@test "uproot: unknown option rejected" {
    run bash bin/uproot --bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown option"* ]]
}

# --- lsl-boot-time: probe runs with a list ---
@test "lsl-boot-time: probe measures the precache list" {
    printf '/etc/os-release\n/bin/bash\n' > "$TMPDIR_TEST/list"
    run env LSL_BOOT_STATE="$TMPDIR_TEST/state" LSL_BOOT_LOG="$TMPDIR_TEST/log" \
        LSL_PRECACHE_LIST="$TMPDIR_TEST/list" bash bin/lsl-boot-time.sh --desktop
    [ "$status" -eq 0 ]
    [[ "$output" == *"probe"* ]]
}

# --- lsl: --find / --efu dispatch ---
@test "lsl --find dispatches to lsl-find" {
    mkdir -p "$TMPDIR_TEST/bin"
    printf '#!/bin/bash\necho "lsl-find called with: $*"\n' > "$TMPDIR_TEST/bin/lsl-find"
    chmod +x "$TMPDIR_TEST/bin/lsl-find"
    run env PATH="$TMPDIR_TEST/bin:$PATH" bash bin/lsl --find vhdx
    [ "$status" -eq 0 ]
    [ "$output" = 'lsl-find called with: vhdx' ]
}

@test "lsl --efu dispatches to lsl-find -l" {
    mkdir -p "$TMPDIR_TEST/bin"
    printf '#!/bin/bash\necho "lsl-find called with: $*"\n' > "$TMPDIR_TEST/bin/lsl-find"
    chmod +x "$TMPDIR_TEST/bin/lsl-find"
    run env PATH="$TMPDIR_TEST/bin:$PATH" bash bin/lsl --efu vhdx
    [ "$status" -eq 0 ]
    [ "$output" = 'lsl-find called with: -l vhdx' ]
}

# --- lsl-shutdown-gui: toram option present in all menu variants ---
@test "lsl-shutdown-gui: toram option warns about persistence in all menus" {
    n=$(grep -c 'Load to RAM + remove USB (persistence to USB stops)' bin/lsl-shutdown-gui)
    [ "$n" -eq 4 ]
    bash -n bin/lsl-shutdown-gui
}

@test "lsl-shutdown-gui: toram case arm matches the label zenity returns" {
    # zenity --radiolist returns the option TEXT, not its index, so the case
    # arm must match the whole label including "(persistence to USB stops)".
    # The old bare "Load to RAM + remove USB" pattern fell through to the
    # catch-all `*) exit 0`: selecting the option did nothing at all.
    grep -qF '"Load to RAM + remove USB"*|"7")' bin/lsl-shutdown-gui
}

@test "lsl-shutdown-gui: Load to RAM runs toram --progress and reports success" {
    mkdir -p "$TMPDIR_TEST/bin"
    # zenity mock: the radiolist returns the toram label; --progress drains
    # the feeder; --info/--error are recorded so we can assert the notice.
    cat > "$TMPDIR_TEST/bin/zenity" <<'EOF'
#!/bin/bash
for a in "$@"; do
    case "$a" in
        --list) echo "Load to RAM + remove USB (persistence to USB stops)"; exit 0 ;;
        --progress) cat >/dev/null; exit 0 ;;
        --info) echo "INFO $*" >> "$ZENITY_LOG"; exit 0 ;;
        --error) echo "ERROR $*" >> "$ZENITY_LOG"; exit 0 ;;
    esac
done
exit 0
EOF
    chmod +x "$TMPDIR_TEST/bin/zenity"
    # pkexec mock: run the target directly (the run_privileged ladder).
    printf '#!/bin/bash\nexec "$@"\n' > "$TMPDIR_TEST/bin/pkexec"
    chmod +x "$TMPDIR_TEST/bin/pkexec"
    # toram mock: record its argv and speak the progress protocol.
    cat > "$TMPDIR_TEST/toram" <<'EOF'
#!/bin/bash
echo "toram $*" >> "$TORAM_LOG"
echo "42 # half"
echo "100 # done"
EOF
    chmod +x "$TMPDIR_TEST/toram"
    export TORAM_LOG="$TMPDIR_TEST/toram.log" ZENITY_LOG="$TMPDIR_TEST/zenity.log"
    : > "$TORAM_LOG"
    : > "$ZENITY_LOG"
    run env PATH="$TMPDIR_TEST/bin:$PATH" LSL_TORAM_BIN="$TMPDIR_TEST/toram" \
        bash bin/lsl-shutdown-gui
    [ "$status" -eq 0 ]
    grep -q 'toram --progress' "$TORAM_LOG"
    grep -q 'Session is now running from RAM' "$ZENITY_LOG"
}

@test "shutdown chain: sibling scripts resolve from the nofmt toolkit" {
    # lsl-shutdown-gui resolves uphome via PATH or /cdrom/bin/uphome; uphome
    # execs lsl-flush-home.sh (USB) and sources lsl-common.sh, and calls
    # persist-wifi.sh. The "Load to RAM + remove USB" option execs
    # /cdrom/bin/lsl-toram.sh. The nofmt installer writes /cdrom/bin from
    # FIRSTBOOT_TOOLKIT only - anything referenced but not embedded fails
    # at shutdown with "Could not find 'uphome'". Every name must exist
    # in repo bin/ AND be embedded in the toolkit array.
    for name in uphome lsl-flush-home.sh lsl-common.sh persist-wifi.sh lsl-toram.sh; do
        [ -f "bin/$name" ]
        grep -qF "bin\\\\$name" rust9x/lslsetup/src/lslfiles.rs
    done
}

# --- lsl-firstboot: dry-run with mocks ---
setup_firstboot() {
    export LSL_FIRSTBOOT_STAMP="$TMPDIR_TEST/stamp"
    export LSL_FIRSTBOOT_LOG_DIR="$TMPDIR_TEST/logs"
    export LSL_FIRSTBOOT_STATUS="$TMPDIR_TEST/status"
    export LSL_FIRSTBOOT_UPROOT="$TMPDIR_TEST/uproot"
    export LSL_FIRSTBOOT_ATTEMPT="$TMPDIR_TEST/attempts"
    export LSL_FIRSTBOOT_NET_TRIES=1
    export LSL_FIRSTBOOT_REBOOT=0
    # Instant reboot path by default (LSL_FIRSTBOOT_REBOOT_TIMEOUT=0 reboots
    # immediately without asking); approval-wait tests override per-case
    # below. Any other timeout value waits indefinitely for user approval.
    export LSL_FIRSTBOOT_REBOOT_TIMEOUT=0
    export LSL_FIRSTBOOT_FLAG_DIR="$TMPDIR_TEST/reboot-flags"
    # Stick location seam (misc/lsl-firstboot.sh): the partition scan and
    # the /cdrom fallback both need root; CI runners are non-root.
    mkdir -p "$TMPDIR_TEST/stick/casper" "$TMPDIR_TEST/bin"
    export LSL_FIRSTBOOT_STICK="$TMPDIR_TEST/stick"
    printf '#!/bin/bash\necho full\n' > "$TMPDIR_TEST/bin/nmcli"
    chmod +x "$TMPDIR_TEST/bin/nmcli"
    # No graphical sessions by default: the reboot-timer dialog launcher
    # becomes a silent no-op (notify tests install their own stub after).
    printf '#!/bin/bash\nexit 0\n' > "$TMPDIR_TEST/bin/loginctl"
    chmod +x "$TMPDIR_TEST/bin/loginctl"
    export PATH="$TMPDIR_TEST/bin:$PATH"
}

@test "lsl-firstboot: stamp present -> exit 0" {
    setup_firstboot
    touch "$LSL_FIRSTBOOT_STAMP"
    run bash misc/lsl-firstboot.sh
    [ "$status" -eq 0 ]
}

@test "lsl-firstboot: no network -> exit 1 (retry)" {
    setup_firstboot
    printf '#!/bin/bash\nexit 1\n' > "$TMPDIR_TEST/bin/nmcli"
    chmod +x "$TMPDIR_TEST/bin/nmcli"
    run bash misc/lsl-firstboot.sh
    [ "$status" -eq 1 ]
    [ ! -e "$LSL_FIRSTBOOT_STAMP" ]
}

@test "lsl-firstboot: uproot missing -> stamp anyway" {
    setup_firstboot
    run bash misc/lsl-firstboot.sh
    [ "$status" -eq 0 ]
    [ -e "$LSL_FIRSTBOOT_STAMP" ]
}

@test "lsl-firstboot: uproot success -> stamp + reboot" {
    setup_firstboot
    printf '#!/bin/bash\nexit 0\n' > "$LSL_FIRSTBOOT_UPROOT"
    chmod +x "$LSL_FIRSTBOOT_UPROOT"
    printf '#!/bin/bash\necho "systemctl $*" >> "$TMPDIR_TEST/reboot.log"\n' > "$TMPDIR_TEST/bin/systemctl"
    chmod +x "$TMPDIR_TEST/bin/systemctl"
    export LSL_FIRSTBOOT_REBOOT=1
    run bash misc/lsl-firstboot.sh
    [ "$status" -eq 0 ]
    [ -e "$LSL_FIRSTBOOT_STAMP" ]
    grep -q "reboot" "$TMPDIR_TEST/reboot.log"
}

@test "lsl-firstboot: success flushes home via the stick uphome" {
    setup_firstboot
    printf '#!/bin/bash\nexit 0\n' > "$LSL_FIRSTBOOT_UPROOT"
    chmod +x "$LSL_FIRSTBOOT_UPROOT"
    mkdir -p "$LSL_FIRSTBOOT_STICK/bin"
    printf '#!/bin/bash\necho flushed > "$TMPDIR_TEST/home-flushed"\n' > "$LSL_FIRSTBOOT_STICK/bin/uphome"
    chmod +x "$LSL_FIRSTBOOT_STICK/bin/uphome"
    printf '#!/bin/bash\necho "systemctl $*" >> "$TMPDIR_TEST/reboot.log"\n' > "$TMPDIR_TEST/bin/systemctl"
    chmod +x "$TMPDIR_TEST/bin/systemctl"
    export LSL_FIRSTBOOT_REBOOT=1
    run bash misc/lsl-firstboot.sh
    [ "$status" -eq 0 ]
    [ -e "$LSL_FIRSTBOOT_STAMP" ]
    [ -e "$TMPDIR_TEST/home-flushed" ]
    grep -q "reboot" "$TMPDIR_TEST/reboot.log"
}

@test "lsl-firstboot: reboot approval honors cancel written while waiting" {
    setup_firstboot
    printf '#!/bin/bash\nexit 0\n' > "$LSL_FIRSTBOOT_UPROOT"
    chmod +x "$LSL_FIRSTBOOT_UPROOT"
    printf '#!/bin/bash\necho "systemctl $*" >> "$TMPDIR_TEST/reboot.log"\n' > "$TMPDIR_TEST/bin/systemctl"
    chmod +x "$TMPDIR_TEST/bin/systemctl"
    export LSL_FIRSTBOOT_REBOOT=1 LSL_FIRSTBOOT_REBOOT_TIMEOUT=60
    mkdir -p "$LSL_FIRSTBOOT_FLAG_DIR"
    # Signal after the loop starts (it clears stale flags first, and logs
    # "Waiting for you to approve" once listening) - no race either way.
    bash misc/lsl-firstboot.sh >"$TMPDIR_TEST/out.log" 2>&1 &
    srv=$!
    for _ in $(seq 1 200); do
        grep -q "Waiting for you to approve" "$TMPDIR_TEST/logs"/*.log 2>/dev/null && break
        sleep 0.1
    done
    touch "$LSL_FIRSTBOOT_FLAG_DIR/reboot-cancel"
    wait "$srv"
    [ "$?" -eq 0 ]
    [ -e "$LSL_FIRSTBOOT_STAMP" ]
    [ ! -e "$TMPDIR_TEST/reboot.log" ]
}

@test "lsl-firstboot: reboot approval honors reboot-now written while waiting" {
    setup_firstboot
    printf '#!/bin/bash\nexit 0\n' > "$LSL_FIRSTBOOT_UPROOT"
    chmod +x "$LSL_FIRSTBOOT_UPROOT"
    printf '#!/bin/bash\necho "systemctl $*" >> "$TMPDIR_TEST/reboot.log"\n' > "$TMPDIR_TEST/bin/systemctl"
    chmod +x "$TMPDIR_TEST/bin/systemctl"
    export LSL_FIRSTBOOT_REBOOT=1 LSL_FIRSTBOOT_REBOOT_TIMEOUT=60
    mkdir -p "$LSL_FIRSTBOOT_FLAG_DIR"
    bash misc/lsl-firstboot.sh >"$TMPDIR_TEST/out.log" 2>&1 &
    srv=$!
    for _ in $(seq 1 200); do
        grep -q "Waiting for you to approve" "$TMPDIR_TEST/logs"/*.log 2>/dev/null && break
        sleep 0.1
    done
    touch "$LSL_FIRSTBOOT_FLAG_DIR/reboot-now"
    wait "$srv"
    [ "$?" -eq 0 ]
    [ -e "$LSL_FIRSTBOOT_STAMP" ]
    grep -q "reboot" "$TMPDIR_TEST/reboot.log"
}

@test "lsl-firstboot: reboot approval never fires on its own (no timer)" {
    setup_firstboot
    printf '#!/bin/bash\nexit 0\n' > "$LSL_FIRSTBOOT_UPROOT"
    chmod +x "$LSL_FIRSTBOOT_UPROOT"
    printf '#!/bin/bash\necho "systemctl $*" >> "$TMPDIR_TEST/reboot.log"\n' > "$TMPDIR_TEST/bin/systemctl"
    chmod +x "$TMPDIR_TEST/bin/systemctl"
    export LSL_FIRSTBOOT_REBOOT=1 LSL_FIRSTBOOT_REBOOT_TIMEOUT=600
    mkdir -p "$LSL_FIRSTBOOT_FLAG_DIR"
    bash misc/lsl-firstboot.sh >"$TMPDIR_TEST/out.log" 2>&1 &
    srv=$!
    for _ in $(seq 1 100); do
        grep -q "Waiting for you to approve" "$TMPDIR_TEST/logs"/*.log 2>/dev/null && break
        sleep 0.1
    done
    grep -q "Waiting for you to approve" "$TMPDIR_TEST/logs"/*.log
    # Past the old 10-minute-timer behavior: no decision yet, so no reboot.
    sleep 5
    [ ! -e "$TMPDIR_TEST/reboot.log" ]
    kill "$srv" 2>/dev/null || true
    wait "$srv" 2>/dev/null || true
    [ -e "$LSL_FIRSTBOOT_STAMP" ]
    [ ! -e "$TMPDIR_TEST/reboot.log" ]
}

@test "lsl-firstboot: uproot failure retries, then gives up after max attempts" {
    setup_firstboot
    printf '#!/bin/bash\nexit 1\n' > "$LSL_FIRSTBOOT_UPROOT"
    chmod +x "$LSL_FIRSTBOOT_UPROOT"
    export LSL_FIRSTBOOT_MAX_ATTEMPTS=3
    run bash misc/lsl-firstboot.sh
    [ "$status" -eq 1 ]
    [ ! -e "$LSL_FIRSTBOOT_STAMP" ]
    run bash misc/lsl-firstboot.sh
    [ "$status" -eq 1 ]
    run bash misc/lsl-firstboot.sh
    [ "$status" -eq 0 ]   # gave up after 3 attempts
    [ -e "$LSL_FIRSTBOOT_STAMP" ]
}

@test "lsl-firstboot-reboot: no backend exits 0 without flags" {
    mkdir -p "$TMPDIR_TEST/empty" "$TMPDIR_TEST/flags"
    # PATH with nothing in it: no python3, no zenity, no date/logger
    # (all guarded). LSL_PROGRESS_GTK points at a missing file.
    run env PATH="$TMPDIR_TEST/empty" LSL_PROGRESS_GTK="$TMPDIR_TEST/missing.py" \
        LSL_DIALOG_LOG="$TMPDIR_TEST/dialog.log" \
        /bin/bash misc/lsl-firstboot-reboot.sh --timeout 600 --flag-dir "$TMPDIR_TEST/flags"
    [ "$status" -eq 0 ]
    [ ! -e "$TMPDIR_TEST/flags/reboot-now" ]
    [ ! -e "$TMPDIR_TEST/flags/reboot-cancel" ]
}

@test "lsl-firstboot-reboot: gtk backend waits for approval (no timer)" {
    mkdir -p "$TMPDIR_TEST/bin" "$TMPDIR_TEST/flags"
    printf '#!/bin/bash\nif [ "$1" = "-c" ]; then exit 0; fi\necho "$@" > "$TMPDIR_TEST/gtk-args"\n' > "$TMPDIR_TEST/bin/python3"
    chmod +x "$TMPDIR_TEST/bin/python3"
    touch "$TMPDIR_TEST/fake-gtk.py"
    run env PATH="$TMPDIR_TEST/bin:/usr/bin:/bin" LSL_PROGRESS_GTK="$TMPDIR_TEST/fake-gtk.py" \
        LSL_DIALOG_LOG="$TMPDIR_TEST/dialog.log" \
        bash misc/lsl-firstboot-reboot.sh --flag-dir "$TMPDIR_TEST/flags"
    [ "$status" -eq 0 ]
    grep -q -- "--reboot-countdown 0" "$TMPDIR_TEST/gtk-args"
    grep -q -- "--flag-dir $TMPDIR_TEST/flags" "$TMPDIR_TEST/gtk-args"
    grep -q -- "NOT reboot" "$TMPDIR_TEST/gtk-args"
    # Legacy --timeout is accepted but ignored (no timer).
    run env PATH="$TMPDIR_TEST/bin:/usr/bin:/bin" LSL_PROGRESS_GTK="$TMPDIR_TEST/fake-gtk.py" \
        LSL_DIALOG_LOG="$TMPDIR_TEST/dialog.log" \
        bash misc/lsl-firstboot-reboot.sh --timeout 321 --flag-dir "$TMPDIR_TEST/flags"
    [ "$status" -eq 0 ]
    grep -q -- "--reboot-countdown 0" "$TMPDIR_TEST/gtk-args"
}

@test "lsl-firstboot-reboot: zenity ok writes reboot-now, cancel writes reboot-cancel" {
    mkdir -p "$TMPDIR_TEST/bin" "$TMPDIR_TEST/flags"
    printf '#!/bin/bash\nexit 1\n' > "$TMPDIR_TEST/bin/python3"
    chmod +x "$TMPDIR_TEST/bin/python3"
    printf '#!/bin/bash\necho "$@" > "$TMPDIR_TEST/zenity-args"\nexit 0\n' > "$TMPDIR_TEST/bin/zenity"
    chmod +x "$TMPDIR_TEST/bin/zenity"
    run env PATH="$TMPDIR_TEST/bin:/usr/bin:/bin" LSL_PROGRESS_GTK="$TMPDIR_TEST/missing.py" \
        LSL_DIALOG_LOG="$TMPDIR_TEST/dialog.log" \
        bash misc/lsl-firstboot-reboot.sh --flag-dir "$TMPDIR_TEST/flags"
    [ "$status" -eq 0 ]
    grep -q -- "Reboot now" "$TMPDIR_TEST/zenity-args"
    grep -q -- "Reboot later" "$TMPDIR_TEST/zenity-args"
    if grep -q -- "--timeout" "$TMPDIR_TEST/zenity-args"; then false; fi
    [ -e "$TMPDIR_TEST/flags/reboot-now" ]
    [ ! -e "$TMPDIR_TEST/flags/reboot-cancel" ]
    rm -f "$TMPDIR_TEST/flags/reboot-now"
    printf '#!/bin/bash\nexit 1\n' > "$TMPDIR_TEST/bin/zenity"
    chmod +x "$TMPDIR_TEST/bin/zenity"
    run env PATH="$TMPDIR_TEST/bin:/usr/bin:/bin" LSL_PROGRESS_GTK="$TMPDIR_TEST/missing.py" \
        LSL_DIALOG_LOG="$TMPDIR_TEST/dialog.log" \
        bash misc/lsl-firstboot-reboot.sh --flag-dir "$TMPDIR_TEST/flags"
    [ "$status" -eq 0 ]
    [ -e "$TMPDIR_TEST/flags/reboot-cancel" ]
    [ ! -e "$TMPDIR_TEST/flags/reboot-now" ]
}

@test "lsl-firstboot-reboot: zenity dismissal defers reboot (no timer, never auto-reboots)" {
    mkdir -p "$TMPDIR_TEST/bin" "$TMPDIR_TEST/flags"
    printf '#!/bin/bash\nexit 1\n' > "$TMPDIR_TEST/bin/python3"
    printf '#!/bin/bash\nexit 5\n' > "$TMPDIR_TEST/bin/zenity"
    chmod +x "$TMPDIR_TEST/bin"/*
    run env PATH="$TMPDIR_TEST/bin:/usr/bin:/bin" LSL_PROGRESS_GTK="$TMPDIR_TEST/missing.py" \
        LSL_DIALOG_LOG="$TMPDIR_TEST/dialog.log" \
        bash misc/lsl-firstboot-reboot.sh --flag-dir "$TMPDIR_TEST/flags"
    [ "$status" -eq 0 ]
    [ ! -e "$TMPDIR_TEST/flags/reboot-now" ]
    [ -e "$TMPDIR_TEST/flags/reboot-cancel" ]
}

@test "lsl-progress-gtk: reboot-countdown mode compiles and parses args" {
    command -v python3 >/dev/null 2>&1 || skip "python3 not available"
    python3 -m py_compile misc/lsl-progress-gtk.py
    run python3 -c "import importlib.util; s=importlib.util.spec_from_file_location('lpg','misc/lsl-progress-gtk.py'); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); print(m.parse_args(['--reboot-countdown','321','--flag-dir','/tmp/x']))"
    [ "$status" -eq 0 ]
    [[ "$output" == *"'reboot'"* ]]
    [[ "$output" == *"321"* ]]
    [[ "$output" == *"/tmp/x"* ]]
}

@test "lsl-progress-gtk: task order includes the home backup step" {
    command -v python3 >/dev/null 2>&1 || skip "python3 not available"
    run python3 -c "import importlib.util; s=importlib.util.spec_from_file_location('lpg','misc/lsl-progress-gtk.py'); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); print([t for t,_ in m.TASK_ORDER])"
    [ "$status" -eq 0 ]
    [[ "$output" == *"'home'"* ]]
}

@test "z0 layer ships the reboot dialog + gtk fallback" {
    grep -q "lsl-firstboot-reboot.sh" build.sh
    grep -q "lsl-firstboot-reboot.sh" misc/build-z0.sh
    grep -q "usr/local/bin/lsl-firstboot-reboot.sh" build.sh
    grep -q "lsl-progress-gtk.py" build.sh
}

# --- notify_desktop_now: session display for the failure dialog ----------
# The dialog must target the REAL graphical session (loginctl), never a
# hardcoded DISPLAY=:0 and never /dev/console ownership (root-owned on
# systemd, so that test silently never fired). Stub loginctl + su and
# assert what the notifier would execute.
notify_loginctl_stub() {
    # $1 = session type (x11|wayland|none), $2 = user, $3 = display
    local type="$1" user="$2" disp="$3"
    cat > "$MOCKS/loginctl" <<EOF
#!/bin/bash
if [ "\$1" = "list-sessions" ]; then
    [ "$type" = none ] || echo "3 $user tty7"
elif [ "\$3" = "Type" ]; then echo "$type";
elif [ "\$3" = "Name" ]; then echo "$user";
elif [ "\$3" = "Display" ]; then echo "$disp"; fi
EOF
    chmod +x "$MOCKS/loginctl"
}

@test "notify_desktop_now: uses the session display, not hardcoded :0" {
    MOCKS="$TMPDIR_TEST/bin"
    mkdir -p "$MOCKS"
    notify_loginctl_stub x11 mint ":1"
    printf '#!/bin/bash\necho "$@" >> "%s/su.log"\n' "$TMPDIR_TEST" > "$MOCKS/su"
    printf '#!/bin/bash\necho "mint:x:1000:1000::/home/mint:/bin/bash"\n' > "$MOCKS/getent"
    chmod +x "$MOCKS"/*
    run env PATH="$MOCKS:$PATH" bash -c 'eval "$(sed -n "/^notify_desktop_now()/",/^}/p misc/lsl-firstboot.sh)"; notify_desktop_now'
    [ "$status" -eq 0 ]
    grep -q "DISPLAY=':1'" "$TMPDIR_TEST/su.log"
    grep -q "XAUTHORITY='/home/mint/.Xauthority'" "$TMPDIR_TEST/su.log"
    grep -q "lsl-firstboot-failed.sh" "$TMPDIR_TEST/su.log"
}

@test "notify_desktop_now: wayland gets socket vars and an emptied DISPLAY" {
    MOCKS="$TMPDIR_TEST/bin"
    mkdir -p "$MOCKS"
    notify_loginctl_stub wayland mint ""
    printf '#!/bin/bash\necho "$@" >> "%s/su.log"\n' "$TMPDIR_TEST" > "$MOCKS/su"
    printf '#!/bin/bash\necho "mint:x:1000:1000::/home/mint:/bin/bash"\n' > "$MOCKS/getent"
    chmod +x "$MOCKS"/*
    run env PATH="$MOCKS:$PATH" bash -c 'eval "$(sed -n "/^notify_desktop_now()/",/^}/p misc/lsl-firstboot.sh)"; notify_desktop_now'
    [ "$status" -eq 0 ]
    grep -q "WAYLAND_DISPLAY='wayland-0'" "$TMPDIR_TEST/su.log"
    grep -q "DISPLAY= XDG" "$TMPDIR_TEST/su.log"
    if grep -q "DISPLAY=':0'" "$TMPDIR_TEST/su.log"; then
        echo "must not fall back to hardcoded :0 on wayland" >&2
        return 1
    fi
}

@test "notify_desktop_now: silent no-op with no graphical session" {
    MOCKS="$TMPDIR_TEST/bin"
    mkdir -p "$MOCKS"
    notify_loginctl_stub none "" ""
    printf '#!/bin/bash\necho CALLED >> "%s/su.log"\n' "$TMPDIR_TEST" > "$MOCKS/su"
    chmod +x "$MOCKS"/*
    run env PATH="$MOCKS:$PATH" bash -c 'eval "$(sed -n "/^notify_desktop_now()/",/^}/p misc/lsl-firstboot.sh)"; notify_desktop_now'
    [ "$status" -eq 0 ]
    [ ! -e "$TMPDIR_TEST/su.log" ]
}

# --- lsl-firstboot-progress: zenity dialog logic ---
@test "lsl-firstboot-progress: exits when already stamped" {
    export LSL_FIRSTBOOT_STAMP="$TMPDIR_TEST/stamp"
    export LSL_FIRSTBOOT_STATUS="$TMPDIR_TEST/status"
    touch "$LSL_FIRSTBOOT_STAMP"
    run bash misc/lsl-firstboot-progress.sh
    [ "$status" -eq 0 ]
}

@test "lsl-firstboot-progress: feeds zenity the phase until the stamp appears" {
    export LSL_FIRSTBOOT_STAMP="$TMPDIR_TEST/stamp"
    export LSL_FIRSTBOOT_STATUS="$TMPDIR_TEST/status"
    echo 'phase=installing packages and packing layer (first boot)...' > "$LSL_FIRSTBOOT_STATUS"
    mkdir -p "$TMPDIR_TEST/bin"
    cat > "$TMPDIR_TEST/bin/zenity" <<'EOF'
#!/bin/bash
head -n 3 > "$ZENITY_INPUT"
# Signal the stamp the progress script actually watches: it polls
# $LSL_FIRSTBOOT_STAMP (default /cdrom/casper/lsl-firstboot.done), never
# a bare $STAMP (unset here) - touching that hung the suite to the CI
# timeout with the stamp never appearing.
touch "$LSL_FIRSTBOOT_STAMP"
EOF
    chmod +x "$TMPDIR_TEST/bin/zenity"
    export PATH="$TMPDIR_TEST/bin:$PATH"
    export ZENITY_INPUT="$TMPDIR_TEST/zenity-input"
    export LSL_DIALOG_LOG="$TMPDIR_TEST/dialog.log"
    run bash misc/lsl-firstboot-progress.sh
    [ "$status" -eq 0 ]
    grep -q 'installing packages' "$ZENITY_INPUT"
    # The finished line pins dialog-error logging (the feature that ends
    # silent failures): backend + consumer status hit the log every run.
    grep -q 'finished via zenity' "$TMPDIR_TEST/dialog.log"
}

@test "lsl-firstboot-progress: no backend logs loudly instead of vanishing" {
    export LSL_FIRSTBOOT_STAMP="$TMPDIR_TEST/stamp"
    export LSL_FIRSTBOOT_STATUS="$TMPDIR_TEST/status"
    export LSL_DIALOG_LOG="$TMPDIR_TEST/dialog.log"
    echo 'phase=working...' > "$LSL_FIRSTBOOT_STATUS"
    mkdir -p "$TMPDIR_TEST/emptybin"
    export LSL_PROGRESS_GTK="$TMPDIR_TEST/no-such-gtk.py"
    # No zenity, no python3-gi path here: only the empty bin dir + system
    # paths (which lack zenity in CI) are visible.
    run env PATH="$TMPDIR_TEST/emptybin:/usr/bin:/bin" bash misc/lsl-firstboot-progress.sh
    [ "$status" -eq 0 ]
    grep -q 'no dialog backend' "$TMPDIR_TEST/dialog.log"
}

# --- uproot: --auto-append accepted (config-failure path needs a live system) ---
@test "uproot: --auto-append is accepted (no unknown-option error)" {
    run bash bin/uproot --auto-append
    [ "$status" -eq 1 ]
    [[ "$output" != *"Unknown option"* ]]
    [[ "$output" == *"root"* ]]   # proceeds to the root check
}

@test "uproot: append writes a flat filesystem_z<ts> layer that sorts above all of them" {
    # casper globs *.squashfs and stacks the matches lexically, so an append
    # only has to sort above everything already on the stick - no chain to
    # extend and no boot config to rewrite. This is the invariant that the old
    # dot-chain naming broke: five appends sat inert because no config named
    # them (see WHYFAIL14).
    CD="$TMPDIR_TEST/cdrom"
    mkdir -p "$CD/casper" "$CD/EFI/BOOT"
    touch "$CD/casper/filesystem.squashfs" "$CD/casper/filesystem_z0_firstboot.squashfs" \
          "$CD/casper/filesystem_z20260921085616.squashfs"
    printf 'kernel /vmlinuz boot=casper rootdelay=15 quiet\n' > "$CD/menu.lst"
    cp bin/uproot "$TMPDIR_TEST/uproot.sh"
    sed -i "s|/cdrom|$CD|g" "$TMPDIR_TEST/uproot.sh"
    eval "$(sed -n '/^write_append_layer()/,/^}/p' "$TMPDIR_TEST/uproot.sh")"
    eval "$(sed -n '/^repoint_layerfs_refs()/,/^}/p' "$TMPDIR_TEST/uproot.sh")"
    eval "$(sed -n '/^prune_superseded_layers()/,/^}/p' "$TMPDIR_TEST/uproot.sh")"
    eval "$(sed -n '/^latest_append_layer()/,/^}/p' "$TMPDIR_TEST/uproot.sh")"
    mkdir -p /tmp/squashfs/upper
    mksquashfs() { echo "$*" >> "$TMPDIR_TEST/mk.log"; }
    lsl_ensure_cdrom_space() { return 0; }
    lsl_cdrom_is_vfat() { return 1; }
    log() { :; }
    upper_bytes=123
    write_append_layer
    # a flat filesystem_z<14 digits>.squashfs - no dotted stem, no inheritance
    grep -qE "casper/filesystem_z[0-9]{14}\.squashfs" "$TMPDIR_TEST/mk.log"
    # and it must sort ABOVE the base, the stub and every existing append
    new="$(sed -n 's|.*/casper/\(filesystem_z[0-9]*\.squashfs\).*|\1|p' "$TMPDIR_TEST/mk.log" | head -n1)"
    [[ "$new" > "filesystem.squashfs" ]]
    [[ "$new" > "filesystem_z0_firstboot.squashfs" ]]
    [[ "$new" > "filesystem_z20260921085616.squashfs" ]]
}

@test "uproot: append reaps superseded appends but keeps base and stub" {
    # mksquashfs is stubbed, so it records the call without creating the file;
    # write_append_layer's fail-safe then removes it. That means the layer the
    # prune is handed does not exist on disk, and the fail-safe refuses to act
    # (covered separately below). To exercise the reaping itself, drive
    # prune_superseded_layers directly with a keeper that really is newest.
    CD="$TMPDIR_TEST/cdrom"
    mkdir -p "$CD/casper"
    touch "$CD/casper/filesystem.squashfs" "$CD/casper/filesystem_z0_firstboot.squashfs" \
          "$CD/casper/filesystem_z20260916164712.squashfs" \
          "$CD/casper/filesystem_z20260919045856.squashfs" \
          "$CD/casper/filesystem_z20260930120000.squashfs"
    cp bin/uproot "$TMPDIR_TEST/uproot.sh"
    sed -i "s|/cdrom|$CD|g" "$TMPDIR_TEST/uproot.sh"
    eval "$(sed -n '/^write_append_layer()/,/^}/p' "$TMPDIR_TEST/uproot.sh")"
    eval "$(sed -n '/^repoint_layerfs_refs()/,/^}/p' "$TMPDIR_TEST/uproot.sh")"
    eval "$(sed -n '/^prune_superseded_layers()/,/^}/p' "$TMPDIR_TEST/uproot.sh")"
    eval "$(sed -n '/^latest_append_layer()/,/^}/p' "$TMPDIR_TEST/uproot.sh")"
    log() { :; }
    STICK_DIR="$CD" prune_superseded_layers "$CD/casper/filesystem_z20260930120000.squashfs"
    # base and stub survive (the stub carries lsl-firstboot.service)
    [ -f "$CD/casper/filesystem.squashfs" ]
    [ -f "$CD/casper/filesystem_z0_firstboot.squashfs" ]
    # the two older appends are reaped, the newest survives
    [ ! -f "$CD/casper/filesystem_z20260916164712.squashfs" ]
    [ ! -f "$CD/casper/filesystem_z20260919045856.squashfs" ]
    [ -f "$CD/casper/filesystem_z20260930120000.squashfs" ]
}

@test "uproot: prune skips when the freshly written layer is absent" {
    # Fail-safe: if the new layer is not on disk, nothing defines "newest", so
    # the prune must not delete anything at all.
    CD="$TMPDIR_TEST/cdrom"
    mkdir -p "$CD/casper"
    touch "$CD/casper/filesystem.squashfs" "$CD/casper/filesystem_z0_firstboot.squashfs" \
          "$CD/casper/filesystem_z20260916164712.squashfs"
    cp bin/uproot "$TMPDIR_TEST/uproot.sh"
    sed -i "s|/cdrom|$CD|g" "$TMPDIR_TEST/uproot.sh"
    eval "$(sed -n '/^prune_superseded_layers()/,/^}/p' "$TMPDIR_TEST/uproot.sh")"
    eval "$(sed -n '/^latest_append_layer()/,/^}/p' "$TMPDIR_TEST/uproot.sh")"
    log() { :; }
    # a keeper that does not exist on disk
    run prune_superseded_layers "$CD/casper/filesystem_z20991231235959.squashfs"
    [ -f "$CD/casper/filesystem_z20260916164712.squashfs" ]
}

@test "uproot: prune refuses to act without a resolvable appended layer" {
    # Fail-safe: a prune that cannot name what to keep must delete nothing.
    CD="$TMPDIR_TEST/cdrom"
    mkdir -p "$CD/casper"
    touch "$CD/casper/filesystem.squashfs" "$CD/casper/filesystem_z0_firstboot.squashfs" \
          "$CD/casper/filesystem_z20260916164712.squashfs"
    cp bin/uproot "$TMPDIR_TEST/uproot.sh"
    sed -i "s|/cdrom|$CD|g" "$TMPDIR_TEST/uproot.sh"
    eval "$(sed -n '/^prune_superseded_layers()/,/^}/p' "$TMPDIR_TEST/uproot.sh")"
    eval "$(sed -n '/^latest_append_layer()/,/^}/p' "$TMPDIR_TEST/uproot.sh")"
    log() { :; }
    # a keeper that is not an append (e.g. the base) must be rejected outright
    run prune_superseded_layers "$CD/casper/filesystem.squashfs"
    [ -f "$CD/casper/filesystem_z20260916164712.squashfs" ]
}

@test "uproot: repoint_layerfs_refs strips a stale layerfs-path from every boot config" {
    # A stick written by an older installer still carries layerfs-path=, which
    # would now name a file that no longer exists - casper panics with "File
    # system layers are missing". So the shim's remaining job is to REMOVE it.
    CD="$TMPDIR_TEST/cdrom"
    mkdir -p "$CD/EFI/BOOT" "$CD/efi/grub"
    printf 'kernel /vmlinuz boot=casper layerfs-path=/cdrom/casper/filesystem.z0.squashfs quiet\n' > "$CD/menu.lst"
    printf 'linux /vmlinuz boot=casper layerfs-path=/cdrom/casper/filesystem.z0.squashfs quiet\n' > "$CD/EFI/BOOT/grub.cfg"
    printf 'kernel /vmlinuz boot=casper layerfs-path=/cdrom/casper/filesystem.z0.squashfs quiet\n' > "$CD/efi/grub/menu.lst"
    cp bin/uproot "$TMPDIR_TEST/uproot.sh"
    sed -i "s|/cdrom|$CD|g" "$TMPDIR_TEST/uproot.sh"
    eval "$(sed -n '/^repoint_layerfs_refs()/,/^}/p' "$TMPDIR_TEST/uproot.sh")"
    log() { :; }
    repoint_layerfs_refs "$CD/casper/filesystem_z20260930120000.squashfs"
    for f in "$CD/menu.lst" "$CD/EFI/BOOT/grub.cfg" "$CD/efi/grub/menu.lst"; do
        ! grep -q "layerfs-path=" "$f"
        # the rest of the kernel line must survive the strip
        grep -q "boot=casper" "$f"
    done
}

# --- build.sh: produces the bundle ---
@test "build.sh produces the bundle" {
    run bash build.sh
    [ "$status" -eq 0 ]
    [ -f dist/lsl-usb-win.zip ]
    [ -f dist/filesystem_z0_firstboot.squashfs ]
}

# --- onboot.sh: nix-users membership, zram, fstab merge ---------------------
@test "onboot: nix-users membership adds the desktop user" {
    eval "$(sed -n '/^lsl_ensure_nix_users_group_membership()/,/^}/p' onboot.sh)"
    lsl_desktop_user() { echo "zorin"; }
    getent() { case "$1" in group) return 0 ;; *) return 1 ;; esac; }  # nix-users exists
    groupadd() { echo "groupadd called" >&2; }
    id() { return 0; }   # user exists
    usermod() { echo "$*" > "$TMPDIR_TEST/usermod.log"; }
    run lsl_ensure_nix_users_group_membership
    [ "$status" -eq 0 ]
    grep -q "zorin" "$TMPDIR_TEST/usermod.log"
}

@test "onboot: nix-users membership fails when the user is absent" {
    eval "$(sed -n '/^lsl_ensure_nix_users_group_membership()/,/^}/p' onboot.sh)"
    lsl_desktop_user() { echo "nobody"; }
    getent() { return 1; }   # no nix-users group -> groupadd
    groupadd() { return 0; }
    id() { return 1; }       # user absent
    usermod() { echo "usermod called" >&2; }
    run lsl_ensure_nix_users_group_membership
    [ "$status" -eq 1 ]
}

@test "onboot: zram disabled with LSL_ZRAM_MIB=0" {
    eval "$(sed -n '/^lsl_setup_zram()/,/^}/p' onboot.sh)"
    modprobe() { echo "modprobe $*" > "$TMPDIR_TEST/modprobe.log"; }
    swapon() { echo "swapon $*" >> "$TMPDIR_TEST/swapon.log"; }
    LSL_ZRAM_MIB=0
    run lsl_setup_zram
    [ "$status" -eq 0 ]
    grep -q "zram" "$TMPDIR_TEST/modprobe.log"
    grep -q -- "--show" "$TMPDIR_TEST/swapon.log"
}

@test "onboot: zram sizes from LSL_ZRAM_MIB and asks zramctl" {
    eval "$(sed -n '/^lsl_setup_zram()/,/^}/p' onboot.sh)"
    modprobe() { :; }
    swapon() { :; }
    zramctl() { echo "/dev/zram0"; }
    LSL_ZRAM_MIB=512
    run lsl_setup_zram
    [ "$status" -eq 0 ]
}

@test "onboot: lsl_merge_fstab preserves user lines and writes the block" {
    FSTAB="$TMPDIR_TEST/fstab"
    printf 'user-line\n# BEGIN lsl-usb fstab\nold\n# END lsl-usb fstab\n' > "$FSTAB"
    eval "$(python3 tests/extract_fn.py onboot.sh lsl_merge_fstab | sed "s|local fstab=/etc/fstab|local fstab=\"$FSTAB\"|")"
    mountpoint() { case "$2" in /cdrom|/mnt/c) return 0 ;; *) return 1 ;; esac; }
    findmnt() {
        local o="" mnt=""
        while [ $# -gt 0 ]; do
            case "$1" in -n) ;; -o) o="$2"; shift ;; *) mnt="$1" ;; esac
            shift
        done
        case "$mnt:$o" in
            /cdrom:SOURCE) echo "/dev/sdb1" ;;
            /cdrom:FSTYPE) echo "vfat" ;;
            /mnt/c:SOURCE) echo "/dev/nvme0n1p3" ;;
            /mnt/c:FSTYPE) echo "ntfs3" ;;
        esac
    }
    blkid() { echo "UUID=ABCD-1234"; }
    run lsl_merge_fstab
    [ "$status" -eq 0 ]
    grep -q '^user-line$' "$FSTAB"
    grep -q '^# BEGIN lsl-usb fstab$' "$FSTAB"
    grep -q 'UUID=ABCD-1234 /cdrom vfat defaults,ro,nofail 0 0' "$FSTAB"
    grep -q 'UUID=ABCD-1234 /mnt/c ntfs3 defaults,nofail 0 0' "$FSTAB"
    ! grep -q '^old$' "$FSTAB"
}

# --- bin/lsl: parse_wsl_report ---------------------------------------------
@test "lsl: parse_wsl_report parses registry rootfs and vhdx entries" {
    . bin/lsl-common.sh
    eval "$(python3 tests/extract_fn.py bin/lsl parse_wsl_report)"
    ensure_wsl_report() { :; }
    lsl_vhdx_saved_distro_lines() { :; }
    WSL_REPORT="$TMPDIR_TEST/wsl-report"
    cat > "$WSL_REPORT" <<'EOF'
WSL Registry name: Ubuntu
WSL Registry rootfs: /mnt/d/WSL/Ubuntu2404/rootfs
---
WSL Distro vhdx: /mnt/d/WSL/Ubuntu2404/ext4.vhdx
---
EOF
    run parse_wsl_report
    [ "$status" -eq 0 ]
    [[ "$output" == *"Ubuntu2404||/mnt/d/WSL/Ubuntu2404/rootfs"* ]]
    [[ "$output" == *"ext4.vhdx|/mnt/d/WSL/Ubuntu2404/ext4.vhdx|"* ]]
}

@test "lsl: parse_wsl_report dedupes identical entries" {
    . bin/lsl-common.sh
    eval "$(python3 tests/extract_fn.py bin/lsl parse_wsl_report)"
    ensure_wsl_report() { :; }
    lsl_vhdx_saved_distro_lines() { :; }
    WSL_REPORT="$TMPDIR_TEST/wsl-report"
    printf 'WSL Distro vhdx: /mnt/d/WSL/Ubuntu2404/ext4.vhdx\n---\nWSL Distro vhdx: /mnt/d/WSL/Ubuntu2404/ext4.vhdx\n---\n' > "$WSL_REPORT"
    run parse_wsl_report
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | grep -c 'ext4.vhdx')" -eq 1 ]
}

# --- bin/mount_all.sh: parse_drive -----------------------------------------
@test "mount_all: parse_drive resolves the disk GUID and mounts" {
    eval "$(sed -n '/^reverse_bytes()/,/^}/p' bin/mount_all.sh)"
    eval "$(sed -n '/^hex_to_uuid()/,/^}/p' bin/mount_all.sh)"
    eval "$(sed -n '/^dev_for_uuid()/,/^}/p' bin/mount_all.sh)"
    eval "$(sed -n '/^parse_drive()/,/^}/p' bin/mount_all.sh)"
    # 32-byte DMIO:ID: value = disk GUID (32 hex) + partition GUID (32 hex).
    # The partition GUID bytes below reverse to PARTUUID 04030201-0605-0807-
    # 090a-0b0c0d0e0f10, which the mock lsblk reports for nvme0n1p3.
    INPUT='"\\DosDevices\\C:"=hex(3):44,4d,49,4f,3a,49,44,3a,11,12,13,14,15,16,17,18,19,1a,1b,1c,1d,1e,1f,20,01,02,03,04,05,06,07,08,09,0a,0b,0c,0d,0e,0f,10'
    lsblk() { echo "nvme0n1p3 04030201-0605-0807-090a-0b0c0d0e0f10"; }
    mount() { echo "mount $*" > "$TMPDIR_TEST/mount.log"; }
    # Mount at a path that does not exist yet: parse_drive skips already-
    # mounted targets, and /mnt/c IS mounted under WSL (host C: drive).
    MNT="$TMPDIR_TEST/mnt-c"
    run parse_drive "C" "$MNT"
    [ "$status" -eq 0 ]
    # The disk GUID resolved to /dev/nvme0n1p3 and was mounted at $MNT.
    grep -q "mount /dev/nvme0n1p3 -t ntfs3 $MNT" "$TMPDIR_TEST/mount.log"
}

@test "mount_all: parse_drive skips unknown drive letters" {
    eval "$(sed -n '/^reverse_bytes()/,/^}/p' bin/mount_all.sh)"
    eval "$(sed -n '/^hex_to_uuid()/,/^}/p' bin/mount_all.sh)"
    eval "$(sed -n '/^dev_for_uuid()/,/^}/p' bin/mount_all.sh)"
    eval "$(sed -n '/^parse_drive()/,/^}/p' bin/mount_all.sh)"
    # 32-byte DMIO:IDdisk GUID + partition GUID); only the partition
    # GUID matters and the test replaces the drive letter with "Z", which is
    # absent, so parse_drive must fall through and return 1.
    INPUT='"\\DosDevices\\C:"=hex(3):44,4d,49,4f,3a,49,44,3a,11,12,13,14,15,16,17,18,19,1a,1b,1c,1d,1e,1f,20,01,02,03,04,05,06,07,08,09,0a,0b,0c,0d,0e,0f,10'
    run parse_drive "Z" "/mnt/z"
    [ "$status" -eq 1 ]
}

# --- bin/persist-wifi.sh: cdrom_is_ro + collect_current_wifi_line ----------
@test "persist-wifi: cdrom_is_ro detects ro vs rw" {
    eval "$(sed -n '/^cdrom_is_ro()/,/^}/p' bin/persist-wifi.sh)"
    findmnt() { echo "rw,relatime"; }
    run cdrom_is_ro
    [ "$status" -eq 1 ]
    findmnt() { echo "ro,relatime"; }
    run cdrom_is_ro
    [ "$status" -eq 0 ]
}

@test "persist-wifi: collect_current_wifi_line quotes SSID and PSK" {
    eval "$(sed -n '/^collect_current_wifi_line()/,/^}/p' bin/persist-wifi.sh)"
    command() { case "$1" in -v) return 0 ;; *) return 1 ;; esac; }
    nmcli() {
        case "$1" in
            -t) echo "wlan0:wifi:connected" ;;
            -g) case "$2" in
                    GENERAL.CONNECTION) echo "HomeNet" ;;
                    802-11-wireless.ssid) echo "HomeNet" ;;
                esac ;;
            -s) echo "secret123" ;;
        esac
    }
    run collect_current_wifi_line
    [ "$status" -eq 0 ]
    [ "$output" = "nmcli device wifi connect HomeNet password secret123" ]
}

@test "persist-wifi: open network gets no password argument" {
    eval "$(sed -n '/^collect_current_wifi_line()/,/^}/p' bin/persist-wifi.sh)"
    command() { case "$1" in -v) return 0 ;; *) return 1 ;; esac; }
    nmcli() {
        case "$1" in
            -t) echo "wlan0:wifi:connected" ;;
            -g) echo "CafeNet" ;;
            -s) echo "" ;;
        esac
    }
    run collect_current_wifi_line
    [ "$status" -eq 0 ]
    [ "$output" = "nmcli device wifi connect CafeNet" ]
}

# --- install.sh: wifi.sh generation -----------------------------------------
@test "install.sh: writes wifi.sh with SSID and password" {
    REPO="$TMPDIR_TEST/repo"
    CD="$TMPDIR_TEST/cdrom"
    MOCKS="$TMPDIR_TEST/bin"
    mkdir -p "$REPO/bin" "$CD/casper" "$MOCKS"
    cp install.sh "$REPO/install.sh"
    sed -i "s|/cdrom|$CD|g" "$REPO/install.sh"
    printf '#!/bin/bash\nexit 0\n' > "$REPO/bin/config.sh"
    printf '#!/bin/bash\nexit 0\n' > "$REPO/bin/mount_all.sh"
    printf '#!/bin/bash\nexit 0\n' > "$REPO/bin/squashfs_config.sh"
    chmod +x "$REPO/bin"/*
    printf '#!/bin/bash\ntrue\n' > "$MOCKS/mount"
    printf '#!/bin/bash\ntouch "$2"\n' > "$MOCKS/mksquashfs"
    printf '#!/bin/bash\ncase "$1" in -t) echo "yes:HomeNet" ;; -s) echo "secret123" ;; esac\n' > "$MOCKS/nmcli"
    printf '#!/bin/bash\ntrue\n' > "$MOCKS/chroot"
    printf '#!/bin/bash\ntrue\n' > "$MOCKS/find"
    printf '#!/bin/bash\ntrue\n' > "$MOCKS/zstd"
    printf '#!/bin/bash\ntrue\n' > "$MOCKS/mv"
    chmod +x "$MOCKS"/*
    run env PATH="$MOCKS:$PATH" /bin/bash "$REPO/install.sh"
    [ "$status" -eq 0 ]
    grep -q "nmcli device wifi connect HomeNet password secret123" "$CD/wifi.sh"
}

@test "install.sh: no active wifi -> no wifi.sh" {
    REPO="$TMPDIR_TEST/repo"
    CD="$TMPDIR_TEST/cdrom"
    MOCKS="$TMPDIR_TEST/bin"
    mkdir -p "$REPO/bin" "$CD/casper" "$MOCKS"
    cp install.sh "$REPO/install.sh"
    sed -i "s|/cdrom|$CD|g" "$REPO/install.sh"
    printf '#!/bin/bash\nexit 0\n' > "$REPO/bin/config.sh"
    printf '#!/bin/bash\nexit 0\n' > "$REPO/bin/mount_all.sh"
    printf '#!/bin/bash\nexit 0\n' > "$REPO/bin/squashfs_config.sh"
    chmod +x "$REPO/bin"/*
    printf '#!/bin/bash\ntrue\n' > "$MOCKS/mount"
    printf '#!/bin/bash\ntouch "$2"\n' > "$MOCKS/mksquashfs"
    printf '#!/bin/bash\ncase "$1" in -t) echo "no:OtherNet" ;; esac\n' > "$MOCKS/nmcli"
    printf '#!/bin/bash\ntrue\n' > "$MOCKS/chroot"
    printf '#!/bin/bash\ntrue\n' > "$MOCKS/find"
    printf '#!/bin/bash\ntrue\n' > "$MOCKS/zstd"
    printf '#!/bin/bash\ntrue\n' > "$MOCKS/mv"
    chmod +x "$MOCKS"/*
    run env PATH="$MOCKS:$PATH" /bin/bash "$REPO/install.sh"
    [ "$status" -eq 0 ]
    [ ! -f "$CD/wifi.sh" ]
}

# --- bin/config.sh: sync + systemd install ----------------------------------
@test "config.sh: syncs scripts to the USB" {
    CD="$TMPDIR_TEST/cdrom"
    MOCKS="$TMPDIR_TEST/bin"
    mkdir -p "$CD" "$MOCKS"
    printf '#!/bin/bash\ntrue\n' > "$MOCKS/mount"
    printf '#!/bin/bash\ntrue\n' > "$MOCKS/systemctl"
    printf '#!/bin/bash\ntrue\n' > "$MOCKS/chroot"
    # persist-wifi.sh re-execs itself via sudo when not root; in the test we are
    # unprivileged, so provide a no-op sudo (the call is `|| true` anyway).
    printf '#!/bin/bash\ntrue\n' > "$MOCKS/sudo"
    # Force the desktop user to a nonexistent account so the Desktop/autostart
    # installers early-return (they would otherwise try to chown /home/<real user>).
    printf '#!/bin/bash\ncase "$1" in passwd) echo "fakeuser:x:1000:1000::/home/fakeuser:/bin/bash" ;; *) exit 1 ;; esac\n' > "$MOCKS/getent"
    # Report /cdrom as NOT mounted so persist-wifi.sh bails before it can try to
    # re-exec sudo (which would hang waiting for a password in this sandbox).
    printf '#!/bin/bash\nexit 1\n' > "$MOCKS/mountpoint"
    chmod +x "$MOCKS"/*
    run env PATH="$MOCKS:$PATH" LSL_CDROM="$CD" /bin/bash bin/config.sh --sync-only
    [ "$status" -eq 0 ]
    [ -f "$CD/onboot.sh" ]
    [ -f "$CD/bin/uproot" ]
    [ -f "$CD/lsl-usb.env" ]
}

@test "config.sh: installs systemd units into the chroot" {
    CD="$TMPDIR_TEST/cdrom"
    ROOT="$TMPDIR_TEST/root"
    MOCKS="$TMPDIR_TEST/bin"
    mkdir -p "$CD" "$ROOT" "$MOCKS"
    printf '#!/bin/bash\ntrue\n' > "$MOCKS/mount"
    printf '#!/bin/bash\necho "systemctl $*" >> "$SYSTEMCTL_LOG"\n' > "$MOCKS/systemctl"
    printf '#!/bin/bash\nshift; exec "$@"\n' > "$MOCKS/chroot"
    chmod +x "$MOCKS"/*
    run env PATH="$MOCKS:$PATH" LSL_CDROM="$CD" LSL_CONFIG_ROOT="$ROOT" \
        SYSTEMCTL_LOG="$TMPDIR_TEST/systemctl.log" /bin/bash bin/config.sh --systemd-only
    [ "$status" -eq 0 ]
    [ -f "$ROOT/etc/systemd/system/onboot.service" ]
    grep -q "enable onboot.service" "$TMPDIR_TEST/systemctl.log"
}

# --- bin/lsl-btrfs-growd: grow + loop refresh -------------------------------
# try_grow() calls the shared lsl_refresh_image_loops() from bin/lsl-common.sh,
# so both must be spliced in or the call is a bare "command not found".
load_growd_funcs() {
    eval "$(sed -n '/^free_pct()/,/^}/p' bin/lsl-btrfs-growd)"
    eval "$(sed -n '/^try_grow()/,/^}/p' bin/lsl-btrfs-growd)"
    eval "$(sed -n '/^lsl_refresh_image_loops()/,/^}/p' bin/lsl-common.sh)"
}

# Standard losetup mock for these tests.
#
# The shared lsl_refresh_image_loops resolves devices with `losetup -j <img>` and
# then calls `losetup -c <dev>` on each, skipping any that fails `[ -b ]`.
# Two traps, both of which make this test fail for a reason unrelated to growd:
#
#   1. A mock implementing only `-c` makes the helper find NOTHING to refresh,
#      so the expected `losetup -c` line is simply absent. `-j` must answer in
#      real losetup's backing-file form.
#   2. `[ -b "$dev" ]` uses the shell BUILTIN, which a shell function named
#      `test` cannot shadow - the pre-existing `test() {...}` override in some
#      of these tests does nothing for `-b`. The device must therefore be a REAL
#      block device; /dev/loop0 is one on any host that can run these tests
#      (and the whole file already assumes a Linux block-device environment).
#
# The device is passed via a global (LSL_MOCK_LOOP), not a closure variable:
# bats runs `run` in a subshell, and a closure defined in a helper function does
# not survive into it.
mock_losetup() {
    LSL_MOCK_LOOP="$1"
    losetup() {
        case "$1" in
            -j) [ -n "$LSL_MOCK_LOOP" ] && \
                    printf '%s: [2049]:12345 (%s)\n' "$LSL_MOCK_LOOP" "$IMG" ;;
            -c) echo "losetup -c $2" >> "$TMPDIR_TEST/losetup.log" ;;
            *)  return 0 ;;
        esac
    }
}

@test "lsl-btrfs-growd: grows the image and refreshes the loop device" {
    load_growd_funcs
    IMG="$TMPDIR_TEST/home.btrfs"
    touch "$IMG"
    MIN_PCT=10
    CHUNK_MIB=1024
    mountpoint() { case "$2" in /home) return 0 ;; *) return 1 ;; esac; }
    df() { echo "Filesystem 1K-blocks Used Available Use% Mounted on"; echo "/dev/loop0 1048576 950000 48576 95% /home"; }
    btrfs() { echo "btrfs $*" >> "$TMPDIR_TEST/btrfs.log"; }
    truncate() { echo "truncate $*" >> "$TMPDIR_TEST/truncate.log"; }
    mock_losetup /dev/loop0
    # findmnt now supplies the loop device (the script prefers it over losetup -j).
    findmnt() { echo "/dev/loop0"; }
    # No `test` override needed: `[ -b /dev/loop0 ]` uses the shell builtin, which
    # a shell function cannot shadow - the device is real instead.
    run try_grow /home "$IMG" home
    [ "$status" -eq 0 ]
    grep -q "truncate -s +1024M" "$TMPDIR_TEST/truncate.log"
    grep -q "losetup -c /dev/loop0" "$TMPDIR_TEST/losetup.log"
    grep -q "resize max" "$TMPDIR_TEST/btrfs.log"
}

@test "lsl-btrfs-growd: discovers the loop via losetup -j when findmnt shows no loop" {
    load_growd_funcs
    IMG="$TMPDIR_TEST/home.btrfs"
    touch "$IMG"
    MIN_PCT=10
    CHUNK_MIB=1024
    mountpoint() { return 0; }
    df() { echo "Filesystem 1K-blocks Used Available Use% Mounted on"; echo "/dev/loop0 1048576 950000 48576 95% /home"; }
    btrfs() { echo "btrfs $*" >> "$TMPDIR_TEST/btrfs.log"; }
    truncate() { :; }
    # Old findmnt (or another mount stacked above): no loop line at all.
    findmnt() { case "$*" in *TARGET*) printf '/lower\n' ;; *) printf 'overlay\n' ;; esac; }
    # ... so the image path (canonicalized) is the only lead.
    mock_losetup /dev/loop0
    run try_grow /home "$IMG" home
    [ "$status" -eq 0 ]
    grep -q "losetup -c /dev/loop0" "$TMPDIR_TEST/losetup.log"
    grep -q "resize max /lower" "$TMPDIR_TEST/btrfs.log"
}

@test "lsl-btrfs-growd: resizes the underlying fs mount, not a stacked overlay" {
    load_growd_funcs
    IMG="$TMPDIR_TEST/home.btrfs"
    touch "$IMG"
    MIN_PCT=10
    CHUNK_MIB=1024
    mountpoint() { return 0; }
    df() { echo "Filesystem 1K-blocks Used Available Use% Mounted on"; echo "/dev/loop0 1048576 950000 48576 95% /home"; }
    btrfs() { echo "btrfs $*" >> "$TMPDIR_TEST/btrfs.log"; }
    truncate() { :; }
    # findmnt lists every mount stacked on the path (verified live:
    # loop line first, overlay second) - plus the loop's own mountpoint.
    findmnt() { case "$*" in *TARGET*) printf '/lower\n' ;; *) printf '/dev/loop0\noverlay\n' ;; esac; }
    mock_losetup /dev/loop0
    run try_grow /home "$IMG" home
    [ "$status" -eq 0 ]
    grep -q "losetup -c /dev/loop0" "$TMPDIR_TEST/losetup.log"
    # The resize must name the lower fs mount: `resize max /home` would hit
    # the overlay and silently do nothing while the btrfs stays full.
    grep -q "resize max /lower" "$TMPDIR_TEST/btrfs.log"
    ! grep -q "resize max /home" "$TMPDIR_TEST/btrfs.log"
}

# --- bin/uphome / lsl-flush-home.sh / lsl-home-flushd -----------------------
@test "uphome: HDD mode syncs btrfs" {
    btrfs() { echo "btrfs $*" >> "$TMPDIR_TEST/btrfs.log"; }
    # Function mocks do not cross into `bash bin/uphome` unless exported.
    export -f btrfs
    # persist-wifi.sh re-execs via `exec sudo`, which bypasses function
    # mocks; a real sudo would hang waiting for a password in sandboxes
    # without passwordless sudo (WSL). Intercept it with a fake binary on
    # PATH (the test runs in a subshell, so the export is test-scoped).
    mkdir -p "$TMPDIR_TEST/bin"
    printf '#!/bin/bash\nexit 0\n' > "$TMPDIR_TEST/bin/sudo"
    chmod +x "$TMPDIR_TEST/bin/sudo"
    export PATH="$TMPDIR_TEST/bin:$PATH"
    run env LSL_DATA_DIR=/mnt/c/Users/lsl-usb bash bin/uphome
    [ "$status" -eq 0 ]
    grep -q "sync /home" "$TMPDIR_TEST/btrfs.log"
}

@test "lsl-flush-home: refuses in HDD mode" {
    run env LSL_DATA_DIR=/mnt/c/Users/lsl-usb bash bin/lsl-flush-home.sh
    [ "$status" -eq 1 ]
    [[ "$output" == *"not USB mode"* ]]
}

@test "lsl-flush-home: flushes home to home.sfs" {
    CD="$TMPDIR_TEST/cdrom"
    mkdir -p "$CD"
    # The script sources lsl-common.sh SCRIPT_DIR-relative, and both files
    # hardcode /cdrom (paths, df volume, usb-mode match) - rewrite the pair
    # to the scratch dir and point LSL_DATA_DIR inside it too.
    cp bin/lsl-flush-home.sh bin/lsl-common.sh "$TMPDIR_TEST/"
    sed -i "s|/cdrom|$CD|g" "$TMPDIR_TEST/lsl-flush-home.sh" "$TMPDIR_TEST/lsl-common.sh"
    mv "$TMPDIR_TEST/lsl-flush-home.sh" "$TMPDIR_TEST/flush.sh"
    # Function mocks only affect the child bash when exported.
    mountpoint() { return 0; }
    mount() { :; }
    umount() { :; }
    mksquashfs() { touch "$2"; }
    find() { :; }
    export -f mountpoint mount umount mksquashfs find
    # Overlay work dirs default to /run (unwritable for non-root CI) -
    # point them at scratch too.
    mkdir -p "$TMPDIR_TEST/lower" "$TMPDIR_TEST/upper" "$TMPDIR_TEST/work"
    run env LSL_DATA_DIR="$CD/lsl-data" LSL_DISTRO_KEY=test LSL_HOME_LOWER="$TMPDIR_TEST/lower" LSL_HOME_UPPER="$TMPDIR_TEST/upper" LSL_HOME_WORK="$TMPDIR_TEST/work" bash "$TMPDIR_TEST/flush.sh"
    # Print captured output on failure: bats otherwise shows only the assert
    # line, which cannot diagnose container-only failures like this one.
    # (Single %s format: a leading --- in the format trips bash printf
    # option parsing.)
    if [ "$status" -ne 0 ]; then printf '%s\n' "--- flush.sh output:" "$output" "--- end"; fi
    [ "$status" -eq 0 ]
    [ -f "$CD/home-test.sfs" ]
}

@test "lsl-flush-home: skips a RAM (tmpfs) home" {
    # Boot-to-RAM, no persistence: /home is a tmpfs, so there is nothing to
    # flush - the guard must exit 0 before the /cdrom checks.
    findmnt() { echo tmpfs; }
    export -f findmnt
    run env LSL_DATA_DIR=/mnt/c/Users/lsl-usb bash bin/lsl-flush-home.sh
    [ "$status" -eq 0 ]
    [[ "$output" == *"RAM (tmpfs)"* ]]
}

@test "lsl-home-flushd: latest_upper_mtime returns 0 for an empty upper" {
    eval "$(sed -n '/^latest_upper_mtime()/,/^}/p' bin/lsl-home-flushd)"
    UPPER="$TMPDIR_TEST/empty-upper"
    mkdir -p "$UPPER"
    run latest_upper_mtime
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

# --- bin/lsl: pure-logic helpers -------------------------------------------
@test "lsl: normalize_catalog_vhdx_path converts Windows paths" {
    eval "$(sed -n '/^lsl_normalize_catalog_vhdx_path()/,/^}/p' bin/lsl)"
    run lsl_normalize_catalog_vhdx_path 'D:\WSL\Ubuntu2404\ext4.vhdx'
    [ "$status" -eq 0 ]
    [ "$output" = "/mnt/d/WSL/Ubuntu2404/ext4.vhdx" ]
    run lsl_normalize_catalog_vhdx_path '/mnt/c/foo.vhdx'
    [ "$output" = "/mnt/c/foo.vhdx" ]
    run lsl_normalize_catalog_vhdx_path 'garbage'
    [ "$status" -eq 1 ]
}

@test "lsl: vhdx_mount_dir_name is letter-tagged and stable" {
    eval "$(sed -n '/^lsl_vhdx_mount_dir_name()/,/^}/p' bin/lsl)"
    LSL_CHOOSE_LETTER="a"
    run lsl_vhdx_mount_dir_name "/mnt/d/WSL/Ubuntu2404/ext4.vhdx"
    [ "$output" = "ext4_a" ]
    unset LSL_CHOOSE_LETTER
    run lsl_vhdx_mount_dir_name "/mnt/d/WSL/Ubuntu2404/ext4.vhdx"
    [[ "$output" == ext4_* ]]
}

@test "lsl: maybe_link_mount_aliases links letter and hash dirs" {
    eval "$(sed -n '/^lsl_vhdx_mount_dir_name()/,/^}/p' bin/lsl)"
    eval "$(sed -n '/^lsl_maybe_link_mount_aliases()/,/^}/p' bin/lsl)"
    LSL_MOUNT_BASE="$TMPDIR_TEST/mounts"
    mkdir -p "$LSL_MOUNT_BASE/ext4_a"
    LSL_CHOOSE_LETTER="a"
    run lsl_maybe_link_mount_aliases "/mnt/d/WSL/Ubuntu2404/ext4.vhdx" "$LSL_MOUNT_BASE/ext4_a"
    [ "$status" -eq 0 ]
    hash="$(printf '%s' "/mnt/d/WSL/Ubuntu2404/ext4.vhdx" | md5sum | cut -c1-8)"
    [ -L "$LSL_MOUNT_BASE/ext4_$hash" ]
}

# --- bin/safe_ntfsfix.sh: safety checks -------------------------------------
@test "safe_ntfsfix: aborts on BitLocker" {
    MOCKS="$TMPDIR_TEST/bin"
    mkdir -p "$MOCKS"
    printf '#!/bin/bash\nexit 1\n' > "$MOCKS/findmnt"
    printf '#!/bin/bash\necho BitLocker\n' > "$MOCKS/blkid"
    printf '#!/bin/bash\ntrue\n' > "$MOCKS/dmesg"
    printf '#!/bin/bash\necho 0\n' > "$MOCKS/cat"
    printf '#!/bin/bash\ntrue\n' > "$MOCKS/ntfs-3g.probe"
    printf '#!/bin/bash\nexit 0\n' > "$MOCKS/ntfsfix"
    chmod +x "$MOCKS"/*
    # SAFE_NTFSFIX_TEST skips the root + block-device guards (CI runners
    # are non-root and /dev/sdb1 does not exist there); the safety/state
    # logic below is what is under test.
    run env PATH="$MOCKS:$PATH" SAFE_NTFSFIX_TEST=1 /bin/bash bin/safe_ntfsfix.sh /dev/sdb1
    [ "$status" -eq 1 ]
    [[ "$output" == *"BitLocker"* ]]
}

@test "safe_ntfsfix: clean volume exits 0" {
    MOCKS="$TMPDIR_TEST/bin"
    mkdir -p "$MOCKS"
    printf '#!/bin/bash\nexit 1\n' > "$MOCKS/findmnt"
    printf '#!/bin/bash\necho ntfs\n' > "$MOCKS/blkid"
    printf '#!/bin/bash\ntrue\n' > "$MOCKS/dmesg"
    printf '#!/bin/bash\necho 0\n' > "$MOCKS/cat"
    printf '#!/bin/bash\nexit 0\n' > "$MOCKS/ntfs-3g.probe"
    printf '#!/bin/bash\nexit 0\n' > "$MOCKS/ntfsfix"
    chmod +x "$MOCKS"/*
    run env PATH="$MOCKS:$PATH" SAFE_NTFSFIX_TEST=1 /bin/bash bin/safe_ntfsfix.sh /dev/sdb1
    [ "$status" -eq 0 ]
    [[ "$output" == *"clean"* ]]
}

@test "safe_ntfsfix: unclean volume aborts without confirmation" {
    MOCKS="$TMPDIR_TEST/bin"
    mkdir -p "$MOCKS"
    printf '#!/bin/bash\nexit 1\n' > "$MOCKS/findmnt"
    printf '#!/bin/bash\necho ntfs\n' > "$MOCKS/blkid"
    printf '#!/bin/bash\ntrue\n' > "$MOCKS/dmesg"
    printf '#!/bin/bash\necho 0\n' > "$MOCKS/cat"
    printf '#!/bin/bash\necho "volume is dirty"\n' > "$MOCKS/ntfs-3g.probe"
    chmod +x "$MOCKS"/*
    run env PATH="$MOCKS:$PATH" /bin/bash bin/safe_ntfsfix.sh /dev/sdb1 </dev/null
    [ "$status" -eq 1 ]
}

@test "safe_ntfsfix: unclean volume repairs after confirmation" {
    MOCKS="$TMPDIR_TEST/bin"
    mkdir -p "$MOCKS"
    printf '#!/bin/bash\nexit 1\n' > "$MOCKS/findmnt"
    printf '#!/bin/bash\necho ntfs\n' > "$MOCKS/blkid"
    printf '#!/bin/bash\ntrue\n' > "$MOCKS/dmesg"
    printf '#!/bin/bash\necho 0\n' > "$MOCKS/cat"
    printf '#!/bin/bash\necho "volume is dirty"\n' > "$MOCKS/ntfs-3g.probe"
    printf '#!/bin/bash\necho "ntfsfix $*" > "$NTFSFIX_LOG"\n' > "$MOCKS/ntfsfix"
    chmod +x "$MOCKS"/*
    run bash -c "printf 'y\n' | env PATH=\"$MOCKS:\$PATH\" SAFE_NTFSFIX_TEST=1 NTFSFIX_LOG=\"$TMPDIR_TEST/ntfsfix.log\" /bin/bash bin/safe_ntfsfix.sh /dev/sdb1"
    [ "$status" -eq 0 ]
    grep -q "ntfsfix -d" "$TMPDIR_TEST/ntfsfix.log"
}

# --- bin/wsl-boot-setup: pick_partitions ------------------------------------
@test "wsl-boot-setup: pick_partitions finds C: and D:" {
    eval "$(sed -n '/^should_probe_ntfs_for_c()/,/^}/p' bin/wsl-boot-setup)"
    eval "$(sed -n '/^is_windows_system_volume()/,/^}/p' bin/wsl-boot-setup)"
    eval "$(python3 tests/extract_fn.py bin/wsl-boot-setup pick_partitions)"
    lsblk() { printf '/dev/sda1\tntfs\tpart\n/dev/sdb1\texfat\tpart\n'; }
    # blkid is deliberately mocked empty: should_probe_ntfs_for_c falls back
    # to it, and the real blkid would probe the RUNNER's own /dev/sda1 (which
    # exists there), making the test host-dependent.
    blkid() { return 1; }
    mount_ro() { return 0; }
    is_windows_system_volume() { return 0; }
    run pick_partitions
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/sda1|/dev/sdb1" ]
}

# --- bin/lsl-home-session-overlay: ro-home guard ----------------------------
@test "lsl-home-session-overlay: no-op when /home is rw" {
    MOCKS="$TMPDIR_TEST/bin"
    mkdir -p "$MOCKS"
    printf '#!/bin/bash\necho "rw,relatime"\n' > "$MOCKS/findmnt"
    chmod +x "$MOCKS"/*
    run env PATH="$MOCKS:$PATH" /bin/bash bin/lsl-home-session-overlay
    [ "$status" -eq 0 ]
}

@test "lsl-home-session-overlay: stacks an overlay when /home is ro" {
    MOCKS="$TMPDIR_TEST/bin"
    mkdir -p "$MOCKS"
    printf '#!/bin/bash\necho "ro,relatime"\n' > "$MOCKS/findmnt"
    printf '#!/bin/bash\ntrue\n' > "$MOCKS/mount"
    printf '#!/bin/bash\ntrue\n' > "$MOCKS/mkdir"
    printf '#!/bin/bash\ntrue\n' > "$MOCKS/touch"
    chmod +x "$MOCKS"/*
    run env PATH="$MOCKS:$PATH" /bin/bash bin/lsl-home-session-overlay
    [ "$status" -eq 0 ]
}

# --- misc/lsl-firstboot-progress.sh -----------------------------------------
@test "lsl-firstboot-progress: exits when stamped" {
    CD="$TMPDIR_TEST/cdrom"
    mkdir -p "$CD/casper"
    touch "$CD/casper/lsl-firstboot.done"
    cp misc/lsl-firstboot-progress.sh "$TMPDIR_TEST/progress.sh"
    sed -i "s|/cdrom|$CD|g" "$TMPDIR_TEST/progress.sh"
    run bash "$TMPDIR_TEST/progress.sh"
    [ "$status" -eq 0 ]
}

@test "lsl-firstboot-progress: fresh login while approval pending shows the dialog" {
    CD="$TMPDIR_TEST/cdrom"
    mkdir -p "$CD/casper" "$TMPDIR_TEST/flags"
    touch "$CD/casper/lsl-firstboot.done"
    printf '#!/bin/bash\necho "$@" > "$TMPDIR_TEST/reboot-args"\n' > "$TMPDIR_TEST/reboot-mock.sh"
    chmod +x "$TMPDIR_TEST/reboot-mock.sh"
    cp misc/lsl-firstboot-progress.sh "$TMPDIR_TEST/progress.sh"
    sed -i "s|/cdrom|$CD|g" "$TMPDIR_TEST/progress.sh"
    run env LSL_FIRSTBOOT_FLAG_DIR="$TMPDIR_TEST/flags" LSL_FIRSTBOOT_REBOOT_SH="$TMPDIR_TEST/reboot-mock.sh" \
        bash "$TMPDIR_TEST/progress.sh"
    [ "$status" -eq 0 ]
    grep -q -- "--flag-dir $TMPDIR_TEST/flags" "$TMPDIR_TEST/reboot-args"
    if grep -q -- "\-\-timeout" "$TMPDIR_TEST/reboot-args"; then false; fi
}

@test "lsl-firstboot-progress: stays silent when reboot was cancelled" {
    CD="$TMPDIR_TEST/cdrom"
    mkdir -p "$CD/casper" "$TMPDIR_TEST/flags"
    touch "$CD/casper/lsl-firstboot.done" "$TMPDIR_TEST/flags/reboot-cancel"
    echo $(( $(date +%s) + 300 )) > "$TMPDIR_TEST/flags/deadline"
    printf '#!/bin/bash\necho CALLED > "$TMPDIR_TEST/reboot-args"\n' > "$TMPDIR_TEST/reboot-mock.sh"
    chmod +x "$TMPDIR_TEST/reboot-mock.sh"
    cp misc/lsl-firstboot-progress.sh "$TMPDIR_TEST/progress.sh"
    sed -i "s|/cdrom|$CD|g" "$TMPDIR_TEST/progress.sh"
    run env LSL_FIRSTBOOT_FLAG_DIR="$TMPDIR_TEST/flags" LSL_FIRSTBOOT_REBOOT_SH="$TMPDIR_TEST/reboot-mock.sh" \
        bash "$TMPDIR_TEST/progress.sh"
    [ "$status" -eq 0 ]
    [ ! -e "$TMPDIR_TEST/reboot-args" ]
}

@test "lsl-firstboot-progress: stays silent once decided, shows dialog while pending" {
    CD="$TMPDIR_TEST/cdrom"
    mkdir -p "$CD/casper" "$TMPDIR_TEST/flags"
    touch "$CD/casper/lsl-firstboot.done"
    printf '#!/bin/bash\necho CALLED > "$TMPDIR_TEST/reboot-args"\n' > "$TMPDIR_TEST/reboot-mock.sh"
    chmod +x "$TMPDIR_TEST/reboot-mock.sh"
    cp misc/lsl-firstboot-progress.sh "$TMPDIR_TEST/progress.sh"
    sed -i "s|/cdrom|$CD|g" "$TMPDIR_TEST/progress.sh"
    # No decision yet (even with a stale deadline file from an older layer):
    # the approval dialog is due - there is no timer to expire.
    echo $(( $(date +%s) - 60 )) > "$TMPDIR_TEST/flags/deadline"
    run env LSL_FIRSTBOOT_FLAG_DIR="$TMPDIR_TEST/flags" LSL_FIRSTBOOT_REBOOT_SH="$TMPDIR_TEST/reboot-mock.sh" \
        bash "$TMPDIR_TEST/progress.sh"
    [ "$status" -eq 0 ]
    [ -e "$TMPDIR_TEST/reboot-args" ]
    rm -f "$TMPDIR_TEST/reboot-args" "$TMPDIR_TEST/flags/deadline"
    run env LSL_FIRSTBOOT_FLAG_DIR="$TMPDIR_TEST/flags" LSL_FIRSTBOOT_REBOOT_SH="$TMPDIR_TEST/reboot-mock.sh" \
        bash "$TMPDIR_TEST/progress.sh"
    [ "$status" -eq 0 ]
    [ -e "$TMPDIR_TEST/reboot-args" ]
    # Once the user decides, fresh logins stay silent.
    rm -f "$TMPDIR_TEST/reboot-args"
    touch "$TMPDIR_TEST/flags/reboot-cancel"
    run env LSL_FIRSTBOOT_FLAG_DIR="$TMPDIR_TEST/flags" LSL_FIRSTBOOT_REBOOT_SH="$TMPDIR_TEST/reboot-mock.sh" \
        bash "$TMPDIR_TEST/progress.sh"
    [ "$status" -eq 0 ]
    [ ! -e "$TMPDIR_TEST/reboot-args" ]
}

@test "lsl-firstboot-progress: exits without zenity" {
    run env PATH="$TMPDIR_TEST/empty" /bin/bash misc/lsl-firstboot-progress.sh
    [ "$status" -eq 0 ]
}

# --- bin/lsl-display-settings / lsl-pin-favorites ---------------------------
@test "lsl-display-settings: percent_to_scale_str converts" {
    eval "$(sed -n '/^percent_to_scale_str()/,/^}/p' bin/lsl-display-settings)"
    run percent_to_scale_str 150
    [ "$output" = "1.5" ]
    run percent_to_scale_str 200
    [ "$output" = "2" ]
    run percent_to_scale_str 10
    [ "$status" -ne 0 ]
}

@test "lsl-display-settings: set-scale rewrites the monitors file" {
    eval "$(sed -n '/^die()/,/^}/p' bin/lsl-display-settings)"
    eval "$(sed -n '/^require_monitors_file()/,/^}/p' bin/lsl-display-settings)"
    eval "$(sed -n '/^percent_to_scale_str()/,/^}/p' bin/lsl-display-settings)"
    eval "$(sed -n '/^set_scale()/,/^}/p' bin/lsl-display-settings)"
    MONITORS_XML="$TMPDIR_TEST/monitors.xml"
    echo '<monitors><monitor><scale>2</scale></monitor></monitors>' > "$MONITORS_XML"
    run set_scale 150
    [ "$status" -eq 0 ]
    grep -q '<scale>1.5</scale>' "$MONITORS_XML"
}

@test "lsl-pin-favorites: append_unique dedupes" {
    eval "$(sed -n '/^append_unique()/,/^}/p' bin/lsl-pin-favorites)"
    run append_unique "a" "b" "a"
    [ "$status" -eq 0 ]
    [[ "$output" == *"b"* ]]
    [[ "$output" == *"a"* ]]
}

@test "lsl-pin-favorites: parse_gsettings_array splits on commas, not newlines" {
    eval "$(sed -n '/^parse_gsettings_array()/,/^}/p' bin/lsl-pin-favorites)"
    # gsettings get prints the whole "as" array on a single line.
    run parse_gsettings_array "['org.gnome.Calculator.desktop', 'org.x.editor.desktop', 'kitty.desktop']"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 3 ]
    [ "${lines[0]}" = "org.gnome.Calculator.desktop" ]
    [ "${lines[1]}" = "org.x.editor.desktop" ]
    [ "${lines[2]}" = "kitty.desktop" ]
    run parse_gsettings_array "[]"
    [ "${#lines[@]}" -eq 0 ]
}

# --- bin/add-steam-libraries -------------------------------------------------
@test "add-steam-libraries: adds a library to libraryfolders.vdf" {
    # Brace-aware extraction (tests/extract_fn.py): the function contains a
    # heredoc with a column-0 `}` (the VDF closing brace), which truncates
    # the naive sed '/^fn/,/^}/' range mid-heredoc into a syntax error.
    eval "$(python3 tests/extract_fn.py bin/add-steam-libraries add_library_to_config)"
    STEAM_USER="testuser"
    STEAM_CONFIG_DIR="$TMPDIR_TEST/steam"
    mkdir -p "$STEAM_CONFIG_DIR/steamapps"
    LIBRARYFOLDERS_VDF="$STEAM_CONFIG_DIR/steamapps/libraryfolders.vdf"
    run add_library_to_config "/mnt/d/SteamLibrary"
    [ "$status" -eq 0 ]
    grep -q '"/mnt/d/SteamLibrary"' "$LIBRARYFOLDERS_VDF"
}

# --- bin/detect-drive-letters.sh / clean-old-system-patches.sh / lsl-update-bin
@test "detect-drive-letters: requires tools" {
    run env PATH="$TMPDIR_TEST/empty" /bin/bash bin/detect-drive-letters.sh
    [ "$status" -eq 1 ]
    [[ "$output" == *"required"* ]]
}

@test "clean-old-system-patches: strips cdrom/bash.log lines" {
    eval "$(sed -n '/^strip_lines_matching_cdrom_bash_log()/,/^}/p' bin/clean-old-system-patches.sh)"
    F="$TMPDIR_TEST/profile"
    printf 'export PATH=/cdrom/bin:$PATH\n# log to /cdrom/bash.log\n' > "$F"
    run strip_lines_matching_cdrom_bash_log "$F"
    [ "$status" -eq 0 ]
    ! grep -q "bash.log" "$F"
    grep -q "PATH=/cdrom/bin" "$F"
}

@test "lsl-update-bin: syncs scripts to the USB" {
    REPO="$TMPDIR_TEST/repo"
    CD="$TMPDIR_TEST/cdrom"
    mkdir -p "$REPO/bin" "$CD"
    touch "$REPO/onboot.sh" "$REPO/install.sh" "$REPO/bin/uproot"
    cp bin/lsl-update-bin "$REPO/bin/lsl-update-bin"
    sed -i "s|/cdrom|$CD|g" "$REPO/bin/lsl-update-bin"
    # The copy re-escalates via sudo when non-root; under CI sudo that
    # leaves root-owned files teardown cannot remove. The sync logic (not
    # privilege escalation) is under test, so no-op the re-exec line here
    # (replacing, not deleting: an empty `then` clause is a syntax error).
    sed -i 's|exec sudo "$0" "$@"|: test-seam: stay non-root|' "$REPO/bin/lsl-update-bin"
    mount() { :; }
    install() { cp "$1" "$2"; }
    run bash "$REPO/bin/lsl-update-bin"
    [ "$status" -eq 0 ]
    [ -f "$CD/onboot.sh" ]
    [ -f "$CD/bin/uproot" ]
}

# --- bin/kexec-reboot / systemd-reboot / nix / nix-env ---------------------
@test "kexec-reboot: dry-run prints kernel and initrd" {
    CD="$TMPDIR_TEST/cdrom"
    mkdir -p "$CD/casper"
    touch "$CD/casper/vmlinuz" "$CD/casper/initrd.lz"
    cp bin/kexec-reboot "$TMPDIR_TEST/kexec-reboot.sh"
    sed -i "s|/cdrom|$CD|g" "$TMPDIR_TEST/kexec-reboot.sh"
    run bash "$TMPDIR_TEST/kexec-reboot.sh" -n
    [ "$status" -eq 0 ]
    [[ "$output" == *"Kernel:"* ]]
    [[ "$output" == *"Initrd:"* ]]
}

@test "systemd-reboot: dry-run prints actions" {
    run bash bin/systemd-reboot -n
    [ "$status" -eq 0 ]
    [[ "$output" == *"Dry-run"* ]]
}

@test "nix: should_log only for imperative subcommands" {
    eval "$(sed -n '/^lsl_nix_should_log()/,/^}/p' bin/nix)"
    run lsl_nix_should_log profile install
    [ "$status" -eq 0 ]
    run lsl_nix_should_log profile list
    [ "$status" -eq 1 ]
    run lsl_nix_should_log build
    [ "$status" -eq 1 ]
}

@test "nix: delegates to the real nix and logs" {
    MOCKS="$TMPDIR_TEST/bin"
    mkdir -p "$MOCKS"
    printf '#!/bin/bash\necho "real nix $*"\n' > "$MOCKS/nix"
    chmod +x "$MOCKS/nix"
    run env PATH="$MOCKS:$PATH" REAL_NIX="$MOCKS/nix" XDG_STATE_HOME="$TMPDIR_TEST/state" \
        /bin/bash bin/nix profile install foo
    [ "$status" -eq 0 ]
    [[ "$output" == *"real nix profile install foo"* ]]
    [ -f "$TMPDIR_TEST/state/lsl/nix-imperative.log" ]
}

@test "nix-env: delegates and logs" {
    MOCKS="$TMPDIR_TEST/bin"
    mkdir -p "$MOCKS"
    printf '#!/bin/bash\necho "real nix-env $*"\n' > "$MOCKS/nix-env"
    chmod +x "$MOCKS/nix-env"
    run env PATH="$MOCKS:$PATH" REAL_NIX_ENV="$MOCKS/nix-env" XDG_STATE_HOME="$TMPDIR_TEST/state" \
        /bin/bash bin/nix-env -i foo
    [ "$status" -eq 0 ]
    [[ "$output" == *"real nix-env -i foo"* ]]
    [ -f "$TMPDIR_TEST/state/lsl/nix-imperative.log" ]
}

# --- bin/lsl-precache-profile.sh --------------------------------------------
@test "lsl-precache-profile: requires fatrace" {
    run env PATH="$TMPDIR_TEST/empty" /bin/bash bin/lsl-precache-profile.sh 1
    [ "$status" -eq 1 ]
    [[ "$output" == *"fatrace"* ]]
}

@test "lsl-precache-profile: records reads to the output" {
    CD="$TMPDIR_TEST/cdrom"
    MOCKS="$TMPDIR_TEST/bin"
    mkdir -p "$CD" "$MOCKS"
    cp bin/lsl-precache-profile.sh "$TMPDIR_TEST/precache-profile.sh"
    sed -i "s|/cdrom|$CD|g" "$TMPDIR_TEST/precache-profile.sh"
    printf '#!/bin/bash\necho "bash(123): RO /etc/os-release"\necho "bash(123): RO /proc/x"\n' > "$MOCKS/fatrace"
    printf '#!/bin/bash\ntrue\n' > "$MOCKS/mount"
    chmod +x "$MOCKS"/*
    run env PATH="$MOCKS:$PATH" /bin/bash "$TMPDIR_TEST/precache-profile.sh" 1 "$CD/lsl-precache.list"
    [ "$status" -eq 0 ]
    grep -q "/etc/os-release" "$CD/lsl-precache.list"
    ! grep -q "/proc/x" "$CD/lsl-precache.list"
}

# --- lsl-btrfs-growd --------------------------------------------------------
@test "lsl-btrfs-growd: logs a persistent marker when online growth is not applied" {
    . bin/lsl-common.sh
    eval "$(sed -n '/^free_pct()/,/^}/p' bin/lsl-btrfs-growd)"
    eval "$(sed -n '/^try_grow()/,/^}/p' bin/lsl-btrfs-growd)"
    IMG="$TMPDIR_TEST/home.btrfs"
    touch "$IMG"
    MIN_PCT=10
    CHUNK_MIB=1024
    # mountpoint reports /home busy so the re-loop is taken (unmount fails)
    mountpoint() { case "$2" in /home) return 0 ;; *) return 1 ;; esac; }
    # df reports 95% full -> triggers grow
    df() { echo "Filesystem 1K-blocks Used Available Use% Mounted on"; echo "/dev/loop0 1048576 950000 48576 95% /home"; }
    losetup() { case "$1" in -j) echo "/dev/loop0: [2049]:12345 ($IMG)" ;; -c) ;; esac; }
    blockdev() { [ "$1" = "--getsize64" ] && echo 1048576; }   # unchanged size -> detection path
    btrfs() { :; }
    truncate() { :; }
    findmnt() { echo "/dev/loop0"; }
    mkdir -p "$TMPDIR_TEST/datadir"
    export LSL_DATA_DIR="$TMPDIR_TEST/datadir"
    run try_grow /home "$IMG" home
    [ "$status" -eq 0 ]
    # A persistent grow log must explain the busy-loop limitation.
    [ -f "$TMPDIR_TEST/datadir/lsl-btrfs-grow.log" ]
    grep -q "reboot to apply" "$TMPDIR_TEST/datadir/lsl-btrfs-grow.log"
}

@test "lsl-btrfs-growd: refreshes EVERY loop attached to the image, not just the first" {
    # A stale loop left over from a crashed boot keeps the old size cached, so
    # refreshing only the first device (the old head -1 behaviour) silently
    # misses the growth. Two devices must both be refreshed.
    eval "$(sed -n '/^lsl_refresh_image_loops()/,/^}/p' bin/lsl-common.sh)"
    IMG="$TMPDIR_TEST/home.btrfs"
    touch "$IMG"
    # Pick two loop devices that REALLY exist. `[ -b ]` is a shell builtin and
    # cannot be overridden by a function named `test`, so the helper's own guard
    # cannot be mocked away - the device names have to be genuine.
    DEV_A=""; DEV_B=""
    for d in /dev/loop*; do
        [ -b "$d" ] || continue
        if [ -z "$DEV_A" ]; then DEV_A="$d"
        elif [ -z "$DEV_B" ]; then DEV_B="$d"; break; fi
    done
    if [ -z "$DEV_A" ] || [ -z "$DEV_B" ]; then
        skip "need two real block devices under /dev/loop* to test the multi-loop case"
    fi
    A="$DEV_A"; B="$DEV_B"
    losetup() {
        case "$1" in
            -j) printf '%s: [2049]:12345 (%s)\n%s: [2050]:12345 (%s)\n' "$A" "$IMG" "$B" "$IMG" ;;
            -c) echo "losetup -c $2" >> "$TMPDIR_TEST/losetup.log" ;;
            *)  return 0 ;;
        esac
    }
    lsl_refresh_image_loops "$IMG"
    grep -q "losetup -c $A" "$TMPDIR_TEST/losetup.log"
    grep -q "losetup -c $B" "$TMPDIR_TEST/losetup.log"
}

@test "lsl-btrfs-growd: honors LSL_BTRFS_GROW_INTERVAL_SEC in the loop" {
    # Extract the loop body, then run it inside a subshell that defines its
    # dependencies, so we can assert the sleep interval comes from
    # LSL_BTRFS_GROW_INTERVAL_SEC (default 60).
    loop_body="$(sed -n '/^while true; do/,/^done/p' bin/lsl-btrfs-growd)"
    cat > "$TMPDIR_TEST/loop_test.sh" <<EOF
#!/bin/bash
set -e
lsl_is_usb_mode() { return 1; }
# The loop gates on lsl_effective_home_is_hdd (WHYFAIL9 moved it off the live
# lsl_is_usb_mode resolve). Stubbing only lsl_is_usb_mode left the predicate
# undefined, so the loop exited 0 before ever reaching sleep() and this test
# failed on a missing sleep.log - a stale harness, not a daemon bug.
lsl_effective_home_is_hdd() { return 0; }
lsl_load_config() { :; }
lsl_home_btrfs_path() { echo /x/home.btrfs; }
lsl_cache_btrfs_path() { echo /x/cache.btrfs; }
try_grow() { :; }
sleep() { echo "slept \$1" > "$TMPDIR_TEST/sleep.log"; }
export LSL_BTRFS_GROW_INTERVAL_SEC=7
$loop_body
EOF
    chmod +x "$TMPDIR_TEST/loop_test.sh"
    ( "$TMPDIR_TEST/loop_test.sh" >/dev/null 2>&1 & echo $! > "$TMPDIR_TEST/pid"; sleep 0.3; kill "$(cat "$TMPDIR_TEST/pid")" 2>/dev/null ) || true
    grep -q "slept 7" "$TMPDIR_TEST/sleep.log"
}

@test "lsl-toram: refuses when a persistence write is in progress" {
    MOCKS="$TMPDIR_TEST/bin"
    mkdir -p "$MOCKS"
    printf '#!/bin/bash\nexit 3\n' > "$MOCKS/systemctl"
    printf '#!/bin/bash\ncase "$*" in *cdrom*) exit 0 ;; *) exit 1 ;; esac\n' > "$MOCKS/mountpoint"
    # Run as if root so the live-session checks (not the EUID guard) are what we exercise.
    printf '#!/bin/bash\necho 0\n' > "$MOCKS/id"
    chmod +x "$MOCKS"/*
    # Simulate an in-flight uphome/flush by dropping a live PID file under /run.
    # Use this test shell's own PID (always alive during the run) so we don't
    # spawn a long-lived background process that would keep bats waiting.
    mkdir -p "$TMPDIR_TEST/run"
    echo "$$" > "$TMPDIR_TEST/run/lsl-flush-home.pid"
    # Rewrite the per-run paths (/run/...) to a temp dir, then run the script
    # directly (run env PATH=... bash <file> honors the mocks; bash -c does not).
    sed "s#/run/#$TMPDIR_TEST/run/#g" bin/lsl-toram.sh > "$TMPDIR_TEST/toram.sh"
    chmod +x "$TMPDIR_TEST/toram.sh"
    run env PATH="$MOCKS:$PATH" bash "$TMPDIR_TEST/toram.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"persistence write is in progress"* ]]
}

@test "lsl-nix-doctor: reports missing nix-users membership" {
    MOCKS="$TMPDIR_TEST/bin"
    mkdir -p "$MOCKS"
    # Provide getent that lacks membership, id that is the desktop user.
    printf '#!/bin/bash\ncase "$1" in group) exit 1 ;; *) exit 1 ;; esac\n' > "$MOCKS/getent"
    printf '#!/bin/bash\nexit 1\n' > "$MOCKS/systemctl"
    chmod +x "$MOCKS"/*
    lsl_desktop_user() { echo "mint"; }
    run env PATH="$MOCKS:$PATH" bash -c '
        . bin/lsl-common.sh
        getent() { return 1; }
        id() { return 0; }
        mountpoint() { return 1; }
        command() { case "$1" in -v) return 1 ;; *) return 1 ;; esac; }
        bash bin/lsl-nix-doctor.sh'
    [ "$status" -eq 1 ]
    [[ "$output" == *"nix-users"* ]]
}

@test "lsl-steam-doctor: skips cleanly when no Steam overlay is set up" {
    MOCKS="$TMPDIR_TEST/bin"
    mkdir -p "$MOCKS"
    printf '#!/bin/bash\nexit 1\n' > "$MOCKS/systemctl"
    chmod +x "$MOCKS"/*
    run env PATH="$MOCKS:$PATH" bash -c '
        . bin/lsl-common.sh
        mountpoint() { return 1; }
        lsl_desktop_user() { echo "mint"; }
        bash bin/lsl-steam-doctor.sh'
    # No overlay and no Windows volumes -> all SKIP; exit 0 is acceptable.
    [ "$status" -eq 0 ]
}

@test "lsl-win-backup: include/exclude regex filters and produces a squashfs" {
    T="$(mktemp -d)"
    mkdir -p "$T/src/sub"
    printf x > "$T/src/a.txt"
    printf x > "$T/src/sub/b.md"
    printf x > "$T/src/c.log"
    printf x > "$T/src/old.txt"; touch -d '2020-01-01' "$T/src/old.txt"
    mkdir -p "$T/data"
    cat > "$T/data/backup.conf" <<EOF
job Docs
source $T/src
include \.txt$
include \.md$
exclude c\.log
mode full
EOF
    run env LSL_DATA_DIR="$T/data" LSL_BACKUP_DIR="$T/data/backups" LSL_BACKUP_CONF="$T/data/backup.conf" \
        bash bin/lsl-win-backup.sh --run
    [ "$status" -eq 0 ]
    sfs="$(find "$T/data/backups" -name '*_full.squashfs' | head -1)"
    [ -n "$sfs" ]
    run bash -c "unsquashfs -l '$sfs' | grep -c c.log"
    [ "$output" = "0" ]
    run bash -c "unsquashfs -l '$sfs' | grep -cE 'a.txt|sub/b.md|old.txt'"
    [ "${output:-0}" -ge 3 ]
    rm -rf "$T"
}

@test "lsl-win-backup: incremental captures only files newer than last run" {
    T="$(mktemp -d)"
    mkdir -p "$T/src" "$T/data/backups/.state"
    printf x > "$T/src/a.txt"; touch -d '2026-01-01 10:00:00' "$T/src/a.txt"
    printf x > "$T/src/b.md";  touch -d '2026-01-01 10:00:00' "$T/src/b.md"
    cat > "$T/data/backup.conf" <<EOF
job J
source $T/src
mode incremental
EOF
    # Seed last run at 12:00 => threshold 11:50; files from 10:00 are older => SKIP (no sfs).
    echo "$(date -d '2026-01-01 12:00:00' +%s)" > "$T/data/backups/.state/last_J.ts"
    run env LSL_DATA_DIR="$T/data" LSL_BACKUP_DIR="$T/data/backups" LSL_BACKUP_CONF="$T/data/backup.conf" \
        bash bin/lsl-win-backup.sh --run
    [ "$status" -eq 0 ]
    run bash -c "find '$T/data/backups' -name '*_incr.squashfs' | wc -l"
    [ "$output" = "0" ]
    # Modify a.txt at 12:30 (after threshold) => only a.txt should be captured.
    touch -d '2026-01-01 12:30:00' "$T/src/a.txt"
    run env LSL_DATA_DIR="$T/data" LSL_BACKUP_DIR="$T/data/backups" LSL_BACKUP_CONF="$T/data/backup.conf" \
        bash bin/lsl-win-backup.sh --run
    [ "$status" -eq 0 ]
    sfs="$(find "$T/data/backups" -name '*_incr.squashfs' | tail -1)"
    [ -n "$sfs" ]
    run bash -c "unsquashfs -l '$sfs' | grep -c a.txt"; [ "$output" = "1" ]
    run bash -c "unsquashfs -l '$sfs' | grep -c b.md"; [ "$output" = "0" ]
    rm -rf "$T"
}

@test "lsl-copy-sfs-hdd: merges layers into one self-contained layer" {
    # The mirror is a SINGLE self-contained squashfs now, because casper's
    # LAYERFS_PATH walk on a dot-free name resolves to exactly that one file -
    # it cannot stack a chain that no longer exists (see WHYFAIL14).
    T="$(mktemp -d)"
    USBDIR="$T/usb"; HDD="$T/hdd"; mkdir -p "$USBDIR/casper"
    printf 'LSL_DATA_DIR=/mnt/c/Users/lsl-usb\n' > "$USBDIR/lsl-usb.env"
    # Real squashfs layers: a base rootfs, the firstboot stub, and an append.
    # build_layer <srcdir> <marker> <out.squashfs> [extra-file ...]
    build_layer() {
        local d marker out extra
        d="$1"; marker="$2"; out="$3"; shift 3
        rm -rf "$d"; mkdir -p "$d/sbin" "$d/etc"
        echo "#!/bin/sh" > "$d/sbin/init"; chmod +x "$d/sbin/init"
        echo "$marker" > "$d/etc/marker"
        for extra in "$@"; do echo "$extra" > "$d/etc/$extra"; done
        mksquashfs "$d" "$out" -comp zstd >/dev/null 2>&1
        rm -rf "$d"
    }
    build_layer "$T/l1" base "$T/usb/casper/filesystem.squashfs"
    build_layer "$T/l2" stub "$T/usb/casper/filesystem_z0_firstboot.squashfs"
    build_layer "$T/l3" appended "$T/usb/casper/filesystem_z20260930120000.squashfs" newfile
    run env LSL_CDROM="$USBDIR" LSL_DATA_DIR="$HDD" bash bin/lsl-copy-sfs-hdd.sh --yes
    [ "$status" -eq 0 ]
    # exactly one layer is published, and it is the merged one
    [ -f "$HDD/sfs/filesystem_zmerged.squashfs" ]
    [ ! -f "$HDD/sfs/filesystem.squashfs" ]
    # it carries content from EVERY layer, newest winning
    run bash -c "unsquashfs -cat '$HDD/sfs/filesystem_zmerged.squashfs' etc/marker"
    [ "$output" = "appended" ]
    run bash -c "unsquashfs -cat '$HDD/sfs/filesystem_zmerged.squashfs' etc/newfile"; [ "$output" = "newfile" ]
    # and it is a real rootfs (no /sbin/init would drop the boot to initramfs)
    run bash -c "unsquashfs -cat '$HDD/sfs/filesystem_zmerged.squashfs' sbin/init"
    [[ "$output" == *"#!/bin/sh"* ]]
    # --status reports the merged layer, not per-layer copies
    run env LSL_CDROM="$USBDIR" LSL_DATA_DIR="$HDD" bash bin/lsl-copy-sfs-hdd.sh --status
    [[ "$output" == *"filesystem_zmerged.squashfs: present"* ]]
    rm -rf "$T"
}

@test "lsl-copy-sfs-hdd: refuses to publish a layer with no /sbin/init" {
    # A merged tree without an init would brick the mirror boot silently, so
    # the builder must refuse rather than publish it.
    T="$(mktemp -d)"
    USBDIR="$T/usb"; HDD="$T/hdd"; mkdir -p "$USBDIR/casper" "$T/l1"
    printf 'LSL_DATA_DIR=/mnt/c/Users/lsl-usb\n' > "$USBDIR/lsl-usb.env"
    echo "not a rootfs" > "$T/l1/file"
    mksquashfs "$T/l1" "$USBDIR/casper/filesystem.squashfs" -comp zstd >/dev/null 2>&1
    run env LSL_CDROM="$USBDIR" LSL_DATA_DIR="$HDD" bash bin/lsl-copy-sfs-hdd.sh --yes
    [ "$status" -ne 0 ]
    [ ! -f "$HDD/sfs/filesystem_zmerged.squashfs" ]
    rm -rf "$T"
}

# --- lsl-home.service: /home before the greeter; onboot after it ------------
@test "lsl-home.service mounts /home before the display manager" {
    # A session that starts before /home is final has the persistent home mounted
    # underneath it, dies, and drops back to the greeter.
    grep -qE '^Before=.*display-manager\.service' systemd/lsl-home.service
    grep -q '^ExecStart=/cdrom/bin/lsl-mount-home\.sh$' systemd/lsl-home.service
    # a wedged mount must not block the greeter forever (oneshot: no default timeout)
    grep -qE '^TimeoutStartSec=' systemd/lsl-home.service
    # gated on neither onboot.service nor its own duration: the greeter waits
    # only for the home mount
    ! grep -qE '^(After|Before)=.*onboot\.service' systemd/lsl-home.service
}

@test "onboot.service runs after lsl-home.service and no longer gates the greeter" {
    grep -qE '^After=.*lsl-home\.service' systemd/onboot.service
    ! grep -qE '^Before=.*display-manager\.service' systemd/onboot.service
}

@test "onboot.sh delegates the /home mount and backgrounds the wifi wait" {
    # The moved block must be gone from onboot.sh, and the mount delegated.
    grep -q '/cdrom/bin/lsl-mount-home.sh' onboot.sh
    ! grep -q 'lsl_home=tmpfs' onboot.sh
    bash -n bin/lsl-mount-home.sh
    grep -q '^lsl_wait_for_wifi()' onboot.sh
    grep -q '^lsl_wait_for_wifi &$' onboot.sh
    # exactly two mentions: the definition and the backgrounded call
    run bash -c 'grep -c lsl_wait_for_wifi onboot.sh'
    [ "$output" = "2" ]
}

# --- Boot to RAM (ramclone): dm-clone status parsing + boot hook + dialog -----
# dm-clone STATUSTYPE_INFO is
#   0 <len> clone <metablock> <used>/<total> <regionsize> <hydrated>/<total> <hydrating> ...
# The hydrated/total pair is FIELD 7. The old code read fields 4/5 and so always
# reported 0% / never signalled completion, so no "safe to remove" ever appeared.
@test "lsl-ramclone-status: parses hydration from field 7 of the dm-clone status" {
    MOCKS="$TMPDIR_TEST/bin"; mkdir -p "$MOCKS"
    printf '#!/bin/bash\ncase "$1" in status) echo "0 2000000 clone 128 1024/1024 2048 512/2048 1 0 1 hydration_threshold 1 rw" ;; esac\n' > "$MOCKS/dmsetup"
    chmod +x "$MOCKS/dmsetup"
    mkdir -p "$TMPDIR_TEST/ramclone"; : > "$TMPDIR_TEST/ramclone/status"
    sed "s#/run/#$TMPDIR_TEST/#g" bin/lsl-ramclone-status > "$TMPDIR_TEST/ram-status"
    run env PATH="$MOCKS:$PATH" bash "$TMPDIR_TEST/ram-status"
    [ "$status" -eq 1 ]
    [ "$(printf '%s\n' "$output" | head -n1)" = "25" ]
}

@test "lsl-ramclone-status: exit 0 and 100% when hydration is complete" {
    MOCKS="$TMPDIR_TEST/bin"; mkdir -p "$MOCKS"
    printf '#!/bin/bash\ncase "$1" in status) echo "0 2000000 clone 128 2048/2048 2048 2048/2048 0 0 1 hydration_threshold 1 rw" ;; esac\n' > "$MOCKS/dmsetup"
    chmod +x "$MOCKS/dmsetup"
    mkdir -p "$TMPDIR_TEST/ramclone"; : > "$TMPDIR_TEST/ramclone/status"
    sed "s#/run/#$TMPDIR_TEST/#g" bin/lsl-ramclone-status > "$TMPDIR_TEST/ram-status"
    run env PATH="$MOCKS:$PATH" bash "$TMPDIR_TEST/ram-status"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | head -n1)" = "100" ]
}

@test "lsl-ramclone-status: exit 2 when ramclone is not active" {
    sed "s#/run/#$TMPDIR_TEST/#g" bin/lsl-ramclone-status > "$TMPDIR_TEST/ram-status"
    run bash "$TMPDIR_TEST/ram-status"
    [ "$status" -eq 2 ]
}

@test "live-ramclone: dm-clone table includes the mandatory region size" {
    # Without the region-size arg the kernel rejects the table (argc < 4) and
    # Boot to RAM silently copied nothing.
    grep -q 'clone \$META_DEV \$DEST_DEV \$ORIGIN_DEV \$REGION' initramfs/live-ramclone
    grep -q '^REGION=2048$' initramfs/live-ramclone
}

@test "live-ramclone: base and other chain layers resolve to distinct RAM backings" {
    # The base maps to the clone; every other chain layer (z0 / appended) is
    # copied into tmpfs and looped there, so no USB squashfs stays open.
    grep -q '/dev/mapper/clone' initramfs/live-ramclone
    grep -q 'RAMDIR/backdev' initramfs/live-ramclone
    grep -q 'for _lsl_img in \$_lsl_chain' initramfs/live-ramclone
}

@test "live-ramclone: POSIX sh syntax" {
    sh -n initramfs/live-ramclone
}

@test "live-ramclone: no sourced-shell-killing '&& return || exit' guard" {
    # run_scripts SOURCES this hook so its get_backing_device override reaches
    # casper. `[ cond ] && return 0 || exit 0` would exit casper's shell whenever
    # cond is FALSE, so every early-out must be an `if ...; then return ...; fi`.
    # (Comment lines are excluded: the fix's own NOTE quotes the bad idiom.)
    ! grep -vE '^[[:space:]]*#' initramfs/live-ramclone |
        grep -qE '&&[[:space:]]*return 0.*\|\|[[:space:]]*exit 0'
}

@test "lsl-ramclone-progress: no-op when ramclone is not on the cmdline" {
    printf 'BOOT_IMAGE=/vmlinuz quiet splash\n' > "$TMPDIR_TEST/cmdline"
    run env LSL_CMDLINE_FILE="$TMPDIR_TEST/cmdline" LSL_RAMCLONE_DIR="$TMPDIR_TEST/ramclone" \
        bash misc/lsl-ramclone-progress.sh
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "lsl-ramclone-progress: syntax" {
    bash -n misc/lsl-ramclone-progress.sh
}

@test "lsl-ramclone-progress.desktop runs the staged dialog script" {
    grep -q '^Exec=/usr/local/bin/lsl-ramclone-progress.sh$' misc/lsl-ramclone-progress.desktop
    grep -q '^X-GNOME-Autostart-enabled=true$' misc/lsl-ramclone-progress.desktop
}

@test "lsl-progress-gtk.py: parses and has the ramclone mode" {
    python3 -c "import ast; ast.parse(open('misc/lsl-progress-gtk.py').read())"
    grep -q 'def run_ramclone' misc/lsl-progress-gtk.py
    grep -q '"--ramclone"' misc/lsl-progress-gtk.py
}


# --- misc/lsl-firstboot.sh: fine-grained `packages` progress -----------------
# Regression for the "Install packages stuck at 44%" report (2026-09-30): the
# monitor used to fold the single LSL_STEP n/m marker straight into pct, so the
# whole ~470-package apt run showed one frozen value (step 4/9 -> 44). The
# monitor now derives pct for the `packages` task from apt's own stdout.
#
# Harness: extract the real monitor, stub the task_* status writers so we can
# capture the published pct/detail stream, and feed a synthetic log (tail is
# stubbed to dump the file, since the real one uses --pid/-F on a live log).
#
# The `tail` mock must handle ARGS, not just dump the file. monitor_uproot_progress
# uses `tail` twice: once as the log source (`tail --pid -n 0 -F "$LOG"`, which the
# mock replaces with `cat`) and once to take the LAST match out of a progress line
# (`... | tail -n 1`). A mock that ignored its arguments made that second call emit
# the whole log, so `_pct` became a multi-line blob, the numeric guard rejected it,
# and every layer percentage was silently dropped - the test then failed on a
# missing PROG line for a reason that had nothing to do with the monitor.
#
# Only the log-source form is special-cased; everything else falls through to the
# real tail, which is what production uses.
run_monitor() {
    local logfile="$1"
    LOG="$logfile" bash -c '
        set -uo pipefail
        LSL_TASK="packages"
        task_begin()    { LSL_TASK="$1"; printf "BEGIN|%s|%s\n" "$LSL_TASK" "${2:-}"; }
        task_progress() { printf "PROG|%s|%s\n" "$1" "${2:-}"; }
        task_done()     { printf "DONE|%s\n" "$1"; }
        tail() {
            case " $* " in
                *" --pid "*|*" -F "*) cat "$LOG" ;;
                *) command tail "$@" ;;
            esac
        }
        eval "$(python3 tests/extract_fn.py misc/lsl-firstboot.sh monitor_uproot_progress)"
        monitor_uproot_progress 0
    '
}

@test "firstboot monitor: packages pct follows apt output, not one frozen step value" {
    cat > "$TMPDIR_TEST/apt.log" <<'EOF'
LSL_STEP 4/9 base packages (amd64)
Need to get 100 MB of archives.
Get:1 http://x a [1 MB]
Get:2 http://x b [1 MB]
Get:3 http://x c [1 MB]
Get:4 http://x d [1 MB]
Unpacking a
Setting up a
Unpacking b
Setting up b
Unpacking c
Setting up c
Unpacking d
Setting up d
EOF
    run run_monitor "$TMPDIR_TEST/apt.log"
    [ "$status" -eq 0 ]
    # The download phase must produce SEVERAL distinct pct values (the old code
    # emitted exactly one, 44, for the entire step).
    local n
    n="$(printf '%s\n' "$output" | grep '^PROG|' | cut -d'|' -f2 | sort -u | wc -l)"
    [ "$n" -ge 4 ]
    # ...and it must sweep well past 44 during the downloads.
    printf '%s\n' "$output" | grep -q '^PROG|60|'
}

@test "firstboot monitor: published pct never moves backwards" {
    cat > "$TMPDIR_TEST/mono.log" <<'EOF'
LSL_STEP 4/9 base packages (amd64)
Need to get 10 MB of archives.
Get:1 http://x a [1 MB]
Get:2 http://x b [1 MB]
Unpacking a
Setting up a
Unpacking b
Setting up b
LSL_STEP 5/9 snap support
LSL_STEP 6/9 web browser
LSL_STEP 9/9 CLI tools
LSL_TASK layer
Writing new layer squashfs: /cdrom/casper/filesystem_z20260101000000.squashfs
[=/    ]  5000/10000  50%
[====/] 10000/10000 100%
EOF
    run run_monitor "$TMPDIR_TEST/mono.log"
    [ "$status" -eq 0 ]
    python3 - "$output" <<'PY'
import sys
vals = [int(l.split("|")[1]) for l in sys.argv[1].splitlines() if l.startswith("PROG|")]
assert vals, "no progress emitted"
for a, b in zip(vals, vals[1:]):
    assert b >= a, "pct went backwards: %d -> %d" % (a, b)
PY
}

@test "firstboot monitor: hands off to layer packing and tracks mksquashfs" {
    cat > "$TMPDIR_TEST/layer.log" <<'EOF'
LSL_STEP 4/9 base packages (amd64)
Need to get 1 MB of archives.
Get:1 http://x a [1 MB]
Unpacking a
Setting up a
LSL_TASK layer
Writing new layer squashfs: /cdrom/casper/filesystem_z20260101000000.squashfs
[=/] 2500/10000 25%
[==/] 7500/10000 75%
EOF
    run run_monitor "$TMPDIR_TEST/layer.log"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -q '^DONE|packages$'
    printf '%s\n' "$output" | grep -q '^BEGIN|layer|'
    # The layer arm must PUBLISH the mksquashfs percentages. It does so through
    # the shared high-water mark, so the published value is the running maximum,
    # not this line's raw percentage - assert the intent (layer percentages reach
    # the dialog) rather than one exact number that the monotonicity rule is
    # entitled to raise.
    printf '%s\n' "$output" | grep -q '^PROG|.*|Compressing layer'
    printf '%s\n' "$output" | grep -qE '^PROG\|(2[5-9]|[3-9][0-9])\|.*Compressing layer'
    # ...and it must never regress.
    printf '%s\n' "$output" | python3 -c '
import sys
vals = [int(l.split("|")[1]) for l in sys.stdin.read().splitlines() if l.startswith("PROG|")]
assert vals, "no progress emitted"
for a, b in zip(vals, vals[1:]):
    assert b >= a, "pct went backwards: %d -> %d" % (a, b)
'
}

@test "firstboot monitor: malformed apt lines do not abort or divide by zero" {
    cat > "$TMPDIR_TEST/bad.log" <<'EOF'
LSL_STEP
LSL_STEP x/y label
Need to get  MB of archives.
Get:abc
Unpacking
Setting up
LSL_STEP 4/9
Need to get 2 MB of archives.
Get:1 a b [1]
Setting up z
EOF
    run run_monitor "$TMPDIR_TEST/bad.log"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -q '^PROG|'
}

@test "firstboot monitor: syntax" {
    bash -n misc/lsl-firstboot.sh
}

@test "firstboot monitor: detail shows n/m package counts from apt's plan line" {
    # apt announces "N upgraded, M newly installed"; the detail text must show
    # that count rather than the MB figure from "Need to get" (which is a size).
    cat > "$TMPDIR_TEST/count.log" <<'EOF'
LSL_STEP 4/9 base packages (amd64)
155 upgraded, 312 newly installed, 0 to remove and 419 not upgraded.
Need to get 346 MB of archives.
Get:1 http://x a [1 MB]
Get:2 http://x b [1 MB]
Unpacking a
Setting up a
Unpacking b
Setting up b
EOF
    run run_monitor "$TMPDIR_TEST/count.log"
    [ "$status" -eq 0 ]
    # 155 + 312 = 467: the download line must be labelled /467, never /346.
    printf '%s\n' "$output" | grep -q 'Downloading packages (1/467)'
    printf '%s\n' "$output" | grep -q 'Installing packages (1/467)'
    ! printf '%s\n' "$output" | grep -q '/346'
}
