//! Wikilink scanning and resolution: the scanner that both the index and the
//! Markdown preview use, then the two lookups a target can reach.
#![no_main]
use libfuzzer_sys::fuzz_target;

const NOTES: [&str; 4] = ["index.md", "sub/other.md", "a b.md", "Note.md"];

fuzz_target!(|data: &[u8]| {
    let Ok(body) = std::str::from_utf8(data) else {
        return;
    };
    for link in gpty_core::links::parse_links(body) {
        let _ = gpty_core::links::resolve_target(&link.target, &NOTES);
        let _ = gpty_core::links::retarget(&link.target, "sub/other.md");
    }
});
