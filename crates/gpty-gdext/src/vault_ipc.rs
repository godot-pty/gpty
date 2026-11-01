//! The vault's public API over the control socket: the knowledge base's
//! search and read primitives, for agents and scripts.
//!
//! These are the same operations the wiki pane performs, reached through the
//! pane API (`gpty vault search|read`, and the `vault-search`/`vault-read` MCP
//! tools) instead of a pane. Both are answered in Rust on the blocking pool,
//! not through `ipc_handlers.gd`: a vault query is about a directory rather
//! than a workspace or a terminal, and the walk and SQLite read must not run
//! on the GUI thread — the wiki pane's own synchronous calls are user-driven
//! and bounded, while an agent may query on a timer.
//!
//! The semantics are `gpty_core::vault`'s, unchanged:
//!
//! - **Search re-indexes first.** The pass re-reads only notes whose
//!   mtime/size changed, so a note edited outside gPTY (by Obsidian, an
//!   editor, another agent) is searchable without the pane having to reopen
//!   the vault. The walk's caps bound the work (`MAX_NOTES`, `MAX_DEPTH`) and
//!   its `truncated` flag is reported: a partial index must not look complete.
//! - **Read is a read.** `read_vault_note` applies the note editor's path
//!   vocabulary (vault-relative, no hidden component, `.md`), follows a
//!   symlinked note, requires a regular file, and cuts the body at
//!   `MAX_NOTE_BYTES` with a torn UTF-8 tail dropped. Nothing is written to
//!   the vault by either method; the only write is the derived index in
//!   gPTY's own state directory.
//!
//! Failures are JSON-RPC errors: a malformed request is `-32602`, and a
//! refusal or I/O failure from the vault is `-32000` with the stable
//! `NoteError::code()` in `data.code` (the discriminator the FFI answers in
//! its documents), so a client can tell "no such note" from "bad path"
//! without parsing a message.

use std::sync::Arc;

use gpty_ipc::protocol::JsonRpcError;
use gpty_ipc::server::HandlerFn;
use serde_json::Value;

use crate::vault_api::{note_failure_is_diagnostic, vault_db_path, vault_path_problem};

/// Search results the CLI/MCP surface returns when the caller does not ask for
/// a count. Small on purpose: an agent follows a hit with a read, and the
/// answer is a JSON document over a socket.
const DEFAULT_SEARCH_LIMIT: i64 = 20;

/// Run `job` on the blocking pool, so a vault walk or an FTS query never
/// occupies the runtime's async workers or the GUI thread that polls IPC.
///
/// The handler itself is called inside `crate::RUNTIME`, so `spawn_blocking`
/// has a runtime handle to use; a panic in the job (a bug, never an expected
/// refusal) is reported as an internal error instead of wedging the request.
async fn run_blocking<F>(job: F) -> Result<Value, JsonRpcError>
where
    F: FnOnce() -> Result<Value, JsonRpcError> + Send + 'static,
{
    match tokio::task::spawn_blocking(job).await {
        Ok(result) => result,
        Err(e) => Err(JsonRpcError::new(
            JsonRpcError::INTERNAL_ERROR,
            format!("vault task failed: {e}"),
        )),
    }
}

/// The control socket's `vaultSearch` handler.
pub(crate) fn search_handler() -> HandlerFn {
    Arc::new(|params| {
        Box::pin(async move {
            let db = db_path()?;
            run_blocking(move || search_work(&db, &params)).await
        })
    })
}

/// The control socket's `vaultRead` handler.
pub(crate) fn read_handler() -> HandlerFn {
    Arc::new(|params| Box::pin(async move { run_blocking(move || read_work(&params)).await }))
}

fn db_path() -> Result<String, JsonRpcError> {
    vault_db_path().ok_or_else(|| {
        JsonRpcError::new(
            JsonRpcError::INTERNAL_ERROR,
            "no writable state directory for the vault index",
        )
    })
}

/// Parameters the vault methods read. Values arrive from the CLI's typed
/// arguments and from an MCP client, which may spell a number as a string
/// because the generated tool schema types every argument as a string — the
/// same tolerance `pane-read`'s `lines` needs.
fn string_param(params: &Value, key: &str) -> Result<String, JsonRpcError> {
    match params.get(key).and_then(Value::as_str) {
        Some(value) if !value.is_empty() => Ok(value.to_string()),
        _ => Err(JsonRpcError::new(
            JsonRpcError::INVALID_PARAMS,
            format!("`{key}` is required and must be a non-empty string"),
        )),
    }
}

fn int_param(params: &Value, key: &str, default: i64) -> i64 {
    match params.get(key) {
        Some(Value::Number(n)) => n.as_i64().unwrap_or(default),
        Some(Value::String(s)) => s.trim().parse().unwrap_or(default),
        _ => default,
    }
}

/// The vault root, held to the same rule every caller applies: an absolute
/// path that is a directory, and one the user registered. The first is a
/// malformed request (`-32602`); the second is a valid request the server
/// refuses (`-32000` with `data.code = "not_registered"`), because the caller
/// can fix it by opening the vault in a pane's settings.
///
/// Without the second check these handlers are a file-read primitive over any
/// directory a client names: a same-user process could read those files
/// anyway, but a prompt-injected agent confined to gPTY's own tools could not.
fn vault_root(params: &Value) -> Result<String, JsonRpcError> {
    let path = string_param(params, "vault_path")?;
    match vault_path_problem(&path) {
        Some(problem) => Err(JsonRpcError::new(JsonRpcError::INVALID_PARAMS, problem)),
        None if crate::vault_api::vault_root_registered(&path) => Ok(path),
        None => Err(JsonRpcError::with_data(
            JsonRpcError::SERVER_ERROR,
            format!("vault is not registered: {path} - open it in a Wiki pane's settings first"),
            serde_json::json!({ "code": "not_registered" }),
        )),
    }
}

/// Open the shared index, reporting a failure as an internal error: the
/// caller asked for a valid vault, not for a store that cannot be opened.
fn open_store(db: &str) -> Result<gpty_core::vault::VaultStore, JsonRpcError> {
    gpty_core::vault::VaultStore::open(db).map_err(|e| {
        log::warn!("vault index open failed ({db}): {e}");
        JsonRpcError::new(
            JsonRpcError::INTERNAL_ERROR,
            format!("vault index unavailable: {e}"),
        )
    })
}

fn store_error(root: &str, action: &str, error: impl std::fmt::Display) -> JsonRpcError {
    log::warn!("vault {action} failed ({root}): {error}");
    JsonRpcError::new(
        JsonRpcError::INTERNAL_ERROR,
        format!("vault {action} failed: {error}"),
    )
}

fn note_error(error: gpty_core::vault::NoteError) -> JsonRpcError {
    if note_failure_is_diagnostic(&error) {
        log::warn!("vault note read failed: {error}");
    }
    JsonRpcError::with_data(
        JsonRpcError::SERVER_ERROR,
        error.to_string(),
        serde_json::json!({ "code": error.code() }),
    )
}

/// Index the vault (changed notes only) and answer the query.
///
/// Params: `vault_path`, `pattern` (free text; the core sanitises it for
/// FTS5), optional `limit` (clamped 1..=`SEARCH_LIMIT_MAX`). Answer:
/// `{"results": [{"path", "title", "snippet"}], "total", "truncated"}`, where
/// `truncated` says the walk hit `MAX_NOTES` — the index, and therefore the
/// result set, covers only part of the vault.
fn search_work(db: &str, params: &Value) -> Result<Value, JsonRpcError> {
    let root = vault_root(params)?;
    let pattern = string_param(params, "pattern")?;
    let limit = int_param(params, "limit", DEFAULT_SEARCH_LIMIT)
        .clamp(1, gpty_core::vault::SEARCH_LIMIT_MAX as i64) as usize;

    let mut store = open_store(db)?;
    let outcome = gpty_core::vault::index_vault(&mut store, &root)
        .map_err(|e| store_error(&root, "index", e))?;
    let hits = store
        .search_user_text(&root, &pattern, limit)
        .map_err(|e| store_error(&root, "search", e))?;
    let results: Vec<Value> = hits
        .iter()
        .map(|hit| {
            serde_json::json!({
                "path": hit.rel_path,
                "title": hit.title,
                "snippet": hit.snippet,
            })
        })
        .collect();
    Ok(serde_json::json!({
        "results": results,
        "total": hits.len(),
        "truncated": outcome.truncated,
    }))
}

/// Read one vault-relative note.
///
/// Params: `vault_path`, `path`. Answer: the note document the editor's read
/// answers — `{path, text, truncated, crlf, mtime, size}` — where `truncated`
/// says the file is larger than the 1 MiB display cap.
fn read_work(params: &Value) -> Result<Value, JsonRpcError> {
    let root = vault_root(params)?;
    let rel_path = string_param(params, "path")?;
    match gpty_core::vault::read_vault_note(&root, &rel_path) {
        Ok(note) => Ok(serde_json::json!({
            "path": rel_path,
            "text": note.text,
            "truncated": note.truncated,
            "crlf": note.crlf,
            "mtime": note.stamp.mtime,
            "size": note.stamp.size,
        })),
        Err(e) => Err(note_error(e)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT: AtomicU64 = AtomicU64::new(0);

    /// A vault and its own index under one private temp directory, so tests
    /// never touch the developer's state directory or run against each other
    /// (the repo's parallel-test rule: no fixed temp paths).
    struct Fixture {
        dir: PathBuf,
    }

    impl Fixture {
        fn new() -> Self {
            Self::make(true)
        }

        /// A vault the user never registered: the handlers must refuse it.
        fn unregistered() -> Self {
            Self::make(false)
        }

        fn make(register: bool) -> Self {
            let nanos = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("clock after the epoch")
                .as_nanos();
            let dir = std::env::temp_dir().join(format!(
                "gpty-vault-ipc-{}-{nanos}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            std::fs::create_dir_all(dir.join("vault/notes")).expect("create the vault");
            let fixture = Self { dir };
            if register {
                assert!(
                    crate::vault_api::register_vault_root(&fixture.root()),
                    "the fixture's vault must register"
                );
            }
            fixture
        }

        fn vault(&self) -> PathBuf {
            self.dir.join("vault")
        }

        fn db(&self) -> String {
            self.dir.join("vaults.db").to_string_lossy().into_owned()
        }

        fn root(&self) -> String {
            self.vault().to_string_lossy().into_owned()
        }

        fn write(&self, rel_path: &str, body: &str) {
            std::fs::write(self.vault().join(rel_path), body).expect("write a note");
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.dir);
        }
    }

    fn search(fixture: &Fixture, params: Value) -> Value {
        search_work(&fixture.db(), &params).expect("search succeeds")
    }

    #[test]
    fn search_indexes_first_and_answers_paths_titles_and_snippets() {
        let fixture = Fixture::new();
        fixture.write("Alpha.md", "Rust ownership notes\n");
        fixture.write("notes/Beta.md", "Borrow checker rules\n");

        let answer = search(
            &fixture,
            serde_json::json!({"vault_path": fixture.root(), "pattern": "ownership"}),
        );
        assert_eq!(answer["total"], 1);
        assert_eq!(answer["truncated"], false);
        let hit = &answer["results"][0];
        assert_eq!(hit["path"], "Alpha.md");
        assert_eq!(hit["title"], "Alpha");
        assert!(
            hit["snippet"]
                .as_str()
                .is_some_and(|s| s.contains("[ownership]")),
            "the snippet must mark the match: {hit}"
        );

        // The index was created by the search itself; a second vault is not
        // consulted (results are keyed by the vault root).
        let other = search(
            &fixture,
            serde_json::json!({"vault_path": fixture.root(), "pattern": "checker"}),
        );
        assert_eq!(other["results"][0]["path"], "notes/Beta.md");
    }

    #[test]
    fn a_note_edited_outside_gpty_is_searchable_on_the_next_query() {
        let fixture = Fixture::new();
        fixture.write("Alpha.md", "first draft\n");
        let before = search(
            &fixture,
            serde_json::json!({"vault_path": fixture.root(), "pattern": "lifetimes"}),
        );
        assert_eq!(before["total"], 0, "the term is not there yet");

        // A different length guarantees a distinct (mtime, size) stamp even on
        // a coarse filesystem clock, so this cannot pass by accident.
        fixture.write("Alpha.md", "first draft with lifetimes spelled out\n");
        let after = search(
            &fixture,
            serde_json::json!({"vault_path": fixture.root(), "pattern": "lifetimes"}),
        );
        assert_eq!(after["total"], 1, "search must re-index before querying");
        assert_eq!(after["results"][0]["path"], "Alpha.md");
    }

    #[test]
    fn a_string_limit_is_accepted_and_clamped() {
        let fixture = Fixture::new();
        fixture.write("Alpha.md", "shared term one\n");
        fixture.write("Beta.md", "shared term two\n");
        let one = search(
            &fixture,
            serde_json::json!({
                "vault_path": fixture.root(),
                "pattern": "shared",
                "limit": "1"
            }),
        );
        assert_eq!(one["total"], 1, "a string count from MCP must still work");
        let none = search(
            &fixture,
            serde_json::json!({
                "vault_path": fixture.root(),
                "pattern": "shared",
                "limit": 0
            }),
        );
        assert_eq!(none["total"], 1, "limit 0 is clamped to 1");
    }

    #[test]
    fn read_answers_the_note_and_refuses_paths_the_walk_could_not_list() {
        let fixture = Fixture::new();
        fixture.write("notes/Beta.md", "# Beta\n\nBorrow checker rules\n");
        let read = read_work(&serde_json::json!({
            "vault_path": fixture.root(),
            "path": "notes/Beta.md"
        }))
        .expect("read succeeds");
        assert_eq!(read["path"], "notes/Beta.md");
        assert_eq!(read["text"], "# Beta\n\nBorrow checker rules\n");
        assert_eq!(read["truncated"], false);
        assert_eq!(read["crlf"], false);
        assert!(read["size"].as_i64().is_some_and(|size| size > 0));

        let escape = read_work(&serde_json::json!({
            "vault_path": fixture.root(),
            "path": "../outside.md"
        }))
        .expect_err("an escaping path is refused");
        assert_eq!(escape.code, JsonRpcError::SERVER_ERROR);
        assert_eq!(escape.data.unwrap()["code"], "bad_path");

        let missing = read_work(&serde_json::json!({
            "vault_path": fixture.root(),
            "path": "missing.md"
        }))
        .expect_err("a missing note is reported");
        assert_eq!(missing.data.unwrap()["code"], "not_found");
    }

    #[test]
    fn malformed_requests_are_invalid_params() {
        let fixture = Fixture::new();

        let relative = search_work(
            &fixture.db(),
            &serde_json::json!({"vault_path": "relative/vault", "pattern": "x"}),
        )
        .expect_err("a relative vault path is refused");
        assert_eq!(relative.code, JsonRpcError::INVALID_PARAMS);

        let no_pattern = search_work(
            &fixture.db(),
            &serde_json::json!({"vault_path": fixture.root()}),
        )
        .expect_err("a missing pattern is refused");
        assert_eq!(no_pattern.code, JsonRpcError::INVALID_PARAMS);

        let no_path = read_work(&serde_json::json!({"vault_path": fixture.root()}))
            .expect_err("a missing note path is refused");
        assert_eq!(no_path.code, JsonRpcError::INVALID_PARAMS);
    }

    /// The gate this test pins: a control-socket client may not point the
    /// vault verbs at a directory the user never registered. It is a valid
    /// request the server refuses (its own code), and registering the very
    /// same root makes the identical request answer - so the test cannot pass
    /// because the path was unusable for some other reason.
    #[test]
    fn a_vault_root_the_user_never_registered_is_refused() {
        let fixture = Fixture::unregistered();
        fixture.write("Alpha.md", "registered later\n");

        let refused = search_work(
            &fixture.db(),
            &serde_json::json!({"vault_path": fixture.root(), "pattern": "later"}),
        )
        .expect_err("an unregistered vault is refused");
        assert_eq!(refused.code, JsonRpcError::SERVER_ERROR);
        assert_eq!(
            refused.data.as_ref().expect("a stable code")["code"],
            "not_registered",
            "the refusal names the condition, not just a sentence"
        );

        let read_refused = read_work(&serde_json::json!({
            "vault_path": fixture.root(),
            "path": "Alpha.md"
        }))
        .expect_err("the read handler applies the same gate");
        assert_eq!(read_refused.code, JsonRpcError::SERVER_ERROR);

        assert!(crate::vault_api::register_vault_root(&fixture.root()));
        let answer = search(
            &fixture,
            serde_json::json!({"vault_path": fixture.root(), "pattern": "later"}),
        );
        assert_eq!(
            answer["total"], 1,
            "registration is what the refusal wanted"
        );
    }

    /// One spelling per vault: a trailing separator or a `..` detour must not
    /// slip past a registered root.
    #[test]
    fn a_registered_root_is_matched_by_canonical_spelling() {
        let fixture = Fixture::unregistered();
        fixture.write("Alpha.md", "canonical\n");
        assert!(crate::vault_api::register_vault_root(&fixture.root()));

        let detour = format!("{}/./notes/..", fixture.root());
        let answer = search(
            &fixture,
            serde_json::json!({"vault_path": detour, "pattern": "canonical"}),
        );
        assert_eq!(answer["total"], 1);
    }
}
