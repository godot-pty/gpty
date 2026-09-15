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
//! - Commits the buffer on `\n` (LF); a bare `\r` stashes it (CRLF pairs
//!   and prompt reprints are resolved by the bytes that follow)
//! - Discards all CSI, OSC, ESC, and DCS sequences — with one exception:
//!   cursor moves that advance the row (CUP to another row, CUD, CNL)
//!   commit the pending line, because ConPTY renders line breaks as cursor
//!   positioning without LF (see [`Handler`]).
//!
//! This is ~80 lines total — far simpler than a full terminal emulator,
//! and sufficient for regex-based concept triggering.

use vte::{Params, Parser, Perform};

/// Strips ANSI escape sequences from a PTY byte stream and extracts
/// completed lines of visible text for regex matching.
pub struct LineParser {
    parser: Parser,
    handler: Handler,
    /// Bytes consumed by the OSC sequence currently open, if any.
    osc_len: Option<usize>,
    /// The previous byte was an ESC: outside a sequence it may introduce an
    /// OSC (`ESC ]`), inside one it may start the string terminator (`ESC \`).
    osc_pending_esc: bool,
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
            osc_len: None,
            osc_pending_esc: false,
        }
    }

    /// Feed raw PTY bytes into the parser.
    ///
    /// The stream is watched for an OSC sequence that never terminates. vte's
    /// `std` build (which alacritty forces on) keeps OSC bytes in an unbounded
    /// `Vec` — its 1 KiB `MAX_OSC_RAW` cap exists only in the no_std ArrayVec
    /// build — so a truncated title, a malformed hyperlink, or
    /// `printf '\033]0;'` followed by endless output would accumulate memory
    /// for as long as the stream continues, and no later text would ever be
    /// parsed because the parser would still be inside the string. Past the
    /// budget the sequence is closed with a BEL, which vte handles as a string
    /// terminator, and parsing continues normally.
    pub fn feed(&mut self, bytes: &[u8]) -> Vec<String> {
        let mut flushed = 0usize;
        for (i, &byte) in bytes.iter().enumerate() {
            match self.osc_len {
                Some(len) => {
                    self.osc_len = Some(len + 1);
                    if byte == 0x07 || byte == 0x18 || byte == 0x1a {
                        // String terminators: BEL, CAN, SUB.
                        self.osc_len = None;
                    } else if byte == 0x1b {
                        self.osc_pending_esc = true;
                    } else if self.osc_pending_esc {
                        self.osc_pending_esc = false;
                        if byte == b'\\' {
                            self.osc_len = None; // ST
                        }
                    }
                    if self.osc_len.is_some_and(|n| n > MAX_OSC_BYTES) {
                        self.parser.advance(&mut self.handler, &bytes[flushed..=i]);
                        self.parser.advance(&mut self.handler, &[0x07]);
                        flushed = i + 1;
                        self.osc_len = None;
                        self.osc_pending_esc = false;
                    }
                }
                None => {
                    if self.osc_pending_esc {
                        self.osc_pending_esc = false;
                        if byte == b']' {
                            self.osc_len = Some(0);
                            continue;
                        }
                    }
                    if byte == 0x1b {
                        self.osc_pending_esc = true;
                    }
                }
            }
        }
        if flushed < bytes.len() {
            self.parser.advance(&mut self.handler, &bytes[flushed..]);
        }
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

/// Bytes an OSC sequence may accumulate before the parser forces it closed.
/// Sized well above any legitimate title or hyperlink, and small enough that
/// a malformed sequence cannot hold meaningful memory.
const MAX_OSC_BYTES: usize = 64 * 1024;

/// Private vte handler that collects printable text and ignores everything else.
///
/// One class of CSI is interpreted: cursor moves that advance the row
/// (`CUP`/`HVP` to a different row, `CUD`, `CNL`). ConPTY renders command
/// output lines as text followed by the cursor moving to the next row —
/// with no LF — so a discard-only parser that ignored positioning merged
/// every output line with the following prompt into one buffer that never
/// committed (windows-smoke: `pane-read` showed the output line, pane-wait
/// never matched it). Same-row moves do not commit — they are prompt
/// redraws and progress-bar updates, which must keep the LF/CR semantics
/// above.
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
    /// 1-based cursor row, tracked across CSI cursor moves (see above).
    cursor_row: usize,
}

impl Default for Handler {
    fn default() -> Self {
        Self {
            current_line: String::new(),
            completed_lines: Vec::new(),
            cr_stash: None,
            declared_state: None,
            cursor_row: 1,
        }
    }
}

impl Handler {
    /// Commit the pending line when a downward cursor move ends it. Unlike
    /// LF, this does not commit empty buffers — positioning noise would
    /// otherwise stamp blank history rows.
    fn commit_if_nonempty(&mut self) {
        if let Some(stashed) = self.cr_stash.take() {
            if !stashed.is_empty() {
                self.completed_lines.push(stashed);
            }
        } else if !self.current_line.is_empty() {
            self.completed_lines
                .push(std::mem::take(&mut self.current_line));
        }
    }
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
            // Carriage-return: stash, never commit (see cr_stash doc). A
            // repeated CR keeps the first stash: ConPTY emits `\r\r\n` for
            // some line ends, and re-stashing would clobber the text with
            // the now-empty buffer, turning the completed line into "".
            b'\r' if self.cr_stash.is_none() => {
                self.cr_stash = Some(std::mem::take(&mut self.current_line));
            }
            // BEL, BS, HT, VT, FF — ignore.
            _ => {}
        }
    }

    // ── Escape sequence handlers ──────────────────────────────────────
    // Discard-only, with one interpreted class in `csi_dispatch` (see the
    // Handler doc); OSC carries the single whitelisted agent-state
    // declaration; everything else is stripped.

    /// CSI: `ESC [` — the one class interpreted beyond discard: cursor
    /// moves that advance the row commit the pending line (see the Handler
    /// doc — ConPTY line breaks carry no LF). Same-row moves never commit.
    fn csi_dispatch(&mut self, params: &Params, _intermediates: &[u8], ignore: bool, action: char) {
        if ignore {
            return;
        }
        match action {
            // CUP / HVP — `ESC[row;colH`. A row CHANGE is a line break;
            // same-row repositioning (prompt redraw, progress bar) is not.
            'H' | 'f' => {
                let row = params
                    .iter()
                    .next()
                    .and_then(|sub| sub.first().copied())
                    .filter(|r| *r != 0)
                    .unwrap_or(1) as usize;
                if row != self.cursor_row {
                    self.commit_if_nonempty();
                    self.cursor_row = row;
                }
            }
            // CUD / CNL — `ESC[nB` / `ESC[nE`: move down n rows. n > 0 is
            // always a line advance.
            'B' | 'E' => {
                let n = params
                    .iter()
                    .next()
                    .and_then(|sub| sub.first().copied())
                    .filter(|r| *r != 0)
                    .unwrap_or(1) as usize;
                if n > 0 {
                    self.commit_if_nonempty();
                    self.cursor_row = self.cursor_row.saturating_add(n);
                }
            }
            _ => {}
        }
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
    fn unterminated_osc_does_not_swallow_the_stream() {
        // vte keeps OSC bytes in an unbounded Vec under `std`, so a sequence
        // that never terminates used to grow memory forever and leave the
        // parser stuck inside the string — every later byte was swallowed as
        // OSC content instead of being parsed as output.
        let mut p = LineParser::new();
        let mut input = b"\x1b]0;".to_vec();
        input.extend(std::iter::repeat_n(b'x', MAX_OSC_BYTES + 16));
        input.extend_from_slice(b"visible line\n");

        let lines = p.feed(&input);
        assert!(
            lines.iter().any(|l| l.contains("visible line")),
            "text after an unterminated OSC must still be parsed: {lines:?}"
        );
    }

    #[test]
    fn terminated_osc_is_stripped_normally() {
        // The watchdog must not disturb ordinary OSC traffic.
        let mut p = LineParser::new();
        let lines = p.feed(b"\x1b]0;window title\x07hello\n");
        assert_eq!(lines, vec!["hello".to_string()]);
    }

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
    fn cr_cr_lf_keeps_the_line() {
        // ConPTY emits `\r\r\n` for some line ends; the second CR must not
        // clobber the stashed text with the emptied buffer — the line used
        // to complete as "" (windows-smoke failure class).
        let mut p = LineParser::new();
        assert_eq!(p.feed(b"SMOKE_7X9Q2\r\r\n"), vec!["SMOKE_7X9Q2"]);
    }

    #[test]
    fn bare_cr_reprint_does_not_commit() {
        // The SIGWINCH prompt reprint: `\r ESC[K \r prompt`. The first CR
        // stashes, EL is discarded, the second CR keeps the stash, and the
        // prompt printables discard it — nothing commits until the LF.
        let mut p = LineParser::new();
        assert!(p.feed(b"old line\r\x1b[K\rprompt$ ").is_empty());
        assert_eq!(p.feed(b"\n"), vec!["prompt$ "]);
    }

    #[test]
    fn cursor_down_commits_the_line_without_lf() {
        // ConPTY renders output lines with a cursor move to the next row
        // and no LF; the parser must commit on the row change.
        let mut p = LineParser::new();
        assert_eq!(p.feed(b"SMOKE_7X9Q2\r\x1b[5;1H"), vec!["SMOKE_7X9Q2"]);
        // The prompt that follows accumulates into the next (uncommitted) line.
        assert!(p.feed(b"C:\\dir>").is_empty());
    }

    #[test]
    fn cud_and_cnl_commit() {
        let mut p = LineParser::new();
        assert_eq!(p.feed(b"a\x1b[1B"), vec!["a"]);
        assert_eq!(p.feed(b"b\x1b[2E"), vec!["b"]);
    }

    #[test]
    fn same_row_cup_does_not_commit() {
        // Same-row repositioning (prompt redraw, progress bar) must not
        // stamp a history row — the reprint contract depends on it.
        let mut p = LineParser::new();
        assert_eq!(
            p.feed(b"progress \x1b[1;1Hupdate\n"),
            vec!["progress update"]
        );
    }

    #[test]
    fn conpty_transaction_commits_output_and_prompt_separately() {
        // The windows-smoke shape: the command echo (CRLF), then the output
        // line ending in `\r` + CUP to the next row, then the prompt — which
        // must NOT merge into the committed output line.
        let mut p = LineParser::new();
        let lines = p.feed(b"C:\\>echo SMOKE\r\nSMOKE\r\x1b[2;1HC:\\>");
        assert_eq!(lines, vec!["C:\\>echo SMOKE", "SMOKE"]);
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
