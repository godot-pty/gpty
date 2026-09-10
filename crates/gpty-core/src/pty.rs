//! Cross-platform PTY lifecycle via [`portable_pty`].
//!
//! Spawns a shell process connected to a pseudo-terminal, runs a
//! dedicated I/O thread for reading, and exposes write/resize operations.
//! Each PTY uses one OS thread.

use std::io::{Read, Write};
use std::thread;

use portable_pty::{CommandBuilder, MasterPty, PtySize, native_pty_system};
use tokio::sync::mpsc::UnboundedSender;

/// Environment variables that may not be set via pane/profile config.
/// These are dynamic-loader injection vectors: a shared or imported
/// layout carrying one of them would run arbitrary code in every shell
/// spawned from it. Users can still set them manually inside a shell.
const BLOCKED_ENV_KEYS: &[&str] = &[
    "LD_PRELOAD",
    "LD_AUDIT",
    "LD_LIBRARY_PATH",
    "LD_ORIGIN_PATH",
    "DYLD_INSERT_LIBRARIES",
    "DYLD_LIBRARY_PATH",
    "DYLD_FALLBACK_LIBRARY_PATH",
    "DYLD_FORCE_FLAT_NAMESPACE",
    "GPTY_EVENT_SOCKET",
    "GPTY_EVENT_PROTOCOL",
    "GPTY_TERMINAL_SESSION_ID",
    "GPTY_EVENT_CAPABILITY",
    // Pane-marker vars injected as trusted runtime values by start_shell().
    // Untrusted env (pane settings / layouts / profiles) must not override them.
    "GPTY_ENV",
    "GPTY_PANE_ID",
    // Process-wide control credentials. These are also stripped from the
    // inherited environment (see STRIPPED_INHERITED_ENV_KEYS) *before*
    // sanitize_envs() runs, so listing them here is what stops a persisted
    // pane/profile `shell_env` from re-adding them afterwards and letting a
    // child shell steer the workspace's control socket.
    "GPTY_SECRET",
    "GPTY_SOCKET",
    "GPTY_GUI",
];

/// Process-wide control credentials must never leak into child shells.
const STRIPPED_INHERITED_ENV_KEYS: &[&str] = &["GPTY_SECRET", "GPTY_SOCKET", "GPTY_GUI"];

/// Filter `KEY=VALUE` environment entries from settings/layouts/profiles.
///
/// Drops entries without `=`, with an empty or malformed key (must match
/// `[A-Za-z_][A-Za-z0-9_]*`), and keys in [`BLOCKED_ENV_KEYS`] (exact
/// case match — case variants are inert for the dynamic loaders).
pub fn sanitize_envs(envs: &[String]) -> Vec<(String, String)> {
    let mut out = Vec::with_capacity(envs.len());
    for e in envs {
        let Some((k, v)) = e.split_once('=') else {
            continue;
        };
        let k = k.trim();
        let v = v.trim();
        let mut chars = k.chars();
        let valid = chars
            .next()
            .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
            && chars.all(|c| c.is_ascii_alphanumeric() || c == '_');
        if !valid || BLOCKED_ENV_KEYS.contains(&k) {
            continue;
        }
        out.push((k.to_string(), v.to_string()));
    }
    out
}
const DEFAULT_ROWS: u16 = 24;
const DEFAULT_COLS: u16 = 80;
const READ_BUF_SIZE: usize = 4096;
/// Reject a program path that the untrusted layout/profile data could have
/// aimed at a file another user controls.
///
/// Saved tiles choose the program a terminal spawns, and that value is
/// executed verbatim. Bare names are left alone — the shipped profiles launch
/// tools by name through `PATH` (`omp`, `lazygit`, `nvim`) — but an absolute
/// path must be a regular file that is neither group- nor other-writable and
/// is owned either by this user or by root. The whole parent chain is held to
/// the same rule: a safe file can still be swapped for a hostile one when a
/// directory above it is group/other-writable without the sticky bit, so every
/// ancestor up to the filesystem root must be non-writable by others (a sticky
/// directory such as `/tmp` is allowed — only its owner may unlink entries).
/// That is the same standard `validate_gui_binary` and `resolve_omp_binary`
/// hold their binaries to, and it rejects the shared-`/tmp` payload a hostile
/// layout would point at.
pub fn validate_executable(program: &str) -> Result<(), String> {
    if program.is_empty() || !program.contains('/') {
        // PATH-resolved, as the shipped profiles do.
        return Ok(());
    }
    let path = std::path::Path::new(program);
    if !path.is_absolute() {
        return Err(format!("relative executable path: {program}"));
    }
    // Follow symlinks: on Arch and Fedora /bin is a symlink to /usr/bin, so
    // an lstat would reject the default shell outright. The checks below then
    // apply to the file that will actually be executed.
    let meta =
        std::fs::metadata(path).map_err(|e| format!("cannot stat executable {program}: {e}"))?;
    if !meta.is_file() {
        return Err(format!("executable is not a regular file: {program}"));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if meta.mode() & 0o022 != 0 {
            return Err(format!("group/other-writable executable: {program}"));
        }
        let owner = meta.uid();
        let me = unsafe { libc::geteuid() };
        if owner != me && owner != 0 {
            return Err(format!(
                "executable belongs to another user (uid {owner}): {program}"
            ));
        }
        // The file can be replaced rather than written to: a directory above
        // it that group or others may write to lets another user swap the
        // binary, even though the binary itself is 0755. /tmp is spared only
        // by its sticky bit, so walk to the root and refuse the first
        // non-sticky writable ancestor.
        let mut dir = path.parent();
        while let Some(current) = dir {
            // A component we cannot stat cannot be shown to be unsafe, and a
            // lazy/missing component must not turn into a false rejection.
            let Ok(dir_meta) = std::fs::metadata(current) else {
                break;
            };
            let dir_mode = dir_meta.mode();
            if dir_mode & 0o022 != 0 && dir_mode & 0o1000 == 0 {
                return Err(format!(
                    "executable lives in a group/other-writable directory ({}): {program}",
                    current.display()
                ));
            }
            dir = current.parent();
        }
    }
    Ok(())
}

/// A handle to a spawned PTY: shell process + I/O thread.
pub struct PtyHandle {
    pub id: u32,
    writer: Box<dyn Write + Send>,
    master: Box<dyn MasterPty + Send>,
    _child: Box<dyn portable_pty::Child + Send + Sync>,
    _read_thread: thread::JoinHandle<()>,
}

impl PtyHandle {
    /// OS process id of the child shell, when the platform exposes one.
    pub fn process_id(&self) -> Option<u32> {
        self._child.process_id()
    }

    /// Non-blocking exit reaping. `None` while the child is still running.
    pub fn try_wait(&mut self) -> Option<i32> {
        self._child
            .try_wait()
            .ok()
            .flatten()
            .map(|s| s.exit_code() as i32)
    }
}
impl Drop for PtyHandle {
    fn drop(&mut self) {
        let _ = self._child.kill();
        // Non-blocking reap: try_wait returns immediately.
        // If the child hasn't exited yet (brief race after kill),
        // the zombie is reaped when the process eventually exits.
        let _ = self._child.try_wait();
    }
}

impl PtyHandle {
    /// Spawn a shell process in a new PTY and start a reader thread.
    /// Output bytes are sent to `tx` as `Vec<u8>` chunks.
    pub fn spawn(
        id: u32,
        command: &str,
        args: &[&str],
        envs: &[String],
        trusted_envs: &[(String, String)],
        tx: UnboundedSender<Vec<u8>>,
    ) -> Result<Self, Box<dyn std::error::Error + Send + Sync>> {
        let pty_system = native_pty_system();
        let mut cmd = CommandBuilder::new(command);
        cmd.args(args);
        for key in STRIPPED_INHERITED_ENV_KEYS {
            cmd.env_remove(key);
        }
        cmd.env("TERM", "xterm-256color");
        for (k, v) in sanitize_envs(envs) {
            cmd.env(k, v);
        }
        // Trusted runtime values are generated by gpty and applied last. They
        // are never accepted from persisted pane/profile environment data.
        for (k, v) in trusted_envs {
            cmd.env(k, v);
        }

        let pty_pair = pty_system.openpty(PtySize {
            rows: DEFAULT_ROWS,
            cols: DEFAULT_COLS,
            pixel_width: 0,
            pixel_height: 0,
        })?;
        // Take the reader and writer BEFORE spawning. Both are fallible, and
        // doing them after spawn_command left a successfully-spawned shell
        // behind with no handle to kill it: portable-pty's child has no Drop
        // impl, so the process only dies if closing the master happens to
        // deliver SIGHUP (a child that ignores it would survive). With this
        // order nothing has been spawned when either call can still fail.
        let mut reader = pty_pair.master.try_clone_reader()?;
        let writer = pty_pair.master.take_writer()?;
        let mut child = pty_pair.slave.spawn_command(cmd)?;
        let master = pty_pair.master;

        // The reader thread is the last fallible step after the shell exists,
        // so its failure has to reap the child explicitly — there is no owner
        // to drop it and portable-pty's child has no Drop impl.
        let read_thread = match thread::Builder::new()
            .name(format!("pty-reader-{id}"))
            .spawn(move || {
                let mut buf = [0u8; READ_BUF_SIZE];
                loop {
                    match reader.read(&mut buf) {
                        Ok(0) => break,
                        Ok(n) => {
                            if tx.send(buf[..n].to_vec()).is_err() {
                                break;
                            }
                        }
                        Err(e) => {
                            log::error!("[PTY {id}] Read error: {e}");
                            break;
                        }
                    }
                }
            }) {
            Ok(handle) => handle,
            Err(e) => {
                let _ = child.kill();
                let _ = child.try_wait();
                return Err(e.into());
            }
        };

        Ok(Self {
            id,
            writer,
            master,
            _child: child,
            _read_thread: read_thread,
        })
    }

    /// Write a line to the PTY (appends `\r` = Enter).
    pub fn write_line(&mut self, line: &str) -> Result<(), std::io::Error> {
        self.writer.write_all(line.as_bytes())?;
        self.writer.write_all(b"\r")?;
        self.writer.flush()
    }

    /// Write raw bytes to the PTY (no newline appended).
    pub fn write_bytes(&mut self, data: &[u8]) -> Result<(), std::io::Error> {
        self.writer.write_all(data)?;
        self.writer.flush()
    }

    /// Resize the PTY — sends SIGWINCH to the child process.
    pub fn resize(
        &self,
        rows: u16,
        cols: u16,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        self.master.resize(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(v: &str) -> String {
        v.to_string()
    }

    #[test]
    fn sanitize_envs_drops_blocked_keys() {
        let envs = vec![
            s("LD_PRELOAD=/evil.so"),
            s("LD_AUDIT=/evil.so"),
            s("DYLD_INSERT_LIBRARIES=/evil.dylib"),
            s("GPTY_EVENT_SOCKET=/tmp/fake.sock"),
            s("GPTY_EVENT_CAPABILITY=stolen"),
            s("PATH=/usr/bin"),
        ];
        assert_eq!(
            sanitize_envs(&envs),
            vec![("PATH".to_string(), "/usr/bin".to_string())]
        );
    }

    #[test]
    fn sanitize_envs_blocklist_is_case_sensitive() {
        // Lowercase variants are inert for the dynamic loaders.
        let envs = vec![s("ld_preload=/x.so")];
        assert_eq!(
            sanitize_envs(&envs),
            vec![("ld_preload".to_string(), "/x.so".to_string())]
        );
    }

    #[test]
    fn sanitize_envs_drops_malformed_keys() {
        let envs = vec![
            s("-X=y"),
            s("1A=b"),
            s("=novalue"),
            s("no_equals"),
            s("A B=c"),
            s("OK=yes"),
        ];
        assert_eq!(
            sanitize_envs(&envs),
            vec![("OK".to_string(), "yes".to_string())]
        );
    }

    #[test]
    fn sanitize_envs_trims_key_and_value() {
        let envs = vec![s("  PATH = /usr/bin  ")];
        assert_eq!(
            sanitize_envs(&envs),
            vec![("PATH".to_string(), "/usr/bin".to_string())]
        );
    }

    // ── Pane-marker vars (GPTY_ENV, GPTY_PANE_ID) ───────────────────────────
    // These must be dropped from *untrusted* env (pane settings, layouts,
    // profiles) so a malicious layout cannot fake GPTY_ENV=1 to impersonate
    // a pane. They are injected as *trusted* runtime values by start_shell(),
    // bypassing sanitize_envs — the same two-part pattern as GPTY_EVENT_*.

    #[test]
    fn sanitize_envs_drops_gpty_env_from_untrusted() {
        // An attacker-controlled "GPTY_ENV=1" in pane settings must be dropped.
        let envs = vec![s("GPTY_ENV=1"), s("HOME=/root")];
        let out = sanitize_envs(&envs);
        assert!(
            !out.iter().any(|(k, _)| k == "GPTY_ENV"),
            "GPTY_ENV must be blocked from untrusted env"
        );
        // Unrelated key survives.
        assert!(out.iter().any(|(k, _)| k == "HOME"));
    }

    #[test]
    fn sanitize_envs_drops_gpty_pane_id_from_untrusted() {
        // An attacker-controlled "GPTY_PANE_ID=spoofed" in pane settings
        // must be dropped.
        let envs = vec![s("GPTY_PANE_ID=spoofed"), s("HOME=/root")];
        let out = sanitize_envs(&envs);
        assert!(
            !out.iter().any(|(k, _)| k == "GPTY_PANE_ID"),
            "GPTY_PANE_ID must be blocked from untrusted env"
        );
        assert!(out.iter().any(|(k, _)| k == "HOME"));
    }

    #[cfg(unix)]
    #[test]
    fn validate_executable_refuses_paths_another_user_controls() {
        use std::os::unix::fs::PermissionsExt;
        // Bare names are PATH-resolved — the shipped profiles launch `omp`,
        // `lazygit` and `nvim` that way, so they must stay allowed.
        assert!(validate_executable("omp").is_ok());
        assert!(validate_executable("").is_ok());
        // A system binary owned by root is fine.
        assert!(validate_executable("/bin/sh").is_ok());

        // An absolute path in a shared, writable location is not.
        let path = std::env::temp_dir().join(format!("gpty_exec_{}", std::process::id()));
        std::fs::write(&path, b"#!/bin/sh\n").unwrap();
        let mut perms = std::fs::metadata(&path).unwrap().permissions();
        perms.set_mode(0o777);
        std::fs::set_permissions(&path, perms.clone()).unwrap();
        assert!(
            validate_executable(&path.to_string_lossy()).is_err(),
            "group/other-writable executable must be refused"
        );

        // The same file, private to its owner, is accepted.
        perms.set_mode(0o755);
        std::fs::set_permissions(&path, perms).unwrap();
        assert!(validate_executable(&path.to_string_lossy()).is_ok());
        let _ = std::fs::remove_file(&path);

        // A safe 0755 binary is still replaceable when its *directory* is
        // writable by group or others. This is the /tmp-without-`t` case.
        let shared = std::env::temp_dir().join(format!("gpty_exec_dir_{}", std::process::id()));
        std::fs::create_dir_all(&shared).unwrap();
        std::fs::set_permissions(&shared, std::fs::Permissions::from_mode(0o777)).unwrap();
        let inner = shared.join("payload");
        std::fs::write(&inner, b"#!/bin/sh\n").unwrap();
        std::fs::set_permissions(&inner, std::fs::Permissions::from_mode(0o755)).unwrap();
        let in_open_dir = validate_executable(&inner.to_string_lossy());
        // The sticky bit restores /tmp semantics: only the entry's owner may
        // rename or unlink it, so a writable directory is acceptable again.
        std::fs::set_permissions(&shared, std::fs::Permissions::from_mode(0o1777)).unwrap();
        let in_sticky_dir = validate_executable(&inner.to_string_lossy());

        // Restore and remove before asserting: an unconditional cleanup that
        // runs first cannot leave a world-writable directory behind.
        let _ = std::fs::set_permissions(&shared, std::fs::Permissions::from_mode(0o700));
        let _ = std::fs::remove_dir_all(&shared);
        assert!(
            in_open_dir.is_err(),
            "0755 file in a 0777 non-sticky directory must be refused"
        );
        // The refusal must come from the directory rule and name that
        // directory — the 0755 file itself is fine in both runs.
        let refusal = in_open_dir.unwrap_err();
        assert!(
            refusal.contains("group/other-writable directory")
                && refusal.contains(&shared.display().to_string()),
            "refusal must name the directory at fault, got: {refusal}"
        );
        assert!(
            in_sticky_dir.is_ok(),
            "0755 file in a 1777 sticky directory must be accepted"
        );

        // Not a regular file, and not absolute.
        assert!(validate_executable("/tmp").is_err());
        assert!(validate_executable("./relative").is_err());
    }

    #[test]
    fn sanitize_envs_drops_control_credentials_from_untrusted() {
        // PtyHandle::spawn() strips these from the inherited environment, but
        // that runs *before* sanitize_envs(). Without the blocklist entry a
        // persisted pane/profile `shell_env` could re-add GPTY_SOCKET and let
        // the child shell point at an attacker-controlled control socket.
        let envs = vec![s("GPTY_SOCKET=/tmp/x"), s("HOME=/root")];
        assert_eq!(
            sanitize_envs(&envs),
            vec![("HOME".to_string(), "/root".to_string())]
        );
    }

    #[test]
    fn trusted_envs_contain_gpty_env_and_pane_id() {
        // The trusted_envs vector constructed by start_shell() bypasses
        // sanitize_envs and is applied last by PtyHandle::spawn().
        // Verify the expected shape — both keys are valid and non-empty.
        let attachment_id = "my-pane".to_string();
        let trusted: Vec<(String, String)> = vec![
            ("GPTY_ENV".to_string(), "1".to_string()),
            ("GPTY_PANE_ID".to_string(), attachment_id.clone()),
        ];
        // Neither key should appear if passed through sanitize_envs
        // (confirming they ARE blocked from the untrusted path).
        let as_untrusted: Vec<String> = trusted.iter().map(|(k, v)| format!("{k}={v}")).collect();
        assert!(
            sanitize_envs(&as_untrusted).is_empty(),
            "GPTY_ENV and GPTY_PANE_ID must be blocked from untrusted env"
        );
        // But the trusted vec is well-formed for direct injection.
        assert_eq!(trusted[0], ("GPTY_ENV".to_string(), "1".to_string()));
        assert_eq!(trusted[1], ("GPTY_PANE_ID".to_string(), attachment_id));
    }
}
