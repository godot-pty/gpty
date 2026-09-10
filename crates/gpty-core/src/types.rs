//! Shared data vocabulary — the strict data boundaries of the application.
//!
//! These types form the contract between the PTY layer, the concept
//! capture engine, and the terminal tasks. Every type is `Clone` so it
//! can be handed to more than one owner.
use serde::{Deserialize, Serialize};

/// How a triggered concept captures terminal output.
///
/// A concept never executes anything: a trigger match starts a capture and
/// the captured text is routed to a pane that advertises the concept's
/// target type. `UntilStop` is therefore the only mode — a match without a
/// subsequent capture would produce no observable effect at all.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CaptureMode {
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
/// or query. The `as_str()` method returns the GDScript-compatible key.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum PaneType {
    Terminal,
    CodeViewer,
    FileTree,
    #[serde(alias = "observer")]
    Inspector,
    Reasoning,
}

impl PaneType {
    /// Returns the GDScript `PaneTypes.ALL` dictionary key for this type.
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Terminal => "terminal",
            Self::CodeViewer => "code_viewer",
            Self::FileTree => "file_tree",
            Self::Inspector => "inspector",
            Self::Reasoning => "reasoning",
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
///     destinations: vec![Action { target_label: "code_viewer".into() }],
/// }
/// ```
#[derive(Debug, Clone)]
pub struct Concept {
    pub name: String,
    pub trigger_regex: Regex,
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
