//! The tool-call argument vocabulary: what `tools/list` advertises, what
//! `tools/call` accepts, and how each argument becomes an IPC param.
//!
//! An MCP tool carries two names for the same argument and nothing connected
//! them. The schema advertises clap's argument id (`pane_type`, `title`,
//! `lines`), the GUI handler reads the CLI's wire name (`type`,
//! `title_label`), and the server forwarded a client's `arguments` object
//! verbatim — so every id that differed was dropped and the call succeeded
//! with the default value: `tools/call new-pane {"pane_type": "wiki"}`
//! created a *terminal*. This module is the one translation, derived from the
//! clap definitions themselves (the action and value-parser type say whether
//! an argument is a list, a boolean or an integer), so each argument is
//! described and validated once.
//!
//! The second half is refusal. A wrong call must fail, not silently do
//! something else: an unknown key names itself and its nearest valid
//! neighbour, a value of the wrong JSON type names the type it needed, and the
//! one tool whose arguments are not a one-to-one mapping (`vault-weight`)
//! states its contradiction. `mcp.rs` answers those with JSON-RPC `-32602`.

use std::any::TypeId;

use clap::ArgAction;
use serde_json::{Map, Value, json};

/// What one advertised argument accepts.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Text,
    Integer,
    Bool,
    /// A list of strings. The `char` is clap's command-line delimiter, when
    /// the flag is written joined (`--tags a,b`); the wire form is always a
    /// JSON array.
    List(Option<char>),
}

impl Kind {
    /// The property schema `tools/list` advertises for this kind.
    pub fn schema(self) -> Value {
        match self {
            Kind::Text => json!({"type": "string"}),
            Kind::Integer => json!({"type": "integer"}),
            Kind::Bool => json!({"type": "boolean"}),
            Kind::List(_) => json!({"type": "array", "items": {"type": "string"}}),
        }
    }

    fn describe(self) -> &'static str {
        match self {
            Kind::Text => "a string",
            Kind::Integer => "an integer",
            Kind::Bool => "a boolean",
            Kind::List(_) => "an array of strings",
        }
    }
}

/// One advertised argument, derived from its clap definition.
pub struct ArgSpec {
    pub id: String,
    pub kind: Kind,
    pub help: String,
    pub required: bool,
    /// clap's closed set of command-line values, when it declares one.
    pub possible: Vec<String>,
    pub default: Option<Value>,
}

/// The arguments a command accepts, in clap order.
pub fn tool_args(cmd: &clap::Command) -> Vec<ArgSpec> {
    cmd.get_arguments()
        .map(|arg| ArgSpec {
            id: arg.get_id().to_string(),
            kind: kind_of(arg),
            help: arg.get_help().map(|h| h.to_string()).unwrap_or_default(),
            required: arg.is_required_set(),
            possible: arg
                .get_possible_values()
                .iter()
                .map(|v| v.get_name().to_string())
                .collect(),
            default: default_of(arg),
        })
        .collect()
}

/// The JSON shape clap itself implies: `Append` collects a list, a flag is a
/// boolean, an integer field's value parser says so, everything else is text.
fn kind_of(arg: &clap::Arg) -> Kind {
    match arg.get_action() {
        ArgAction::Append => Kind::List(arg.get_value_delimiter()),
        ArgAction::Count => Kind::Integer,
        ArgAction::SetTrue | ArgAction::SetFalse => Kind::Bool,
        _ => {
            let parser = arg.get_value_parser().type_id();
            if parser == TypeId::of::<bool>() {
                Kind::Bool
            } else if [
                TypeId::of::<i8>(),
                TypeId::of::<i16>(),
                TypeId::of::<i32>(),
                TypeId::of::<i64>(),
                TypeId::of::<u8>(),
                TypeId::of::<u16>(),
                TypeId::of::<u32>(),
                TypeId::of::<u64>(),
            ]
            .iter()
            .any(|int| parser == *int)
            {
                Kind::Integer
            } else {
                Kind::Text
            }
        }
    }
}

/// clap's declared default, as the JSON value the property's schema claims.
fn default_of(arg: &clap::Arg) -> Option<Value> {
    let raw = arg.get_default_values().first()?.to_str()?;
    Some(match kind_of(arg) {
        Kind::Bool => Value::Bool(matches!(raw, "true" | "1")),
        Kind::Integer => Value::from(raw.parse::<i64>().ok()?),
        Kind::List(delim) => Value::Array(split_delimited(raw, delim)),
        Kind::Text => Value::String(raw.to_string()),
    })
}

/// The argument ids whose IPC param name is not the id itself.
///
/// Every other argument is the identity, which is why this is a short table
/// and not a copy of the vocabulary: a second full list could only drift from
/// the clap definitions. `wire_keys_are_the_keys_the_handlers_read` fails when
/// an entry names an argument that does not exist, and when a tool's
/// advertised id reaches a key no handler reads.
///
/// `title` is deliberately *not* here: the wire key is `title` too, the name
/// the `newPane` handler reads (and the row that gave `--title` effect chose),
/// and the handler renames it to `title_label` when it builds the pane's spawn
/// options — the boundary where an API request becomes internal state.
const RENAMES: &[(&str, &str, &str)] = &[
    // `--pane-type` is the CLI flag; the handler's `newPane` reads `type`.
    ("new-pane", "pane_type", "type"),
];

fn wire_key(tool: &str, id: &str) -> Option<&'static str> {
    RENAMES
        .iter()
        .find(|(t, argument, _)| *t == tool && *argument == id)
        .map(|(_, _, key)| *key)
}

/// Translate one `tools/call`'s `arguments` into the IPC params the GUI
/// handler reads, or refuse the call with a message naming what to fix.
pub fn wire_params(tool: &str, arguments: &Value) -> Result<Value, String> {
    let cmd =
        super::schema::find_tool_command(tool).ok_or_else(|| format!("Unknown tool: {tool}"))?;
    let specs = tool_args(&cmd);
    let mut params = Map::new();
    match arguments {
        // Absent arguments mean "no arguments": every tool with required
        // arguments declares them in its schema, and a client that ignores
        // that gets the handler's own refusal, which names the missing value.
        Value::Null => {}
        Value::Object(args) => {
            for (id, value) in args {
                let spec = specs
                    .iter()
                    .find(|spec| spec.id == *id)
                    .ok_or_else(|| unknown_argument(tool, id, &specs))?;
                let key = wire_key(tool, id).unwrap_or(id.as_str());
                params.insert(key.to_string(), coerce(spec, value)?);
            }
        }
        other => {
            return Err(format!(
                "arguments must be a JSON object, got {}",
                json_type(other)
            ));
        }
    }
    apply_tool_rules(tool, &mut params)?;
    Ok(Value::Object(params))
}

/// Validate one value against the shape clap advertises, accepting the
/// spellings the previous schema advertised (a numeric or boolean string) so
/// a client built against it keeps working.
fn coerce(spec: &ArgSpec, value: &Value) -> Result<Value, String> {
    match spec.kind {
        Kind::Text => match value {
            Value::String(_) => Ok(value.clone()),
            other => Err(mismatch(spec, other)),
        },
        Kind::Integer => match value {
            Value::String(text) => text
                .trim()
                .parse::<i64>()
                .map(Value::from)
                .map_err(|_| mismatch(spec, value)),
            other if other.is_i64() || other.is_u64() => Ok(other.clone()),
            other => Err(mismatch(spec, other)),
        },
        Kind::Bool => match value {
            Value::Bool(_) => Ok(value.clone()),
            Value::String(text) if text == "true" || text == "false" => {
                Ok(Value::Bool(text == "true"))
            }
            other => Err(mismatch(spec, other)),
        },
        Kind::List(delim) => match value {
            Value::Array(items) => {
                for (at, item) in items.iter().enumerate() {
                    if !item.is_string() {
                        return Err(format!(
                            "argument '{}' must be an array of strings; entry {at} is {}",
                            spec.id,
                            json_type(item)
                        ));
                    }
                }
                Ok(value.clone())
            }
            // Only where clap joins the flag's value itself (`--tags a,b`):
            // splitting an argv list on commas would corrupt an argument that
            // contains one.
            Value::String(text) => match delim {
                Some(d) => Ok(Value::Array(split_delimited(text, Some(d)))),
                None => Err(format!(
                    "argument '{}' must be an array of strings, not one string (send [\"a\", \"b\"])",
                    spec.id
                )),
            },
            other => Err(mismatch(spec, other)),
        },
    }
}

fn split_delimited(text: &str, delim: Option<char>) -> Vec<Value> {
    match delim {
        Some(d) => text
            .split(d)
            .map(str::trim)
            .filter(|part| !part.is_empty())
            .map(|part| Value::String(part.to_string()))
            .collect(),
        None => text
            .split_whitespace()
            .map(|part| Value::String(part.to_string()))
            .collect(),
    }
}

/// The tools whose arguments are not a one-to-one mapping.
///
/// `vault-weight`'s write surface is one number plus its clear switch, and the
/// handler reads the *absence* of `weight` as "clear" — so `{"clear": true}`
/// must become `{"weight": null}`, and naming neither must be refused the way
/// the CLI refuses it (a typo must not delete a declaration).
fn apply_tool_rules(tool: &str, params: &mut Map<String, Value>) -> Result<(), String> {
    if tool != "vault-weight" {
        return Ok(());
    }
    let weight = params.get("weight").cloned();
    let clear = params
        .remove("clear")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    match (weight, clear) {
        (Some(_), true) => {
            Err("give one of 'weight' (an integer) or 'clear' (true), not both".to_string())
        }
        (Some(_), false) => Ok(()),
        (None, true) => {
            params.insert("weight".to_string(), Value::Null);
            Ok(())
        }
        (None, false) => {
            Err("give 'weight' to declare a weight, or 'clear' to remove one".to_string())
        }
    }
}

fn unknown_argument(tool: &str, id: &str, specs: &[ArgSpec]) -> String {
    let names: Vec<&str> = specs.iter().map(|spec| spec.id.as_str()).collect();
    let hint = match super::closest_match(id, &names) {
        Some(near) => format!(" — did you mean '{near}'?"),
        None => String::new(),
    };
    format!(
        "unknown argument '{id}' for tool '{tool}'{hint} (valid arguments: {})",
        names.join(", ")
    )
}

fn mismatch(spec: &ArgSpec, got: &Value) -> String {
    format!(
        "argument '{}' must be {}, got {}",
        spec.id,
        spec.kind.describe(),
        json_type(got)
    )
}

fn json_type(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "a boolean",
        Value::Number(_) => "a number",
        Value::String(_) => "a string",
        Value::Array(_) => "an array",
        Value::Object(_) => "an object",
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use clap::CommandFactory;

    use super::*;

    /// The GDScript half of the vocabulary: the dispatch arms in
    /// `WorkspaceIpcHandlers.handle`, plus the two methods
    /// `WorkspaceIpcHandlers.dispatch_request` intercepts before it reaches
    /// `handle` (`paneWait` and `pluginInstall`, whose answers land frames or a
    /// dialog later).
    const IPC_HANDLERS_SRC: &str =
        include_str!("../../../../godot/scenes/terminal/ipc_handlers.gd");
    /// The vault pair's handlers are native Rust (the walk and SQLite run on
    /// the blocking pool), and they read keys through `string_param` /
    /// `int_param`. The pair shares one vocabulary (`vault_path`), so the
    /// module's key set is checked whole rather than split per method.
    const VAULT_IPC_SRC: &str = include_str!("../../../../crates/gpty-gdext/src/vault_ipc.rs");

    /// One valid call per tool — every advertised argument, so each one is
    /// exercised on the way to the handler's keys.
    fn sample(tool: &str) -> Value {
        match tool {
            "new-pane" => json!({
                "pane_type": "wiki",
                "command": "true",
                "args": ["--short"],
                "split": "top",
                "title": "sample",
                "focus": true,
                "tags": ["agent"],
            }),
            "list-panes" | "concept-list" | "layout-list" | "version" => json!({}),
            "kill-pane" | "focus-pane" | "pane-status" => json!({"pane_id": "p1"}),
            "inject" => json!({"pane_id": "p1", "text": "x"}),
            "pane-read" => json!({"pane_id": "p1", "lines": 20}),
            "pane-run" => json!({"command": "true"}),
            "pane-wait" => json!({"pane_id": "p1", "pattern": "x", "timeout_ms": 500}),
            "broadcast" => json!({"tags": ["agent"], "text": "x"}),
            "concept-toggle" => json!({"name": "agent-idle"}),
            "layout-save" | "layout-load" => json!({"name": "sample"}),
            "vault-search" => json!({"vault_path": "/v", "pattern": "p", "limit": 5}),
            "vault-read" => json!({"vault_path": "/v", "path": "a.md"}),
            "vault-weight" => json!({
                "vault_path": "/v", "src": "a.md", "target": "b.md", "weight": 5,
            }),
            other => panic!("no sample arguments for tool '{other}'"),
        }
    }

    /// The `params.get("…")` keys a method's body reads.
    ///
    /// The arms sit at two tabs; a block ends at the next arm. `paneWait` and
    /// `pluginInstall` are intercepted before the match (a `\tif method ==`
    /// branch at one tab inside `dispatch_request`), so their bodies are read
    /// from there, and the vault pair's native handlers from their own module.
    fn handler_param_keys(method: &str) -> BTreeSet<String> {
        let arm = format!("\t\t\"{method}\":");
        if let Some(at) = IPC_HANDLERS_SRC.find(&arm) {
            return IPC_HANDLERS_SRC[at + arm.len()..]
                .lines()
                .take_while(|line| !line.starts_with("\t\t\"") && !line.starts_with("\t\t_:"))
                .filter_map(|line| line.split("params.get(\"").skip(1).next())
                .filter_map(|rest| rest.split('"').next())
                .filter(|key| !key.is_empty())
                .map(str::to_string)
                .collect();
        }
        let branch = format!("\tif method == \"{method}\":");
        if let Some(at) = IPC_HANDLERS_SRC.find(&branch) {
            return IPC_HANDLERS_SRC[at + branch.len()..]
                .lines()
                .take_while(|line| !line.starts_with("\tif method =="))
                .filter_map(|line| line.split("params.get(\"").skip(1).next())
                .filter_map(|rest| rest.split('"').next())
                .filter(|key| !key.is_empty())
                .map(str::to_string)
                .collect();
        }
        assert!(
            method.starts_with("vault"),
            "no handler arm, drain-loop branch or native handler for '{method}'"
        );
        VAULT_IPC_SRC
            .match_indices("_param(params, \"")
            .filter_map(|(at, marker)| VAULT_IPC_SRC[at + marker.len()..].split('"').next())
            .map(str::to_string)
            .collect()
    }

    /// Advertised arguments whose handler does not read them yet.
    ///
    /// An entry here is a lie the surface still tells: the argument is
    /// accepted and has no effect. Empty since `new-pane`'s `--split` grew a
    /// handler: `_split_for` now takes the side (`left`/`right`/`top`/
    /// `bottom`) and falls back to the aspect choice when it cannot be
    /// honoured. Adding an entry is a product decision, and the test below
    /// fails for every emitted key that is neither read nor listed here.
    const INERT_ARGUMENTS: &[(&str, &str)] = &[];

    /// Arguments one sample cannot carry because the tool refuses them
    /// together; `vault_weight_asks_for_exactly_one_of_weight_and_clear`
    /// covers the switch.
    const MUTUALLY_EXCLUSIVE: &[(&str, &str)] = &[("vault-weight", "clear")];

    /// The contract this module exists for: every key a translated call emits
    /// is a key the handler reads. The MCP bug was exactly one violation —
    /// `new-pane` emitted `pane_type`, the handler read `type` — and it was
    /// invisible to both sides' tests.
    #[test]
    fn wire_keys_are_the_keys_the_handlers_read() {
        for tool in super::super::schema::mcp_tool_names(&crate::Cli::command()) {
            if tool.starts_with("daemon-") {
                continue; // answered by the MCP server itself
            }
            let params = wire_params(&tool, &sample(&tool))
                .unwrap_or_else(|why| panic!("tool '{tool}' refused its own sample: {why}"));
            let emitted: BTreeSet<String> = params
                .as_object()
                .expect("wire params are an object")
                .keys()
                .cloned()
                .collect();
            if emitted.is_empty() {
                // A tool that takes no arguments has nothing to translate
                // (several are answered without touching a handler at all).
                continue;
            }
            let mut known = handler_param_keys(&super::super::mcp::tool_to_ipc_method(&tool));
            for (named, id) in INERT_ARGUMENTS {
                if *named == tool {
                    known.insert(wire_key(&tool, id).unwrap_or(*id).to_string());
                }
            }
            let unread: Vec<_> = emitted.difference(&known).collect();
            assert!(
                unread.is_empty(),
                "tool '{tool}' sends {unread:?}, which its handler never reads — the call \
                 would succeed and do something else"
            );
        }
    }

    /// Every advertised argument reaches *something*: the sample sets all of
    /// them, so a tool whose spec is missing one would drop it silently.
    #[test]
    fn every_advertised_argument_is_translated() {
        let root = crate::Cli::command();
        for tool in super::super::schema::mcp_tool_names(&root) {
            if tool.starts_with("daemon-") {
                continue;
            }
            let args = sample(&tool);
            let specs = match super::super::schema::find_tool_command(&tool) {
                Some(cmd) => tool_args(&cmd),
                None => panic!("'{tool}' is advertised but not findable"),
            };
            let sent: BTreeSet<&str> = args
                .as_object()
                .unwrap()
                .keys()
                .map(String::as_str)
                .collect();
            let known: BTreeSet<&str> = specs
                .iter()
                .map(|spec| spec.id.as_str())
                .filter(|id| !MUTUALLY_EXCLUSIVE.contains(&(tool.as_str(), *id)))
                .collect();
            let missing: Vec<_> = known.difference(&sent).collect();
            assert!(
                missing.is_empty(),
                "the sample for '{tool}' does not exercise {missing:?}"
            );
        }
    }

    /// The pane type is the row's headline: the tool's `pane_type` is the
    /// handler's `type`, for every pane type the registry holds.
    #[test]
    fn pane_type_reaches_the_handler_as_type() {
        for name in gpty_core::types::PaneType::ALL.iter().map(|t| t.as_str()) {
            let params = wire_params("new-pane", &json!({"pane_type": name})).unwrap();
            assert_eq!(params, json!({"type": name}), "{name}");
        }
        assert_eq!(
            wire_params("new-pane", &json!({})).unwrap(),
            json!({}),
            "no arguments must stay no arguments: the handler's own default applies"
        );
    }

    #[test]
    fn an_unknown_argument_names_the_key_and_the_nearest_valid_one() {
        let why = wire_params("new-pane", &json!({"paneType": "wiki"})).unwrap_err();
        assert!(why.contains("paneType"), "{why}");
        assert!(why.contains("did you mean 'pane_type'"), "{why}");
        // A key with no near neighbour still lists what the tool accepts.
        let why = wire_params("new-pane", &json!({"colour": "red"})).unwrap_err();
        assert!(!why.contains("did you mean"), "{why}");
        assert!(why.contains("valid arguments:"), "{why}");
    }

    #[test]
    fn lists_accept_arrays_and_a_joined_string_only_where_clap_joins() {
        // `--arg` takes one value each and never splits, so a string is a
        // client error rather than a list of words.
        let why = wire_params("new-pane", &json!({"args": "a b"})).unwrap_err();
        assert!(why.contains("array of strings"), "{why}");
        assert_eq!(
            wire_params("new-pane", &json!({"args": ["a", "b"]})).unwrap()["args"],
            json!(["a", "b"])
        );
        // `--tags` is declared `value_delimiter = ','`, so the joined form is
        // the same value the flag takes.
        assert_eq!(
            wire_params("broadcast", &json!({"tags": "a, b", "text": "x"})).unwrap()["tags"],
            json!(["a", "b"])
        );
        assert!(wire_params("broadcast", &json!({"tags": [1], "text": "x"})).is_err());
    }

    #[test]
    fn scalars_refuse_the_wrong_json_type() {
        // The shipped schema advertised every property as a string; both
        // spellings keep working, anything else is named.
        assert_eq!(
            wire_params("pane-read", &json!({"pane_id": "p", "lines": 500})).unwrap()["lines"],
            json!(500)
        );
        assert_eq!(
            wire_params("pane-read", &json!({"pane_id": "p", "lines": "500"})).unwrap()["lines"],
            json!(500)
        );
        let why = wire_params("pane-read", &json!({"pane_id": "p", "lines": "many"})).unwrap_err();
        assert!(why.contains("must be an integer"), "{why}");
        let why = wire_params("new-pane", &json!({"pane_type": 5})).unwrap_err();
        assert!(why.contains("must be a string"), "{why}");
        // `focus` was advertised as an enum of the strings "true"/"false".
        assert_eq!(
            wire_params("new-pane", &json!({"focus": "false"})).unwrap()["focus"],
            json!(false)
        );
        assert!(wire_params("new-pane", &json!({"focus": 1})).is_err());
    }

    #[test]
    fn vault_weight_asks_for_exactly_one_of_weight_and_clear() {
        let base = json!({"vault_path": "/v", "src": "a.md", "target": "b.md"});
        let mut set = base.clone();
        set["weight"] = json!(5);
        assert_eq!(
            wire_params("vault-weight", &set).unwrap()["weight"],
            json!(5)
        );

        let mut cleared = base.clone();
        cleared["clear"] = json!(true);
        assert_eq!(
            wire_params("vault-weight", &cleared).unwrap()["weight"],
            Value::Null,
            "`clear` is the handler's absent weight: null, never a dropped key"
        );
        assert!(
            wire_params("vault-weight", &base).is_err(),
            "naming neither is a usage error, as it is on the CLI — a typo must not clear"
        );
        let mut both = set.clone();
        both["clear"] = json!(true);
        assert!(wire_params("vault-weight", &both).is_err());
    }

    #[test]
    fn arguments_that_are_not_an_object_are_refused() {
        assert!(wire_params("new-pane", &json!([1, 2])).is_err());
        assert!(wire_params("new-pane", &json!("x")).is_err());
        assert_eq!(wire_params("new-pane", &Value::Null).unwrap(), json!({}));
    }

    #[test]
    fn the_rename_table_only_names_arguments_that_exist() {
        for (tool, argument, key) in RENAMES {
            let cmd = super::super::schema::find_tool_command(tool)
                .unwrap_or_else(|| panic!("rename table names unknown tool '{tool}'"));
            assert!(
                tool_args(&cmd).iter().any(|spec| spec.id == *argument),
                "'{tool}' has no argument '{argument}' (renamed to '{key}')"
            );
            assert_ne!(argument, key, "'{tool}.{argument}' needs no rename entry");
        }
    }
}
