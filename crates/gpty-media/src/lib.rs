//! Media probe and decode backend for gpty's media pane.
//!
//! This crate is the one owner of the FFmpeg binding. Everything above it
//! (`gpty-gdext`, GDScript) sees only [`MediaInfo`], [`MediaSession`] and the
//! packed frame/sample types below, so the binding can be replaced or patched
//! without touching a pane.
//!
//! ## Trust boundary
//!
//! A media path is untrusted input: it can arrive from a layout, a profile or
//! an IPC caller. [`validate_path`] is therefore applied here as well as at
//! the GDScript edge — absolute, a regular file, no URL scheme — and the
//! demuxer/codec allowlists below are checked after FFmpeg has opened the
//! file. The shipped FFmpeg build is configured with
//! `--disable-everything --disable-network` and only the components in the
//! `scripts/media-deps` allowlist, so this check is defense in depth rather
//! than the only gate.
//!
//! ## Binding rules
//!
//! `ffmpeg-the-third` is used through a deliberately narrow subset:
//!
//! * Packets are read with [`ffmpeg_the_third::codec::packet::Packet::read`],
//!   never through `Input::packets()`, whose iterator relies on Rust struct
//!   field order (`mem::transmute_copy`) and is unsound.
//! * Container metadata is never read (file-controlled bytes are not UTF-8).
//! * Frame dimension setters are never called.
//! * Filters, subtitles and `sample::Buffer` are not used.
//!
//! These rules are asserted by `tests/binding_rules.rs`, so a future edit that
//! reintroduces one of the banned paths fails the suite.
//!
//! ## Decode model
//!
//! One [`MediaSession`] owns one OS thread and one FFmpeg input context. The
//! worker reads packets, decodes video to packed RGBA and audio to interleaved
//! f32 at the caller's rate/channels, and pushes both into bounded queues.
//! The caller polls; a full queue blocks the worker, exactly like the PTY
//! reader's backpressure. No decode work runs on the Godot thread and none
//! runs on the GDExtension's two-worker tokio runtime.

use std::path::{Path, PathBuf};
use std::sync::LazyLock;

pub mod error;
pub mod probe;
pub mod session;

pub use error::{MediaError, MediaErrorCode};
pub use probe::{AudioInfo, MediaInfo, StreamInfo, StreamKind, VideoInfo, probe};
pub use session::{AudioChunk, MediaSession, OpenConfig, SessionState, SessionStatus, VideoFrame};

/// Largest side of a decoded video frame. A 4K UHD frame is 3840×2160;
/// 4096 is one notch above it and rejects 8K before a single allocation.
pub const MAX_VIDEO_DIMENSION: u32 = 4096;

/// Largest decoded frame, in bytes. 3840×2160 RGBA is 33,177,600 bytes, so
/// this admits 4K and rejects anything that would make the bounded queue
/// meaningfully larger than a pane's own surface.
pub const MAX_FRAME_BYTES: usize = 34 * 1024 * 1024;

/// Most streams inspected in one file. A media pane plays one video and one
/// audio stream; the rest are reported but not decoded.
pub const MAX_STREAMS: usize = 16;

/// Most audio channels accepted from a file (and requested by a caller).
pub const MAX_CHANNELS: u16 = 8;

/// Lowest and highest sample rates accepted for decode output.
pub const MIN_SAMPLE_RATE: u32 = 8_000;
pub const MAX_SAMPLE_RATE: u32 = 192_000;

/// Longest accepted media path, in bytes. The path reaches `File::open` and
/// FFmpeg's AVIO layer; both are happier with a bounded name.
pub const MAX_PATH_BYTES: usize = 4096;

/// Wall-clock budget for opening and probing one file. A local regular file
/// opens in milliseconds; the budget exists so a crafted file or a path
/// swapped for a blocking node cannot pin the decode thread forever.
pub const OPEN_TIMEOUT_MS: u64 = 10_000;

/// Container demuxers the backend will open, by FFmpeg's own short name.
/// This mirrors the component list in `scripts/media-deps` and the
/// user-facing `MediaFiles` table.
pub const ALLOWED_DEMUXERS: &[&str] = &[
    "mov", "matroska", "ogg", "wav", "flac", "mp3", "aac", "avi", "mpegts",
];

/// Video codecs the backend will decode, by FFmpeg codec name.
pub const ALLOWED_VIDEO_CODECS: &[&str] = &[
    "h264",
    "hevc",
    "vp8",
    "vp9",
    "av1",
    "theora",
    "mpeg2video",
    "mpeg4",
];

/// Audio codecs the backend will decode. PCM variants are matched by prefix.
pub const ALLOWED_AUDIO_CODECS: &[&str] = &["aac", "mp3", "opus", "vorbis", "flac", "alac", "ac3"];

/// The one-time FFmpeg initialization. `ffmpeg_the_third::init` registers
/// codecs and (for a default build) network protocols; calling it once keeps
/// the process state deterministic and makes a second session cheap.
pub(crate) fn ensure_ffmpeg_init() -> Result<(), MediaError> {
    static INIT: LazyLock<Result<(), String>> =
        LazyLock::new(|| ffmpeg_the_third::init().map_err(|e| e.to_string()));
    INIT.clone().map_err(MediaError::open)
}

/// Validate a media path and return it as a `PathBuf`.
///
/// The rule is the one the media pane and the file tree already apply:
/// absolute, local, no scheme, and a **regular file** — a FIFO or device must
/// never reach FFmpeg's open, which would block the decode thread. The
/// metadata check follows symlinks, which is intended: a link to a regular
/// file is playable, a link to a device is not.
pub fn validate_path(path: &str) -> Result<PathBuf, MediaError> {
    let trimmed = path.trim();
    if trimmed.is_empty() {
        return Err(MediaError::bad_path("empty path"));
    }
    if trimmed.len() > MAX_PATH_BYTES {
        return Err(MediaError::bad_path("path is too long"));
    }
    if trimmed.contains("://") || trimmed.starts_with("res:") || trimmed.starts_with("user:") {
        return Err(MediaError::bad_path("only local files are supported"));
    }
    let candidate = Path::new(trimmed);
    if !candidate.is_absolute() {
        return Err(MediaError::bad_path("path must be absolute"));
    }
    let metadata = std::fs::metadata(candidate)
        .map_err(|e| MediaError::bad_path(format!("cannot stat {:?}: {e}", candidate)))?;
    if !metadata.is_file() {
        return Err(MediaError::bad_path("not a regular file"));
    }
    Ok(candidate.to_path_buf())
}

/// True when `name` is a video decoder this backend is allowed to run.
pub fn video_codec_allowed(name: &str) -> bool {
    ALLOWED_VIDEO_CODECS.contains(&name)
}

/// True when `name` is an audio decoder this backend is allowed to run.
/// PCM variants are accepted by prefix (`pcm_s16le`, `pcm_f32le`, …).
pub fn audio_codec_allowed(name: &str) -> bool {
    ALLOWED_AUDIO_CODECS.contains(&name) || name.starts_with("pcm_")
}

/// Convert a stream time-base timestamp to microseconds without overflow.
pub(crate) fn timestamp_to_us(ts: i64, numerator: i32, denominator: i32) -> u64 {
    if ts <= 0 || numerator <= 0 || denominator <= 0 {
        return 0;
    }
    let scaled = (ts as i128) * (numerator as i128) * 1_000_000i128 / (denominator as i128);
    scaled.clamp(0, i64::MAX as i128) as u64
}
