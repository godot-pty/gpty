//! The Markdown-to-BBCode renderer: the untrusted model/file text the pane
//! displays. Both entry points, because the wikilink substitution is a second
//! pass over the same source.
#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Ok(source) = std::str::from_utf8(data) else {
        return;
    };
    let _ = gpty_gdext::markdown::render_markdown(source);
    let _ = gpty_gdext::markdown::render_markdown_with(source, true);
});
