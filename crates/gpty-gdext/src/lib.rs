//! Godot 4 GDExtension for gpty — bridges the Rust terminal engine
//! to Godot's rendering pipeline.
//!
//! ## Architecture
//!
//! - A **global tokio runtime** is started at extension init and shared
//!   across all terminal nodes.
//! - Each [`GptyTerminal`] node wraps a [`SpawnedTerminal`], which runs
//!   a background task feeding PTY output into a renderable grid.
//! - GDScript polls the grid in `_process()` and renders it in `_draw()`.
//! - Keyboard input flows GDScript → Rust → PTY stdin.

use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, LazyLock};

use godot::prelude::*;

use godot::global::Key;
use gpty_core::engine::{SpawnedTerminal, WorkspaceEngine};
use gpty_core::types::TerminalConfig;

mod ai;
mod ipc;
mod markdown;
mod omp_events;

// ═══════════════════════════════════════════════════════════════════════
// Constants
// ═══════════════════════════════════════════════════════════════════════

const TOKIO_WORKERS: usize = 2;
const MIN_DIM: i64 = 1;
/// Terminal ids must be unique across every pane in the process: the engine
/// compares an event's `source_pane` against each receiver's id to suppress
/// self-reaction, so a collision makes every pane look like the source and
/// silently discards every concept action. A per-instance counter gave every
/// pane id 1 — one GptyTerminal is created per pane and each is started once.
static NEXT_TERMINAL_ID: AtomicU32 = AtomicU32::new(1);
/// Maximum concept-routing labels accepted per pane (the pane id plus tags).
const MAX_LABELS: usize = 32;
const RGB_SCALE: f32 = 1.0 / 255.0;

// ═══════════════════════════════════════════════════════════════════════
// Global tokio runtime + engine
// ═══════════════════════════════════════════════════════════════════════

static RUNTIME: LazyLock<tokio::runtime::Runtime> = LazyLock::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(TOKIO_WORKERS)
        .enable_all()
        .build()
        .expect("failed to start tokio runtime")
});

static ENGINE: LazyLock<WorkspaceEngine> = LazyLock::new(|| WorkspaceEngine::new(Vec::new()));

// ═══════════════════════════════════════════════════════════════════════
// GptyTerminal — a Godot node backed by a Rust PTY session
// ═══════════════════════════════════════════════════════════════════════

#[derive(GodotClass)]
#[class(base = Node2D)]
struct GptyTerminal {
    spawned: Option<SpawnedTerminal>,
    capture_queue: Option<Arc<std::sync::Mutex<Vec<gpty_core::types::CapturedOutput>>>>,
    terminal_session_id: String,
}

#[godot_api]
impl INode2D for GptyTerminal {
    fn init(_base: Base<Node2D>) -> Self {
        Self {
            spawned: None,
            capture_queue: None,
            terminal_session_id: String::new(),
        }
    }
}

impl Drop for GptyTerminal {
    fn drop(&mut self) {
        if !self.terminal_session_id.is_empty() {
            omp_events::unregister_terminal(&self.terminal_session_id);
        }
    }
}

#[godot_api]
impl GptyTerminal {
    /// Start a shell in this terminal pane.
    ///
    /// Spawns a PTY at `rows × cols`. Call once during `_ready()`.
    ///
    /// `pane_id` is the pane's stable `attachment_id` from GDScript. It is
    /// injected as `GPTY_PANE_ID` so agents running inside the shell can
    /// identify the pane they are in. If empty, the function falls back to
    /// the per-PTY session id used for `GPTY_TERMINAL_SESSION_ID`.
    ///
    /// `history_lines` caps persisted scrollback per pane (clamped to
    /// 100..=100_000). History is keyed by the stable `attachment_id`
    /// ONLY — when `pane_id` is empty, no persistent store is attached
    /// (ephemeral session ids must never write rows that orphan across
    /// restarts). The newest `history_lines` rows are restored into the
    /// grid's scrollback on spawn.
    ///
    /// `args_json` is a JSON array of strings passed as the program's
    /// arguments (e.g. `["-c", "echo hi && exit 7"]` for shell wrapping).
    /// Capped at 32 args of ≤4096 chars each.
    ///
    /// # Edge cases
    /// - Calling twice replaces the previous session.
    /// - If spawning fails, the grid stays empty and `get_grid_rows()` returns `[]`.
    /// - `rows` and `cols` are clamped to ≥1.
    // FFI boundary: GDScript callers pass positionally; no object to group into.
    #[allow(clippy::too_many_arguments)]
    #[func]
    fn start_shell(
        &mut self,
        command: GString,
        rows: i64,
        cols: i64,
        envs: GString,
        pane_id: GString,
        history_lines: i64,
        args_json: GString,
        labels_json: GString,
    ) {
        let command = command.to_string();
        if command.is_empty() || command.len() > 1024 || command.contains('\0') {
            godot_error!("Refusing to spawn invalid shell command (empty, oversized, or NUL)");
            return;
        }
        // Saved tiles and profiles choose this program, so an absolute path
        // must not name a file another user could have written.
        if let Err(e) = gpty_core::pty::validate_executable(&command) {
            godot_error!("Refusing to spawn: {e}");
            return;
        }

        let id = NEXT_TERMINAL_ID.fetch_add(1, Ordering::Relaxed);

        if !self.terminal_session_id.is_empty() {
            omp_events::unregister_terminal(&self.terminal_session_id);
            self.terminal_session_id.clear();
        }
        omp_events::ensure_server_started();
        let event_registration = omp_events::register_terminal().ok();

        let mut trusted_envs: Vec<(String, String)> = Vec::new();

        // OMP event-channel vars — Unix-only; conditional on successful registration.
        if let Some((session_id, capability)) = &event_registration {
            trusted_envs.push((
                "GPTY_EVENT_SOCKET".to_string(),
                gpty_ipc::transport::default_event_socket_path(),
            ));
            trusted_envs.push(("GPTY_EVENT_PROTOCOL".to_string(), "1".to_string()));
            trusted_envs.push(("GPTY_TERMINAL_SESSION_ID".to_string(), session_id.clone()));
            trusted_envs.push(("GPTY_EVENT_CAPABILITY".to_string(), capability.clone()));
        }

        // Pane-marker vars: always injected as trusted runtime values so agents
        // inside the shell can prove they are running inside a gpty pane.
        // BLOCKED_ENV_KEYS prevents untrusted env (pane settings / layouts /
        // profiles) from spoofing these values.
        trusted_envs.push(("GPTY_ENV".to_string(), "1".to_string()));

        // GPTY_PANE_ID: prefer the stable attachment_id; fall back to the
        // per-PTY ephemeral session_id when no attachment_id was supplied.
        let pane_id_str = pane_id.to_string();
        // History persistence key: the stable attachment_id ONLY (see doc).
        let history_key = pane_id_str.clone();
        let pane_id_value = if !pane_id_str.is_empty() {
            pane_id_str
        } else if let Some((session_id, _)) = &event_registration {
            session_id.clone()
        } else {
            String::new()
        };
        // Labels the concept engine matches an action's `target` against: the
        // pane's stable public id plus its user tags. Without these every
        // concept action was unreachable — `matching_commands` compares the
        // action target against this list, so an empty list meant no action
        // could ever be delivered. Sanitized in GDScript; capped again here
        // because this is the FFI boundary.
        let mut labels: Vec<String> = Vec::new();
        if !pane_id_value.is_empty() {
            labels.push(pane_id_value.clone());
        }
        if let Ok(parsed) = serde_json::from_str::<Vec<String>>(&labels_json.to_string()) {
            for label in parsed {
                if label.is_empty() || label.len() > 64 || labels.len() >= MAX_LABELS {
                    continue;
                }
                if !labels.contains(&label) {
                    labels.push(label);
                }
            }
        }

        if !pane_id_value.is_empty() {
            trusted_envs.push(("GPTY_PANE_ID".to_string(), pane_id_value));
        }

        let config = TerminalConfig { id, labels };

        let rows = rows.max(MIN_DIM) as usize;
        let cols = cols.max(MIN_DIM) as usize;

        // Parse "KEY=value" lines into Vec<String> — capped so hostile
        // layout data cannot blow up the env list.
        let env_list: Vec<String> = envs
            .to_string()
            .lines()
            .map(|l| l.trim().to_string())
            .filter(|l| !l.is_empty() && l.contains('=') && l.len() <= 4096)
            .take(64)
            .collect();

        // Program arguments (JSON array) — capped like other untrusted input.
        let args: Vec<String> = serde_json::from_str::<Vec<String>>(&args_json.to_string())
            .unwrap_or_default()
            .into_iter()
            .filter(|a| !a.is_empty() && a.len() <= 4096)
            .take(32)
            .collect();
        let args_refs: Vec<&str> = args.iter().map(|a| a.as_str()).collect();

        match RUNTIME.block_on(ENGINE.spawn_terminal_with_grid(
            config,
            &command,
            &args_refs,
            &env_list,
            &trusted_envs,
            rows,
            cols,
        )) {
            Ok(spawned) => {
                // Attach the SQLite history store and restore the scrollback
                // tail. All inside one grid lock so the engine's store_line
                // cannot interleave between the line-number read and the
                // restored feed.
                if let Ok(mut grid) = spawned.grid.lock() {
                    let history_lines = history_lines.clamp(100, 100_000) as u32;
                    if !history_key.is_empty() {
                        let db_path = godot::classes::ProjectSettings::singleton()
                            .globalize_path("user://history.db")
                            .to_string();
                        match gpty_core::history::HistoryStore::open(
                            &db_path,
                            &history_key,
                            history_lines,
                        ) {
                            Ok(store) => {
                                let history = Arc::new(std::sync::Mutex::new(store));
                                let max_ln = match history.lock() {
                                    Ok(h) => match h.max_line_num() {
                                        Ok(n) => Some(n),
                                        Err(e) => {
                                            godot_warn!(
                                                "[GDExt] Could not read history for pane {history_key}: {e}"
                                            );
                                            None
                                        }
                                    },
                                    Err(_) => None,
                                };
                                if let Some(max_ln) = max_ln {
                                    let start = (max_ln - history_lines as i64).max(1);
                                    let restored: Vec<String> = history
                                        .lock()
                                        .ok()
                                        .and_then(|h| h.get_lines(start, max_ln).ok())
                                        .map(|rows| {
                                            rows.into_iter().map(|(_, text)| text).collect()
                                        })
                                        .unwrap_or_default();
                                    grid.seed_line_count(max_ln as u64);
                                    grid.feed_restore_lines(&restored);
                                }
                                grid.history = Some(history);
                            }
                            Err(e) => {
                                godot_warn!(
                                    "[GDExt] Could not open history store for pane {history_key}: {e}"
                                );
                            }
                        }
                    }
                }
                self.capture_queue = Some(Arc::clone(&spawned.capture_queue));
                self.spawned = Some(spawned);
                if let Some((session_id, _)) = event_registration {
                    self.terminal_session_id = session_id;
                }
            }
            Err(e) => {
                if let Some((session_id, _)) = event_registration {
                    omp_events::unregister_terminal(&session_id);
                }
                godot_error!("Failed to spawn PTY for '{command}': {e}");
            }
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
        let history = if let Ok(grid) = spawned.grid.lock() {
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
        let (results, stored, error) = match history.lock() {
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
        let history = if let Ok(grid) = spawned.grid.lock() {
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
        match history.lock() {
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

    /// Send raw text to the PTY — NO newline appended.
    ///
    /// Use this for interactive keyboard input. The shell's line discipline
    /// handles echo, backspace, and line buffering. For submitting a command
    /// (Enter key), use `send_line()`.
    #[func]
    fn send_text(&self, text: GString) {
        if let Some(ref spawned) = self.spawned {
            spawned.handle.send_text(&text.to_string());
        }
    }

    /// Send a complete line to the PTY (appends `\n`).
    ///
    /// Use this for the Enter key to submit a command, or for concept-triggered
    /// action commands.
    #[func]
    fn send_line(&self, text: GString) {
        if let Some(ref spawned) = self.spawned {
            spawned.handle.send_line(&text.to_string());
        }
    }

    // ── Grid access helpers ─────────────────────────────────────────

    /// Lock the grid immutably, call `f`, return its result.
    /// Returns `default` if no shell started or the mutex is poisoned.
    fn with_grid<T>(&self, f: impl FnOnce(&gpty_core::term::TermGrid) -> T, default: T) -> T {
        if let Some(ref spawned) = self.spawned {
            match spawned.grid.lock() {
                Ok(g) => f(&g),
                Err(e) => {
                    godot_error!("gpty: TermGrid lock poisoned: {e}");
                    default
                }
            }
        } else {
            default
        }
    }
    fn with_grid_mut_ret<T>(
        &self,
        f: impl FnOnce(&mut gpty_core::term::TermGrid) -> T,
        default: T,
    ) -> T {
        if let Some(ref spawned) = self.spawned {
            match spawned.grid.lock() {
                Ok(mut g) => f(&mut g),
                Err(e) => {
                    godot_error!("gpty: TermGrid lock poisoned: {e}");
                    default
                }
            }
        } else {
            default
        }
    }

    /// Lock the grid mutably and call `f`. No-op if no shell or lock poisoned.
    fn with_grid_mut(&self, f: impl FnOnce(&mut gpty_core::term::TermGrid)) {
        if let Some(ref spawned) = self.spawned {
            match spawned.grid.lock() {
                Ok(mut g) => f(&mut g),
                Err(e) => godot_error!("gpty: TermGrid lock poisoned: {e}"),
            }
        }
    }

    /// Cursor row position (0-based). Returns -1 if no shell or cursor hidden.
    #[func]
    fn get_cursor_row(&self) -> i64 {
        self.with_grid(
            |g| g.cursor_position().map(|(r, _)| r as i64).unwrap_or(-1),
            -1,
        )
    }

    /// Cursor column position (0-based). Returns -1 if no shell or cursor hidden.
    #[func]
    fn get_cursor_col(&self) -> i64 {
        self.with_grid(
            |g| g.cursor_position().map(|(_, c)| c as i64).unwrap_or(-1),
            -1,
        )
    }

    /// Cursor shape: 0 = Block, 1 = Underline, 2 = Beam.
    #[func]
    fn get_cursor_shape(&self) -> i64 {
        self.with_grid(|g| g.cursor_shape() as u8 as i64, -1)
    }

    /// Resize the terminal grid and PTY to `rows × cols`.
    /// Sends SIGWINCH to the child process so bash/zsh reflows.
    ///
    /// No-op when the grid already has these dimensions: re-sending
    /// SIGWINCH makes the shell redraw (and re-echo its input line) for
    /// nothing, which surfaces as scrollback churn during resize cascades.
    #[func]
    fn resize_grid(&mut self, rows: i64, cols: i64) {
        let rows = rows.max(MIN_DIM) as usize;
        let cols = cols.max(MIN_DIM) as usize;
        if self.with_grid(|g| g.num_rows() == rows && g.num_cols() == cols, false) {
            return;
        }
        self.with_grid_mut(|g| g.resize(rows, cols));
        if let Some(ref spawned) = self.spawned {
            spawned.handle.resize_pty(rows as u16, cols as u16);
        }
    }

    /// Terminal window title (from OSC escape sequences). Empty string if none set.
    #[func]
    fn get_title(&self) -> GString {
        self.with_grid(|g| GString::from(&g.title()), GString::new())
    }

    /// Plain-text snapshot of the pane: screen plus scrollback, oldest
    /// first, newline-joined, capped at `limit` lines (1..=2000).
    #[func]
    fn get_plain_text(&self, limit: i64) -> GString {
        self.with_grid(
            |g| {
                let joined = g.plain_text(limit.clamp(1, 2000) as usize).join("\n");
                GString::from(joined.as_str())
            },
            GString::new(),
        )
    }

    /// Process status primitives as JSON: pid, running, exit_code, idle_ms,
    /// agent_state, agent_state_tier.
    #[func]
    fn get_status(&self) -> GString {
        self.with_grid(
            |g| {
                let s = &g.status;
                let now = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_millis() as u64)
                    .unwrap_or(0);
                let idle_ms = s.last_output_unix_ms.map(|t| now.saturating_sub(t));
                let json = serde_json::json!({
                    "pid": s.pid,
                    "running": s.exit_code.is_none(),
                    "exit_code": s.exit_code,
                    "idle_ms": idle_ms,
                    "agent_state": g.agent_state.state.as_str(),
                    "agent_state_tier": g.agent_state.tier.map(|t| t as u8),
                })
                .to_string();
                GString::from(json.as_str())
            },
            GString::from("{}"),
        )
    }

    /// Display-only agent state for this terminal: idle, working,
    /// needs-attention, completed, or failed. Cheap string getter — the
    /// badge layer polls it every frame.
    #[func]
    fn get_agent_state(&self) -> GString {
        self.with_grid(
            |g| GString::from(g.agent_state.state.as_str()),
            GString::from("idle"),
        )
    }

    /// Tier 1 (authoritative) agent-state observation from a
    /// capability-authenticated event. Values outside the whitelist are
    /// ignored. Display state only — never a decision input.
    #[func]
    fn set_agent_state(&self, state: GString) {
        let Some(state) = gpty_core::agent_state::AgentState::from_declaration(&state.to_string())
        else {
            return;
        };
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0);
        self.with_grid_mut(|g| {
            g.agent_state
                .observe(gpty_core::agent_state::StateTier::Tier1, state, now);
        });
    }

    /// Newest-first scan of the recent-lines ring for `pattern` (standard
    /// Rust `regex` — ReDoS-safe, 1024-char cap). Returns the first matching
    /// line or an empty string. Backs `waitForOutput`.
    #[func]
    fn check_lines(&self, pattern: GString) -> GString {
        self.with_grid(
            |g| {
                g.first_matching_line(&pattern.to_string())
                    .map(|l| GString::from(l.as_str()))
                    .unwrap_or_default()
            },
            GString::new(),
        )
    }

    /// Fan a JSON event out to event-socket subscribers. No-op on Windows.
    #[func]
    fn emit_event(event_json: GString) {
        omp_events::emit_event(&event_json.to_string());
    }

    // ── Scrollback ──────────────────────────────────────────────────

    /// Scroll up by `lines` (back in terminal history).
    #[func]
    fn scroll_up(&mut self, lines: i64) {
        self.with_grid_mut(|g| g.scroll_up(lines.max(0) as usize));
    }

    /// Scroll down by `lines` (forward in terminal history).
    #[func]
    fn scroll_down(&mut self, lines: i64) {
        self.with_grid_mut(|g| g.scroll_down(lines.max(0) as usize));
    }

    /// Reset scroll position to follow live output.
    #[func]
    fn scroll_reset(&mut self) {
        self.with_grid_mut(|g| g.scroll_reset());
    }

    /// Current scrollback offset (lines above visible viewport).
    #[func]
    fn get_scroll_offset(&self) -> i64 {
        self.with_grid(|g| g.display_offset() as i64, 0)
    }

    /// Total lines of scrollback history available.
    #[func]
    fn get_history_size(&self) -> i64 {
        self.with_grid(|g| g.history_size() as i64, 0)
    }

    /// Number of rows in the terminal grid (0 if no shell started).
    #[func]
    fn get_rows(&self) -> i64 {
        self.with_grid(|g| g.num_rows() as i64, 0)
    }

    /// Number of columns in the terminal grid.
    #[func]
    fn get_cols(&self) -> i64 {
        self.with_grid(|g| g.num_cols() as i64, 0)
    }

    /// Monotonically increasing counter; changes every time the grid is
    /// updated. GDScript can compare to a cached value to skip redundant
    /// `get_grid_rows()` calls when nothing changed.
    #[func]
    fn get_grid_generation(&self) -> i64 {
        self.with_grid(|g| g.generation as i64, -1)
    }

    /// Load a color scheme from a comma-separated string of 16 hex colors.
    /// Example: "#002b36,#dc322f,...". Empty string resets to default.
    #[func]
    fn set_palette(&mut self, hex_csv: GString) {
        let spawned = match &self.spawned {
            Some(s) => s,
            None => return,
        };
        let mut grid = match spawned.grid.lock() {
            Ok(g) => g,
            Err(_) => return,
        };
        if hex_csv.is_empty() {
            grid.palette = gpty_core::color::SYSTEM_COLORS;
            grid.generation += 1;
            grid.palette_changed = true;
            return;
        }
        let s = hex_csv.to_string();
        let mut changed = false;
        for (i, hex) in s.split(',').enumerate().take(16) {
            let h = hex.trim();
            if h.len() == 7
                && h.starts_with('#')
                && let (Ok(r), Ok(g), Ok(b)) = (
                    u8::from_str_radix(&h[1..3], 16),
                    u8::from_str_radix(&h[3..5], 16),
                    u8::from_str_radix(&h[5..7], 16),
                )
            {
                grid.palette[i] = [r, g, b];
                changed = true;
            }
        }
        if changed {
            grid.generation += 1;
            grid.palette_changed = true;
        }
    }

    /// Grid updates as PackedColorArray and PackedInt32Array
    /// instead of generic Array, avoiding per-element Variant boxing overhead.
    /// This is the preferred path for GDScript rendering.
    #[func]
    fn get_grid_updates_packed(&self, force_full: bool) -> Dictionary<Variant, Variant> {
        self.with_grid_mut_ret(
            |g| {
                let updates = g.get_grid_updates(force_full);
                let mut dict = Dictionary::<Variant, Variant>::new();
                match updates {
                    gpty_core::term::GridUpdate::Full(rows) => {
                        let n_rows = rows.len();
                        let n_cols = if n_rows > 0 { rows[0].len() } else { 0 };
                        let mut chars: Array<Variant> = Array::new();
                        let mut fg_arr = PackedColorArray::new();
                        let mut bg_arr = PackedColorArray::new();
                        let mut attrs_arr = PackedInt32Array::new();
                        for row in rows.iter() {
                            let mut line = String::with_capacity(n_cols);
                            for cell in row.iter() {
                                line.push(cell.ch);
                                fg_arr.push(Color::from_rgb(
                                    cell.fg[0] as f32 * RGB_SCALE,
                                    cell.fg[1] as f32 * RGB_SCALE,
                                    cell.fg[2] as f32 * RGB_SCALE,
                                ));
                                bg_arr.push(Color::from_rgb(
                                    cell.bg[0] as f32 * RGB_SCALE,
                                    cell.bg[1] as f32 * RGB_SCALE,
                                    cell.bg[2] as f32 * RGB_SCALE,
                                ));
                                let mut a: i32 = 0;
                                if cell.bold {
                                    a |= 1;
                                }
                                if cell.italic {
                                    a |= 2;
                                }
                                if cell.underline {
                                    a |= 4;
                                }
                                if cell.inverse {
                                    a |= 8;
                                }
                                if cell.wide {
                                    a |= 16;
                                }
                                attrs_arr.push(a);
                            }
                            chars.push(&Variant::from(line));
                        }
                        dict.set("is_full", &Variant::from(true));
                        dict.set("rows", &Variant::from(n_rows as i64));
                        dict.set("cols", &Variant::from(n_cols as i64));
                        dict.set("chars", &Variant::from(chars));
                        dict.set("fg", &Variant::from(fg_arr));
                        dict.set("bg", &Variant::from(bg_arr));
                        dict.set("attrs", &Variant::from(attrs_arr));
                    }
                    gpty_core::term::GridUpdate::Partial(cells) => {
                        let mut indices_arr = PackedInt32Array::new();
                        let mut chars: Array<Variant> = Array::new();
                        let mut fg_arr = PackedColorArray::new();
                        let mut bg_arr = PackedColorArray::new();
                        let mut attrs_arr = PackedInt32Array::new();
                        let cols = g.num_cols();
                        for u in cells {
                            indices_arr.push((u.row * cols + u.col) as i32);
                            chars.push(&Variant::from(u.cell.ch.to_string()));
                            fg_arr.push(Color::from_rgb(
                                u.cell.fg[0] as f32 * RGB_SCALE,
                                u.cell.fg[1] as f32 * RGB_SCALE,
                                u.cell.fg[2] as f32 * RGB_SCALE,
                            ));
                            bg_arr.push(Color::from_rgb(
                                u.cell.bg[0] as f32 * RGB_SCALE,
                                u.cell.bg[1] as f32 * RGB_SCALE,
                                u.cell.bg[2] as f32 * RGB_SCALE,
                            ));
                            let mut a: i32 = 0;
                            if u.cell.bold {
                                a |= 1;
                            }
                            if u.cell.italic {
                                a |= 2;
                            }
                            if u.cell.underline {
                                a |= 4;
                            }
                            if u.cell.inverse {
                                a |= 8;
                            }
                            if u.cell.wide {
                                a |= 16;
                            }
                            attrs_arr.push(a);
                        }
                        dict.set("is_full", &Variant::from(false));
                        dict.set("indices", &Variant::from(indices_arr));
                        dict.set("chars", &Variant::from(chars));
                        dict.set("fg", &Variant::from(fg_arr));
                        dict.set("bg", &Variant::from(bg_arr));
                        dict.set("attrs", &Variant::from(attrs_arr));
                    }
                }
                dict
            },
            Dictionary::<Variant, Variant>::new(),
        )
    }

    /// Search the full grid (scrollback + visible) for `pattern`.
    ///
    /// Returns a Dictionary: `{count: int, rows: Array[int], cols: Array[int], error: String}`.
    /// `rows[i]` is the 0-based line index from top of scrollback history.
    /// `cols[i]` is the byte offset within that line.
    /// On regex error, `error` is set and `count` is 0.
    #[func]
    fn search_grid(&self, pattern: GString) -> Dictionary<Variant, Variant> {
        self.with_grid(
            |g| {
                let mut dict = Dictionary::<Variant, Variant>::new();
                match g.search(&pattern.to_string()) {
                    Ok(matches) => {
                        let mut rows: Array<Variant> = Array::new();
                        let mut cols: Array<Variant> = Array::new();
                        for (row, col) in matches {
                            rows.push(&Variant::from(row));
                            cols.push(&Variant::from(col));
                        }
                        dict.set("count", &Variant::from(rows.len() as i64));
                        dict.set("rows", &Variant::from(rows));
                        dict.set("cols", &Variant::from(cols));
                    }
                    Err(e) => {
                        dict.set("error", &Variant::from(e.to_string()));
                        dict.set("count", &Variant::from(0i64));
                    }
                }
                dict
            },
            Dictionary::<Variant, Variant>::new(),
        )
    }

    /// Convert a Godot key event to the raw PTY bytes (escape sequences for
    /// special keys, empty for unhandled keys that should use the unicode path).
    #[func]
    fn key_to_bytes(
        &self,
        keycode: i64,
        shift: bool,
        alt: bool,
        ctrl: bool,
        meta: bool,
    ) -> PackedByteArray {
        // Printable ASCII keys (letters, digits, punctuation) are handled by
        // the GDScript unicode path (`_key_to_text`). Routing them through the
        // evdev keymap fabricates scancodes that collide with special keys —
        // 'z' → 55 = KP_MULTIPLY, ';' → 59 = F1, '`' → 96 = KP_ENTER — which
        // silently swallowed those characters. Space stays in the keymap for
        // Ctrl+Space → NUL.
        if (0x21..=0x7E).contains(&(keycode as u32)) {
            return PackedByteArray::new();
        }

        let mut m: u8 = 0;
        if shift {
            m |= gpty_core::keymap::Modifiers::SHIFT;
        }
        if alt {
            m |= gpty_core::keymap::Modifiers::ALT;
        }
        if ctrl {
            m |= gpty_core::keymap::Modifiers::CTRL;
        }
        if meta {
            m |= gpty_core::keymap::Modifiers::SUPER;
        }

        // Translate Godot KEY_* constants to evdev scancodes
        let evdev = godot_key_to_evdev(keycode);
        // The numpad's byte sequence depends on whether the running
        // application enabled DECPAM; the grid tracks that mode.
        let app_keypad = self.with_grid(|g| g.is_app_keypad(), false);
        match gpty_core::keymap::key_event_to_bytes(evdev, m, app_keypad) {
            Some(bytes) => PackedByteArray::from(bytes.as_slice()),
            None => PackedByteArray::new(),
        }
    }

    /// Replace all concepts in the global engine.
    /// `concepts_json` is a JSON Array of objects, each with:
    ///   "name": String, "trigger": String (regex),
    ///   "enabled": bool, "capture_mode": String,
    ///   "stop_timeout_ms": int, "stop_on_input": bool,
    ///   "actions": Array[{"cmd":String,"target":String}]
    /// Parsing and caps (count, lengths, timeout clamp) live in
    /// `gpty_core::concept::concepts_from_json`.
    #[func]
    fn set_global_concepts(&self, concepts_json: GString) {
        let concepts = gpty_core::concept::concepts_from_json(&concepts_json.to_string());
        ENGINE.set_concepts(concepts);
    }
    /// Get all concepts as an Array of Dictionaries.
    #[func]
    fn get_global_concepts(&self) -> Array<Variant> {
        use gpty_core::types::CaptureMode;
        let concepts = ENGINE.get_concepts();
        let mut arr = Array::<Variant>::new();
        for c in &concepts {
            let mut obj = Dictionary::<Variant, Variant>::new();
            obj.set("name", &Variant::from(c.name.clone()));
            obj.set("trigger", &Variant::from(c.trigger_regex.as_str()));
            obj.set("enabled", &Variant::from(c.enabled));
            match &c.capture_mode {
                CaptureMode::SingleLine => {
                    obj.set("capture_mode", &Variant::from("single_line"));
                }
                CaptureMode::UntilStop {
                    stop_timeout_ms,
                    stop_on_input,
                } => {
                    obj.set("capture_mode", &Variant::from("until_stop"));
                    obj.set("stop_timeout_ms", &Variant::from(*stop_timeout_ms as i64));
                    obj.set("stop_on_input", &Variant::from(*stop_on_input));
                }
            }
            let mut acts = Array::<Variant>::new();
            for a in &c.destinations {
                let mut ad = Dictionary::<Variant, Variant>::new();
                ad.set("cmd", &Variant::from(a.command_template.clone()));
                ad.set("target", &Variant::from(a.target_label.clone()));
                acts.push(&Variant::from(ad));
            }
            obj.set("actions", &Variant::from(acts));
            arr.push(&Variant::from(obj));
        }
        arr
    }

    /// Match every enabled concept against `line` and return, for each
    /// matching concept, the substituted command from its first action.
    ///
    /// Returns an Array of Dictionaries `{"name": String, "cmd": String}`.
    /// `cmd` is the template with `{payload}`/`{N}` substituted and
    /// shell-quoted; it may be empty (e.g. capture-only concepts).
    /// GDScript decides whether to inject it. Uses the Rust `regex` crate
    /// only — no backtracking engine.
    #[func]
    fn match_concepts_on_line(&self, line: GString) -> Array<Variant> {
        let line = line.to_string();
        let concepts = ENGINE.get_concepts();
        let mut arr = Array::<Variant>::new();
        for c in &concepts {
            if !c.enabled {
                continue;
            }
            let Some(caps) = c.trigger_regex.captures(&line) else {
                continue;
            };
            let mut captures = Vec::with_capacity(caps.len());
            for m in caps.iter() {
                captures.push(m.map(|m| m.as_str().to_string()).unwrap_or_default());
            }
            let payload = captures.first().cloned().unwrap_or_default();
            let template = c
                .destinations
                .first()
                .map(|a| a.command_template.clone())
                .unwrap_or_default();
            let cmd = gpty_core::concept::substitute_template(&template, &payload, &captures);
            let mut obj = Dictionary::<Variant, Variant>::new();
            obj.set("name", &Variant::from(c.name.clone()));
            obj.set("cmd", &Variant::from(cmd));
            arr.push(&Variant::from(obj));
        }
        arr
    }

    /// Drain all completed capture events from this terminal's queue.
    ///
    /// Returns an Array of Dictionaries with keys:
    /// - `id` (int): capture ID for acknowledge/flush
    /// - `concept_name` (String)
    /// - `lines` (PackedStringArray): captured output lines
    /// - `target_pane_type` (String)
    #[func]
    fn drain_concept_events(&self) -> Array<Variant> {
        let mut arr = Array::<Variant>::new();
        if let Some(ref queue) = self.capture_queue
            && let Ok(mut events) = queue.lock()
        {
            for ev in events.drain(..) {
                let mut obj = Dictionary::<Variant, Variant>::new();
                obj.set("id", &Variant::from(ev.id as i64));
                obj.set("concept_name", &Variant::from(ev.concept_name));
                let lines_arr = PackedStringArray::from_iter(ev.lines.iter().map(GString::from));
                obj.set("lines", &Variant::from(lines_arr));
                obj.set("target_pane_type", &Variant::from(ev.target_pane_type));
                arr.push(&Variant::from(obj));
            }
        }
        arr
    }

    /// Acknowledge that GDScript routed a capture to a receiver.
    ///
    /// Discards the buffered raw bytes — they will NOT appear on the terminal.
    #[func]
    fn acknowledge_capture(&self, event_id: i64) {
        if let Some(ref spawned) = self.spawned {
            spawned.handle.acknowledge_capture(event_id as u64);
        }
    }

    /// Flush a capture's buffered bytes to the terminal grid.
    ///
    /// Called when no receiver pane was available — the output
    /// appears normally on the terminal.
    #[func]
    fn flush_capture(&self, event_id: i64) {
        if let Some(ref spawned) = self.spawned {
            spawned.handle.flush_capture(event_id as u64);
        }
    }

    // ── IPC bridge ────────────────────────────────────────────
    // Polled from GDScript each frame. Requests arrive via the
    // IpcServer → PENDING_REQUESTS → drain_ipc_requests.

    /// Drain pending IPC requests into an Array of Dictionaries.
    /// Returns `[{id: int, method: String, params: String}]`.
    #[func]
    fn drain_ipc_requests() -> Array<Dictionary<Variant, Variant>> {
        crate::ipc::ensure_server_started();
        let requests = crate::ipc::drain_requests();
        let mut arr = Array::new();
        for req in requests {
            let mut dict = Dictionary::new();
            dict.set("id", &Variant::from(req.id as i64));
            dict.set("method", &Variant::from(req.method));
            dict.set("params", &Variant::from(req.params));
            arr.push(&dict);
        }
        arr
    }

    /// Stable opaque identifier for the current PTY lifetime.
    #[func]
    fn get_terminal_session_id(&self) -> GString {
        GString::from(&self.terminal_session_id)
    }

    /// Return the application version baked in at compile time (CARGO_PKG_VERSION).
    ///
    /// This is a static method — call it as `GptyTerminal.get_app_version()` from
    /// GDScript. It never changes at runtime and is safe to call before any
    /// terminal is spawned.
    #[func]
    fn get_app_version() -> GString {
        GString::from(env!("CARGO_PKG_VERSION"))
    }

    /// Drain semantic events emitted by explicitly installed agent extensions.
    #[func]
    fn drain_agent_events() -> GString {
        omp_events::ensure_server_started();
        let values: Vec<serde_json::Value> = omp_events::drain_events()
            .into_iter()
            .map(|event| {
                serde_json::json!({
                    "terminal_session_id": event.terminal_session_id,
                    "omp_session_id": event.omp_session_id,
                    "seq": event.seq,
                    "event": event.event,
                })
            })
            .collect();
        GString::from(&serde_json::to_string(&values).unwrap_or_else(|_| "[]".into()))
    }

    /// Respond to an IPC request identified by `id`.
    #[func]
    fn respond_ipc(id: i64, success: bool, result_json: String) {
        crate::ipc::complete_response(id as u64, success, result_json);
    }
}

/// Map Godot `Key` enum values to Linux evdev scancodes.
///
/// Convert a Godot 4 Key ordinal to a Linux evdev scancode.
///
/// Only special keys are mapped — printable ASCII is handled by the
/// GDScript unicode path and never reaches this function (see
/// `key_to_bytes`). The exception is Space, which the keymap needs for
/// Ctrl+Space → NUL.
///
/// Special keys compare against [`godot::global::Key`] ordinals.
fn godot_key_to_evdev(kc: i64) -> u32 {
    let k = kc as u32;
    if k == 0x20 {
        return 57; // Space
    }

    // Special keys — use Godot 4 Key enum ordinals so we stay correct
    // across engine upgrades.
    if k == Key::ESCAPE.ord() as u32 {
        return 1;
    }
    if k == Key::TAB.ord() as u32 {
        return 15;
    }
    if k == Key::BACKSPACE.ord() as u32 {
        return 14;
    }
    if k == Key::ENTER.ord() as u32 {
        return 28;
    }
    if k == Key::KP_ENTER.ord() as u32 {
        return 96;
    }
    if k == Key::DELETE.ord() as u32 {
        return 111;
    }
    if k == Key::INSERT.ord() as u32 {
        return 110;
    }
    if k == Key::HOME.ord() as u32 {
        return 102;
    }
    if k == Key::END.ord() as u32 {
        return 107;
    }
    if k == Key::LEFT.ord() as u32 {
        return 105;
    }
    if k == Key::UP.ord() as u32 {
        return 103;
    }
    if k == Key::RIGHT.ord() as u32 {
        return 106;
    }
    if k == Key::DOWN.ord() as u32 {
        return 108;
    }
    if k == Key::PAGEUP.ord() as u32 {
        return 104;
    }
    if k == Key::PAGEDOWN.ord() as u32 {
        return 109;
    }
    if k == Key::PAUSE.ord() as u32 {
        return 119;
    }

    // Function keys
    if k == Key::F1.ord() as u32 {
        return 59;
    }
    if k == Key::F2.ord() as u32 {
        return 60;
    }
    if k == Key::F3.ord() as u32 {
        return 61;
    }
    if k == Key::F4.ord() as u32 {
        return 62;
    }
    if k == Key::F5.ord() as u32 {
        return 63;
    }
    if k == Key::F6.ord() as u32 {
        return 64;
    }
    if k == Key::F7.ord() as u32 {
        return 65;
    }
    if k == Key::F8.ord() as u32 {
        return 66;
    }
    if k == Key::F9.ord() as u32 {
        return 67;
    }
    if k == Key::F10.ord() as u32 {
        return 68;
    }
    if k == Key::F11.ord() as u32 {
        return 87;
    }
    if k == Key::F12.ord() as u32 {
        return 88;
    }

    // Numpad
    if k == Key::KP_MULTIPLY.ord() as u32 {
        return 55;
    }
    if k == Key::KP_DIVIDE.ord() as u32 {
        return 98;
    }
    if k == Key::KP_SUBTRACT.ord() as u32 {
        return 74;
    }
    if k == Key::KP_ADD.ord() as u32 {
        return 78;
    }
    if k == Key::KP_PERIOD.ord() as u32 {
        return 83;
    }
    if k == Key::KP_7.ord() as u32 {
        return 71;
    }
    if k == Key::KP_8.ord() as u32 {
        return 72;
    }
    if k == Key::KP_9.ord() as u32 {
        return 73;
    }
    if k == Key::KP_4.ord() as u32 {
        return 75;
    }
    if k == Key::KP_5.ord() as u32 {
        return 76;
    }
    if k == Key::KP_6.ord() as u32 {
        return 77;
    }
    if k == Key::KP_1.ord() as u32 {
        return 79;
    }
    if k == Key::KP_2.ord() as u32 {
        return 80;
    }
    if k == Key::KP_3.ord() as u32 {
        return 81;
    }
    if k == Key::KP_0.ord() as u32 {
        return 82;
    }

    // Fallback: return as-is (won't match keymap but won't crash)
    k
}

// ═══════════════════════════════════════════════════════════════════════
// Extension entry point
// ═══════════════════════════════════════════════════════════════════════

struct GptyExtension;

#[gdextension]
unsafe impl ExtensionLibrary for GptyExtension {}
