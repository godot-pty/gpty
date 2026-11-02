//! The terminal grid's byte path: `TermGrid::feed` and the plain-text read
//! every capture and concept match goes through.
//!
//! The unbounded OSC buffer v0.7.1 closed was found by reading this code, not
//! by a tool; this target is the tool. Memory itself is bounded outside the
//! process (the CI runner passes `-rss_limit_mb`), because an in-process
//! allocator check would have to change the code under test.
#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let mut grid = gpty_core::term::TermGrid::new(24, 80);
    grid.feed(data);
    let _ = grid.plain_text(50);
});
