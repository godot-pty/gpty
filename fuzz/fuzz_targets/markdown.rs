//! The Markdown-to-BBCode renderer: the untrusted model/file text the pane
//! displays. Every mode, because the wikilink substitution and the docs
//! `gpty-doc:` acceptance are separate passes over the same source.
#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Ok(source) = std::str::from_utf8(data) else {
        return;
    };
    let _ = gpty_gdext::markdown::render_markdown(source);
    let _ = gpty_gdext::markdown::render_markdown_with(source, true, false);
    let _ = gpty_gdext::markdown::render_markdown_with(source, false, true);
});
