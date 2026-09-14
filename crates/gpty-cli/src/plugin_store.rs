//! `plugins.json` — the installed-plugin record store.
//!
//! One JSON file at `state_dir()/plugins.json` (Unix:
//! `$XDG_STATE_HOME/gpty`, `%LOCALAPPDATA%\gpty` on Windows), keyed by plugin
//! id. The store records *what is installed*; the content itself lives under
//! `data_dir()/plugins/<id>` and the per-plugin runtime dirs under
//! `state_dir()/plugins/<id>`.
//!
//! Writes are atomic — a random sibling temp name, mode 0600, renamed over
//! the target — mirroring `BasePersistenceManager._write_file`: an in-place
//! write truncates the target as soon as it opens, so a failure would cost
//! the entire store, and a fixed temp name would let another local writer
//! point the rename at a file of its choosing. Reads are strict: a store
//! that does not parse (or holds an entry outside the caps) is an error that
//! names the file, never a silent drop — dropping an entry would write the
//! reduced state back on the next save.

use std::fmt;
use std::path::{Path, PathBuf};

use crate::plugin_manifest::valid_plugin_id;
use gpty_ipc::transport;

/// The most plugin records the store keeps. Mirrors the manifest's own
/// concept/profile caps in spirit: the file is user-owned state, not content,
/// so this only bounds the accidental/untrusted-file case.
pub const MAX_PLUGINS: usize = 256;
/// Revisions are git commit ids — 40 hex (sha1) today, 64 for sha256 repos.
pub const MIN_REVISION_LEN: usize = 7;
pub const MAX_REVISION_LEN: usize = 64;
/// `owner/name` with both parts at the manifest's 63-char cap.
pub const MAX_ID_LEN: usize = 127;

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct PluginRecord {
    pub id: String,
    pub revision: String,
    pub enabled: bool,
    pub installed_at: u64,
}

/// A store-level failure. Never a validation of manifest *content* — that is
/// `ManifestError`'s job.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoreError(pub String);

impl StoreError {
    fn corrupt(path: &Path, what: &str) -> Self {
        Self(format!("{} is corrupt: {what}", path.display()))
    }
}

impl fmt::Display for StoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for StoreError {}

pub type StoreResult<T> = Result<T, StoreError>;

/// The on-disk record store.
pub struct PluginStore {
    path: PathBuf,
}

impl PluginStore {
    /// The store in the per-user state directory.
    pub fn open() -> StoreResult<Self> {
        let dir = transport::state_dir().ok_or_else(|| {
            StoreError(
                "no per-user state directory is available (set HOME or XDG_STATE_HOME)".into(),
            )
        })?;
        Ok(Self::at(dir.join("plugins.json")))
    }

    /// A store at an explicit path (tests).
    pub fn at(path: PathBuf) -> Self {
        Self { path }
    }

    /// All records. A missing file is an empty store; a file that does not
    /// parse, or an entry outside the caps, is an error naming the file.
    pub fn records(&self) -> StoreResult<Vec<PluginRecord>> {
        let bytes = match std::fs::read(&self.path) {
            Ok(bytes) => bytes,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(e) => return Err(StoreError(format!("{}: {e}", self.path.display()))),
        };
        let root: serde_json::Value = serde_json::from_slice(&bytes)
            .map_err(|e| StoreError::corrupt(&self.path, &e.to_string()))?;
        let entries = root
            .get("plugins")
            .and_then(|v| v.as_array())
            .ok_or_else(|| StoreError::corrupt(&self.path, "no `plugins` array"))?;
        if entries.len() > MAX_PLUGINS {
            return Err(StoreError::corrupt(
                &self.path,
                &format!("more than {MAX_PLUGINS} records"),
            ));
        }
        let mut out = Vec::with_capacity(entries.len());
        for (i, entry) in entries.iter().enumerate() {
            out.push(
                parse_record(entry).map_err(|what| {
                    StoreError::corrupt(&self.path, &format!("record {i}: {what}"))
                })?,
            );
        }
        Ok(out)
    }

    /// One record by id.
    pub fn record(&self, id: &str) -> StoreResult<Option<PluginRecord>> {
        Ok(self.records()?.into_iter().find(|record| record.id == id))
    }

    /// Install or re-install `id` at `revision`. A re-install keeps the
    /// existing `enabled` flag — a plugin the user disabled stays disabled
    /// across an upgrade — and refreshes `installed_at`.
    pub fn upsert(&self, id: &str, revision: &str) -> StoreResult<PluginRecord> {
        validate_id(id)?;
        validate_revision(revision)?;
        let mut records = self.records()?;
        if let Some(slot) = records.iter_mut().find(|record| record.id == id) {
            // A re-install keeps the existing enabled flag — a plugin the
            // user disabled stays disabled across an upgrade.
            slot.revision = revision.to_string();
            slot.installed_at = now_secs();
        } else {
            if records.len() >= MAX_PLUGINS {
                return Err(StoreError(format!(
                    "at most {MAX_PLUGINS} plugins can be installed"
                )));
            }
            records.push(PluginRecord {
                id: id.to_string(),
                revision: revision.to_string(),
                enabled: true,
                installed_at: now_secs(),
            });
        }
        self.write_records(&records)?;
        Ok(records
            .into_iter()
            .find(|record| record.id == id)
            .expect("the record was just inserted"))
    }

    /// Remove `id`'s record. Returns whether a record existed.
    pub fn remove(&self, id: &str) -> StoreResult<bool> {
        validate_id(id)?;
        let mut records = self.records()?;
        let before = records.len();
        records.retain(|record| record.id != id);
        if records.len() == before {
            return Ok(false);
        }
        self.write_records(&records)?;
        Ok(true)
    }

    /// Flip `id`'s enabled flag. `None` when the id is not installed.
    pub fn set_enabled(&self, id: &str, enabled: bool) -> StoreResult<Option<PluginRecord>> {
        validate_id(id)?;
        let mut records = self.records()?;
        let Some(slot) = records.iter_mut().find(|record| record.id == id) else {
            return Ok(None);
        };
        slot.enabled = enabled;
        self.write_records(&records)?;
        Ok(records.into_iter().find(|record| record.id == id))
    }

    /// Atomic replace: random sibling temp name, 0600, rename over the
    /// target. The name is the protection (64 random bits cannot be
    /// pre-planted), exactly like the GDScript store writer.
    fn write_records(&self, records: &[PluginRecord]) -> StoreResult<()> {
        let dir = self.path.parent().ok_or_else(|| {
            StoreError(format!("{} has no parent directory", self.path.display()))
        })?;
        std::fs::create_dir_all(dir).map_err(|e| StoreError(format!("{}: {e}", dir.display())))?;
        let payload = serde_json::json!({ "plugins": records });
        let mut bytes = serde_json::to_vec_pretty(&payload).expect("records serialize");
        bytes.push(b'\n');

        let tmp = dir.join(format!("plugins.json.tmp-{:016x}", temp_suffix()));
        let write_result = write_new_file(&tmp, &bytes);
        let result = match write_result {
            Ok(()) => std::fs::rename(&tmp, &self.path)
                .map_err(|e| StoreError(format!("{}: {e}", self.path.display()))),
            Err(e) => Err(e),
        };
        if result.is_err() {
            let _ = std::fs::remove_file(&tmp);
        }
        result
    }
}

fn parse_record(entry: &serde_json::Value) -> Result<PluginRecord, String> {
    let Some(table) = entry.as_object() else {
        return Err("not an object".into());
    };
    let known = ["id", "revision", "enabled", "installed_at"];
    for key in table.keys() {
        if !known.contains(&key.as_str()) {
            return Err(format!("unknown key `{key}`"));
        }
    }
    let id = table
        .get("id")
        .and_then(|v| v.as_str())
        .ok_or("missing string `id`")?;
    validate_id(id).map_err(|e| e.0)?;
    let revision = table
        .get("revision")
        .and_then(|v| v.as_str())
        .ok_or("missing string `revision`")?;
    validate_revision(revision).map_err(|e| e.0)?;
    let enabled = table
        .get("enabled")
        .and_then(|v| v.as_bool())
        .ok_or("missing boolean `enabled`")?;
    let installed_at = table
        .get("installed_at")
        .and_then(|v| v.as_u64())
        .ok_or("missing integer `installed_at`")?;
    Ok(PluginRecord {
        id: id.to_string(),
        revision: revision.to_string(),
        enabled,
        installed_at,
    })
}

fn validate_id(id: &str) -> StoreResult<()> {
    if valid_plugin_id(id) && id.len() <= MAX_ID_LEN {
        Ok(())
    } else {
        Err(StoreError(format!(
            "invalid plugin id `{id}` (must be `owner/name`)"
        )))
    }
}

fn validate_revision(revision: &str) -> StoreResult<()> {
    let ok = revision.len() >= MIN_REVISION_LEN
        && revision.len() <= MAX_REVISION_LEN
        && revision
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, '.' | '_' | '-'));
    if ok {
        Ok(())
    } else {
        Err(StoreError(format!(
            "invalid revision `{revision}` ({MIN_REVISION_LEN}-{MAX_REVISION_LEN} chars of [a-z0-9._-])"
        )))
    }
}

fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

/// 64 bits of process-local randomness for the temp name: time nanos mixed
/// with the pid and a per-process counter. The name only needs to be
/// unpredictable to another local writer; it is not a secret. Also names
/// the install CLI's staging dirs.
pub(crate) fn temp_suffix() -> u64 {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.subsec_nanos() as u64 | d.as_secs() << 32);
    nanos
        ^ (std::process::id() as u64) << 16
        ^ COUNTER
            .fetch_add(1, Ordering::Relaxed)
            .wrapping_mul(0x9E37_79B9_7F4A_7C15)
}

fn write_new_file(path: &Path, bytes: &[u8]) -> StoreResult<()> {
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options
        .open(path)
        .map_err(|e| StoreError(format!("{}: {e}", path.display())))?;
    use std::io::Write;
    file.write_all(bytes)
        .map_err(|e| StoreError(format!("{}: {e}", path.display())))
}

// ── Plugin directory layout ──────────────────────────────────────────
//
// Content (git checkout, pinned revision) lives under the *data* dir;
// mutable per-plugin state under the *state* dir:
//
//   data:   <data>/plugins/<id>/          — the installed content
//   state:  <state>/plugins/<id>/config/  — per-plugin config
//           <state>/plugins/<id>/state/   — per-plugin state
//           <state>/plugins/<id>/logs/    — per-plugin logs
//   store:  <state>/plugins.json          — the records
//
// Every helper validates the id before joining it into a path — ids come
// from manifests and CLI arguments, both untrusted.

/// Root holding installed plugin content (`<data>/plugins`).
pub fn content_root() -> StoreResult<PathBuf> {
    data_dir().map(|dir| dir.join("plugins"))
}

/// The installed content of one plugin.
pub fn content_dir(id: &str) -> StoreResult<PathBuf> {
    Ok(content_root()?.join(validated_id_component(id)?))
}

/// Staging area for clones that are not yet installed (`<data>/staging`).
/// Lives under the data dir so the final move is a rename on one filesystem.
pub fn staging_root() -> StoreResult<PathBuf> {
    data_dir().map(|dir| dir.join("staging"))
}

/// The per-plugin runtime directory (`<state>/plugins/<id>`).
pub fn runtime_dir(id: &str) -> StoreResult<PathBuf> {
    Ok(state_root()?.join(validated_id_component(id)?))
}

/// The per-plugin log directory (`<state>/plugins/<id>/logs`).
pub fn logs_dir(id: &str) -> StoreResult<PathBuf> {
    Ok(runtime_dir(id)?.join("logs"))
}

fn state_root() -> StoreResult<PathBuf> {
    transport::state_dir()
        .map(|dir| dir.join("plugins"))
        .ok_or_else(no_dir_error)
}

fn data_dir() -> StoreResult<PathBuf> {
    transport::data_dir().ok_or_else(no_dir_error)
}

fn no_dir_error() -> StoreError {
    StoreError("no per-user directory is available (set HOME or the XDG variables)".into())
}

fn validated_id_component(id: &str) -> StoreResult<&str> {
    validate_id(id)?;
    Ok(id)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A private directory per test — the atomicity test scans for leftover
    /// temp files, and the process-wide temp dir is shared with every other
    /// parallel test (the class the parallel cargo-test gate exists to
    /// catch).
    fn test_dir(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!("gpty-plugin-store-{}-{name}", std::process::id()))
    }

    fn make_store(name: &str) -> PluginStore {
        let dir = test_dir(name);
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        PluginStore::at(dir.join("plugins.json"))
    }

    #[test]
    fn missing_file_is_an_empty_store() {
        let store = make_store("missing");
        assert_eq!(store.records().unwrap(), Vec::new());
        assert_eq!(store.record("owner/name").unwrap(), None);
    }

    #[test]
    fn upsert_roundtrips_and_refreshes_installed_at() {
        let store = make_store("roundtrip");
        let first = store.upsert("owner/name", "abc123def456").unwrap();
        assert_eq!(first.id, "owner/name");
        assert_eq!(first.revision, "abc123def456");
        assert!(first.enabled);

        // An upgrade keeps the enabled flag and changes the revision.
        store.set_enabled("owner/name", false).unwrap();
        let upgraded = store.upsert("owner/name", "fedcba987654").unwrap();
        assert_eq!(upgraded.revision, "fedcba987654");
        assert!(!upgraded.enabled, "an upgrade must not re-enable");

        let records = store.records().unwrap();
        assert_eq!(records.len(), 1);
        assert_eq!(records[0], upgraded);
    }

    #[test]
    fn remove_deletes_only_the_named_record() {
        let store = make_store("remove");
        store.upsert("owner/a", "aaaaaaa").unwrap();
        store.upsert("owner/b", "bbbbbbb").unwrap();
        assert!(store.remove("owner/a").unwrap());
        assert!(!store.remove("owner/a").unwrap());
        let ids: Vec<_> = store
            .records()
            .unwrap()
            .into_iter()
            .map(|record| record.id)
            .collect();
        assert_eq!(ids, vec!["owner/b".to_string()]);
    }

    #[test]
    fn set_enabled_reports_unknown_ids() {
        let store = make_store("enable");
        assert_eq!(store.set_enabled("owner/x", true).unwrap(), None);
        store.upsert("owner/x", "aaaaaaa").unwrap();
        let record = store.set_enabled("owner/x", false).unwrap().unwrap();
        assert!(!record.enabled);
    }

    #[test]
    fn ids_are_validated_before_any_write() {
        let store = make_store("bad-id");
        // A path separator in an id must never reach a path join.
        assert!(store.upsert("owner/../etc", "aaaaaaa").is_err());
        assert!(store.upsert("Owner/UPPER", "aaaaaaa").is_err());
        assert!(store.upsert("nohyphen", "aaaaaaa").is_err());
        assert!(store.remove("owner/../etc").is_err());
        assert!(store.set_enabled("../../x", true).is_err());
        assert_eq!(store.records().unwrap(), Vec::new());
    }

    #[test]
    fn revisions_are_validated() {
        let store = make_store("bad-rev");
        assert!(store.upsert("owner/x", "short").is_err());
        assert!(store.upsert("owner/x", "has a space in it").is_err());
        let long = "a".repeat(MAX_REVISION_LEN + 1);
        assert!(store.upsert("owner/x", &long).is_err());
        assert_eq!(store.records().unwrap(), Vec::new());
    }

    #[test]
    fn corrupt_json_is_an_error_not_a_drop() {
        let store = make_store("corrupt");
        std::fs::write(&store.path, "{not json").unwrap();
        let err = store.records().unwrap_err();
        assert!(err.0.contains("corrupt"), "error names the file: {err}");
        // A corrupt store must not be silently overwritten by a later op.
        assert!(store.upsert("owner/x", "aaaaaaa").is_err());
    }

    #[test]
    fn wrong_shaped_entry_is_an_error() {
        let store = make_store("shape");
        std::fs::write(
            &store.path,
            r#"{"plugins": [{"id": "owner/x", "revision": "aaaaaaa", "enabled": "yes", "installed_at": 1}]}"#,
        )
        .unwrap();
        assert!(store.records().unwrap_err().0.contains("missing boolean"));
    }

    #[test]
    fn cap_on_record_count() {
        let store = make_store("cap");
        let mut records = Vec::new();
        for i in 0..=MAX_PLUGINS {
            records.push(serde_json::json!({
                "id": format!("owner/p{i}"),
                "revision": "aaaaaaa",
                "enabled": true,
                "installed_at": 1,
            }));
        }
        std::fs::write(
            &store.path,
            serde_json::to_vec(&serde_json::json!({"plugins": records})).unwrap(),
        )
        .unwrap();
        assert!(store.records().unwrap_err().0.contains("more than"));
        // The write side enforces the same cap.
        let write_store = make_store("cap-write");
        for i in 0..MAX_PLUGINS {
            write_store
                .upsert(&format!("owner/p{i}"), "aaaaaaa")
                .unwrap();
        }
        assert!(write_store.upsert("owner/overflow", "aaaaaaa").is_err());
    }

    #[test]
    fn writes_are_atomic_and_leave_no_temp_files() {
        let store = make_store("atomic");
        store.upsert("owner/x", "aaaaaaa").unwrap();
        let dir = store.path.parent().unwrap().to_path_buf();
        let leftovers: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .filter(|name| name.to_string_lossy().contains(".tmp-"))
            .collect();
        assert!(
            leftovers.is_empty(),
            "temp files left behind: {leftovers:?}"
        );
        // A second write replaces the target, not the temp name.
        store.upsert("owner/y", "bbbbbbb").unwrap();
        assert_eq!(store.records().unwrap().len(), 2);
    }

    #[cfg(unix)]
    #[test]
    fn store_file_is_private() {
        use std::os::unix::fs::PermissionsExt;
        let store = make_store("mode");
        store.upsert("owner/x", "aaaaaaa").unwrap();
        let mode = std::fs::metadata(store.path).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600, "the store holds install records");
    }

    #[test]
    fn dir_helpers_refuse_path_traversal() {
        assert!(content_dir("owner/../x").is_err());
        assert!(logs_dir("a/b/c").is_err());
        assert!(runtime_dir("noslash").is_err());
    }
}
