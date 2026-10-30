//! Bounds the escape-string state a byte stream can accumulate.
//!
//! `vte` keeps an OSC string's payload in a `Vec` that grows until the string
//! terminates — its 1 KiB `MAX_OSC_RAW` cap exists only in the `no_std`
//! build, which `alacritty_terminal` does not use. A program that writes
//! `ESC ]` and then never closes the string therefore grows the reader's
//! memory at the speed it can write. Every consumer of the PTY byte stream —
//! the terminal grid in [`crate::term`] and the plain-text line parser in
//! [`crate::parser`] — puts this guard in front of its parser: bytes pass
//! through unchanged, and a string that passes the budget is closed with a
//! terminator so its payload stays finite and parsing resumes.
//!
//! # Only OSC is counted, because only OSC buffers
//!
//! Measured 2026-10-30 by feeding a grid `intro` + 256 × 1 MiB of `x`:
//! OSC (`ESC ]`) grew resident memory 3.3 MB → 267 MB, while DCS (`ESC P`),
//! APC (`ESC _`), PM (`ESC ^`) and SOS (`ESC X`) stayed flat. `vte` routes
//! those four through `Perform::put`, which `alacritty_terminal` ignores, so
//! their payload never accumulates; only `Parser::osc_raw` grows. Counting
//! them would cut legitimate sixel/kitty payloads that are currently read and
//! discarded, so the budget is applied to OSC alone. If a future `vte` starts
//! buffering another kind, the bound test in `tests/escape_string_bound.rs`
//! fails and says so.
//!
//! # Framing
//!
//! The state machine is the subset of `vte`'s needed to know when an OSC
//! string starts and ends, so the guard's idea of "inside a string" never
//! disagrees with the parser behind it: a string opens on `ESC ]`
//! (split across feeds is fine — the ESC is remembered), and closes on BEL,
//! CAN, SUB, or ESC. ESC is the interesting one: `vte` ends the OSC there and
//! dispatches what it has, then treats the next byte as the start of a new
//! sequence — which may itself be `ESC ]`. The guard does the same, so an
//! `ESC [` inside a string is a CSI that resumes normal parsing rather than
//! payload the guard keeps counting.

/// Bytes an OSC string may accumulate before [`EscapeStringGuard`] forces it
/// closed. Sized well above any legitimate title, hyperlink or colour
/// assignment, and small enough that a malformed sequence cannot hold
/// meaningful memory: the payload is cut just past this budget, so the worst
/// case is one chunk (`pty::READ_BUF_SIZE`) over.
pub const MAX_ESCAPE_STRING_BYTES: usize = 64 * 1024;

/// Byte injected to close an over-long string: BEL is a string terminator to
/// `vte`, and in the ground state it is only a bell, so it cannot corrupt a
/// parser that has already left the string.
const TERMINATOR: u8 = 0x07;

/// Passes a PTY byte stream through unchanged while bounding any OSC string
/// in it. See the module docs for why only OSC is counted.
#[derive(Debug, Default)]
pub struct EscapeStringGuard {
    /// Payload bytes consumed by the OSC string currently open, if any.
    osc_len: Option<usize>,
    /// The previous byte was an ESC: outside a string it may introduce an OSC
    /// (`ESC ]`), inside one it may start the string terminator (`ESC \`).
    pending_esc: bool,
}

impl EscapeStringGuard {
    pub fn new() -> Self {
        Self::default()
    }

    /// Feed `bytes` to `sink` in order, injecting [`TERMINATOR`] whenever the
    /// open string passes `budget` payload bytes. Every byte of `bytes` reaches
    /// `sink` exactly once; the only bytes added are terminators.
    pub fn feed(&mut self, bytes: &[u8], budget: usize, mut sink: impl FnMut(&[u8])) {
        let mut start = 0;
        for (i, &byte) in bytes.iter().enumerate() {
            if let Some(len) = self.osc_len {
                self.osc_len = Some(len + 1);
                match byte {
                    // BEL, CAN and SUB all terminate an OSC string in `vte`.
                    0x07 | 0x18 | 0x1a => self.osc_len = None,
                    // ESC ends the string (dispatching the payload so far) and
                    // starts a new sequence, whose introducer the next byte is.
                    0x1b => {
                        self.osc_len = None;
                        self.pending_esc = true;
                    }
                    _ => {}
                }
                if self.osc_len.is_some_and(|n| n > budget) {
                    sink(&bytes[start..=i]);
                    sink(&[TERMINATOR]);
                    self.osc_len = None;
                    self.pending_esc = false;
                    start = i + 1;
                }
            } else if self.pending_esc {
                self.pending_esc = false;
                if byte == b']' {
                    self.osc_len = Some(0);
                }
            } else if byte == 0x1b {
                self.pending_esc = true;
            }
        }
        if start < bytes.len() {
            sink(&bytes[start..]);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Run `input` through the guard in chunks of `chunk` bytes and return the
    /// concatenation of every slice the sink saw.
    fn run_chunked(input: &[u8], budget: usize, chunk: usize) -> Vec<u8> {
        let mut guard = EscapeStringGuard::new();
        let mut out = Vec::new();
        for piece in input.chunks(chunk.max(1)) {
            guard.feed(piece, budget, |slice| out.extend_from_slice(slice));
        }
        out
    }

    /// An unterminated OSC with an 8-byte budget: the terminator lands right
    /// after the ninth payload byte, whatever the chunk boundaries.
    #[test]
    fn terminator_lands_at_the_budget_for_every_split() {
        let mut input = b"\x1b]0;".to_vec();
        input.extend(std::iter::repeat_n(b'x', 40));
        // The payload count starts at the introducer, so it includes "0;":
        // the ninth payload byte is input[2 + 8], and the terminator follows.
        let mut expected = input[..=10].to_vec();
        expected.push(TERMINATOR);
        expected.extend_from_slice(&input[11..]);

        for split in 0..=input.len() {
            let mut guard = EscapeStringGuard::new();
            let mut out = Vec::new();
            guard.feed(&input[..split], 8, |s| out.extend_from_slice(s));
            guard.feed(&input[split..], 8, |s| out.extend_from_slice(s));
            assert_eq!(out, expected, "two feeds split at {split}");
        }
        for chunk in 1..=input.len() {
            assert_eq!(
                run_chunked(&input, 8, chunk),
                expected,
                "chunked every {chunk} bytes"
            );
        }
    }

    /// A string that terminates inside the budget is passed through untouched.
    #[test]
    fn terminated_strings_pass_through_unchanged() {
        for terminator in [&[0x07u8][..], b"\x18", b"\x1a", b"\x1b\\"] {
            let mut input = b"before\x1b]0;title".to_vec();
            input.extend_from_slice(terminator);
            input.extend_from_slice(b"after");
            assert_eq!(run_chunked(&input, 64, 1), input);
            assert_eq!(run_chunked(&input, 64, 3), input);
        }
    }

    /// One forced close, then the rest of the stream is plain bytes: no second
    /// terminator is injected while no string is open.
    #[test]
    fn text_after_a_forced_close_is_not_touched() {
        let mut input = b"\x1b]0;".to_vec();
        input.extend(std::iter::repeat_n(b'x', 4 * 8));
        let out = run_chunked(&input, 8, 5);
        assert_eq!(out.iter().filter(|&&b| b == TERMINATOR).count(), 1);
        assert_eq!(out.len(), input.len() + 1);
    }

    /// ESC inside a string ends it, exactly as `vte` does, so an SGR sequence
    /// that follows is not mistaken for payload.
    #[test]
    fn esc_inside_a_string_ends_it() {
        let mut input = b"\x1b]0;ab\x1b[31m".to_vec();
        input.extend(std::iter::repeat_n(b'x', 64));
        assert_eq!(run_chunked(&input, 8, 7), input);
    }

    /// An introducer split from its ESC still opens the string.
    #[test]
    fn introducer_split_across_feeds_still_opens() {
        let mut input = b"\x1b]".to_vec();
        input.extend(std::iter::repeat_n(b'x', 40));
        let out = run_chunked(&input, 8, 1);
        assert_eq!(out.iter().filter(|&&b| b == TERMINATOR).count(), 1);
        assert_eq!(out.len(), input.len() + 1);
    }

    /// A bare `]` is text, not an introducer.
    #[test]
    fn bracket_without_esc_is_not_a_string() {
        let mut input = b"]".to_vec();
        input.extend(std::iter::repeat_n(b'x', 64));
        assert_eq!(run_chunked(&input, 8, 9), input);
    }
}
