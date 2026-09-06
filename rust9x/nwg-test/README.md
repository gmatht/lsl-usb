# nwg-test

Tiny GUI test app for [rust9x](https://github.com/rust9x) using
[native-windows-gui](https://crates.io/crates/native-windows-gui) (nwg).

A 300x150 window with a label, a "Say hello" button (updates the label with a
click counter) and an "About" button (modal message box). Win9x-era APIs only.

## Toolchain (installed on this machine)

- rust9x 1.99.0-dev at `/opt/rust9x`, linked into rustup as toolchain `rust9x`
  (from [rust9x-1.99-beta-v2](https://github.com/rust9x/rust/releases) Linux
  release; bundles std for `i586/i686/x86_64-rust9x-windows-msvc`).

## Libraries: vintage toolset for rust9x targets only

Per the [rust9x docs](https://github.com/rust9x/docs), the Platform SDK import
libs can be any version, but the **MSVC runtime decides OS support**. Instead
of VS2022 (Win7+), the rust9x targets link the vintage toolset:

- `/opt/msvc-toolchains/sdk71a/Lib` — Windows SDK **v7.1A** import libraries
  (incl. `unicows.lib`, `ws2_32.lib`). Mirror:
  [huangqinjin/Windows-SDK-v7.1A](https://github.com/huangqinjin/Windows-SDK-v7.1A).
  Lowercase symlinks were added for every `*.Lib` because `rust-lld` looks up
  e.g. `kernel32.lib` verbatim on a case-sensitive filesystem.
  `cfgmgr32.lib` (not in v7.1A) is an empty stub archive — nothing imports it.
- `/opt/msvc-toolchains/vc6/VC98Lib` — **VC6 (MSVC 6.0) static CRT**
  (`libcmt.lib`). Mirror: [itsmattkc/MSVC600](https://github.com/itsmattkc/MSVC600).
  Supports Win95+/NT3.5+; no unwinding (`panic = "abort"` in Cargo.toml) and
  no SAFESEH (`/SAFESEH:NO` is passed).

All of this is scoped in `.cargo/config.toml` to
`[target.'cfg(all(target_family = "rust9x", target_env = "msvc"))']`, so
regular msvc targets are unaffected (modern VS2022/Win10-SDK LIBPATHs are
listed commented-out there).

### C99 float shims

On MSVC targets `compiler_builtins` delegates float routines to the CRT, and
the VC6 CRT predates C99. `src/float_shim.rs` provides `round`/`roundf`
(needed by nwg's `stretch` layout engine) implemented without calling any
libm function that would itself lower to a CRT float call.

## Building

```
cargo +rust9x build --target i686-rust9x-windows-msvc
```

Verified output: PE32/i386, GUI subsystem, `OSVersion 3.1 /
SubsystemVersion 4.0`, imports only USER32/KERNEL32/GDI32/COMCTL32/ole32/SHELL32.

Notes:

- `#![windows_subsystem = "windows"]` in `main.rs` is required: with
  `/SUBSYSTEM:WINDOWS` the MSVC CRT startup would otherwise look for
  `_WinMain@16` and the link fails.
- Running on Windows 9x/ME needs `unicows.dll` next to the executable.
- `build-std` is off (the tarball doesn't bundle `rust-src`); the precompiled
  std for the rust9x targets is used instead.

## Sanity check without the rust9x toolchain

```
cargo check --target i686-pc-windows-msvc
```
