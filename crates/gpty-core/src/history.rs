//! SQLite-backed scrollback history with full-text search.
//!
//! [`HistoryStore`] persists terminal output lines to disk and provides
//! indexed search via FTS5. The in-memory [`crate::term::TermGrid`] remains
//! the primary render source; SQLite is the persistence layer.
//!
//! Pane rows are keyed by the pane's stable `attachment_id` string (schema
//! v2). An optional cap bounds how many lines are retained per pane.

use rusqlite::{Connection, params};

/// Maximum terms carried from user input into an FTS5 query.
const MAX_QUERY_TERMS: usize = 32;

/// Reduce free text to a valid FTS5 query.
///
/// FTS5's `MATCH` takes a query language, not a search string, so raw user
/// input rejects ordinary searches: `main.rs` (syntax error near "."),
/// `error: x` (read as a column filter), `warning:`, `*`, `"unclosed`. Keeping
/// only word characters and quoting each term makes any input valid, and
/// space-separated quoted terms keep FTS5's implicit AND.
pub fn sanitize_fts_query(input: &str) -> String {
    input
        .chars()
        .map(|c| {
            if c.is_alphanumeric() || c == '_' {
                c
            } else {
                ' '
            }
        })
        .collect::<String>()
        .split_whitespace()
        .take(MAX_QUERY_TERMS)
        .map(|term| format!("\"{term}\""))
        .collect::<Vec<_>>()
        .join(" ")
}

/// Manages scrollback persistence for terminal panes.
pub struct HistoryStore {
    conn: Connection,
    pane_key: String,
    cap: u32,
}

impl HistoryStore {
    /// Open or create the history database at `path` for `pane_key`.
    ///
    /// Creates tables on first use; migrates pre-v2 databases by dropping
    /// their rows (legacy rows were keyed by per-node counters that collide
    /// across panes and orphan across restarts — unrecoverable). Uses WAL
    /// mode for concurrent access. `cap` bounds retained lines per pane.
    pub fn open(path: &str, pane_key: &str, cap: u32) -> Result<Self, rusqlite::Error> {
        let conn = Connection::open(path)?;
        let version: i64 = conn.pragma_query_value(None, "user_version", |row| row.get(0))?;
        conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")?;
        if version < 2 {
            conn.execute_batch(
                "DROP TABLE IF EXISTS lines_fts;
                 DROP TABLE IF EXISTS lines;",
            )?;
        }
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS lines (
                pane_id TEXT NOT NULL,
                line_num INTEGER NOT NULL,
                text TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_lines_pane ON lines(pane_id, line_num);
            CREATE VIRTUAL TABLE IF NOT EXISTS lines_fts USING fts5(text, content=lines, content_rowid=rowid);
            CREATE TRIGGER IF NOT EXISTS lines_ai AFTER INSERT ON lines BEGIN
                INSERT INTO lines_fts(rowid, text) VALUES (new.rowid, new.text);
            END;
            CREATE TRIGGER IF NOT EXISTS lines_ad AFTER DELETE ON lines BEGIN
                INSERT INTO lines_fts(lines_fts, rowid, text) VALUES('delete', old.rowid, old.text);
            END;
            CREATE TRIGGER IF NOT EXISTS lines_au AFTER UPDATE ON lines BEGIN
                INSERT INTO lines_fts(lines_fts, rowid, text) VALUES('delete', old.rowid, old.text);
                INSERT INTO lines_fts(rowid, text) VALUES (new.rowid, new.text);
            END;
            PRAGMA user_version=2;"
        )?;
        Ok(Self {
            conn,
            pane_key: pane_key.to_string(),
            cap,
        })
    }

    /// Append an output line to the history.
    pub fn append(&self, line_num: i64, text: &str) -> Result<i64, rusqlite::Error> {
        self.conn.execute(
            "INSERT INTO lines (pane_id, line_num, text) VALUES (?1, ?2, ?3)",
            params![self.pane_key, line_num, text],
        )?;
        Ok(self.conn.last_insert_rowid())
    }

    /// Search all history lines for `pattern` using FTS5.
    ///
    /// `pattern` is passed to FTS5 `MATCH` verbatim (raw query syntax:
    /// bare words, quoted phrases, `NEAR`, prefix `*`).
    pub fn search(
        &self,
        pattern: &str,
        limit: usize,
    ) -> Result<Vec<(i64, String)>, rusqlite::Error> {
        let mut stmt = self.conn.prepare(
            "SELECT l.line_num, l.text FROM lines l
             JOIN lines_fts f ON l.rowid = f.rowid
             WHERE l.pane_id = ?1 AND lines_fts MATCH ?2
             ORDER BY l.line_num DESC LIMIT ?3",
        )?;
        let rows = stmt.query_map(params![self.pane_key, pattern, limit as i64], |row| {
            Ok((row.get(0)?, row.get(1)?))
        })?;
        let mut results = Vec::new();
        for row in rows {
            results.push(row?);
        }
        Ok(results)
    }

    /// Search using free text as a user typed it.
    ///
    /// The search box takes a search *string*; FTS5's `MATCH` takes a query
    /// language. Left raw, ordinary input fails: `main.rs` is a syntax error
    /// (near "."), `error: x` is read as a column filter, `warning:` and `*`
    /// fail too — and a syntax error reported as an empty result set is
    /// indistinguishable from "no match". Sanitising first makes any input
    /// valid, keeping AND between terms.
    pub fn search_user_text(
        &self,
        text: &str,
        limit: usize,
    ) -> Result<Vec<(i64, String)>, rusqlite::Error> {
        let query = sanitize_fts_query(text);
        if query.is_empty() {
            // Nothing searchable was typed; an empty MATCH is itself invalid.
            return Ok(Vec::new());
        }
        self.search(&query, limit)
    }

    /// Retrieve a range of history lines by absolute line number.
    pub fn get_lines(&self, start: i64, end: i64) -> Result<Vec<(i64, String)>, rusqlite::Error> {
        let mut stmt = self.conn.prepare(
            "SELECT line_num, text FROM lines
             WHERE pane_id = ?1 AND line_num BETWEEN ?2 AND ?3
             ORDER BY line_num",
        )?;
        let rows = stmt.query_map(params![self.pane_key, start, end], |row| {
            Ok((row.get(0)?, row.get(1)?))
        })?;
        let mut results = Vec::new();
        for row in rows {
            results.push(row?);
        }
        Ok(results)
    }

    /// Total number of lines stored for this pane.
    pub fn line_count(&self) -> Result<i64, rusqlite::Error> {
        self.conn.query_row(
            "SELECT COUNT(*) FROM lines WHERE pane_id = ?1",
            params![self.pane_key],
            |row| row.get(0),
        )
    }

    /// Highest absolute line number stored for this pane (0 when empty).
    pub fn max_line_num(&self) -> Result<i64, rusqlite::Error> {
        self.conn.query_row(
            "SELECT COALESCE(MAX(line_num), 0) FROM lines WHERE pane_id = ?1",
            params![self.pane_key],
            |row| row.get(0),
        )
    }

    /// Delete the oldest lines beyond `cap`, keeping the newest `cap`.
    pub fn enforce_cap(&self) -> Result<(), rusqlite::Error> {
        if self.cap == 0 {
            return Ok(());
        }
        self.conn.execute(
            "DELETE FROM lines WHERE pane_id = ?1 AND line_num <=
                (SELECT MAX(line_num) FROM lines WHERE pane_id = ?1) - ?2",
            params![self.pane_key, self.cap as i64],
        )?;
        Ok(())
    }

    /// Delete all history for this pane.
    pub fn clear(&self) -> Result<(), rusqlite::Error> {
        self.conn.execute(
            "DELETE FROM lines WHERE pane_id = ?1",
            params![self.pane_key],
        )?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    /// Unique temp DB path per test; removed in drop-guard style by caller.
    fn temp_db_path(name: &str) -> String {
        format!(
            "{}/gpty_history_test_{}_{}.db",
            std::env::temp_dir().display(),
            name,
            std::process::id()
        )
    }

    #[test]
    fn append_and_search() {
        let store = HistoryStore::open(":memory:", "pane-a", 100).unwrap();
        store.append(0, "hello world").unwrap();
        store.append(1, "error: disk full").unwrap();
        store.append(2, "goodbye").unwrap();

        let results = store.search("error", 10).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].0, 1);
        assert!(results[0].1.contains("error"));
    }

    #[test]
    fn sanitize_fts_query_accepts_ordinary_search_text() {
        // Each of these is a syntax error or a column filter when handed to
        // FTS5 raw — which is how the search box reported "no results" for
        // perfectly ordinary input.
        assert_eq!(sanitize_fts_query("main.rs"), "\"main\" \"rs\"");
        assert_eq!(sanitize_fts_query("src/main.rs"), "\"src\" \"main\" \"rs\"");
        assert_eq!(
            sanitize_fts_query("error: something"),
            "\"error\" \"something\""
        );
        assert_eq!(sanitize_fts_query("warning:"), "\"warning\"");
        assert_eq!(sanitize_fts_query("-x"), "\"x\"");
        assert_eq!(sanitize_fts_query("\"unbalanced"), "\"unbalanced\"");
        // Operators lose their meaning instead of raising a syntax error.
        assert_eq!(sanitize_fts_query("a OR b*"), "\"a\" \"OR\" \"b\"");
        // Underscores survive, so identifiers stay searchable.
        assert_eq!(sanitize_fts_query("GPTY_SOCKET"), "\"GPTY_SOCKET\"");
    }

    #[test]
    fn sanitize_fts_query_yields_nothing_for_punctuation_only() {
        // Callers must treat this as "nothing to search", not as a query.
        assert_eq!(sanitize_fts_query("*"), "");
        assert_eq!(sanitize_fts_query("   "), "");
        assert_eq!(sanitize_fts_query("..."), "");
    }

    #[test]
    fn search_user_text_handles_punctuated_input() {
        let store = HistoryStore::open(":memory:", "pane-a", 100).unwrap();
        store.append(0, "compiling src/main.rs").unwrap();
        store.append(1, "error: cannot find value").unwrap();
        store.append(2, "unrelated line").unwrap();

        // Raw FTS5 rejects both of these outright.
        assert!(store.search("main.rs", 10).is_err());
        assert!(store.search("error: cannot", 10).is_err());

        let hits = store.search_user_text("main.rs", 10).unwrap();
        assert_eq!(hits.len(), 1, "expected the src/main.rs line: {hits:?}");
        assert_eq!(hits[0].1, "compiling src/main.rs");

        let hits = store.search_user_text("error: cannot", 10).unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].1, "error: cannot find value");

        // Punctuation-only input is an empty search, not an error.
        assert!(store.search_user_text("*", 10).unwrap().is_empty());
    }

    #[test]
    fn get_range() {
        let store = HistoryStore::open(":memory:", "pane-a", 100).unwrap();
        for i in 0..10 {
            store.append(i, &format!("line {i}")).unwrap();
        }
        let lines = store.get_lines(3, 6).unwrap();
        assert_eq!(lines.len(), 4);
        assert_eq!(lines[0].1, "line 3");
        assert_eq!(lines[3].1, "line 6");
    }

    #[test]
    fn pane_isolation() {
        // Two stores over the SAME file must not see each other's rows.
        let path = temp_db_path("isolation");
        let store1 = HistoryStore::open(&path, "pane-a", 100).unwrap();
        let store2 = HistoryStore::open(&path, "pane-b", 100).unwrap();
        store1.append(0, "pane1").unwrap();
        store2.append(0, "pane2").unwrap();
        assert_eq!(store1.line_count().unwrap(), 1);
        assert_eq!(store2.line_count().unwrap(), 1);
        assert_eq!(store1.max_line_num().unwrap(), 0);
        assert_eq!(store2.max_line_num().unwrap(), 0);
        fs::remove_file(&path).ok();
    }

    #[test]
    fn clear_history() {
        let store = HistoryStore::open(":memory:", "pane-a", 100).unwrap();
        store.append(0, "test").unwrap();
        assert_eq!(store.line_count().unwrap(), 1);
        store.clear().unwrap();
        assert_eq!(store.line_count().unwrap(), 0);
        assert_eq!(store.max_line_num().unwrap(), 0);
    }

    #[test]
    fn cap_enforced() {
        let store = HistoryStore::open(":memory:", "pane-a", 5).unwrap();
        for i in 0..8 {
            store.append(i, &format!("line {i}")).unwrap();
        }
        store.enforce_cap().unwrap();
        assert_eq!(store.line_count().unwrap(), 5);
        assert_eq!(store.max_line_num().unwrap(), 7);
        let lines = store.get_lines(0, 7).unwrap();
        assert_eq!(lines.first().unwrap().0, 3);
        assert_eq!(lines.last().unwrap().0, 7);
    }

    #[test]
    fn max_line_num_persists_across_reopen() {
        let path = temp_db_path("reopen");
        {
            let store = HistoryStore::open(&path, "pane-a", 100).unwrap();
            for i in 0..3 {
                store.append(i, &format!("line {i}")).unwrap();
            }
        }
        let store = HistoryStore::open(&path, "pane-a", 100).unwrap();
        assert_eq!(store.max_line_num().unwrap(), 2);
        assert_eq!(store.line_count().unwrap(), 3);
        fs::remove_file(&path).ok();
    }

    #[test]
    fn legacy_schema_v1_rows_dropped() {
        let path = temp_db_path("legacy");
        {
            // Hand-build a v1 database: integer pane ids, user_version unset.
            let conn = Connection::open(&path).unwrap();
            conn.execute_batch(
                "CREATE TABLE lines (
                    pane_id INTEGER NOT NULL,
                    line_num INTEGER NOT NULL,
                    text TEXT NOT NULL
                );
                INSERT INTO lines VALUES (0, 0, 'stale');",
            )
            .unwrap();
        }
        let store = HistoryStore::open(&path, "pane-a", 100).unwrap();
        assert_eq!(store.line_count().unwrap(), 0);
        let version: i64 = store
            .conn
            .pragma_query_value(None, "user_version", |row| row.get(0))
            .unwrap();
        assert_eq!(version, 2);
        fs::remove_file(&path).ok();
    }
}
