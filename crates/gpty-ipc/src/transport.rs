//! Platform abstraction for the IPC transport layer.
//!
//! Provides a unified `connect()` function that returns a
//! `Box<dyn IpcTransport>` for the current platform (Unix domain
//! socket on Linux/macOS, named pipe on Windows).

use std::io;
use std::path::Path;

/// Marker trait for any async-readable, async-writable, sendable,
/// unpinned stream — automatically implemented for things that
/// already satisfy the bounds.
pub trait IpcTransport: tokio::io::AsyncRead + tokio::io::AsyncWrite + Send + Unpin {}

impl<T> IpcTransport for T where T: tokio::io::AsyncRead + tokio::io::AsyncWrite + Send + Unpin {}

// ── Platform connection ──────────────────────────────────

#[cfg(unix)]
pub async fn connect_unix(path: &Path) -> io::Result<tokio::net::UnixStream> {
    tokio::net::UnixStream::connect(path).await
}

#[cfg(windows)]
pub async fn connect_named_pipe(
    path: &str,
) -> io::Result<tokio::net::windows::named_pipe::NamedPipeClient> {
    // On Windows, named pipes are used instead of Unix sockets.
    tokio::net::windows::named_pipe::ClientOptions::new().open(path)
}

/// Open a connection to the running gpty IPC socket.
///
/// The `socket_path` is the platform-specific socket address.
pub async fn connect(socket_path: &str) -> io::Result<Box<dyn IpcTransport>> {
    #[cfg(unix)]
    {
        let stream = connect_unix(Path::new(socket_path)).await?;
        Ok(Box::new(stream))
    }
    #[cfg(windows)]
    {
        let stream = connect_named_pipe(socket_path).await?;
        Ok(Box::new(stream))
    }
    #[cfg(not(any(unix, windows)))]
    {
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "unsupported platform for IPC transport",
        ))
    }
}

// ── Default socket path ──────────────────────────────────

/// Returns the default IPC socket path for the current platform.
///
/// Respects the `GPTY_SOCKET` environment variable if set.
pub fn default_socket_path() -> String {
    if let Ok(val) = std::env::var("GPTY_SOCKET") {
        if !val.is_empty() {
            return val;
        }
    }

    #[cfg(target_os = "linux")]
    {
        "/tmp/gpty.sock".into()
    }

    #[cfg(target_os = "macos")]
    {
        format!(
            "{}/gpty.sock",
            std::env::var("TMPDIR").unwrap_or_else(|_| "/tmp".into())
        )
    }

    #[cfg(windows)]
    {
        r"\\.\pipe\gpty".into()
    }

    #[cfg(not(any(target_os = "linux", target_os = "macos", windows)))]
    {
        "/tmp/gpty.sock".into()
    }
}

// ── Tests ────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_socket_path_is_non_empty() {
        let path = default_socket_path();
        assert!(!path.is_empty());
    }
    #[test]
    fn env_var_overrides_default() {
        // SAFETY: test runs in single-threaded context, no other tests read GPTY_SOCKET concurrently.
        unsafe { std::env::set_var("GPTY_SOCKET", "/custom/path.sock") };
        assert_eq!(default_socket_path(), "/custom/path.sock");
        unsafe { std::env::remove_var("GPTY_SOCKET") };
    }

    #[test]
    fn env_var_empty_falls_back() {
        unsafe { std::env::set_var("GPTY_SOCKET", "") };
        let path = default_socket_path();
        assert!(!path.is_empty());
        assert_ne!(path, "");
        unsafe { std::env::remove_var("GPTY_SOCKET") };
    }
}
