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
            1 => Some(";2"), // Shift
            2 => Some(";3"), // Alt
            3 => Some(";4"), // Shift+Alt
            4 => Some(";5"), // Ctrl
            5 => Some(";6"), // Ctrl+Shift
            6 => Some(";7"), // Ctrl+Alt
            7 => Some(";8"), // Ctrl+Alt+Shift
            _ => None,
        }
    }

    #[inline]
    pub fn has_ctrl(self) -> bool {
        self.0 & Self::CTRL != 0
    }
    #[inline]
    pub fn has_alt(self) -> bool {
        self.0 & Self::ALT != 0
    }
    #[inline]
    pub fn has_shift(self) -> bool {
        self.0 & Self::SHIFT != 0
    }
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
/// `app_keypad` is the terminal's DECPAM/DECKPAM state. When false (a plain
/// shell) the numpad sends the characters printed on its keys; when true (a
/// full-screen app that enabled application keypad mode) it sends the SS3
/// sequences that app expects.
///
/// Returns `None` for keys that should be handled by the caller (e.g.
/// plain printable characters, which are delivered via the Unicode path).
///
/// # Examples
///
/// ```
/// # use gpty_core::keymap::{key_event_to_bytes, Modifiers};
/// assert_eq!(key_event_to_bytes(103, Modifiers::CTRL, false), Some(b"\x1b[1;5A".to_vec()));
/// assert_eq!(key_event_to_bytes(1, 0, false), Some(b"\x1b".to_vec()));
/// assert_eq!(key_event_to_bytes(30, 0, false), None); // 'a' → unicode path
/// assert_eq!(key_event_to_bytes(71, 0, false), Some(b"7".to_vec())); // numpad 7
/// ```
pub fn key_event_to_bytes(scancode: u32, modifiers: u8, app_keypad: bool) -> Option<Vec<u8>> {
    let m = Modifiers(modifiers);
    let param = m.xterm_param();

    match scancode {
        // ── Special control chars ───────────────────────────────
        1 => Some(b"\x1b".to_vec()),                     // Escape
        14 => Some(b"\x7f".to_vec()),                    // Backspace
        15 if m.has_shift() => Some(b"\x1b[Z".to_vec()), // Shift+Tab
        15 => Some(b"\t".to_vec()),                      // Tab
        28 => Some(b"\r".to_vec()),                      // Enter
        // ── Arrow keys ────────────────────────────────────────
        103 => xterm_csi("A", param), // Up
        108 => xterm_csi("B", param), // Down
        106 => xterm_csi("C", param), // Right
        105 => xterm_csi("D", param), // Left

        // ── Navigation ────────────────────────────────────────
        102 => xterm_csi("H", param),     // Home
        107 => xterm_csi("F", param),     // End
        104 => xterm_csi_tilde(5, param), // PageUp
        109 => xterm_csi_tilde(6, param), // PageDown
        110 => xterm_csi_tilde(2, param), // Insert
        111 => xterm_csi_tilde(3, param), // Delete

        // ── Function keys ─────────────────────────────────────
        59 => xterm_csi("P", param),      // F1
        60 => xterm_csi("Q", param),      // F2
        61 => xterm_csi("R", param),      // F3
        62 => xterm_csi("S", param),      // F4
        63 => xterm_csi_tilde(15, param), // F5
        64 => xterm_csi_tilde(17, param), // F6
        65 => xterm_csi_tilde(18, param), // F7
        66 => xterm_csi_tilde(19, param), // F8
        67 => xterm_csi_tilde(20, param), // F9
        68 => xterm_csi_tilde(21, param), // F10
        87 => xterm_csi_tilde(23, param), // F11
        88 => xterm_csi_tilde(24, param), // F12

        // ── Numpad ────────────────────────────────────────────
        // Application keypad mode (DECPAM/DECKPAM, enabled by the running
        // application) sends SS3 sequences; otherwise the numpad sends the
        // characters printed on the keys, which is what a plain shell,
        // readline or vim insert mode expects. The mode comes from the grid,
        // so a shell no longer receives ESC O q for a numpad 7.
        71 => numpad(app_keypad, b"\x1bOq", b"7"), // KP_Home  / KP_7
        72 => numpad(app_keypad, b"\x1bOr", b"8"), // KP_Up    / KP_8
        73 => numpad(app_keypad, b"\x1bOs", b"9"), // KP_PgUp  / KP_9
        75 => numpad(app_keypad, b"\x1bOt", b"4"), // KP_Left  / KP_4
        76 => numpad(app_keypad, b"\x1bOu", b"5"), // KP_Begin / KP_5
        77 => numpad(app_keypad, b"\x1bOv", b"6"), // KP_Right / KP_6
        79 => numpad(app_keypad, b"\x1bOw", b"1"), // KP_End   / KP_1
        80 => numpad(app_keypad, b"\x1bOx", b"2"), // KP_Down  / KP_2
        81 => numpad(app_keypad, b"\x1bOy", b"3"), // KP_PgDn  / KP_3
        82 => numpad(app_keypad, b"\x1bOp", b"0"), // KP_Insert/ KP_0
        KP_DECIMAL => numpad(app_keypad, b"\x1bOn", b"."), // KP_Del / KP_.
        KP_ENTER => numpad(app_keypad, b"\x1bOM", b"\r"),
        KP_DIVIDE => numpad(app_keypad, b"\x1bOo", b"/"),
        KP_MULTIPLY => numpad(app_keypad, b"\x1bOj", b"*"),
        KP_SUBTRACT => numpad(app_keypad, b"\x1bOm", b"-"),
        KP_ADD => numpad(app_keypad, b"\x1bOk", b"+"),

        // ── Misc ───────────────────────────────────────────────
        119 => Some(b"\x1b".to_vec()), // Pause/Break → ESC
        57 if m.has_ctrl() => Some(b"\0".to_vec()), // Ctrl+Space → NUL

        // ── Alt+printable: emit ESC prefix + char ─────────────
        _ if m.has_alt() && !m.has_ctrl() => None, // Let caller prepend ESC

        // Everything else → caller handles (Unicode path)
        _ => None,
    }
}

/// Build a CSI sequence `\e[{param}{suffix}` for the letter-suffixed keys
/// (arrows, Home/End, F1-F4), where xterm's modified form is
/// `\e[1;{mod}{letter}`.
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

/// Build a CSI sequence for the `~`-suffixed keys (Insert, Delete, PageUp,
/// PageDown, F5-F12), where xterm puts the key number *first*:
/// `\e[3~`, or `\e[3;5~` with modifiers.
///
/// The letter form's `1` prefix is wrong here — concatenating it with the
/// modifier and the key number produced `\e[1;53~` for Ctrl+Delete, a
/// parameter consumers read as "unknown" and ignore, so the keystroke did
/// nothing.
fn xterm_csi_tilde(num: u8, param: Option<&str>) -> Option<Vec<u8>> {
    let mut v = Vec::with_capacity(8);
    v.push(0x1b);
    v.push(b'[');
    v.extend(num.to_string().as_bytes());
    if let Some(p) = param {
        v.extend(p.as_bytes());
    }
    v.push(b'~');
    Some(v)
}

/// Numpad bytes: the SS3 sequence when the application enabled keypad mode,
/// the character printed on the key otherwise.
fn numpad(app_keypad: bool, ss3: &[u8], plain: &[u8]) -> Option<Vec<u8>> {
    Some(if app_keypad { ss3 } else { plain }.to_vec())
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
        assert_eq!(key_event_to_bytes(1, 0, false), Some(b"\x1b".to_vec())); // Escape
        assert_eq!(key_event_to_bytes(14, 0, false), Some(b"\x7f".to_vec())); // Backspace
        assert_eq!(key_event_to_bytes(15, 0, false), Some(b"\t".to_vec())); // Tab
        assert_eq!(key_event_to_bytes(28, 0, false), Some(b"\r".to_vec())); // Enter
        assert_eq!(
            key_event_to_bytes(15, Modifiers::SHIFT, false),
            Some(b"\x1b[Z".to_vec())
        ); // Shift+Tab
    }

    #[test]
    fn ctrl_combinations() {
        assert_eq!(
            key_event_to_bytes(57, Modifiers::CTRL, false),
            Some(b"\0".to_vec())
        ); // Ctrl+Space
        // Ctrl+digit is not standard terminal behavior — falls through to unicode path
        assert_eq!(key_event_to_bytes(2, Modifiers::CTRL, false), None); // Ctrl+1
        assert_eq!(key_event_to_bytes(11, Modifiers::CTRL, false), None); // Ctrl+0
        // Ctrl+Alt+digit: Ctrl takes precedence, but still falls through
        assert_eq!(
            key_event_to_bytes(2, Modifiers::CTRL | Modifiers::ALT, false),
            None
        );
    }

    #[test]
    fn arrow_keys() {
        assert_eq!(key_event_to_bytes(103, 0, false), Some(esc(b"[A"))); // Up
        assert_eq!(
            key_event_to_bytes(103, Modifiers::CTRL, false),
            Some(esc(b"[1;5A"))
        ); // Ctrl+Up
        assert_eq!(
            key_event_to_bytes(103, Modifiers::SHIFT, false),
            Some(esc(b"[1;2A"))
        ); // Shift+Up
        assert_eq!(
            key_event_to_bytes(105, Modifiers::CTRL | Modifiers::ALT, false),
            Some(esc(b"[1;7D"))
        ); // Ctrl+Alt+Left
    }

    #[test]
    fn navigation_keys() {
        assert_eq!(key_event_to_bytes(102, 0, false), Some(esc(b"[H"))); // Home
        assert_eq!(
            key_event_to_bytes(102, Modifiers::CTRL, false),
            Some(esc(b"[1;5H"))
        ); // Ctrl+Home
        assert_eq!(key_event_to_bytes(107, 0, false), Some(esc(b"[F"))); // End
        assert_eq!(key_event_to_bytes(111, 0, false), Some(esc(b"[3~"))); // Delete
        assert_eq!(key_event_to_bytes(110, 0, false), Some(esc(b"[2~"))); // Insert
    }

    #[test]
    fn function_keys() {
        assert_eq!(key_event_to_bytes(59, 0, false), Some(esc(b"[P"))); // F1
        assert_eq!(key_event_to_bytes(63, 0, false), Some(esc(b"[15~"))); // F5
        assert_eq!(key_event_to_bytes(88, 0, false), Some(esc(b"[24~"))); // F12
        assert_eq!(
            key_event_to_bytes(59, Modifiers::CTRL, false),
            Some(esc(b"[1;5P"))
        ); // Ctrl+F1
    }

    #[test]
    fn modified_tilde_keys_put_the_key_number_first() {
        // xterm's `~` family is `\e[{num};{mod}~`. Prefixing "1" — the letter
        // convention — produced `\e[1;53~` for Ctrl+Delete, which consumers
        // read as an unknown parameter and ignore.
        assert_eq!(
            key_event_to_bytes(111, Modifiers::CTRL, false),
            Some(esc(b"[3;5~"))
        ); // Ctrl+Delete
        assert_eq!(
            key_event_to_bytes(104, Modifiers::SHIFT, false),
            Some(esc(b"[5;2~"))
        ); // Shift+PageUp
        assert_eq!(
            key_event_to_bytes(63, Modifiers::CTRL, false),
            Some(esc(b"[15;5~"))
        ); // Ctrl+F5
        assert_eq!(
            key_event_to_bytes(109, Modifiers::CTRL | Modifiers::ALT, false),
            Some(esc(b"[6;7~"))
        ); // Ctrl+Alt+PageDown
        assert_eq!(
            key_event_to_bytes(110, Modifiers::ALT, false),
            Some(esc(b"[2;3~"))
        ); // Alt+Insert
    }

    #[test]
    fn numpad_follows_application_keypad_mode() {
        // Application keypad mode (DECPAM, set by a full-screen app).
        assert_eq!(key_event_to_bytes(71, 0, true), Some(esc(b"Oq"))); // KP_Home / KP_7
        assert_eq!(key_event_to_bytes(72, 0, true), Some(esc(b"Or"))); // KP_Up / KP_8
        assert_eq!(key_event_to_bytes(KP_ENTER, 0, true), Some(esc(b"OM")));
        assert_eq!(key_event_to_bytes(KP_ADD, 0, true), Some(esc(b"Ok")));

        // Plain shell: the characters printed on the keys. Sending ESC O q
        // here makes readline read ESC as a meta prefix and lose the digit.
        assert_eq!(key_event_to_bytes(71, 0, false), Some(b"7".to_vec()));
        assert_eq!(key_event_to_bytes(82, 0, false), Some(b"0".to_vec()));
        assert_eq!(
            key_event_to_bytes(KP_DECIMAL, 0, false),
            Some(b".".to_vec())
        );
        assert_eq!(key_event_to_bytes(KP_ADD, 0, false), Some(b"+".to_vec()));
        assert_eq!(
            key_event_to_bytes(KP_MULTIPLY, 0, false),
            Some(b"*".to_vec())
        );
        assert_eq!(key_event_to_bytes(KP_DIVIDE, 0, false), Some(b"/".to_vec()));
        assert_eq!(
            key_event_to_bytes(KP_SUBTRACT, 0, false),
            Some(b"-".to_vec())
        );
        assert_eq!(key_event_to_bytes(KP_ENTER, 0, false), Some(b"\r".to_vec()));
    }

    #[test]
    fn unicode_path_none() {
        // Printable characters without modifiers → None (caller handles via unicode)
        assert_eq!(key_event_to_bytes(30, 0, false), None); // 'a'
        assert_eq!(key_event_to_bytes(57, 0, false), None); // Space
        assert_eq!(key_event_to_bytes(16, 0, false), None); // 'q'
    }

    #[test]
    fn alt_prefix_none() {
        // Alt without Ctrl → caller should prepend ESC + char
        assert_eq!(key_event_to_bytes(30, Modifiers::ALT, false), None); // Alt+a
    }
}
