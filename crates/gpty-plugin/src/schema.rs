//! Caps shared by the manifest validator and the installed-plugin store.
//!
//! These moved out of `plugin_manifest` so the store crate can enforce the
//! same numbers without depending on the CLI. `plugin_manifest` re-exports
//! the ones its own callers use, keeping one definition for both sides.

/// The engine's own concept cap (`gpty_core::concept::MAX_CONCEPTS`) — a
/// manifest cannot exceed what the engine will load.
pub const MAX_CONCEPTS: usize = 128;

/// The engine parser's own caps for one concept entry (`concepts_from_json`):
/// the manifest validator, the store reader, and the engine all judge a name
/// and a trigger by the same numbers.
pub const MAX_CONCEPT_NAME_LEN: usize = 256;
pub const MAX_CONCEPT_TRIGGER_LEN: usize = 1024;

/// Identifier shapes.
pub const MAX_NAME_LEN: usize = 64;
pub const MAX_ID_PART_LEN: usize = 63;

/// The keys a `[[concepts]]` entry may carry — the closed set the visual
/// editor compiles (`ConceptGraphModel.entry_for_path`). A plugin concept
/// cannot smuggle another key into the engine.
pub const CONCEPT_KEYS: &[&str] = &[
    "name",
    "trigger",
    "enabled",
    "conditions",
    "capture_mode",
    "stop_timeout_ms",
    "stop_on_input",
    "actions",
];

/// `owner/name` — the registry's plugin identity. Both parts lowercase
/// alphanumeric with hyphens, 1-63 characters each. The install CLI and the
/// store validate ids before joining them into paths, and the store keys on
/// them.
pub fn valid_plugin_id(id: &str) -> bool {
    let Some((owner, name)) = id.split_once('/') else {
        return false;
    };
    !owner.is_empty()
        && !name.is_empty()
        && owner.len() <= MAX_ID_PART_LEN
        && name.len() <= MAX_ID_PART_LEN
        && owner
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
        && name
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}
