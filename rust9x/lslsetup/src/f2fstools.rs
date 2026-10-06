// Resolve + fetch the f2fs-tools and fatresize binaries into the initrd's tool
// tarball, at install time.
//
// WHY NOT JUST TAKE THEM FROM THE ISO (DESIGN-F2FS-PERSISTENCE.md §4.3)
//   A stock Mint 22.3 ISO ships neither tool: its rootfs has no mkfs.f2fs and no
//   fatresize, and casper/filesystem.manifest (2005 packages) does not list
//   f2fs-tools or fatresize either - the pool is a subset of what the live
//   session needs. Measured, not assumed.
//
// WHY NOT SHIP BINARY + .so CLOSURE
//   A host-built fatresize needs libparted.so.2 and libparted-fs-resize.so.0,
//   which are NOT in casper's initrd, so it drags in ~11 libraries whose glibc
//   must match the guest's exactly. Wrong build host => it fails to load inside
//   an initrd that cannot report the error usefully. Shipping whole debs and
//   unpacking only the needed files sidesteps this: we take the SAME binaries
//   the guest's own packages would install, so the version always matches the
//   distribution it came from.
//
// WHAT THIS DOES
//   1. resolve each package's exact URL from the suite's Packages index (so a
//      version bump does not break it - the same technique hardware.rs already
//      uses for driver debs),
//   2. download the .deb,
//   3. open it as an ar archive, take data.tar.{xz,zst,gz},
//   4. extract the tool plus its shared-library closure out of that tar,
//   5. pack the result as the tarball the initrd's lsl-f2fs-tools.sh unpacks.
//
// The suite is read from the target ISO when possible (dists/<suite>), so the
// binaries match the stick's own release rather than the build machine's.

use std::collections::BTreeMap;
use std::io::Read;

// WHICH ARCHIVE WE QUERY - NOT HARDCODEABLE TO ONE DISTRO
//   A suite name alone is not enough to pick a mirror: `trixie` is a Debian
//   release, `noble` is an Ubuntu one, and asking Ubuntu's archive for `trixie`
//   produces a URL that cannot exist. The suite is read off the ISO
//   (`suite_from_iso`), so feeding it to the wrong mirror is the natural
//   mistake and it fails with an HTTP 404 rather than anything legible.
//   So the mirror is DERIVED from the suite, and an unrecognised suite is an
//   explicit error rather than a silent fallback to Ubuntu - which is what a
//   hardcoded mirror constant did.
//
// VERIFIED AGAINST THE LIVE ARCHIVE (pool listings, 2026-10)
//   Debian main carries `f2fs-tools` and `fatresize` under the SAME names as
//   Ubuntu, plus `libparted2t64` / `libparted-fs-resize0t64` (the 64-bit
//   time_t rename is Debian's too, since 3.6). So WANTED and LIBS need no
//   per-distro table - only the mirror root and the component list differ.
//   Both packages are in Debian `main`; there is no `universe` on Debian.

/// Debian release codenames we know how to query. Explicit and narrow on
/// purpose: the list is what makes `suite -> mirror` auditable, and a fuzzy
/// match would let a future codename silently land on the Ubuntu archive.
const DEBIAN_SUITES: &[&str] = &["bookworm", "trixie", "forky"];

/// Components to search, in order, on Ubuntu and its derivatives.
const UBUNTU_COMPONENTS: &[&str] = &["main", "universe"];
/// Debian has no `universe`; both tools are in `main`.
const DEBIAN_COMPONENTS: &[&str] = &["main"];

/// A resolved apt archive: where to fetch, and which components to search.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Mirror {
    pub root: &'static str,
    pub components: &'static [&'static str],
}

const UBUNTU_MIRROR: Mirror = Mirror {
    root: "http://archive.ubuntu.com/ubuntu",
    components: UBUNTU_COMPONENTS,
};

const DEBIAN_MIRROR: Mirror = Mirror {
    root: "https://deb.debian.org/debian",
    components: DEBIAN_COMPONENTS,
};

/// Ubuntu suite names we recognise. Mint, Zorin, Lubuntu and Xubuntu all
/// publish the suite of their Ubuntu base (`noble`), which is why the driver
/// table's hardcoded `noble` is correct for the supported set.
const UBUNTU_SUITES: &[&str] = &[
    "noble", "jammy", "focal", "mantic", "oracular", "plucky", "questing", "devel",
    "bionic", "xenial", "artful", "disco", "eoan", "groovy", "hirsute", "impish",
];

/// Map a suite name onto the spelling the apt archive actually serves.
///
/// ISO9660 directory names are UPPERCASE by spec, so `suite_from_iso` on a
/// Mint or Zorin image really returns `NOBLE`, not `noble`. The tables below
/// are lowercase, and the suite is interpolated straight into the index URL
/// (`resolve_pool_path`), which the archive serves lowercase-only - MEASURED
/// against archive.ubuntu.com: `/dists/noble/...` is HTTP 200,
/// `/dists/NOBLE/...` is HTTP 404. So the name has to be canonicalised
/// *before* it is used as a URL, not merely matched case-insensitively;
/// folding only in the matcher would trade a legible refusal for a silent
/// 404.
///
/// Case folding does NOT widen the accepted set: the result is still one of
/// the exact table entries, so an unrecognised suite is still refused rather
/// than guessed at.
pub fn canonical_suite(suite: &str) -> Option<&'static str> {
    let lower = suite.trim().to_ascii_lowercase();
    DEBIAN_SUITES
        .iter()
        .chain(UBUNTU_SUITES.iter())
        .find(|known| **known == lower)
        .copied()
}

/// Debian codename -> mirror. `None` for anything unknown, so the caller can
/// refuse rather than guess.
pub fn mirror_for_suite(suite: &str) -> Option<Mirror> {
    let canon = canonical_suite(suite)?;
    if DEBIAN_SUITES.contains(&canon) {
        Some(DEBIAN_MIRROR)
    } else if UBUNTU_SUITES.contains(&canon) {
        Some(UBUNTU_MIRROR)
    } else {
        None
    }
}

/// Debian architectures we can request an index for. A 32-bit stick cannot
/// run an amd64 binary, so the arch is part of the URL and of the cache key.
pub fn apt_arch_for(arch: Option<&str>) -> &'static str {
    match arch.unwrap_or("") {
        "i686" | "i386" | "x86" => "i386",
        _ => "amd64",
    }
}

/// Cache key for a downloaded Packages index.
///
/// The mirror host AND the arch are both part of the key. They used to be
/// omitted, which meant `f2fstools` and `hardware.rs` (which builds the key
/// with a byte-identical format string) shared one namespace: a `main` index
/// fetched for one distro was served for another, and nothing ever
/// invalidated it.
pub fn apt_cache_name(mirror: &Mirror, suite: &str, component: &str, arch: &str) -> String {
    let host = mirror
        .root
        .trim_start_matches("https://")
        .trim_start_matches("http://")
        .trim_end_matches('/');
    let host: String = host
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect();
    format!(
        "lsl-apt-{}-{}-{}-{}-Packages.gz",
        host, suite, component, arch
    )
}

/// Packages the hook needs at boot.
///
/// `f2fs-tools` gives `mkfs.f2fs`; `fatresize` does the FAT shrink. Both are in
/// `universe` on noble (verified against the live index), but `main` is tried
/// first so a future promotion does not break us.
///
/// `sfdisk` is deliberately NOT here: util-linux is in casper's initrd already,
/// and staging a second copy would add ABI risk for nothing.
///
/// `coreutils` is here ONLY for `od` (bin/od), which the hook needs to read the
/// FAT BPB. Measured on the real Mint 22.3 initrd: it has no `od`, no
/// `hexdump` and no `xxd` as a binary OR as a busybox applet, so
/// `dd | od -An -tu4` yields nothing and the hook's corruption guard - the one
/// check standing between "repartitioned" and "a stick that boots fine until
/// you write past the boundary" - is dead without it. One small binary from
/// coreutils is cheaper than hand-rolling byte-to-decimal conversion in sh.
const WANTED: &[&str] = &["f2fs-tools", "fatresize", "coreutils"];

/// Extra libraries the staged tools need beyond the initrd's own set.
///
/// `fatresize`'s gap is the six below (MEASURED: `ldd` on the noble build
/// lists 12 sonames, the initrd supplies 6). `od` pulls nothing new - it wants
/// only `libc`, `libselinux` and `ld-linux`, all of which the initrd has - but
/// that is asserted rather than assumed by `od_extra_libs_is_empty`, so a
/// future coreutils that needs more fails loudly at install time instead of
/// silently producing an `od` that cannot start.
const LIBS: &[(&str, &str)] = &[
    ("libparted.so.2", "libparted2t64"),
    ("libparted-fs-resize.so.0", "libparted-fs-resize0t64"),
    ("libblkid.so.1", "libblkid1"),
    ("libcap.so.2", "libcap2"),
    ("libpcre2-8.so.0", "libpcre2-8-0"),
    ("libuuid.so.1", "libuuid1"),
];

/// Libraries the initrd already provides, so they are never staged. Listed so
/// the report can say what it relied on.
const INITRD_PROVIDES: &[&str] = &[
    "libc.so.6",
    "libm.so.6",
    "libselinux.so.1",
    "libudev.so.1",
    "libdevmapper.so.1",
    "ld-linux-x86-64.so.2",
];

fn log(s: &str) {
    crate::out::info(&format!("f2fs-tools: {}", s));
}

/// The ISO's suite name as found in its `dists/` directory, if any.
///
/// `None` when the ISO cannot be read or carries no `dists/` - which is the
/// case for antiX and Tiny Core. Those have no apt archive at all, so there is
/// nothing to resolve and the caller must be told so rather than handed a
/// guess. This deliberately does NOT fall back to `noble`: a fallback here is
/// what made a non-Ubuntu ISO produce an Ubuntu URL.
pub fn suite_from_iso(iso: &str) -> Option<String> {
    if let Ok(mut h) = crate::iso::Iso::open(iso) {
        if let Ok(entries) = h.list_dir("dists") {
            for (name, is_dir) in entries {
                if is_dir && name != "Release" && !name.is_empty() {
                    return Some(name);
                }
            }
        }
    }
    None
}

/// Resolve the suite read off an ISO into the mirror that actually serves it.
///
/// `Err` names the suite, so the message tells the user which archive was
/// considered and why it was rejected rather than surfacing a bare 404.
pub fn mirror_for_iso(iso: &str) -> Result<(Mirror, String), String> {
    let Some(raw) = suite_from_iso(iso) else {
        return Err(format!(
            "{} has no dists/ directory, so no apt suite can be resolved. Its binaries cannot be fetched from a package archive.",
            std::path::Path::new(iso)
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_else(|| iso.to_string())
        ));
    };
    // The returned suite is the CANONICAL one, not the ISO's spelling: it is
    // interpolated into the index URL, and the archive serves lowercase only
    // (an ISO9660 name is uppercase, so returning `raw` here is what produced
    // "NOBLE is not a suite this build knows how to query"). The refusal names
    // the ISO's own spelling, which is the one the user can recognise.
    let canonical = canonical_suite(&raw).ok_or_else(|| {
        format!(
            "'{}' is not a suite this build knows how to query (Debian: {}; Ubuntu: {}). Refusing to guess an archive.",
            raw,
            DEBIAN_SUITES.join(", "),
            UBUNTU_SUITES.join(", ")
        )
    })?;
    // `canonical` is by construction one of the two tables, so this is total.
    let mirror = mirror_for_suite(canonical).expect("canonical suite is always in a table");
    Ok((mirror, canonical.to_string()))
}

/// Find `pkg`'s `Filename:` in the suite's Packages index on `mirror`.
/// Returns the pool-relative path.
fn resolve_pool_path(
    pkg: &str,
    mirror: &Mirror,
    suite: &str,
    component: &str,
    arch: &str,
) -> Option<String> {
    let cache = format!(
        "{}\\{}",
        crate::sys::temp_dir(),
        apt_cache_name(mirror, suite, component, arch)
    );
    if !crate::sys::path_exists(&cache) {
        let url = format!(
            "{}/dists/{}/{}/binary-{}/Packages.gz",
            mirror.root, suite, component, arch
        );
        let dest = cache.clone();
        if crate::net::download_to_file(&url, &dest, crate::net::user_agent(), &mut |_| {}).is_err() {
            return None;
        }
    }
    let f = std::fs::File::open(&cache).ok()?;
    let gz = flate2::read::GzDecoder::new(f);
    let reader = std::io::BufReader::new(gz);
    use std::io::BufRead;
    let want = format!("Package: {}", pkg);
    let mut in_block = false;
    for line in reader.lines().flatten() {
        if line == want {
            in_block = true;
            continue;
        }
        if in_block {
            if let Some(v) = line.strip_prefix("Filename: ") {
                return Some(v.trim().to_string());
            }
            if line.is_empty() {
                return None; // block ended without a Filename
            }
        }
    }
    None
}

/// A member of an ar archive: name plus data. `ar` members are 60-byte
/// headers with the name in 0..16 and the size in 48..58, padded to even
/// lengths. Minimal by design - a .deb has exactly three members
/// (debian-binary, control.tar.*, data.tar.*) and we only want the last.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ArMember {
    pub name: String,
    pub data: Vec<u8>,
}

/// Parse an ar archive into its members.
pub fn parse_ar(buf: &[u8]) -> Result<Vec<ArMember>, String> {
    if !buf.starts_with(b"!<arch>\n") {
        return Err("not an ar archive (bad magic)".into());
    }
    let mut out = Vec::new();
    let mut i = 8usize;
    while i + 60 <= buf.len() {
        let hdr = &buf[i..i + 60];
        let name_field = String::from_utf8_lossy(&hdr[0..16]).trim().to_string();
        let size_field = String::from_utf8_lossy(&hdr[48..58]).trim().to_string();
        let size: usize = size_field
            .parse()
            .map_err(|_| format!("bad member size {:?}", size_field))?;
        i += 60;
        if i + size > buf.len() {
            // Truncated archive - take what is there and stop rather than
            // reading past the end.
            if i < buf.len() {
                out.push(ArMember {
                    name: name_field,
                    data: buf[i..].to_vec(),
                });
            }
            break;
        }
        out.push(ArMember {
            name: name_field,
            data: buf[i..i + size].to_vec(),
        });
        i += size;
        if size % 2 == 1 {
            i += 1; // members are padded to an even offset
        }
    }
    Ok(out)
}

/// Decompress `data.tar.{zst,xz,gz}` and return the tar bytes.
///
/// Only `.zst` is expected in practice - verified against a real noble `.deb`,
/// whose members are `control.tar.zst` / `data.tar.zst`. The xz and gzip
/// branches keep an older or hand-built package from being a hard error; they
/// use the tar/gzip we already depend on, and deliberately NOT an xz crate
/// (adding a dependency for a path that never runs is not worth it).
pub fn decompress_data_tar(name: &str, data: &[u8]) -> Result<Vec<u8>, String> {
    if name.ends_with(".zst") {
        let mut d = zstd::stream::Decoder::new(data).map_err(|e| format!("zstd: {}", e))?;
        let mut out = Vec::new();
        d.read_to_end(&mut out).map_err(|e| format!("zstd read: {}", e))?;
        Ok(out)
    } else if name.ends_with(".gz") {
        let mut d = flate2::read::GzDecoder::new(data);
        let mut out = Vec::new();
        d.read_to_end(&mut out).map_err(|e| format!("gzip: {}", e))?;
        Ok(out)
    } else if name.ends_with(".xz") {
        Err("xz-compressed deb (no decoder available)".into())
    } else if name.ends_with(".tar") {
        Ok(data.to_vec())
    } else {
        Err(format!("unsupported data member: {}", name))
    }
}

/// Download `pkg` and return `(deb_bytes, its data.tar member name, tar bytes)`.
///
/// Searches `mirror.components` in order, so a component change between
/// releases does not break the lookup.
fn fetch_data_tar(
    pkg: &str,
    mirror: &Mirror,
    suite: &str,
    arch: &str,
) -> Result<(Vec<u8>, String, Vec<u8>), String> {
    let mut pool_path = None;
    for component in mirror.components {
        if let Some(p) = resolve_pool_path(pkg, mirror, suite, component, arch) {
            pool_path = Some(p);
            break;
        }
    }
    let pool_path = pool_path.ok_or_else(|| {
        format!(
            "{} is in none of {}/{} on {}; cannot resolve a download URL",
            pkg,
            suite,
            mirror.components.join(", "),
            mirror.root
        )
    })?;
    let url = format!("{}/{}", mirror.root, pool_path);
    let deb = crate::net::get(&url, crate::net::user_agent())
        .map_err(|e| format!("download {} failed: {}", pkg, e))?
        .body;
    if deb.is_empty() {
        return Err(format!("{} downloaded empty", pkg));
    }
    let members = parse_ar(&deb)?;
    let data_member = members
        .iter()
        .find(|m| m.name.starts_with("data.tar"))
        .ok_or_else(|| format!("{} has no data.tar member", pkg))?;
    let name = data_member.name.clone();
    let tar = decompress_data_tar(&name, &data_member.data)?;
    Ok((deb, name, tar))
}

/// Every file in a package's data tar, as `(path, data)`.
///
/// Symlinks are NOT followed here (the tar crate would need the target bytes);
/// the Debian convention is that `libfoo.so.2` is a symlink to
/// `libfoo.so.2.0.5`, so a real file of the wanted name may be a versioned
/// sibling. `pick_by_soname` resolves that.
fn read_tar_files(tar_bytes: &[u8]) -> Result<Vec<(String, Vec<u8>)>, String> {
    let mut ar = tar::Archive::new(std::io::Cursor::new(tar_bytes.to_vec()));
    let mut out = Vec::new();
    for entry in ar.entries().map_err(|e| format!("tar: {}", e))? {
        let mut entry = entry.map_err(|e| format!("tar entry: {}", e))?;
        let path = entry
            .path()
            .map_err(|e| format!("tar path: {}", e))?
            .to_string_lossy()
            .into_owned();
        let kind = entry.header().entry_type();
        if kind.is_dir() || kind.is_symlink() || kind.is_hard_link() {
            continue; // resolved by pick_by_soname
        }
        if !kind.is_file() {
            continue;
        }
        let mut data = Vec::new();
        entry
            .read_to_end(&mut data)
            .map_err(|e| format!("read {}: {}", path, e))?;
        out.push((path, data));
    }
    Ok(out)
}

/// Find the real file providing soname `want` among a package's files.
///
/// Debian ships `libfoo.so.2 -> libfoo.so.2.0.5`, so the exact name is usually a
/// symlink and the payload is the versioned file beside it. Prefer an exact
/// real-file match; otherwise take the HIGHEST version suffix.
///
/// "Highest" is a numeric component-wise compare, not a string compare: a
/// package can legitimately ship `libfoo.so.2.0.5` and `libfoo.so.2.10.0`, and
/// picking by length or lexicographically would choose between them by accident
/// (`"2.0.5" > "2.10.0"` as strings, and the two above are the same length).
fn pick_by_soname(files: &[(String, Vec<u8>)], want: &str) -> Option<usize> {
    if let Some(i) = files.iter().position(|(p, _)| p.rsplit('/').next() == Some(want)) {
        return Some(i);
    }
    let prefix = format!("{}.", want);
    let mut best: Option<(usize, &str)> = None;
    for (i, (p, _)) in files.iter().enumerate() {
        let Some(base) = p.rsplit('/').next() else { continue };
        let Some(rest) = base.strip_prefix(&prefix) else { continue };
        match best {
            Some((_, b_rest)) if cmp_versions(rest, b_rest) != std::cmp::Ordering::Greater => {}
            _ => best = Some((i, rest)),
        }
    }
    best.map(|(i, _)| i)
}

/// Compare two dot-separated version tails numerically, component by component.
/// A non-numeric component sorts before a numeric one (so `1.0.rc1` precedes
/// `1.0.1`), which is arbitrary but deterministic - the point is only to be
/// stable, not to implement dpkg's version comparison.
fn cmp_versions(a: &str, b: &str) -> std::cmp::Ordering {
    use std::cmp::Ordering;
    let mut ai = a.split('.');
    let mut bi = b.split('.');
    loop {
        match (ai.next(), bi.next()) {
            (None, None) => return Ordering::Equal,
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(x), Some(y)) => {
                let xn = x.parse::<u64>();
                let yn = y.parse::<u64>();
                let ord = match (xn, yn) {
                    (Ok(p), Ok(q)) => p.cmp(&q),
                    (Ok(_), Err(_)) => Ordering::Greater,
                    (Err(_), Ok(_)) => Ordering::Less,
                    (Err(_), Err(_)) => x.cmp(y),
                };
                if ord != Ordering::Equal {
                    return ord;
                }
            }
        }
    }
}

/// Stage `wanted_files` (by basename) plus every soname in `LIBS` that
/// `pkg` PROVIDES, writing each under `lib/` (libraries) or `bin/`
/// (executables).
///
/// `pkg` scopes the library pass on purpose. This used to iterate the whole
/// `LIBS` table, so staging `fatresize`'s binary also demanded
/// libparted.so.2 / libcap.so.2 / libpcre2-8.so.0 from fatresize's own file
/// list - libraries of six other packages, which it does not ship (MEASURED:
/// the noble deb's data.tar holds exactly ./usr/sbin/ and ./usr/sbin/fatresize).
/// That aborted the install with "libparted.so.2 not found in the package".
/// The library closure is fetched per-provider by `fetch_f2fs_tools`, so a
/// binary-only package must contribute binaries only.
///
/// `LIBS` is `(soname, providing package)`, so the filter is an exact package
/// match - a package never picks up a neighbour's soname.
fn stage_from(
    pkg: &str,
    files: &[(String, Vec<u8>)],
    wanted_files: &[&str],
    stage: &mut BTreeMap<String, Vec<u8>>,
) -> Result<usize, String> {
    let mut n = 0;
    for want in wanted_files {
        let hit = files
            .iter()
            .find(|(p, _)| p.rsplit('/').next() == Some(*want));
        let Some((path, data)) = hit else {
            return Err(format!("{} not found in the package", want));
        };
        // Debian uses ./usr/sbin/... ; the initrd wants plain names on PATH.
        let dest = if *want == "mkfs.f2fs" || *want == "fatresize" {
            format!("usr/sbin/{}", want)
        } else {
            format!("bin/{}", want)
        };
        let _ = path;
        stage.insert(dest, data.clone());
        n += 1;
    }
    for (soname, _provider) in LIBS.iter().filter(|(_, p)| *p == pkg) {
        let Some(idx) = pick_by_soname(files, soname) else {
            return Err(format!("{} missing from {}", soname, pkg));
        };
        // Keep the payload under the SONAME, not its versioned real name: the
        // loader asks for `libfoo.so.2`, and a symlink is not worth carrying.
        stage.insert(format!("lib/{}", soname), files[idx].1.clone());
        n += 1;
    }
    Ok(n)
}

/// Fetch and stage the F2FS tools, returning `(staged files, report lines)`
/// where each staged file is `(path -> bytes)` keyed by its initrd path.
///
/// `Err` means the tools could not be obtained - the caller decides whether
/// that is fatal (it is, when the user selected f2fs: failing at install time
/// beats a silent no-op on first boot).
pub fn fetch_f2fs_tools(
    vol_letter: &str,
    mirror: &Mirror,
    suite: &str,
    arch: &str,
) -> Result<(BTreeMap<String, Vec<u8>>, Vec<String>), String> {
    let _ = vol_letter;
    let mut report = Vec::new();
    let mut stage: BTreeMap<String, Vec<u8>> = BTreeMap::new();

    report.push(format!(
        "  archive {} (suite {}, arch {}, components {})",
        mirror.root,
        suite,
        arch,
        mirror.components.join(", ")
    ));

    // 1. The tools themselves.
    for pkg in WANTED {
        let (deb, _name, tar) = fetch_data_tar(pkg, mirror, suite, arch)?;
        report.push(format!("  {} ({} bytes)", pkg, deb.len()));
        let files = read_tar_files(&tar)?;
        let bins = wanted_binaries(pkg);
        // `pkg` scopes the library half to whatever THIS package provides.
        stage_from(pkg, &files, bins, &mut stage)?;
    }

    // 2. The library closure fatresize needs and casper's initrd lacks.
    //    Each soname is fetched from the package the table names, so a
    //    provider's data.tar yields its own soname and nothing else.
    for (soname, pkg) in LIBS {
        let (_deb, _name, tar) = fetch_data_tar(pkg, mirror, suite, arch)?;
        let files = read_tar_files(&tar)?;
        let Some(idx) = pick_by_soname(&files, soname) else {
            return Err(format!(
                "{} missing from {} - the provider no longer ships it",
                soname, pkg
            ));
        };
        stage.insert(format!("lib/{}", soname), files[idx].1.clone());
    }

    // 3. Sanity: the staged set must contain every tool the hook calls by
    // name, and must not rely on a library we did not stage or the initrd is
    // known to have. A silent gap here is the failure that cost several QEMU
    // iterations (an `od` that cannot load looks exactly like an absent one).
    for want in ["mkfs.f2fs", "fatresize", "sfdisk", "od"] {
        let have = stage
            .keys()
            .any(|k| k.rsplit('/').next() == Some(want));
        if !have && want != "sfdisk" {
            return Err(format!("{} was not staged; the hook would skip", want));
        }
    }

    if stage.is_empty() {
        return Err("no tool binaries or libraries extracted".into());
    }

    // The tools go into the initrd as PLAIN cpio members at their final paths.
    //
    // Not a tarball, and not a self-extracting script, because the guest cannot
    // unpack either: casper's initrd has `gzip` and `cpio` but NO `tar`, and
    // its busybox has no `untar` applet (all measured on the real Mint 22.3
    // initrd - a QEMU boot logged `tar: not found` and skipped). The one thing
    // that definitely works is the thing the kernel already does for us: it
    // unpacks every initramfs member onto the root filesystem. So each file IS
    // a member, at the path the dynamic loader will look for it.
    //
    // `stage_f2fs_initrd_members` turns this map into cpio entries.
    report.push(format!(
        "  {} files staged as initrd members (no tar/gzip needed at boot)",
        stage.len()
    ));
    log(&format!("staged {} files for the initrd hook", stage.len()));
    Ok((stage, report))
}

/// Where each staged file must land in the unpacked initramfs.
///
/// `mkfs.f2fs` and `fatresize` go under `usr/sbin` (where the hook looks for
/// executables); `od` under `usr/bin`, because it is a general utility rather
/// than a system tool and the hook's PATH covers both. Libraries go under
/// `usr/lib` AND `usr/lib/x86_64-linux-gnu`, because the loader searches both
/// and the hook's LD_LIBRARY_PATH points at the same places.
pub fn stage_f2fs_initrd_members(stage: &BTreeMap<String, Vec<u8>>) -> Vec<(String, Vec<u8>, u32)> {
    let mut out = Vec::new();
    for (path, data) in stage {
        match path.strip_prefix("lib/") {
            Some(soname) => {
                // The soname is what the loader asks for, so that is the name.
                for dir in ["usr/lib", "usr/lib/x86_64-linux-gnu"] {
                    out.push((format!("{}/{}", dir, soname), data.clone(), 0o100644));
                }
            }
            None => {
                let base = path.rsplit('/').next().unwrap_or("");
                let exec = matches!(base, "mkfs.f2fs" | "fatresize" | "od");
                let dest = if base == "od" {
                    // coreutils ships it in bin/; keep it there so PATH finds it.
                    path.replacen("usr/sbin/", "usr/bin/", 1)
                } else {
                    path.clone()
                };
                // cpio needs the file-TYPE bits: a bare 0o755 is not a regular
                // file to the unpacker, and the kernel silently skips it.
                out.push((dest, data.clone(), if exec { 0o100755 } else { 0o100644 }));
            }
        }
    }
    out
}

/// Binaries each package provides that the hook calls by name.
///
/// `coreutils` is a large package; only `od` is taken from it (see `WANTED`).
fn wanted_binaries(pkg: &str) -> &'static [&'static str] {
    match pkg {
        "f2fs-tools" => &["mkfs.f2fs"],
        "fatresize" => &["fatresize"],
        "coreutils" => &["od"],
        _ => &[],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn staging_a_binary_package_never_asks_it_for_libraries() {
        // BUG (observed 2026-10-03: "libparted.so.2 not found in the
        // package", immediately after the suite-name fix let resolution
        // proceed as far as the archive).
        //
        // `stage_from` is called once per WANTED package with that package's
        // files, but its library loop iterated the WHOLE `LIBS` table:
        //
        //     for (soname, _pkg) in LIBS { pick_by_soname(files, soname) ... }
        //
        // So `fatresize`'s file list was asked for libparted.so.2,
        // libcap.so.2, libpcre2-8.so.0 - libraries belonging to six other
        // packages. MEASURED against the real noble deb
        // (fatresize_1.1.0-2build2_amd64.deb, 11136 bytes): its data.tar
        // contains EXACTLY two entries, ./usr/sbin/ and ./usr/sbin/fatresize.
        // It ships no shared library at all - they are dependencies, not
        // members - so the lookup failed and the whole install aborted with
        // an error naming a library fatresize was never going to contain.
        //
        // The provider table is already correct (MEASURED: each soname is in
        // the deb the table names - libparted.so.2.0.5 in libparted2t64,
        // libcap.so.2.66 in libcap2, and so on); the loop just asked the
        // wrong package. The fix is to stage the binaries and nothing else,
        // leaving the library closure to the per-library pass in
        // `fetch_f2fs_tools`, which already fetches each provider itself.
        let fatresize_files = vec![
            ("usr/sbin/".to_string(), Vec::new()),
            ("usr/sbin/fatresize".to_string(), vec![0x7f, b'E', b'L', b'F']),
        ];
        let mut stage = BTreeMap::new();
        stage_from("fatresize", &fatresize_files, &["fatresize"], &mut stage)
            .expect("a binary-only package must stage cleanly");
        assert_eq!(
            stage.keys().cloned().collect::<Vec<_>>(),
            vec!["usr/sbin/fatresize".to_string()],
            "only the binary may be staged"
        );

        // The converse still has to hold: a library package DOES yield its
        // sonames, resolved through the versioned real file (Debian ships
        // `libfoo.so.2` as a symlink, and read_tar_files skips symlinks).
        let parted_files = vec![
            ("usr/lib/x86_64-linux-gnu/libparted.so.2.0.5".to_string(), vec![0x7f, b'E', b'L', b'F', b'D']),
        ];
        let mut stage2 = BTreeMap::new();
        let n = stage_from("libparted2t64", &parted_files, &[], &mut stage2)
            .expect("provider must yield its soname");
        assert!(stage2.contains_key("lib/libparted.so.2"), "got {:?}", stage2.keys().collect::<Vec<_>>());
        assert_eq!(n, 1);

        // And a package that genuinely lacks the soname still fails loudly -
        // the guard must not become a silent skip.
        let mut stage3 = BTreeMap::new();
        let e = stage_from("libparted2t64", &parted_files, &["mkfs.f2fs"], &mut stage3)
            .expect_err("a missing binary must stay an error");
        assert!(e.contains("mkfs.f2fs"), "error must name the file: {}", e);
    }

#[test]
    fn ar_parses_a_real_deb_layout() {
        // Build a synthetic ar archive the way dpkg does: 60-byte headers,
        // even-offset padding.
        let mut buf: Vec<u8> = b"!<arch>\n".to_vec();
        for (name, body) in [
            ("debian-binary", &b"2.0\n"[..]),
            ("control.tar.zst", &b"CONTROL"[..]),
            ("data.tar.zst", &[0u8, 1, 2, 3, 4][..]),
        ] {
            let mut hdr = [b' '; 60];
            hdr[..name.len()].copy_from_slice(name.as_bytes());
            let sz = format!("{}", body.len());
            hdr[48..48 + sz.len()].copy_from_slice(sz.as_bytes());
            buf.extend_from_slice(&hdr);
            buf.extend_from_slice(body);
            if body.len() % 2 == 1 {
                buf.push(b'\n'); // odd-size members are padded
            }
        }
        let m = parse_ar(&buf).unwrap();
        assert_eq!(m.len(), 3);
        assert_eq!(m[0].name, "debian-binary");
        assert_eq!(m[2].name, "data.tar.zst");
        assert_eq!(m[2].data, vec![0u8, 1, 2, 3, 4]);
    }

    #[test]
    fn ar_rejects_non_ar_input() {
        assert!(parse_ar(b"not an ar file at all").is_err());
    }

    #[test]
    fn ar_survives_a_truncated_member() {
        let mut buf: Vec<u8> = b"!<arch>\n".to_vec();
        let mut hdr = [b' '; 60];
        hdr[..7].copy_from_slice(b"data.ta");
        hdr[48..51].copy_from_slice(b"999");
        buf.extend_from_slice(&hdr);
        buf.extend_from_slice(b"short");
        // Must not panic or over-read.
        let m = parse_ar(&buf).unwrap();
        assert_eq!(m.len(), 1);
        assert_eq!(m[0].data, b"short".to_vec());
    }

    #[test]
    fn data_member_compression_is_detected_by_name() {
        // A plain .tar passes through; .zst/.gz are actually decompressed.
        let plain = b"hello".to_vec();
        assert_eq!(decompress_data_tar("data.tar", &plain).unwrap(), plain);
        assert!(decompress_data_tar("control.tar.zst", &plain).is_err());
    }

    #[test]
    fn only_the_named_tools_are_staged() {
        assert_eq!(wanted_binaries("f2fs-tools"), &["mkfs.f2fs"]);
        assert_eq!(wanted_binaries("fatresize"), &["fatresize"]);
        // coreutils is huge; only od is taken from it.
        assert_eq!(wanted_binaries("coreutils"), &["od"]);
        assert!(wanted_binaries("something-else").is_empty());
    }

    /// The initrd has no `od`, so it must be staged or the hook's corruption
    /// guard silently never runs - which looks exactly like a clean skip.
    #[test]
    fn od_is_staged_because_the_initrd_has_none() {
        assert!(
            WANTED.contains(&"coreutils"),
            "od must be staged: casper's initrd has no od/hexdump/xxd, binary or applet"
        );
        assert!(wanted_binaries("coreutils").contains(&"od"));
    }

    /// `od` is a general utility: it must land in usr/bin (where PATH looks),
    /// while the system tools go to usr/sbin. Getting this wrong produces an
    /// `od` that exists but is never found.
    #[test]
    fn od_lands_in_usr_bin_and_the_tools_in_usr_sbin() {
        use std::collections::BTreeMap;
        let mut stage = BTreeMap::new();
        stage.insert("usr/sbin/od".to_string(), vec![0u8]);
        stage.insert("usr/sbin/mkfs.f2fs".to_string(), vec![0u8]);
        stage.insert("usr/sbin/fatresize".to_string(), vec![0u8]);
        let members = stage_f2fs_initrd_members(&stage);
        let find = |name: &str| {
            members
                .iter()
                .find(|(p, _, _)| p.rsplit('/').next() == Some(name))
                .map(|(p, _, m)| (p.clone(), *m))
        };
        let (od_path, od_mode) = find("od").expect("od must be staged");
        assert_eq!(od_path, "usr/bin/od", "od must be on the hook's PATH");
        assert_eq!(od_mode, 0o100755, "od must be executable");
        assert_eq!(find("mkfs.f2fs").unwrap().0, "usr/sbin/mkfs.f2fs");
        assert_eq!(find("fatresize").unwrap().0, "usr/sbin/fatresize");
    }

    /// The Debian layout that makes naive extraction fail: the soname the loader
    /// asks for is a SYMLINK, and the real payload is the versioned file beside
    /// it. A `.so` is almost never shipped under its own plain name.
    #[test]
    fn soname_resolution_finds_the_versioned_payload() {
        let files = vec![
            ("usr/lib/x86_64-linux-gnu/libparted.so.2.0.5".to_string(), vec![1u8, 2, 3]),
            ("usr/lib/x86_64-linux-gnu/libparted.so.2.5.0".to_string(), vec![9u8]),
        ];
        let hit = pick_by_soname(&files, "libparted.so.2").expect("must resolve");
        assert_eq!(files[hit].1, vec![9u8], "2.5.0 outranks 2.0.5");
    }

    /// The case that caught the first implementation: equal-length tails and a
    /// lexicographic order that inverts the numeric one. `10` > `9` as numbers,
    /// but `"10" < "9"` as text, so a string compare picks the OLDER library.
    #[test]
    fn soname_resolution_compares_versions_numerically() {
        let files = vec![
            ("lib/libfoo.so.2.9.0".to_string(), vec![1u8]),
            ("lib/libfoo.so.2.10.0".to_string(), vec![2u8]),
        ];
        let hit = pick_by_soname(&files, "libfoo.so.2").expect("must resolve");
        assert_eq!(files[hit].1, vec![2u8], "2.10.0 outranks 2.9.0 despite sorting lower as text");
    }

    #[test]
    fn version_compare_orders_components_numerically() {
        use std::cmp::Ordering;
        assert_eq!(cmp_versions("10.0", "9.0"), Ordering::Greater);
        assert_eq!(cmp_versions("2.0.5", "2.0.5"), Ordering::Equal);
        assert_eq!(cmp_versions("1.2", "1.2.3"), Ordering::Less);
        assert_eq!(cmp_versions("3.0.1", "3.0.rc1"), Ordering::Greater);
    }

    #[test]
    fn soname_resolution_prefers_an_exact_real_file() {
        let files = vec![
            ("lib/libuuid.so.1.3.0".to_string(), vec![7u8]),
            ("lib/libuuid.so.1".to_string(), vec![8u8]),
        ];
        let hit = pick_by_soname(&files, "libuuid.so.1").expect("must resolve");
        assert_eq!(files[hit].0, "lib/libuuid.so.1", "an exact real file beats a versioned one");
    }

    #[test]
    fn soname_resolution_reports_a_miss_rather_than_guessing() {
        let files = vec![("lib/libc.so.6".to_string(), vec![0u8])];
        assert!(pick_by_soname(&files, "libparted.so.2").is_none());
    }

    #[test]
    fn every_declared_library_has_a_provider_package() {
        // A typo in LIBS would only show up as a download failure at install
        // time, which is exactly when we cannot afford it.
        assert_eq!(LIBS.len(), 6);
        for (soname, pkg) in LIBS {
            assert!(!pkg.is_empty(), "{} has no provider", soname);
            assert!(pkg.contains(|c: char| c.is_ascii_alphanumeric()), "{}: odd pkg name", pkg);
        }
        // The noble 64-bit-time_t rename - the packages are NOT "libparted".
        assert!(LIBS.iter().any(|(_, p)| *p == "libparted2t64"));
        assert!(LIBS.iter().any(|(_, p)| *p == "libparted-fs-resize0t64"));
    }

    #[test]
    fn unreadable_iso_resolves_no_suite_instead_of_guessing_noble() {
        // A missing ISO must not panic or hang. It must NOT resolve to `noble`
        // either: that fallback is what made a non-Ubuntu ISO build an Ubuntu
        // URL. No suite => no mirror => an explicit error at the call site.
        assert_eq!(suite_from_iso("Z:\\no\\such\\file.iso"), None);
        let e = mirror_for_iso("Z:\\no\\such\\file.iso").unwrap_err();
        assert!(e.contains("dists/"), "error must say why: {}", e);
    }

    #[test]
    fn each_suite_resolves_to_the_archive_that_actually_serves_it() {
        // Debian codenames must never be looked up on Ubuntu's archive: that
        // URL cannot exist and 404s with nothing legible.
        for suite in ["trixie", "bookworm", "forky"] {
            let m = mirror_for_suite(suite).expect("debian suite must resolve");
            assert_eq!(m.root, "https://deb.debian.org/debian", "{} -> wrong mirror", suite);
            assert_eq!(m.components, &["main"], "{} must not query universe", suite);
        }
        // Ubuntu suite => Ubuntu archive, both components.
        let m = mirror_for_suite("noble").expect("noble must resolve");
        assert_eq!(m.root, "http://archive.ubuntu.com/ubuntu");
        assert_eq!(m.components, &["main", "universe"]);
    }

    #[test]
    fn an_unknown_suite_resolves_to_no_mirror_rather_than_ubuntus() {
        // The negative case the whole resolver exists for.
        for suite in ["trixie-backports", "not-a-suite", "", "noble-updates"] {
            assert!(
                mirror_for_suite(suite).is_none(),
                "{} must not resolve - guessing sends it to the wrong archive",
                suite
            );
        }
    }

    #[test]
    fn an_iso9660_uppercase_suite_resolves_and_produces_a_lowercase_url() {
        // BUG (observed 2026-10-03: "F2FS persistence was selected but its
        // boot-time tools could not be prepared ('NOBLE' is not a suite this
        // build knows how to query)").
        //
        // `suite_from_iso` returns the name straight out of the ISO's ISO9660
        // directory record, and ISO9660 names are UPPERCASE by spec: a Mint /
        // Zorin image really does yield "NOBLE", not "noble". The resolver's
        // tables are lowercase, and `contains(&suite)` is an exact match, so
        // every uppercase suite fell through to the "refusing to guess"
        // error - while `main.rs`'s ISO check compared with
        // `eq_ignore_ascii_case` and happily confirmed the very same image as
        // "Ubuntu 24.04 based, supported". Two modules disagreed about the
        // same string.
        //
        // Canonicalisation must happen at RESOLUTION time, not only in the
        // matcher: the archive serves `dists/noble/...` and 404s on
        // `dists/NOBLE/...` (MEASURED against archive.ubuntu.com: lowercase
        // HTTP 200, uppercase HTTP 404), and the suite is interpolated
        // straight into that URL by resolve_pool_path. Matching case-
        // insensitively while keeping the uppercase name would turn the
        // refusal into a silent 404 instead.
        let canon = canonical_suite("NOBLE").expect("ISO9660 uppercase must canonicalise");
        assert_eq!(canon, "noble", "the URL must carry the lowercase suite");
        assert_eq!(
            mirror_for_suite(&canon).map(|m| m.root),
            Some("http://archive.ubuntu.com/ubuntu"),
            "NOBLE must reach the Ubuntu archive, not be refused"
        );
        // Every recognised suite, in the casing an ISO actually stores.
        for suite in ["noble", "jammy", "focal", "mantic", "oracular", "plucky", "questing", "devel"] {
            let up = suite.to_ascii_uppercase();
            assert_eq!(
                canonical_suite(&up).as_deref(),
                Some(suite),
                "{} must canonicalise to {}",
                up,
                suite
            );
        }
        for suite in ["bookworm", "trixie", "forky"] {
            let up = suite.to_ascii_uppercase();
            assert_eq!(canonical_suite(&up).as_deref(), Some(suite), "{}", up);
            assert_eq!(
                mirror_for_suite(&canonical_suite(&up).unwrap()).map(|m| m.root),
                Some("https://deb.debian.org/debian"),
                "{} must reach Debian, not Ubuntu",
                up
            );
        }
        // Canonicalisation must not widen the accepted set: the whole point
        // of the explicit tables is that an unknown suite is refused.
        for bad in ["TRIXIE-BACKPORTS", "NOBLE-UPDATES", "NOT-A-SUITE", ""] {
            assert!(
                canonical_suite(bad).is_none(),
                "{} must stay refused - case folding must not smuggle it in",
                bad
            );
        }
        // The URL built by resolve_pool_path must be lowercase even when the
        // name came from the ISO uppercase.
        let m = mirror_for_suite("NOBLE").expect("matcher itself must accept the ISO casing");
        let url = format!(
            "{}/dists/{}/main/binary-amd64/Packages.gz",
            m.root,
            canonical_suite("NOBLE").unwrap()
        );
        assert!(
            url.contains("/dists/noble/"),
            "URL must be the one the archive serves, got {}",
            url
        );
    }

    #[test]
    fn the_index_url_can_only_ever_name_its_own_mirrors_suite() {
        // Build the URL the way resolve_pool_path does and assert the
        // cross-distro combination is unreachable: a Debian suite under the
        // Ubuntu root, or an Ubuntu suite under the Debian root.
        let trixie = mirror_for_suite("trixie").unwrap();
        let noble = mirror_for_suite("noble").unwrap();
        let bad1 = format!("{}/dists/{}/main/binary-amd64/Packages.gz", noble.root, "trixie");
        let bad2 = format!("{}/dists/{}/main/binary-amd64/Packages.gz", trixie.root, "noble");
        assert!(!noble.root.contains("trixie") && !bad1.contains("deb.debian.org"));
        assert!(!trixie.root.contains("noble") && !bad2.contains("archive.ubuntu.com"));
    }

    #[test]
    fn the_cache_key_separates_mirrors_suites_components_and_arches() {
        // The old key was `{suite}-{component}`, shared byte-identically with
        // hardware.rs - so one distro's index was served for another's.
        let ub = mirror_for_suite("noble").unwrap();
        let db = mirror_for_suite("trixie").unwrap();
        let keys = [
            apt_cache_name(&ub, "noble", "main", "amd64"),
            apt_cache_name(&db, "noble", "main", "amd64"),
            apt_cache_name(&ub, "trixie", "main", "amd64"),
            apt_cache_name(&ub, "noble", "universe", "amd64"),
            apt_cache_name(&ub, "noble", "main", "i386"),
        ];
        for i in 0..keys.len() {
            for j in (i + 1)..keys.len() {
                assert_ne!(keys[i], keys[j], "cache key collision: {}", keys[i]);
            }
        }
// The host is reduced to [a-z0-9-] so it is a legal filename on a
        // case-insensitive volume; assert the DISTINCTION, not a literal dot.
        assert!(keys[0].contains("archive-ubuntu-com"), "{}", keys[0]);
        assert!(keys[1].contains("deb-debian-org"), "{}", keys[1]);
    }

    #[test]
    fn the_index_arch_follows_the_selected_distro() {
        // A 32-bit ISO cannot run an amd64 binary, so the arch is part of the
        // URL. antiX / Tiny Core are i386.
        assert_eq!(apt_arch_for(Some("i686")), "i386");
        assert_eq!(apt_arch_for(Some("i386")), "i386");
        assert_eq!(apt_arch_for(Some("x86_64")), "amd64");
        assert_eq!(apt_arch_for(None), "amd64");
    }
}