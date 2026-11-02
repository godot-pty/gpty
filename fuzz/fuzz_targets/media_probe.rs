//! The media path gate and demuxer probe over arbitrary bytes. The extension
//! is a supported one so the probe reaches FFmpeg's own parsers; the C
//! decoders themselves are SECURITY.md's accepted exception, so what this
//! target asserts is the Rust gates (path shape, demuxer alias, codec id,
//! caps) and that no input can hang or panic above them.
#![no_main]
use libfuzzer_sys::fuzz_target;
use std::sync::LazyLock;

/// FFmpeg's default level logs every container it rejects, and every fuzz
/// input that reaches the demuxer is one. Silence it once, before the first
/// probe; a crash report is libFuzzer's output, not a decoder's complaint.
static QUIET: LazyLock<()> = LazyLock::new(|| {
    ffmpeg_the_third::util::log::set_level(ffmpeg_the_third::util::log::Level::Quiet);
});

fuzz_target!(|data: &[u8]| {
    LazyLock::force(&QUIET);
    if data.len() > 1 << 20 {
        return;
    }
    // One private directory per input: the guard removes the file on a normal
    // or panicking return. An abort or OOM runs no destructor, so a killed fuzz
    // process can still leave the directory behind — that is libFuzzer's
    // crash path, not a leak this target can close. A host that cannot give us
    // a scratch directory skips the input: an environmental `ENOSPC`/`EMFILE`
    // must never be reported as a crash.
    let Ok(tmp) = tempfile::TempDir::new() else {
        return;
    };
    let path = tmp.path().join("input.mkv");
    if std::fs::write(&path, data).is_err() {
        return;
    }
    let _ = gpty_media::probe(path.to_string_lossy().as_ref());
});
