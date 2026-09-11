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

use alacritty_terminal::Term;
use alacritty_terminal::event::{Event as TermEvent, EventListener};
use alacritty_terminal::grid::{Dimensions, Grid, Scroll};
use alacritty_terminal::index::{Column, Line};
use alacritty_terminal::term::Config;
use alacritty_terminal::term::cell::Cell;
use alacritty_terminal::term::cell::Flags;

/// Cursor shape returned by the terminal.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum CursorShape {
    Block = 0,
    Underline = 1,
    Beam = 2,
}

/// Mouse-tracking bits returned by [`TermGrid::mouse_mode`]. The values are
/// part of the FFI contract with the pane's `MOUSE_MODE_*` constants: the UI
/// both checks them and encodes the bytes it forwards from them.
pub const MOUSE_MODE_CLICK: u8 = 1;
pub const MOUSE_MODE_DRAG: u8 = 2;
pub const MOUSE_MODE_MOTION: u8 = 4;
pub const MOUSE_MODE_SGR: u8 = 8;

use crate::color::color_to_rgb;
use crate::lock::lock_or_warn;

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
/// Terminal event proxy: captures OSC window titles and forwards PTY
/// replies (cursor-position reports, mode reports) to the engine so they
/// reach the child process. Dropping them breaks TUIs that query the
/// terminal after SIGWINCH (e.g. the OMP TUI's cursor-position request).
struct TitleListener {
    title: Arc<Mutex<String>>,
    replies: Arc<Mutex<std::collections::VecDeque<Vec<u8>>>>,
}

impl EventListener for TitleListener {
    fn send_event(&self, event: TermEvent) {
        match event {
            TermEvent::Title(t) => {
                if let Some(mut title) = lock_or_warn(&self.title, "terminal title") {
                    *title = t;
                }
            }
            TermEvent::PtyWrite(text) => {
                if let Some(mut replies) = lock_or_warn(&self.replies, "terminal replies") {
                    replies.push_back(text.into_bytes());
                }
            }
            _ => {}
        }
    }
}
/// Process status primitives for the terminal, updated by the engine task
/// and read by the gdext bridge. Display-oriented; never a decision input.
#[derive(Debug, Clone, Copy, Default)]
pub struct TermStatus {
    pub pid: Option<u32>,
    pub exit_code: Option<i32>,
    pub last_output_unix_ms: Option<u64>,
    pub started_unix_ms: u64,
}

pub struct TermGrid {
    term: Term<TitleListener>,
    processor: vte::ansi::Processor,
    title: Arc<Mutex<String>>,
    /// Bytes the terminal emulator generated as replies to application
    /// queries (DSR cursor position, mode reports). The engine drains
    /// these and writes them to the PTY.
    replies: Arc<Mutex<std::collections::VecDeque<Vec<u8>>>>,
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
    /// Optional persistent scrollback for this pane: the SQLite store (read
    /// paths) plus the writer thread that commits queued lines.
    pub history: Option<Arc<crate::history::PaneHistory>>,
    /// Process/liveness primitives written by the engine task.
    pub status: TermStatus,
    /// Tiered agent-state tracker (display only) written by the engine
    /// task from OSC declarations and heuristics, and by the gdext bridge
    /// from capability-authenticated events.
    pub agent_state: crate::agent_state::AgentStateTracker,
    /// Bounded ring of recent committed plain-text lines (newest last).
    /// Backs `waitForOutput`.
    pub recent_lines: std::collections::VecDeque<String>,
}

/// Cap on `recent_lines` per terminal.
pub const RECENT_LINE_CAP: usize = 512;

/// Cap on matches collected by [`TermGrid::search`]. The pane re-runs the
/// search on every keystroke and walks every result on every frame, so a
/// one-character pattern over a full scrollback must not be able to hand the
/// UI thread millions of positions.
pub const MAX_SEARCH_RESULTS: usize = 10_000;

impl TermGrid {
    /// Create a new terminal grid at the given dimensions.
    ///
    /// The cell area is `rows × cols`. The default alacritty config is
    /// used; a custom `Config` can be substituted later if needed.
    pub fn new(rows: usize, cols: usize) -> Self {
        Self::new_with_history(rows, cols, 10_000)
    }

    /// Create a new terminal grid with a bounded scrollback history.
    ///
    /// `max_history` caps how many scrolled-off lines alacritty retains in
    /// memory; the persistent SQLite store has its own independent cap.
    pub fn new_with_history(rows: usize, cols: usize, max_history: usize) -> Self {
        let config = Config {
            scrolling_history: max_history,
            ..Config::default()
        };
        let size = GridSize { rows, cols };
        let title = Arc::new(Mutex::new(String::new()));
        let replies = Arc::new(Mutex::new(std::collections::VecDeque::new()));
        let listener = TitleListener {
            title: Arc::clone(&title),
            replies: Arc::clone(&replies),
        };
        let term = Term::new(config, &size, listener);
        let processor = vte::ansi::Processor::new();
        Self {
            term,
            processor,
            title,
            replies,
            rows,
            cols,
            generation: 0,
            palette_changed: false,
            last_full_offset: 0,
            palette: crate::color::SYSTEM_COLORS,
            line_count: 0,
            history: None,
            status: TermStatus::default(),
            agent_state: crate::agent_state::AgentStateTracker::default(),
            recent_lines: std::collections::VecDeque::new(),
        }
    }

    /// Take pending emulator-generated PTY replies (cursor reports, mode
    /// reports). The engine writes them to the child PTY.
    pub fn drain_replies(&mut self) -> Vec<Vec<u8>> {
        lock_or_warn(&self.replies, "terminal replies")
            .map(|mut q| q.drain(..).collect())
            .unwrap_or_default()
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

    /// Seed the internal line counter to continue numbering after restored
    /// history rows (`max_line_num` of the pane's store). Prevents line
    /// number collisions between restored and freshly appended rows.
    pub fn seed_line_count(&mut self, n: u64) {
        self.line_count = n;
    }

    /// Feed restored history lines into the grid's scrollback.
    ///
    /// Uses the ANSI path so escape sequences in restored lines are
    /// interpreted correctly. Never calls `store_line` — restored rows
    /// already live in the database and must not be re-appended.
    ///
    /// Consecutive identical non-empty lines collapse to one: builds before
    /// the bare-CR parser fix committed the shell prompt on every SIGWINCH
    /// redraw, stamping runs of identical prompt rows into history. Those
    /// rows carry no information (a redraw run, not real output) and
    /// restoring them makes the terminal look like Enter was pressed
    /// dozens of times.
    pub fn feed_restore_lines(&mut self, lines: &[String]) {
        let mut prev: Option<&str> = None;
        for line in lines {
            if !line.is_empty() && prev == Some(line.as_str()) {
                continue;
            }
            self.feed(format!("{line}\r\n").as_bytes());
            prev = Some(line.as_str());
        }
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
        let mut rows: Vec<Vec<CellInfo>> = vec![vec![CellInfo::default(); self.cols]; self.rows];

        for indexed in content.display_iter {
            // display_iter reports negative line numbers for history rows;
            // add the display offset to shift them into 0..self.rows range
            let line = (indexed.point.line.0 + offset) as usize;
            let col = indexed.point.column.0;

            if line < self.rows && col < self.cols {
                rows[line][col] = CellInfo::from_cell(indexed.cell, &self.palette);
            }
        }
        rows
    }

    /// Plain-text lines of the visible screen plus scrollback, oldest
    /// first, most recent last. No ANSI, no trailing spaces, wide-char
    /// spacers skipped. Capped at `limit` lines (most recent kept).
    /// This backs `paneRead`.
    pub fn plain_text(&self, limit: usize) -> Vec<String> {
        let grid = self.term.grid();
        let history = grid.history_size() as i32;
        let screen = grid.screen_lines() as i32;
        let mut out: Vec<String> = Vec::with_capacity((history + screen) as usize);
        // Grid uses negative Line for scrollback: Line(-history) .. Line(screen-1).
        // `display_iter` would cover the viewport only, which silently dropped
        // every scrolled-off line from `paneRead`.
        for raw_line in -history..screen {
            let row = &grid[Line(raw_line)];
            let mut text = String::with_capacity(self.cols);
            for col in 0..self.cols {
                let ch = row[Column(col)].c;
                // Zero-width spacer following a wide character.
                if ch == '\0' {
                    continue;
                }
                text.push(ch);
            }
            while text.ends_with(' ') {
                text.pop();
            }
            out.push(text);
        }
        if out.len() > limit {
            let skip = out.len() - limit;
            out.drain(..skip);
        }
        out
    }
    pub fn get_grid_updates(&mut self, force_full: bool) -> GridUpdate {
        let offset_changed = self.term.grid().display_offset() != self.last_full_offset;
        if force_full || self.palette_changed || offset_changed {
            self.palette_changed = false;
            self.term.reset_damage();
            let rows = self.renderable_rows();
            self.last_full_offset = self.term.grid().display_offset();
            return GridUpdate::Full(rows);
        }

        let damage: Vec<_> = match self.term.damage() {
            alacritty_terminal::term::TermDamage::Full => {
                self.term.reset_damage();
                let rows = self.renderable_rows();
                self.last_full_offset = self.term.grid().display_offset();
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
        if self.rows == rows && self.cols == cols {
            return;
        }
        let old_rows = self.rows;
        let was_following = self.term.grid().display_offset() == 0;
        let cursor = self.cursor_position();
        let alt_screen = self.is_alt_screen();
        self.rows = rows;
        self.cols = cols;
        self.term.resize(GridSize { rows, cols });

        // xterm-style anchoring: alacritty's resize pulls scrollback into
        // the new top rows and moves the cursor to the new bottom, so the
        // visible text appears to "scroll through the past". When the grid
        // GREW and the user was following output, undo that: delete the
        // revealed rows and return the cursor to its previous row, leaving
        // the text in view untouched and blank rows below the cursor.
        //
        // The `history_size() > 0` test is read from the POST-resize grid,
        // and alacritty's `grow_lines` ends with
        // `decrease_scroll_limit(lines_added)`: the growth consumes
        // scrollback first, so post-resize history is
        // `pre_history.saturating_sub(growth)`. It passes only when the
        // scrollback was longer than the growth — exactly when every new row
        // was recovered from history and no visible row was pushed off. The
        // deleted rows are therefore recovered scrollback rows, never
        // on-screen content; scrollback shorter than the growth is zeroed by
        // that same call, so the guard fails and the surgery is skipped.
        //
        // That is a guarantee about which rows can be deleted, not about
        // what the pane is running: it cannot distinguish a shell from a
        // full-screen app. A primary-screen app that paints without smcup
        // (the OMP TUI) is only safe on a fresh pane — launched after the
        // pane had more scrollback than the row growth, it passes every test
        // here and these raw CUP/DL escapes land in its screen. Only the
        // alternate-screen check catches real full-screen apps.
        if was_following && rows > old_rows && !alt_screen && self.term.grid().history_size() > 0 {
            let growth = rows - old_rows;
            let mut seq = String::from("\x1b[H"); // cursor home
            seq.push_str(&format!("\x1b[{growth}M")); // delete revealed history
            if let Some((cursor_row, cursor_col)) = cursor {
                seq.push_str(&format!("\x1b[{cursor_row}B")); // back to old row
                seq.push_str(&format!("\x1b[{}G", cursor_col + 1)); // restore column
            }
            self.processor.advance(&mut self.term, seq.as_bytes());
        }
        self.generation += 1;
    }

    /// True while the terminal runs a full-screen application in the
    /// alternate screen buffer (smcup users: vim, less, btop, …). The
    /// alternate screen keeps no scrollback, and concept engines must not
    /// treat its redraw output as shell lines. This check is what keeps
    /// `resize()`'s row-deletion surgery off full-screen apps; it does not
    /// cover apps that paint the PRIMARY screen without entering smcup (the
    /// OMP TUI), which is why that surgery's own guard must stay
    /// conservative.
    pub fn is_alt_screen(&self) -> bool {
        self.term
            .mode()
            .contains(alacritty_terminal::term::TermMode::ALT_SCREEN)
    }

    /// True while the application has enabled application keypad mode
    /// (DECPAM/DECKPAM). Numpad keys send SS3 sequences in that mode, and
    /// the characters printed on the keys otherwise.
    pub fn is_app_keypad(&self) -> bool {
        self.term
            .mode()
            .contains(alacritty_terminal::term::TermMode::APP_KEYPAD)
    }

    /// Mouse reporting the child process has enabled, as a bitmask of the
    /// `MOUSE_MODE_*` constants (DECSET 1000/1002/1003 for the tracking mode,
    /// 1006 for SGR encoding). Zero means the pane owns mouse events:
    /// selection and scrollback behave as usual. The UI encodes what it
    /// forwards from these same bits, so the FFI value and the emitted bytes
    /// can never disagree.
    pub fn mouse_mode(&self) -> u8 {
        let mode = self.term.mode();
        let mut bits = 0u8;
        if mode.contains(alacritty_terminal::term::TermMode::MOUSE_REPORT_CLICK) {
            bits |= MOUSE_MODE_CLICK;
        }
        if mode.contains(alacritty_terminal::term::TermMode::MOUSE_DRAG) {
            bits |= MOUSE_MODE_DRAG;
        }
        if mode.contains(alacritty_terminal::term::TermMode::MOUSE_MOTION) {
            bits |= MOUSE_MODE_MOTION;
        }
        if mode.contains(alacritty_terminal::term::TermMode::SGR_MOUSE) {
            bits |= MOUSE_MODE_SGR;
        }
        bits
    }

    /// Current terminal title (set via OSC escape sequences, e.g. bash prompt).
    pub fn title(&self) -> String {
        lock_or_warn(&self.title, "terminal title")
            .map(|t| t.clone())
            .unwrap_or_default()
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
        // A hidden cursor (\x1b[?25l, which most TUIs emit while redrawing)
        // must not be painted at all.
        if !self
            .term
            .mode()
            .contains(alacritty_terminal::term::TermMode::SHOW_CURSOR)
        {
            return None;
        }
        let content = self.term.renderable_content();
        // Report viewport coordinates. While scrolled back the cursor sits
        // below the viewport, and painting it at its grid row draws it over
        // an unrelated line; past the viewport this yields None.
        let offset = self.term.grid().display_offset();
        let point = alacritty_terminal::term::point_to_viewport(offset, content.cursor.point)?;
        let col = point.column.0;
        if point.line < self.rows && col < self.cols {
            Some((point.line, col))
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
        self.term
            .grid_mut()
            .scroll_display(Scroll::Delta(lines as i32));
        self.generation += 1;
    }

    /// Scroll down (forward in history) by `lines`.
    pub fn scroll_down(&mut self, lines: usize) {
        self.term
            .grid_mut()
            .scroll_display(Scroll::Delta(-(lines as i32)));
        self.generation += 1;
    }

    /// Reset scroll to follow live output (bottom).
    pub fn scroll_reset(&mut self) {
        self.term.grid_mut().scroll_display(Scroll::Bottom);
        self.generation += 1;
    }

    /// Store a completed output line in the optional scrollback and the
    /// recent-lines ring (backs `waitForOutput`).
    ///
    /// The ring is updated synchronously — `waitForOutput` polls it every
    /// frame and must see the line that just matched — while persistence is
    /// handed to the pane's writer thread. Nothing here touches SQLite: this
    /// runs under the grid mutex, which the UI thread needs to render, and a
    /// per-line insert used to hold it for ~30 µs.
    pub fn store_line(&mut self, line: &str) {
        self.line_count += 1;
        self.recent_lines.push_back(line.to_string());
        if self.recent_lines.len() > RECENT_LINE_CAP {
            self.recent_lines.pop_front();
        }
        if let Some(history) = &self.history {
            history.push(self.line_count as i64, line);
        }
    }

    /// First recent line (newest-first scan) matching `pattern`, or `None`.
    /// Uses the standard `regex` crate — ReDoS-safe. Pattern capped at 1024
    /// chars; invalid patterns yield `None`.
    pub fn first_matching_line(&self, pattern: &str) -> Option<String> {
        if pattern.is_empty() || pattern.len() > 1024 {
            return None;
        }
        let Ok(re) = regex::Regex::new(pattern) else {
            return None;
        };
        self.recent_lines
            .iter()
            .rev()
            .find(|l| re.is_match(l))
            .cloned()
    }
    /// Search the full grid (scrollback + visible) for lines matching `pattern`.
    ///
    /// Returns a list of `(line_idx, col)` positions. `line_idx` is 0-based
    /// from the top of scrollback history (0 = oldest history line).
    /// `col` is the byte offset of the match within the line's text.
    ///
    /// Collection stops at [`MAX_SEARCH_RESULTS`]: a one-character pattern
    /// matches every character of every line, and the pane re-runs the search
    /// on each keystroke and walks every result each frame, so an uncapped
    /// result set is a UI-thread stall. Terminal content is attacker-influenced
    /// (a program can print repetitive output) even though the pattern is typed
    /// by the user.
    ///
    /// Uses the standard `regex` crate — no backtracking engine, ReDoS-safe.
    pub fn search(&self, pattern: &str) -> Result<Vec<(i32, i32)>, regex::Error> {
        let re = regex::Regex::new(pattern)?;
        let grid = self.term.grid();
        let history = grid.history_size() as i32;
        let screen = grid.screen_lines() as i32;
        let mut results = Vec::new();

        // Grid uses negative Line for scrollback: Line(-history) .. Line(screen-1)
        'rows: for raw_line in -history..screen {
            let row = &grid[Line(raw_line)];
            let mut text = String::with_capacity(self.cols);
            for col in 0..self.cols {
                text.push(row[Column(col)].c);
            }
            // Trim trailing spaces — terminal lines are space-padded to width
            let trimmed_len = text.trim_end().len();
            for m in re.find_iter(&text[..trimmed_len]) {
                // Report line as 0-based from top of scrollback
                results.push((raw_line + history, m.start() as i32));
                if results.len() >= MAX_SEARCH_RESULTS {
                    break 'rows;
                }
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

    /// DECSET 1000/1002/1003 pick one tracking mode (the newest wins) and
    /// 1006 is independent of it — the UI both checks these bits and encodes
    /// the bytes it forwards from them.
    #[test]
    fn mouse_mode_tracks_decset_and_reset() {
        let mut g = TermGrid::new(24, 80);
        assert_eq!(g.mouse_mode(), 0, "a fresh grid owns its own mouse events");

        g.feed(b"\x1b[?1000h");
        assert_eq!(g.mouse_mode(), MOUSE_MODE_CLICK);

        g.feed(b"\x1b[?1002h");
        assert_eq!(
            g.mouse_mode(),
            MOUSE_MODE_DRAG,
            "a tracking mode replaces the previous one"
        );

        g.feed(b"\x1b[?1006h");
        assert_eq!(g.mouse_mode(), MOUSE_MODE_DRAG | MOUSE_MODE_SGR);

        g.feed(b"\x1b[?1002l");
        assert_eq!(
            g.mouse_mode(),
            MOUSE_MODE_SGR,
            "encoding outlives the tracking mode"
        );

        g.feed(b"\x1b[?1006l");
        assert_eq!(g.mouse_mode(), 0, "all reporting off");

        g.feed(b"\x1b[?1003h");
        assert_eq!(g.mouse_mode(), MOUSE_MODE_MOTION);
    }

    #[test]
    fn restore_feed_does_not_duplicate_history_rows() {
        let mut g = TermGrid::new_with_history(24, 80, 100);
        let history = crate::history::PaneHistory::open(":memory:", "pane-t", 100).unwrap();
        let store = Arc::clone(history.store());
        g.history = Some(Arc::new(history));
        g.seed_line_count(5);
        g.feed_restore_lines(&["old line 1".to_string(), "old line 2".to_string()]);
        g.store_line("new line");
        // The writer thread commits asynchronously; a push is not a write.
        g.history.as_ref().unwrap().flush();
        let hist = store.lock().unwrap();
        // Restored rows are not re-appended; numbering continues at 6.
        assert_eq!(hist.max_line_num().unwrap(), 6);
        assert_eq!(hist.line_count().unwrap(), 1);
    }

    #[test]
    fn restore_collapses_identical_prompt_runs() {
        let mut g = TermGrid::new(10, 60);
        let mut lines: Vec<String> = vec!["line-a".to_string(), "line-b".to_string()];
        for _ in 0..25 {
            lines.push("[neilp@cachyos-x8664 ~]$ ".to_string());
        }
        lines.push("line-c".to_string());
        g.feed_restore_lines(&lines);
        let rows = g.renderable_rows();
        let text: Vec<String> = rows
            .iter()
            .map(|r| {
                r.iter()
                    .map(|c| c.ch)
                    .collect::<String>()
                    .trim_end()
                    .to_string()
            })
            .collect();
        assert_eq!(text[0], "line-a", "first restored line must survive");
        assert_eq!(text[1], "line-b", "second restored line must survive");
        assert_eq!(
            text[2], "[neilp@cachyos-x8664 ~]$",
            "a run of 25 identical prompt rows must collapse to one"
        );
        assert_eq!(text[3], "line-c", "content after the run must survive");
        assert_eq!(text[4], "", "nothing else may follow");
    }

    #[test]
    fn resize_growth_keeps_viewport_anchored() {
        let mut grid = TermGrid::new(5, 20);
        for i in 0..20 {
            let line = format!("line-{:02}-{}", i, "x".repeat(12));
            grid.feed(format!("{line}\r\n").as_bytes());
        }
        let top_before: String = grid.renderable_rows()[0]
            .iter()
            .map(|c| c.ch)
            .collect::<String>()
            .trim_end()
            .to_string();
        let cursor_before = grid.cursor_position();

        grid.resize(8, 30);

        let rows = grid.renderable_rows();
        let top_after: String = rows[0]
            .iter()
            .map(|c| c.ch)
            .collect::<String>()
            .trim_end()
            .to_string();
        assert_eq!(
            top_before, top_after,
            "top row must not change when the grid grows"
        );
        assert_eq!(
            cursor_before,
            grid.cursor_position(),
            "cursor row/column must not move when the grid grows"
        );
        if let Some((cursor_row, _)) = grid.cursor_position() {
            for row in &rows[cursor_row + 1..] {
                let text: String = row.iter().map(|c| c.ch).collect();
                assert_eq!(
                    text.trim_end(),
                    "",
                    "rows below the cursor must stay blank after growth"
                );
            }
        }
    }

    #[test]
    fn resize_growth_without_scrollback_keeps_content() {
        let mut grid = TermGrid::new(5, 20);
        grid.feed(b"line one\r\nline two\r\nline three\r\n");
        assert_eq!(grid.history_size(), 0, "fresh grid has no scrollback");
        let top_before: String = grid.renderable_rows()[0]
            .iter()
            .map(|c| c.ch)
            .collect::<String>()
            .trim_end()
            .to_string();

        grid.resize(8, 30);

        let top_after: String = grid.renderable_rows()[0]
            .iter()
            .map(|c| c.ch)
            .collect::<String>()
            .trim_end()
            .to_string();
        assert_eq!(
            top_before, top_after,
            "primary-screen apps without scrollback must not lose rows"
        );
    }
    #[test]
    fn resize_growth_skips_alternate_screen() {
        let mut grid = TermGrid::new(5, 20);
        grid.feed(b"\x1b[?1049h"); // enter alternate screen (full-screen TUI)
        grid.feed(b"TUI content\r\n");
        grid.feed(b"more TUI\r\n");
        assert!(grid.is_alt_screen(), "alt screen mode must be active");
        let top_before: String = grid.renderable_rows()[0]
            .iter()
            .map(|c| c.ch)
            .collect::<String>()
            .trim_end()
            .to_string();

        grid.resize(8, 30);

        let top_after: String = grid.renderable_rows()[0]
            .iter()
            .map(|c| c.ch)
            .collect::<String>()
            .trim_end()
            .to_string();
        assert_eq!(
            top_before, top_after,
            "resize must not delete rows on the alternate screen"
        );
    }

    #[test]
    fn dsr_cursor_query_produces_reply() {
        let mut g = TermGrid::new(5, 20);
        g.feed(b"abc"); // cursor at row 0, column 3
        g.feed(b"\x1b[6n"); // device status report: cursor position
        let replies = g.drain_replies();
        assert_eq!(
            replies,
            vec![b"\x1b[1;4R".to_vec()],
            "DSR must produce a 1-based cursor report"
        );
        assert!(g.drain_replies().is_empty(), "queue must drain");
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
    fn plain_text_includes_scrollback() {
        let mut g = TermGrid::new(5, 20);
        for i in 0..8 {
            g.feed(format!("L{i}\r\n").as_bytes());
        }

        let lines = g.plain_text(50);
        assert!(
            lines.iter().any(|l| l == "L0"),
            "scrolled-off line must stay readable through paneRead: {lines:?}"
        );
        assert!(
            lines.len() > 5,
            "result must cover more than one viewport: {lines:?}"
        );

        // `limit` keeps the most recent lines, so the oldest must fall off.
        let recent = g.plain_text(3);
        assert_eq!(recent.len(), 3);
        assert!(
            !recent.iter().any(|l| l == "L0"),
            "limit must drop the oldest lines first: {recent:?}"
        );
        assert!(
            recent.iter().any(|l| l == "L7"),
            "limit must retain the newest lines: {recent:?}"
        );
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
        assert_eq!(rows[0][0].fg, [205, 0, 0]); // \x1b[31m = Red
    }

    #[test]
    fn cursor_position() {
        let mut g = TermGrid::new(5, 20);
        g.feed(b"abc");
        let pos = g.cursor_position().expect("cursor should be visible");
        assert_eq!(pos, (0, 3));
    }

    #[test]
    fn cursor_position_respects_visibility() {
        let mut g = TermGrid::new(5, 20);
        g.feed(b"abc");
        assert!(g.cursor_position().is_some());

        g.feed(b"\x1b[?25l"); // DECTCEM off — hide cursor
        assert!(
            g.cursor_position().is_none(),
            "a hidden cursor must not be reported for drawing"
        );

        g.feed(b"\x1b[?25h"); // show again
        assert!(g.cursor_position().is_some());
    }

    #[test]
    fn cursor_position_is_viewport_relative_when_scrolled() {
        let mut g = TermGrid::new(5, 20);
        for i in 0..10 {
            g.feed(format!("L{i}\r\n").as_bytes());
        }
        g.feed(b"\x1b[H"); // cursor to the top row of the screen
        assert_eq!(g.cursor_position(), Some((0, 0)));

        g.scroll_up(3);
        // The grid row is unchanged, but the viewport moved: the cursor now
        // sits three rows lower on screen, and past the viewport it is gone.
        assert_eq!(g.cursor_position(), Some((3, 0)));

        g.scroll_up(5);
        assert!(
            g.cursor_position().is_none(),
            "a cursor scrolled below the viewport must not be drawn"
        );
    }

    #[test]
    fn scrollback_basic() {
        let mut g = TermGrid::new(3, 10);
        g.feed(b"line1\r\nline2\r\nline3\r\nline4\r\nline5\r\n");
        let hist = g.history_size();
        assert_eq!(hist, 3, "5 lines + trailing CRLF = 3 history");
        // Before scroll, visible rows should be the last 3 lines
        let before: Vec<String> = g
            .renderable_rows()
            .iter()
            .map(|r| {
                r.iter()
                    .map(|c| c.ch)
                    .collect::<String>()
                    .trim_end()
                    .to_string()
            })
            .collect();
        assert_eq!(before[0], "line4", "visible row 0 before scroll");
        assert_eq!(before[1], "line5", "visible row 1 before scroll");
        assert_eq!(before[2], "", "visible row 2 before scroll");
        // After scrolling up, we should see history
        g.scroll_up(2);
        let after: Vec<String> = g
            .renderable_rows()
            .iter()
            .map(|r| {
                r.iter()
                    .map(|c| c.ch)
                    .collect::<String>()
                    .trim_end()
                    .to_string()
            })
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
        assert_eq!(
            g.generation,
            gen_before + 3,
            "scroll operations should increment generation"
        );
    }

    #[test]
    fn title_capture() {
        let mut g = TermGrid::new(5, 20);
        g.feed(b"\x1b]0;Test Title\x07");
        assert_eq!(g.title(), "Test Title");
    }

    #[test]
    fn partial_damage_tracks_fed_cells() {
        let mut g = TermGrid::new(3, 20);
        // Initial state carries full damage — flush it the way the
        // renderer's first force_full fetch does.
        let _ = g.get_grid_updates(false);
        g.feed(b"hi");
        match g.get_grid_updates(false) {
            GridUpdate::Partial(ups) => {
                // Fed cells plus the always-damaged cursor cell.
                let at = |col: usize| ups.iter().find(|u| u.row == 0 && u.col == col);
                assert_eq!(at(0).map(|u| u.cell.ch), Some('h'));
                assert_eq!(at(1).map(|u| u.cell.ch), Some('i'));
            }
            _ => panic!("expected partial update after feed"),
        }
        // Fed-cell damage consumed — only the cursor cell may remain
        // (alacritty always damages the current cursor position).
        match g.get_grid_updates(false) {
            GridUpdate::Partial(ups) => assert!(
                ups.iter().all(|u| u.cell.ch != 'h' && u.cell.ch != 'i'),
                "fed-cell damage must be reset"
            ),
            _ => panic!("expected partial update"),
        }
    }

    #[test]
    fn force_full_returns_all_cells_and_resets_damage() {
        let mut g = TermGrid::new(2, 10);
        g.feed(b"abc");
        match g.get_grid_updates(true) {
            GridUpdate::Full(rows) => {
                assert_eq!(rows.len(), 2);
                assert_eq!(rows[0][0].ch, 'a');
                assert_eq!(rows[0][2].ch, 'c');
            }
            _ => panic!("expected full update when forced"),
        }
        // The next partial fetch still spans the old-cursor → new-cursor
        // range (alacritty damages everything the cursor crossed; the
        // forced-full branch never reads damage(), so last_cursor was
        // still the construction default). Fetch once to stabilize, then
        // assert fed-cell damage is gone.
        let _ = g.get_grid_updates(false);
        match g.get_grid_updates(false) {
            GridUpdate::Partial(ups) => assert!(
                ups.iter()
                    .all(|u| u.cell.ch != 'a' && u.cell.ch != 'b' && u.cell.ch != 'c'),
                "fed-cell damage must be reset by forced full"
            ),
            _ => panic!("expected partial after forced full"),
        }
    }
}
