//! Owner-only modes for gPTY's own files, repaired on the way in.
//!
//! Every store gPTY keeps is meant for its owner alone: pane environments,
//! shell commands, window geometry, scrollback. The *write* path sets the mode
//! (`BasePersistenceManager` writes a store at 0600, and
//! [`crate::history::HistoryStore`] chmods its SQLite file and its `-wal`/`-shm`
//! siblings), but a file written by an older build, or a directory the engine
//! created, carries whatever the process umask produced. Measured on a normal
//! install: `layout.json` and `profiles.json` at 0644 next to `concepts.json`
//! at 0600, and the `user://` root at 0755 - and a store that is never saved
//! again keeps its old mode indefinitely.
//!
//! So there is a second, best-effort half: repair the mode when a store is
//! read, and once for the directory that holds them. Both go through this
//! module rather than a bare `chmod` because of the two things a repair must
//! not do:
//!
//! - **Never through a symlink.** A link planted at a store path would
//!   otherwise hand gPTY a `chmod` of someone else's file. The path is opened
//!   with `O_NOFOLLOW`, so the mode is changed on the object the caller named;
//!   a link is skipped, not followed (the write path already replaces a link
//!   by renaming over it).
//! - **Never loosen, never touch what is not ours.** Only a mode with
//!   group/other bits set is rewritten, only for a file this user owns, and
//!   only to [`FILE_MODE`] or [`DIR_MODE`]. A path owned by another account is
//!   skipped silently: it is not a diagnostic a user can act on, and turning
//!   it into a warning would print on every launch.
//!
//! Windows needs none of this (its files inherit the profile directory's
//! ACLs), and a mode that cannot be read or set is worth a log line rather
//! than a failed load — the caller decides where to say it.

use std::path::Path;

/// Mode for a store file: owner read/write only (0600).
pub const FILE_MODE: u32 = 0o600;

/// Mode for a directory that holds stores: owner only (0700).
pub const DIR_MODE: u32 = 0o700;

/// What a tightening call did.
#[derive(Debug)]
pub enum Restriction {
    /// Nothing to do: the path is missing, already owner-only, a symlink, not
    /// the file/directory kind the caller named, or owned by another account.
    Untouched,
    /// The mode was looser than the owner-only rule and is now that mode.
    Tightened,
    /// The mode could not be read or set. Best effort: the caller logs it and
    /// carries on with the load that asked.
    Failed(std::io::Error),
}

impl Restriction {
    /// A diagnostic for a caller that logs the outcome, or `None` when there
    /// is nothing to report.
    pub fn problem(&self, path: &str) -> Option<String> {
        match self {
            Restriction::Failed(e) => Some(format!("{path}: {e}")),
            _ => None,
        }
    }
}

/// Tighten a file to [`FILE_MODE`] when it is this user's and looser.
pub fn restrict_file(path: &Path) -> Restriction {
    restrict(path, FILE_MODE, false)
}

/// Tighten a directory to [`DIR_MODE`] when it is this user's and looser.
pub fn restrict_dir(path: &Path) -> Restriction {
    restrict(path, DIR_MODE, true)
}

#[cfg(unix)]
fn restrict(path: &Path, want: u32, want_dir: bool) -> Restriction {
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};

    // `O_NOFOLLOW` is the symlink refusal; the open also gives the mode change
    // a descriptor, so the path cannot be swapped for a link between the check
    // and the `fchmod` below.
    let opened = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path);
    let file = match opened {
        Ok(file) => file,
        // A path that is not there has no mode to repair.
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Restriction::Untouched,
        Err(e) => {
            // The errno for a refused symlink is ELOOP on Linux and macOS but
            // the decision must not rest on it: ask the path what it is, with
            // the one call that does not follow. A link is skipped silently.
            return match std::fs::symlink_metadata(path) {
                Ok(meta) if meta.file_type().is_symlink() => Restriction::Untouched,
                _ => Restriction::Failed(e),
            };
        }
    };
    let meta = match file.metadata() {
        Ok(meta) => meta,
        Err(e) => return Restriction::Failed(e),
    };
    if meta.is_dir() != want_dir
        || meta.uid() != unsafe { libc::geteuid() }
        || meta.mode() & 0o077 == 0
    {
        return Restriction::Untouched;
    }
    // SAFETY: `fchmod` reads the descriptor this function owns and sets a mode;
    // it touches no memory. `mode_t` is `u16` on the BSDs, and the two modes
    // this module applies are 0600 and 0700, so the cast cannot lose a bit.
    match unsafe { libc::fchmod(file.as_raw_fd(), want as libc::mode_t) } {
        0 => Restriction::Tightened,
        _ => Restriction::Failed(std::io::Error::last_os_error()),
    }
}

#[cfg(not(unix))]
fn restrict(_path: &Path, _want: u32, _want_dir: bool) -> Restriction {
    // Windows inherits the profile directory's ACLs; there is no mode to repair.
    Restriction::Untouched
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;

    /// A directory of this test's own, removed by `cleanup`.
    fn scratch(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("gpty_owner_only_{}_{}", name, std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[cfg(unix)]
    fn mode_of(path: &Path) -> u32 {
        fs::metadata(path).unwrap().permissions().mode() & 0o777
    }

    #[cfg(unix)]
    #[test]
    fn a_loose_file_is_tightened() {
        let dir = scratch("loose_file");
        let path = dir.join("store.json");
        fs::write(&path, b"{}").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();

        assert!(matches!(restrict_file(&path), Restriction::Tightened));
        assert_eq!(
            mode_of(&path),
            FILE_MODE,
            "contents stay, the mode must not"
        );
        assert_eq!(
            fs::read(&path).unwrap(),
            b"{}",
            "tightening must not touch content"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    fn an_owner_only_file_is_left_alone() {
        let dir = scratch("already_private");
        let path = dir.join("store.json");
        fs::write(&path, b"{}").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(FILE_MODE)).unwrap();

        assert!(matches!(restrict_file(&path), Restriction::Untouched));
        assert_eq!(mode_of(&path), FILE_MODE);
        let _ = fs::remove_dir_all(&dir);
    }

    /// The repair must never reach through a link: a symlink at a store path
    /// is not gPTY's file, and a `chmod` that followed it would change a file
    /// outside the stores (or outside the user's own files).
    #[cfg(unix)]
    #[test]
    fn a_symlink_is_skipped_and_its_target_is_untouched() {
        let dir = scratch("symlink");
        let victim = dir.join("victim.txt");
        fs::write(&victim, b"not a store").unwrap();
        fs::set_permissions(&victim, fs::Permissions::from_mode(0o644)).unwrap();
        let link = dir.join("store.json");
        std::os::unix::fs::symlink(&victim, &link).unwrap();

        assert!(matches!(restrict_file(&link), Restriction::Untouched));
        assert_eq!(
            mode_of(&victim),
            0o644,
            "the link's target must keep its mode"
        );
        assert_eq!(mode_of(&link), 0o644, "and the link is a link, not a mode");
        let _ = fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    fn a_loose_directory_is_tightened_and_a_private_one_is_not() {
        let dir = scratch("directory");
        let target = dir.join("stores");
        fs::create_dir(&target).unwrap();
        fs::set_permissions(&target, fs::Permissions::from_mode(0o755)).unwrap();

        assert!(matches!(restrict_dir(&target), Restriction::Tightened));
        assert_eq!(mode_of(&target), DIR_MODE);
        assert!(matches!(restrict_dir(&target), Restriction::Untouched));
        let _ = fs::remove_dir_all(&dir);
    }

    /// The kind is part of the contract: a store read must not `chmod` a
    /// directory shaped like a store, and the root repair must not `chmod` a
    /// file, because `0600` on a directory makes it unusable and `0700` on a
    /// file makes it executable.
    #[cfg(unix)]
    #[test]
    fn the_wrong_kind_is_left_alone() {
        let dir = scratch("wrong_kind");
        let target = dir.join("stores");
        fs::create_dir(&target).unwrap();
        fs::set_permissions(&target, fs::Permissions::from_mode(0o755)).unwrap();

        assert!(matches!(restrict_file(&target), Restriction::Untouched));
        assert_eq!(mode_of(&target), 0o755);

        let file = dir.join("store.json");
        fs::write(&file, b"{}").unwrap();
        fs::set_permissions(&file, fs::Permissions::from_mode(0o644)).unwrap();
        assert!(matches!(restrict_dir(&file), Restriction::Untouched));
        assert_eq!(mode_of(&file), 0o644);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_missing_path_is_not_a_failure() {
        let dir = scratch("missing");
        let missing = dir.join("never-written.json");
        assert!(matches!(restrict_file(&missing), Restriction::Untouched));
        assert!(matches!(restrict_dir(&missing), Restriction::Untouched));
        assert!(restrict_file(&missing).problem("x").is_none());
        let _ = fs::remove_dir_all(&dir);
    }

    /// A path whose *parent chain* is not a directory cannot even be opened for
    /// the repair - the shape of a filesystem that refuses the change. It is
    /// reported, never panicked on, and the caller's load carries on.
    #[cfg(unix)]
    #[test]
    fn an_unopenable_path_reports_the_reason() {
        let dir = scratch("unopenable");
        let blocker = dir.join("store.json");
        fs::write(&blocker, b"{}").unwrap();
        let unreachable = blocker.join("inner.json");

        let result = restrict_file(&unreachable);
        assert!(matches!(result, Restriction::Failed(_)), "got {result:?}");
        let text = result
            .problem("store")
            .expect("a failure must have a message");
        assert!(
            text.starts_with("store: "),
            "the message names the path: {text}"
        );
        let _ = fs::remove_dir_all(&dir);
    }
}
