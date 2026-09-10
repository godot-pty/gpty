//! Test-only helper: a generated script file that deletes itself.
//!
//! `fake_adapter`-style helpers write a shell script per test and return its
//! path. Without a drop guard the suite leaves one file per adapter test in
//! `/tmp` — including on a panic, which is exactly when a manual
//! `remove_file` at the end of the test is skipped.

use std::path::{Path, PathBuf};

/// Owns a generated script and removes it when dropped, panics included.
pub(crate) struct TempScript(PathBuf);

impl TempScript {
    /// Take ownership of `path`, which is removed on drop.
    pub(crate) fn new(path: PathBuf) -> Self {
        Self(path)
    }

    /// The script's path.
    pub(crate) fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TempScript {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}
