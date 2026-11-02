//! The capture-side parser: `vte` plus the escape-string guard that closes an
//! over-budget OSC with a BEL instead of letting the payload grow.
#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let mut parser = gpty_core::parser::LineParser::new();
    let _ = parser.feed(data);
});
