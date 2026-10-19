//! Guard the vetted subset of the FFmpeg binding.
//!
//! The binding has open soundness reports in APIs we do not need. `src/lib.rs`
//! states the rules; this test keeps an edit from reintroducing one of the
//! banned calls in the two modules that touch FFmpeg. It is a seam check in
//! the same spirit as `scripts/check-ffi-surface`: the alternative is a
//! comment nobody rereads.

use std::path::PathBuf;

const BANNED: &[&str] = &[
    // The unsound packet iterator (`repr(Rust)` field-order transmute).
    ".packets(",
    // File-controlled metadata is not necessarily UTF-8.
    ".metadata(",
    // Safe dimension setters can manufacture out-of-bounds slices.
    "set_width(",
    "set_height(",
    // Planar sample buffers we index ourselves; use `frame::Audio` instead.
    "sample::Buffer",
    // Components outside the backend's job.
    "filter::Context",
    "subtitle::",
];

#[test]
fn decode_modules_use_the_vetted_binding_subset() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("src");
    for module in ["session.rs", "probe.rs"] {
        let path = root.join(module);
        let source = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("cannot read {}: {e}", path.display()));
        for banned in BANNED {
            assert!(
                !source.contains(banned),
                "{} uses banned FFmpeg API {banned:?}",
                path.display()
            );
        }
    }
}
