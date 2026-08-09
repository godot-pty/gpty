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

use std::sync::{Arc, LazyLock};

use godot::prelude::*;

use godot::global::Key;
use gpty_core::engine::{SpawnedTerminal, WorkspaceEngine};
use gpty_core::types::TerminalConfig;

mod ipc;

// ═══════════════════════════════════════════════════════════════════════
// Constants
// ═══════════════════════════════════════════════════════════════════════

const TOKIO_WORKERS: usize = 2;
const MIN_DIM: i64 = 1;
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
    next_id: u32,
    capture_queue: Option<Arc<std::sync::Mutex<Vec<gpty_core::types::CapturedOutput>>>>,
}

#[godot_api]
impl INode2D for GptyTerminal {
    fn init(_base: Base<Node2D>) -> Self {
        Self {
            spawned: None,
            next_id: 1,
            capture_queue: None,
        }
    }
}

#[godot_api]
impl GptyTerminal {
    /// Start a shell in this terminal pane.
    ///
    /// Spawns a PTY at `rows × cols`. Call once during `_ready()`.
    ///
    /// # Edge cases
    /// - Calling twice replaces the previous session.
    /// - If spawning fails, the grid stays empty and `get_grid_rows()` returns `[]`.
    /// - `rows` and `cols` are clamped to ≥1.
    #[func]
    fn start_shell(&mut self, command: GString, rows: i64, cols: i64, envs: GString) {
        let id = self.next_id;
        self.next_id += 1;

        let config = TerminalConfig {
            id,
            labels: Vec::new(),
        };

        let rows = rows.max(MIN_DIM) as usize;
        let cols = cols.max(MIN_DIM) as usize;

        // Parse "KEY=value" lines into Vec<String>
        let env_list: Vec<String> = envs
            .to_string()
            .lines()
            .map(|l| l.trim().to_string())
            .filter(|l| !l.is_empty() && l.contains('='))
            .collect();

        godot_print!("[GDExt] Starting PTY {id}: {command} ({rows}×{cols})");

        match RUNTIME.block_on(ENGINE.spawn_terminal_with_grid(
            config,
            &command.to_string(),
            &[],
            &env_list,
            rows,
            cols,
        )) {
            Ok(spawned) => {
                // Attach SQLite history store for persistent scrollback
                if let Ok(mut grid) = spawned.grid.lock() {
                    let db_path = godot::classes::ProjectSettings::singleton()
                        .globalize_path("user://history.db")
                        .to_string();
                    match gpty_core::history::HistoryStore::open(&db_path, id) {
                        Ok(store) => {
                            grid.history = Some(Arc::new(std::sync::Mutex::new(store)));
                        }
                        Err(e) => {
                            godot_warn!("[GDExt] Could not open history store for pane {id}: {e}");
                        }
                    }
                }
                self.capture_queue = Some(Arc::clone(&spawned.capture_queue));
                self.spawned = Some(spawned);
            }
            Err(e) => {
                godot_error!("Failed to spawn PTY for '{command}': {e}");
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
    #[func]
    fn resize_grid(&mut self, rows: i64, cols: i64) {
        let rows = rows.max(MIN_DIM) as usize;
        let cols = cols.max(MIN_DIM) as usize;
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

    /// Return the grid as flat parallel arrays (no per-cell Dictionary overhead).
    /// Returns a Dictionary: rows, cols, chars (String per row), fg/bg (Color array), attrs (int array).
    #[func]
    fn get_grid_packed(&self) -> Dictionary<Variant, Variant> {
        self.with_grid(
            |g| {
                let rows = g.renderable_rows();
                let n_rows = rows.len();
                let n_cols = if n_rows > 0 { rows[0].len() } else { 0 };
                let mut chars: Array<Variant> = Array::new();
                let mut fg: Array<Variant> = Array::new();
                let mut bg: Array<Variant> = Array::new();
                let mut attrs: Array<Variant> = Array::new();
                for row in rows.iter() {
                    let mut line = String::with_capacity(n_cols);
                    for cell in row.iter() {
                        line.push(cell.ch);
                        fg.push(&Variant::from(Color::from_rgb(
                            cell.fg[0] as f32 * RGB_SCALE,
                            cell.fg[1] as f32 * RGB_SCALE,
                            cell.fg[2] as f32 * RGB_SCALE,
                        )));
                        bg.push(&Variant::from(Color::from_rgb(
                            cell.bg[0] as f32 * RGB_SCALE,
                            cell.bg[1] as f32 * RGB_SCALE,
                            cell.bg[2] as f32 * RGB_SCALE,
                        )));
                        let mut a: i64 = 0;
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
                        attrs.push(&Variant::from(a));
                    }
                    chars.push(&Variant::from(line));
                }
                let mut dict = Dictionary::<Variant, Variant>::new();
                dict.set("rows", &Variant::from(n_rows as i64));
                dict.set("cols", &Variant::from(n_cols as i64));
                dict.set("chars", &Variant::from(chars));
                dict.set("fg", &Variant::from(fg));
                dict.set("bg", &Variant::from(bg));
                dict.set("attrs", &Variant::from(attrs));
                dict
            },
            Dictionary::<Variant, Variant>::new(),
        )
    }
    /// Fetches grid updates incrementally using damage tracking.
    /// If `force_full` is true (or damage triggers a full redraw), returns `is_full = true`
    /// along with parallel arrays (`chars`, `fg`, `bg`, `attrs`) covering the entire grid.
    /// Otherwise, returns `is_full = false` along with `indices` and modified data arrays
    /// for only the cells that changed since the last frame.
    #[func]
    fn get_grid_updates(&self, force_full: bool) -> Dictionary<Variant, Variant> {
        self.with_grid_mut_ret(
            |g| {
                let updates = g.get_grid_updates(force_full);
                match updates {
                    gpty_core::term::GridUpdate::Full(rows) => {
                        let n_rows = rows.len();
                        let n_cols = if n_rows > 0 { rows[0].len() } else { 0 };
                        let mut chars: Array<Variant> = Array::new();
                        let mut fg: Array<Variant> = Array::new();
                        let mut bg: Array<Variant> = Array::new();
                        let mut attrs: Array<Variant> = Array::new();
                        for row in rows.iter() {
                            let mut line = String::with_capacity(n_cols);
                            for cell in row.iter() {
                                line.push(cell.ch);
                                fg.push(&Variant::from(Color::from_rgb(
                                    cell.fg[0] as f32 * RGB_SCALE,
                                    cell.fg[1] as f32 * RGB_SCALE,
                                    cell.fg[2] as f32 * RGB_SCALE,
                                )));
                                bg.push(&Variant::from(Color::from_rgb(
                                    cell.bg[0] as f32 * RGB_SCALE,
                                    cell.bg[1] as f32 * RGB_SCALE,
                                    cell.bg[2] as f32 * RGB_SCALE,
                                )));
                                let mut a: i64 = 0;
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
                                attrs.push(&Variant::from(a));
                            }
                            chars.push(&Variant::from(line));
                        }
                        let mut dict = Dictionary::<Variant, Variant>::new();
                        dict.set("is_full", &Variant::from(true));
                        dict.set("rows", &Variant::from(n_rows as i64));
                        dict.set("cols", &Variant::from(n_cols as i64));
                        dict.set("chars", &Variant::from(chars));
                        dict.set("fg", &Variant::from(fg));
                        dict.set("bg", &Variant::from(bg));
                        dict.set("attrs", &Variant::from(attrs));
                        dict
                    }
                    gpty_core::term::GridUpdate::Partial(cells) => {
                        let mut indices: Array<Variant> = Array::new();
                        let mut chars: Array<Variant> = Array::new();
                        let mut fg: Array<Variant> = Array::new();
                        let mut bg: Array<Variant> = Array::new();
                        let mut attrs: Array<Variant> = Array::new();
                        let cols = g.num_cols();
                        for u in cells {
                            indices.push(&Variant::from((u.row * cols + u.col) as i64));
                            chars.push(&Variant::from(u.cell.ch.to_string()));
                            fg.push(&Variant::from(Color::from_rgb(
                                u.cell.fg[0] as f32 * RGB_SCALE,
                                u.cell.fg[1] as f32 * RGB_SCALE,
                                u.cell.fg[2] as f32 * RGB_SCALE,
                            )));
                            bg.push(&Variant::from(Color::from_rgb(
                                u.cell.bg[0] as f32 * RGB_SCALE,
                                u.cell.bg[1] as f32 * RGB_SCALE,
                                u.cell.bg[2] as f32 * RGB_SCALE,
                            )));
                            let mut a: i64 = 0;
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
                            attrs.push(&Variant::from(a));
                        }
                        let mut dict = Dictionary::<Variant, Variant>::new();
                        dict.set("is_full", &Variant::from(false));
                        dict.set("indices", &Variant::from(indices));
                        dict.set("chars", &Variant::from(chars));
                        dict.set("fg", &Variant::from(fg));
                        dict.set("bg", &Variant::from(bg));
                        dict.set("attrs", &Variant::from(attrs));
                        dict
                    }
                }
            },
            Dictionary::<Variant, Variant>::new(),
        )
    }

    /// Same as `get_grid_updates` but returns PackedColorArray and PackedInt32Array
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
        match gpty_core::keymap::key_event_to_bytes(evdev, m) {
            Some(bytes) => PackedByteArray::from(bytes.as_slice()),
            None => PackedByteArray::new(),
        }
    }

    /// Replace all concepts in the global engine.
    /// `concepts_array` is an Array of Dictionaries, each with:
    ///   "name": String, "trigger": String (regex),
    ///   "enabled": bool, "capture_mode": String,
    ///   "stop_timeout_ms": int, "stop_on_input": bool,
    ///   "actions": Array[{"cmd":String,"target":String}]
    #[func]
    fn set_global_concepts(&self, concepts_array: Variant) {
        use gpty_core::types::{Action, CaptureMode, Concept};
        godot_print!("[gpty-gdext] set_global_concepts called");
        let Ok(arr) = concepts_array.try_to::<Array<Variant>>() else {
            godot_print!("[gpty-gdext] set_global_concepts: FAILED to convert variant to array");
            return;
        };
        let mut concepts = Vec::new();
        for item in arr.iter_shared() {
            let obj: Dictionary<Variant, Variant> = item.to();
            let name = obj
                .get("name")
                .and_then(|v| v.try_to::<GString>().ok())
                .map(|s| s.to_string())
                .unwrap_or_default();
            let trigger = obj
                .get("trigger")
                .and_then(|v| v.try_to::<GString>().ok())
                .map(|s| s.to_string())
                .unwrap_or_default();
            let Ok(re) = regex::Regex::new(&trigger) else {
                continue;
            };
            let enabled = obj
                .get("enabled")
                .and_then(|v| v.try_to::<bool>().ok())
                .unwrap_or(true);
            let capture_mode = obj
                .get("capture_mode")
                .and_then(|v| v.try_to::<GString>().ok())
                .map(|s| s.to_string())
                .unwrap_or_default();
            let cap_mode = if capture_mode == "until_stop" {
                let stop_ms = obj
                    .get("stop_timeout_ms")
                    .and_then(|v| v.try_to::<i64>().ok())
                    .unwrap_or(300) as u64;
                let stop_input = obj
                    .get("stop_on_input")
                    .and_then(|v| v.try_to::<bool>().ok())
                    .unwrap_or(true);
                CaptureMode::UntilStop {
                    stop_timeout_ms: stop_ms,
                    stop_on_input: stop_input,
                }
            } else {
                CaptureMode::SingleLine
            };
            let mut actions = Vec::new();
            if let Some(acts) = obj
                .get("actions")
                .and_then(|v| v.try_to::<Array<Variant>>().ok())
            {
                for a in acts.iter_shared() {
                    let ad: Dictionary<Variant, Variant> = a.to();
                    let cmd = ad
                        .get("cmd")
                        .and_then(|v| v.try_to::<GString>().ok())
                        .map(|s| s.to_string())
                        .unwrap_or_default();
                    let target = ad
                        .get("target")
                        .and_then(|v| v.try_to::<GString>().ok())
                        .map(|s| s.to_string())
                        .unwrap_or_default();
                    actions.push(Action {
                        command_template: cmd,
                        target_label: target,
                    });
                }
            }
            concepts.push(Concept {
                name,
                trigger_regex: re,
                enabled,
                capture_mode: cap_mode,
                destinations: actions,
            });
        }
        godot_print!("[gpty-gdext] Setting {} global concepts", concepts.len());
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
/// Printable ASCII keys use the Unicode code point (same in all Godot versions).
/// Special keys compare against [`godot::global::Key`] ordinals.
fn godot_key_to_evdev(kc: i64) -> u32 {
    let k = kc as u32;
    // Printable ASCII range — same values in all Godot versions
    match k {
        0x20 => return 57,                   // Space
        0x21..=0x2F => return k,             // ! " # $ % & ' ( ) * + , - . / → raw
        0x30..=0x39 => return k - 0x30 + 2,  // 0-9 → evdev 2-11
        0x3A..=0x40 => return k,             // : ; < = > ? @ → raw
        0x41..=0x5A => return k - 0x41 + 30, // A-Z → evdev 30-55
        0x5B..=0x60 => return k,             // [ \ ] ^ _ ` → raw
        0x61..=0x7A => return k - 0x61 + 30, // a-z → evdev 30-55
        0x7B..=0x7E => return k,             // { | } ~ → raw
        _ => {}
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
