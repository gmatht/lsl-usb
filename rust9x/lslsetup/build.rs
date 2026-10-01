// Compiles the lsl-hw-cache snapshot (../../lsl-hw-cache/*.html) into a
// compact per-device summary embedded in the binary, so common hardware is
// rated instantly with no network request (the live linux-hardware.org path
// has a 10s crawl-delay per device).

use std::env;
use std::fs;
use std::path::Path;

fn find_between<'a>(s: &'a str, start: &str, end: &str) -> Option<&'a str> {
    let i = s.find(start)? + start.len();
    let rest = &s[i..];
    let j = rest.find(end)?;
    Some(&rest[..j])
}

/// Same heuristics as the runtime parser in src/hardware.rs.
fn parse_page(html: &str) -> (String, String, String, Vec<String>) {
    let mut name = String::new();
    let mut ksup = String::new();
    let mut src = String::new();
    let mut third = Vec::new();

    if let Some(n) = find_between(html, "<h2 class='top'>Device '", "'") {
        name = n.to_string();
    }
    if let Some(k) = find_between(html, "supported by kernel versions <a", "</a>") {
        let k = match k.find('>') {
            Some(i) => &k[i + 1..],
            None => k,
        };
        ksup = k.to_string();
    }
    if let Some(seg) = find_between(html, "&nbsp;-&nbsp;</td>", "</td><td>") {
        src = seg.to_string();
    } else if let Some(seg) = find_between(html, "<td>", "</td>") {
        if seg.chars().next().map(|c| c.is_ascii_digit()).unwrap_or(false) {
            src = seg.to_string();
        }
    }
    let mut from = 0;
    while let Some(rel) = html[from..].find("<a href=\"https://github.com/") {
        let start = from + rel + "<a href=\"https://github.com/".len();
        let rest = &html[start..];
        if let Some(q) = rest.find('"') {
            third.push(rest[..q].to_string());
            from = start + q;
        } else {
            break;
        }
    }
    (name, ksup, src, third)
}

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    let manifest = env::var("CARGO_MANIFEST_DIR").unwrap();

    // ---- Embedded z0 firstboot layer freshness (WHYFAIL10) -----------------
    // src/lslfiles.rs embeds assets/filesystem.z0.squashfs with include_bytes!,
    // which makes cargo depend on the BLOB, not on the misc/ sources it was
    // packed from. So editing misc/ used to reship a stale firstboot layer
    // silently (the firstboot progress dialog stayed broken for ~14h despite
    // the fix being in misc/). assets/z0_sources.sha256 is rewritten by
    // misc/build-z0.sh every time the blob is regenerated; re-hashing each
    // listed source here fails the build if any has drifted since. Regenerate
    // with `bash misc/build-z0.sh` (WSL/Linux; needs squashfs-tools).
    {
        println!("cargo:rerun-if-changed=assets/filesystem.z0.squashfs");
        println!("cargo:rerun-if-changed=assets/z0_sources.sha256");
        println!("cargo:rerun-if-changed=../../misc/build-z0.sh");
        let blob_path = Path::new(&manifest).join("assets").join("filesystem.z0.squashfs");
        let blob = fs::read(&blob_path)
            .unwrap_or_else(|e| panic!("read {}: {}", blob_path.display(), e));
        assert!(
            blob.len() >= 4096 && blob[0..4] == [0x68, 0x73, 0x71, 0x73],
            "assets/filesystem.z0.squashfs is not a squashfs blob (bad magic/size)"
        );
        let man_path = Path::new(&manifest).join("assets").join("z0_sources.sha256");
        let man = fs::read_to_string(&man_path).unwrap_or_else(|e| {
            panic!(
                "missing {} ({}) - regenerate the embedded z0 layer with `bash misc/build-z0.sh`",
                man_path.display(),
                e
            )
        });
        let repo_root = Path::new(&manifest).join("..").join("..");
        let mut stale: Vec<String> = Vec::new();
        let mut sources = 0usize;
        for line in man.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let Some((want, rel)) = line.split_once("  ") else {
                panic!("malformed assets/z0_sources.sha256 line: {:?}", line);
            };
            println!("cargo:rerun-if-changed=../../{}", rel);
            sources += 1;
            match fs::read(repo_root.join(rel)) {
                Ok(bytes) => {
                    use sha2::Digest;
                    let mut h = sha2::Sha256::new();
                    h.update(&bytes);
                    if format!("{:x}", h.finalize()) != want {
                        stale.push(rel.to_string());
                    }
                }
                Err(_) => stale.push(format!("{} (missing)", rel)),
            }
        }
        assert!(sources > 0, "assets/z0_sources.sha256 lists no sources");
        assert!(
            stale.is_empty(),
            "STALE embedded z0 firstboot layer (WHYFAIL10): {} source(s) changed since the \
             blob was packed: {}. Regenerate with `bash misc/build-z0.sh` and commit BOTH \
             assets/filesystem.z0.squashfs and assets/z0_sources.sha256.",
            stale.len(),
            stale.join(", ")
        );
        println!(
            "cargo:warning=embedded z0 layer is fresh ({} sources verified)",
            sources
        );
    }

    // ---- Embedded firstboot toolkit freshness (WHYFAIL13 follow-up) --------
    // FIRSTBOOT_TOOLKIT in src/lslfiles.rs include_str!s 36 repo files, and the
    // nofmt installer writes the stick's /cdrom/bin, /cdrom/fuse and
    // /cdrom/systemd from that array ALONE. include_str! makes cargo depend on
    // each source file, so an incremental *rebuild* picks up an edit - but a
    // prebuilt or committed lslsetup.exe keeps embedding whatever was current
    // when it was compiled, and nothing detected that. On 2026-10-01 every
    // shipped .exe still embedded the broken bin/lsl-pin-favorites (it split
    // `gsettings get` string-arrays on newlines, collapsing the whole favorites
    // list into one unresolvable element and dropping every pinned app from the
    // panel) while the fix sat in bin/ unshipped - "rebuild the exe" was the
    // only step, and it was invisible. assets/toolkit_sources.sha256 is
    // regenerated by misc/build-toolkit-manifest.sh; re-hashing each listed
    // source here fails the build if any has drifted since.
    {
        println!("cargo:rerun-if-changed=assets/toolkit_sources.sha256");
        println!("cargo:rerun-if-changed=../../misc/build-toolkit-manifest.sh");
        let tk_path = Path::new(&manifest)
            .join("assets")
            .join("toolkit_sources.sha256");
        let tk = fs::read_to_string(&tk_path).unwrap_or_else(|e| {
            panic!(
                "missing {} ({}) - regenerate with `bash misc/build-toolkit-manifest.sh`",
                tk_path.display(),
                e
            )
        });
        let repo_root = Path::new(&manifest).join("..").join("..");
        let mut tk_stale: Vec<String> = Vec::new();
        let mut tk_sources = 0usize;
        for line in tk.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let Some((want, rel)) = line.split_once("  ") else {
                panic!("malformed assets/toolkit_sources.sha256 line: {:?}", line);
            };
            println!("cargo:rerun-if-changed=../../{}", rel);
            tk_sources += 1;
            match fs::read(repo_root.join(rel)) {
                Ok(bytes) => {
                    use sha2::Digest;
                    let mut h = sha2::Sha256::new();
                    h.update(&bytes);
                    if format!("{:x}", h.finalize()) != want {
                        tk_stale.push(rel.to_string());
                    }
                }
                Err(_) => tk_stale.push(format!("{} (missing)", rel)),
            }
        }
        assert!(
            tk_sources > 0,
            "assets/toolkit_sources.sha256 lists no sources"
        );
        assert!(
            tk_stale.is_empty(),
            "STALE embedded firstboot toolkit (WHYFAIL13 follow-up): {} source(s) changed \
             since the manifest was generated: {}. The built lslsetup.exe would write the \
             OLD content to the stick. Regenerate with `bash misc/build-toolkit-manifest.sh` \
             and commit assets/toolkit_sources.sha256, then rebuild the exe.",
            tk_stale.len(),
            tk_stale.join(", ")
        );
        println!(
            "cargo:warning=embedded firstboot toolkit is fresh ({} sources verified)",
            tk_sources
        );
    }

    let cache_dir = Path::new(&manifest).join("..").join("..").join("lsl-hw-cache");
    let mut entries: Vec<(String, String, String, String, Vec<String>)> = Vec::new();
    if let Ok(rd) = fs::read_dir(&cache_dir) {
        let mut files: Vec<_> = rd
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.extension().map(|e| e == "html").unwrap_or(false))
            .collect();
        files.sort();
        for p in files {
            // lsl-lhw-<kind>-<vid>-<did>.html  ->  <kind>:<vid>-<did>
            let stem = p.file_stem().unwrap().to_string_lossy().into_owned();
            let id = stem
                .strip_prefix("lsl-lhw-")
                .unwrap_or(&stem)
                .replacen('-', ":", 1);
            if !id.contains(':') {
                continue;
            }
            let Ok(html) = fs::read_to_string(&p) else { continue };
            let (name, ksup, src, third) = parse_page(&html);
            entries.push((id, name, ksup, src, third));
        }
    }

    // Optional vendored UEFI loaders embedded via OUT_DIR/uefi_embedded.rs:
    // (a) the SIGNED chain (assets/shimx64.efi.gz + grubx64.efi.gz +
    // mmx64.efi.gz - shim + Canonical-signed GRUB2; Secure Boot ON), the
    // DEFAULT loader when present, and (b) the unsigned grub4dos-for-UEFI
    // BOOTX64.EFI fallback (Secure Boot must be OFF). Absent files -> the
    // matching BUNDLED_* static is None and --uefi-bootx64 <file> remains
    // the remaining UEFI source. sha256 pins sit next to each asset; nofmt
    // refuses the bundled bytes at runtime on mismatch.
    let out_dir = env::var("OUT_DIR").unwrap();
    let uefi_src = Path::new(&manifest).join("assets").join("BOOTX64.EFI");
    let mut uefi_code = if uefi_src.is_file() {
        let bytes = fs::read(&uefi_src).unwrap();
        let pin_path = Path::new(&manifest).join("assets").join("BOOTX64.EFI.sha256");
        if pin_path.is_file() {
            let pin: String = fs::read_to_string(&pin_path)
                .unwrap()
                .chars()
                .filter(|c| !c.is_whitespace())
                .collect();
            // sha256sum without external crates: compare via a tiny check
            // done at runtime instead - embed the pin for nofmt to verify.
            let dst = Path::new(&out_dir).join("BOOTX64.EFI");
            fs::write(&dst, &bytes).unwrap();
            format!(
                "pub static BUNDLED_BOOTX64_EFI: Option<&[u8]> = Some(include_bytes!(\"{}\"));\npub static BUNDLED_BOOTX64_SHA256: Option<&str> = Some(\"{}\");\n",
                dst.to_string_lossy().replace('\\', "/"),
                pin.to_ascii_lowercase()
            )
        } else {
            let dst = Path::new(&out_dir).join("BOOTX64.EFI");
            fs::write(&dst, &bytes).unwrap();
            format!(
                "pub static BUNDLED_BOOTX64_EFI: Option<&[u8]> = Some(include_bytes!(\"{}\"));\npub static BUNDLED_BOOTX64_SHA256: Option<&str> = None;\n",
                dst.to_string_lossy().replace('\\', "/")
            )
        }
    } else {
        "pub static BUNDLED_BOOTX64_EFI: Option<&[u8]> = None;\npub static BUNDLED_BOOTX64_SHA256: Option<&str> = None;\n".to_string()
    };
    fs::write(Path::new(&out_dir).join("uefi_embedded.rs"), &uefi_code).unwrap();
    println!("cargo:rerun-if-changed=assets/BOOTX64.EFI");
    println!("cargo:rerun-if-changed=assets/BOOTX64.EFI.sha256");
    // Signed UEFI chain (Secure Boot ON): Microsoft-signed shim ->
    // Canonical-signed grub2 (+ signed MokManager), see assets/SIGNED-UEFI.txt.
    // Each assets/<name>.efi.gz is gzip -9 of the raw EFI binary; the raw
    // SHA-256 is pinned in assets/<name>.efi.sha256 (lowercase hex, whitespace
    // tolerated) and verified here, so a corrupt/foreign blob fails the build
    // instead of shipping a bootloader that cannot be trusted. A present .gz
    // WITHOUT its pin is a hard error - an unverifiable signed chain must
    // never sneak into the binary. The .gz bytes (not the raw binary) are
    // embedded via OUT_DIR and inflated once at runtime (same OnceLock
    // pattern as grldr): ~2.4 MB smaller exe for milliseconds of startup.
    // Runtime re-verifies the inflated bytes against the pin before use.
    for name in ["shimx64.efi", "grubx64.efi", "mmx64.efi"] {
        let gz_path = Path::new(&manifest).join("assets").join(format!("{}.gz", name));
        let pin_path = Path::new(&manifest).join("assets").join(format!("{}.sha256", name));
        println!("cargo:rerun-if-changed=assets/{}.gz", name);
        println!("cargo:rerun-if-changed=assets/{}.sha256", name);
        let upper = name.replace('.', "_").to_ascii_uppercase();
        let (embedded, pin_lit) = if gz_path.is_file() {
            assert!(pin_path.is_file(), "assets/{}.gz has no {}.sha256 pin - add one", name, name);
            let pin: String = fs::read_to_string(&pin_path)
                .unwrap()
                .chars()
                .filter(|c| !c.is_whitespace())
                .collect::<String>()
                .to_ascii_lowercase();
            let gz = fs::read(&gz_path).unwrap();
            let mut dec = flate2::read::GzDecoder::new(&gz[..]);
            let mut raw = Vec::new();
            use std::io::Read as _;
            dec.read_to_end(&mut raw).unwrap_or_else(|e| {
                panic!("assets/{}.gz does not inflate (not a valid gzip stream): {}", name, e)
            });
            let mut h = sha2::Sha256::new();
            use sha2::Digest as _;
            h.update(&raw);
            let hex = format!("{:x}", h.finalize());
            assert_eq!(hex, pin, "assets/{}.gz inflates to unexpected bytes (got sha256 {})", name, hex);
            assert!(
                gz.len() < raw.len(),
                "assets/{}.gz ({} bytes) is no smaller than the raw binary ({} bytes) - recompress it",
                name, gz.len(), raw.len()
            );
            let dst = Path::new(&out_dir).join(format!("{}.gz", name));
            fs::write(&dst, &gz).unwrap();
            println!("cargo:warning={} OK: {} -> {} bytes, sha256 {}", name, raw.len(), gz.len(), &hex[..16]);
            (
                format!(
                    "pub static BUNDLED_{}_GZ: Option<&[u8]> = Some(include_bytes!(\"{}\"));",
                    upper,
                    dst.to_string_lossy().replace('\\', "/")
                ),
                format!("pub static BUNDLED_{}_SHA256: Option<&str> = Some(\"{}\");", upper, pin),
            )
        } else {
            (
                format!("pub static BUNDLED_{}_GZ: Option<&[u8]> = None;", upper),
                format!("pub static BUNDLED_{}_SHA256: Option<&str> = None;", upper),
            )
        };
        uefi_code.push_str(&embedded);
        uefi_code.push('\n');
        uefi_code.push_str(&pin_lit);
        uefi_code.push('\n');
    }
    fs::write(Path::new(&out_dir).join("uefi_embedded.rs"), &uefi_code).unwrap();
    // Application manifest for rust9x targets (asInvoker: opt out of the
    // UAC installer-detection heuristic; dpiAware; supportedOS). The .res
    // was compiled once with: llvm-rc /FO src/app_manifest.res
    // src/app_manifest.rc. Emitted from the manifest dir so the link works
    // on any build machine (never hardcode an absolute path here).
    if std::env::var("TARGET").map(|t| t.contains("rust9x")).unwrap_or(false) {
        let res = Path::new(&manifest).join("src").join("app_manifest.res");
        assert!(res.is_file(), "src/app_manifest.res missing");
        println!("cargo:rerun-if-changed=src/app_manifest.res");
        println!(
            "cargo:rustc-link-arg={}",
            res.to_string_lossy().replace('\\', "/")
        );
    }
    // Verify the compressed grub4dos loader: inflate assets/grldr.gz
    // (produced with `gzip -9` + `advdef -z -4`) and check the raw bytes
    // against the pinned SHA-256 (must match GRLDR_SHA256 in src/nofmt.rs).
    // A bad blob fails the build instead of shipping a bad bootloader.
    println!("cargo:rerun-if-changed=assets/grldr.gz");
    let grldr_gz = fs::read(Path::new(&manifest).join("assets").join("grldr.gz"))
        .expect("assets/grldr.gz missing (regenerate: gzip -9 grldr, then advdef -z -4)");
    let mut dec = flate2::read::GzDecoder::new(&grldr_gz[..]);
    let mut raw = Vec::new();
    use std::io::Read;
    dec.read_to_end(&mut raw)
        .expect("assets/grldr.gz does not inflate (not a valid gzip stream)");
    let mut h = sha2::Sha256::new();
    use sha2::Digest;
    h.update(&raw);
    let hex = format!("{:x}", h.finalize());
    // Pinned raw-grldr hash (== GRLDR_SHA256 in src/nofmt.rs).
    let want = "dece3f8d20f84ae0d0fb892b5c3a2d19e7233d0d8885b0027a6f43d77239128d";
    assert_eq!(
        hex, want,
        "assets/grldr.gz inflates to unexpected bytes (got sha256 {})",
        hex
    );
    assert!(
        grldr_gz.len() < raw.len(),
        "assets/grldr.gz ({} bytes) is no smaller than the raw loader ({} bytes) - recompress it",
        grldr_gz.len(),
        raw.len()
    );
    println!(
        "cargo:warning=grldr.gz OK: {} -> {} bytes, sha256 {}",
        raw.len(),
        grldr_gz.len(),
        &hex[..16]
    );
    // Compact + gzip the snapshot: the literal table above costs ~90 KB of
    // .rdata (highly repetitive text: 9.5:1 with gzip). flate2's decoder is
    // already linked (Packages.gz), so the marginal code cost is ~nil.
    // Format per entry (one line): id \x1f name \x1f ksup \x1f src \x1f repo,repo
    fn flat(s: &str) -> String {
        s.replace('\x1f', " ").replace('\n', " ")
    }
    let mut plain = String::new();
    for (id, name, ksup, src, third) in &entries {
        plain.push_str(&flat(id));
        plain.push('\x1f');
        plain.push_str(&flat(name));
        plain.push('\x1f');
        plain.push_str(&flat(ksup));
        plain.push('\x1f');
        plain.push_str(&flat(src));
        plain.push('\x1f');
        plain.push_str(&third.iter().map(|t| flat(t)).collect::<Vec<_>>().join(","));
        plain.push('\n');
    }
    let mut enc = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::best());
    use std::io::Write;
    enc.write_all(plain.as_bytes()).unwrap();
    let gz = enc.finish().unwrap();
    let dst = Path::new(&out_dir).join("hw_cache_embedded.rs");
    let mut code = String::new();
    code.push_str("// AUTO-GENERATED by build.rs from the lsl-hw-cache snapshot (gzip).\n");
    code.push_str(&format!(
        "pub static COMPRESSED_HW_CACHE: &[u8] = &[{}];\n",
        gz.iter().map(|b| b.to_string()).collect::<Vec<_>>().join(",")
    ));
    code.push_str(&format!("pub static HW_CACHE_ENTRIES: usize = {};\n", entries.len()));
    fs::write(&dst, code).unwrap();
    println!(
        "cargo:warning=embedded LKDDb cache summary: {} devices ({} -> {} bytes)",
        entries.len(),
        plain.len(),
        gz.len()
    );
}
