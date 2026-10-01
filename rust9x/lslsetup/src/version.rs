//! Build identity: the version and git revision compiled into the exe.
//!
//! WHYFAIL16: the build stamp used to be read from `<bundle>\VERSION` and
//! `unwrap_or_default()`-ed, so the default (nofmt) path - which has no bundle -
//! produced a blank version line on every stick. `bin/lsl-diag.sh` reads that
//! stamp precisely to answer "which build is failing?", and it printed an empty
//! section, silently.
//!
//! `CARGO_PKG_VERSION` is always available, needs no staged file, and cannot be
//! empty, so it is the fallback. The bundle VERSION still wins when present: a
//! bundle build ships a VERSION that may be ahead of the crate metadata.

/// The version from Cargo.toml. Never empty.
pub const CARGO_VERSION: &str = env!("CARGO_PKG_VERSION");

/// Short git revision, or "unknown" when the build had no git available.
pub const GIT_REV: &str = match option_env!("LSL_GIT_REV") {
    Some(r) if !r.is_empty() => r,
    _ => "unknown",
};

/// One stamp line describing the revision, or nothing when it is unknown.
///
/// Returns an empty string rather than a placeholder line so a source tree built
/// without git does not claim a revision it cannot know.
pub fn git_rev_line() -> String {
    if GIT_REV == "unknown" {
        String::new()
    } else {
        format!("Rev:   {}", GIT_REV)
    }
}

/// `--version` output.
pub fn version_line() -> String {
    format!("lslsetup {} ({})", CARGO_VERSION, GIT_REV)
}

/// The version a stick should be stamped with, given an optional bundle VERSION.
///
/// Split out from the writer so it can be tested without a real filesystem: the
/// whole point of WHYFAIL16 was that the "file is missing" case and the
/// "legitimately empty" case were indistinguishable, and a unit test is where
/// that difference has to be pinned down.
pub fn resolve_version(bundle_version: Option<&str>) -> String {
    match bundle_version.map(str::trim) {
        Some(v) if !v.is_empty() => v.to_string(),
        _ => CARGO_VERSION.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// WHYFAIL16 regression: no bundle VERSION (the nofmt default path) must
    /// still yield a version, never an empty string.
    #[test]
    fn missing_bundle_version_falls_back_to_the_compiled_in_version() {
        let v = resolve_version(None);
        assert!(!v.is_empty(), "version must never be empty (WHYFAIL16)");
        assert_eq!(v, CARGO_VERSION);
    }

    /// An empty or whitespace-only file is the same defect as a missing one: it
    /// produced the blank stamp line, just via a different route.
    #[test]
    fn empty_bundle_version_falls_back_rather_than_stamping_nothing() {
        assert_eq!(resolve_version(Some("")), CARGO_VERSION);
        assert_eq!(resolve_version(Some("   \r\n")), CARGO_VERSION);
    }

    /// A real bundle VERSION still wins - a bundle build may ship a VERSION
    /// ahead of the crate metadata.
    #[test]
    fn bundle_version_wins_when_present() {
        assert_eq!(resolve_version(Some("9.9.9")), "9.9.9");
        assert_eq!(resolve_version(Some(" 9.9.9\r\n")), "9.9.9");
    }

    #[test]
    fn version_line_is_never_empty() {
        assert!(version_line().contains(CARGO_VERSION));
    }
}