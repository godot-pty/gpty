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
        #[cfg(unix)]
        {
            if val.starts_with('/') {
                return val;
            }
            log::warn!("ignoring relative GPTY_SOCKET path ({val}); using default resolution");
        }
        #[cfg(not(unix))]
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

/// Returns the dedicated local socket for passive agent semantic events.
///
/// This socket deliberately does not honor `GPTY_SOCKET`: event producers
/// receive its exact path through a per-terminal trusted environment variable.
pub fn default_event_socket_path() -> String {
    let control = default_socket_path();
    if let Some(prefix) = control.strip_suffix(".sock") {
        format!("{prefix}-events.sock")
    } else {
        format!("{control}-events")
    }
}

/// Validate a Unix-domain socket path before connecting to it.
///
/// Guards against `GPTY_SOCKET` env hijacking: an attacker who controls a
/// victim's environment could point the CLI/MCP at a fake socket, which
/// would receive every command (and `GPTY_SECRET`, if set). A legitimate
/// gpty socket is owned by the current user and inaccessible to
/// group/other (the server chmods it 0600).
///
/// A missing file is NOT an error — the socket may not exist yet (the
/// daemon auto-spawns the GUI); `connect` fails naturally in that case.
pub fn validate_socket_path(path: &str) -> io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::{FileTypeExt, MetadataExt};
        if !path.starts_with('/') {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "refusing relative GPTY_SOCKET path",
            ));
        }
        let meta = match std::fs::metadata(path) {
            Err(_) => return Ok(()),
            Ok(m) => m,
        };
        if !meta.file_type().is_socket() {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "refusing to connect: GPTY_SOCKET is not a socket",
            ));
        }
        let uid = unsafe { libc::geteuid() };
        if meta.uid() != uid {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "refusing to connect: GPTY_SOCKET owned by another user (possible env hijack)",
            ));
        }
        if meta.mode() & 0o077 != 0 {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "refusing to connect: GPTY_SOCKET permissions too open (possible env hijack)",
            ));
        }
    }
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
}

/// Validate a GUI binary path before spawning it (GPTY_GUI override).
///
/// True when the path is an absolute, regular, user-owned file that is
/// not writable by group or others. On non-Unix platforms only absolute
/// path and file type are checked (no ownership metadata).
pub fn validate_gui_binary(path: &std::path::Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if !path.is_absolute() {
            return false;
        }
        let Ok(meta) = std::fs::metadata(path) else {
            return false;
        };
        meta.is_file() && meta.uid() == unsafe { libc::geteuid() } && meta.mode() & 0o022 == 0
    }
    #[cfg(not(unix))]
    {
        path.is_absolute() && std::fs::metadata(path).is_ok_and(|m| m.is_file())
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
    mod socket_validation {
        use super::*;
        use std::os::unix::fs::PermissionsExt;

        fn tmp_socket(mode: u32) -> std::path::PathBuf {
            let path =
                std::env::temp_dir().join(format!("gpty-val-test-{}-{}", std::process::id(), mode));
            let _ = std::fs::remove_file(&path);
            let listener = std::os::unix::net::UnixListener::bind(&path).unwrap();
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(mode)).unwrap();
            drop(listener);
            path
        }

        #[test]
        fn insecure_mode_socket_rejected() {
            let path = tmp_socket(0o666);
            assert!(validate_socket_path(path.to_str().unwrap()).is_err());
            std::fs::remove_file(&path).unwrap();
        }

        #[test]
        fn secure_mode_socket_accepted() {
            let path = tmp_socket(0o600);
            assert!(validate_socket_path(path.to_str().unwrap()).is_ok());
            std::fs::remove_file(&path).unwrap();
        }

        #[test]
        fn missing_file_is_ok() {
            let path = std::env::temp_dir().join("gpty-val-missing-99999.sock");
            let _ = std::fs::remove_file(&path);
            assert!(validate_socket_path(path.to_str().unwrap()).is_ok());
        }

        #[test]
        fn regular_file_rejected() {
            let path = std::env::temp_dir().join(format!("gpty-val-reg-{}", std::process::id()));
            std::fs::write(&path, b"x").unwrap();
            assert!(validate_socket_path(path.to_str().unwrap()).is_err());
            std::fs::remove_file(&path).unwrap();
        }

        #[test]
        fn relative_path_rejected() {
            assert!(validate_socket_path("relative/path.sock").is_err());
        }

        #[test]
        fn gui_binary_world_writable_rejected() {
            let path = std::env::temp_dir().join(format!("gpty-val-bin-{}", std::process::id()));
            std::fs::write(&path, b"#!/bin/sh\n").unwrap();
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o777)).unwrap();
            assert!(!validate_gui_binary(&path));
            std::fs::remove_file(&path).unwrap();
        }

        #[test]
        fn gui_binary_private_owned_accepted() {
            let path = std::env::temp_dir().join(format!("gpty-val-bin-ok-{}", std::process::id()));
            std::fs::write(&path, b"#!/bin/sh\n").unwrap();
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
            assert!(validate_gui_binary(&path));
            std::fs::remove_file(&path).unwrap();
        }
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
