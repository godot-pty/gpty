//! SQLite-backed scrollback history with full-text search.
//!
//! [`HistoryStore`] persists terminal output lines to disk and provides
//! indexed search via FTS5. The in-memory [`crate::term::TermGrid`] remains
//! the primary render source; SQLite is the persistence layer.
//!
//! Pane rows are keyed by the pane's stable `attachment_id` string (schema
//! v2). Two caps bound what a pane retains: rows (the `history_lines`
//! setting) and bytes (derived, see [`RETAINED_BYTES_PER_ROW`]).
//!
//! Writers never touch the store directly. [`PaneHistory::push`] queues a
//! line and a per-pane writer thread commits batches on an interval, so a
//! pane printing faster than SQLite can index (an insert costs ~30 µs, mostly
//! the FTS5 trigger) neither stalls the terminal task nor holds the grid
//! mutex the UI renders under.

use std::collections::VecDeque;
use std::sync::{Arc, Condvar, Mutex};

use rusqlite::{Connection, params, params_from_iter};

use crate::lock::lock_or_warn;

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
    byte_cap: u64,
}

/// Bytes of text a pane's store may retain per retained row.
///
/// The row cap bounds how *many* lines a pane keeps; this bounds how much
/// text they may hold. A single line can be 16 KiB (`parser::MAX_LINE_LEN`),
/// so 10 000 rows of pathological output — a program printing one giant line
/// after another — would be 160 MB on disk and in the FTS index without it.
/// Derived rather than separately configured: at 1 KiB per row the byte cap
/// only binds when lines are far longer than terminal output usually is.
const RETAINED_BYTES_PER_ROW: u64 = 1024;

/// Row budget used to derive the byte cap for a store with no row cap
/// (`cap == 0`, tests). Keeps the byte bound meaningful when the row bound is
/// deliberately disabled.
const UNCAPPED_ROW_BUDGET: u64 = 1024;

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
            byte_cap: u64::from(cap.max(UNCAPPED_ROW_BUDGET as u32)) * RETAINED_BYTES_PER_ROW,
        })
    }

    /// Open a store with an explicit byte cap (tests: a bound small enough to
    /// exercise trimming without writing megabytes).
    pub fn with_byte_cap(mut self, bytes: u64) -> Self {
        self.byte_cap = bytes;
        self
    }

    /// What this store retains: `(rows, bytes)`. `rows` is `usize::MAX` when
    /// the row cap is disabled.
    ///
    /// The writer thread bounds its pending queue with the same window, so a
    /// line it drops under flood is one [`Self::enforce_cap`] would delete on
    /// the next flush — never a line that would have been retained.
    pub fn retention_window(&self) -> (usize, usize) {
        let rows = if self.cap == 0 {
            usize::MAX
        } else {
            self.cap as usize
        };
        (rows, self.byte_cap as usize)
    }

    /// Append a single output line. Pane writes go through
    /// [`Self::append_batch`] (via `PaneHistory`); this is the one-row form
    /// the tests build their fixtures with.
    pub fn append(&self, line_num: i64, text: &str) -> Result<i64, rusqlite::Error> {
        self.conn.execute(
            "INSERT INTO lines (pane_id, line_num, text) VALUES (?1, ?2, ?3)",
            params![self.pane_key, line_num, text],
        )?;
        Ok(self.conn.last_insert_rowid())
    }

    /// Append a batch of output lines in one transaction.
    ///
    /// The per-statement cost is what the write path used to pay per line: a
    /// commit per row measured 33 k rows/s, one transaction per batch 111 k
    /// (release build; two calls with one variable prepared statement).
    /// Batching past ~512 rows does not pay — the FTS5 index write, not the
    /// commit, is what remains.
    pub fn append_batch(&mut self, lines: &[(i64, String)]) -> Result<(), rusqlite::Error> {
        if lines.is_empty() {
            return Ok(());
        }
        let tx = self.conn.transaction()?;
        {
            let mut stmt = tx.prepare_cached(
                "INSERT INTO lines (pane_id, line_num, text) VALUES (?1, ?2, ?3)",
            )?;
            for (line_num, text) in lines {
                stmt.execute(params![self.pane_key, line_num, text])?;
            }
        }
        tx.commit()
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
    ///
    /// Two caps apply: rows (`cap`) and retained text bytes
    /// ([`RETAINED_BYTES_PER_ROW`]-derived). The byte trim matters when lines
    /// are long — the row cap alone would let a pane hold hundreds of
    /// megabytes of 16 KiB lines.
    pub fn enforce_cap(&self) -> Result<(), rusqlite::Error> {
        if self.cap != 0 {
            self.conn.execute(
                "DELETE FROM lines WHERE pane_id = ?1 AND line_num <=
                    (SELECT MAX(line_num) FROM lines WHERE pane_id = ?1) - ?2",
                params![self.pane_key, self.cap as i64],
            )?;
        }
        if self.byte_cap != 0 {
            let total: i64 = self.conn.query_row(
                "SELECT COALESCE(SUM(LENGTH(text)), 0) FROM lines WHERE pane_id = ?1",
                params![self.pane_key],
                |row| row.get(0),
            )?;
            if total > self.byte_cap as i64 {
                // Delete oldest-first until the newest rows fit the budget:
                // the cutoff is the oldest line whose running total (summed
                // from the newest backwards) is already over it.
                self.conn.execute(
                    "DELETE FROM lines WHERE pane_id = ?1 AND line_num <= (
                        SELECT MIN(line_num) FROM (
                            SELECT line_num, SUM(LENGTH(text)) OVER (ORDER BY line_num DESC) AS running
                            FROM lines WHERE pane_id = ?1
                        ) WHERE running > ?2
                    )",
                    params![self.pane_key, self.byte_cap as i64],
                )?;
            }
        }
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

    /// Delete every stored line whose pane id is not in `known`.
    ///
    /// The connection sees the WHOLE database, not just this pane, so this
    /// reclaims scrollback for panes that no longer exist: rows keyed by an
    /// `attachment_id` nothing will ever open again are unreachable by
    /// [`Self::clear`] (which knows only its own key) and their own store's
    /// [`Self::enforce_cap`] never runs again, so they would leak forever.
    ///
    /// `known` is the set of live pane ids. An empty `known` returns `Ok(0)`
    /// without touching anything: an empty list means the caller had no data,
    /// and treating that as "prune everything" would destroy every pane's
    /// scrollback.
    ///
    /// The FTS5 index is kept in sync by the `lines_ad` trigger declared in
    /// [`Self::open`] (it issues FTS5's external-content `'delete'` command
    /// for the removed rowid), so a plain DELETE is enough.
    pub fn prune_missing_panes(&self, known: &[String]) -> Result<usize, rusqlite::Error> {
        if known.is_empty() {
            return Ok(0);
        }
        // Placeholders are built by repetition; values are bound, never
        // concatenated into the SQL. `known` is non-empty (guarded above).
        let placeholders = format!("?{}", ",?".repeat(known.len() - 1));
        let sql = format!("DELETE FROM lines WHERE pane_id NOT IN ({placeholders})");
        self.conn.execute(&sql, params_from_iter(known.iter()))
    }
}

// ── Write path ────────────────────────────────────────────────────────

/// How long a commit waits for the batch to keep growing.
///
/// A batch is committed once it reaches [`FLUSH_ROWS`] or once this long
/// passes with nothing new arriving, so a slow producer costs one transaction
/// per interval instead of one per line. It is also the upper bound on how
/// stale the store is for a reader: a search run right after output can miss
/// the last 200 ms of it, which is the price of keeping SQLite off the
/// terminal's path.
const FLUSH_INTERVAL: std::time::Duration = std::time::Duration::from_millis(200);

/// Rows a batch grows to before it is committed (whatever the interval).
///
/// Measured (release): 512 rows per transaction reaches the store's ceiling
/// (~111 k rows/s); larger transactions do not go faster.
const FLUSH_ROWS: usize = 512;

/// How long [`PaneHistory::flush`] waits for the writer to commit.
const FLUSH_ACK_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(2);

/// Buffered output lines between the terminal task and the store's writer.
///
/// Bounded by the store's *retention window*: a line pushed out of the queue
/// is older than the newest `rows`/`bytes` the store keeps anyway — exactly
/// what [`HistoryStore::enforce_cap`] deletes on the next flush — so dropping
/// it cannot open a gap inside the retained scrollback. Without that bound a
/// pane flooding output at millions of lines per second would push the
/// backlog somewhere else instead of fixing it (the store absorbs ~111 k
/// rows/s).
struct LineQueue {
    inner: Mutex<QueueInner>,
    window_rows: usize,
    window_bytes: usize,
    wake: Condvar,
}

struct QueueInner {
    lines: VecDeque<(i64, String)>,
    bytes: usize,
    /// Pushed but not yet committed. Decremented for dropped lines too, so a
    /// [`PaneHistory::flush`] wait cannot hang on a line nobody will write.
    pending: usize,
    closed: bool,
}

impl LineQueue {
    fn new(window_rows: usize, window_bytes: usize) -> Self {
        Self {
            inner: Mutex::new(QueueInner {
                lines: VecDeque::new(),
                bytes: 0,
                pending: 0,
                closed: false,
            }),
            window_rows,
            window_bytes,
            wake: Condvar::new(),
        }
    }

    /// Never blocks and never hands SQLite work to the caller; dropping only
    /// happens past the retention window.
    fn push(&self, line_num: i64, text: &str) {
        let Some(mut inner) = lock_or_warn(&self.inner, "history queue") else {
            return;
        };
        if inner.closed {
            return;
        }
        inner.bytes += text.len();
        inner.pending += 1;
        // Only a queue that was empty can need waking the writer (it sleeps
        // while there is nothing to take); a flood pushes millions of lines a
        // second and every notify would be one system call too many.
        let was_empty = inner.lines.is_empty();
        inner.lines.push_back((line_num, text.to_string()));
        while inner.lines.len() > self.window_rows || inner.bytes > self.window_bytes {
            let Some((_, dropped)) = inner.lines.pop_front() else {
                break;
            };
            inner.bytes -= dropped.len();
            inner.pending -= 1;
        }
        drop(inner);
        if was_empty {
            self.wake.notify_one();
        }
    }

    /// Take everything queued, oldest first.
    fn take(&self) -> Vec<(i64, String)> {
        let Some(mut inner) = lock_or_warn(&self.inner, "history queue") else {
            return Vec::new();
        };
        inner.bytes = 0;
        inner.lines.drain(..).collect()
    }

    fn flushed(&self, rows: usize) {
        if let Some(mut inner) = lock_or_warn(&self.inner, "history queue") {
            inner.pending = inner.pending.saturating_sub(rows);
        }
        self.wake.notify_all();
    }

    fn close(&self) {
        if let Some(mut inner) = lock_or_warn(&self.inner, "history queue") {
            inner.closed = true;
        }
        self.wake.notify_all();
    }

    /// Sleep until there is something to take, the queue closes, or `timeout`.
    /// `true` when lines are waiting.
    fn wait(&self, timeout: std::time::Duration) -> bool {
        let Some(inner) = lock_or_warn(&self.inner, "history queue") else {
            return false;
        };
        let Ok((inner, _)) = self.wake.wait_timeout_while(inner, timeout, |state| {
            state.lines.is_empty() && !state.closed
        }) else {
            return false;
        };
        !inner.lines.is_empty()
    }

    fn closed(&self) -> bool {
        lock_or_warn(&self.inner, "history queue")
            .map(|inner| inner.closed)
            .unwrap_or(true)
    }

    fn pending(&self) -> usize {
        lock_or_warn(&self.inner, "history queue")
            .map(|inner| inner.pending)
            .unwrap_or(0)
    }

    /// Block until every pushed line has been committed (or `timeout`).
    fn wait_committed(&self) -> bool {
        let Some(inner) = lock_or_warn(&self.inner, "history queue") else {
            return false;
        };
        let Ok((inner, _)) = self
            .wake
            .wait_timeout_while(inner, FLUSH_ACK_TIMEOUT, |state| state.pending > 0)
        else {
            return false;
        };
        inner.pending == 0
    }
}

/// A pane's persistent scrollback: the store, plus the thread that writes to
/// it.
///
/// The terminal task used to call `HistoryStore::append` per output line while
/// holding the grid mutex. One insert costs ~30 µs (a commit plus an FTS5
/// index write per row), so a pane flooding output held the lock — and with it
/// the UI thread — for the whole insert, and the pane's own ceiling was the
/// store's per-row rate. Writes now go through [`Self::push`], which only
/// touches the queue, and the writer thread commits batches off the terminal
/// path; the same flood that used to cap a pane at ~33 k lines/s no longer
/// reaches SQLite at the terminal's cadence at all.
pub struct PaneHistory {
    store: Arc<Mutex<HistoryStore>>,
    queue: Arc<LineQueue>,
}

impl PaneHistory {
    /// Open the pane's store and start its writer thread.
    pub fn open(path: &str, pane_key: &str, cap: u32) -> Result<Self, rusqlite::Error> {
        let store = HistoryStore::open(path, pane_key, cap)?;
        let (rows, bytes) = store.retention_window();
        let store = Arc::new(Mutex::new(store));
        let queue = Arc::new(LineQueue::new(rows, bytes));
        spawn_writer(Arc::clone(&store), Arc::clone(&queue));
        Ok(Self { store, queue })
    }

    /// The store, for readers (search, restore, prune). Writes go through
    /// [`Self::push`] so the lock is never held from the terminal path.
    pub fn store(&self) -> &Arc<Mutex<HistoryStore>> {
        &self.store
    }

    /// Queue a committed output line. Never blocks, never drops unless the
    /// pane is already past what the store would retain.
    pub fn push(&self, line_num: i64, text: &str) {
        self.queue.push(line_num, text);
    }

    /// Lines pushed but not yet committed — how far the store trails the
    /// pane. Zero when the writer has caught up.
    pub fn pending(&self) -> usize {
        self.queue.pending()
    }

    /// Commit everything pushed so far and return whether the queue drained.
    ///
    /// Called on shutdown (a process exit does not run the writer thread to
    /// completion) and by tests, so a restart sees the output printed just
    /// before the app closed.
    pub fn flush(&self) -> bool {
        self.queue.wait_committed()
    }
}

impl Drop for PaneHistory {
    fn drop(&mut self) {
        // The writer flushes what it still holds and exits; the queue is
        // dropped with the pane, so anything left in it is unreachable anyway.
        self.queue.close();
    }
}

/// Writer thread: drain the queue into batches, commit them, trim the store.
fn spawn_writer(store: Arc<Mutex<HistoryStore>>, queue: Arc<LineQueue>) {
    let spawned = std::thread::Builder::new()
        .name("history-writer".to_string())
        .spawn(move || {
            let mut batch: Vec<(i64, String)> = Vec::new();
            loop {
                batch.extend(queue.take());
                // A batch waits for more lines until it is worth a
                // transaction, so a slow producer is not one commit per line.
                if batch.len() < FLUSH_ROWS {
                    if batch.is_empty() {
                        // Closure is only terminal once the queue is empty: a
                        // pane being torn down still has its last lines
                        // committed (a push can land between take and close).
                        if queue.closed() {
                            break;
                        }
                    }
                    if queue.wait(FLUSH_INTERVAL) {
                        continue;
                    }
                }
                if batch.is_empty() {
                    continue;
                }
                let rows = batch.len();
                match store.lock() {
                    Ok(mut store) => {
                        if let Err(e) = store.append_batch(&batch) {
                            log::warn!("history append failed ({rows} rows): {e}");
                        }
                        // One trim per commit: the byte check scans the
                        // pane's retained rows.
                        if let Err(e) = store.enforce_cap() {
                            log::warn!("history retention failed: {e}");
                        }
                    }
                    Err(e) => log::warn!("history store lock poisoned: {e}"),
                }
                // The rows are accounted for whether they were written or not:
                // a failed batch must not leave `flush` waiting.
                queue.flushed(rows);
                batch.clear();
            }
        });
    if let Err(e) = spawned {
        log::error!("could not start the history writer: {e}");
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
    fn prune_missing_panes_reclaims_orphans_and_keeps_known() {
        let path = temp_db_path("prune");
        let live = HistoryStore::open(&path, "pane-live", 100).unwrap();
        let dead = HistoryStore::open(&path, "pane-dead", 100).unwrap();
        live.append(0, "live line kept").unwrap();
        dead.append(0, "orphan marker").unwrap();
        dead.append(1, "orphan second").unwrap();

        // Both panes' rows live in one database; the orphan is searchable.
        assert_eq!(live.line_count().unwrap(), 1);
        assert_eq!(dead.line_count().unwrap(), 2);
        assert_eq!(dead.search("orphan", 10).unwrap().len(), 2);

        // An empty known list means "the caller had no data", never "delete
        // everything" — nothing may be touched.
        assert_eq!(live.prune_missing_panes(&[]).unwrap(), 0);
        assert_eq!(
            dead.line_count().unwrap(),
            2,
            "empty known list pruned rows"
        );

        // Count the raw FTS index entries (no pane_id filter): this is what
        // proves the lines_ad trigger fired for the orphan rows.
        let fts_hits = |needle: &str| -> i64 {
            live.conn
                .query_row(
                    "SELECT COUNT(*) FROM lines_fts WHERE lines_fts MATCH ?1",
                    params![needle],
                    |row| row.get(0),
                )
                .unwrap()
        };
        assert_eq!(fts_hits("orphan"), 2, "orphan rows were never indexed");

        let known = vec!["pane-live".to_string()];
        assert_eq!(live.prune_missing_panes(&known).unwrap(), 2);
        assert_eq!(live.line_count().unwrap(), 1, "known pane's row was pruned");
        assert_eq!(
            live.get_lines(0, 0).unwrap(),
            vec![(0, "live line kept".to_string())]
        );
        assert_eq!(dead.line_count().unwrap(), 0, "orphan rows survived");
        assert!(dead.search("orphan", 10).unwrap().is_empty());
        assert_eq!(
            fts_hits("orphan"),
            0,
            "FTS index still returns deleted text"
        );

        fs::remove_file(&path).ok();
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

    /// A batch lands complete, in one transaction, and is searchable.
    #[test]
    fn append_batch_commits_every_row_in_order() {
        let mut store = HistoryStore::open(":memory:", "pane-a", 100).unwrap();
        let batch: Vec<(i64, String)> = (0..600).map(|i| (i, format!("batch line {i}"))).collect();
        store.append_batch(&batch).unwrap();

        assert_eq!(store.line_count().unwrap(), 600);
        assert_eq!(store.max_line_num().unwrap(), 599);
        assert_eq!(store.get_lines(0, 599).unwrap(), batch);
        // The FTS index is maintained by the insert trigger, so a batched
        // insert is searchable exactly like a single one.
        assert_eq!(
            store.search_user_text("batch line 599", 5).unwrap().len(),
            1
        );
        assert!(store.append_batch(&[]).is_ok());
    }

    /// The byte cap trims the oldest rows once retained text exceeds it,
    /// even when the row cap would not have.
    #[test]
    fn byte_cap_trims_oldest_rows() {
        // 100-byte lines, 250-byte budget: the newest two rows fit, the third
        // does not.
        let mut store = HistoryStore::open(":memory:", "pane-a", 0)
            .unwrap()
            .with_byte_cap(250);
        let long = "x".repeat(100);
        let batch: Vec<(i64, String)> = (0..3).map(|i| (i, format!("{i}{long}"))).collect();
        store.append_batch(&batch).unwrap();
        store.enforce_cap().unwrap();

        let kept = store.get_lines(0, 9).unwrap();
        assert_eq!(kept.len(), 2, "oldest rows beyond the byte budget are gone");
        assert_eq!(kept.first().unwrap().0, 1);
        assert_eq!(kept.last().unwrap().0, 2);
        // The row cap is untouched by the byte trim when it is disabled.
        assert_eq!(store.max_line_num().unwrap(), 2);
    }

    /// A line dropped by the queue is one the store would have deleted, so
    /// the retained window stays contiguous — and a `flush` wait cannot hang
    /// on a line that was dropped.
    #[test]
    fn a_full_queue_drops_only_past_the_retention_window() {
        let queue = LineQueue::new(4, 10_000);
        for i in 1..=10 {
            queue.push(i, &format!("line {i}"));
        }
        let taken = queue.take();
        let nums: Vec<i64> = taken.iter().map(|(n, _)| *n).collect();
        assert_eq!(
            nums,
            vec![7, 8, 9, 10],
            "the newest window survives; older lines are what enforce_cap deletes"
        );
        queue.flushed(taken.len());
        assert!(
            queue.wait_committed(),
            "dropped lines must not hold a flush open"
        );

        // Same for the byte window, with one long line standing in for many.
        let queue = LineQueue::new(usize::MAX, 30);
        queue.push(1, &"a".repeat(20));
        queue.push(2, &"b".repeat(20));
        let taken = queue.take();
        assert_eq!(taken.len(), 1);
        assert_eq!(
            taken[0].0, 2,
            "the older over-budget line is the one dropped"
        );
    }

    /// End to end: what the terminal pushes reaches the store through the
    /// writer thread, in order, without the caller ever touching SQLite.
    #[test]
    fn pushed_lines_reach_the_store_and_a_flush_waits_for_them() {
        let path = temp_db_path("push");
        let history = PaneHistory::open(&path, "pane-a", 100).unwrap();
        let store = Arc::clone(history.store());
        for i in 1..=50 {
            history.push(i, &format!("pushed {i}"));
        }
        assert!(history.flush(), "flush must wait for the writer");
        assert_eq!(store.lock().unwrap().max_line_num().unwrap(), 50);
        assert_eq!(store.lock().unwrap().line_count().unwrap(), 50);

        // A pending write must survive the pane handle going away: the queue
        // closes, the writer commits what it holds, then exits.
        history.push(51, "last word");
        drop(history);
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        let mut last = 0;
        while std::time::Instant::now() < deadline {
            last = store.lock().unwrap().max_line_num().unwrap();
            if last == 51 {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        assert_eq!(last, 51, "a closing writer must commit what it still holds");
        fs::remove_file(&path).ok();
    }

    /// The writer commits on its own, without a flush call.
    #[test]
    fn the_writer_commits_on_its_interval() {
        let history = PaneHistory::open(":memory:", "pane-a", 100).unwrap();
        let store = Arc::clone(history.store());
        history.push(1, "unflushed line");
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        let mut last = 0;
        while std::time::Instant::now() < deadline {
            last = store.lock().unwrap().max_line_num().unwrap();
            if last == 1 {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        assert_eq!(last, 1, "the writer thread must commit without being asked");
    }

    /// What a pane writes is what the next launch restores: the store-level
    /// half of "scrollback survives a restart" (the grid feeds the returned
    /// rows back through `feed_restore_lines`).
    #[test]
    fn a_reopened_pane_reads_back_what_the_writer_committed() {
        let path = temp_db_path("restore");
        {
            let history = PaneHistory::open(&path, "pane-a", 100).unwrap();
            for i in 1..=3 {
                history.push(i, &format!("session one line {i}"));
            }
            assert!(history.flush());
        }
        // A restart: same database, same pane id, fresh store and writer.
        let reopened = PaneHistory::open(&path, "pane-a", 100).unwrap();
        let store = reopened.store().lock().unwrap();
        assert_eq!(store.max_line_num().unwrap(), 3);
        let lines: Vec<String> = store
            .get_lines(1, 3)
            .unwrap()
            .into_iter()
            .map(|(_, text)| text)
            .collect();
        assert_eq!(
            lines,
            vec![
                "session one line 1",
                "session one line 2",
                "session one line 3"
            ]
        );
        assert_eq!(store.search_user_text("session one", 10).unwrap().len(), 3);
        drop(store);
        drop(reopened);
        fs::remove_file(&path).ok();
    }
}
