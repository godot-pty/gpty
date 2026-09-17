//! `gpty-plugin.toml` — the plugin manifest schema and its validator.
//!
//! A plugin is a directory containing this file. It can be pure JSON —
//! `[[concepts]]` and `[[profiles]]` — or name programs: `build`, `startup`,
//! `[[actions]]`, and `[[link_handlers]]` are argv arrays, never shell
//! strings, and nothing in a manifest executes during parsing or validation.
//!
//! The validator's contract is "the manifest ships only what gpty already
//! accepts":
//!
//! * Every `[[concepts]]` entry is held to the engine's own vocabulary and
//!   caps (`gpty_core::concept::concepts_from_json`) — the entries are
//!   serialized and parsed back by the real engine parser, and a manifest
//!   whose entry the engine would silently drop is rejected. The trigger and
//!   condition regexes are therefore judged in the engine's Rust `regex`
//!   dialect, not GDScript's PCRE2.
//! * Every `[[profiles]]` tile is held to the shape `PaneTypes.sanitize_tile`
//!   accepts (pane type set, grid geometry, rows/cols ceilings,
//!   `attachment_id` pattern). One deliberate difference: the sanitizer
//!   *clamps* legacy files, while the validator *rejects* — a manifest is
//!   authored content, so an out-of-range value is an authoring error rather
//!   than something to quietly rewrite.
//! * `[[actions]].command` must be one of the advertised MCP tool names
//!   (`schema::mcp_tool_names` — the published agent-facing API surface).
//! * `[[events]].type` must be one of the event-socket vocabulary strings
//!   (the generic OMP translation in `omp_events.rs` plus gpty's own
//!   `pane.spawned` / `pane.killed` / `concept.matched`).
//!
//! Installation, the review dialog, and executing actions are the plugin
//! install & lifecycle item — this module only parses and validates.

use std::fmt;

use clap::CommandFactory;
use gpty_core::types::PaneType;

/// The manifest's file name in a plugin directory.
pub const MANIFEST_FILENAME: &str = "gpty-plugin.toml";

// ── Caps ──────────────────────────────────────────────────────────────

/// Manifest-level section counts.
pub const MAX_ACTIONS: usize = 64;
pub const MAX_EVENTS: usize = 64;
pub const MAX_LINK_HANDLERS: usize = 16;
pub const MAX_PROFILES: usize = 64;
pub const MAX_PROFILE_TILES: usize = 64;
/// The engine's own concept cap (`gpty_core::concept::MAX_CONCEPTS`) — a
/// manifest cannot exceed what the engine will load.
pub const MAX_CONCEPTS: usize = 128;

/// Identifier shapes.
pub const MAX_NAME_LEN: usize = 64;
pub const MAX_ID_PART_LEN: usize = 63;
/// `name` fields on actions/events: the pane `attachment_id` pattern.
pub const MAX_SPEC_NAME_LEN: usize = 32;
pub const MAX_SCHEME_LEN: usize = 32;
pub const MAX_ARG_VALUE_LEN: usize = 1024;
pub const MAX_ACTION_ARGS: usize = 32;
pub const MAX_ACTION_ARG_KEY_LEN: usize = 32;

/// Argv arrays (`build`, `startup`, link-handler commands): the same caps the
/// pane sanitizer applies to `shell_args` — ≤32 entries, ≤4096 characters in
/// total, no U+FFFD.
pub const MAX_ARGV_ENTRIES: usize = 32;
pub const MAX_ARGV_CHARS: usize = 4096;

/// Tile geometry and grid ceilings — the same numbers `PaneTypes` enforces
/// (`GRID` = 60, `PANE_MAX_ROWS` = 500, `PANE_MAX_COLS` = 2000). Never
/// re-declare these in the GUI; here they are the manifest's mirror.
pub const GRID: i64 = 60;
pub const PANE_MAX_ROWS: i64 = 500;
pub const PANE_MAX_COLS: i64 = 2000;

/// Pane types `PaneTypes.ALL` registers — the closed set a tile's `type` may
/// name.
///
/// Derived from [`PaneType::ALL`] rather than listed again: the enum is where
/// the wire spelling lives (`as_str`), and a second literal here could only
/// drift from it (the manifest's own seam test would then be checking the
/// copy). The GUI side is pinned by `test_pane_types_all_has_six_entries`
/// (`godot/tests/integration/test_palette.gd`), and
/// `pane_type_and_platform_lists_match_the_gui_surface` pins this derivation
/// against the expected six.
pub fn pane_types() -> Vec<&'static str> {
    PaneType::ALL.iter().map(|t| t.as_str()).collect()
}

/// Platforms a manifest may declare.
pub const PLATFORMS: &[&str] = &["linux", "macos", "windows"];

/// The event-socket vocabulary a `[[events]].type` may name: gpty's own pane
/// and concept events (emitted by `workspace.gd` / `ipc_handlers.gd`) plus
/// the generic OMP translation (`omp_events.rs`).
pub const EVENT_TYPES: &[&str] = &[
    "pane.spawned",
    "pane.killed",
    "concept.matched",
    "state.declared",
    "session.bound",
    "agent.started",
    "turn.started",
    "tool.call",
    "thinking.delta",
];

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

/// The `capture_mode` values the file vocabulary carries: absent (capture),
/// or `"single_line"` (notify-only) — exactly what the visual editor writes.
pub const CONCEPT_MODES: &[&str] = &["single_line"];

// ── Errors ────────────────────────────────────────────────────────────

/// A manifest validation failure, addressed by path so the install review
/// dialog (and the author) sees exactly which field is wrong.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManifestError {
    pub message: String,
}

impl ManifestError {
    fn at(path: &str, what: &str) -> Self {
        Self {
            message: format!("{path}: {what}"),
        }
    }
}

impl fmt::Display for ManifestError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for ManifestError {}

pub type ManifestResult<T> = Result<T, ManifestError>;

// ── Parsed manifest ───────────────────────────────────────────────────

/// `X.Y.Z`, three numeric parts. The manifest vocabulary carries no
/// pre-release or build suffixes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct SemVer {
    pub major: u64,
    pub minor: u64,
    pub patch: u64,
}

impl fmt::Display for SemVer {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}.{}.{}", self.major, self.minor, self.patch)
    }
}

impl SemVer {
    pub fn parse(text: &str) -> Option<Self> {
        let mut parts = text.split('.');
        let major = parts.next()?.parse().ok()?;
        let minor = parts.next()?.parse().ok()?;
        let patch = parts.next()?.parse().ok()?;
        if parts.next().is_some() {
            return None;
        }
        Some(Self {
            major,
            minor,
            patch,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Platform {
    Linux,
    Macos,
    Windows,
}

impl Platform {
    fn parse(text: &str) -> Option<Self> {
        match text {
            "linux" => Some(Self::Linux),
            "macos" => Some(Self::Macos),
            "windows" => Some(Self::Windows),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ActionSpec {
    pub name: String,
    /// An advertised MCP tool name (`schema::mcp_tool_names`).
    pub command: String,
    /// `--key value` argument pairs; execution is the install item's concern.
    pub args: Vec<(String, String)>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EventSpec {
    pub name: String,
    /// One of [`EVENT_TYPES`].
    pub kind: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LinkHandlerSpec {
    /// URL scheme without the colon (`[a-z][a-z0-9+.-]*`).
    pub scheme: String,
    /// Argv array run with the link appended; never a shell string.
    pub command: Vec<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ProfileSpec {
    pub name: String,
    /// Validated tile tables (sanitize-tile shape).
    pub tiles: Vec<toml::Value>,
}

/// A validated manifest. `concepts` entries are validated *and*
/// engine-accepted; the install item serializes them for the engine push.
#[derive(Debug, Clone)]
pub struct Manifest {
    pub id: String,
    pub name: String,
    pub version: SemVer,
    pub min_gpty_version: SemVer,
    pub platforms: Vec<Platform>,
    pub build: Vec<String>,
    pub startup: Vec<String>,
    pub actions: Vec<ActionSpec>,
    pub events: Vec<EventSpec>,
    pub link_handlers: Vec<LinkHandlerSpec>,
    pub concepts: Vec<toml::Value>,
    pub profiles: Vec<ProfileSpec>,
}

/// The crate's own version — what `min_gpty_version` is compared against at
/// install time.
pub fn current_version() -> SemVer {
    SemVer::parse(env!("CARGO_PKG_VERSION")).expect("CARGO_PKG_VERSION is a valid X.Y.Z")
}

// ── Parsing ───────────────────────────────────────────────────────────

/// Parse and validate a manifest. Never executes anything.
pub fn parse_manifest(text: &str) -> ManifestResult<Manifest> {
    let table: toml::Table = text.parse().map_err(|e| ManifestError {
        message: format!("manifest is not valid TOML: {e}"),
    })?;
    validate(&table)
}

fn validate(table: &toml::Table) -> ManifestResult<Manifest> {
    let known: &[&str] = &[
        "id",
        "name",
        "version",
        "min_gpty_version",
        "platforms",
        "build",
        "startup",
        "actions",
        "events",
        "link_handlers",
        "concepts",
        "profiles",
    ];
    for key in table.keys() {
        if !known.contains(&key.as_str()) {
            return Err(ManifestError::at(
                "manifest",
                &format!("unknown key `{key}`"),
            ));
        }
    }

    let id = required_string(table, "id", "manifest")?;
    if !valid_plugin_id(&id) {
        return Err(ManifestError::at(
            "manifest.id",
            "must be `owner/name` ([a-z0-9-] parts, 1-63 chars each)",
        ));
    }
    let name = required_string(table, "name", "manifest")?;
    if name.is_empty() || name.chars().count() > MAX_NAME_LEN {
        return Err(ManifestError::at(
            "manifest.name",
            &format!("must be 1-{MAX_NAME_LEN} characters"),
        ));
    }
    let version = parse_semver_field(table, "version")?;
    let min_gpty_version = parse_semver_field(table, "min_gpty_version")?;
    let platforms = parse_platforms(table)?;
    let build = parse_argv(table, "build", "manifest.build")?;
    let startup = parse_argv(table, "startup", "manifest.startup")?;
    let actions = parse_actions(table)?;
    let events = parse_events(table)?;
    let link_handlers = parse_link_handlers(table)?;
    let concepts = parse_concepts(table)?;
    let profiles = parse_profiles(table)?;

    Ok(Manifest {
        id,
        name,
        version,
        min_gpty_version,
        platforms,
        build,
        startup,
        actions,
        events,
        link_handlers,
        concepts,
        profiles,
    })
}

fn required_string(table: &toml::Table, key: &str, path: &str) -> ManifestResult<String> {
    match table.get(key) {
        Some(toml::Value::String(s)) => Ok(s.clone()),
        Some(_) => Err(ManifestError::at(
            path,
            &format!("`{key}` must be a string"),
        )),
        None => Err(ManifestError::at(
            path,
            &format!("missing required key `{key}`"),
        )),
    }
}

fn parse_semver_field(table: &toml::Table, key: &str) -> ManifestResult<SemVer> {
    let path = format!("manifest.{key}");
    let text = required_string(table, key, "manifest")?;
    SemVer::parse(&text).ok_or_else(|| {
        ManifestError::at(
            &path,
            &format!("`{key}` must be a semantic version `X.Y.Z` (got `{text}`)"),
        )
    })
}

fn parse_platforms(table: &toml::Table) -> ManifestResult<Vec<Platform>> {
    let Some(value) = table.get("platforms") else {
        return Ok(vec![Platform::Linux, Platform::Macos, Platform::Windows]);
    };
    let toml::Value::Array(items) = value else {
        return Err(ManifestError::at(
            "manifest.platforms",
            "must be an array of strings",
        ));
    };
    let mut out = Vec::new();
    for (i, item) in items.iter().enumerate() {
        let toml::Value::String(s) = item else {
            return Err(ManifestError::at(
                &format!("manifest.platforms[{i}]"),
                "must be a string",
            ));
        };
        let Some(platform) = Platform::parse(s) else {
            return Err(ManifestError::at(
                &format!("manifest.platforms[{i}]"),
                &format!(
                    "unknown platform `{s}` (use one of: {})",
                    PLATFORMS.join(", ")
                ),
            ));
        };
        if !out.contains(&platform) {
            out.push(platform);
        }
    }
    Ok(out)
}

/// An argv array: ≤`MAX_ARGV_ENTRIES` strings, ≤`MAX_ARGV_CHARS` characters
/// in total, no U+FFFD — the same contract `PaneTypes.sanitize_shell_args`
/// applies to a tile's `shell_args`.
fn parse_argv(table: &toml::Table, key: &str, path: &str) -> ManifestResult<Vec<String>> {
    let Some(value) = table.get(key) else {
        return Ok(Vec::new());
    };
    validate_argv(value, path)
}

fn validate_argv(value: &toml::Value, path: &str) -> ManifestResult<Vec<String>> {
    let toml::Value::Array(items) = value else {
        return Err(ManifestError::at(
            path,
            "must be an array of strings (argv, never a shell string)",
        ));
    };
    if items.len() > MAX_ARGV_ENTRIES {
        return Err(ManifestError::at(
            path,
            &format!("at most {MAX_ARGV_ENTRIES} entries"),
        ));
    }
    let mut out = Vec::with_capacity(items.len());
    let mut total = 0usize;
    for (i, item) in items.iter().enumerate() {
        let toml::Value::String(s) = item else {
            return Err(ManifestError::at(
                &format!("{path}[{i}]"),
                "must be a string",
            ));
        };
        if s.is_empty() || s.chars().count() > MAX_ARG_VALUE_LEN || s.contains('\u{FFFD}') {
            return Err(ManifestError::at(
                &format!("{path}[{i}]"),
                &format!("must be 1-{MAX_ARG_VALUE_LEN} characters without U+FFFD"),
            ));
        }
        total += s.chars().count();
        out.push(s.clone());
    }
    if total > MAX_ARGV_CHARS {
        return Err(ManifestError::at(
            path,
            &format!("at most {MAX_ARGV_CHARS} characters in total"),
        ));
    }
    Ok(out)
}

fn parse_actions(table: &toml::Table) -> ManifestResult<Vec<ActionSpec>> {
    let Some(value) = table.get("actions") else {
        return Ok(Vec::new());
    };
    let toml::Value::Array(items) = value else {
        return Err(ManifestError::at(
            "manifest.actions",
            "must be an array of tables",
        ));
    };
    if items.len() > MAX_ACTIONS {
        return Err(ManifestError::at(
            "manifest.actions",
            &format!("at most {MAX_ACTIONS} entries"),
        ));
    }
    let commands = crate::commands::schema::mcp_tool_names(&crate::Cli::command());
    let mut out = Vec::with_capacity(items.len());
    for (i, item) in items.iter().enumerate() {
        let path = format!("manifest.actions[{i}]");
        let Some(entry) = item.as_table() else {
            return Err(ManifestError::at(&path, "must be a table"));
        };
        reject_unknown_keys(entry, &["name", "command", "args"], &path)?;
        let name = spec_name(entry, &path)?;
        let command = required_string(entry, "command", &path)?;
        if !commands.contains(&command) {
            return Err(ManifestError::at(
                &format!("{path}.command"),
                &format!(
                    "`{command}` is not a published gpty CLI command (see `gpty mcp` tool list)"
                ),
            ));
        }
        let args = parse_action_args(entry, &path)?;
        out.push(ActionSpec {
            name,
            command,
            args,
        });
    }
    Ok(out)
}

fn parse_action_args(entry: &toml::Table, path: &str) -> ManifestResult<Vec<(String, String)>> {
    let Some(value) = entry.get("args") else {
        return Ok(Vec::new());
    };
    let Some(args) = value.as_table() else {
        return Err(ManifestError::at(
            &format!("{path}.args"),
            "must be a table of string values",
        ));
    };
    if args.len() > MAX_ACTION_ARGS {
        return Err(ManifestError::at(
            &format!("{path}.args"),
            &format!("at most {MAX_ACTION_ARGS} entries"),
        ));
    }
    let mut out = Vec::with_capacity(args.len());
    for (key, value) in args {
        if !valid_arg_key(key) {
            return Err(ManifestError::at(
                &format!("{path}.args.{key}"),
                "keys must match [a-z][a-z0-9_-]* (≤32 chars)",
            ));
        }
        let Some(text) = value.as_str() else {
            return Err(ManifestError::at(
                &format!("{path}.args.{key}"),
                "values must be strings",
            ));
        };
        if text.chars().count() > MAX_ARG_VALUE_LEN {
            return Err(ManifestError::at(
                &format!("{path}.args.{key}"),
                &format!("values are at most {MAX_ARG_VALUE_LEN} characters"),
            ));
        }
        out.push((key.clone(), text.to_string()));
    }
    Ok(out)
}

fn parse_events(table: &toml::Table) -> ManifestResult<Vec<EventSpec>> {
    let Some(value) = table.get("events") else {
        return Ok(Vec::new());
    };
    let toml::Value::Array(items) = value else {
        return Err(ManifestError::at(
            "manifest.events",
            "must be an array of tables",
        ));
    };
    if items.len() > MAX_EVENTS {
        return Err(ManifestError::at(
            "manifest.events",
            &format!("at most {MAX_EVENTS} entries"),
        ));
    }
    let mut out = Vec::with_capacity(items.len());
    for (i, item) in items.iter().enumerate() {
        let path = format!("manifest.events[{i}]");
        let Some(entry) = item.as_table() else {
            return Err(ManifestError::at(&path, "must be a table"));
        };
        reject_unknown_keys(entry, &["name", "type"], &path)?;
        let name = spec_name(entry, &path)?;
        let kind = required_string(entry, "type", &path)?;
        if !EVENT_TYPES.contains(&kind.as_str()) {
            return Err(ManifestError::at(
                &format!("{path}.type"),
                &format!("`{kind}` is not an event gpty emits (see EVENT_TYPES)"),
            ));
        }
        out.push(EventSpec { name, kind });
    }
    Ok(out)
}

fn parse_link_handlers(table: &toml::Table) -> ManifestResult<Vec<LinkHandlerSpec>> {
    let Some(value) = table.get("link_handlers") else {
        return Ok(Vec::new());
    };
    let toml::Value::Array(items) = value else {
        return Err(ManifestError::at(
            "manifest.link_handlers",
            "must be an array of tables",
        ));
    };
    if items.len() > MAX_LINK_HANDLERS {
        return Err(ManifestError::at(
            "manifest.link_handlers",
            &format!("at most {MAX_LINK_HANDLERS} entries"),
        ));
    }
    let mut out = Vec::with_capacity(items.len());
    for (i, item) in items.iter().enumerate() {
        let path = format!("manifest.link_handlers[{i}]");
        let Some(entry) = item.as_table() else {
            return Err(ManifestError::at(&path, "must be a table"));
        };
        reject_unknown_keys(entry, &["scheme", "command"], &path)?;
        let scheme = required_string(entry, "scheme", &path)?;
        if !valid_scheme(&scheme) {
            return Err(ManifestError::at(
                &format!("{path}.scheme"),
                &format!("must be a URL scheme ([a-z][a-z0-9+.-]*, ≤{MAX_SCHEME_LEN} chars)"),
            ));
        }
        let command = match entry.get("command") {
            Some(value) => validate_argv(value, &format!("{path}.command"))?,
            None => {
                return Err(ManifestError::at(&path, "missing required key `command`"));
            }
        };
        out.push(LinkHandlerSpec { scheme, command });
    }
    Ok(out)
}

fn parse_concepts(table: &toml::Table) -> ManifestResult<Vec<toml::Value>> {
    let Some(value) = table.get("concepts") else {
        return Ok(Vec::new());
    };
    let toml::Value::Array(items) = value else {
        return Err(ManifestError::at(
            "manifest.concepts",
            "must be an array of tables",
        ));
    };
    if items.len() > MAX_CONCEPTS {
        return Err(ManifestError::at(
            "manifest.concepts",
            &format!("at most {MAX_CONCEPTS} entries (the engine's cap)"),
        ));
    }
    let mut names = Vec::with_capacity(items.len());
    for (i, item) in items.iter().enumerate() {
        let path = format!("manifest.concepts[{i}]");
        let Some(entry) = item.as_table() else {
            return Err(ManifestError::at(&path, "must be a table"));
        };
        validate_concept_entry(entry, &path)?;
        names.push(
            entry
                .get("name")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_string(),
        );
    }
    // Engine acceptance is the seam: serialize the validated entries and let
    // the engine's own parser read them. A concept the engine would silently
    // drop (a trigger or condition outside the Rust `regex` dialect) is an
    // invalid manifest — the engine is the consumer, so its verdict is the
    // one that matters, not GDScript's PCRE2.
    let json = serde_json::to_string(items).expect("validated toml values serialize");
    let parsed = gpty_core::concept::concepts_from_json(&json);
    if parsed.len() != items.len() {
        return Err(ManifestError {
            message: format!(
                "manifest.concepts: the engine rejected {} of {} entries (a trigger or condition the Rust `regex` engine cannot compile)",
                items.len() - parsed.len(),
                items.len()
            ),
        });
    }
    for (entry, concept) in names.iter().zip(&parsed) {
        if entry != &concept.name {
            return Err(ManifestError {
                message: format!(
                    "manifest.concepts: entry `{entry}` was not accepted by the engine as `{entry}`"
                ),
            });
        }
    }
    Ok(items.clone())
}

fn validate_concept_entry(entry: &toml::Table, path: &str) -> ManifestResult<()> {
    reject_unknown_keys(entry, CONCEPT_KEYS, path)?;
    let name = required_string(entry, "name", path)?;
    if name.is_empty() || name.chars().count() > 256 {
        return Err(ManifestError::at(
            &format!("{path}.name"),
            "must be 1-256 characters",
        ));
    }
    let trigger = required_string(entry, "trigger", path)?;
    if trigger.is_empty() || trigger.chars().count() > 1024 {
        return Err(ManifestError::at(
            &format!("{path}.trigger"),
            "must be 1-1024 characters",
        ));
    }
    if let Some(v) = entry.get("enabled")
        && !v.is_bool()
    {
        return Err(ManifestError::at(
            &format!("{path}.enabled"),
            "must be a boolean",
        ));
    }
    if let Some(v) = entry.get("stop_on_input")
        && !v.is_bool()
    {
        return Err(ManifestError::at(
            &format!("{path}.stop_on_input"),
            "must be a boolean",
        ));
    }
    if let Some(v) = entry.get("stop_timeout_ms") {
        let Some(ms) = v.as_integer() else {
            return Err(ManifestError::at(
                &format!("{path}.stop_timeout_ms"),
                "must be an integer",
            ));
        };
        if !(1..=600_000).contains(&ms) {
            return Err(ManifestError::at(
                &format!("{path}.stop_timeout_ms"),
                "must be 1-600000",
            ));
        }
    }
    if let Some(v) = entry.get("capture_mode") {
        let Some(mode) = v.as_str() else {
            return Err(ManifestError::at(
                &format!("{path}.capture_mode"),
                "must be a string",
            ));
        };
        if !CONCEPT_MODES.contains(&mode) {
            return Err(ManifestError::at(
                &format!("{path}.capture_mode"),
                "must be \"single_line\" or absent (absent captures)",
            ));
        }
    }
    if let Some(v) = entry.get("conditions") {
        let Some(items) = v.as_array() else {
            return Err(ManifestError::at(
                &format!("{path}.conditions"),
                "must be an array of strings",
            ));
        };
        if items.len() > 8 {
            return Err(ManifestError::at(
                &format!("{path}.conditions"),
                "at most 8 entries",
            ));
        }
        for (i, item) in items.iter().enumerate() {
            let Some(text) = item.as_str() else {
                return Err(ManifestError::at(
                    &format!("{path}.conditions[{i}]"),
                    "must be a string",
                ));
            };
            if text.is_empty() || text.chars().count() > 1024 {
                return Err(ManifestError::at(
                    &format!("{path}.conditions[{i}]"),
                    "must be 1-1024 characters",
                ));
            }
        }
    }
    if let Some(v) = entry.get("actions") {
        let Some(items) = v.as_array() else {
            return Err(ManifestError::at(
                &format!("{path}.actions"),
                "must be an array of tables",
            ));
        };
        if items.len() > 32 {
            return Err(ManifestError::at(
                &format!("{path}.actions"),
                "at most 32 entries",
            ));
        }
        for (i, item) in items.iter().enumerate() {
            let Some(a) = item.as_table() else {
                return Err(ManifestError::at(
                    &format!("{path}.actions[{i}]"),
                    "must be a table",
                ));
            };
            reject_unknown_keys(a, &["target"], &format!("{path}.actions[{i}]"))?;
            let target = required_string(a, "target", &format!("{path}.actions[{i}]"))?;
            if target.is_empty() || target.chars().count() > 64 {
                return Err(ManifestError::at(
                    &format!("{path}.actions[{i}].target"),
                    "must be 1-64 characters",
                ));
            }
        }
    }
    Ok(())
}

fn parse_profiles(table: &toml::Table) -> ManifestResult<Vec<ProfileSpec>> {
    let Some(value) = table.get("profiles") else {
        return Ok(Vec::new());
    };
    let toml::Value::Array(items) = value else {
        return Err(ManifestError::at(
            "manifest.profiles",
            "must be an array of tables",
        ));
    };
    if items.len() > MAX_PROFILES {
        return Err(ManifestError::at(
            "manifest.profiles",
            &format!("at most {MAX_PROFILES} entries"),
        ));
    }
    let mut out = Vec::with_capacity(items.len());
    for (i, item) in items.iter().enumerate() {
        let path = format!("manifest.profiles[{i}]");
        let Some(entry) = item.as_table() else {
            return Err(ManifestError::at(&path, "must be a table"));
        };
        reject_unknown_keys(entry, &["name", "tiles"], &path)?;
        let name = required_string(entry, "name", &path)?;
        if name.is_empty() || name.chars().count() > MAX_NAME_LEN {
            return Err(ManifestError::at(
                &format!("{path}.name"),
                &format!("must be 1-{MAX_NAME_LEN} characters"),
            ));
        }
        let tiles = match entry.get("tiles") {
            Some(toml::Value::Array(tiles)) => tiles.clone(),
            Some(_) => {
                return Err(ManifestError::at(
                    &format!("{path}.tiles"),
                    "must be an array of tables",
                ));
            }
            None => return Err(ManifestError::at(&path, "missing required key `tiles`")),
        };
        if tiles.len() > MAX_PROFILE_TILES {
            return Err(ManifestError::at(
                &format!("{path}.tiles"),
                &format!("at most {MAX_PROFILE_TILES} entries"),
            ));
        }
        for (j, tile) in tiles.iter().enumerate() {
            validate_tile(tile, &format!("{path}.tiles[{j}]"))?;
        }
        out.push(ProfileSpec { name, tiles });
    }
    Ok(out)
}

/// Mirror `PaneTypes.sanitize_tile`'s contract — with one deliberate
/// difference: the sanitizer clamps legacy files, the validator rejects,
/// because a manifest is authored content and an out-of-range value is an
/// authoring error.
fn validate_tile(tile: &toml::Value, path: &str) -> ManifestResult<()> {
    let Some(td) = tile.as_table() else {
        return Err(ManifestError::at(path, "must be a table"));
    };
    let Some(settings) = td.get("settings") else {
        return Err(ManifestError::at(path, "missing required key `settings`"));
    };
    let Some(settings) = settings.as_table() else {
        return Err(ManifestError::at(path, "`settings` must be a table"));
    };
    let type_name = settings
        .get("type")
        .and_then(|v| v.as_str())
        .unwrap_or("terminal");
    // The legacy `observer` type is refused with guidance — the manifest
    // vocabulary is new content, so it authors `inspector`/`reasoning`
    // directly; the GUI's migrate step remains the guard for old user files.
    if type_name == "observer" {
        return Err(ManifestError::at(
            &format!("{path}.settings.type"),
            "`observer` is legacy; author `inspector` or `reasoning`",
        ));
    }
    let pane_types = pane_types();
    if !pane_types.contains(&type_name) {
        return Err(ManifestError::at(
            &format!("{path}.settings.type"),
            &format!(
                "unknown pane type `{type_name}` (use one of: {})",
                pane_types.join(", ")
            ),
        ));
    }
    if let Some(v) = settings.get("rows") {
        let Some(rows) = v.as_integer() else {
            return Err(ManifestError::at(
                &format!("{path}.settings.rows"),
                "must be an integer",
            ));
        };
        if !(1..=PANE_MAX_ROWS).contains(&rows) {
            return Err(ManifestError::at(
                &format!("{path}.settings.rows"),
                &format!("must be 1-{PANE_MAX_ROWS}"),
            ));
        }
    }
    if let Some(v) = settings.get("cols") {
        let Some(cols) = v.as_integer() else {
            return Err(ManifestError::at(
                &format!("{path}.settings.cols"),
                "must be an integer",
            ));
        };
        if !(1..=PANE_MAX_COLS).contains(&cols) {
            return Err(ManifestError::at(
                &format!("{path}.settings.cols"),
                &format!("must be 1-{PANE_MAX_COLS}"),
            ));
        }
    }
    if let Some(v) = settings.get("attachment_id") {
        let Some(id) = v.as_str() else {
            return Err(ManifestError::at(
                &format!("{path}.settings.attachment_id"),
                "must be a string",
            ));
        };
        if !valid_spec_name(id) {
            return Err(ManifestError::at(
                &format!("{path}.settings.attachment_id"),
                "must match [a-z][a-z0-9_-]{0,31}",
            ));
        }
    }
    let col = int_field(td, "col", 0, &format!("{path}.col"))?;
    let row = int_field(td, "row", 0, &format!("{path}.row"))?;
    let cspan = int_field(td, "cspan", GRID, &format!("{path}.cspan"))?;
    let rspan = int_field(td, "rspan", GRID, &format!("{path}.rspan"))?;
    if !(0..GRID).contains(&col) || !(0..GRID).contains(&row) {
        return Err(ManifestError::at(
            path,
            &format!("col/row must be 0-{}", GRID - 1),
        ));
    }
    if !(1..=GRID).contains(&cspan) || !(1..=GRID).contains(&rspan) {
        return Err(ManifestError::at(
            path,
            &format!("cspan/rspan must be 1-{GRID}"),
        ));
    }
    if col + cspan > GRID || row + rspan > GRID {
        return Err(ManifestError::at(path, "the tile must fit inside the grid"));
    }
    Ok(())
}

fn int_field(td: &toml::Table, key: &str, default: i64, path: &str) -> ManifestResult<i64> {
    match td.get(key) {
        None => Ok(default),
        Some(toml::Value::Integer(v)) => Ok(*v),
        Some(_) => Err(ManifestError::at(path, "must be an integer")),
    }
}

fn spec_name(entry: &toml::Table, path: &str) -> ManifestResult<String> {
    let name = required_string(entry, "name", path)?;
    if !valid_spec_name(&name) {
        return Err(ManifestError::at(
            &format!("{path}.name"),
            "must match [a-z][a-z0-9_-]{0,31}",
        ));
    }
    Ok(name)
}

fn reject_unknown_keys(entry: &toml::Table, known: &[&str], path: &str) -> ManifestResult<()> {
    for key in entry.keys() {
        if !known.contains(&key.as_str()) {
            return Err(ManifestError::at(path, &format!("unknown key `{key}`")));
        }
    }
    Ok(())
}

// ── Identifier shapes ─────────────────────────────────────────────────

/// `owner/name` — the registry's plugin identity. Both parts lowercase
/// alphanumeric with hyphens, 1-63 characters each. Public because the
/// install CLI validates ids before joining them into paths
/// (`plugin_store`), and the store keys on them.
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

/// The pane `attachment_id` shape, reused for action/event names.
fn valid_spec_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= MAX_SPEC_NAME_LEN
        && name.bytes().next().is_some_and(|b| b.is_ascii_lowercase())
        && name
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
}

fn valid_arg_key(key: &str) -> bool {
    !key.is_empty()
        && key.len() <= MAX_ACTION_ARG_KEY_LEN
        && key.bytes().next().is_some_and(|b| b.is_ascii_lowercase())
        && key
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
}

fn valid_scheme(scheme: &str) -> bool {
    !scheme.is_empty()
        && scheme.len() <= MAX_SCHEME_LEN
        && scheme
            .bytes()
            .next()
            .is_some_and(|b| b.is_ascii_lowercase())
        && scheme.chars().all(|c| {
            c.is_ascii_lowercase() || c.is_ascii_digit() || c == '+' || c == '.' || c == '-'
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(text: &str) -> Manifest {
        parse_manifest(text).unwrap_or_else(|e| panic!("manifest must parse: {e}"))
    }

    fn rejects(text: &str, needle: &str) -> ManifestError {
        match parse_manifest(text) {
            Ok(_) => panic!("manifest must be rejected (needle: {needle})"),
            Err(e) => {
                assert!(
                    e.message.contains(needle),
                    "error `{}` must contain `{needle}`",
                    e.message
                );
                e
            }
        }
    }

    const MINIMAL: &str = r#"
id = "owner/demo"
name = "Demo"
version = "1.0.0"
min_gpty_version = "0.5.5"
"#;

    #[test]
    fn minimal_manifest_defaults_everything() {
        let m = parse(MINIMAL);
        assert_eq!(m.id, "owner/demo");
        assert_eq!(m.name, "Demo");
        assert_eq!(
            m.version,
            SemVer {
                major: 1,
                minor: 0,
                patch: 0
            }
        );
        assert_eq!(m.platforms.len(), 3, "no platforms key = all platforms");
        assert!(m.build.is_empty() && m.startup.is_empty());
        assert!(m.actions.is_empty() && m.events.is_empty());
        assert!(m.link_handlers.is_empty() && m.concepts.is_empty() && m.profiles.is_empty());
    }

    #[test]
    fn full_manifest_roundtrips() {
        let m = parse(
            r#"
id = "godot-pty/rust-workspace"
name = "Rust Workspace"
version = "1.2.3"
min_gpty_version = "0.5.5"
platforms = ["linux", "macos"]
build = ["make", "build"]
startup = ["make", "dev"]

[[actions]]
name = "watch-tests"
command = "pane-run"
args = { cmd = "cargo test" }

[[events]]
name = "test-done"
type = "concept.matched"

[[link_handlers]]
scheme = "pr"
command = ["gh", "pr", "view"]

[[concepts]]
name = "cargo_check"
trigger = "^error\\[E\\d+\\]"
conditions = ["^error"]
capture_mode = "single_line"

[[profiles]]
name = "Rust"
tiles = [
  { col = 0, row = 0, cspan = 30, rspan = 60, settings = { type = "terminal", attachment_id = "rust-term" } },
  { col = 30, row = 0, cspan = 30, rspan = 60, settings = { type = "code_viewer" } },
]
"#,
        );
        assert_eq!(m.platforms.len(), 2);
        assert_eq!(m.build, vec!["make", "build"]);
        assert_eq!(m.actions.len(), 1);
        assert_eq!(m.actions[0].command, "pane-run");
        assert_eq!(
            m.actions[0].args,
            vec![("cmd".to_string(), "cargo test".to_string())]
        );
        assert_eq!(m.events[0].kind, "concept.matched");
        assert_eq!(m.link_handlers[0].scheme, "pr");
        assert_eq!(m.link_handlers[0].command, vec!["gh", "pr", "view"]);
        assert_eq!(m.concepts.len(), 1, "the concept must be engine-accepted");
        assert_eq!(m.profiles.len(), 1);
        assert_eq!(m.profiles[0].tiles.len(), 2);
    }

    #[test]
    fn required_fields_and_bad_toml() {
        rejects("id = ", "not valid TOML");
        rejects(
            "id = \"a/b\"\nname = \"x\"\nversion = \"1.0.0\"",
            "min_gpty_version",
        );
        rejects(
            "name = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"",
            "id",
        );
        rejects(
            "id = 7\nname = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"",
            "must be a string",
        );
        rejects(
            "id = \"a/b\"\nname = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"\nextra = 1\n",
            "unknown key `extra`",
        );
    }

    #[test]
    fn plugin_id_shape() {
        rejects(
            "id = \"nope\"\nname = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"",
            "owner/name",
        );
        rejects(
            "id = \"Owner/demo\"\nname = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"",
            "owner/name",
        );
        rejects(
            "id = \"a/b/c\"\nname = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"",
            "owner/name",
        );
        parse(
            "id = \"a1-2/b3-4\"\nname = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"",
        );
    }

    #[test]
    fn semver_field_shapes() {
        for bad in ["1.2", "1.2.3.4", "1.2.x", "1.2.3-alpha", "one.two.three"] {
            rejects(
                &format!(
                    "id = \"a/b\"\nname = \"x\"\nversion = \"{bad}\"\nmin_gpty_version = \"0.5.5\""
                ),
                "semantic version",
            );
        }
        let m =
            parse("id = \"a/b\"\nname = \"x\"\nversion = \"0.5.3\"\nmin_gpty_version = \"0.5.5\"");
        assert_eq!(
            m.version,
            SemVer {
                major: 0,
                minor: 5,
                patch: 3
            }
        );
        assert!(m.min_gpty_version > m.version);
        assert!(current_version() > m.version);
    }

    #[test]
    fn platforms_closed_set_and_dedupe() {
        rejects(
            "id = \"a/b\"\nname = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"\nplatforms = [\"plan9\"]\n",
            "unknown platform",
        );
        let m = parse(
            "id = \"a/b\"\nname = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"\nplatforms = [\"linux\", \"linux\"]\n",
        );
        assert_eq!(m.platforms.len(), 1, "duplicates collapse");
    }

    #[test]
    fn argv_arrays_caps() {
        rejects(
            "id = \"a/b\"\nname = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"\nbuild = \"make\"\n",
            "array of strings",
        );
        rejects(
            "id = \"a/b\"\nname = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"\nbuild = [7]\n",
            "must be a string",
        );
        rejects(
            "id = \"a/b\"\nname = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"\nbuild = [\"\"]\n",
            "1-1024",
        );
        rejects(
            "id = \"a/b\"\nname = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"\nbuild = [\"\u{FFFD}\"]\n",
            "U+FFFD",
        );
        let big: Vec<String> = vec!["x".repeat(200); 33];
        let joined = big
            .iter()
            .map(|s| format!("\"{s}\""))
            .collect::<Vec<_>>()
            .join(", ");
        rejects(
            &format!(
                "id = \"a/b\"\nname = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"\nbuild = [{joined}]\n"
            ),
            "at most 32",
        );
    }

    #[test]
    fn action_commands_are_the_advertised_cli_surface() {
        // The manifest's action vocabulary is the published MCP tool list —
        // the same derivation mcp.rs gates tools/call with. A manifest action
        // cannot name anything outside it.
        rejects(
            "id = \"a/b\"\nname = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"\n[[actions]]\nname = \"x\"\ncommand = \"herdr\"\n",
            "not a published gpty CLI command",
        );
        let tools = crate::commands::schema::mcp_tool_names(&crate::Cli::command());
        assert!(
            tools.contains(&"pane-run".to_string()),
            "the seam vocabulary must carry pane-run"
        );
        for tool in &tools {
            parse(&format!(
                "id = \"a/b\"\nname = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"\n[[actions]]\nname = \"a-{tool}\"\ncommand = \"{tool}\"\n"
            ));
        }
    }

    #[test]
    fn action_shapes_and_caps() {
        rejects(
            "id = \"a/b\"\nname = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"\n[[actions]]\nname = \"Bad Name\"\ncommand = \"inject\"\n",
            "[a-z][a-z0-9_-]",
        );
        rejects(
            "id = \"a/b\"\nname = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"\n[[actions]]\nname = \"x\"\ncommand = \"inject\"\nargs = { CMD = \"x\" }\n",
            "keys must match",
        );
        rejects(
            "id = \"a/b\"\nname = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"\n[[actions]]\nname = \"x\"\ncommand = \"inject\"\nargs = { cmd = 7 }\n",
            "values must be strings",
        );
        rejects(
            "id = \"a/b\"\nname = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"\n[[actions]]\nname = \"x\"\ncommand = \"inject\"\nextra = true\n",
            "unknown key `extra`",
        );
        let many: Vec<String> = (0..MAX_ACTIONS + 1)
            .map(|i| format!("[[actions]]\nname = \"a{i}\"\ncommand = \"inject\""))
            .collect();
        rejects(
            &format!(
                "id = \"a/b\"\nname = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"\n{}\n",
                many.join("\n")
            ),
            "at most",
        );
    }

    #[test]
    fn event_types_are_the_socket_vocabulary() {
        rejects(
            "id = \"a/b\"\nname = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"\n[[events]]\nname = \"x\"\ntype = \"pane.gone\"\n",
            "not an event gpty emits",
        );
        for kind in EVENT_TYPES {
            parse(&format!(
                "id = \"a/b\"\nname = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"\n[[events]]\nname = \"e\"\ntype = \"{kind}\"\n"
            ));
        }
    }

    #[test]
    fn link_handler_shapes() {
        rejects(
            "id = \"a/b\"\nname = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"\n[[link_handlers]]\nscheme = \"9bad\"\ncommand = [\"gh\"]\n",
            "URL scheme",
        );
        rejects(
            "id = \"a/b\"\nname = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"\n[[link_handlers]]\nscheme = \"pr\"\n",
            "missing required key `command`",
        );
        let many: Vec<String> = (0..MAX_LINK_HANDLERS + 1)
            .map(|i| format!("[[link_handlers]]\nscheme = \"s{i}\"\ncommand = [\"gh\"]"))
            .collect();
        rejects(
            &format!(
                "id = \"a/b\"\nname = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"\n{}\n",
                many.join("\n")
            ),
            "at most",
        );
        parse(
            "id = \"a/b\"\nname = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"\n[[link_handlers]]\nscheme = \"vscode\"\ncommand = [\"code\", \"--goto\"]\n",
        );
    }

    #[test]
    fn concepts_are_engine_accepted() {
        let m = parse(
            r#"id = "a/b"
name = "x"
version = "1.0.0"
min_gpty_version = "0.5.5"
[[concepts]]
name = "git_log"
trigger = "^commit [0-9a-f]{7}"
enabled = false
conditions = ["^commit"]
capture_mode = "single_line"
[[concepts]]
name = "cargo_err"
trigger = "^error\\[E[0-9]+\\]"
stop_timeout_ms = 2000
stop_on_input = false
actions = [{ target = "code_viewer" }]
"#,
        );
        assert_eq!(
            m.concepts.len(),
            2,
            "both entries must survive the engine parser"
        );
    }

    #[test]
    fn concepts_reject_what_the_engine_or_editor_rejects() {
        // Unknown keys: the closed set the visual editor compiles.
        rejects(
            "id = \"a/b\"\nname = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"\n[[concepts]]\nname = \"x\"\ntrigger = \"y\"\ncmd = \"rm -rf\"\n",
            "unknown key `cmd`",
        );
        rejects(
            "id = \"a/b\"\nname = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"\n[[concepts]]\nname = \"x\"\ntrigger = \"y\"\ncapture_mode = \"until_stop\"\n",
            "capture_mode",
        );
        rejects(
            "id = \"a/b\"\nname = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"\n[[concepts]]\nname = \"x\"\ntrigger = \"y\"\nstop_timeout_ms = 99999999\n",
            "1-600000",
        );
        // The engine's regex dialect, not GDScript's PCRE2: a lookbehind
        // compiles under PCRE2 but the Rust `regex` engine refuses it — the
        // round-trip through concepts_from_json is what catches it.
        rejects(
            "id = \"a/b\"\nname = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"\n[[concepts]]\nname = \"x\"\ntrigger = \"(?<=foo)bar\"\n",
            "engine rejected",
        );
        let many: Vec<String> = (0..MAX_CONCEPTS + 1)
            .map(|i| format!("[[concepts]]\nname = \"c{i}\"\ntrigger = \"x{i}\""))
            .collect();
        rejects(
            &format!(
                "id = \"a/b\"\nname = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"\n{}\n",
                many.join("\n")
            ),
            "at most",
        );
    }

    #[test]
    fn profiles_mirror_sanitize_tile_with_rejection_instead_of_clamps() {
        let m = parse(
            r#"id = "a/b"
name = "x"
version = "1.0.0"
min_gpty_version = "0.5.5"
[[profiles]]
name = "Full"
tiles = [
  { col = 0, row = 0, cspan = 60, rspan = 60, settings = { type = "terminal", rows = 500, cols = 2000 } },
]
"#,
        );
        assert_eq!(m.profiles[0].tiles.len(), 1);
        rejects(
            "id = \"a/b\"\nname = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"\n[[profiles]]\nname = \"P\"\ntiles = [{ settings = { type = \"observer\" } }]\n",
            "`observer` is legacy",
        );
        rejects(
            "id = \"a/b\"\nname = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"\n[[profiles]]\nname = \"P\"\ntiles = [{ settings = { type = \"tv\" } }]\n",
            "unknown pane type",
        );
        rejects(
            "id = \"a/b\"\nname = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"\n[[profiles]]\nname = \"P\"\ntiles = [{ settings = { type = \"terminal\", rows = 501 } }]\n",
            "1-500",
        );
        rejects(
            "id = \"a/b\"\nname = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"\n[[profiles]]\nname = \"P\"\ntiles = [{ col = 50, cspan = 20, settings = { type = \"terminal\" } }]\n",
            "fit inside the grid",
        );
        rejects(
            "id = \"a/b\"\nname = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"\n[[profiles]]\nname = \"P\"\ntiles = [{ settings = { type = \"terminal\", attachment_id = \"BAD!\" } }]\n",
            "[a-z][a-z0-9_-]",
        );
        rejects(
            "id = \"a/b\"\nname = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"\n[[profiles]]\nname = \"P\"\n",
            "missing required key `tiles`",
        );
    }

    /// The tile contract covers type/geometry/`attachment_id` only, so a
    /// cli_view tile's own settings — `command` (program) and `shell_args`
    /// (argv) — are tolerated and carried through untouched: the pane, not
    /// the manifest, owns what a view runs.
    #[test]
    fn cli_view_tile_settings_pass_through() {
        let m = parse(
            r#"id = "a/b"
name = "x"
version = "1.0.0"
min_gpty_version = "0.5.5"
[[profiles]]
name = "Tools"
tiles = [
  { col = 0, row = 0, cspan = 30, rspan = 60, settings = { type = "cli_view", attachment_id = "git-log", command = "git", shell_args = ["log", "--oneline", "-n", "20"] } },
]
"#,
        );
        let tile = &m.profiles[0].tiles[0];
        assert_eq!(tile["settings"]["type"].as_str(), Some("cli_view"));
        assert_eq!(tile["settings"]["command"].as_str(), Some("git"));
        assert_eq!(
            tile["settings"]["shell_args"]
                .as_array()
                .expect("shell_args array")
                .len(),
            4
        );
    }

    #[test]
    fn profile_and_tile_counts_are_capped() {
        let many: Vec<String> = (0..MAX_PROFILES + 1)
            .map(|i| format!("[[profiles]]\nname = \"p{i}\"\ntiles = []"))
            .collect();
        rejects(
            &format!(
                "id = \"a/b\"\nname = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"\n{}\n",
                many.join("\n")
            ),
            "at most",
        );
        let tiles: Vec<String> = (0..MAX_PROFILE_TILES + 1)
            .map(|i| format!("{{ col = {i}, settings = {{ type = \"terminal\" }} }}"))
            .collect();
        rejects(
            &format!(
                "id = \"a/b\"\nname = \"x\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.5\"\n[[profiles]]\nname = \"P\"\ntiles = [{}]\n",
                tiles.join(", ")
            ),
            "at most",
        );
    }

    /// Keys of a GDScript `static var ALL: Dictionary = { … }` registry, in
    /// file order — the GUI side read rather than restated.
    fn gdscript_registry_keys(source: &str) -> Vec<&str> {
        let start = source
            .find("static var ALL: Dictionary = {")
            .expect("PaneTypes.ALL must exist");
        let rest = &source[start..];
        let end = rest
            .find("\n}")
            .expect("the registry dictionary must close");
        rest[..end]
            .lines()
            .filter_map(|line| {
                let tail = line.trim_start().strip_prefix('"')?;
                let (key, after) = tail.split_once('"')?;
                after.trim_start().starts_with(':').then_some(key)
            })
            .collect()
    }

    /// The pane vocabulary is one thing seen from two sides: the enum's wire
    /// spellings — what serde emits, what the manifest validator accepts, what
    /// the CLI's `new-pane` validates — and the GUI's registry keys. This test
    /// reads the registry instead of restating it, so a rename on either side
    /// fails here; the count-only checks on both sides would have let a
    /// `code_viewer` → `codeviewer` through in silence.
    #[test]
    fn pane_types_match_the_gui_registry_key_for_key() {
        const PANE_TYPES_SRC: &str = include_str!("../../../godot/scenes/panes/pane_types.gd");
        assert_eq!(
            pane_types(),
            gdscript_registry_keys(PANE_TYPES_SRC),
            "the enum's wire spellings must be the registry's keys, in its order"
        );
    }

    #[test]
    fn pane_type_and_platform_lists_match_the_gui_surface() {
        // The platform set is the export preset's own vocabulary, so it stays
        // a literal; the pane types are derived from the enum, and this is the
        // contract that both the GUI registry and the derivation must satisfy
        // (`test_pane_types_all_has_six_entries` pins the GUI side).
        assert_eq!(
            pane_types(),
            vec![
                "terminal",
                "code_viewer",
                "file_tree",
                "inspector",
                "reasoning",
                "cli_view"
            ],
            "the enum's wire spellings are the GUI's registry keys, in its order"
        );
        assert_eq!(PLATFORMS.len(), 3);
    }
}
