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
/// Resolution order: a per-user *runtime* directory first — `$XDG_RUNTIME_DIR`
/// then `/run/user/<uid>` on Linux, `$TMPDIR` on macOS — each accepted only when
/// it is user-owned and inaccessible to group/other. Then a private state
/// directory of our own ([`private_state_dir`]). Only then the session temp
/// directory: `/tmp/gpty-<uid>.sock` is predictable in a world-writable place,
/// so another user can hold the path and deny the control surface (owner and
/// mode are validated, so it is denial of service and not a spoof). Windows:
/// `\\.\pipe\gpty`, whose namespace the creating user's ACL covers.
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
        fallback_socket_path(uid)
    }

    #[cfg(target_os = "macos")]
    {
        let uid = unsafe { libc::geteuid() };
        let tmp = std::env::var("TMPDIR").unwrap_or_else(|_| "/tmp".into());
        if is_secure_runtime_dir(&tmp, uid) {
            return format!("{tmp}/gpty.sock");
        }
        fallback_socket_path(uid)
    }

    #[cfg(windows)]
    {
        r"\\.\pipe\gpty".into()
    }

    // Other Unix platforms: no runtime directory convention is wired up, so a
    // private state directory is the first stop and the shared temp the last.
    #[cfg(all(unix, not(any(target_os = "linux", target_os = "macos"))))]
    {
        fallback_socket_path(unsafe { libc::geteuid() })
    }

    // Targets with neither a Unix socket nor a named pipe (wasm and friends):
    // a path is still the honest answer, even though nothing can bind it.
    #[cfg(not(any(unix, windows)))]
    {
        "/tmp/gpty.sock".into()
    }
}

/// A private state directory this user owns, for the fallback socket.
///
/// `$XDG_STATE_HOME/gpty` when set to an absolute path, else
/// `$HOME/.local/state/gpty`. The directory is created when missing, tightened
/// to 0700 when it exists but is lax (only if it is *ours* — another user's
/// directory is not ours to chmod), and validated with the same rule as a
/// runtime directory before it is used. `None` when neither variable names a
/// usable absolute path, which leaves the shared temp path as the documented
/// last resort.
///
/// This exists because the shared-`/tmp` fallback is squattable: a predictable
/// path in a world-writable directory lets another user hold the control
/// socket's name and deny service. Removing that needs a directory nobody else
/// can write to, not a less guessable filename — the client has to derive the
/// same path, so it cannot be random.
#[cfg(unix)]
fn private_state_dir(uid: u32) -> Option<std::path::PathBuf> {
    use std::os::unix::fs::MetadataExt;
    use std::os::unix::fs::PermissionsExt;

    let candidates = [
        std::env::var("XDG_STATE_HOME")
            .ok()
            .filter(|value| value.starts_with('/'))
            .map(|value| std::path::PathBuf::from(value).join("gpty")),
        std::env::var("HOME")
            .ok()
            .filter(|value| value.starts_with('/'))
            .map(|value| std::path::PathBuf::from(value).join(".local/state/gpty")),
    ];

    for dir in candidates.into_iter().flatten() {
        if !dir.exists() && std::fs::create_dir_all(&dir).is_err() {
            continue;
        }
        let Ok(meta) = std::fs::metadata(&dir) else {
            continue;
        };
        // Tighten only what is ours; a directory we do not own is skipped and
        // the next candidate (or the shared temp path) is used instead.
        if meta.uid() == uid && meta.mode() & 0o077 != 0 {
            let _ = std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700));
        }
        if is_secure_runtime_dir(&dir.to_string_lossy(), uid) {
            return Some(dir);
        }
    }
    None
}

/// The socket path used when no per-user runtime directory is available.
///
/// A private state directory when one can be had ([`private_state_dir`]),
/// otherwise the uid-suffixed path in the session temp directory. That last
/// resort is squattable — predictable in a world-writable place — so anything
/// above it is tried first; the socket itself is still validated (owner, mode)
/// before either side uses it, which makes squatting a denial of service rather
/// than a way in.
#[cfg(unix)]
fn fallback_socket_path(uid: u32) -> String {
    match private_state_dir(uid) {
        Some(dir) => format!("{}/gpty.sock", dir.display()),
        None => format!("/tmp/gpty-{uid}.sock"),
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

    /// Serialises every test that mutates the process environment. These
    /// variables are process-global and cargo runs one binary's tests on
    /// parallel threads, so an unlocked pair races for real: a run failed with
    /// `env_var_empty_falls_back` clearing `GPTY_SOCKET` between the
    /// `set_var` and the assertion of `env_var_overrides_default`.
    static ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    /// Sets or clears one environment variable while holding [`ENV_LOCK`],
    /// restoring the previous value (and releasing the lock) on drop —
    /// including on panic, so a failing test cannot leak its value into the
    /// rest of a parallel run.
    struct EnvVar {
        key: &'static str,
        previous: Option<std::ffi::OsString>,
        _lock: std::sync::MutexGuard<'static, ()>,
    }

    impl EnvVar {
        fn lock() -> std::sync::MutexGuard<'static, ()> {
            // A panicking test poisons the lock; its guard restored the value
            // on the way out, so the environment is still consistent.
            ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner())
        }

        fn set(key: &'static str, value: impl AsRef<std::ffi::OsStr>) -> Self {
            let lock = Self::lock();
            let previous = std::env::var_os(key);
            // SAFETY: the lock makes this the only test touching the variable,
            // and the guard restores it on drop.
            unsafe { std::env::set_var(key, value) };
            Self {
                key,
                previous,
                _lock: lock,
            }
        }

        fn clear(key: &'static str) -> Self {
            let lock = Self::lock();
            let previous = std::env::var_os(key);
            // SAFETY: as in `set`.
            unsafe { std::env::remove_var(key) };
            Self {
                key,
                previous,
                _lock: lock,
            }
        }
    }

    impl Drop for EnvVar {
        fn drop(&mut self) {
            match self.previous.take() {
                Some(previous) => unsafe { std::env::set_var(self.key, previous) },
                None => unsafe { std::env::remove_var(self.key) },
            }
        }
    }

    #[test]
    fn default_socket_path_is_non_empty() {
        let path = default_socket_path();
        assert!(!path.is_empty());
    }

    #[test]
    fn env_var_overrides_default() {
        let _env = EnvVar::set("GPTY_SOCKET", "/custom/path.sock");
        assert_eq!(default_socket_path(), "/custom/path.sock");
    }

    #[test]
    fn env_var_empty_falls_back() {
        let _env = EnvVar::set("GPTY_SOCKET", "");
        let path = default_socket_path();
        assert!(!path.is_empty());
        assert_ne!(path, "");
    }

    /// The same guard for a test that needs several variables at once.
    ///
    /// [`ENV_LOCK`] is a plain `Mutex`: taking two [`EnvVar`]s in one test
    /// deadlocks on the second (it did — the whole `xdg` module hung for
    /// minutes), so the variables a single resolution reads are set together.
    struct EnvVars {
        previous: Vec<(&'static str, Option<std::ffi::OsString>)>,
        _lock: std::sync::MutexGuard<'static, ()>,
    }

    impl EnvVars {
        /// Set or clear each variable under one guard; `None` clears a key.
        fn apply(changes: &[(&'static str, Option<&str>)]) -> Self {
            let lock = EnvVar::lock();
            let mut previous = Vec::with_capacity(changes.len());
            for (key, value) in changes {
                previous.push((*key, std::env::var_os(key)));
                // SAFETY: the guard makes this the only test touching these
                // variables, and it restores them on drop.
                unsafe {
                    match value {
                        Some(value) => std::env::set_var(key, value),
                        None => std::env::remove_var(key),
                    }
                }
            }
            Self {
                previous,
                _lock: lock,
            }
        }
    }

    impl Drop for EnvVars {
        fn drop(&mut self) {
            for (key, previous) in self.previous.drain(..) {
                match previous {
                    Some(previous) => unsafe { std::env::set_var(key, previous) },
                    None => unsafe { std::env::remove_var(key) },
                }
            }
        }
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

        // `XDG_RUNTIME_DIR` is process-global like `GPTY_SOCKET`, so every test
        // here guards it through the shared `EnvVar` above (the previous value
        // is restored on drop, including on panic).

        fn make_dir(name: &str, mode: u32) -> std::path::PathBuf {
            let dir = std::env::temp_dir().join(format!("{name}-{}", std::process::id()));
            std::fs::create_dir_all(&dir).unwrap();
            std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(mode)).unwrap();
            dir
        }

        #[test]
        fn default_socket_path_follows_a_secure_xdg_runtime_dir() {
            let secure = make_dir("gpty-xdg-test", 0o700);
            {
                let _env = EnvVar::set("XDG_RUNTIME_DIR", &secure);
                assert_eq!(
                    default_socket_path(),
                    format!("{}/gpty.sock", secure.display())
                );
            }
            std::fs::remove_dir_all(&secure).unwrap();
        }

        #[test]
        fn insecure_xdg_runtime_dir_is_rejected() {
            let insecure = make_dir("gpty-xdg-insecure", 0o777);
            {
                let _env = EnvVar::set("XDG_RUNTIME_DIR", &insecure);
                let path = default_socket_path();
                assert!(
                    !path.starts_with(&format!("{}/", insecure.display())),
                    "insecure XDG_RUNTIME_DIR {insecure:?} must not be used; got {path}"
                );
            }
            std::fs::remove_dir_all(&insecure).unwrap();
        }

        #[test]
        fn unset_xdg_runtime_dir_still_names_the_socket() {
            let state = std::env::temp_dir().join(format!("gpty-state-{}", std::process::id()));
            let _env = EnvVars::apply(&[
                ("XDG_RUNTIME_DIR", None),
                ("XDG_STATE_HOME", Some(state.to_str().unwrap())),
            ]);
            let path = default_socket_path();
            assert!(
                path.ends_with("gpty.sock"),
                "fallback must still name the control socket: {path}"
            );
        }

        /// The shared-`/tmp` path is predictable in a world-writable directory:
        /// another user can hold the name and deny the control surface. A
        /// private state directory removes that, so the fallback prefers one.
        ///
        /// Tested through the fallback itself rather than through
        /// `default_socket_path()`: on a machine where `/run/user/<uid>` exists
        /// and is private (every modern Linux), the chain legitimately stops
        /// before reaching here.
        #[test]
        fn the_fallback_prefers_a_private_state_dir_over_the_shared_tmp_path() {
            let state_root = make_dir("gpty-state-home", 0o700);
            let path;
            {
                let _env = EnvVars::apply(&[
                    ("XDG_STATE_HOME", Some(state_root.to_str().unwrap())),
                    ("HOME", None),
                ]);
                path = fallback_socket_path(unsafe { libc::geteuid() });
            }
            let expected = state_root.join("gpty/gpty.sock");
            assert_eq!(path, expected.to_string_lossy());
            // Created and private: that is what makes the path un-squattable.
            let meta = std::fs::metadata(state_root.join("gpty")).unwrap();
            assert_eq!(meta.permissions().mode() & 0o777, 0o700);
            std::fs::remove_dir_all(&state_root).unwrap();
        }

        /// A state directory that exists but is lax is tightened, not rejected
        /// and not written into as-is — the umask of whichever run created it
        /// must not leave the socket's directory open to others.
        #[test]
        fn the_fallback_tightens_a_lax_state_dir() {
            let state_root = make_dir("gpty-state-lax", 0o700);
            let lax = state_root.join("gpty");
            std::fs::create_dir_all(&lax).unwrap();
            std::fs::set_permissions(&lax, std::fs::Permissions::from_mode(0o755)).unwrap();

            let path;
            {
                let _env = EnvVars::apply(&[
                    ("XDG_STATE_HOME", Some(state_root.to_str().unwrap())),
                    ("HOME", None),
                ]);
                path = fallback_socket_path(unsafe { libc::geteuid() });
            }

            assert_eq!(path, lax.join("gpty.sock").to_string_lossy());
            assert_eq!(
                std::fs::metadata(&lax).unwrap().permissions().mode() & 0o777,
                0o700,
                "an existing state dir this user owns must be tightened to 0700"
            );
            std::fs::remove_dir_all(&state_root).unwrap();
        }

        /// With nowhere private to go, the documented last resort is the
        /// uid-suffixed path in the session temp directory.
        #[test]
        fn the_fallback_ends_in_the_shared_temp_directory() {
            let path;
            {
                let _env = EnvVars::apply(&[("XDG_STATE_HOME", None), ("HOME", None)]);
                path = fallback_socket_path(unsafe { libc::geteuid() });
            }
            assert_eq!(
                path,
                format!("/tmp/gpty-{}.sock", unsafe { libc::geteuid() }),
                "with no private directory the last resort is the shared temp path"
            );
        }

        /// Relative values are not directories in any useful sense, so they are
        /// ignored rather than joined onto the working directory.
        #[test]
        fn a_relative_state_dir_is_ignored() {
            let relative = format!("gpty-state-relative-{}", std::process::id());
            let path;
            {
                let _env = EnvVars::apply(&[("XDG_STATE_HOME", Some(&relative)), ("HOME", None)]);
                path = fallback_socket_path(unsafe { libc::geteuid() });
            }
            assert_eq!(
                path,
                format!("/tmp/gpty-{}.sock", unsafe { libc::geteuid() }),
                "a relative XDG_STATE_HOME must be ignored, not joined onto the working directory"
            );
        }
    }
}
