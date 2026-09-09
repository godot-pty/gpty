//! SQLite-backed scrollback history with full-text search.
//!
//! [`HistoryStore`] persists terminal output lines to disk and provides
//! indexed search via FTS5. The in-memory [`crate::term::TermGrid`] remains
//! the primary render source; SQLite is the persistence layer.
//!
//! Pane rows are keyed by the pane's stable `attachment_id` string (schema
//! v2). An optional cap bounds how many lines are retained per pane.

use rusqlite::{Connection, params};

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
