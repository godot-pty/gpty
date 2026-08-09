//! Keyboard-to-escape-sequence mapping.
//!
//! Converts hardware scancodes + modifier masks into xterm-compatible
//! escape sequences suitable for writing to a PTY.
//!
//! ## Key codes
//!
//! Uses Linux evdev scancodes (the same codes returned by
//! `/usr/include/linux/input-event-codes.h`). The CLI demo reads these
//! from `termion`/`crossterm`; the Godot FFI layer translates Godot
//! `KEY_*` constants into evdev codes before calling into this module.
//!
//! ## References
//!
//! - xterm modified-keys: <https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h2-PC-Style-Function-Keys>
//! - kitty keyboard protocol: <https://sw.kovidgoyal.net/kitty/keyboard-protocol/>

/// Modifier bitmask.
///
/// Multiple modifiers are combined with bitwise OR.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Modifiers(pub u8);

impl Modifiers {
    pub const SHIFT: u8 = 1;
    pub const ALT: u8 = 2;
    pub const CTRL: u8 = 4;
    pub const SUPER: u8 = 8;

    /// Build the xterm CSI modifier parameter (2–8).
    ///
    /// Returns `None` if no modifiers are active (parameter is omitted).
    fn xterm_param(self) -> Option<&'static str> {
        match self.0 & 0xF {
            0 => None,
            1 => Some(";2"),  // Shift
            2 => Some(";3"),  // Alt
            3 => Some(";4"),  // Shift+Alt
            4 => Some(";5"),  // Ctrl
            5 => Some(";6"),  // Ctrl+Shift
            6 => Some(";7"),  // Ctrl+Alt
            7 => Some(";8"),  // Ctrl+Alt+Shift
            _ => None,
        }
    }

    #[inline]
    pub fn has_ctrl(self) -> bool { self.0 & Self::CTRL != 0 }
    #[inline]
    pub fn has_alt(self) -> bool { self.0 & Self::ALT != 0 }
    #[inline]
    pub fn has_shift(self) -> bool { self.0 & Self::SHIFT != 0 }
}

// ── evdev scancode constants ─────────────────────────────────────────

/// Numpad Enter (evdev 96).
const KP_ENTER: u32 = 96;
/// Numpad / (evdev 98).
const KP_DIVIDE: u32 = 98;
/// Numpad * (evdev 55).
const KP_MULTIPLY: u32 = 55;
/// Numpad - (evdev 74).
const KP_SUBTRACT: u32 = 74;
/// Numpad + (evdev 78).
const KP_ADD: u32 = 78;
/// Numpad . / Del (evdev 83).
const KP_DECIMAL: u32 = 83;

/// Convert a hardware scancode + modifiers into the raw bytes that
/// should be written to the PTY.
///
/// Returns `None` for keys that should be handled by the caller (e.g.
/// plain printable characters, which are delivered via the Unicode path).
///
/// # Examples
///
/// ```
/// # use gpty_core::keymap::{key_event_to_bytes, Modifiers};
/// assert_eq!(key_event_to_bytes(103, Modifiers::CTRL), Some(b"\x1b[1;5A".to_vec()));
/// assert_eq!(key_event_to_bytes(1, 0), Some(b"\x1b".to_vec()));
/// assert_eq!(key_event_to_bytes(30, 0), None); // 'a' → unicode path
/// ```
pub fn key_event_to_bytes(scancode: u32, modifiers: u8) -> Option<Vec<u8>> {
    let m = Modifiers(modifiers);
    let param = m.xterm_param();

    match scancode {
        // ── Special control chars ───────────────────────────────
        1 => Some(b"\x1b".to_vec()),                       // Escape
        14 => Some(b"\x7f".to_vec()),                       // Backspace
        15 if m.has_shift() => Some(b"\x1b[Z".to_vec()),   // Shift+Tab
        15 => Some(b"\t".to_vec()),                         // Tab
        28 => Some(b"\r".to_vec()),                         // Enter
        // ── Arrow keys ────────────────────────────────────────
        103 => xterm_csi("A", param),  // Up
        108 => xterm_csi("B", param),  // Down
        106 => xterm_csi("C", param),  // Right
        105 => xterm_csi("D", param),  // Left

        // ── Navigation ────────────────────────────────────────
        102 => xterm_csi("H", param),  // Home
        107 => xterm_csi("F", param),  // End
        104 => xterm_csi("5~", param), // PageUp
        109 => xterm_csi("6~", param), // PageDown
        110 => xterm_csi("2~", param), // Insert
        111 => xterm_csi("3~", param), // Delete

        // ── Function keys ─────────────────────────────────────
        59 => xterm_csi("P", param),   // F1
        60 => xterm_csi("Q", param),   // F2
        61 => xterm_csi("R", param),   // F3
        62 => xterm_csi("S", param),   // F4
        63 => xterm_csi("15~", param), // F5
        64 => xterm_csi("17~", param), // F6
        65 => xterm_csi("18~", param), // F7
        66 => xterm_csi("19~", param), // F8
        67 => xterm_csi("20~", param), // F9
        68 => xterm_csi("21~", param), // F10
        87 => xterm_csi("23~", param), // F11
        88 => xterm_csi("24~", param), // F12

        // ── Numpad ────────────────────────────────────────────
        // Numpad keys produce distinct escape sequences when NumLock is off
        // (application keypad mode) vs. when it's on (same as regular keys).
        // In application mode (DECPNM / DECKPAM), they send SS3 sequences.
        // We assume application keypad mode here — the application can toggle.
        71 => Some(b"\x1bOq".to_vec()),  // KP_Home  / KP_7
        72 => Some(b"\x1bOr".to_vec()),  // KP_Up    / KP_8
        73 => Some(b"\x1bOs".to_vec()),  // KP_PgUp  / KP_9
        75 => Some(b"\x1bOt".to_vec()),  // KP_Left  / KP_4
        76 => Some(b"\x1bOu".to_vec()),  // KP_Begin / KP_5
        77 => Some(b"\x1bOv".to_vec()),  // KP_Right / KP_6
        79 => Some(b"\x1bOw".to_vec()),  // KP_End   / KP_1
        80 => Some(b"\x1bOx".to_vec()),  // KP_Down  / KP_2
        81 => Some(b"\x1bOy".to_vec()),  // KP_PgDn  / KP_3
        82 => Some(b"\x1bOp".to_vec()),  // KP_Insert/ KP_0
        KP_DECIMAL => Some(b"\x1bOn".to_vec()),  // KP_Del   / KP_.
        KP_ENTER => Some(b"\x1bOM".to_vec()),
        KP_DIVIDE => Some(b"\x1bOo".to_vec()),
        KP_MULTIPLY => Some(b"\x1bOj".to_vec()),
        KP_SUBTRACT => Some(b"\x1bOm".to_vec()),
        KP_ADD => Some(b"\x1bOk".to_vec()),

        // ── Misc ───────────────────────────────────────────────
        119 => Some(b"\x1b".to_vec()),   // Pause/Break → ESC
        57 if m.has_ctrl() => Some(b"\0".to_vec()),  // Ctrl+Space → NUL

        // ── Alt+printable: emit ESC prefix + char ─────────────
        _ if m.has_alt() && !m.has_ctrl() => None, // Let caller prepend ESC

        // Everything else → caller handles (Unicode path)
        _ => None,
    }
}

/// Build a CSI sequence `\e[{param}{suffix}`.
fn xterm_csi(suffix: &str, param: Option<&str>) -> Option<Vec<u8>> {
    let mut v = Vec::with_capacity(3 + suffix.len() + param.map(|p| p.len()).unwrap_or(0));
    v.push(0x1b);
    v.push(b'[');
    if let Some(p) = param {
        // Always emit "1" prefix when modifiers are present
        v.extend(b"1");
        v.extend(p.as_bytes());
    }
    v.extend(suffix.as_bytes());
    Some(v)
}
// Tests
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    fn esc(seq: &[u8]) -> Vec<u8> {
        [b"\x1b", seq].concat()
    }

    #[test]
    fn basic_special_keys() {
        assert_eq!(key_event_to_bytes(1, 0), Some(b"\x1b".to_vec()));          // Escape
        assert_eq!(key_event_to_bytes(14, 0), Some(b"\x7f".to_vec()));         // Backspace
        assert_eq!(key_event_to_bytes(15, 0), Some(b"\t".to_vec()));           // Tab
        assert_eq!(key_event_to_bytes(28, 0), Some(b"\r".to_vec()));           // Enter
        assert_eq!(key_event_to_bytes(15, Modifiers::SHIFT), Some(b"\x1b[Z".to_vec())); // Shift+Tab
    }

    #[test]
    fn ctrl_combinations() {
        assert_eq!(key_event_to_bytes(57, Modifiers::CTRL), Some(b"\0".to_vec()));   // Ctrl+Space
        // Ctrl+digit is not standard terminal behavior — falls through to unicode path
        assert_eq!(key_event_to_bytes(2, Modifiers::CTRL), None);                     // Ctrl+1
        assert_eq!(key_event_to_bytes(11, Modifiers::CTRL), None);                    // Ctrl+0
        // Ctrl+Alt+digit: Ctrl takes precedence, but still falls through
        assert_eq!(key_event_to_bytes(2, Modifiers::CTRL | Modifiers::ALT), None);
    }

    #[test]
    fn arrow_keys() {
        assert_eq!(key_event_to_bytes(103, 0),                  Some(esc(b"[A")));   // Up
        assert_eq!(key_event_to_bytes(103, Modifiers::CTRL),    Some(esc(b"[1;5A"))); // Ctrl+Up
        assert_eq!(key_event_to_bytes(103, Modifiers::SHIFT),   Some(esc(b"[1;2A"))); // Shift+Up
        assert_eq!(key_event_to_bytes(105, Modifiers::CTRL | Modifiers::ALT),
                   Some(esc(b"[1;7D"))); // Ctrl+Alt+Left
    }

    #[test]
    fn navigation_keys() {
        assert_eq!(key_event_to_bytes(102, 0),               Some(esc(b"[H")));     // Home
        assert_eq!(key_event_to_bytes(102, Modifiers::CTRL), Some(esc(b"[1;5H")));  // Ctrl+Home
        assert_eq!(key_event_to_bytes(107, 0),               Some(esc(b"[F")));     // End
        assert_eq!(key_event_to_bytes(111, 0),               Some(esc(b"[3~")));    // Delete
        assert_eq!(key_event_to_bytes(110, 0),               Some(esc(b"[2~")));    // Insert
    }

    #[test]
    fn function_keys() {
        assert_eq!(key_event_to_bytes(59, 0), Some(esc(b"[P")));      // F1
        assert_eq!(key_event_to_bytes(63, 0), Some(esc(b"[15~")));    // F5
        assert_eq!(key_event_to_bytes(88, 0), Some(esc(b"[24~")));    // F12
        assert_eq!(key_event_to_bytes(59, Modifiers::CTRL), Some(esc(b"[1;5P")));  // Ctrl+F1
    }

    #[test]
    fn numpad_application_mode() {
        assert_eq!(key_event_to_bytes(71, 0), Some(esc(b"Oq")));  // KP_Home / KP_7
        assert_eq!(key_event_to_bytes(72, 0), Some(esc(b"Or")));  // KP_Up / KP_8
        assert_eq!(key_event_to_bytes(KP_ENTER, 0), Some(esc(b"OM")));
        assert_eq!(key_event_to_bytes(KP_ADD, 0), Some(esc(b"Ok")));
    }

    #[test]
    fn unicode_path_none() {
        // Printable characters without modifiers → None (caller handles via unicode)
        assert_eq!(key_event_to_bytes(30, 0), None);   // 'a'
        assert_eq!(key_event_to_bytes(57, 0), None);   // Space
        assert_eq!(key_event_to_bytes(16, 0), None);   // 'q'
    }

    #[test]
    fn alt_prefix_none() {
        // Alt without Ctrl → caller should prepend ESC + char
        assert_eq!(key_event_to_bytes(30, Modifiers::ALT), None);  // Alt+a
    }
}
