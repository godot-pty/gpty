//! Shared data vocabulary — the strict data boundaries of the application.
//!
//! These types form the contract between the PTY layer, the concept
//! capture engine, and the terminal tasks. Every type is `Clone` so it
//! can be handed to more than one owner.
use serde::{Deserialize, Serialize};

/// What a trigger match does.
///
/// A concept never executes anything. The two modes differ only in what the
/// emulator does with the match itself:
///
/// - [`CaptureMode::UntilStop`] buffers the output that follows the trigger and
///   hands it to a receiver pane (code viewer, Inspector).
/// - [`CaptureMode::SingleLine`] is notify-only: the match is published as an
///   event on the event socket and nothing else happens — no capture, no
///   routing, no pane involvement. It is the mode for orchestrators that want
///   to know a pattern appeared without stealing the output.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CaptureMode {
    /// Publish the match as an event; capture nothing.
    SingleLine,
    /// Capture all subsequent output until stop conditions are met.
    UntilStop {
        /// Silence for this many ms stops the capture.
        stop_timeout_ms: u64,
        /// User typing a command stops the capture.
        stop_on_input: bool,
    },
}

impl Default for CaptureMode {
    fn default() -> Self {
        Self::UntilStop {
            stop_timeout_ms: 300,
            stop_on_input: true,
        }
    }
}

use regex::Regex;

/// Pane type discriminator — mirrors GDScript PaneTypes.ALL keys.
///
/// Used across the IPC boundary to identify which type of pane to spawn
/// or query. The `as_str()` method returns the GDScript-compatible key, and
/// that key **is** the wire spelling: serde delegates to it below, so a struct
/// carrying this type cannot spell a pane differently from the registry the
/// GUI reads. (It used to be `#[serde(rename_all = "kebab-case")]`, which made
/// `NewPaneParams` serialize `code-viewer` and — worse — *reject* the
/// `code_viewer` every other surface uses.)
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PaneType {
    Terminal,
    CodeViewer,
    FileTree,
    Inspector,
    Reasoning,
    CliView,
}

/// Serialized as the GUI's own key, not as a Rust variant name.
impl Serialize for PaneType {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.as_str())
    }
}

/// Parsed by the same function the rest of the code uses ([`PaneType::parse`]),
/// so the accepted set and the emitted set are one definition.
impl<'de> Deserialize<'de> for PaneType {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let raw = String::deserialize(deserializer)?;
        Self::parse(&raw).ok_or_else(|| {
            let valid = Self::ALL.map(|t| t.as_str()).join(", ");
            serde::de::Error::custom(format!(
                "unknown pane type `{raw}` (expected one of: {valid})"
            ))
        })
    }
}

impl PaneType {
    /// Every pane type, in the order `PaneTypes.ALL` registers them.
    ///
    /// The one enumeration: [`Self::as_str`] names each, serde emits exactly
    /// those names, and callers that need "all of them" (the manifest
    /// validator, tests) iterate this instead of writing a second list.
    pub const ALL: [PaneType; 6] = [
        PaneType::Terminal,
        PaneType::CodeViewer,
        PaneType::FileTree,
        PaneType::Inspector,
        PaneType::Reasoning,
        PaneType::CliView,
    ];

    /// Returns the GDScript `PaneTypes.ALL` dictionary key for this type.
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Terminal => "terminal",
            Self::CodeViewer => "code_viewer",
            Self::FileTree => "file_tree",
            Self::Inspector => "inspector",
            Self::Reasoning => "reasoning",
            Self::CliView => "cli_view",
        }
    }

    /// Parse from a GDScript type string (case-sensitive).
    pub fn parse(s: &str) -> Option<Self> {
        s.parse().ok()
    }
}

impl std::str::FromStr for PaneType {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "terminal" => Ok(Self::Terminal),
            "code_viewer" => Ok(Self::CodeViewer),
            "file_tree" => Ok(Self::FileTree),
            "inspector" | "observer" => Ok(Self::Inspector),
            "reasoning" => Ok(Self::Reasoning),
            "cli_view" => Ok(Self::CliView),
            _ => Err(()),
        }
    }
}

/// Identifies a distinct terminal pane.
///
/// `id` must be unique across all terminals in a workspace: it keys capture
/// state, status lookups, and log lines.
#[derive(Debug, Clone)]
pub struct TerminalConfig {
    pub id: u32,
}

/// Where a concept's captured output is delivered.
///
/// The label names a pane kind (e.g. `code_viewer`, `inspector`): the
/// GDScript router matches it against each pane's `_pane_type()` and the
/// first pane that accepts the content receives it. Concepts never carry a
/// command to run — capture-and-route is the whole vocabulary.
#[derive(Debug, Clone)]
pub struct Action {
    pub target_label: String,
}

/// A display concept: regex trigger → capture, routed to a target pane kind.
///
/// When a terminal produces a line matching `trigger_regex`, the engine
/// enters capture mode; the captured output is later routed to the first
/// pane advertising the `target_label` of the concept's first destination.
///
/// # Example
///
/// ```ignore
/// Concept {
///     name: "cat_command".into(),
///     trigger_regex: Regex::new(r"(?:^|[$#>]\s)\bcat\s+\S").unwrap(),
///     enabled: true,
///     capture_mode: CaptureMode::UntilStop { stop_timeout_ms: 300, stop_on_input: true },
///     conditions: vec![],
///     destinations: vec![Action { target_label: "code_viewer".into() }],
/// }
/// ```
#[derive(Debug, Clone)]
pub struct Concept {
    pub name: String,
    pub trigger_regex: Regex,
    /// Additional predicates over the same line `trigger_regex` matched.
    ///
    /// Every condition must match that line for the concept to fire, so a
    /// condition can only ever narrow a match — it never starts a capture or
    /// routes anything on its own. Conditions are regexes in the same dialect
    /// as the trigger and are data like the rest of the vocabulary: nothing
    /// here executes.
    pub conditions: Vec<Regex>,
    /// Whether this concept is active. Disabled concepts are never evaluated.
    pub enabled: bool,
    /// How output is captured when this concept triggers.
    pub capture_mode: CaptureMode,
    pub destinations: Vec<Action>,
}

impl Concept {
    /// Convenience constructor with reasonable defaults.
    pub fn new(name: &str, trigger_regex: Regex, destinations: Vec<Action>) -> Self {
        Self {
            name: name.to_string(),
            trigger_regex,
            conditions: Vec::new(),
            enabled: true,
            capture_mode: CaptureMode::default(),
            destinations,
        }
    }
}

/// A completed capture produced by a `UntilStop` concept match.
///
/// Emitted once the stop condition fires (timeout or user input).
/// The `lines` contain the plain-text output captured between the
/// trigger and the stop. The GDScript layer decides whether to route
/// this to a receiver pane or flush it back to the terminal grid.
#[derive(Debug, Clone)]
pub struct CapturedOutput {
    /// Monotonically increasing per-terminal capture ID.
    pub id: u64,
    /// The concept that triggered this capture.
    pub concept_name: String,
    /// Plain-text lines captured between trigger and stop.
    pub lines: Vec<String>,
    /// Which pane type this output should be routed to.
    pub target_pane_type: String,
}

/// A notify-only concept match (`CaptureMode::SingleLine`).
///
/// Metadata only — deliberately never the matched line. The GDScript layer
/// forwards it to the event socket, where subscribers (plugins, orchestrators)
/// learn that a trigger fired without any pane receiving output. Terminal
/// content stays in the terminal; the event channel carries facts about the
/// workspace, not what was printed.
#[derive(Debug, Clone)]
pub struct ConceptNotice {
    /// The concept whose trigger matched.
    pub concept_name: String,
}

#[cfg(test)]
mod pane_type_tests {
    use super::PaneType;

    /// The wire spelling is the GUI's key, for every variant. This is the
    /// contract the old `rename_all = "kebab-case"` broke: a Rust struct
    /// serialized a pane type the GUI's registry has no entry for.
    #[test]
    fn serde_speaks_the_gui_key_for_every_variant() {
        for pane_type in PaneType::ALL {
            let value = serde_json::to_value(pane_type).unwrap();
            assert_eq!(
                value,
                serde_json::Value::String(pane_type.as_str().to_string()),
                "{pane_type:?} must serialize as its GUI key"
            );
        }
    }

    /// And it *reads* that key: the direction that used to fail, since serde
    /// expected `code-viewer` while every other surface sends `code_viewer`.
    #[test]
    fn the_gui_key_deserializes_back_to_the_same_variant() {
        for pane_type in PaneType::ALL {
            let json = format!("\"{}\"", pane_type.as_str());
            let back: PaneType = serde_json::from_str(&json).unwrap();
            assert_eq!(back, pane_type);
        }
        // The legacy spelling of the inspector pane is still understood — it
        // arrives from saved layouts (`PaneTypes.migrate_pane_settings`), so
        // dropping it would refuse files the GUI still accepts.
        let legacy: PaneType = serde_json::from_str("\"observer\"").unwrap();
        assert_eq!(legacy, PaneType::Inspector);
    }

    /// A Rust-shaped name is not a wire value: the kebab form is what this
    /// type used to emit, and nothing may speak it again.
    #[test]
    fn rust_shaped_names_are_not_wire_values() {
        let error = serde_json::from_str::<PaneType>("\"code-viewer\"").unwrap_err();
        let message = error.to_string();
        assert!(
            message.contains("code-viewer"),
            "the error names the input: {message}"
        );
        assert!(
            message.contains("code_viewer"),
            "and the valid set: {message}"
        );
    }
}
