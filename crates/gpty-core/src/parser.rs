//! ANSI escape sequence stripper — extracts plain-text lines from raw PTY output.
//!
//! This is a **lightweight** parser used for concept regex matching. It
//! intentionally discards all formatting (colors, cursor movements, erase
//! operations) and only collects printable characters and line breaks.
//!
//! For full terminal grid rendering (cursor position, SGR attributes,
//! scrolling regions), use [`crate::term::TermGrid`] instead, which wraps
//! `alacritty_terminal` and maintains the complete grid state.
//!
//! # Design
//!
//! The vte crate provides a [`vte::Parser`] and a [`vte::Perform`] trait.
//! We implement `Perform` on a private [`Handler`] struct that:
//!
//! - Collects printable characters into a `current_line` buffer
//! - Commits the buffer on `\n` (LF) or `\r` (CR)
//! - Discards all CSI, OSC, ESC, and DCS sequences
//!
//! This is ~80 lines total — far simpler than a full terminal emulator,
//! and sufficient for regex-based concept triggering.

use vte::{Params, Parser, Perform};

/// Strips ANSI escape sequences from a PTY byte stream and extracts
/// completed lines of visible text for regex matching.
pub struct LineParser {
    parser: Parser,
    handler: Handler,
}

impl LineParser {
    pub fn new() -> Self {
        Self { parser: Parser::new(), handler: Handler::default() }
    }

    /// Feed raw PTY bytes into the parser.
    pub fn feed(&mut self, bytes: &[u8]) -> Vec<String> {
        self.parser.advance(&mut self.handler, bytes);
        std::mem::take(&mut self.handler.completed_lines)
    }
}

// ── vte Perform implementation ─────────────────────────────────────────

/// Private vte handler that collects printable text and ignores everything else.
#[derive(Default)]
struct Handler {
    current_line: String,
    completed_lines: Vec<String>,
    last_was_cr: bool,
}

impl Perform for Handler {
    /// Printable character — append to current line.
    fn print(&mut self, c: char) {
        self.current_line.push(c);
        self.last_was_cr = false;
    }

    /// C0 control character.
    fn execute(&mut self, byte: u8) {
        match byte {
            // Line-feed: commit even if the line is empty (some programs
            // output blank lines intentionally). Skip if preceded by CR
            // to avoid spurious empty lines from \r\n pairs.
            b'\n' => {
                if !self.last_was_cr {
                    self.completed_lines
                        .push(std::mem::take(&mut self.current_line));
                }
                self.last_was_cr = false;
            }
            // Carriage-return: commit only if the line has content.
            // Some programs (e.g., progress bars) output status lines
            // terminated only by CR without a following LF.
            b'\r' => {
                let line = std::mem::take(&mut self.current_line);
                if !line.is_empty() {
                    self.completed_lines.push(line);
                }
                self.last_was_cr = true;
            }
            // BEL, BS, HT, VT, FF — reset the CR flag and ignore.
            _ => {
                self.last_was_cr = false;
            }
        }
    }

    // ── All escape sequence handlers: discard ──────────────────────────

    /// CSI: `ESC [` — cursor positioning, SGR, etc.
    fn csi_dispatch(
        &mut self,
        _params: &Params,
        _intermediates: &[u8],
        _ignore: bool,
        _action: char,
    ) {
    }

    /// OSC: `ESC ]` — window title, clipboard, etc.
    fn osc_dispatch(&mut self, _params: &[&[u8]], _bell_terminated: bool) {}

    /// ESC: single-character escape sequences.
    fn esc_dispatch(&mut self, _intermediates: &[u8], _ignore: bool, _byte: u8) {}

    /// DCS: device control strings — enter.
    fn hook(
        &mut self,
        _params: &Params,
        _intermediates: &[u8],
        _ignore: bool,
        _action: char,
    ) {
    }

    /// DCS: device control strings — data byte.
    fn put(&mut self, _byte: u8) {}

    /// DCS: device control strings — exit.
    fn unhook(&mut self) {}
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_text() {
        let mut p = LineParser::new();
        let lines = p.feed(b"hello world\n");
        assert_eq!(lines, vec!["hello world"]);
    }

    #[test]
    fn multiple_lines() {
        let mut p = LineParser::new();
        let lines = p.feed(b"line1\nline2\n");
        assert_eq!(lines, vec!["line1", "line2"]);
    }

    #[test]
    fn cr_then_text_then_lf() {
        let mut p = LineParser::new();
        let lines = p.feed(b"hello\rworld\n");
        assert_eq!(lines, vec!["hello", "world"]);
    }

    #[test]
    fn partial_then_complete() {
        let mut p = LineParser::new();
        let lines = p.feed(b"hel");
        assert!(lines.is_empty(), "partial should buffer");
        let lines = p.feed(b"lo\n");
        assert_eq!(lines, vec!["hello"]);
    }

    #[test]
    fn strip_ansi_colors() {
        let mut p = LineParser::new();
        // \x1b[31m = red, \x1b[0m = reset
        let lines = p.feed(b"\x1b[31mRED\x1b[0m normal\n");
        assert_eq!(lines, vec!["RED normal"]);
    }

    #[test]
    fn carriage_return_commits() {
        let mut p = LineParser::new();
        let lines = p.feed(b"progress 50%\r");
        assert_eq!(lines, vec!["progress 50%"]);
    }

    #[test]
    fn empty_cr_ignored() {
        let mut p = LineParser::new();
        let lines = p.feed(b"\r");
        assert!(lines.is_empty(), "empty CR should not produce a line");
    }

    #[test]
    fn empty_lf_commits() {
        let mut p = LineParser::new();
        let lines = p.feed(b"\n");
        assert_eq!(lines, vec![""]);
    }
    #[test]
    fn crlf_produces_single_line() {
        let mut p = LineParser::new();
        let lines = p.feed(b"hello\r\nworld\r\n");
        assert_eq!(lines, vec!["hello", "world"], "CRLF should not produce empty lines");
    }

    #[test]
    fn csi_cursor_movement_stripped() {
        let mut p = LineParser::new();
        // \x1b[2J = clear screen, should be discarded
        let lines = p.feed(b"\x1b[2Jhello\n");
        assert_eq!(lines, vec!["hello"]);
    }

    #[test]
    fn osc_title_stripped() {
        let mut p = LineParser::new();
        // OSC 0;title BEL
        let lines = p.feed(b"\x1b]0;mytitle\x07prompt$\n");
        assert_eq!(lines, vec!["prompt$"]);
    }
}
