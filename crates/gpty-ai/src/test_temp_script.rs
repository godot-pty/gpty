//! Test-only helper: a generated script file that deletes itself.
//!
//! `fake_adapter`-style helpers write a shell script per test and return its
//! path. Without a drop guard the suite leaves one file per adapter test in
//! `/tmp` — including on a panic, which is exactly when a manual
//! `remove_file` at the end of the test is skipped.
//!
//! The script lives in a private temporary directory that the guard owns, so
//! the file *and* its directory are removed on drop, panics included. The
//! directory is unique per call, which is also what keeps parallel tests from
//! reading each other's script: no process id or clock tick has to be unique.

use std::path::{Path, PathBuf};

/// Owns a generated script and the private directory holding it, removing
/// both when dropped, panics included.
pub(crate) struct TempScript {
    path: PathBuf,
    // Held only for its destructor: dropping it removes the directory and the
    // script inside it.
    _dir: tempfile::TempDir,
}

impl TempScript {
    /// Write `contents` to `name` in a fresh private directory, which is
    /// created and removed with the script.
    pub(crate) fn write(name: &str, contents: &[u8]) -> Self {
        let dir = tempfile::TempDir::new().expect("temp dir");
        let path = dir.path().join(name);
        std::fs::write(&path, contents).expect("write temp script");
        Self { path, _dir: dir }
    }

    /// The script's path.
    pub(crate) fn path(&self) -> &Path {
        &self.path
    }
}
