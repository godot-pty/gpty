//! Persisted-scrollback facet of `GptyTerminal`: the SQLite store behind the history reads.
//!
//! Flushing the per-pane writer, pruning orphaned panes, the FTS search, and the on-disk
//! size the settings panel reports. Nothing here runs on the terminal path: the grid queues
//! lines and a per-pane writer commits them (see `gpty_core::history`).

use crate::GptyTerminal;
use godot::prelude::*;

#[godot_api(secondary)]
impl GptyTerminal {
    /// Commit this pane's buffered scrollback and wait for it (bounded).
    ///
    /// Output lines are queued and written by a background thread, so a
    /// process that exits without teardown (SIGKILL, `daemon stop`'s
    /// `process::exit`) loses whatever is still queued. The pane calls this
    /// from its GDScript `_exit_tree()`, which Godot does run on a normal
    /// quit, so the output printed just before closing is in the database
    /// when the next launch restores the pane.
    #[func]
    fn flush_history(&self) {
        let Some(spawned) = &self.spawned else {
            return;
        };
        let history = if let Some(grid) = gpty_core::lock::lock_or_warn(&spawned.grid, "pane grid")
        {
            grid.history.clone()
        } else {
            None
        };
        if let Some(history) = history
            && !history.flush()
        {
            godot_warn!("[GDExt] Scrollback did not finish committing before exit");
        }
    }

    /// Search this pane's persisted scrollback (SQLite + FTS5).
    ///
    /// `pattern` is free text as a user typed it, not an FTS5 query: it is
    /// sanitised first, because raw `MATCH` rejects ordinary searches such as
    /// `main.rs` (syntax error near ".") or `error: x` (read as a column
    /// filter). Terms are ANDed. Returns JSON
    /// `{"results": [[line_num, text], ...], "stored_lines": N}` newest-first;
    /// `error` is present only when the query could not run at all, so a
    /// caller can distinguish "no match" from "this pane has no history" (the
    /// common case when a pane is not restored under its saved id).
    /// `limit` is clamped to 1..=500.
    #[func]
    fn search_history(&self, pattern: GString, limit: i64) -> GString {
        let Some(spawned) = &self.spawned else {
            return GString::from(
                "{\"results\":[],\"stored_lines\":0,\"error\":\"pane is not running\"}",
            );
        };
        let history = if let Some(grid) = gpty_core::lock::lock_or_warn(&spawned.grid, "pane grid")
        {
            grid.history.clone()
        } else {
            None
        };
        let Some(history) = history else {
            return GString::from(
                "{\"results\":[],\"stored_lines\":0,\"error\":\"no history store for this pane\"}",
            );
        };
        let limit = limit.clamp(1, 500) as usize;
        let text = pattern.to_string();
        // A search can miss output printed in the last flush interval: the
        // store is written off the terminal path on purpose (see
        // `gpty_core::history::PaneHistory`).
        let (results, stored, error) = match history.store().lock() {
            Ok(h) => {
                let stored = h.line_count().unwrap_or(0);
                match h.search_user_text(&text, limit) {
                    Ok(rows) => (rows, stored, None),
                    Err(e) => (Vec::new(), stored, Some(e.to_string())),
                }
            }
            Err(e) => (
                Vec::new(),
                0,
                Some(format!("history store lock poisoned: {e}")),
            ),
        };
        let rows: Vec<Vec<serde_json::Value>> = results
            .into_iter()
            .map(|(n, t)| vec![serde_json::json!(n), serde_json::json!(t)])
            .collect();
        let mut json = serde_json::json!({ "results": rows, "stored_lines": stored });
        if let Some(error) = error {
            json["error"] = serde_json::json!(error);
        }
        GString::from(json.to_string().as_str())
    }

    /// Reclaim scrollback rows belonging to panes that no longer exist.
    ///
    /// `known_ids_json` is a JSON array of the `attachment_id`s that are live;
    /// non-string entries are ignored and only the first 512 are considered.
    /// This store's connection sees the WHOLE database, so the prune is
    /// global — one call from any live pane reclaims orphaned rows for every
    /// workspace. An empty (or empty-string) id list deletes nothing, because
    /// it means the caller had no data rather than that every pane is gone.
    /// Returns the number of deleted rows, or -1 when the pane is not running,
    /// has no history store, the JSON is malformed, or the delete fails.
    #[func]
    fn prune_history(&self, known_ids_json: GString) -> i64 {
        let Some(spawned) = &self.spawned else {
            return -1;
        };
        let history = if let Some(grid) = gpty_core::lock::lock_or_warn(&spawned.grid, "pane grid")
        {
            grid.history.clone()
        } else {
            None
        };
        let Some(history) = history else {
            return -1;
        };
        let Ok(values) =
            serde_json::from_str::<Vec<serde_json::Value>>(&known_ids_json.to_string())
        else {
            return -1;
        };
        // Same cap as other untrusted-input paths; only strings are ids.
        let known: Vec<String> = values
            .into_iter()
            .take(512)
            .filter_map(|v| v.as_str().map(str::to_string))
            .collect();
        match history.store().lock() {
            Ok(h) => match h.prune_missing_panes(&known) {
                Ok(deleted) => deleted as i64,
                Err(e) => {
                    godot_warn!("[GDExt] Could not prune orphaned history rows: {e}");
                    -1
                }
            },
            Err(e) => {
                godot_warn!("[GDExt] History store lock poisoned during prune: {e}");
                -1
            }
        }
    }

    /// Bytes the scrollback store occupies on disk, and where it lives.
    ///
    /// Static, like `get_app_version`: the GUI asks before any pane exists, and
    /// the answer is about the store file, not a terminal. JSON so the settings
    /// panel can show the size (the path is there for a future "reveal").
    #[func]
    fn history_store_stats() -> GString {
        let path = crate::history_db_path();
        let bytes = gpty_core::history::store_size_on_disk(&path);
        GString::from(&serde_json::json!({ "path": path, "bytes": bytes }).to_string())
    }
}
