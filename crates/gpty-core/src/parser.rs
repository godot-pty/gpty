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

impl Default for LineParser {
    fn default() -> Self {
        Self::new()
    }
}

impl LineParser {
    pub fn new() -> Self {
        Self {
            parser: Parser::new(),
            handler: Handler::default(),
        }
    }

    /// Feed raw PTY bytes into the parser.
    pub fn feed(&mut self, bytes: &[u8]) -> Vec<String> {
        self.parser.advance(&mut self.handler, bytes);
        std::mem::take(&mut self.handler.completed_lines)
    }

    /// Consume the Tier 2 agent-state declaration seen in the bytes fed
    /// since the last take. Returns `None` when no whitelisted
    /// `gpty_state=<value>` sequence was parsed.
    pub fn take_declared_state(&mut self) -> Option<crate::agent_state::AgentState> {
        self.handler.declared_state.take()
    }
}

/// Maximum bytes buffered for a single output line before the parser
/// stops collecting. Bounds memory when a program floods output without
/// newlines; concept matching is additionally gated on this length in
/// the engine. The grid still receives raw bytes (separate path).
pub const MAX_LINE_LEN: usize = 16 * 1024;

/// Private vte handler that collects printable text and ignores everything else.
#[derive(Default)]
struct Handler {
    current_line: String,
    completed_lines: Vec<String>,
    /// Line stashed by a CR. CR alone never commits: bash reprints its
    /// prompt on SIGWINCH as `\r\x1b[K\r<prompt>` and a commit-per-CR
    /// would stamp a history row for every resize. The next byte decides:
    /// LF → CRLF pair, the stashed text IS the completed line; any
    /// printable → the stashed text was overwritten (reprint), drop it.
    cr_stash: Option<String>,
    /// Tier 2 agent-state declaration from an OSC `gpty_state=<value>`
    /// sequence. Single-shot: only the first declaration in a parse
    /// applies; the engine consumes it via [`LineParser::take_declared_state`].
    declared_state: Option<crate::agent_state::AgentState>,
}

impl Perform for Handler {
    /// Printable character — append to current line.
    fn print(&mut self, c: char) {
        // A printable after a bare CR means the stashed text was
        // overwritten (redraw/reprint, progress-bar update) — discard it.
        if self.cr_stash.take().is_some() {
            self.current_line.clear();
        }
        if self.current_line.len() < MAX_LINE_LEN {
            self.current_line.push(c);
        }
    }

    /// C0 control character.
    fn execute(&mut self, byte: u8) {
        match byte {
            // Line-feed: ends the line. After a CR (CRLF pair) the stashed
            // text is the line; a bare LF commits the buffer directly.
            // Commits even when empty — blank lines are real output.
            b'\n' => {
                if let Some(stashed) = self.cr_stash.take() {
                    self.completed_lines.push(stashed);
                } else {
                    self.completed_lines
                        .push(std::mem::take(&mut self.current_line));
                }
            }
            // Carriage-return: stash, never commit (see cr_stash doc).
            b'\r' => {
                self.cr_stash = Some(std::mem::take(&mut self.current_line));
            }
            // BEL, BS, HT, VT, FF — ignore.
            _ => {}
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
    ///
    /// The ONE interpreted sequence in this discard-only parser: the
    /// published Tier 2 agent-state declaration `gpty_state=<value>`.
    /// Strictly whitelisted, single-shot, consumed by the engine with the
    /// same alt-screen / capture-replay / resize suppression as concept
    /// matching. Do not interpret further OSC sequences here without a
    /// security review — everything else stays discarded.
    fn osc_dispatch(&mut self, params: &[&[u8]], _bell_terminated: bool) {
        if self.declared_state.is_some() || params.is_empty() {
            return;
        }
        let mut kv = params[0].splitn(2, |b| *b == b'=');
        let key = kv.next();
        let value = kv.next();
        if key == Some(b"gpty_state")
            && let Some(text) = value.and_then(|v| std::str::from_utf8(v).ok())
            && let Some(state) = crate::agent_state::AgentState::from_declaration(text)
        {
            self.declared_state = Some(state);
        }
    }

    /// ESC: single-character escape sequences.
    fn esc_dispatch(&mut self, _intermediates: &[u8], _ignore: bool, _byte: u8) {}

    /// DCS: device control strings — enter.
    fn hook(&mut self, _params: &Params, _intermediates: &[u8], _ignore: bool, _action: char) {}

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
        // Terminal semantics: the CR returns to column 0 and the following
        // text overwrites — "hello" is gone, only "world" completes.
        let lines = p.feed(b"hello\rworld\n");
        assert_eq!(lines, vec!["world"]);
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
    fn bare_cr_does_not_commit() {
        let mut p = LineParser::new();
        // Progress bars / prompt redraws terminate with bare CR — the
        // pending text is not a completed line and must not hit history
        // or concept matching.
        let lines = p.feed(b"progress 50%\r");
        assert!(lines.is_empty(), "bare CR must not commit a line");
    }

    #[test]
    fn crlf_commits_stashed_line() {
        let mut p = LineParser::new();
        let lines = p.feed(b"[neilp@cachyos-x8664 ~]$ \r\n");
        assert_eq!(lines, vec!["[neilp@cachyos-x8664 ~]$ "]);
    }

    #[test]
    fn redraw_sequence_does_not_commit() {
        let mut p = LineParser::new();
        // bash's SIGWINCH redraw: \r, clear-to-EOL, \r, prompt reprint.
        // Each redraw must not stamp another history row.
        let redraw = b"\r\x1b[K\r[neilp@cachyos-x8664 ~]$ ";
        for _ in 0..3 {
            assert!(p.feed(redraw).is_empty(), "redraw must not commit");
        }
        // Only a real line end commits — once, with the final text.
        assert_eq!(p.feed(b"\r\n"), vec!["[neilp@cachyos-x8664 ~]$ "]);
    }

    #[test]
    fn crlf_empty_line_commits() {
        let mut p = LineParser::new();
        // "\r\n" is one real (blank) line.
        let lines = p.feed(b"\r\n");
        assert_eq!(lines, vec![""]);
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
        assert_eq!(
            lines,
            vec!["hello", "world"],
            "CRLF should not produce empty lines"
        );
    }

    #[test]
    fn osc_state_declaration_recognized() {
        use crate::agent_state::AgentState;
        let mut p = LineParser::new();
        let lines = p.feed(b"\x1b]gpty_state=working\x07");
        assert!(lines.is_empty(), "declaration must not commit a line");
        assert_eq!(p.take_declared_state(), Some(AgentState::Working));
    }

    #[test]
    fn osc_state_declaration_whitelist_only() {
        let mut p = LineParser::new();
        p.feed(b"\x1b]gpty_state=rm -rf /\x07");
        assert_eq!(
            p.take_declared_state(),
            None,
            "unknown values must be ignored"
        );
        p.feed(b"\x1b]gpty_state=failed\x07");
        assert_eq!(
            p.take_declared_state(),
            Some(crate::agent_state::AgentState::Failed)
        );
    }

    #[test]
    fn osc_state_declaration_single_shot() {
        use crate::agent_state::AgentState;
        let mut p = LineParser::new();
        p.feed(b"\x1b]gpty_state=working\x07\x1b]gpty_state=failed\x07");
        assert_eq!(
            p.take_declared_state(),
            Some(AgentState::Working),
            "only the first declaration in a parse applies"
        );
        assert_eq!(
            p.take_declared_state(),
            None,
            "declaration is consumed once"
        );
    }

    #[test]
    fn osc_other_sequences_still_stripped() {
        let mut p = LineParser::new();
        let lines = p.feed(b"\x1b]0;mytitle\x07prompt$\n");
        assert_eq!(lines, vec!["prompt$"]);
        assert_eq!(p.take_declared_state(), None);
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
