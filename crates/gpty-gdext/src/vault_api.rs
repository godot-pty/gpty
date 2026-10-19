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
/// data this feature only reads. The path is `gpty_ipc::transport::state_dir()`
/// (Rust) rather than a Godot `user://` path because the index is also
/// reachable from the control socket's native vault handlers
/// (`vault_ipc.rs`), which run outside Godot's path resolution.
pub(crate) fn vault_db_path() -> Option<String> {
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
pub(crate) fn note_failure_is_diagnostic(error: &gpty_core::vault::NoteError) -> bool {
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
pub(crate) fn vault_path_problem(path: &str) -> Option<String> {
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

    /// Every link of one note: what it points at, what points back at it, and
    /// what stays unresolved (JSON).
    ///
    /// Links are parsed and resolved by the index pass — one row per `[[…]]`
    /// occurrence, with the line it was written on — so this reads the derived
    /// store rather than scanning the vault. `outgoing` is what the note links
    /// to (`{target, resolved, line, seq, fragment}`, `resolved` null while it
    /// does not resolve and `fragment` null without a `#heading`); `backlinks`
    /// is the same edges read in reverse
    /// (`{src, line, target}`, one entry per mention); `unresolved` names each
    /// target nothing matched, with `candidates` listing the notes an
    /// ambiguous stem could not be chosen between. `error` is present only
    /// when the vault or the store cannot be used.
    #[func]
    fn vault_links(vault_path: GString, rel_path: GString) -> GString {
        let path = vault_path.to_string();
        if let Some(problem) = vault_path_problem(&path) {
            return vault_error(&problem);
        }
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
        match store.links_for(&path, &rel_path.to_string()) {
            Ok(links) => {
                let outgoing: Vec<serde_json::Value> = links
                    .outgoing
                    .iter()
                    .map(|link| {
                        serde_json::json!({
                            "target": &link.target,
                            "resolved": &link.resolved,
                            "line": link.line,
                            "seq": link.seq,
                            "fragment": &link.fragment,
                        })
                    })
                    .collect();
                let backlinks: Vec<serde_json::Value> = links
                    .backlinks
                    .iter()
                    .map(|link| {
                        serde_json::json!({
                            "src": &link.src,
                            "line": link.line,
                            "target": &link.target,
                        })
                    })
                    .collect();
                let unresolved: Vec<serde_json::Value> = links
                    .unresolved
                    .iter()
                    .map(|link| {
                        serde_json::json!({
                            "target": &link.target,
                            "line": link.line,
                            "candidates": &link.candidates,
                        })
                    })
                    .collect();
                let document = serde_json::json!({
                    "outgoing": outgoing,
                    "backlinks": backlinks,
                    "unresolved": unresolved,
                })
                .to_string();
                GString::from(document.as_str())
            }
            Err(e) => {
                log::warn!("vault links failed ({path}): {e}");
                vault_error(&format!("vault links failed: {e}"))
            }
        }
    }

    /// The vault's link graph: nodes and aggregated edges for a canvas (JSON).
    ///
    /// Read-only over the index the pass already built, so drawing a graph
    /// never walks the vault or re-parses a note; the aggregation (one edge
    /// per `(src, dst)` pair, weighted by `[[…]]` occurrences) happens in the
    /// store, which is also where the deterministic order is settled. Returns
    /// `{"nodes": [{"id", "label", "ghost"}, ...], "edges": [{"src", "dst",
    /// "count", "ghost"}, ...], "truncated": bool}`. A node id is a note's
    /// vault-relative path, or `ghost:<target>` for a target nothing resolved
    /// to; a ghost edge's `dst` is that node id. `error` is present only when
    /// the vault or the store cannot be used.
    #[func]
    fn vault_graph(vault_path: GString) -> GString {
        let path = vault_path.to_string();
        if let Some(problem) = vault_path_problem(&path) {
            return vault_error(&problem);
        }
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
        match store.graph(&path) {
            Ok(graph) => {
                let nodes: Vec<serde_json::Value> = graph
                    .nodes
                    .iter()
                    .map(|node| {
                        serde_json::json!({
                            "id": &node.id,
                            "label": &node.label,
                            "ghost": node.ghost,
                        })
                    })
                    .collect();
                let edges: Vec<serde_json::Value> = graph
                    .edges
                    .iter()
                    .map(|edge| {
                        serde_json::json!({
                            "src": &edge.src,
                            "dst": &edge.dst,
                            "count": edge.count,
                            "ghost": edge.ghost,
                        })
                    })
                    .collect();
                let document = serde_json::json!({
                    "nodes": nodes,
                    "edges": edges,
                    "truncated": graph.truncated,
                })
                .to_string();
                GString::from(document.as_str())
            }
            Err(e) => {
                log::warn!("vault graph failed ({path}): {e}");
                vault_error(&format!("vault graph failed: {e}"))
            }
        }
    }

    /// Resolve one `[[target]]` against a vault's note set (JSON).
    ///
    /// The answer comes from the same rule the index pass applies
    /// (`links::NoteIndex`), so a mention followed from the preview lands on
    /// the note the store recorded — or on the note it *would* record for a
    /// mention that is not saved yet. `{"resolved": "note.md", "candidates":
    /// []}` when exactly one note matched; `resolved` null with the sorted
    /// `candidates` when a stem is ambiguous (never silently picked); and
    /// `resolved` null with no candidates when nothing matched or the target
    /// is empty/oversized. `error` is present only when the vault or the
    /// store cannot be used — "not found" is an answer, not a failure.
    #[func]
    fn vault_link_resolve(vault_path: GString, target: GString) -> GString {
        let path = vault_path.to_string();
        if let Some(problem) = vault_path_problem(&path) {
            return vault_error(&problem);
        }
        let target = target.to_string();
        // An empty or oversized target cannot have been stored as a link
        // (`links::parse_links` refuses both), so it is a missing answer
        // rather than a store query.
        if target.is_empty() || target.len() > gpty_core::links::MAX_LINK_TARGET_BYTES {
            return GString::from(r#"{"resolved":null,"candidates":[]}"#);
        }
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
        match store.resolve_target(&path, &target) {
            Ok(resolution) => {
                let document = match resolution {
                    gpty_core::links::Resolution::Resolved(note) => {
                        serde_json::json!({ "resolved": note, "candidates": [] })
                    }
                    gpty_core::links::Resolution::Ambiguous(candidates) => {
                        serde_json::json!({ "resolved": null, "candidates": candidates })
                    }
                    gpty_core::links::Resolution::Missing => {
                        serde_json::json!({ "resolved": null, "candidates": [] })
                    }
                }
                .to_string();
                GString::from(document.as_str())
            }
            Err(e) => {
                log::warn!("vault link resolve failed ({path}): {e}");
                vault_error(&format!("vault link resolve failed: {e}"))
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

    /// Create one note (JSON), and re-index the vault.
    ///
    /// `rel_path` follows the same vocabulary a save does (vault-relative,
    /// `.md`, no hidden component), and its directory must already exist
    /// inside the vault — creation never makes directories, and never writes
    /// through a directory symlinked out of the vault. The file is claimed
    /// with `create_new`, so an existing note, symlink or directory at the
    /// path answers `code: "exists"`; there is no overwrite path. Returns
    /// `{"mtime", "size", "indexed"}` (the fresh stamp and whether the index
    /// caught up), or `{"error", "code"}`.
    #[func]
    fn vault_note_create(vault_path: GString, rel_path: GString, content: GString) -> GString {
        let path = vault_path.to_string();
        if let Some(problem) = vault_path_problem(&path) {
            return vault_error(&problem);
        }
        match gpty_core::vault::create_vault_note(
            &path,
            &rel_path.to_string(),
            &content.to_string(),
        ) {
            Ok(stamp) => {
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
                    log::warn!("vault note create failed ({path}): {e}");
                }
                note_error(e)
            }
        }
    }

    /// Delete one note (JSON), and re-index the vault.
    ///
    /// Only an existing note is deleted; the operation acts on the vault
    /// **entry**, so a symlinked note is unlinked and the file it points at
    /// stays where it is. Returns `{"indexed"}` (`false` only when the index
    /// could not be brought up to date), or `{"error", "code"}`.
    #[func]
    fn vault_note_delete(vault_path: GString, rel_path: GString) -> GString {
        let path = vault_path.to_string();
        if let Some(problem) = vault_path_problem(&path) {
            return vault_error(&problem);
        }
        match gpty_core::vault::delete_vault_note(&path, &rel_path.to_string()) {
            Ok(()) => {
                let indexed = reindex_vault(&path);
                let document = serde_json::json!({ "indexed": indexed }).to_string();
                GString::from(document.as_str())
            }
            Err(e) => {
                if note_failure_is_diagnostic(&e) {
                    log::warn!("vault note delete failed ({path}): {e}");
                }
                note_error(e)
            }
        }
    }

    /// Rename one note (JSON), and re-index the vault.
    ///
    /// Both paths follow the save vocabulary, and the destination's directory
    /// must exist inside the vault. The destination is claimed before the
    /// rename, so an existing note answers `code: "exists"` instead of being
    /// replaced. The vault **entry** moves (a symlinked note moves as a link).
    /// Returns `{"path", "indexed"}` — the new relative path, which is also
    /// the stamp the caller keeps using, since a rename preserves the file's
    /// mtime and size — or `{"error", "code"}`.
    #[func]
    fn vault_note_rename(vault_path: GString, rel_path: GString, new_rel_path: GString) -> GString {
        let path = vault_path.to_string();
        if let Some(problem) = vault_path_problem(&path) {
            return vault_error(&problem);
        }
        let new_rel = new_rel_path.to_string();
        match gpty_core::vault::rename_vault_note(&path, &rel_path.to_string(), &new_rel) {
            Ok(()) => {
                let indexed = reindex_vault(&path);
                let document = serde_json::json!({
                    "path": new_rel,
                    "indexed": indexed,
                })
                .to_string();
                GString::from(document.as_str())
            }
            Err(e) => {
                if note_failure_is_diagnostic(&e) {
                    log::warn!("vault note rename failed ({path}): {e}");
                }
                note_error(e)
            }
        }
    }

    /// What a rename's reference update would touch (JSON), writing nothing.
    ///
    /// `rel_path` is the name the note had before the move and `new_rel_path`
    /// the name it has now: the pass reads the vault *after* the rename and
    /// reconstructs the old note set from the walk, so the only occurrences
    /// considered are those that resolved to the old name. `include_renamed`
    /// adds the renamed note itself to the candidate set, for a caller whose
    /// buffer is clean; a dirty buffer passes false and its note is left
    /// alone. Answers `{"files", "mentions", "skipped", "truncated"}` — how
    /// many notes and occurrences still name the old target, how many notes
    /// could not be examined (unreadable or over the read cap), and whether
    /// the walk's note cap cut the vault. The pane shows these numbers in its
    /// update question; nothing is written until `vault_link_rewrite` runs.
    #[func]
    fn vault_link_rewrite_preview(
        vault_path: GString,
        rel_path: GString,
        new_rel_path: GString,
        include_renamed: bool,
    ) -> GString {
        let path = vault_path.to_string();
        if let Some(problem) = vault_path_problem(&path) {
            return vault_error(&problem);
        }
        match gpty_core::vault::preview_link_rewrite(
            &path,
            &rel_path.to_string(),
            &new_rel_path.to_string(),
            include_renamed,
        ) {
            Ok(report) => {
                let document = serde_json::json!({
                    "files": report.files,
                    "mentions": report.mentions,
                    "skipped": report.skipped,
                    "truncated": report.truncated,
                })
                .to_string();
                GString::from(document.as_str())
            }
            Err(e) => {
                if note_failure_is_diagnostic(&e) {
                    log::warn!("vault reference preview failed ({path}): {e}");
                }
                note_error(e)
            }
        }
    }

    /// Rewrite the mentions that still name a renamed note (JSON), then
    /// re-index the vault.
    ///
    /// Applies the pass the preview planned: only occurrences that resolved to
    /// the old name before the move are respelled, an alias and a `#` fragment
    /// are preserved, fenced code and code spans are not links to begin with,
    /// and `include_renamed` decides whether the renamed note itself is a
    /// candidate — pass true for a clean buffer and false for a dirty one,
    /// because the pass writes the file under an editor's buffer and must
    /// never do that to unsaved work. Answers
    /// `{"files", "mentions", "skipped", "truncated", "indexed"}`, plus
    /// `"renamed_note": {"text", "crlf", "mtime", "size"}` when the renamed
    /// note itself was rewritten — the text that landed and its fresh stamp,
    /// so the editor showing it can adopt both instead of reading again (a
    /// save right after therefore does not see a stale stamp). `"renamed_note"`
    /// is absent when nothing was written to that note.
    #[func]
    fn vault_link_rewrite(
        vault_path: GString,
        rel_path: GString,
        new_rel_path: GString,
        include_renamed: bool,
    ) -> GString {
        let path = vault_path.to_string();
        if let Some(problem) = vault_path_problem(&path) {
            return vault_error(&problem);
        }
        let new_rel = new_rel_path.to_string();
        match gpty_core::vault::rewrite_links_after_rename(
            &path,
            &rel_path.to_string(),
            &new_rel,
            include_renamed,
        ) {
            Ok(done) => {
                let indexed = reindex_vault(&path);
                let mut document = serde_json::json!({
                    "files": done.files,
                    "mentions": done.mentions,
                    "skipped": done.skipped,
                    "truncated": done.truncated,
                    "indexed": indexed,
                });
                if let Some(note) = &done.renamed_note {
                    document["renamed_note"] = serde_json::json!({
                        "text": note.text,
                        "crlf": note.crlf,
                        "mtime": note.stamp.mtime,
                        "size": note.stamp.size,
                    });
                }
                let document = document.to_string();
                GString::from(document.as_str())
            }
            Err(e) => {
                if note_failure_is_diagnostic(&e) {
                    log::warn!("vault reference rewrite failed ({path}): {e}");
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
