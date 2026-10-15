//! Vault-index facet of `GptyTerminal`: the SQLite + FTS5 store behind the
//! wiki pane's note list and search.
//!
//! The walk that decides what a note is lives in one place
//! (`gpty_core::vault`) so the pane's list and the search index cannot
//! disagree, and both functions here are static — the answer is about a vault
//! directory, not a terminal — so the pane can call them without owning a
//! grid, exactly like `history_store_stats`.

use crate::GptyTerminal;
use godot::prelude::*;

/// Where the vault index lives: the app's private state directory, beside the
/// CLI's other process-shared files and never inside a vault. A vault is user
/// data this feature only reads, and the roadmap's agent-access item needs the
/// same index reachable from the CLI, which cannot resolve `user://`.
fn vault_db_path() -> Option<String> {
    gpty_ipc::transport::state_dir().map(|dir| dir.join("vaults.db").to_string_lossy().into_owned())
}

/// Where the editor's recovery copies live: gpty's own scratch directory in
/// the state directory, beside the vault index and never inside a vault. An
/// unsaved buffer is gpty's state, not the user's files; the directory is
/// created on the first write, owner-only.
fn scratch_dir_path() -> Option<String> {
    gpty_ipc::transport::state_dir().map(|dir| dir.join("scratch").to_string_lossy().into_owned())
}

fn vault_error(message: &str) -> GString {
    let document = serde_json::json!({ "error": message }).to_string();
    GString::from(document.as_str())
}

/// A recovery-copy failure's document.
///
/// The split is the one [`note_failure_is_diagnostic`] already makes: an I/O
/// failure is a diagnostic nobody asked for (the copy is background work, the
/// pane shows no error for it, and nothing else surfaces the reason), while a
/// bad vault, a path outside the walk's vocabulary, or an oversize buffer is
/// the caller's own request being refused by code — logged, that would be
/// noise, and in the wire test below it would fail a GUT run that is
/// legitimately asking for the refusal (GUT counts an engine error as a
/// failure).
fn scratch_error(error: gpty_core::vault::NoteError) -> GString {
    if note_failure_is_diagnostic(&error) {
        log::warn!("vault recovery copy failed: {error}");
    }
    note_error(error)
}

/// A note-path error's document: the message plus the stable `code` the pane
/// switches on (`changed_on_disk` is what offers an explicit overwrite).
fn note_error(error: gpty_core::vault::NoteError) -> GString {
    let document =
        serde_json::json!({ "error": error.to_string(), "code": error.code() }).to_string();
    GString::from(document.as_str())
}

/// Whether a note failure deserves a log line. Refusals the caller asked
/// about — a path outside the walk's vocabulary, a note that moved, a stale
/// stamp, content over the cap — are reported through the pane's toast or
/// overwrite dialog; only a containment refusal (a symlink trying to leave
/// the vault) and an I/O failure are diagnostics, because nobody asked for
/// them and nothing else surfaces them.
fn note_failure_is_diagnostic(error: &gpty_core::vault::NoteError) -> bool {
    matches!(
        error,
        gpty_core::vault::NoteError::Outside | gpty_core::vault::NoteError::Io(_)
    )
}
/// Bring one vault's index up to date, answering whether it worked. A save
/// whose re-index fails is still a saved note, so this never fails its caller.
fn reindex_vault(root: &str) -> bool {
    let Some(db) = vault_db_path() else {
        return false;
    };
    match gpty_core::vault::VaultStore::open(&db) {
        Ok(mut store) => match gpty_core::vault::index_vault(&mut store, root) {
            Ok(_) => true,
            Err(e) => {
                log::warn!("vault re-index after a save failed ({root}): {e}");
                false
            }
        },
        Err(e) => {
            log::warn!("vault index open failed ({db}): {e}");
            false
        }
    }
}

/// Why `path` cannot be a vault root, or `None` when it can.
fn vault_path_problem(path: &str) -> Option<String> {
    let candidate = std::path::Path::new(path);
    if path.is_empty() {
        return Some("no vault path".to_string());
    }
    if !candidate.is_absolute() {
        return Some(format!("not an absolute path: {path}"));
    }
    if !candidate.is_dir() {
        return Some(format!("not a directory: {path}"));
    }
    None
}

#[godot_api(secondary)]
impl GptyTerminal {
    /// Index a vault and return its note list (JSON).
    ///
    /// Walks `vault_path` for Markdown notes (hidden entries skipped at every
    /// level, bounded in count and depth), re-reads only the notes whose
    /// mtime or size changed, drops rows for notes that vanished, and returns
    /// `{"notes": ["note.md", "sub/other.md", ...], "truncated": bool,
    /// "added": n, "updated": n, "removed": n, "unreadable": n}` with the
    /// notes sorted by path (the vault-relative paths a list row shows; a
    /// title is a search-result field, read from the indexed body).
    /// `error` is present only when the path cannot be used or the store
    /// cannot be opened, so "empty vault" and "failed" stay distinguishable.
    #[func]
    fn vault_index(vault_path: GString) -> GString {
        let path = vault_path.to_string();
        if let Some(problem) = vault_path_problem(&path) {
            return vault_error(&problem);
        }
        let Some(db) = vault_db_path() else {
            return vault_error("no writable state directory for the vault index");
        };
        let mut store = match gpty_core::vault::VaultStore::open(&db) {
            Ok(store) => store,
            Err(e) => {
                log::warn!("vault index open failed ({db}): {e}");
                return vault_error(&format!("vault index unavailable: {e}"));
            }
        };
        match gpty_core::vault::index_vault(&mut store, &path) {
            Ok(outcome) => {
                let notes: Vec<&str> = outcome
                    .notes
                    .iter()
                    .map(|note| note.rel_path.as_str())
                    .collect();
                let document = serde_json::json!({
                    "notes": notes,
                    "truncated": outcome.truncated,
                    "added": outcome.added,
                    "updated": outcome.updated,
                    "removed": outcome.removed,
                    "unreadable": outcome.unreadable,
                })
                .to_string();
                GString::from(document.as_str())
            }
            Err(e) => {
                log::warn!("vault index pass failed ({path}): {e}");
                vault_error(&format!("vault index failed: {e}"))
            }
        }
    }

    /// Search one vault's index with free text (JSON).
    ///
    /// `pattern` is free text as a user typed it, not an FTS5 query: it is
    /// sanitised first (raw `MATCH` rejects ordinary searches such as
    /// `main.rs`), terms are ANDed, and notes are stemmed (porter) because a
    /// vault is prose. Returns
    /// `{"results": [{"path", "title", "snippet"}, ...], "total": N}`
    /// best-rank-first; `error` is present only when the query could not run,
    /// so a caller can distinguish "no match" from "not indexed". `limit` is
    /// clamped to 1..=500.
    #[func]
    fn vault_search(vault_path: GString, pattern: GString, limit: i64) -> GString {
        let path = vault_path.to_string();
        if let Some(problem) = vault_path_problem(&path) {
            return vault_error(&problem);
        }
        let text = pattern.to_string();
        let Some(db) = vault_db_path() else {
            return vault_error("no writable state directory for the vault index");
        };
        let store = match gpty_core::vault::VaultStore::open(&db) {
            Ok(store) => store,
            Err(e) => {
                log::warn!("vault index open failed ({db}): {e}");
                return vault_error(&format!("vault index unavailable: {e}"));
            }
        };
        let limit = limit.clamp(1, gpty_core::vault::SEARCH_LIMIT_MAX as i64) as usize;
        match store.search_user_text(&path, &text, limit) {
            Ok(hits) => {
                let results: Vec<serde_json::Value> = hits
                    .iter()
                    .map(|hit| {
                        serde_json::json!({
                            "path": hit.rel_path,
                            "title": hit.title,
                            "snippet": hit.snippet,
                        })
                    })
                    .collect();
                let document =
                    serde_json::json!({ "results": results, "total": hits.len() }).to_string();
                GString::from(document.as_str())
            }
            Err(e) => {
                log::warn!("vault search failed ({path}): {e}");
                vault_error(&format!("vault search failed: {e}"))
            }
        }
    }

    /// Load one note for the editor (JSON).
    ///
    /// `rel_path` is a vault-relative note path (the spelling the index
    /// answers and the list shows). Returns
    /// `{"text", "truncated", "crlf", "mtime", "size"}`: the text at the
    /// display path's 1 MiB cut, whether that cut hit a larger file (the pane
    /// must not offer editing — a save would drop the tail), whether the file
    /// uses CRLF endings, and the stamp a later save checks (`mtime` is in
    /// microseconds since the epoch — exact in JSON's double, unlike the
    /// index's nanoseconds). On failure the answer is `{"error", "code"}` —
    /// `code` is the stable discriminator the pane switches on.
    #[func]
    fn vault_note_read(vault_path: GString, rel_path: GString) -> GString {
        let path = vault_path.to_string();
        if let Some(problem) = vault_path_problem(&path) {
            return vault_error(&problem);
        }
        match gpty_core::vault::read_vault_note(&path, &rel_path.to_string()) {
            Ok(note) => {
                let document = serde_json::json!({
                    "text": note.text,
                    "truncated": note.truncated,
                    "crlf": note.crlf,
                    "mtime": note.stamp.mtime,
                    "size": note.stamp.size,
                })
                .to_string();
                GString::from(document.as_str())
            }
            Err(e) => {
                if note_failure_is_diagnostic(&e) {
                    log::warn!("vault note read failed ({path}): {e}");
                }
                note_error(e)
            }
        }
    }

    /// Replace one note's content (JSON), and re-index the vault.
    ///
    /// Only an existing note is written — this edits, it never creates — and
    /// the write stays inside the vault: the path must satisfy the walk's
    /// vocabulary and the resolved file (symlinks followed) must live under
    /// the root. `expected_mtime`/`expected_size` are the stamp the caller
    /// loaded; a note that differs on disk is refused with
    /// `code: "changed_on_disk"` rather than overwritten, unless `force` is
    /// true (that is what the pane's overwrite confirmation passes). The
    /// replacement is atomic and keeps the note's own mode.
    ///
    /// Returns `{"mtime", "size", "indexed"}` with the file's fresh stamp —
    /// `indexed` is false when the note is saved but the search index could
    /// not be brought up to date. On failure: `{"error", "code"}`.
    #[func]
    fn vault_note_write(
        vault_path: GString,
        rel_path: GString,
        content: GString,
        expected_mtime: i64,
        expected_size: i64,
        force: bool,
    ) -> GString {
        let path = vault_path.to_string();
        if let Some(problem) = vault_path_problem(&path) {
            return vault_error(&problem);
        }
        let expected = if force || expected_mtime < 0 {
            None
        } else {
            Some(gpty_core::vault::NoteStamp {
                mtime: expected_mtime,
                size: expected_size,
            })
        };
        match gpty_core::vault::write_vault_note(
            &path,
            &rel_path.to_string(),
            &content.to_string(),
            expected,
        ) {
            Ok(stamp) => {
                // Write-through: the file is the index's source of truth, so
                // a caller never has to remember a second call to make the
                // edit searchable — and a failed re-index is not a failed
                // save, which is why it is a field and not an error.
                let indexed = reindex_vault(&path);
                let document = serde_json::json!({
                    "mtime": stamp.mtime,
                    "size": stamp.size,
                    "indexed": indexed,
                })
                .to_string();
                GString::from(document.as_str())
            }
            Err(e) => {
                if note_failure_is_diagnostic(&e) {
                    log::warn!("vault note write failed ({path}): {e}");
                }
                note_error(e)
            }
        }
    }

    /// The recovery copy of one note's unsaved buffer (JSON).
    ///
    /// The editor holds its buffer in memory only, so a crash takes it unless
    /// a copy was written; that copy is keyed by this vault and note path, and
    /// this is how the pane asks for it when the note is reopened. Answers
    /// `{"found": false}` when there is none — the normal state, and the answer
    /// for a copy that cannot be trusted (an unreadable file, a record naming
    /// another note) — and `{"found": true, "text", "mtime", "size"}` when
    /// there is: the buffer, and the stamp of the file revision it was typed
    /// against, so a save restored from it still checks the file the user saw.
    /// `error` is present only when the vault or the note path cannot be used
    /// at all.
    #[func]
    fn vault_scratch_read(vault_path: GString, rel_path: GString) -> GString {
        let path = vault_path.to_string();
        if let Some(problem) = vault_path_problem(&path) {
            return vault_error(&problem);
        }
        let Some(dir) = scratch_dir_path() else {
            return vault_error("no writable state directory for recovery copies");
        };
        match gpty_core::vault::read_scratch(&dir, &path, &rel_path.to_string()) {
            Ok(Some(copy)) => {
                let document = serde_json::json!({
                    "found": true,
                    "text": copy.text,
                    "mtime": copy.stamp.mtime,
                    "size": copy.stamp.size,
                })
                .to_string();
                GString::from(document.as_str())
            }
            Ok(None) => {
                let document = serde_json::json!({ "found": false }).to_string();
                GString::from(document.as_str())
            }
            Err(e) => scratch_error(e),
        }
    }

    /// Snapshot one note's unsaved buffer as its recovery copy (JSON).
    ///
    /// The debounced half of the editor's crash protection: the pane calls
    /// this while a dirty buffer is quiet, and the copy is cleared on the save
    /// or the discard that ends it. It goes to gpty's state directory and
    /// *never* to the vault — this is not a note write — it is atomic, and it
    /// is restricted to its owner. `expected_mtime`/`expected_size` are the
    /// stamp the buffer was loaded from; the copy records it so a restore
    /// after the file moved on still asks before overwriting.
    ///
    /// Answers `{"ok": true}` or `{"error", "code"}`.
    #[func]
    fn vault_scratch_write(
        vault_path: GString,
        rel_path: GString,
        text: GString,
        expected_mtime: i64,
        expected_size: i64,
    ) -> GString {
        let path = vault_path.to_string();
        if let Some(problem) = vault_path_problem(&path) {
            return vault_error(&problem);
        }
        let Some(dir) = scratch_dir_path() else {
            return vault_error("no writable state directory for recovery copies");
        };
        let stamp = gpty_core::vault::NoteStamp {
            mtime: expected_mtime,
            size: expected_size,
        };
        match gpty_core::vault::write_scratch(
            &dir,
            &path,
            &rel_path.to_string(),
            &text.to_string(),
            stamp,
        ) {
            Ok(()) => {
                let document = serde_json::json!({ "ok": true }).to_string();
                GString::from(document.as_str())
            }
            Err(e) => scratch_error(e),
        }
    }

    /// Drop one note's recovery copy (JSON): the buffer either reached the
    /// file or was deliberately discarded, and a copy outliving that would
    /// offer a restore of work the user already decided about. An absent copy
    /// is not an error. Answers `{"ok": true}` or `{"error", "code"}`.
    #[func]
    fn vault_scratch_clear(vault_path: GString, rel_path: GString) -> GString {
        let path = vault_path.to_string();
        if let Some(problem) = vault_path_problem(&path) {
            return vault_error(&problem);
        }
        let Some(dir) = scratch_dir_path() else {
            return vault_error("no writable state directory for recovery copies");
        };
        match gpty_core::vault::clear_scratch(&dir, &path, &rel_path.to_string()) {
            Ok(()) => {
                let document = serde_json::json!({ "ok": true }).to_string();
                GString::from(document.as_str())
            }
            Err(e) => scratch_error(e),
        }
    }
}
