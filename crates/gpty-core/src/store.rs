//! Shared SQLite store plumbing for gPTY's two indexes.
//!
//! The scrollback store ([`crate::history::HistoryStore`]) and the vault index
//! ([`crate::vault::VaultStore`]) are one shape of store: a SQLite file with
//! an external-content FTS5 index, the same two pragmas, an owner-only mode,
//! and a version gate of its own. They also learned the same operational
//! lessons twice, so this module holds them once:
//!
//! - **One writer at a time, per process.** [`write_guard`] serializes every
//!   write — and every open, which may move a damaged file aside — across both
//!   stores.
//! - **A file SQLite cannot read is repairable.** [`open_with_recovery`] moves
//!   it aside and replaces it instead of ending that store for good.
//! - **The files are the owner's.** [`restrict_to_owner`] repairs the mode of
//!   a store and its WAL siblings.

use std::sync::{Mutex, MutexGuard};

use crate::lock::lock_or_warn;

/// One writer per store file at a time, for this whole process.
///
/// Every pane's history writer owns its *own* connection to the same file
/// ([`crate::history::HistoryStore::open`]), and SQLite serializes writers per
/// file: N panes meant N writers racing for the write lock, with only
/// `busy_timeout` between them and `SQLITE_BUSY`. That wait is not a queue and
/// can starve a writer — measured on `windows-smoke`, a commit passed a 5 s
/// expiry and the batch was dropped with `history append failed (2 rows):
/// database is locked`.
///
/// Taking this guard around each write makes that impossible by construction
/// for anything inside this process (which is every pane; a GUI is one
/// process). It is always the *innermost* lock — acquired inside a store
/// method, so a caller may hold the per-pane store mutex while taking it, and
/// nothing may take a store mutex while holding it — so the order cannot
/// invert, and it is held only across one transaction — or, for
/// [`open_with_recovery`], across one open, which may also move a damaged file
/// aside and must not interleave with another pane creating the same path.
static WRITE_LOCK: Mutex<()> = Mutex::new(());

/// Serialize this process's writes to any one SQLite store file.
///
/// `None` — the lock was poisoned by a panic on another thread — means the
/// write proceeds **unserialized** rather than not at all: losing the
/// serialization risks a `SQLITE_BUSY` that the busy timeout still waits out,
/// while skipping the write would lose the rows outright. (Elsewhere the
/// policy is the opposite, and [`lock_or_warn`]'s doc says why: skipping is how
/// a pane keeps rendering through someone else's panic. A dropped batch's only
/// second chance was the retention window.)
pub(crate) fn write_guard() -> Option<MutexGuard<'static, ()>> {
    lock_or_warn(&WRITE_LOCK, "store write lock")
}

/// Restrict a store file to its owner.
///
/// SQLite creates the database (and the `-wal`/`-shm` siblings it needs) with
/// the process umask, so under a permissive umask — or a `user://` another
/// account can read — every pane's scrollback and every vault note's indexed
/// text is readable by others. The mechanism is
/// [`crate::owner_only::restrict_file`], shared with the GDScript stores'
/// repair path, so a symlink at the database path is skipped rather than
/// chmod'd through. Best effort by design: a sibling may not exist yet, and a
/// mode that cannot be set is worth a log line, not a failed pane.
pub(crate) fn restrict_to_owner(path: &str) {
    if let Some(problem) =
        crate::owner_only::restrict_file(std::path::Path::new(path)).problem(path)
    {
        log::warn!("could not restrict a store to its owner ({problem})");
    }
}

/// Whether `err` says the file at the path is not a database at all.
///
/// The distinction is the difference between a store that is unusable and one
/// that is merely busy or unwritable: only these two codes mean no future open
/// will ever succeed, so only these two license moving the file aside. A
/// `SQLITE_BUSY` or a permission error must leave it where it is.
fn is_unreadable_store(err: &rusqlite::Error) -> bool {
    matches!(
        err,
        rusqlite::Error::SqliteFailure(inner, _)
            if matches!(
                inner.code,
                rusqlite::ErrorCode::NotADatabase | rusqlite::ErrorCode::DatabaseCorrupt
            )
    )
}

/// Open a store, replacing a file SQLite cannot read.
///
/// `label` names the store in the warning (`"scrollback store"`, `"vault
/// index"`); `open` performs the caller's own open (pragmas, version gate,
/// schema) and is called again against the replacement. The whole call runs
/// under [`write_guard`], not just the replacement: SQLite *creates* a
/// database that is missing, so a second opener racing the move would either
/// have its fresh store renamed away with the damaged one, or create the file
/// in the gap between the move and the replacement.
///
/// On an unreadable file the damaged database and its `-wal`/`-shm` siblings
/// move to `<path>.corrupt` ([`quarantine_unreadable`]) and `open` is tried
/// once more. A move that fails leaves the store exactly as unusable as it
/// was, and the caller's own error — the one out of `open` — is what it gets
/// back; the recovery's own failure is the second log line.
pub(crate) fn open_with_recovery<T>(
    label: &str,
    path: &str,
    open: impl Fn() -> Result<T, rusqlite::Error>,
) -> Result<T, rusqlite::Error> {
    let _serialized = write_guard();
    match open() {
        Err(e) if is_unreadable_store(&e) => {
            let aside = format!("{path}.corrupt");
            log::warn!("{label} {path} is unreadable ({e}); moving it aside to {aside}");
            if !quarantine_unreadable(path) {
                return Err(e);
            }
            open().map_err(|failed| {
                log::warn!("could not replace the unreadable {label} {path}: {failed}");
                // The caller's message stays the one that names the real
                // problem; the recovery's own failure is the second line.
                e
            })
        }
        other => other,
    }
}

/// Move a store file SQLite cannot read, and its WAL siblings, aside.
///
/// The unreadable file is moved, never deleted: on the scrollback store it is
/// the user's output, and a damaged file may still be worth recovering by
/// hand. The `-wal` and `-shm` siblings move *with* it, *before* the database
/// itself — a stale `-wal` left beside the fresh store could replay the old
/// file's frames into it — and a sibling that cannot be moved stops the whole
/// replacement while the database is still in place, so a failure leaves the
/// store exactly as unusable as it was. Answers whether nothing of the damaged
/// store is left at `path`.
///
/// The target is one fixed name, not a timestamped one: a file that cannot be
/// opened is opened again on every launch, and accumulating a copy per launch
/// would be a slow leak in `user://`.
///
/// The caller holds [`write_guard`], which is what makes the move exclusive to
/// this process — every pane opens a store, and they all open the same file at
/// startup.
fn quarantine_unreadable(path: &str) -> bool {
    let aside = format!("{path}.corrupt");
    for suffix in ["-wal", "-shm", ""] {
        let source = format!("{path}{suffix}");
        match std::fs::rename(&source, format!("{aside}{suffix}")) {
            Ok(()) => {}
            // Never existed: there is no part of the damaged store at this
            // path to move.
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => {
                log::warn!("could not move the unreadable store {source} aside: {e}");
                return false;
            }
        }
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    /// A test's own directory and a DB path inside it. The returned guard
    /// must outlive the move: it removes the file and its WAL siblings.
    fn temp_db_path(name: &str) -> (tempfile::TempDir, String) {
        let dir = tempfile::TempDir::new().expect("temp dir");
        let path = dir
            .path()
            .join(format!("gpty_store_test_{name}.db"))
            .to_string_lossy()
            .into_owned();
        (dir, path)
    }

    /// The WAL siblings move *with* the database, before it, under the same
    /// fixed name. `open` rarely gets to do this — SQLite deletes an
    /// unreadable `-wal` itself while failing — so this drives the move
    /// directly: a sibling left at the store's path is the one state that
    /// could corrupt the replacement.
    #[test]
    fn recovery_moves_the_wal_siblings_with_the_store() {
        let (_tmp, path) = temp_db_path("sibling_move");
        fs::write(&path, b"not a database").unwrap();
        fs::write(format!("{path}-wal"), b"stale wal frames").unwrap();
        fs::write(format!("{path}-shm"), b"stale wal index").unwrap();

        let guard = write_guard();
        assert!(guard.is_some(), "the write lock must be healthy");
        assert!(quarantine_unreadable(&path), "the move must succeed");
        drop(guard);

        assert_eq!(
            fs::read(format!("{path}.corrupt")).unwrap(),
            b"not a database"
        );
        assert_eq!(
            fs::read(format!("{path}.corrupt-wal")).unwrap(),
            b"stale wal frames"
        );
        assert_eq!(
            fs::read(format!("{path}.corrupt-shm")).unwrap(),
            b"stale wal index"
        );
        assert!(
            !std::path::Path::new(&path).exists(),
            "nothing of the damaged store stays at the store's path"
        );
    }
}
