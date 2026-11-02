//! The control socket's request decode, framing included: frames are
//! newline-delimited and the server trims them before `serde_json`; the read
//! cap (64 KiB) is modelled by the fuzzer's `-max_len` rather than repeated
//! here, so the target exercises the same parse the server runs.
#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    for frame in data.split(|&byte| byte == b'\n') {
        let Ok(text) = std::str::from_utf8(frame) else {
            continue;
        };
        let trimmed = text.trim();
        if trimmed.is_empty() {
            continue;
        }
        let _ = serde_json::from_str::<gpty_ipc::protocol::Request>(trimmed);
    }
});
