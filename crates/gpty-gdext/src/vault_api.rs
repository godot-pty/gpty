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

fn vault_error(message: &str) -> GString {
    let document = serde_json::json!({ "error": message }).to_string();
    GString::from(document.as_str())
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
}
