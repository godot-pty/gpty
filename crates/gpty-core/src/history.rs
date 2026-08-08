//! SQLite-backed scrollback history with full-text search.
//!
//! [`HistoryStore`] persists terminal output lines to disk and provides
//! indexed search via FTS5. The in-memory [`crate::term::TermGrid`] remains
//! the primary render source; SQLite is the persistence layer.

use rusqlite::{Connection, params};

/// Manages scrollback persistence for terminal panes.
pub struct HistoryStore {
    conn: Connection,
    pane_id: u32,
}

impl HistoryStore {
    /// Open or create the history database at `path` for `pane_id`.
    ///
    /// Creates tables on first use. Uses WAL mode for concurrent access.
    pub fn open(path: &str, pane_id: u32) -> Result<Self, rusqlite::Error> {
        let conn = Connection::open(path)?;
        conn.execute_batch(
            "PRAGMA journal_mode=WAL;
             PRAGMA synchronous=NORMAL;
             CREATE TABLE IF NOT EXISTS lines (
                pane_id INTEGER NOT NULL,
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
            END;"
        )?;
        Ok(Self { conn, pane_id })
    }

    /// Append an output line to the history.
    pub fn append(&self, line_num: i64, text: &str) -> Result<i64, rusqlite::Error> {
        self.conn.execute(
            "INSERT INTO lines (pane_id, line_num, text) VALUES (?1, ?2, ?3)",
            params![self.pane_id, line_num, text],
        )?;
        Ok(self.conn.last_insert_rowid())
    }

    /// Search all history lines for `pattern` using FTS5.
    pub fn search(&self, pattern: &str, limit: usize) -> Result<Vec<(i64, String)>, rusqlite::Error> {
        let mut stmt = self.conn.prepare(
            "SELECT l.line_num, l.text FROM lines l
             JOIN lines_fts f ON l.rowid = f.rowid
             WHERE l.pane_id = ?1 AND lines_fts MATCH ?2
             ORDER BY l.line_num DESC LIMIT ?3"
        )?;
        let rows = stmt.query_map(
            params![self.pane_id, pattern, limit as i64],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )?;
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
             ORDER BY line_num"
        )?;
        let rows = stmt.query_map(
            params![self.pane_id, start, end],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )?;
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
            params![self.pane_id],
            |row| row.get(0),
        )
    }

    /// Delete all history for this pane.
    pub fn clear(&self) -> Result<(), rusqlite::Error> {
        self.conn.execute(
            "DELETE FROM lines WHERE pane_id = ?1",
            params![self.pane_id],
        )?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn append_and_search() {
        let store = HistoryStore::open(":memory:", 1).unwrap();
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
        let store = HistoryStore::open(":memory:", 1).unwrap();
        for i in 0..10 {
            store.append(i, &format!("line {}", i)).unwrap();
        }
        let lines = store.get_lines(3, 6).unwrap();
        assert_eq!(lines.len(), 4);
        assert_eq!(lines[0].1, "line 3");
        assert_eq!(lines[3].1, "line 6");
    }

    #[test]
    fn pane_isolation() {
        let store1 = HistoryStore::open(":memory:", 1).unwrap();
        let store2 = HistoryStore::open(":memory:", 2).unwrap();
        store1.append(0, "pane1").unwrap();
        store2.append(0, "pane2").unwrap();
        assert_eq!(store1.line_count().unwrap(), 1);
        assert_eq!(store2.line_count().unwrap(), 1);
    }

    #[test]
    fn clear_history() {
        let store = HistoryStore::open(":memory:", 1).unwrap();
        store.append(0, "test").unwrap();
        assert_eq!(store.line_count().unwrap(), 1);
        store.clear().unwrap();
        assert_eq!(store.line_count().unwrap(), 0);
    }
}
