//! Vault index: a SQLite + FTS5 store over a directory of Markdown notes.
//!
//! The wiki pane browses a *vault* — a plain directory of `.md` files — and
//! this module is the one definition of what a note is (the walk's hidden,
//! extension, depth and count rules) and of what searching one costs (the
//! `notes_fts` index). It reuses the scrollback store's skeleton deliberately
//! ([`crate::history`]): external-content FTS5 with the three triggers, the
//! same pragmas, the same owner-only mode, and the same process-wide write
//! lock — so the v0.5.1 engine's operational lessons carry over instead of
//! being re-learned.
//!
//! The store file lives in the app's state directory (`state_dir()/vaults.db`),
//! never inside a vault: a vault is user data this module only reads, and the
//! roadmap's agent-access item needs the index reachable from the CLI too,
//! which cannot resolve Godot's `user://`.

use std::path::Path;
use std::time::UNIX_EPOCH;

use rusqlite::{Connection, params};

use crate::history::{restrict_to_owner, sanitize_fts_query, write_guard};

/// Notes one walk keeps, and how deep it descends. Moved here from the wiki
/// pane's GDScript scan so the pane's list and the search index cannot
/// disagree about which files are notes.
pub const MAX_NOTES: usize = 2000;
pub const MAX_DEPTH: usize = 16;

/// Longest note body stored or read, in bytes. Mirrors the display path's
/// `TextRead.DEFAULT_MAX_BYTES` (godot/scenes/panes/text_read.gd): the index
/// and the note view must cut at the same place, or a search hit can match
/// text the view never shows.
pub const MAX_NOTE_BYTES: u64 = 1 << 20;

/// Longest title kept (the first heading, or the file stem).
const MAX_TITLE_CHARS: usize = 200;

/// Most hits one search returns.
pub const SEARCH_LIMIT_MAX: usize = 500;

/// One note the walk found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScannedNote {
    /// `/`-joined path relative to the vault root (portable across platforms;
    /// the index key and the path a caller shows).
    pub rel_path: String,
    /// The absolute path to read.
    pub abs_path: String,
    /// Modification time in nanoseconds since the epoch — seconds would miss a
    /// same-second edit whose size did not change.
    pub mtime: i64,
    pub size: i64,
}

/// A walk's result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScanResult {
    /// Sorted by `rel_path`.
    pub notes: Vec<ScannedNote>,
    /// The count cap cut the walk short with a note still to list.
    pub truncated: bool,
}

/// One row to write into the index.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NoteRow {
    pub vault_id: String,
    pub rel_path: String,
    pub mtime: i64,
    pub size: i64,
    pub title: String,
    pub body: String,
}

/// One search hit.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SearchHit {
    pub rel_path: String,
    pub title: String,
    pub snippet: String,
}

/// What one index pass changed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IndexOutcome {
    /// Every note the walk found (the pane's list), sorted.
    pub notes: Vec<ScannedNote>,
    pub truncated: bool,
    pub added: usize,
    pub updated: usize,
    pub removed: usize,
    /// Notes the walk saw but could not read (permissions, a race).
    pub unreadable: usize,
}

/// Walk `root` for Markdown notes under the production caps.
pub fn scan_vault(root: &str) -> ScanResult {
    scan_vault_limited(root, MAX_NOTES, MAX_DEPTH)
}

/// Walk `root` with explicit caps (tests exercise the limits without
/// building 2000 files, the same seam the pane's old `_scan_vault(limit)` had).
///
/// Best-effort by design: an unreadable entry is skipped, not an error — a
/// vault is user data and one bad subdirectory should not hide the rest.
pub fn scan_vault_limited(root: &str, max_notes: usize, max_depth: usize) -> ScanResult {
    let mut notes = Vec::new();
    let mut truncated = false;
    walk(
        Path::new(root),
        Path::new(""),
        0,
        max_notes,
        max_depth,
        &mut notes,
        &mut truncated,
    );
    notes.sort_by(|a, b| a.rel_path.cmp(&b.rel_path));
    ScanResult { notes, truncated }
}

fn walk(
    dir: &Path,
    rel: &Path,
    depth: usize,
    max_notes: usize,
    max_depth: usize,
    out: &mut Vec<ScannedNote>,
    truncated: &mut bool,
) {
    if *truncated || depth > max_depth {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    // Sorted per directory so the walk is deterministic whatever order the
    // filesystem hands entries back in.
    let mut names: Vec<String> = entries
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    for name in names {
        // Hidden entries are skipped at every level (`.obsidian`, `.git`,
        // `.trash`) — the same rule the pane applied before the index existed.
        if name.starts_with('.') {
            continue;
        }
        let child = dir.join(&name);
        let child_rel = rel.join(&name);
        // `metadata` follows symlinks, so a symlinked directory is walked like
        // a directory; the depth cap is what stops a loop.
        let Ok(meta) = std::fs::metadata(&child) else {
            continue;
        };
        if meta.is_dir() {
            walk(
                &child,
                &child_rel,
                depth + 1,
                max_notes,
                max_depth,
                out,
                truncated,
            );
        } else if meta.is_file() && has_md_extension(&name) {
            if out.len() >= max_notes {
                *truncated = true;
                return;
            }
            out.push(ScannedNote {
                rel_path: slash_join(&child_rel),
                abs_path: child.to_string_lossy().into_owned(),
                mtime: mtime_nanos(&meta),
                size: meta.len() as i64,
            });
        }
    }
}

fn has_md_extension(name: &str) -> bool {
    Path::new(name)
        .extension()
        .is_some_and(|ext| ext.eq_ignore_ascii_case("md"))
}

fn slash_join(path: &Path) -> String {
    path.components()
        .map(|c| c.as_os_str().to_string_lossy().into_owned())
        .collect::<Vec<_>>()
        .join("/")
}

fn mtime_nanos(meta: &std::fs::Metadata) -> i64 {
    meta.modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_nanos().min(i64::MAX as u128) as i64)
        .unwrap_or(0)
}

/// Read a note the way the display path does: at most [`MAX_NOTE_BYTES`], with
/// a UTF-8 sequence the cap landed inside dropped rather than replaced.
///
/// `None` for anything unreadable. Returns `(text, truncated)`.
pub fn read_note(abs_path: &str) -> Option<(String, bool)> {
    use std::io::Read;
    let mut file = std::fs::File::open(abs_path).ok()?;
    let size = file.metadata().ok()?.len();
    let mut bytes = Vec::new();
    file.by_ref()
        .take(MAX_NOTE_BYTES)
        .read_to_end(&mut bytes)
        .ok()?;
    Some((trim_torn_tail(bytes), size > MAX_NOTE_BYTES))
}

/// Drop the trailing bytes of an incomplete UTF-8 sequence so a body cut at
/// the cap does not end on a replacement glyph (the display path's
/// `TextRead._decode_utf8_prefix` does the same thing in GDScript).
fn trim_torn_tail(mut bytes: Vec<u8>) -> String {
    let size = bytes.len();
    let mut cut = size;
    // Walk back over up to 3 continuation bytes to the lead of the last
    // sequence; if that sequence is incomplete, drop it as well.
    while cut > 0 && size - cut < 4 && (bytes[cut - 1] & 0xC0) == 0x80 {
        cut -= 1;
    }
    if cut > 0 {
        let lead = bytes[cut - 1];
        let need = if lead & 0xE0 == 0xC0 {
            2
        } else if lead & 0xF0 == 0xE0 {
            3
        } else if lead & 0xF8 == 0xF0 {
            4
        } else {
            1
        };
        if size - (cut - 1) < need {
            cut -= 1;
        }
    }
    bytes.truncate(cut);
    String::from_utf8_lossy(&bytes).into_owned()
}

/// What a list row shows: the first heading's text, else the file stem.
pub fn note_title(rel_path: &str, body: &str) -> String {
    for line in body.lines() {
        let trimmed = line.trim_start();
        if let Some(rest) = trimmed.strip_prefix('#') {
            let title = rest.trim_start_matches('#').trim();
            if !title.is_empty() {
                return title.chars().take(MAX_TITLE_CHARS).collect();
            }
        }
        if !trimmed.is_empty() {
            // The first non-empty line is not a heading; the stem is the name.
            break;
        }
    }
    let stem = Path::new(rel_path)
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| rel_path.to_string());
    stem.chars().take(MAX_TITLE_CHARS).collect()
}

/// The vault index.
pub struct VaultStore {
    conn: Connection,
}

impl VaultStore {
    /// Open or create the vault index at `path`.
    ///
    /// The pragmas, the owner-only mode on the file and its `-wal`/`-shm`
    /// siblings, and the external-content FTS5 triggers mirror
    /// `HistoryStore::open` — the same store shape, the same umask problem,
    /// the same fix. `user_version` is this schema's own version gate (the
    /// history store's 2 must never be mistaken for it).
    pub fn open(path: &str) -> Result<Self, rusqlite::Error> {
        let conn = Connection::open(path)?;
        // The backstop for another *process* on the same file; this process's
        // own writers are serialized by [`write_guard`] before SQLite sees
        // them.
        conn.busy_timeout(std::time::Duration::from_secs(5))?;
        let version: i64 = conn.pragma_query_value(None, "user_version", |row| row.get(0))?;
        conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")?;
        if version < 1 {
            conn.execute_batch(VAULT_SCHEMA)?;
        }
        for candidate in [
            path.to_string(),
            format!("{path}-wal"),
            format!("{path}-shm"),
        ] {
            restrict_to_owner(&candidate);
        }
        Ok(Self { conn })
    }

    /// Insert or refresh rows in one transaction (one FTS index write per row;
    /// the batching shape mirrors `HistoryStore::append_batch`).
    pub fn upsert_batch(&mut self, rows: &[NoteRow]) -> Result<(), rusqlite::Error> {
        let _serialized = write_guard();
        let tx = self.conn.transaction()?;
        {
            let mut stmt = tx.prepare_cached(
                "INSERT INTO notes (vault_id, rel_path, mtime, size, title, body)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                 ON CONFLICT(vault_id, rel_path) DO UPDATE SET
                     mtime=excluded.mtime, size=excluded.size,
                     title=excluded.title, body=excluded.body",
            )?;
            for row in rows {
                stmt.execute(params![
                    row.vault_id,
                    row.rel_path,
                    row.mtime,
                    row.size,
                    row.title,
                    row.body
                ])?;
            }
        }
        tx.commit()
    }

    /// `(rel_path, mtime, size)` for every indexed note of one vault — the
    /// staleness side of an index pass.
    pub fn indexed(&self, vault_id: &str) -> Result<Vec<(String, i64, i64)>, rusqlite::Error> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT rel_path, mtime, size FROM notes WHERE vault_id = ?1")?;
        let rows = stmt.query_map(params![vault_id], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, i64>(1)?,
                row.get::<_, i64>(2)?,
            ))
        })?;
        rows.collect()
    }

    /// Delete this vault's rows whose path is not in `known` (the walked set),
    /// returning how many went. Only call this with a *complete* walk: a
    /// truncated list would delete the notes it did not reach.
    pub fn remove_missing(
        &self,
        vault_id: &str,
        known: &[String],
    ) -> Result<usize, rusqlite::Error> {
        let _serialized = write_guard();
        let mut stmt = self
            .conn
            .prepare_cached("SELECT rel_path FROM notes WHERE vault_id = ?1")?;
        let stored: Vec<String> = stmt
            .query_map(params![vault_id], |row| row.get(0))?
            .collect::<Result<_, _>>()?;
        let mut deleted = 0usize;
        for rel_path in stored {
            if known.contains(&rel_path) {
                continue;
            }
            self.conn.execute(
                "DELETE FROM notes WHERE vault_id = ?1 AND rel_path = ?2",
                params![vault_id, rel_path],
            )?;
            deleted += 1;
        }
        Ok(deleted)
    }

    /// Drop rows for vault roots that are no longer directories (a moved or
    /// deleted vault), so the index does not accumulate dead scopes.
    pub fn prune_dead_vaults(&self) -> Result<usize, rusqlite::Error> {
        let _serialized = write_guard();
        let mut stmt = self
            .conn
            .prepare_cached("SELECT DISTINCT vault_id FROM notes")?;
        let vaults: Vec<String> = stmt
            .query_map([], |row| row.get(0))?
            .collect::<Result<_, _>>()?;
        drop(stmt);
        let mut deleted = 0usize;
        for vault_id in vaults {
            if Path::new(&vault_id).is_dir() {
                continue;
            }
            deleted += self
                .conn
                .execute("DELETE FROM notes WHERE vault_id = ?1", params![vault_id])?;
        }
        Ok(deleted)
    }

    /// Notes indexed for one vault.
    pub fn note_count(&self, vault_id: &str) -> Result<i64, rusqlite::Error> {
        self.conn.query_row(
            "SELECT COUNT(*) FROM notes WHERE vault_id = ?1",
            params![vault_id],
            |row| row.get(0),
        )
    }

    /// Forget one vault's notes.
    pub fn clear_vault(&self, vault_id: &str) -> Result<(), rusqlite::Error> {
        let _serialized = write_guard();
        self.conn
            .execute("DELETE FROM notes WHERE vault_id = ?1", params![vault_id])?;
        Ok(())
    }

    /// FTS5 `MATCH` within one vault, best rank first, with a body snippet.
    ///
    /// `pattern` is FTS5 query syntax (callers with user text want
    /// [`Self::search_user_text`]); `limit` is clamped to `1..=SEARCH_LIMIT_MAX`.
    pub fn search(
        &self,
        vault_id: &str,
        pattern: &str,
        limit: usize,
    ) -> Result<Vec<SearchHit>, rusqlite::Error> {
        let limit = limit.clamp(1, SEARCH_LIMIT_MAX);
        let mut stmt = self.conn.prepare_cached(
            "SELECT n.rel_path, n.title, snippet(notes_fts, 1, '[', ']', '…', 24)
             FROM notes n JOIN notes_fts ON notes_fts.rowid = n.rowid
             WHERE n.vault_id = ?1 AND notes_fts MATCH ?2
             ORDER BY bm25(notes_fts)
             LIMIT ?3",
        )?;
        let rows = stmt.query_map(params![vault_id, pattern, limit as i64], |row| {
            Ok(SearchHit {
                rel_path: row.get(0)?,
                title: row.get(1)?,
                snippet: row.get(2)?,
            })
        })?;
        rows.collect()
    }

    /// Search with free text: the query is sanitized first (only word
    /// characters, quoted terms) — the same wrapper `HistoryStore` exposes,
    /// because FTS5's `MATCH` takes a query language, not a string.
    pub fn search_user_text(
        &self,
        vault_id: &str,
        text: &str,
        limit: usize,
    ) -> Result<Vec<SearchHit>, rusqlite::Error> {
        let pattern = sanitize_fts_query(text);
        if pattern.trim().is_empty() {
            return Ok(Vec::new());
        }
        self.search(vault_id, &pattern, limit)
    }
}

/// Bring one vault's index up to date and return what changed.
///
/// The walk decides which files are notes; a note whose `mtime`/`size` match
/// the index is not re-read, one that changed is re-indexed, one that vanished
/// is dropped (only from a complete walk — a truncated list would delete the
/// notes it did not reach), and rows for dead vault roots are pruned.
pub fn index_vault(store: &mut VaultStore, root: &str) -> Result<IndexOutcome, rusqlite::Error> {
    index_vault_limited(store, root, MAX_NOTES, MAX_DEPTH)
}

/// [`index_vault`] with explicit walk caps (tests exercise the truncation rule
/// without building 2000 files, like [`scan_vault_limited`]).
pub fn index_vault_limited(
    store: &mut VaultStore,
    root: &str,
    max_notes: usize,
    max_depth: usize,
) -> Result<IndexOutcome, rusqlite::Error> {
    let scan = scan_vault_limited(root, max_notes, max_depth);
    let indexed = store.indexed(root)?;
    let mut rows = Vec::new();
    let mut added = 0usize;
    let mut updated = 0usize;
    let mut unreadable = 0usize;
    for note in &scan.notes {
        let known = indexed
            .iter()
            .find(|(rel, _, _)| rel == &note.rel_path)
            .map(|(_, mtime, size)| (*mtime, *size));
        if known == Some((note.mtime, note.size)) {
            continue;
        }
        match read_note(&note.abs_path) {
            Some((body, _truncated)) => {
                if known.is_some() {
                    updated += 1;
                } else {
                    added += 1;
                }
                rows.push(NoteRow {
                    vault_id: root.to_string(),
                    rel_path: note.rel_path.clone(),
                    mtime: note.mtime,
                    size: note.size,
                    title: note_title(&note.rel_path, &body),
                    body,
                });
            }
            None => unreadable += 1,
        }
    }
    if !rows.is_empty() {
        store.upsert_batch(&rows)?;
    }
    let removed = if scan.truncated {
        0
    } else {
        let known: Vec<String> = scan.notes.iter().map(|n| n.rel_path.clone()).collect();
        store.remove_missing(root, &known)?
    };
    store.prune_dead_vaults()?;
    Ok(IndexOutcome {
        notes: scan.notes,
        truncated: scan.truncated,
        added,
        updated,
        removed,
        unreadable,
    })
}

/// The vault schema: a notes table keyed by `(vault_id, rel_path)` with an
/// external-content FTS5 index over title and body.
///
/// `porter unicode61` (not the history store's default tokenizer): notes are
/// prose, where "running" matching "run" is wanted; terminal lines, which the
/// history store indexes, are not prose and keep the default.
const VAULT_SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS notes (
    vault_id TEXT NOT NULL,
    rel_path TEXT NOT NULL,
    mtime    INTEGER NOT NULL,
    size     INTEGER NOT NULL,
    title    TEXT NOT NULL,
    body     TEXT NOT NULL,
    PRIMARY KEY (vault_id, rel_path)
);
CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(
    title, body,
    content=notes,
    content_rowid=rowid,
    tokenize='porter unicode61'
);
CREATE TRIGGER IF NOT EXISTS notes_ai AFTER INSERT ON notes BEGIN
    INSERT INTO notes_fts(rowid, title, body) VALUES (new.rowid, new.title, new.body);
END;
CREATE TRIGGER IF NOT EXISTS notes_ad AFTER DELETE ON notes BEGIN
    INSERT INTO notes_fts(notes_fts, rowid, title, body) VALUES ('delete', old.rowid, old.title, old.body);
END;
CREATE TRIGGER IF NOT EXISTS notes_au AFTER UPDATE ON notes BEGIN
    INSERT INTO notes_fts(notes_fts, rowid, title, body) VALUES ('delete', old.rowid, old.title, old.body);
    INSERT INTO notes_fts(rowid, title, body) VALUES (new.rowid, new.title, new.body);
END;
PRAGMA user_version=1;
";

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn temp_db(tag: &str) -> String {
        let path = format!(
            "{}/gpty_vault_test_{}_{}.db",
            std::env::temp_dir().display(),
            tag,
            std::process::id()
        );
        for suffix in ["", "-wal", "-shm"] {
            let _ = fs::remove_file(format!("{path}{suffix}"));
        }
        path
    }

    fn temp_vault(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("gpty_vault_{tag}_{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn write_note(dir: &Path, rel: &str, text: &str) {
        let path = dir.join(rel);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(path, text).unwrap();
    }

    fn root_str(dir: &Path) -> String {
        dir.to_string_lossy().into_owned()
    }

    #[test]
    fn open_creates_the_schema_and_is_idempotent() {
        let path = temp_db("open");
        let vault = temp_vault("open");
        {
            let store = VaultStore::open(&path).unwrap();
            assert_eq!(store.note_count(&root_str(&vault)).unwrap(), 0);
        }
        // Reopening an existing store must not fail on the schema's
        // CREATE ... IF NOT EXISTS or the version gate.
        let store = VaultStore::open(&path).unwrap();
        assert_eq!(store.note_count("any").unwrap(), 0);
    }

    #[cfg(unix)]
    #[test]
    fn the_store_file_is_owner_only() {
        use std::os::unix::fs::PermissionsExt;
        let path = temp_db("owner");
        fs::write(&path, b"").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
        let _store = VaultStore::open(&path).unwrap();
        let mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(
            mode, 0o600,
            "the umask must not decide who can read the index"
        );
    }

    #[test]
    fn upsert_and_search_find_a_note() {
        let path = temp_db("search");
        let vault = temp_vault("search");
        let mut store = VaultStore::open(&path).unwrap();
        store
            .upsert_batch(&[NoteRow {
                vault_id: root_str(&vault),
                rel_path: "a.md".into(),
                mtime: 1,
                size: 10,
                title: "Widgets".into(),
                body: "The widget is running quickly.".into(),
            }])
            .unwrap();
        let hits = store
            .search_user_text(&root_str(&vault), "widget", 10)
            .unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].rel_path, "a.md");
        assert_eq!(hits[0].title, "Widgets");
        assert!(
            hits[0].snippet.contains("widget"),
            "snippet: {}",
            hits[0].snippet
        );
    }

    #[test]
    fn a_search_is_scoped_to_one_vault() {
        let path = temp_db("scope");
        let vault = temp_vault("scope_a");
        let mut store = VaultStore::open(&path).unwrap();
        let mut row = |vault_id: &str, rel: &str| NoteRow {
            vault_id: vault_id.into(),
            rel_path: rel.into(),
            mtime: 1,
            size: 1,
            title: "Same".into(),
            body: "shared token".into(),
        };
        store
            .upsert_batch(&[
                row(&root_str(&vault), "a.md"),
                row("/nonexistent/other-vault", "b.md"),
            ])
            .unwrap();
        let hits = store
            .search_user_text(&root_str(&vault), "shared", 10)
            .unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].rel_path, "a.md");
        // The dead vault's rows are pruned; the live one's are untouched.
        let pruned = store.prune_dead_vaults().unwrap();
        assert_eq!(pruned, 1);
        assert_eq!(store.note_count(&root_str(&vault)).unwrap(), 1);
    }

    #[test]
    fn porter_stemming_matches_a_word_form() {
        let path = temp_db("porter");
        let vault = temp_vault("porter");
        let mut store = VaultStore::open(&path).unwrap();
        store
            .upsert_batch(&[NoteRow {
                vault_id: root_str(&vault),
                rel_path: "a.md".into(),
                mtime: 1,
                size: 1,
                title: "Notes".into(),
                body: "The tests are running.".into(),
            }])
            .unwrap();
        let hits = store
            .search_user_text(&root_str(&vault), "run", 10)
            .unwrap();
        assert_eq!(hits.len(), 1, "prose needs the porter tokenizer");
    }

    #[test]
    fn a_punctuation_only_query_is_not_an_error() {
        let path = temp_db("empty_query");
        let vault = temp_vault("empty_query");
        let store = VaultStore::open(&path).unwrap();
        let hits = store
            .search_user_text(&root_str(&vault), "!!! ???", 10)
            .unwrap();
        assert!(hits.is_empty());
    }

    #[test]
    fn the_walk_skips_hidden_entries_and_non_markdown() {
        let vault = temp_vault("walk");
        write_note(&vault, "note.md", "# Heading");
        write_note(&vault, "sub/nested.md", "# Nested");
        write_note(&vault, ".hidden/secret.md", "# Secret");
        write_note(&vault, "top.txt", "not a note");
        let scan = scan_vault(&root_str(&vault));
        let paths: Vec<&str> = scan.notes.iter().map(|n| n.rel_path.as_str()).collect();
        assert_eq!(paths, vec!["note.md", "sub/nested.md"]);
        assert!(!scan.truncated);
    }

    #[test]
    fn the_walk_honors_the_depth_cap() {
        let vault = temp_vault("depth");
        let mut deep = vault.clone();
        for i in 0..MAX_DEPTH + 1 {
            deep = deep.join(format!("d{i}"));
        }
        fs::create_dir_all(&deep).unwrap();
        fs::write(deep.join("deep.md"), "# Deep").unwrap();
        write_note(&vault, "top.md", "# Top");
        let scan = scan_vault(&root_str(&vault));
        let paths: Vec<&str> = scan.notes.iter().map(|n| n.rel_path.as_str()).collect();
        assert_eq!(
            paths,
            vec!["top.md"],
            "a note past the depth cap is not walked"
        );
    }

    #[test]
    fn the_walk_caps_notes_and_reports_truncation() {
        let vault = temp_vault("cap");
        for i in 0..3 {
            write_note(&vault, &format!("n{i}.md"), "# N");
        }
        let scan = scan_vault_limited(&root_str(&vault), 2, MAX_DEPTH);
        assert_eq!(scan.notes.len(), 2);
        assert!(
            scan.truncated,
            "the cap must report that a note was left out"
        );
        assert!(!scan_vault_limited(&root_str(&vault), MAX_NOTES, MAX_DEPTH).truncated);
    }

    #[test]
    fn indexing_adds_updates_and_removes_notes() {
        let path = temp_db("index");
        let vault = temp_vault("index");
        let root = root_str(&vault);
        let mut store = VaultStore::open(&path).unwrap();
        write_note(&vault, "a.md", "# First\nalpha");
        let first = index_vault(&mut store, &root).unwrap();
        assert_eq!((first.added, first.updated, first.removed), (1, 0, 0));
        assert_eq!(store.note_count(&root).unwrap(), 1);
        // Unchanged: nothing re-read, nothing re-written.
        let again = index_vault(&mut store, &root).unwrap();
        assert_eq!((again.added, again.updated, again.removed), (0, 0, 0));
        // Changed size (deterministic across filesystems): re-read.
        write_note(&vault, "a.md", "# First\nalpha and omega");
        let changed = index_vault(&mut store, &root).unwrap();
        assert_eq!((changed.added, changed.updated, changed.removed), (0, 1, 0));
        assert_eq!(
            store.search_user_text(&root, "omega", 10).unwrap().len(),
            1,
            "the updated body must be searchable"
        );
        // Vanished: the row goes with it.
        fs::remove_file(vault.join("a.md")).unwrap();
        let removed = index_vault(&mut store, &root).unwrap();
        assert_eq!((removed.added, removed.updated, removed.removed), (0, 0, 1));
        assert_eq!(store.note_count(&root).unwrap(), 0);
        assert!(
            store
                .search_user_text(&root, "omega", 10)
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn a_truncated_walk_never_prunes_notes_it_did_not_reach() {
        let path = temp_db("truncated");
        let vault = temp_vault("truncated");
        let root = root_str(&vault);
        let mut store = VaultStore::open(&path).unwrap();
        for i in 0..3 {
            write_note(&vault, &format!("n{i}.md"), &format!("# N{i}"));
        }
        index_vault(&mut store, &root).unwrap();
        assert_eq!(store.note_count(&root).unwrap(), 3);
        // A pass whose walk stopped at one note must not conclude the other
        // two are gone: `index_vault` skips the prune entirely, and search
        // keeps finding every note.
        let outcome = index_vault_limited(&mut store, &root, 1, MAX_DEPTH).unwrap();
        assert!(outcome.truncated);
        assert_eq!(outcome.removed, 0, "a truncated walk must not prune");
        assert_eq!(store.note_count(&root).unwrap(), 3);
        assert_eq!(store.search_user_text(&root, "N2", 10).unwrap().len(), 1);
    }

    #[test]
    fn a_torn_utf8_tail_at_the_cap_is_dropped_not_replaced() {
        let vault = temp_vault("torn");
        let mut body = vec![b'a'; (MAX_NOTE_BYTES - 1) as usize];
        body.extend_from_slice("é".as_bytes()); // 2 bytes: the read stops after its lead
        fs::write(vault.join("torn.md"), &body).unwrap();
        let path = vault.join("torn.md");
        let (text, truncated) = read_note(&path.to_string_lossy()).unwrap();
        assert!(truncated);
        assert!(
            !text.contains('\u{FFFD}'),
            "a cut sequence must be dropped, not replaced"
        );
        assert_eq!(text.len(), (MAX_NOTE_BYTES - 1) as usize);
    }

    #[test]
    fn the_title_is_the_first_heading_else_the_file_stem() {
        assert_eq!(
            note_title("dir/my-note.md", "# Real Title\nbody"),
            "Real Title"
        );
        assert_eq!(note_title("dir/my-note.md", "\n\n## Later\nbody"), "Later");
        assert_eq!(note_title("dir/my-note.md", "plain body"), "my-note");
        assert_eq!(note_title("dir/my-note.md", ""), "my-note");
    }

    #[test]
    fn clear_vault_forgets_only_that_vault() {
        let path = temp_db("clear");
        let vault = temp_vault("clear");
        let mut store = VaultStore::open(&path).unwrap();
        store
            .upsert_batch(&[
                NoteRow {
                    vault_id: root_str(&vault),
                    rel_path: "a.md".into(),
                    mtime: 1,
                    size: 1,
                    title: "A".into(),
                    body: "alpha".into(),
                },
                NoteRow {
                    vault_id: "/nonexistent/other".into(),
                    rel_path: "b.md".into(),
                    mtime: 1,
                    size: 1,
                    title: "B".into(),
                    body: "alpha".into(),
                },
            ])
            .unwrap();
        store.clear_vault(&root_str(&vault)).unwrap();
        assert_eq!(store.note_count(&root_str(&vault)).unwrap(), 0);
        assert_eq!(store.note_count("/nonexistent/other").unwrap(), 1);
    }
}
