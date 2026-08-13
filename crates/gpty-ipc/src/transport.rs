//! Platform abstraction for the IPC transport layer.
//!
//! Provides a unified `connect()` function that returns a
//! `Box<dyn IpcTransport>` for the current platform (Unix domain
//! socket on Linux/macOS, named pipe on Windows).

use std::io;
#[cfg(unix)]
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

/// True when `path` is a directory owned by `uid` with no group/other access.
#[cfg(unix)]
fn is_secure_runtime_dir(path: &str, uid: u32) -> bool {
    use std::os::unix::fs::MetadataExt;
    match std::fs::metadata(path) {
        Ok(m) => m.is_dir() && m.uid() == uid && m.mode() & 0o077 == 0,
        Err(_) => false,
    }
}

/// Returns the default IPC socket path for the current platform.
///
/// Respects the `GPTY_SOCKET` environment variable if set (explicit
/// override; bypasses directory validation).
///
/// Resolution order (Linux): `$XDG_RUNTIME_DIR/gpty.sock` when the directory
/// is user-owned and has no group/other access, then `/run/user/<uid>/gpty.sock`,
/// then `/tmp/gpty-<uid>.sock` as a last resort. macOS: `$TMPDIR/gpty.sock`
/// when secure, else `/tmp/gpty-<uid>.sock`. Windows: `\\.\pipe\gpty`.
pub fn default_socket_path() -> String {
    if let Ok(val) = std::env::var("GPTY_SOCKET")
        && !val.is_empty()
    {
        return val;
    }

    #[cfg(target_os = "linux")]
    {
        let uid = unsafe { libc::geteuid() };
        if let Ok(dir) = std::env::var("XDG_RUNTIME_DIR")
            && dir.starts_with('/')
            && is_secure_runtime_dir(&dir, uid)
        {
            return format!("{dir}/gpty.sock");
        }
        let run_user = format!("/run/user/{uid}");
        if is_secure_runtime_dir(&run_user, uid) {
            return format!("{run_user}/gpty.sock");
        }
        // Last resort: uid-suffixed path in /tmp. The server chmods the socket
        // to 0600 and enforces a peer-UID check, so this stays private.
        format!("/tmp/gpty-{uid}.sock")
    }

    #[cfg(target_os = "macos")]
    {
        let uid = unsafe { libc::geteuid() };
        let tmp = std::env::var("TMPDIR").unwrap_or_else(|_| "/tmp".into());
        if is_secure_runtime_dir(&tmp, uid) {
            return format!("{tmp}/gpty.sock");
        }
        format!("/tmp/gpty-{uid}.sock")
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

    #[cfg(unix)]
    mod xdg {
        use super::*;
        use std::os::unix::fs::PermissionsExt;

        #[test]
        fn xdg_runtime_dir_is_preferred() {
            let dir = std::env::temp_dir().join(format!("gpty-xdg-test-{}", std::process::id()));
            std::fs::create_dir_all(&dir).unwrap();
            std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();

            // SAFETY: single-threaded test context; removed in all paths.
            unsafe { std::env::set_var("XDG_RUNTIME_DIR", &dir) };
            assert_eq!(
                default_socket_path(),
                format!("{}/gpty.sock", dir.display())
            );
            unsafe { std::env::remove_var("XDG_RUNTIME_DIR") };
            std::fs::remove_dir(&dir).unwrap();
        }

        #[test]
        fn insecure_xdg_runtime_dir_is_rejected() {
            let dir =
                std::env::temp_dir().join(format!("gpty-xdg-insecure-{}", std::process::id()));
            std::fs::create_dir_all(&dir).unwrap();
            std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o777)).unwrap();

            unsafe { std::env::set_var("XDG_RUNTIME_DIR", &dir) };
            let path = default_socket_path();
            unsafe { std::env::remove_var("XDG_RUNTIME_DIR") };
            std::fs::remove_dir(&dir).unwrap();

            assert!(
                !path.starts_with(&format!("{}/", dir.display())),
                "insecure XDG_RUNTIME_DIR {dir:?} must not be used; got {path}"
            );
        }
    }
}
