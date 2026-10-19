//! Stable error vocabulary for the media backend.
//!
//! The code is the machine-readable half: the FFI answers JSON and GDScript
//! branches on `error.code`, so a message can change without breaking a caller.
//! A refusal the caller asked about (a bad path, an unsupported codec) is not
//! logged; only unexpected failures are.

use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MediaErrorCode {
    /// The path is not an absolute local regular file.
    BadPath,
    /// The container is outside the shipped demuxer allowlist.
    UnsupportedContainer,
    /// No allowed decoder exists for the stream's codec.
    UnsupportedCodec,
    /// The frame or stream exceeds a size cap.
    TooLarge,
    /// FFmpeg could not open or inspect the file.
    OpenFailed,
    /// A packet or frame could not be decoded.
    DecodeFailed,
    /// A seek could not be performed.
    SeekFailed,
    /// The session was closed or its worker ended.
    Closed,
    /// A filesystem operation failed.
    IoError,
}

impl MediaErrorCode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::BadPath => "bad_path",
            Self::UnsupportedContainer => "unsupported_container",
            Self::UnsupportedCodec => "unsupported_codec",
            Self::TooLarge => "too_large",
            Self::OpenFailed => "open_failed",
            Self::DecodeFailed => "decode_failed",
            Self::SeekFailed => "seek_failed",
            Self::Closed => "closed",
            Self::IoError => "io_error",
        }
    }
}

impl fmt::Display for MediaErrorCode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MediaError {
    code: MediaErrorCode,
    message: String,
}

impl MediaError {
    pub fn new(code: MediaErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }

    pub fn bad_path(message: impl Into<String>) -> Self {
        Self::new(MediaErrorCode::BadPath, message)
    }

    pub fn unsupported_container(message: impl Into<String>) -> Self {
        Self::new(MediaErrorCode::UnsupportedContainer, message)
    }

    pub fn unsupported_codec(message: impl Into<String>) -> Self {
        Self::new(MediaErrorCode::UnsupportedCodec, message)
    }

    pub fn too_large(message: impl Into<String>) -> Self {
        Self::new(MediaErrorCode::TooLarge, message)
    }

    pub fn open(message: impl Into<String>) -> Self {
        Self::new(MediaErrorCode::OpenFailed, message)
    }

    pub fn decode(message: impl Into<String>) -> Self {
        Self::new(MediaErrorCode::DecodeFailed, message)
    }

    pub fn seek(message: impl Into<String>) -> Self {
        Self::new(MediaErrorCode::SeekFailed, message)
    }

    pub fn closed() -> Self {
        Self::new(MediaErrorCode::Closed, "media session is closed")
    }

    pub fn io(message: impl Into<String>) -> Self {
        Self::new(MediaErrorCode::IoError, message)
    }

    pub fn code(&self) -> MediaErrorCode {
        self.code
    }

    pub fn message(&self) -> &str {
        &self.message
    }
}

impl fmt::Display for MediaError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for MediaError {}
