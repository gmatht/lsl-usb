#!/bin/bash
# tests/qemu-accel.sh - shared QEMU accelerator selection for tests/qemu-*.sh.
#
# KVM and WHPX are interchangeable accelerators (both near-native); only
# unaccelerated TCG is infeasible for multi-minute live boots. Sourced (not
# executed) by the qemu boot tests via REPO_ROOT, mirroring how they share
# initramfs hooks and dist/:
#
#   REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
#   . "$REPO_ROOT/tests/qemu-accel.sh"
#
# Env in:  LSL_ACCEL (auto|kvm|whpx|tcg, default auto),
#          QEMU_BIN  (default qemu-system-x86_64; point at a Windows
#                     qemu-system-*.exe to boot under WHPX from WSL2).
# Provides:
#   qemu_resolve_accel  - print the accel to use; fails when auto finds
#                         nothing (caller refuses TCG unless explicit).
#   qemu_accel_argv     - append the qemu flags to a named array:
#                           argv=(); qemu_accel_argv argv "$accel"
#                         (array, so `-accel whpx` stays two words).
#   qemu_host_path      - translate a guest path for a Windows QEMU
#                         (wslpath/cygpath); identity otherwise.
# Pure bash, no hypervisor needed to source (safe under `set -u`).

qemu_resolve_accel() {
    local want="${LSL_ACCEL:-auto}" bin="${QEMU_BIN:-qemu-system-x86_64}"
    case "$want" in
        auto) ;;
        *) printf '%s' "$want"; return 0 ;;
    esac
    if [ -c /dev/kvm ]; then
        printf 'kvm'
        return 0
    fi
    if command -v "$bin" >/dev/null 2>&1 && "$bin" -accel help 2>/dev/null | grep -qi whpx; then
        printf 'whpx'
        return 0
    fi
    return 1
}

qemu_accel_argv() {
    # $1 = array name (nameref), $2 = accel (kvm keeps its legacy spelling).
    local -n _qargv="$1"
    case "$2" in
        kvm) _qargv+=(-enable-kvm) ;;
        whpx|tcg) _qargv+=(-accel "$2") ;;
        *) echo "Unknown accel: $2 (kvm|whpx|tcg)" >&2; return 1 ;;
    esac
}

qemu_host_path() {
    # $1 = guest path. A Windows QEMU needs Windows paths; translate from
    # WSL2 (wslpath) or MSYS2/Cygwin (cygpath), else assume already native.
    case "${QEMU_BIN:-}" in
        *.exe|*.EXE)
            if command -v wslpath >/dev/null 2>&1; then wslpath -w "$1";
            elif command -v cygpath >/dev/null 2>&1; then cygpath -w "$1";
            else printf '%s' "$1"; fi ;;
        *) printf '%s' "$1" ;;
    esac
}
