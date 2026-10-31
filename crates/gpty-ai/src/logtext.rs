//! A backend child's stderr, made fit to log and to show.
//!
//! The agent CLIs gPTY runs (`omp --mode rpc`, any `cli` adapter) are third
//! party programs, and what they write to stderr can be a prompt, a path, a
//! fragment of an answer or a credential in an error message - gPTY cannot
//! know. Policy (AGENTS.md, SECURITY.md): a program's output is never logged
//! above `debug` and is never written to a file by default, so both backends
//! log their stderr at `debug`, and this module is the one place that decides
//! what a *line* of it may contain: no terminal control sequences, one line,
//! a bounded size.
//!
//! The bounded tail is the other half of that trade: with the lines out of the
//! log, a start-up failure that names what the child said is the only place a
//! user can still see it, and `cli` already kept one for its exit-status error.
//! [`StderrTail`] is that ring for both backends, filled from a single
//! [`spawn_drain`].

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use tokio::io::{AsyncReadExt, BufReader};
use tokio::process::ChildStderr;

/// Byte cap for one sanitized line.
///
/// Long enough for a real error message and short enough that a program which
/// prints a whole file to stderr cannot push it into a log line or an event
/// envelope. Also the per-line cap of the retained tail.
pub const MAX_LINE_BYTES: usize = 2048;

/// Lines kept for the failure message a caller shows.
pub const MAX_TAIL_LINES: usize = 20;

/// Marker appended when a line is cut, so a reader can tell it happened.
const TRUNCATED: &str = " [truncated]";

/// Strip what must not reach a log or a pane, and bound the result.
///
/// Dropped: every C0 control except tab (so a progress bar's `\r` and a stray
/// BEL cannot rewrite a log line), DEL, and escape sequences - CSI (`ESC [`
/// through its final byte), OSC (`ESC ]` through BEL or `ESC \`) and the
/// two-character forms. Kept: ordinary text and tabs, cut at
/// [`MAX_LINE_BYTES`] on a char boundary.
///
/// This is *not* an ANSI evaluator and must not become one: the line is
/// untrusted, so the only safe answer is to remove the sequences, never to
/// interpret them.
pub fn sanitize(line: &str) -> String {
    let mut out = String::with_capacity(line.len().min(MAX_LINE_BYTES));
    let mut chars = line.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\x1b' => skip_escape(&mut chars),
            '\t' => out.push('\t'),
            c if c.is_control() => {}
            c => out.push(c),
        }
    }
    bounded(&out)
}

/// Cut `text` to [`MAX_LINE_BYTES`], marking the cut, on a char boundary.
fn bounded(text: &str) -> String {
    if text.len() <= MAX_LINE_BYTES {
        return text.to_owned();
    }
    let budget = MAX_LINE_BYTES - TRUNCATED.len();
    let mut end = budget;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}{TRUNCATED}", &text[..end])
}

/// Consume one escape sequence, having already consumed its `ESC`.
fn skip_escape(chars: &mut std::iter::Peekable<std::str::Chars<'_>>) {
    match chars.peek() {
        Some('[') => {
            // CSI: parameter/intermediate bytes, then one byte in 0x40..=0x7e.
            chars.next();
            while let Some(&c) = chars.peek() {
                chars.next();
                if ('\x40'..='\x7e').contains(&c) {
                    break;
                }
            }
        }
        Some(']') => {
            // OSC: a payload terminated by BEL or ST (`ESC \`). Unterminated,
            // it runs to the end of the line, which is what the child sent.
            chars.next();
            while let Some(c) = chars.next() {
                if c == '\x07' {
                    break;
                }
                if c == '\x1b' {
                    if chars.peek() == Some(&'\\') {
                        chars.next();
                    }
                    break;
                }
            }
        }
        // A two-character sequence (`ESC c`, `ESC (B`, …) or a lone `ESC`.
        Some(_) => {
            chars.next();
        }
        None => {}
    }
}

/// The last few sanitized stderr lines, for a failure message.
///
/// One per backend process: `cli` answers a non-zero exit with it, `omp`
/// appends it when the start-up handshake fails. Bounded in both directions
/// (`MAX_TAIL_LINES`, each line by [`MAX_LINE_BYTES`]).
#[derive(Default)]
pub struct StderrTail {
    lines: Mutex<VecDeque<String>>,
}

impl StderrTail {
    pub fn new() -> Self {
        Self::default()
    }

    /// Keep one already-sanitized line (oldest dropped at the cap).
    pub fn push(&self, line: &str) {
        if let Ok(mut lines) = self.lines.lock() {
            if lines.len() == MAX_TAIL_LINES {
                lines.pop_front();
            }
            lines.push_back(line.to_owned());
        }
    }

    /// The retained lines joined for one message; empty when the child said
    /// nothing.
    pub fn summary(&self) -> String {
        match self.lines.lock() {
            Ok(lines) => lines.iter().cloned().collect::<Vec<_>>().join(" | "),
            Err(_) => String::new(),
        }
    }
}

/// Keep a child's stderr pipe drained for its whole life, sanitizing each line.
///
/// The pipe has to be read continuously. Once the kernel buffer (~64 KiB)
/// fills, the child blocks on its next stderr write and can never finish the
/// turn - it stalls until the caller's frame timeout fires, and the failure
/// surfaces as "stopped emitting frames" instead of the child's own error.
/// `wait()` does not drain it; only a reader that keeps up does.
///
/// `label` names the backend in the log line. Every line goes to `debug`:
/// a program's output is not log material (see the module docs) and the
/// retained tail is what a failure message shows.
pub fn spawn_drain(
    stderr: ChildStderr,
    label: &'static str,
    tail: Arc<StderrTail>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut reader = BufReader::new(stderr);
        let mut buffer = [0_u8; 4096];
        loop {
            match reader.read(&mut buffer).await {
                Ok(0) | Err(_) => break,
                Ok(count) => {
                    // Lossy: a non-UTF-8 child must not stop the drain, and a
                    // chunk boundary may split a line in two.
                    let text = String::from_utf8_lossy(&buffer[..count]);
                    for line in text.lines() {
                        let line = sanitize(line);
                        // log-ok: stripped of control sequences and bounded to
                        // MAX_LINE_BYTES by `sanitize`, and at debug - the level
                        // the GDExtension logger drops.
                        log::debug!("{label} stderr: {line}");
                        tail.push(&line);
                    }
                }
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_text_is_kept() {
        assert_eq!(
            sanitize("error: no model configured"),
            "error: no model configured"
        );
        assert_eq!(
            sanitize("a\tb"),
            "a\tb",
            "tabs stay, they cannot rewrite a line"
        );
    }

    /// A colour code or a progress bar is the child's rendering, not text.
    #[test]
    fn escape_sequences_and_control_characters_are_removed() {
        assert_eq!(sanitize("\x1b[31merror\x1b[0m: bad"), "error: bad");
        assert_eq!(
            sanitize("50%\r100%"),
            "50%100%",
            "a CR must not rewind the log line"
        );
        assert_eq!(sanitize("bell\x07"), "bell");
        assert_eq!(
            sanitize("\x1b]0;title\x07text"),
            "text",
            "an OSC title is dropped"
        );
        assert_eq!(
            sanitize("\x1b]8;;http://x\x1b\\link"),
            "link",
            "an OSC 8 hyperlink is dropped"
        );
        assert_eq!(sanitize("del\x7f"), "del");
        assert_eq!(sanitize("\x1b"), "", "a lone ESC disappears");
    }

    /// The cap is the row's contract: a backend that prints a whole file to
    /// stderr must not put a whole file into a log line or an error message.
    #[test]
    fn a_long_line_is_truncated_at_the_cap() {
        let long = "x".repeat(MAX_LINE_BYTES * 3);
        let out = sanitize(&long);
        assert_eq!(out.len(), MAX_LINE_BYTES, "the cut lands on the cap");
        assert!(out.ends_with(TRUNCATED), "and says it was cut: {out}");
        assert_eq!(
            out.chars().filter(|c| *c == 'x').count(),
            MAX_LINE_BYTES - TRUNCATED.len()
        );
    }

    /// Cutting must never split a char: the result is a String, not bytes.
    #[test]
    fn truncation_lands_on_a_char_boundary() {
        let long = "é".repeat(MAX_LINE_BYTES);
        let out = sanitize(&long);
        assert!(out.len() <= MAX_LINE_BYTES);
        assert!(
            out.is_char_boundary(out.len()),
            "valid UTF-8 with the marker"
        );
        assert!(out.ends_with(TRUNCATED));
    }

    #[test]
    fn the_tail_is_bounded_and_ordered() {
        let tail = StderrTail::new();
        for n in 0..MAX_TAIL_LINES + 5 {
            tail.push(&format!("line {n}"));
        }
        let summary = tail.summary();
        assert!(
            summary.starts_with("line 5 | "),
            "the oldest lines are dropped: {summary}"
        );
        assert!(summary.ends_with(&format!("line {}", MAX_TAIL_LINES + 4)));
        assert_eq!(summary.matches(" | ").count(), MAX_TAIL_LINES - 1);
    }

    #[test]
    fn an_empty_tail_summarizes_to_nothing() {
        assert_eq!(StderrTail::new().summary(), "");
    }
}
