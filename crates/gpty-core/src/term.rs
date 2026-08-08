//! Full terminal grid via `alacritty_terminal`.
//!
//! [`TermGrid`] wraps `alacritty_terminal::Term` and provides:
//!
//! - Byte feeding through `vte::ansi::Processor` (full DEC STD 070 emulation)
//! - Grid export as a 2D array of [`CellInfo`] structs ready for Godot `_draw()`
//! - `SIGWINCH`-compatible resize
//!
//! Unlike [`crate::parser::LineParser`] (which only extracts plain text),
//! this module maintains cursor position, SGR attributes (16M colors, bold,
//! italic, underline), scrolling regions, and all VT100/VT220/xterm escape
//! sequences.

use std::sync::{Arc, Mutex};

use alacritty_terminal::event::{Event as TermEvent, EventListener};
use alacritty_terminal::grid::{Dimensions, Grid, Scroll};
use alacritty_terminal::index::{Column, Line};
use alacritty_terminal::term::cell::Cell;
use alacritty_terminal::term::cell::Flags;
use alacritty_terminal::term::Config;
use alacritty_terminal::Term;

/// Cursor shape returned by the terminal.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum CursorShape {
    Block = 0,
    Underline = 1,
    Beam = 2,
}

use crate::color::color_to_rgb;

/// A character cell ready for rendering.
#[derive(Debug, Clone)]
pub struct CellInfo {
    pub ch: char,
    pub fg: [u8; 3],
    pub bg: [u8; 3],
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    pub inverse: bool,
    pub wide: bool,
}

pub struct CellUpdate {
    pub row: usize,
    pub col: usize,
    pub cell: CellInfo,
}

pub enum GridUpdate {
    Full(Vec<Vec<CellInfo>>),
    Partial(Vec<CellUpdate>),
}

/// A simple [`Dimensions`] implementation used for creating and resizing
/// the terminal grid. alacritty_terminal does not ship a concrete size
/// type — callers provide one via the trait.
struct GridSize {
    rows: usize,
    cols: usize,
}

impl Dimensions for GridSize {
    fn total_lines(&self) -> usize {
        self.rows
    }
    fn screen_lines(&self) -> usize {
        self.rows
    }
    fn columns(&self) -> usize {
        self.cols
    }
}

/// A wrapper around `alacritty_terminal::Term` for headless grid management.
///
/// # Usage
///
/// ```ignore
/// let mut grid = TermGrid::new(24, 80);
/// grid.feed(b"Hello, \x1b[91mworld\x1b[0m!\r\n");
/// let rows = grid.renderable_rows();
/// assert_eq!(rows[0][7].ch, 'w');
/// assert_eq!(rows[0][7].fg, [255, 0, 0]); // bright red via \\x1b[91m
/// ```
/// A custom event listener that captures OSC window title sequences.
struct TitleListener {
    title: Arc<Mutex<String>>,
}

impl EventListener for TitleListener {
    fn send_event(&self, event: TermEvent) {
        if let TermEvent::Title(t) = event {
            if let Ok(mut title) = self.title.lock() {
                *title = t;
            }
        }
    }
}

pub struct TermGrid {
    term: Term<TitleListener>,
    processor: vte::ansi::Processor,
    title: Arc<Mutex<String>>,
    rows: usize,
    cols: usize,
    pub generation: u64,
    /// Set to true after calling set_palette; forces next get_grid_updates to return Full.
    pub palette_changed: bool,
    /// Tracks the display_offset last used for a Full grid render; forces Full when it changes.
    last_full_offset: usize,
    pub palette: [[u8; 3]; 16],
    /// Line counter for history storage (monotonically increasing).
    line_count: u64,
    /// Optional SQLite-backed history store for persistent scrollback.
    pub history: Option<Arc<std::sync::Mutex<crate::history::HistoryStore>>>,
}

impl TermGrid {
    /// Create a new terminal grid at the given dimensions.
    ///
    /// The cell area is `rows × cols`. The default alacritty config is
    /// used; a custom `Config` can be substituted later if needed.
    pub fn new(rows: usize, cols: usize) -> Self {
        let config = Config::default();
        let size = GridSize { rows, cols };
        let title = Arc::new(Mutex::new(String::new()));
        let listener = TitleListener { title: Arc::clone(&title) };
        let term = Term::new(config, &size, listener);
        let processor = vte::ansi::Processor::new();
        Self { term, processor, title, rows, cols, generation: 0, palette_changed: false, last_full_offset: 0, palette: crate::color::SYSTEM_COLORS, line_count: 0, history: None }

    }

    /// Feed raw PTY output bytes into the terminal state machine.
    ///
    /// This updates the internal grid (cursor position, scrolling, SGR
    /// state, etc.). Call this whenever new bytes arrive from the PTY
    /// read thread.
    pub fn feed(&mut self, bytes: &[u8]) {
        self.generation += 1;
        self.processor.advance(&mut self.term, bytes);
    }

    /// Return the full grid as row-major `Vec<Vec<CellInfo>>`.
    ///
    /// Row 0 is the **top** visible row (after accounting for scrollback).
    /// Each row has exactly `self.cols` cells. Empty cells are represented
    /// as `CellInfo { ch: ' ', fg: DEFAULT_FG, bg: DEFAULT_BG }`.
    ///
    /// This is the primary data structure passed to Godot's `_draw()`.
    pub fn renderable_rows(&self) -> Vec<Vec<CellInfo>> {
        let content = self.term.renderable_content();
        let offset = self.term.grid().display_offset() as i32;
        let mut rows: Vec<Vec<CellInfo>> =
            vec![vec![CellInfo::default(); self.cols]; self.rows];

        for indexed in content.display_iter {
            // display_iter reports negative line numbers for history rows;
            // add the display offset to shift them into 0..self.rows range
            let line = (indexed.point.line.0 + offset) as usize;
            let col = indexed.point.column.0 as usize;

            if line < self.rows && col < self.cols {
                rows[line][col] = CellInfo::from_cell(indexed.cell, &self.palette);
            }
        }

        rows
    }
    pub fn get_grid_updates(&mut self, force_full: bool) -> GridUpdate {
        let offset_changed = self.term.grid().display_offset() as usize != self.last_full_offset;
        if force_full || self.palette_changed || offset_changed {
            self.palette_changed = false;
            self.term.reset_damage();
            let rows = self.renderable_rows();
            self.last_full_offset = self.term.grid().display_offset() as usize;
            return GridUpdate::Full(rows);
        }

        let damage: Vec<_> = match self.term.damage() {
            alacritty_terminal::term::TermDamage::Full => {
                self.term.reset_damage();
                let rows = self.renderable_rows();
                self.last_full_offset = self.term.grid().display_offset() as usize;
                return GridUpdate::Full(rows);
            }
            alacritty_terminal::term::TermDamage::Partial(iter) => iter.collect(),
        };

        let mut updates = Vec::new();
        let rows = self.renderable_rows();
        for bounds in damage {
            let r = bounds.line;
            let left = bounds.left;
            let right = bounds.right;
            if r < rows.len() {
                for c in left..=right {
                    if c < rows[r].len() {
                        updates.push(CellUpdate {
                            row: r,
                            col: c,
                            cell: rows[r][c].clone(),
                        });
                    }
                }
            }
        }

        self.term.reset_damage();
        GridUpdate::Partial(updates)
    }

    /// Get a direct reference to the underlying alacritty grid.
    ///
    /// Useful for advanced operations like scrollback inspection.
    pub fn grid(&self) -> &Grid<Cell> {
        self.term.grid()
    }

    /// Resize the terminal grid (the `SIGWINCH` path).
    ///
    /// Called when the Godot `SplitContainer` changes dimensions. The
    /// underlying PTY must also be notified with `ioctl(TIOCSWINSZ)` —
    /// that is handled by [`crate::pty::PtyHandle`].
    pub fn resize(&mut self, rows: usize, cols: usize) {
        self.rows = rows;
        self.cols = cols;
        self.term.resize(GridSize { rows, cols });
        self.generation += 1;
    }

    /// Current terminal title (set via OSC escape sequences, e.g. bash prompt).
    pub fn title(&self) -> String {
        self.title.lock().map(|t| t.clone()).unwrap_or_default()
    }

    /// Current row count.
    pub fn num_rows(&self) -> usize {
        self.rows
    }

    /// Current column count.
    pub fn num_cols(&self) -> usize {
        self.cols
    }

    /// Cursor position as `(row, col)`, or `None` if the cursor is hidden
    /// or outside the visible viewport.
    pub fn cursor_position(&self) -> Option<(usize, usize)> {
        let content = self.term.renderable_content();
        let point = content.cursor.point;
        let line = point.line.0 as usize;
        let col = point.column.0 as usize;
        if line < self.rows && col < self.cols {
            Some((line, col))
        } else {
            None
        }
    }

    /// Cursor shape: 0 = Block, 1 = Underline, 2 = Beam.
    pub fn cursor_shape(&self) -> CursorShape {
        match self.term.renderable_content().cursor.shape {
            alacritty_terminal::vte::ansi::CursorShape::Block => CursorShape::Block,
            alacritty_terminal::vte::ansi::CursorShape::Underline => CursorShape::Underline,
            alacritty_terminal::vte::ansi::CursorShape::Beam => CursorShape::Beam,
            _ => CursorShape::Block,
        }
    }

    // ── Scrollback ─────────────────────────────────────────────────

    /// Current scrollback offset (0 = following output at bottom).
    pub fn display_offset(&self) -> usize {
        self.term.grid().display_offset()
    }

    /// Total lines of scrollback history stored.
    pub fn history_size(&self) -> usize {
        self.term.grid().history_size()
    }

    /// Scroll up (back in history) by `lines`.
    pub fn scroll_up(&mut self, lines: usize) {
        self.term.grid_mut().scroll_display(Scroll::Delta(lines as i32));
        self.generation += 1;
    }

    /// Scroll down (forward in history) by `lines`.
    pub fn scroll_down(&mut self, lines: usize) {
        self.term.grid_mut().scroll_display(Scroll::Delta(-(lines as i32)));
        self.generation += 1;
    }

    /// Reset scroll to follow live output (bottom).
    pub fn scroll_reset(&mut self) {
        self.term.grid_mut().scroll_display(Scroll::Bottom);
        self.generation += 1;
    }

	/// Store a completed output line in the optional SQLite history.
	pub fn store_line(&mut self, line: &str) {
		self.line_count += 1;
		if let Some(ref history) = self.history {
			if let Ok(h) = history.lock() {
				let _ = h.append(self.line_count as i64, line);
			}
		}
	}
	/// Search the full grid (scrollback + visible) for lines matching `pattern`.
	///
	/// Returns a list of `(line_idx, col)` positions. `line_idx` is 0-based
	/// from the top of scrollback history (0 = oldest history line).
	/// `col` is the byte offset of the match within the line's text.
	///
	/// Uses the standard `regex` crate — no backtracking engine, ReDoS-safe.
	pub fn search(&self, pattern: &str) -> Result<Vec<(i32, i32)>, regex::Error> {
		let re = regex::Regex::new(pattern)?;
		let grid = self.term.grid();
		let history = grid.history_size() as i32;
		let screen = grid.screen_lines() as i32;
		let mut results = Vec::new();

		// Grid uses negative Line for scrollback: Line(-history) .. Line(screen-1)
		for raw_line in -history..screen {
			let row = &grid[Line(raw_line)];
			let mut text = String::with_capacity(self.cols);
			for col in 0..self.cols {
				text.push(row[Column(col)].c);
			}
			// Trim trailing spaces — terminal lines are space-padded to width
			let trimmed_len = text.trim_end().len();
			for m in re.find_iter(&text[..trimmed_len]) {
				// Report line as 0-based from top of scrollback
				results.push(((raw_line + history) as i32, m.start() as i32));
			}
		}
		Ok(results)
	}
}

// ── CellInfo helpers ───────────────────────────────────────────────────

impl CellInfo {
    /// Default terminal foreground color (light gray).
    pub const DEFAULT_FG: [u8; 3] = [204, 204, 204];
    /// Default terminal background color (dark gray).
    pub const DEFAULT_BG: [u8; 3] = [30, 30, 30];
}

impl Default for CellInfo {
    /// Returns a default empty cell with terminal colors.
    fn default() -> Self {
        Self {
            ch: ' ',
            fg: Self::DEFAULT_FG,
            bg: Self::DEFAULT_BG,
            bold: false,
            italic: false,
            underline: false,
            inverse: false,
            wide: false,
        }
    }
}

impl CellInfo {
    /// Convert from alacritty's `Cell` type.
    ///
    /// Named colors (like "Background", "Foreground", "Red") are resolved
    /// to their approximate RGB values. True-color ANSI sequences
    /// (`\x1b[38;2;R;G;Bm`) are handled natively by `vte::ansi::Rgb`.
    pub fn from_cell(cell: &Cell, palette: &[[u8; 3]; 16]) -> Self {
        let flags = cell.flags;
        Self {
            ch: cell.c,
            fg: color_to_rgb(&cell.fg, palette),
            bg: color_to_rgb(&cell.bg, palette),
            bold: flags.contains(Flags::BOLD),
            italic: flags.contains(Flags::ITALIC),
            underline: flags.contains(Flags::UNDERLINE),
            inverse: flags.contains(Flags::INVERSE),
            wide: flags.contains(Flags::WIDE_CHAR),
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn create_grid() {
        let g = TermGrid::new(24, 80);
        assert_eq!(g.num_rows(), 24);
        assert_eq!(g.num_cols(), 80);
    }

    #[test]
    fn feed_plain_text() {
        let mut g = TermGrid::new(5, 20);
        g.feed(b"hello\r\n");
        let rows = g.renderable_rows();
        assert_eq!(rows[0][0].ch, 'h');
        assert_eq!(rows[0][4].ch, 'o');
    }

    #[test]
    fn wide_character_flag() {
        let mut g = TermGrid::new(5, 20);
        // Feed a wide emoji character (Crab)
        g.feed("🦀".as_bytes());
        let rows = g.renderable_rows();
        assert_eq!(rows[0][0].ch, '🦀');
        assert!(rows[0][0].wide, "emoji cell should have the wide flag set");
    }

    #[test]
    fn feed_ansi_colors() {
        let mut g = TermGrid::new(5, 20);
        g.feed(b"\x1b[31mRED\x1b[0m\r\n");
        let rows = g.renderable_rows();
        assert_eq!(rows[0][0].ch, 'R');
        assert_eq!(rows[0][0].fg, [205, 0, 0]);  // \x1b[31m = Red
    }

    #[test]
    fn cursor_position() {
        let mut g = TermGrid::new(5, 20);
        g.feed(b"abc");
        let pos = g.cursor_position().expect("cursor should be visible");
        assert_eq!(pos, (0, 3));
    }

    #[test]
    fn scrollback_basic() {
        let mut g = TermGrid::new(3, 10);
        g.feed(b"line1\r\nline2\r\nline3\r\nline4\r\nline5\r\n");
        let hist = g.history_size();
        assert_eq!(hist, 3, "5 lines + trailing CRLF = 3 history");
        // Before scroll, visible rows should be the last 3 lines
        let before: Vec<String> = g.renderable_rows().iter()
            .map(|r| r.iter().map(|c| c.ch).collect::<String>().trim_end().to_string())
            .collect();
        assert_eq!(before[0], "line4", "visible row 0 before scroll");
        assert_eq!(before[1], "line5", "visible row 1 before scroll");
        assert_eq!(before[2], "", "visible row 2 before scroll");
        // After scrolling up, we should see history
        g.scroll_up(2);
        let after: Vec<String> = g.renderable_rows().iter()
            .map(|r| r.iter().map(|c| c.ch).collect::<String>().trim_end().to_string())
            .collect();
        assert_eq!(after[0], "line2", "row 0 after scroll_up(2)");
        assert_eq!(after[1], "line3", "row 1 after scroll_up(2)");
        assert_eq!(after[2], "line4", "row 2 after scroll_up(2)");
        g.scroll_reset();
        assert_eq!(g.display_offset(), 0);
    }

    #[test]
    fn resize_grid() {
        let mut g = TermGrid::new(24, 80);
        g.resize(30, 100);
        assert_eq!(g.num_rows(), 30);
        assert_eq!(g.num_cols(), 100);
    }

    #[test]
    fn generation_increments_on_feed() {
        let mut g = TermGrid::new(5, 20);
        let gen_before = g.generation;
        g.feed(b"hello");
        assert_eq!(g.generation, gen_before + 1);
        g.feed(b" world");
        assert_eq!(g.generation, gen_before + 2);
    }

    #[test]
    fn generation_increments_on_resize() {
        let mut g = TermGrid::new(24, 80);
        let gen_before = g.generation;
        g.resize(30, 100);
        assert_eq!(g.generation, gen_before + 1);
    }

    #[test]
    fn generation_increments_on_scroll() {
        let mut g = TermGrid::new(5, 20);
        g.feed(b"line1\r\nline2\r\nline3\r\n");
        let gen_before = g.generation;
        g.scroll_up(1);
		assert_eq!(g.generation, gen_before + 1);
        g.scroll_down(1);
		assert_eq!(g.generation, gen_before + 2);
        g.scroll_reset();
        assert_eq!(g.generation, gen_before + 3, "scroll operations should increment generation");
    }

    #[test]
    fn title_capture() {
        let mut g = TermGrid::new(5, 20);
        g.feed(b"\x1b]0;Test Title\x07");
        assert_eq!(g.title(), "Test Title");
    }
}
