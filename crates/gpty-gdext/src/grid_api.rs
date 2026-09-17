//! Grid facet of `GptyTerminal`: the read surface over the live terminal grid.
//!
//! Rendering (damage-tracked packed updates), cursor and title, viewport scrolling, the
//! live-grid search, and the plain-text / recent-line reads the pane API is built on.
//!
//! Split out of `lib.rs` as a `#[godot_api(secondary)]` impl block: the class is one, and
//! only the code serving it is filed by facet, mirroring the sections of this crate's
//! README.

use crate::{GptyTerminal, RGB_SCALE};
use godot::prelude::*;

#[godot_api(secondary)]
impl GptyTerminal {
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

    /// Mouse reporting the child process has enabled, as a bitmask: bit 0
    /// click (DECSET 1000), bit 1 drag (1002), bit 2 any-motion (1003), bit 3
    /// SGR encoding (1006). Zero — the common case — means the pane owns
    /// mouse events and selection/scrollback behave as usual.
    #[func]
    fn get_mouse_mode(&self) -> i64 {
        self.with_grid(|g| g.mouse_mode() as i64, 0)
    }

    /// Whether the application asked for bracketed paste (DECSET 2004).
    ///
    /// A paste is wrapped in `ESC[200~`/`ESC[201~` when this is true; see
    /// `TerminalPane.build_paste_payload`.
    #[func]
    fn is_bracketed_paste(&self) -> bool {
        self.with_grid(|g| g.bracketed_paste(), false)
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
    /// `get_grid_updates_packed()` calls when nothing changed.
    #[func]
    fn get_grid_generation(&self) -> i64 {
        self.with_grid(|g| g.generation as i64, -1)
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
}
