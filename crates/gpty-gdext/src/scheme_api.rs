//! `GptyScheme` - colour-scheme import over the FFI.
//!
//! The parser and its caps live in `gpty_core::scheme`; this is only the
//! JSON-shaped seam a GDScript picker calls. It is a static method (like
//! `GptyTerminal.get_app_version`), so nothing is instantiated: the pane's
//! scheme path is read once by `TerminalPane`, and the answer carries both the
//! parsed colours and the canonical native file text an import writes.

use godot::prelude::*;
use gpty_core::scheme::{parse_scheme, to_native_json};
use serde_json::json;

#[derive(GodotClass)]
#[class(base = RefCounted)]
struct GptyScheme;

#[godot_api]
impl IRefCounted for GptyScheme {
    fn init(_base: Base<RefCounted>) -> Self {
        Self
    }
}

#[godot_api]
impl GptyScheme {
    /// Parse one colour-scheme file's text into the native six-key shape.
    ///
    /// `file_name` is a label fallback only - the format is sniffed from the
    /// content, so a misnamed file still imports. Answers JSON:
    /// `{"ok": true, "name": String, "palette": [16 "#rrggbb"],
    /// "foreground": "#rrggbb", "background": "#rrggbb", "cursor": "#rrggbb",
    /// "selection": "#rrggbb", "json": <the native file text>}` or
    /// `{"ok": false, "error": "one user-facing sentence"}`.
    #[func]
    fn parse(text: GString, file_name: GString) -> GString {
        let answer = match parse_scheme(&text.to_string(), &file_name.to_string()) {
            Ok(scheme) => {
                let native = to_native_json(&scheme);
                json!({
                    "ok": true,
                    "name": scheme.name,
                    "palette": scheme.palette.iter().map(hex).collect::<Vec<_>>(),
                    "foreground": hex(&scheme.foreground),
                    "background": hex(&scheme.background),
                    "cursor": hex(&scheme.cursor),
                    "selection": hex(&scheme.selection),
                    "json": native,
                })
            }
            Err(error) => json!({ "ok": false, "error": error }),
        };
        GString::from(&answer.to_string())
    }
}

fn hex(colour: &[u8; 3]) -> String {
    format!("#{:02x}{:02x}{:02x}", colour[0], colour[1], colour[2])
}
