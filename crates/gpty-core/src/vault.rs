//! Vault index: a SQLite + FTS5 store over a directory of Markdown notes.
//!
//! The wiki pane browses *and edits* a vault — a plain directory of `.md`
//! files — and this module is the one definition of what a note is (the
//! walk's hidden, extension, depth and count rules), of what searching one
//! costs (the `notes_fts` index), and of what writing one is allowed to touch
//! ([`write_vault_note`]: the same path vocabulary, containment through
//! symlinks, a stamp that refuses to overwrite an outside edit, and an atomic
//! replacement that keeps the note's own mode). It reuses the scrollback
//! store's skeleton deliberately ([`crate::history`]): external-content FTS5
//! with the three triggers, the same pragmas, the same owner-only mode, and
//! the same process-wide write lock — so the v0.5.1 engine's operational
//! lessons carry over instead of being re-learned.
//!
//! The store file lives in the app's state directory (`state_dir()/vaults.db`),
//! never inside a vault: a vault is the user's own data, and the roadmap's
//! agent-access item needs the index reachable from the CLI too, which cannot
//! resolve Godot's `user://`.

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
    read_file_capped(Path::new(abs_path))
}

/// [`read_note`]'s shared body, so the index and the editor load the same cut.
fn read_file_capped(path: &Path) -> Option<(String, bool)> {
    use std::io::Read;
    let mut file = std::fs::File::open(path).ok()?;
    let size = file.metadata().ok()?.len();
    let mut bytes = Vec::new();
    file.by_ref()
        .take(MAX_NOTE_BYTES)
        .read_to_end(&mut bytes)
        .ok()?;
    Some((trim_torn_tail(bytes), size > MAX_NOTE_BYTES))
}

/// A note's on-disk identity: the (mtime, size) pair the index uses to decide
/// whether a note changed, and the pair a save checks before overwriting.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NoteStamp {
    /// Modification time in microseconds since the epoch. Microseconds, not
    /// the index's nanoseconds: the stamp travels to the pane through JSON,
    /// whose numbers are IEEE-754 doubles — 1.7e18 ns loses its low bits in
    /// that round trip, while 1.8e15 µs is exact.
    pub mtime: i64,
    pub size: i64,
}

impl NoteStamp {
    fn of(meta: &std::fs::Metadata) -> Self {
        NoteStamp {
            mtime: mtime_nanos(meta) / 1000,
            size: meta.len() as i64,
        }
    }
}

/// A note as the editor loads it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NoteContent {
    /// The text, at most [`MAX_NOTE_BYTES`], torn UTF-8 tail dropped.
    pub text: String,
    /// The text is a prefix of a larger file. The editor must not offer
    /// editing: saving a truncated read would drop everything past the cut.
    pub truncated: bool,
    /// The file uses CRLF line endings. The editor works in LF and the save
    /// puts the CRLFs back, or editing one word rewrites every line.
    pub crlf: bool,
    pub stamp: NoteStamp,
}

/// Why a note could not be read or written. [`NoteError::code`] is the stable
/// spelling the FFI answers, and the pane switches on it — `changed_on_disk`
/// is what offers an explicit overwrite, so the codes are a contract.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NoteError {
    /// The vault root is not an absolute directory.
    BadVault(String),
    /// The vault-relative path is not a note path: empty, absolute, escaping
    /// the vault, hidden at any level, or not `.md`.
    BadPath(String),
    /// No regular file at the resolved path.
    NotFound,
    /// The file changed on disk since the caller loaded it.
    ChangedOnDisk,
    /// The content exceeds [`MAX_NOTE_BYTES`].
    TooLarge(usize),
    /// The path resolves — through a symlink — outside the vault.
    Outside,
    Io(String),
}

impl NoteError {
    /// The stable code the FFI answers for this error.
    pub fn code(&self) -> &'static str {
        match self {
            NoteError::BadVault(_) => "bad_vault",
            NoteError::BadPath(_) => "bad_path",
            NoteError::NotFound => "not_found",
            NoteError::ChangedOnDisk => "changed_on_disk",
            NoteError::TooLarge(_) => "too_large",
            NoteError::Outside => "outside_vault",
            NoteError::Io(_) => "io",
        }
    }
}

impl std::fmt::Display for NoteError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            NoteError::BadVault(m) => write!(f, "not a vault directory: {m}"),
            NoteError::BadPath(m) => write!(f, "not a note path: {m}"),
            NoteError::NotFound => write!(f, "no such note"),
            NoteError::ChangedOnDisk => {
                write!(f, "the note changed on disk since it was opened")
            }
            NoteError::TooLarge(size) => {
                write!(f, "note is {size} bytes; the limit is {MAX_NOTE_BYTES}")
            }
            NoteError::Outside => write!(f, "the note resolves outside the vault"),
            NoteError::Io(m) => write!(f, "{m}"),
        }
    }
}

/// Longest vault-relative path accepted (a note path, not a filesystem path).
const MAX_REL_PATH_BYTES: usize = 1024;

/// Resolve `rel_path` under `root`, enforcing the walk's own vocabulary: a
/// relative path of ordinary components, none of them hidden, whose last one
/// is `.md`. The shape rule is what makes `..` unrepresentable — a note path
/// can only name something the walk would have listed.
fn note_path(root: &str, rel_path: &str) -> Result<std::path::PathBuf, NoteError> {
    let root_path = Path::new(root);
    if !root_path.is_absolute() || !root_path.is_dir() {
        return Err(NoteError::BadVault(root.to_string()));
    }
    if rel_path.is_empty() || rel_path.len() > MAX_REL_PATH_BYTES {
        return Err(NoteError::BadPath(rel_path.to_string()));
    }
    let rel = Path::new(rel_path);
    let mut last: Option<String> = None;
    for component in rel.components() {
        let std::path::Component::Normal(name) = component else {
            return Err(NoteError::BadPath(rel_path.to_string()));
        };
        let name = name.to_string_lossy().into_owned();
        if name.starts_with('.') {
            return Err(NoteError::BadPath(rel_path.to_string()));
        }
        last = Some(name);
    }
    let Some(last) = last else {
        return Err(NoteError::BadPath(rel_path.to_string()));
    };
    if !has_md_extension(&last) {
        return Err(NoteError::BadPath(rel_path.to_string()));
    }
    Ok(root_path.join(rel))
}

/// Load one note of a vault for the editor: the text at the display path's
/// cap, the CRLF flag, and the stamp a later save checks.
///
/// Resolution does not canonicalise: the walk lists symlinked notes, and this
/// read follows them exactly as the pane's display read does. The target must
/// be a regular file, though — a FIFO planted in a vault must not reach
/// `File::open`, which would block the GUI thread the FFI runs on.
pub fn read_vault_note(root: &str, rel_path: &str) -> Result<NoteContent, NoteError> {
    let path = note_path(root, rel_path)?;
    let meta = std::fs::metadata(&path).map_err(|_| NoteError::NotFound)?;
    if !meta.is_file() {
        return Err(NoteError::NotFound);
    }
    let (text, truncated) = read_file_capped(&path).ok_or(NoteError::NotFound)?;
    Ok(NoteContent {
        crlf: text.contains("\r\n"),
        text,
        truncated,
        stamp: NoteStamp::of(&meta),
    })
}

/// Replace one note's content, atomically.
///
/// The write is contained: the vault-relative path must satisfy the walk's
/// vocabulary, the resolved path (symlinks followed) must stay inside the
/// vault — a note symlinked to a file outside it is refused, one symlinked to
/// a sibling note is written through — and the target must be an existing
/// regular file, because this edits notes and never creates one.
///
/// `expected` is the stamp the caller loaded: a note whose (mtime, size)
/// differs is refused with [`NoteError::ChangedOnDisk`] rather than
/// overwritten, and `None` skips the check (a forced save).
///
/// The replacement is a hidden sibling temp file — random name, so a
/// concurrent walk never lists it — renamed over the target, which keeps the
/// note's own mode and cannot truncate a file it fails to rewrite.
pub fn write_vault_note(
    root: &str,
    rel_path: &str,
    content: &str,
    expected: Option<NoteStamp>,
) -> Result<NoteStamp, NoteError> {
    if content.len() as u64 > MAX_NOTE_BYTES {
        return Err(NoteError::TooLarge(content.len()));
    }
    let path = note_path(root, rel_path)?;
    let real = std::fs::canonicalize(&path).map_err(|_| NoteError::NotFound)?;
    let root_real =
        std::fs::canonicalize(root).map_err(|_| NoteError::BadVault(root.to_string()))?;
    if !real.starts_with(&root_real) {
        return Err(NoteError::Outside);
    }
    let meta = std::fs::metadata(&real).map_err(|_| NoteError::NotFound)?;
    if !meta.is_file() {
        return Err(NoteError::NotFound);
    }
    if let Some(expected) = expected
        && NoteStamp::of(&meta) != expected
    {
        return Err(NoteError::ChangedOnDisk);
    }
    let Some(dir) = real.parent() else {
        return Err(NoteError::Io(
            "the note has no parent directory".to_string(),
        ));
    };
    let tmp = dir.join(format!(".gpty-note-{:016x}.tmp", temp_suffix()));
    if let Err(e) = std::fs::write(&tmp, content) {
        let _ = std::fs::remove_file(&tmp);
        return Err(NoteError::Io(format!("writing {}: {e}", tmp.display())));
    }
    // Keep the note's own mode: the temp file was created with the process
    // umask, and a vault may be shared or deliberately readable by others.
    if let Err(e) = std::fs::set_permissions(&tmp, meta.permissions()) {
        let _ = std::fs::remove_file(&tmp);
        return Err(NoteError::Io(format!("setting the note's mode: {e}")));
    }
    if let Err(e) = std::fs::rename(&tmp, &real) {
        let _ = std::fs::remove_file(&tmp);
        return Err(NoteError::Io(format!("replacing {}: {e}", real.display())));
    }
    let meta =
        std::fs::metadata(&real).map_err(|e| NoteError::Io(format!("stamping the note: {e}")))?;
    Ok(NoteStamp::of(&meta))
}

/// 64 bits of process-local randomness for the temp name: time nanos mixed
/// with the pid and a per-process counter — the same rule the plugin store's
/// temp files follow. The name is not a secret; it only has to be
/// unpredictable to another local writer.
fn temp_suffix() -> u64 {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.subsec_nanos() as u64 | d.as_secs() << 32);
    nanos ^ (std::process::id() as u64) << 16 ^ COUNTER.fetch_add(1, Ordering::Relaxed)
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

// ── Recovery copies (the editor's unsaved buffers) ─────────────────────
//
// The editor holds its buffer in memory only — [`write_vault_note`] runs on an
// explicit save and nothing writes on teardown — so a crash, or an outside
// kill, takes whatever was typed since. These three functions are the other
// half of that design: a throttled snapshot of the buffer *outside the vault*,
// under gpty's own state directory, offered back when the same note is
// reopened, and never applied on its own.
//
// The copy is keyed by the canonical vault root and the note path, so the same
// note reached through a different spelling of the root finds its copy, and
// the record repeats that identity so a stale file (or a hash collision) can
// only answer "no copy" — never somebody else's text. Nothing here touches a
// vault: an absent copy is the normal state, and every failure is a diagnostic
// rather than a refusal the caller asked about, because no write to a note is
// at stake.

/// Longest recovery copy stored: the editor's buffer space, held to the same
/// 1 MiB the note read cuts at. A copy can only come from a note this module
/// let the editor edit, so it can never be larger than the note it copies —
/// and a buffer past that cap could not be saved either ([`write_vault_note`]
/// refuses it the same way), so refusing its copy keeps the two limits saying
/// the same thing rather than promising a recovery nothing could write back.
pub const MAX_SCRATCH_BYTES: u64 = MAX_NOTE_BYTES;

/// One note's recovery copy: the unsaved buffer, and the stamp of the file
/// revision it was typed against — so a save restored from it still checks the
/// file the user actually saw.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Scratch {
    pub text: String,
    pub stamp: NoteStamp,
}

/// Where one note's copy lives: its canonical vault root (the identity the
/// record repeats) and the file both hash to, under `dir`.
fn scratch_location(
    dir: &str,
    root: &str,
    rel_path: &str,
) -> Result<(String, std::path::PathBuf), NoteError> {
    // The walk's own vocabulary, so a copy can only belong to a note the walk
    // could have listed; the resolved path itself is unused, because nothing
    // here reads or writes the vault.
    note_path(root, rel_path)?;
    let root_real =
        std::fs::canonicalize(root).map_err(|_| NoteError::BadVault(root.to_string()))?;
    let root_key = root_real.to_string_lossy().into_owned();
    let file = Path::new(dir).join(format!("{:016x}.json", scratch_key(&root_key, rel_path)));
    Ok((root_key, file))
}

/// 64 bits of FNV-1a over the canonical root, a NUL, and the note path.
///
/// Fixed here rather than taken from `DefaultHasher`: Rust promises nothing
/// about that algorithm across releases, and a toolchain bump would silently
/// orphan every copy in the state directory.
fn scratch_key(root_key: &str, rel_path: &str) -> u64 {
    const OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
    const PRIME: u64 = 0x0000_0100_0000_01b3;
    let mut hash = OFFSET;
    let bytes = root_key
        .bytes()
        .chain(std::iter::once(0))
        .chain(rel_path.bytes());
    for byte in bytes {
        hash ^= byte as u64;
        hash = hash.wrapping_mul(PRIME);
    }
    hash
}

/// Snapshot one note's unsaved buffer under `dir`.
///
/// `stamp` is the stamp the buffer was loaded from. The write is atomic — a
/// hidden temp file under a random name, renamed over the previous copy — so an
/// interrupted write cannot truncate the copy the user may still need, and the
/// file is restricted to its owner like every store gpty writes. A write is
/// also the cleanup point ([`prune_scratch`]): the copies of vaults that went
/// away are reclaimed here, before the new copy is located, so a write refused
/// for a vault that is no longer a directory still tidies the directory.
pub fn write_scratch(
    dir: &str,
    root: &str,
    rel_path: &str,
    text: &str,
    stamp: NoteStamp,
) -> Result<(), NoteError> {
    if text.len() as u64 > MAX_SCRATCH_BYTES {
        return Err(NoteError::TooLarge(text.len()));
    }
    prune_scratch(Path::new(dir));
    let (root_key, path) = scratch_location(dir, root, rel_path)?;
    let Some(parent) = path.parent() else {
        return Err(NoteError::Io(format!(
            "the recovery copy has no directory: {}",
            path.display()
        )));
    };
    ensure_private_dir(parent)?;
    let document = serde_json::json!({
        "vault": root_key,
        "path": rel_path,
        "mtime": stamp.mtime,
        "size": stamp.size,
        "text": text,
    })
    .to_string();
    let tmp = parent.join(format!(".gpty-scratch-{:016x}.tmp", temp_suffix()));
    if let Err(e) = std::fs::write(&tmp, document) {
        let _ = std::fs::remove_file(&tmp);
        return Err(NoteError::Io(format!("writing {}: {e}", tmp.display())));
    }
    restrict_to_owner(&tmp.to_string_lossy());
    if let Err(e) = std::fs::rename(&tmp, &path) {
        let _ = std::fs::remove_file(&tmp);
        return Err(NoteError::Io(format!("replacing {}: {e}", path.display())));
    }
    Ok(())
}

/// Load one note's recovery copy, `None` when there is none.
///
/// A copy that cannot be parsed, or whose record names a different vault or
/// note, answers as absent — never as the wrong text — and is reported as a
/// diagnostic. A stamp that is missing or malformed reads as `(0, 0)`: no real
/// file's stamp equals that, so a restore into such a copy still has to pass
/// the save's own conflict check.
pub fn read_scratch(dir: &str, root: &str, rel_path: &str) -> Result<Option<Scratch>, NoteError> {
    let (root_key, path) = scratch_location(dir, root, rel_path)?;
    let bytes = match std::fs::read(&path) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => {
            log::warn!("could not read the recovery copy {}: {e}", path.display());
            return Ok(None);
        }
    };
    let Ok(document) = serde_json::from_slice::<serde_json::Value>(&bytes) else {
        log::warn!("ignoring an unreadable recovery copy at {}", path.display());
        return Ok(None);
    };
    if document.get("vault").and_then(|v| v.as_str()) != Some(root_key.as_str())
        || document.get("path").and_then(|v| v.as_str()) != Some(rel_path)
    {
        log::warn!(
            "ignoring a recovery copy that names another note: {}",
            path.display()
        );
        return Ok(None);
    }
    let Some(text) = document.get("text").and_then(|v| v.as_str()) else {
        log::warn!("ignoring a recovery copy without text: {}", path.display());
        return Ok(None);
    };
    let field = |name: &str| document.get(name).and_then(|v| v.as_i64()).unwrap_or(0);
    Ok(Some(Scratch {
        text: text.to_string(),
        stamp: NoteStamp {
            mtime: field("mtime"),
            size: field("size"),
        },
    }))
}

/// Drop one note's recovery copy. Absent is not an error: the pane clears on
/// every deliberate end (a save, a discard) and most of them have no copy to
/// clear, because nothing was typed since the last one.
pub fn clear_scratch(dir: &str, root: &str, rel_path: &str) -> Result<(), NoteError> {
    let (_, path) = scratch_location(dir, root, rel_path)?;
    match std::fs::remove_file(&path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(NoteError::Io(format!("removing {}: {e}", path.display()))),
    }
}

/// How long the remains of an interrupted copy write may sit before a prune
/// reclaims them. A live temp file exists for the microseconds between its
/// `write` and the `rename` over the previous copy, so an hour is far beyond
/// any writer's business with it — and without the check, a crash inside that
/// window would leave the file behind forever.
const STALE_SCRATCH_TEMP: std::time::Duration = std::time::Duration::from_secs(60 * 60);

/// 16 lowercase hex digits: the stem [`scratch_location`]'s `{:016x}` builds.
fn is_hex16(stem: &str) -> bool {
    stem.len() == 16
        && stem
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// Whether a name is one of this module's copy files (`<16 hex>.json`).
fn is_copy_name(name: &str) -> bool {
    name.strip_suffix(".json").is_some_and(is_hex16)
}

/// Whether a name is the temp file a copy write renames into place.
fn is_temp_name(name: &str) -> bool {
    name.strip_prefix(".gpty-scratch-")
        .and_then(|rest| rest.strip_suffix(".tmp"))
        .is_some_and(is_hex16)
}

/// Whether a temp file is old enough to be the remains of a write that died
/// rather than the property of one in flight. A file whose age cannot be
/// read is kept.
fn temp_is_stale(path: &Path) -> bool {
    path.metadata()
        .and_then(|meta| meta.modified())
        .ok()
        .and_then(|modified| modified.elapsed().ok())
        .is_some_and(|age| age > STALE_SCRATCH_TEMP)
}

/// Whether one copy's record names a vault that is definitively gone.
///
/// The record is the only authority consulted, and it is consulted whole:
/// nothing here walks a vault, so a note that merely was not listed (the walk
/// was capped, or the note is momentarily unreadable) keeps its copy — that is
/// exactly the work this feature exists to keep. A record that cannot be read,
/// parsed, or that never names a vault decides nothing.
fn copy_is_orphaned(path: &Path) -> bool {
    let Ok(bytes) = std::fs::read(path) else {
        return false;
    };
    let Ok(record) = serde_json::from_slice::<serde_json::Value>(&bytes) else {
        return false;
    };
    let Some(vault) = record.get("vault").and_then(|v| v.as_str()) else {
        return false;
    };
    // A record this module wrote names an absolute canonical root
    // (`scratch_location` canonicalizes). A relative one would be resolved
    // against whatever the process's working directory happens to be, which is
    // no verdict about a vault at all, so it decides nothing.
    if !Path::new(vault).is_absolute() {
        return false;
    }
    match std::fs::metadata(vault) {
        // Still there, and a directory: its copies stay. A vault root that
        // became a file is not a vault any more, so its copies go.
        Ok(meta) => !meta.is_dir(),
        // Absent: moved, renamed, or deleted. Every path through the API —
        // reads and offers included — resolves a canonical root first, so
        // this copy cannot be reached again.
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => true,
        // Anything else — a permission error, a network path that is not
        // mounted, an I/O error — cannot say the vault is gone, and the copy
        // of a vault that is merely hard to reach must survive.
        Err(_) => false,
    }
}

/// Remove a file a prune decided is unreachable. A file that is already gone
/// is not a failure: two writers may race the same prune.
fn remove_stale(path: &Path) {
    match std::fs::remove_file(path) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => log::warn!(
            "could not remove the stale recovery copy {}: {e}",
            path.display()
        ),
    }
}

/// Drop the recovery copies and temp remains that nothing can reach again.
///
/// [`write_scratch`] runs this on its way in — the pane's throttle is the only
/// writer, so this is one short directory listing a few times a minute at the
/// very most over a directory that holds one file per dirty note, each record
/// read to be judged — so the copies a crashed session left for a vault that
/// later moved or vanished do not accumulate forever. A pile a crash left
/// behind is read once and then gone, which is the case this exists for; a
/// steady state is one small record per open, dirty note.
///
/// What a prune may delete is deliberately narrow: a copy whose own record
/// names a vault that is gone ([`copy_is_orphaned`]), and the temp file of a
/// write that never finished ([`STALE_SCRATCH_TEMP`]). A name this module did
/// not build is never touched, and neither is a record that cannot be read or
/// made sense of — a deletion needs a record that says the copy is
/// unreachable, never one this code could not interpret. Nothing here touches
/// a vault, so no vault walk, truncated or otherwise, can ever cost a copy.
///
/// Housekeeping never fails the write it rides on: a listing or a removal that
/// fails is a diagnostic, and the copy waits for the next attempt.
fn prune_scratch(dir: &Path) {
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        // The directory is created by the first write; before that there is
        // nothing to prune.
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return,
        Err(e) => {
            log::warn!(
                "could not list the recovery copies at {}: {e}",
                dir.display()
            );
            return;
        }
    };
    // An entry the listing could not yield is left where it is: every deletion
    // below is justified by the file's own content, never by an absence from
    // this walk, so a short walk only means the copy waits for the next prune.
    for entry in entries.flatten() {
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        let unreachable = if is_copy_name(name) {
            copy_is_orphaned(&path)
        } else if is_temp_name(name) {
            temp_is_stale(&path)
        } else {
            false
        };
        if unreachable {
            remove_stale(&path);
        }
    }
}

/// Create the recovery copy's directory, owner-only.
///
/// The files inside carry the 0600 every store gets; a directory others can
/// list would still name them, and the process umask decides the mode
/// `create_dir_all` leaves behind. Best effort on the mode like
/// [`restrict_to_owner`]: a directory whose mode cannot be set is worth a log
/// line, not a lost edit.
fn ensure_private_dir(dir: &Path) -> Result<(), NoteError> {
    std::fs::create_dir_all(dir).map_err(|e| NoteError::Io(format!("{}: {e}", dir.display())))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if let Err(e) = std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700)) {
            log::warn!("could not restrict {} to its owner: {e}", dir.display());
        }
    }
    Ok(())
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
        let row = |vault_id: &str, rel: &str| NoteRow {
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

    // ── Note editing: the single-note read/write path ────────────────────

    #[test]
    fn a_vault_note_round_trips_through_read_and_write() {
        let vault = temp_vault("note_round_trip");
        write_note(&vault, "note.md", "# One\n\nbody\n");
        let root = root_str(&vault);

        let loaded = read_vault_note(&root, "note.md").unwrap();
        assert_eq!(loaded.text, "# One\n\nbody\n");
        assert!(!loaded.truncated);
        assert!(!loaded.crlf);

        let stamp = write_vault_note(&root, "note.md", "# Two\n", Some(loaded.stamp)).unwrap();
        let reread = read_vault_note(&root, "note.md").unwrap();
        assert_eq!(reread.text, "# Two\n");
        assert_eq!(
            reread.stamp, stamp,
            "the write's stamp must be the file's current one"
        );
        assert_eq!(
            scan_vault(&root).notes.len(),
            1,
            "the hidden temp file must not survive the write"
        );
    }

    #[test]
    fn a_stale_stamp_refuses_a_save_and_a_forced_one_goes_through() {
        let vault = temp_vault("note_stale");
        write_note(&vault, "note.md", "first");
        let root = root_str(&vault);
        let loaded = read_vault_note(&root, "note.md").unwrap();

        // Someone else edited the file (a different size guarantees the
        // stamp differs even on a coarse-grained filesystem).
        write_note(&vault, "note.md", "second, longer");
        let error = write_vault_note(&root, "note.md", "mine", Some(loaded.stamp)).unwrap_err();
        assert_eq!(error, NoteError::ChangedOnDisk);
        assert_eq!(error.code(), "changed_on_disk");
        assert_eq!(
            fs::read_to_string(vault.join("note.md")).unwrap(),
            "second, longer",
            "a refused save must leave the other writer's content alone"
        );

        let stamp = write_vault_note(&root, "note.md", "mine", None).unwrap();
        assert_eq!(read_vault_note(&root, "note.md").unwrap().stamp, stamp);
    }

    #[test]
    fn note_paths_must_stay_in_the_vault_vocabulary() {
        let vault = temp_vault("note_paths");
        write_note(&vault, "note.md", "x");
        let root = root_str(&vault);
        // Every path the walk could never have produced: escaping, absolute,
        // hidden at either level, or not Markdown.
        for rel in [
            "",
            "../escape.md",
            "sub/../../escape.md",
            "/etc/notes.md",
            ".hidden.md",
            "sub/.hidden.md",
            "note.txt",
            "..",
        ] {
            assert_eq!(
                read_vault_note(&root, rel).unwrap_err(),
                NoteError::BadPath(rel.to_string()),
                "the read must refuse {rel:?}"
            );
            assert_eq!(
                write_vault_note(&root, rel, "x", None).unwrap_err(),
                NoteError::BadPath(rel.to_string()),
                "the write must refuse {rel:?}"
            );
        }
        assert!(
            !std::path::Path::new(&std::env::temp_dir())
                .join("escape.md")
                .exists(),
            "no refused path may have created a file"
        );
    }

    #[test]
    fn a_write_refuses_a_directory_and_a_missing_note_and_oversized_content() {
        let vault = temp_vault("note_refuse");
        fs::create_dir_all(vault.join("dir.md")).unwrap();
        write_note(&vault, "note.md", "x");
        let root = root_str(&vault);

        assert_eq!(
            read_vault_note(&root, "dir.md").unwrap_err(),
            NoteError::NotFound,
            "a directory is not a note to read"
        );
        assert_eq!(
            write_vault_note(&root, "dir.md", "x", None).unwrap_err(),
            NoteError::NotFound
        );
        assert_eq!(
            write_vault_note(&root, "new.md", "x", None).unwrap_err(),
            NoteError::NotFound,
            "editing never creates a note"
        );

        let huge = "x".repeat(MAX_NOTE_BYTES as usize + 1);
        assert_eq!(
            write_vault_note(&root, "note.md", &huge, None).unwrap_err(),
            NoteError::TooLarge(MAX_NOTE_BYTES as usize + 1)
        );
        assert_eq!(fs::read_to_string(vault.join("note.md")).unwrap(), "x");
    }

    #[cfg(unix)]
    #[test]
    fn a_symlink_out_of_the_vault_is_written_by_neither() {
        let vault = temp_vault("note_symlink_out");
        let outside = temp_vault("note_symlink_target");
        fs::write(outside.join("secret.md"), "outside").unwrap();
        std::os::unix::fs::symlink(outside.join("secret.md"), vault.join("link.md")).unwrap();
        let root = root_str(&vault);

        assert!(
            read_vault_note(&root, "link.md").is_ok(),
            "reads follow the walk's symlink rule"
        );
        assert_eq!(
            write_vault_note(&root, "link.md", "changed", None).unwrap_err(),
            NoteError::Outside
        );
        assert_eq!(
            fs::read_to_string(outside.join("secret.md")).unwrap(),
            "outside",
            "the file the link points at must be untouched"
        );
    }

    #[cfg(unix)]
    #[test]
    fn a_symlink_inside_the_vault_is_written_through() {
        let vault = temp_vault("note_symlink_in");
        write_note(&vault, "real.md", "one");
        std::os::unix::fs::symlink("real.md", vault.join("alias.md")).unwrap();
        let root = root_str(&vault);

        let loaded = read_vault_note(&root, "alias.md").unwrap();
        assert_eq!(loaded.text, "one");
        write_vault_note(&root, "alias.md", "two", Some(loaded.stamp)).unwrap();
        assert_eq!(fs::read_to_string(vault.join("real.md")).unwrap(), "two");
        assert!(
            fs::symlink_metadata(vault.join("alias.md"))
                .unwrap()
                .file_type()
                .is_symlink(),
            "the write replaces the target, not the link"
        );
    }

    #[cfg(unix)]
    #[test]
    fn a_write_keeps_the_notes_mode() {
        use std::os::unix::fs::PermissionsExt;
        let vault = temp_vault("note_mode");
        write_note(&vault, "note.md", "x");
        let path = vault.join("note.md");
        fs::set_permissions(&path, fs::Permissions::from_mode(0o640)).unwrap();
        let root = root_str(&vault);

        let loaded = read_vault_note(&root, "note.md").unwrap();
        write_vault_note(&root, "note.md", "y", Some(loaded.stamp)).unwrap();
        let mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(
            mode, 0o640,
            "the replacement must keep the note's mode, not the umask's"
        );
    }

    fn temp_scratch(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("gpty_scratch_{tag}_{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn a_recovery_copy_round_trips_and_clears() {
        let vault = temp_vault("scratch_round_trip");
        write_note(&vault, "note.md", "one\n");
        let dir = temp_scratch("round_trip");
        let root = root_str(&vault);
        let dir = root_str(&dir);
        let stamp = NoteStamp {
            mtime: 1_700_000_000_000_000,
            size: 4,
        };

        assert_eq!(
            read_scratch(&dir, &root, "note.md").unwrap(),
            None,
            "no copy has been written yet"
        );
        write_scratch(&dir, &root, "note.md", "typed\ntext\n", stamp).unwrap();
        assert_eq!(
            read_scratch(&dir, &root, "note.md").unwrap(),
            Some(Scratch {
                text: "typed\ntext\n".to_string(),
                stamp,
            })
        );

        // A later snapshot replaces the copy rather than accumulating files.
        let later = NoteStamp {
            mtime: 1_700_000_000_000_001,
            size: 4,
        };
        write_scratch(&dir, &root, "note.md", "more\n", later).unwrap();
        assert_eq!(
            read_scratch(&dir, &root, "note.md").unwrap().unwrap().text,
            "more\n"
        );

        clear_scratch(&dir, &root, "note.md").unwrap();
        assert_eq!(read_scratch(&dir, &root, "note.md").unwrap(), None);
        // Clearing again is the common case, not an error: the pane clears on
        // every deliberate end, whether or not a copy exists.
        clear_scratch(&dir, &root, "note.md").unwrap();
    }

    #[test]
    fn a_recovery_copy_is_keyed_by_vault_and_note() {
        let vault = temp_vault("scratch_keys");
        let other_vault = temp_vault("scratch_keys_other");
        write_note(&vault, "a.md", "a");
        write_note(&vault, "b.md", "b");
        write_note(&other_vault, "a.md", "a");
        let dir = root_str(&temp_scratch("keys"));
        let root = root_str(&vault);
        let other_root = root_str(&other_vault);
        let stamp = NoteStamp { mtime: 7, size: 1 };

        write_scratch(&dir, &root, "a.md", "A", stamp).unwrap();
        write_scratch(&dir, &root, "b.md", "B", stamp).unwrap();
        write_scratch(&dir, &other_root, "a.md", "OTHER", stamp).unwrap();

        clear_scratch(&dir, &root, "a.md").unwrap();
        assert_eq!(read_scratch(&dir, &root, "a.md").unwrap(), None);
        assert_eq!(
            read_scratch(&dir, &root, "b.md").unwrap().unwrap().text,
            "B",
            "a sibling note keeps its copy"
        );
        assert_eq!(
            read_scratch(&dir, &other_root, "a.md")
                .unwrap()
                .unwrap()
                .text,
            "OTHER",
            "the same note path in another vault is another copy"
        );
    }

    #[test]
    fn a_copy_that_names_another_note_is_never_restored() {
        let vault = temp_vault("scratch_identity");
        write_note(&vault, "note.md", "x");
        let dir = root_str(&temp_scratch("identity"));
        let root = root_str(&vault);

        // The file is named by a hash, so what it *says* is the safety net:
        // a record naming another vault or note must read as absent.
        let (_, path) = scratch_location(&dir, &root, "note.md").unwrap();
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let record = |vault: &str, rel: &str, text: &str| {
            serde_json::json!({ "vault": vault, "path": rel, "mtime": 1, "size": 1, "text": text })
                .to_string()
        };
        fs::write(&path, record("/somewhere/else", "note.md", "theirs")).unwrap();
        assert_eq!(read_scratch(&dir, &root, "note.md").unwrap(), None);
        fs::write(&path, record(&root, "other.md", "theirs")).unwrap();
        assert_eq!(read_scratch(&dir, &root, "note.md").unwrap(), None);
        fs::write(&path, "not json at all").unwrap();
        assert_eq!(read_scratch(&dir, &root, "note.md").unwrap(), None);
        // A record that names the note but has no stamp must not answer with
        // a stamp that could match a file and skip the save's conflict check.
        fs::write(
            &path,
            serde_json::json!({ "vault": root, "path": "note.md", "text": "mine" }).to_string(),
        )
        .unwrap();
        assert_eq!(
            read_scratch(&dir, &root, "note.md").unwrap().unwrap().stamp,
            NoteStamp { mtime: 0, size: 0 }
        );
    }

    #[test]
    fn a_copy_can_only_belong_to_a_note_path() {
        let vault = temp_vault("scratch_paths");
        write_note(&vault, "note.md", "x");
        let dir = root_str(&temp_scratch("paths"));
        let root = root_str(&vault);
        let stamp = NoteStamp { mtime: 1, size: 1 };

        for bad in [
            "../escape.md",
            "/etc/passwd.md",
            ".hidden.md",
            "sub/.hidden/note.md",
            "note.txt",
            "",
        ] {
            assert!(
                matches!(
                    write_scratch(&dir, &root, bad, "x", stamp),
                    Err(NoteError::BadPath(_))
                ),
                "{bad:?} is not a note path and must have no copy"
            );
            assert!(matches!(
                read_scratch(&dir, &root, bad),
                Err(NoteError::BadPath(_))
            ));
            assert!(matches!(
                clear_scratch(&dir, &root, bad),
                Err(NoteError::BadPath(_))
            ));
        }
        assert!(matches!(
            write_scratch(&dir, "/no/such/vault", "note.md", "x", stamp),
            Err(NoteError::BadVault(_))
        ));
        assert!(matches!(
            write_scratch(
                &dir,
                &root,
                "note.md",
                &"x".repeat(MAX_SCRATCH_BYTES as usize + 1),
                stamp
            ),
            Err(NoteError::TooLarge(_))
        ));
    }

    #[cfg(unix)]
    #[test]
    fn the_recovery_copy_is_owner_only() {
        use std::os::unix::fs::PermissionsExt;
        let vault = temp_vault("scratch_mode");
        write_note(&vault, "note.md", "x");
        let dir = root_str(&temp_scratch("mode"));
        let root = root_str(&vault);
        write_scratch(&dir, &root, "note.md", "x", NoteStamp { mtime: 1, size: 1 }).unwrap();

        let (_, path) = scratch_location(&dir, &root, "note.md").unwrap();
        let mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "an unsaved buffer is nobody else's to read");
        let dir_mode = fs::metadata(&dir).unwrap().permissions().mode() & 0o777;
        assert_eq!(dir_mode, 0o700, "and neither are the names of the copies");
    }

    #[test]
    fn a_write_prunes_copies_of_vaults_that_are_gone() {
        let live = temp_vault("scratch_prune_live");
        let moved = temp_vault("scratch_prune_moved");
        let replaced = temp_vault("scratch_prune_replaced");
        for vault in [&live, &moved, &replaced] {
            write_note(vault, "note.md", "x");
        }
        let dir = root_str(&temp_scratch("prune"));
        let live_root = root_str(&live);
        let moved_root = root_str(&moved);
        let replaced_root = root_str(&replaced);
        let stamp = NoteStamp { mtime: 1, size: 1 };

        for root in [&live_root, &moved_root, &replaced_root] {
            write_scratch(&dir, root, "note.md", "typed", stamp).unwrap();
        }
        let (_, live_copy) = scratch_location(&dir, &live_root, "note.md").unwrap();
        let (_, moved_copy) = scratch_location(&dir, &moved_root, "note.md").unwrap();
        let (_, replaced_copy) = scratch_location(&dir, &replaced_root, "note.md").unwrap();

        // One vault is moved away, one is replaced by a file. Both orphans are
        // unreachable: every read of a copy resolves its canonical vault root
        // first, and neither root resolves any more.
        fs::remove_dir_all(&moved).unwrap();
        fs::remove_dir_all(&replaced).unwrap();
        fs::write(&replaced, "not a vault").unwrap();

        // The prune rides a write — of a note in the *live* vault, so the
        // assertion is about the walk and not about the orphan's own key.
        write_scratch(&dir, &live_root, "note.md", "still mine", stamp).unwrap();

        assert!(
            !moved_copy.exists(),
            "a copy of a vault that was moved away must be reclaimed"
        );
        assert!(
            !replaced_copy.exists(),
            "a copy of a path that is not a directory any more must be reclaimed"
        );
        assert!(live_copy.exists(), "a live vault keeps its copy");
        assert_eq!(
            read_scratch(&dir, &live_root, "note.md")
                .unwrap()
                .unwrap()
                .text,
            "still mine"
        );
    }

    #[test]
    fn a_copy_survives_its_note_leaving_the_vault() {
        let vault = temp_vault("scratch_prune_note");
        write_note(&vault, "note.md", "x");
        write_note(&vault, "other.md", "y");
        let dir = root_str(&temp_scratch("prune_note"));
        let root = root_str(&vault);
        let stamp = NoteStamp { mtime: 1, size: 1 };

        write_scratch(&dir, &root, "note.md", "typed", stamp).unwrap();
        let (_, copy) = scratch_location(&dir, &root, "note.md").unwrap();

        // The note is deleted — or the walk was capped and never listed it —
        // while its vault is still the vault it was. The copy stays: it is the
        // unsaved work this feature exists to keep, and a truncated walk must
        // never be what drops it.
        fs::remove_file(vault.join("note.md")).unwrap();
        write_scratch(&dir, &root, "other.md", "other buffer", stamp).unwrap();

        assert!(
            copy.exists(),
            "the vault exists; the note's absence is not a verdict"
        );
        assert_eq!(
            read_scratch(&dir, &root, "note.md").unwrap().unwrap().text,
            "typed"
        );
    }

    #[test]
    fn a_prune_keeps_what_it_cannot_judge() {
        let vault = temp_vault("scratch_prune_unreadable");
        write_note(&vault, "note.md", "x");
        let dir = root_str(&temp_scratch("prune_unreadable"));
        let root = root_str(&vault);
        let stamp = NoteStamp { mtime: 1, size: 1 };
        write_scratch(&dir, &root, "note.md", "typed", stamp).unwrap();

        let dir_path = Path::new(&dir);
        // A name this module did not build, an unparseable record, a record
        // that never names a vault, and one whose vault is not absolute: none
        // may be deleted, because only a record that says "unreachable"
        // authorizes a deletion.
        let foreign = dir_path.join("notes.json");
        fs::write(&foreign, r#"{"vault": "/no/such/vault"}"#).unwrap();
        let torn = dir_path.join(format!("{:016x}.json", 0xdead_beef_u64));
        fs::write(&torn, "{ not json").unwrap();
        let anonymous = dir_path.join(format!("{:016x}.json", 0xfeed_face_u64));
        fs::write(&anonymous, r#"{"path": "note.md", "text": "mine"}"#).unwrap();
        let relative = dir_path.join(format!("{:016x}.json", 0x0bad_f00d_u64));
        fs::write(&relative, r#"{"vault": "notes", "path": "note.md"}"#).unwrap();

        write_scratch(&dir, &root, "note.md", "again", stamp).unwrap();

        assert!(
            foreign.exists(),
            "a name this module did not build is not ours to delete"
        );
        assert!(torn.exists(), "an unparseable record decides nothing");
        assert!(
            anonymous.exists(),
            "a record without a vault decides nothing"
        );
        assert!(
            relative.exists(),
            "a vault named relatively resolves against nothing we can judge"
        );
    }

    #[test]
    fn a_prune_reclaims_the_remains_of_an_interrupted_write() {
        let vault = temp_vault("scratch_prune_temp");
        write_note(&vault, "note.md", "x");
        let dir = root_str(&temp_scratch("prune_temp"));
        let root = root_str(&vault);
        let stamp = NoteStamp { mtime: 1, size: 1 };

        let dir_path = Path::new(&dir);
        fs::create_dir_all(dir_path).unwrap();
        let stale = dir_path.join(format!(".gpty-scratch-{:016x}.tmp", 0xdead_beef_u64));
        let fresh = dir_path.join(format!(".gpty-scratch-{:016x}.tmp", 0xfeed_face_u64));
        fs::write(&stale, "half a copy").unwrap();
        fs::write(&fresh, "half a copy").unwrap();
        // Age the stale one past the window: a writer's temp file lives from
        // its `write` to its `rename`, and an hour is far beyond either.
        let aged =
            std::time::SystemTime::now() - STALE_SCRATCH_TEMP - std::time::Duration::from_secs(60);
        fs::File::options()
            .write(true)
            .open(&stale)
            .unwrap()
            .set_times(std::fs::FileTimes::new().set_modified(aged))
            .unwrap();

        write_scratch(&dir, &root, "note.md", "typed", stamp).unwrap();

        assert!(
            !stale.exists(),
            "a temp file nothing is going to rename is reclaimed"
        );
        assert!(
            fresh.exists(),
            "a temp file a writer may still hold is left alone"
        );
    }

    #[cfg(unix)]
    #[test]
    fn a_vault_that_cannot_be_read_keeps_its_copies() {
        use std::os::unix::fs::PermissionsExt;
        let outer = temp_vault("scratch_prune_eacces");
        let vault = outer.join("vault");
        fs::create_dir_all(&vault).unwrap();
        write_note(&vault, "note.md", "x");
        let live = temp_vault("scratch_prune_eacces_live");
        write_note(&live, "note.md", "y");
        let dir = root_str(&temp_scratch("prune_eacces"));
        let root = root_str(&vault);
        let live_root = root_str(&live);
        let stamp = NoteStamp { mtime: 1, size: 1 };

        write_scratch(&dir, &root, "note.md", "typed", stamp).unwrap();
        let (_, copy) = scratch_location(&dir, &root, "note.md").unwrap();

        // The vault still exists, but nothing can reach it: the check must
        // answer "not gone", because a vault that is temporarily unreachable —
        // an unmounted network path, a permissions problem — keeps the work a
        // crash left behind. (Running as root ignores the mode; the metadata
        // call then succeeds and the copy is kept all the same.)
        fs::set_permissions(&outer, fs::Permissions::from_mode(0o000)).unwrap();
        write_scratch(&dir, &live_root, "note.md", "live", stamp).unwrap();
        let kept = copy.exists();
        fs::set_permissions(&outer, fs::Permissions::from_mode(0o755)).unwrap();

        assert!(
            kept,
            "a vault that may exist but cannot be read keeps its copies"
        );
    }

    #[test]
    fn reading_flags_crlf_and_a_body_past_the_cap() {
        let vault = temp_vault("note_read_flags");
        write_note(&vault, "crlf.md", "# A\r\nline\r\n");
        let root = root_str(&vault);
        let loaded = read_vault_note(&root, "crlf.md").unwrap();
        assert!(
            loaded.crlf,
            "a CRLF note must be flagged so the save can put the CRLFs back"
        );
        assert_eq!(loaded.stamp.size, 11, "# A\r\nline\r\n is 11 bytes");

        let body = "y".repeat(MAX_NOTE_BYTES as usize + 64);
        write_note(&vault, "big.md", &body);
        let loaded = read_vault_note(&root, "big.md").unwrap();
        assert!(loaded.truncated, "past the cap the body is a prefix");
        assert_eq!(loaded.text.len(), MAX_NOTE_BYTES as usize);
        assert_eq!(loaded.stamp.size, body.len() as i64);
    }
}
