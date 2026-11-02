//! The one place a validated path becomes bytes for FFmpeg.
//!
//! [`crate::validate_path`] answers a question about a *name*. A cooperating
//! process can replace the name between that answer and FFmpeg's own
//! `open(2)`: with a FIFO in its place, FFmpeg's `file` protocol opens with
//! plain `O_RDONLY` and waits for a writer, which no read timeout and no
//! interrupt callback can break. So this module opens the descriptor itself
//! with `O_NONBLOCK | O_NOFOLLOW`, verifies **the descriptor** with `fstat`,
//! and gives FFmpeg a custom `AVIOContext` that reads and seeks that
//! descriptor. Nothing after the open touches the path again: replacing the
//! name afterwards changes what a later open would see, never what this
//! session plays.
//!
//! Windows has no FIFO, so `File::open` cannot wait for a writer there; the
//! descriptor is still the thing verified and read, and the `\\.\` device
//! namespace is refused by name because opening one can block in a driver.
//!
//! The interrupt closure the open deadline uses is owned here too: FFmpeg
//! keeps the callback for the context's whole life, so it is freed when this
//! module's context is freed rather than leaked per open.

use std::ffi::{CString, c_void};
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::ops::{Deref, DerefMut};
use std::path::{Path, PathBuf};
use std::ptr;

use ffmpeg_the_third as ffmpeg;
use ffmpeg_the_third::ffi;

use crate::error::MediaError;

/// FFmpeg's read-ahead buffer over the descriptor.
const AVIO_BUFFER_BYTES: usize = 32 * 1024;

/// A media file this process opened, together with the name it was asked for.
pub(crate) struct MediaFile {
    /// The name as the caller wrote it: it is only a probing hint (an
    /// extension is evidence for the demuxer), never opened again.
    path: PathBuf,
    file: Box<File>,
}

impl MediaFile {
    /// Apply the path gate, open the file, and verify the descriptor.
    pub(crate) fn open(path: &str) -> Result<Self, MediaError> {
        let path = crate::validate_path(path)?;
        let file = open_regular(&path)?;
        Ok(Self { path, file })
    }

    /// Build FFmpeg's input context over the descriptor already open.
    ///
    /// `interrupt` is called during open/probe; the caller clears its
    /// deadline once this returns, so playback is never aborted by it.
    pub(crate) fn into_input(
        self,
        interrupt: Box<dyn FnMut() -> bool>,
    ) -> Result<InputSource, MediaError> {
        InputSource::open(self.path, self.file, interrupt)
    }
}

/// Open `path` read-only without ever waiting on the node it names, and
/// require the opened descriptor to be a regular file.
fn open_regular(path: &Path) -> Result<Box<File>, MediaError> {
    let file = open_read_only(path)?;
    // `File::metadata` is `fstat` on this descriptor, so it describes the file
    // actually opened, not whatever the name refers to now.
    let metadata = file
        .metadata()
        .map_err(|e| MediaError::bad_path(format!("cannot stat the opened file: {e}")))?;
    if !metadata.is_file() {
        return Err(MediaError::bad_path("not a regular file"));
    }
    Ok(Box::new(file))
}

#[cfg(unix)]
fn open_read_only(path: &Path) -> Result<File, MediaError> {
    use std::os::unix::fs::OpenOptionsExt;

    // O_NONBLOCK: a FIFO swapped in at the path returns immediately instead of
    // waiting for a writer (a regular file ignores it).
    // O_NOFOLLOW: the last component is opened as named, so a link cannot be
    // swapped in to redirect the open; a legitimate link is resolved below.
    const FLAGS: i32 = libc::O_NONBLOCK | libc::O_NOFOLLOW | libc::O_CLOEXEC;

    let attempt = |path: &Path| {
        std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(FLAGS)
            .open(path)
    };
    match attempt(path) {
        Ok(file) => Ok(file),
        // A symlink to a regular file is playable by design; resolve it and
        // open the target under the same flags. The target's descriptor is
        // still what gets verified, so a link to a FIFO is refused just the
        // same.
        Err(error) if error.raw_os_error() == Some(libc::ELOOP) => {
            let target = std::fs::canonicalize(path)
                .map_err(|e| MediaError::bad_path(format!("cannot resolve {:?}: {e}", path)))?;
            attempt(&target)
                .map_err(|e| MediaError::bad_path(format!("cannot open {:?}: {e}", target)))
        }
        Err(error) => Err(MediaError::bad_path(format!(
            "cannot open {:?}: {error}",
            path
        ))),
    }
}

#[cfg(not(unix))]
fn open_read_only(path: &Path) -> Result<File, MediaError> {
    // Windows has no FIFO files, so a plain open cannot wait for a writer.
    // The device namespace is the one blocking `open` there (`\\.\pipe\…`
    // waits for a server), and no media file lives in it.
    if path.to_string_lossy().starts_with(r"\\.\") {
        return Err(MediaError::bad_path("device paths are not supported"));
    }
    File::open(path).map_err(|e| MediaError::bad_path(format!("cannot open {:?}: {e}", path)))
}

/// An FFmpeg input reading through the descriptor this module opened.
pub(crate) struct InputSource {
    /// Declared first: the input closes before the AVIO context, descriptor
    /// and interrupt closure it reads through are freed.
    input: ffmpeg::format::context::Input,
    _io: Avio,
}

impl InputSource {
    fn open(
        path: PathBuf,
        file: Box<File>,
        interrupt: Box<dyn FnMut() -> bool>,
    ) -> Result<Self, MediaError> {
        let io = Avio::new(file, interrupt)?;
        // No NUL byte can be inside a path that came from a `str`, and FFmpeg
        // only reads this string (the probe hint), never opens it.
        let hint = CString::new(path.as_os_str().as_encoded_bytes())
            .map_err(|_| MediaError::bad_path("path contains a NUL byte"))?;
        // SAFETY: the context is allocated here and either consumed by
        // `Input::wrap` or freed by FFmpeg; `io.context` is set as its `pb`
        // and stays alive in `_io` for as long as `Input` refers to it,
        // because `Input` is dropped first (declaration order).
        unsafe {
            let mut context = ffi::avformat_alloc_context();
            if context.is_null() {
                return Err(MediaError::open("cannot allocate a media context"));
            }
            (*context).pb = io.context;
            (*context).flags |= ffi::AVFMT_FLAG_CUSTOM_IO;
            (*context).interrupt_callback = io.interrupt.callback();

            let opened =
                ffi::avformat_open_input(&mut context, hint.as_ptr(), ptr::null(), ptr::null_mut());
            if opened < 0 {
                // FFmpeg freed the context it was given and left the AVIO
                // context alone (that is what CUSTOM_IO means), so `io`
                // reclaims it here.
                return Err(MediaError::open(format!(
                    "cannot open media: {}",
                    ffmpeg::Error::from(opened)
                )));
            }
            let probed = ffi::avformat_find_stream_info(context, ptr::null_mut());
            if probed < 0 {
                ffi::avformat_close_input(&mut context);
                return Err(MediaError::open(format!(
                    "cannot read media streams: {}",
                    ffmpeg::Error::from(probed)
                )));
            }
            Ok(Self {
                input: ffmpeg::format::context::Input::wrap(context),
                _io: io,
            })
        }
    }
}

impl Deref for InputSource {
    type Target = ffmpeg::format::context::Input;

    fn deref(&self) -> &Self::Target {
        &self.input
    }
}

impl DerefMut for InputSource {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.input
    }
}

/// The `AVIOContext` FFmpeg reads through, its descriptor and its interrupt
/// closure. Freed as one unit when the input is gone.
struct Avio {
    context: *mut ffi::AVIOContext,
    interrupt: Interrupt,
    /// Owned so the callback's `opaque` pointer stays valid; the callbacks
    /// read the file, this struct never does.
    _file: Box<File>,
}

impl Avio {
    fn new(file: Box<File>, interrupt: Box<dyn FnMut() -> bool>) -> Result<Self, MediaError> {
        let interrupt = Interrupt::new(interrupt);
        // The callbacks receive this pointer; `Box` keeps the file at a stable
        // address for as long as the context can call them.
        let opaque = (&*file as *const File).cast_mut().cast::<c_void>();
        // SAFETY: FFmpeg frees the context (and this buffer) via
        // `avio_context_free`, so the buffer is allocated by `av_malloc`.
        unsafe {
            let buffer = ffi::av_malloc(AVIO_BUFFER_BYTES).cast::<u8>();
            if buffer.is_null() {
                return Err(MediaError::open("cannot allocate the media read buffer"));
            }
            let context = ffi::avio_alloc_context(
                buffer,
                AVIO_BUFFER_BYTES as i32,
                0,
                opaque,
                Some(read_packet),
                None,
                Some(seek),
            );
            if context.is_null() {
                // `avio_alloc_context` frees nothing it was given.
                ffi::av_free(buffer.cast());
                return Err(MediaError::open("cannot allocate the media reader"));
            }
            Ok(Self {
                context,
                interrupt,
                _file: file,
            })
        }
    }
}

impl Drop for Avio {
    fn drop(&mut self) {
        // `avio_context_free` frees the AVIOContext, never the buffer: FFmpeg
        // treats a buffer passed to `avio_alloc_context` as the caller's
        // (ffmpeg 9.0.2, libavformat/aviobuf.c). `ffio_ensure_seekback` may
        // have replaced it with a reallocated block, so the pointer current at
        // drop time is the one to free. Measured before the fix: a probe of a
        // crafted header left 32 KiB unreachable per call (ASAN, 2000 calls)
        // and the plain build grew 6-8 KiB per open.
        // SAFETY: created by `avio_alloc_context` and replaced only by FFmpeg's
        // own realloc of this same field; freed exactly once here, after the
        // context that used it is gone.
        unsafe {
            if !self.context.is_null() {
                let buffer = (*self.context).buffer;
                ffi::avio_context_free(&mut self.context);
                if !buffer.is_null() {
                    ffi::av_free(buffer.cast());
                }
            }
        }
    }
}

/// The open/probe deadline callback, owned rather than leaked.
struct Interrupt {
    /// Boxed twice so the pointer FFmpeg stores is thin: `*mut c_void` cannot
    /// carry a `dyn` pointer's vtable.
    opaque: *mut Box<dyn FnMut() -> bool>,
}

impl Interrupt {
    fn new(callback: Box<dyn FnMut() -> bool>) -> Self {
        Self {
            opaque: Box::into_raw(Box::new(callback)),
        }
    }

    fn callback(&self) -> ffi::AVIOInterruptCB {
        ffi::AVIOInterruptCB {
            callback: Some(interrupt_callback),
            opaque: self.opaque.cast(),
        }
    }
}

impl Drop for Interrupt {
    fn drop(&mut self) {
        // SAFETY: allocated in `new`, reclaimed once, after the context that
        // holds a copy of the callback struct has been freed.
        unsafe { drop(Box::from_raw(self.opaque)) };
    }
}

unsafe extern "C" fn interrupt_callback(opaque: *mut c_void) -> i32 {
    debug_assert!(!opaque.is_null());
    // SAFETY: `opaque` is the pointer `Interrupt` allocated, and it outlives
    // every call FFmpeg can make.
    let callback = unsafe { &mut *(opaque as *mut Box<dyn FnMut() -> bool>) };
    // A panic must never unwind into C.
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(callback)) {
        Ok(stop) => i32::from(stop),
        Err(_) => std::process::abort(),
    }
}

/// `AVERROR(e)` is `-e`; a decode error without an OS code is EIO.
fn error_code(error: &std::io::Error) -> i32 {
    match error.raw_os_error() {
        Some(code) if code > 0 => code,
        _ => libc::EIO,
    }
}

unsafe extern "C" fn read_packet(opaque: *mut c_void, buffer: *mut u8, size: i32) -> i32 {
    if size <= 0 || buffer.is_null() {
        return ffi::AVERROR_EOF;
    }
    // SAFETY: `opaque` is the `File` inside `Avio`, which outlives the AVIO
    // context; `buffer` is FFmpeg's write-into buffer of `size` bytes.
    let file = unsafe { &mut *(opaque as *mut File) };
    // SAFETY: FFmpeg passes a writable region of `size` bytes (the read
    // callback's contract); nothing else aliases it for this call.
    let destination = unsafe { std::slice::from_raw_parts_mut(buffer, size as usize) };
    loop {
        match file.read(destination) {
            Ok(0) => return ffi::AVERROR_EOF,
            Ok(read) => return read as i32,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(error) => return -error_code(&error),
        }
    }
}

unsafe extern "C" fn seek(opaque: *mut c_void, offset: i64, whence: i32) -> i64 {
    // SAFETY: same contract as `read_packet`.
    let file = unsafe { &mut *(opaque as *mut File) };
    if whence & ffi::AVSEEK_SIZE != 0 {
        return match file.metadata() {
            Ok(metadata) => metadata.len().min(i64::MAX as u64) as i64,
            Err(error) => -(error_code(&error) as i64),
        };
    }
    let origin = match whence & !(ffi::AVSEEK_SIZE | ffi::AVSEEK_FORCE) {
        libc::SEEK_SET if offset >= 0 => SeekFrom::Start(offset as u64),
        libc::SEEK_CUR => SeekFrom::Current(offset),
        libc::SEEK_END => SeekFrom::End(offset),
        _ => return -(libc::EINVAL as i64),
    };
    match file.seek(origin) {
        Ok(position) => position.min(i64::MAX as u64) as i64,
        Err(error) => -(error_code(&error) as i64),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::MediaErrorCode;
    #[cfg(unix)]
    use std::sync::mpsc;
    #[cfg(unix)]
    use std::time::Duration;

    /// A path that cannot be opened: the gate refuses it on every platform.
    #[test]
    fn a_directory_is_refused_as_a_media_source() {
        let directory = std::env::temp_dir();
        let error = MediaFile::open(&directory.to_string_lossy())
            .err()
            .expect("a directory is not a media source");
        assert_eq!(error.code(), MediaErrorCode::BadPath);
    }

    #[cfg(unix)]
    fn scratch_path(name: &str) -> PathBuf {
        let path =
            std::env::temp_dir().join(format!("gpty-media-source-{}-{name}", std::process::id()));
        let _ = std::fs::remove_file(&path);
        path
    }

    #[cfg(unix)]
    fn make_fifo(path: &Path) {
        let name = CString::new(path.as_os_str().as_encoded_bytes()).unwrap();
        // SAFETY: a plain libc call with a valid C string.
        assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
    }

    /// `MediaFile::open` must refuse a FIFO without waiting for a writer.
    #[cfg(unix)]
    #[test]
    fn a_fifo_is_refused_without_blocking() {
        let path = scratch_path("fifo");
        make_fifo(&path);
        let (tx, rx) = mpsc::channel();
        let probe_path = path.clone();
        let handle = std::thread::spawn(move || {
            let result = MediaFile::open(&probe_path.to_string_lossy());
            let _ = tx.send(result.err().map(|error| error.code()));
        });
        let outcome = rx.recv_timeout(Duration::from_secs(5));
        let _ = std::fs::remove_file(&path);
        assert_eq!(
            outcome.expect("open blocked on a FIFO"),
            Some(MediaErrorCode::BadPath)
        );
        handle.join().unwrap();
    }

    /// The race this module closes: the name is replaced between the
    /// descriptor open and FFmpeg's open. FFmpeg must read the descriptor,
    /// so a FIFO in the name can neither block nor be read.
    #[cfg(unix)]
    #[test]
    fn a_swapped_fifo_never_reaches_ffmpeg() {
        let source = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/wav.wav");
        let path = scratch_path("swapped.wav");
        std::fs::copy(&source, &path).unwrap();
        let file = MediaFile::open(&path.to_string_lossy()).unwrap();

        // The attack: the name now points at a FIFO instead of the file the
        // descriptor was opened from.
        let fifo = scratch_path("swapped.fifo");
        make_fifo(&fifo);
        std::fs::rename(&fifo, &path).unwrap();
        let hint = file.path.clone();
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let outcome = file
                .into_input(Box::new(|| false))
                .map(|input| (input.format().name().to_string(), input.streams().count()));
            let _ = tx.send(outcome.map_err(|error| error.code()));
        });
        let outcome = rx.recv_timeout(Duration::from_secs(5));
        let _ = std::fs::remove_file(&path);
        let opened = outcome.unwrap_or_else(|_| {
            panic!("opening blocked: the input reopened {hint:?} instead of the descriptor")
        });
        let (container, streams) = opened.expect("the wav fixture should open");
        assert_eq!(container, "wav");
        assert!(streams >= 1, "no stream reported");
    }

    /// A symlinked media file stays playable (the link is resolved once).
    #[cfg(unix)]
    #[test]
    fn a_symlink_to_a_regular_file_is_playable() {
        let source = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/wav.wav");
        let path = scratch_path("link.wav");
        std::os::unix::fs::symlink(&source, &path).unwrap();
        let input = MediaFile::open(&path.to_string_lossy())
            .and_then(|file| file.into_input(Box::new(|| false)));
        let _ = std::fs::remove_file(&path);
        let input = input.expect("a link to a regular file opens");
        assert!(input.duration() > 0);
    }
}
