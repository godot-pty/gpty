//! The backend child's stdout framing: `gpty_ai::frame::read_frame` is the one
//! bounded line reader both process backends use, so a missing newline may not
//! grow past the limit.
#![no_main]
use libfuzzer_sys::fuzz_target;
use std::sync::LazyLock;
use tokio::runtime::{Builder, Runtime};

static RUNTIME: LazyLock<Runtime> = LazyLock::new(|| {
    Builder::new_current_thread()
        .build()
        .expect("current-thread runtime")
});

fuzz_target!(|data: &[u8]| {
    // A small limit keeps the interesting boundary (input longer than the
    // budget) inside libFuzzer's usual input sizes.
    const LIMIT: usize = 1024;
    let mut reader = data;
    let _ = RUNTIME.block_on(gpty_ai::frame::read_frame(&mut reader, LIMIT, "fuzz"));
});
