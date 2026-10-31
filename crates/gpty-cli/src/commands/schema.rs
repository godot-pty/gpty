use crate::Cli;
use clap::CommandFactory;
use serde_json::{Map, Value, json};

use super::wire;

pub fn run(format: &str) -> anyhow::Result<()> {
    match format {
        "json-schema" => {
            let schema = clap_command_to_json_schema(&Cli::command());
            println!("{}", serde_json::to_string_pretty(&schema)?);
        }
        "mcp" => {
            let tools = build_mcp_tools_inline(&Cli::command());
            println!("{}", serde_json::to_string_pretty(&tools)?);
        }
        other => anyhow::bail!("Unknown format: {other}. Use json-schema or mcp."),
    }
    Ok(())
}

fn clap_command_to_json_schema(cmd: &clap::Command) -> serde_json::Value {
    let mut one_of = Vec::new();
    for sub in cmd.get_subcommands() {
        // The same argument schemas the MCP manifest advertises: one
        // derivation, so the two discovery surfaces cannot describe an
        // argument differently (both used to call every one of them a
        // string, an integer argument included).
        let (sub_props, _required) = build_args_schema(sub);
        let sub_schema = serde_json::json!({
            "type": "object",
            "properties": sub_props,
            "additionalProperties": false,
        });
        one_of.push(serde_json::json!({
            "required": ["command"],
            "properties": {
                "command": {"const": sub.get_name()},
                "args": sub_schema,
            }
        }));
    }
    serde_json::json!({
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "title": "gpty CLI",
        "description": cmd.get_about().unwrap_or_default().to_string(),
        "type": "object",
        "oneOf": one_of,
    })
}

/// One advertised MCP tool: its name, description, and the clap command its
/// arguments come from.
pub struct ToolDef {
    pub name: String,
    pub about: String,
    pub command: clap::Command,
}

/// Every advertised tool, with nested subcommands flattened (`daemon-start`)
/// and the deliberate exclusions applied.
///
/// The one place that decides what the surface contains: the manifest, the
/// `tools/call` allow-list and the argument translation all read this list, so
/// a command appears in all three or in none.
pub fn tool_defs(root: &clap::Command) -> Vec<ToolDef> {
    let mut defs = Vec::new();
    for sub in root.get_subcommands() {
        let name = sub.get_name().to_string();
        // Skip self-referential / admin commands that aren't useful as MCP tools
        if name == "mcp" || name == "schema" {
            continue;
        }
        // `state` declares the state of the pane the command runs *in*, from
        // the `GPTY_EVENT_*` its parent injected, and reaches the event
        // socket — not the control socket. There is no IPC method behind it,
        // so advertising it would publish a tool that cannot dispatch
        // (`every_mcp_tool_maps_to_a_registered_method` fails if this
        // exclusion is dropped).
        if name == "state" {
            continue;
        }
        // `plugin` is the install/manage CLI: installing waits on a human
        // reading the review dialog (the `pluginInstall` handshake, which is
        // deliberately not an MCP tool — an MCP client cannot answer a
        // dialog, the same rule that refuses `layoutLoad` on untrusted
        // profiles), and `list`/`enable`/`uninstall`/`logs` touch local
        // state, not the workspace API. `plugin run` *is* the way an action
        // reaches the MCP tool surface — each action names an advertised
        // tool from this very list.
        if name == "plugin" {
            continue;
        }
        // Flatten nested subcommands (daemon, layout) into prefixed tools
        let nested: Vec<clap::Command> = sub.get_subcommands().cloned().collect();
        if nested.is_empty() {
            defs.push(ToolDef {
                about: sub.get_about().unwrap_or_default().to_string(),
                name,
                command: sub.clone(),
            });
            continue;
        }
        for nested_sub in nested {
            defs.push(ToolDef {
                name: format!("{name}-{}", nested_sub.get_name()),
                about: nested_sub.get_about().unwrap_or_default().to_string(),
                command: nested_sub,
            });
        }
    }
    defs
}

/// The clap command behind one advertised tool name — `tools/call`'s argument
/// translation looks the tool up here, so it validates against exactly what
/// the manifest advertised.
pub fn find_tool_command(tool: &str) -> Option<clap::Command> {
    tool_defs(&Cli::command())
        .into_iter()
        .find(|def| def.name == tool)
        .map(|def| def.command)
}

pub fn build_mcp_tools_inline(cmd: &clap::Command) -> serde_json::Value {
    let tools: Vec<Value> = tool_defs(cmd)
        .iter()
        .map(|def| {
            let (properties, required) = build_args_schema(&def.command);
            build_tool(&def.name, &def.about, properties, required)
        })
        .collect();
    json!({ "tools": tools })
}

/// Names of every advertised MCP tool, in schema order.
///
/// `tools/call` validates against this list: the kebab→camel mapping turns
/// *any* string into an IPC method name, so without the gate a client reaches
/// methods that were never published as tools (e.g. `shutdown`, which only the
/// `daemon-stop` tool should trigger).
pub fn mcp_tool_names(cmd: &clap::Command) -> Vec<String> {
    build_mcp_tools_inline(cmd)
        .get("tools")
        .and_then(|tools| tools.as_array())
        .map(|tools| {
            tools
                .iter()
                .filter_map(|tool| tool.get("name").and_then(|n| n.as_str()))
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default()
}

fn build_args_schema(sub: &clap::Command) -> (Map<String, Value>, Vec<String>) {
    let mut properties = Map::new();
    let mut required = Vec::new();
    for spec in wire::tool_args(sub) {
        let mut schema = spec.kind.schema();
        schema["description"] = json!(spec.help);
        // A boolean's `["true", "false"]` is its type, not a closed set of
        // values; only a string argument's possible values are an enum.
        if spec.kind != wire::Kind::Bool && !spec.possible.is_empty() {
            schema["enum"] = json!(spec.possible);
        }
        if let Some(default) = spec.default {
            schema["default"] = default;
        }
        if spec.required {
            required.push(spec.id.clone());
        }
        properties.insert(spec.id, schema);
    }
    (properties, required)
}

/// Tools that only read: they change nothing a caller can observe beyond the
/// answer. Everything not named here and not in [`DESTRUCTIVE_TOOLS`] is an
/// additive write (it creates something or changes a display setting).
const READ_ONLY_TOOLS: &[&str] = &[
    "concept-list",
    "daemon-status",
    "layout-list",
    "list-panes",
    "pane-read",
    "pane-status",
    "vault-read",
    "vault-search",
    "version",
];

/// Tools whose write can destroy work: they stop a process, replace the
/// workspace, or send input to whatever a pane is running.
const DESTRUCTIVE_TOOLS: &[&str] = &[
    "broadcast",
    "daemon-stop",
    "inject",
    "kill-pane",
    "layout-load",
    "pane-run",
];

/// The MCP `annotations` a tool declares, from the two closed sets above.
///
/// `readOnlyHint` lets a client offer a tool without a confirmation step, and
/// `destructiveHint` is what tells it to ask first — a tool that kills panes
/// and one that lists them must not look alike. A tool in neither set is
/// additive: it may create or adjust, never remove what is there.
fn annotations(name: &str) -> Value {
    json!({
        "readOnlyHint": READ_ONLY_TOOLS.contains(&name),
        "destructiveHint": DESTRUCTIVE_TOOLS.contains(&name),
    })
}

fn build_tool(
    name: &str,
    desc: &str,
    properties: Map<String, Value>,
    required: Vec<String>,
) -> Value {
    json!({
        "name": name,
        "description": desc,
        "inputSchema": {
            "type": "object",
            "properties": properties,
            "required": required,
        },
        "annotations": annotations(name),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::CommandFactory;

    fn tools() -> Vec<serde_json::Value> {
        build_mcp_tools_inline(&crate::Cli::command())["tools"]
            .as_array()
            .expect("the document carries a tools array")
            .clone()
    }

    fn tool<'a>(tools: &'a [serde_json::Value], name: &str) -> &'a serde_json::Value {
        tools
            .iter()
            .find(|t| t["name"] == name)
            .unwrap_or_else(|| panic!("no tool named {name}"))
    }

    fn required_of(tool: &serde_json::Value) -> Vec<String> {
        let mut required: Vec<String> = tool["inputSchema"]["required"]
            .as_array()
            .expect("required is an array")
            .iter()
            .map(|v| v.as_str().unwrap().to_string())
            .collect();
        required.sort();
        required
    }

    #[test]
    fn json_schema_has_one_variant_per_subcommand_with_its_arguments() {
        let cmd = crate::Cli::command();
        let schema = clap_command_to_json_schema(&cmd);
        assert_eq!(
            schema["$schema"],
            "https://json-schema.org/draft/2020-12/schema"
        );
        assert_eq!(schema["title"], "gpty CLI");
        assert_eq!(schema["type"], "object");

        let variants = schema["oneOf"].as_array().expect("oneOf is an array");
        let names: Vec<&str> = variants
            .iter()
            .map(|v| v["properties"]["command"]["const"].as_str().unwrap())
            .collect();
        let expected: Vec<&str> = cmd.get_subcommands().map(|s| s.get_name()).collect();
        assert_eq!(names, expected, "one variant per subcommand, in order");

        // A subcommand's variant describes its own arguments and nothing else.
        let inject = variants
            .iter()
            .find(|v| v["properties"]["command"]["const"] == "inject")
            .unwrap();
        let args = &inject["properties"]["args"];
        assert_eq!(args["additionalProperties"], false);
        let props = args["properties"].as_object().unwrap();
        assert!(props.contains_key("pane_id") && props.contains_key("text"));
        assert_eq!(
            props["text"]["description"],
            "Text to send (trailing newline added)"
        );
        assert_eq!(props["text"]["type"], "string");
    }

    /// A property's type is what clap parses, not a blanket "string".
    ///
    /// The manifest called every argument a string — an integer's, a
    /// boolean's and an array's alike — so an MCP client following it sent
    /// `"lines": "200"` and `"args": "a b"`, and the second one reached a
    /// handler expecting an array.
    #[test]
    fn argument_types_are_the_ones_clap_parses() {
        let tools = tools();
        let pane_read = &tool(&tools, "pane-read")["inputSchema"]["properties"];
        assert_eq!(pane_read["lines"]["type"], "integer");
        assert_eq!(pane_read["lines"]["default"], 200);
        let wait = &tool(&tools, "pane-wait")["inputSchema"]["properties"];
        assert_eq!(wait["timeout_ms"]["type"], "integer");
        assert_eq!(wait["timeout_ms"]["default"], 10_000);

        let new_pane = &tool(&tools, "new-pane")["inputSchema"]["properties"];
        assert_eq!(new_pane["focus"]["type"], "boolean");
        assert_eq!(new_pane["focus"]["default"], true);
        assert!(
            new_pane["focus"].get("enum").is_none(),
            "a boolean's true/false is its type, not a closed set of strings"
        );
        assert_eq!(new_pane["tags"]["type"], "array");
        assert_eq!(new_pane["tags"]["items"]["type"], "string");
        assert_eq!(new_pane["args"]["type"], "array");
        assert_eq!(
            new_pane["split"]["enum"],
            json!(["left", "right", "top", "bottom"]),
            "the sides the GUI can build are the ones the schema offers"
        );
        assert_eq!(new_pane["pane_type"]["type"], "string");
        assert_eq!(new_pane["pane_type"]["default"], "terminal");

        let weight = &tool(&tools, "vault-weight")["inputSchema"]["properties"];
        assert_eq!(weight["weight"]["type"], "integer");
        assert_eq!(weight["clear"]["type"], "boolean");
    }

    /// The MCP `annotations` are classified exhaustively: a tool that kills
    /// panes and one that lists them must not look alike to a client deciding
    /// whether to ask first.
    #[test]
    fn every_tool_declares_its_hints() {
        let tools = tools();
        for t in &tools {
            let name = t["name"].as_str().unwrap();
            let read_only = t["annotations"]["readOnlyHint"]
                .as_bool()
                .unwrap_or_else(|| panic!("{name} declares no readOnlyHint"));
            let destructive = t["annotations"]["destructiveHint"]
                .as_bool()
                .unwrap_or_else(|| panic!("{name} declares no destructiveHint"));
            assert!(!read_only || !destructive, "{name} cannot be both");
            assert_eq!(
                read_only,
                READ_ONLY_TOOLS.contains(&name),
                "{name} disagrees with the read-only set"
            );
            assert_eq!(
                destructive,
                DESTRUCTIVE_TOOLS.contains(&name),
                "{name} disagrees with the destructive set"
            );
        }
        // A classified name must still be advertised: a rename would otherwise
        // leave the hint attached to nothing and the tool silently additive.
        for name in READ_ONLY_TOOLS.iter().chain(DESTRUCTIVE_TOOLS) {
            assert!(
                tools.iter().any(|t| t["name"] == *name),
                "classified but not advertised: {name}"
            );
        }
    }

    #[test]
    fn mcp_tool_inputs_name_what_each_command_needs() {
        let tools = tools();
        assert_eq!(required_of(tool(&tools, "kill-pane")), ["pane_id"]);
        assert_eq!(required_of(tool(&tools, "focus-pane")), ["pane_id"]);
        assert_eq!(required_of(tool(&tools, "inject")), ["pane_id", "text"]);
        // Everything `new-pane` takes has a default, so none of it is required
        // — an MCP client may open a pane with no arguments at all.
        assert_eq!(required_of(tool(&tools, "new-pane")), Vec::<String>::new());
        // Vault access names its directory and its own argument in the same
        // spellings the native handlers read; `limit` stays optional.
        assert_eq!(
            required_of(tool(&tools, "vault-search")),
            ["pattern", "vault_path"]
        );
        assert_eq!(
            required_of(tool(&tools, "vault-read")),
            ["path", "vault_path"]
        );
        let vault_search = &tool(&tools, "vault-search")["inputSchema"]["properties"];
        assert!(
            vault_search.get("limit").is_some(),
            "limit must be optional"
        );
        // The authored layer's write is one directed number plus its clear
        // switch; all of the pair's paths are required, the number is not.
        assert_eq!(
            required_of(tool(&tools, "vault-weight")),
            ["src", "target", "vault_path"]
        );
        let vault_weight = &tool(&tools, "vault-weight")["inputSchema"]["properties"];
        assert!(
            vault_weight.get("weight").is_some(),
            "weight must be optional"
        );
        assert!(
            vault_weight.get("clear").is_some(),
            "clear must be optional"
        );
        let new_pane = &tool(&tools, "new-pane")["inputSchema"]["properties"];
        for arg in [
            "pane_type",
            "command",
            "args",
            "split",
            "title",
            "focus",
            "tags",
        ] {
            assert!(new_pane.get(arg).is_some(), "new-pane must expose {arg}");
        }

        for t in &tools {
            let name = t["name"].as_str().unwrap();
            assert_eq!(t["inputSchema"]["type"], "object", "{name}");
            let props = t["inputSchema"]["properties"].as_object().unwrap();
            for r in required_of(t) {
                assert!(
                    props.contains_key(&r),
                    "{name} requires {r} but does not declare it"
                );
            }
        }
    }

    #[test]
    fn mcp_tool_names_are_unique_and_match_the_advertised_list() {
        let tools = tools();
        let names: Vec<String> = tools
            .iter()
            .map(|t| t["name"].as_str().unwrap().to_string())
            .collect();
        let mut sorted = names.clone();
        sorted.sort();
        sorted.dedup();
        assert_eq!(sorted.len(), names.len(), "a tool name is advertised twice");
        assert_eq!(
            mcp_tool_names(&crate::Cli::command()),
            names,
            "the tools/call allow-list is exactly the advertised tools, in order"
        );
    }

    #[test]
    fn mcp_tools_has_expected_commands() {
        let tools = build_mcp_tools_inline(&crate::Cli::command());
        let names: Vec<&str> = tools["tools"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t["name"].as_str().unwrap())
            .collect();
        // Standalone tools
        assert!(names.contains(&"new-pane"));
        assert!(names.contains(&"list-panes"));
        assert!(names.contains(&"kill-pane"));
        assert!(names.contains(&"focus-pane"));
        assert!(names.contains(&"inject"));
        assert!(names.contains(&"version"));
        // Flattened daemon subcommands
        assert!(names.contains(&"daemon-start"));
        assert!(names.contains(&"daemon-stop"));
        assert!(names.contains(&"daemon-status"));
        // Flattened layout subcommands
        assert!(names.contains(&"layout-save"));
        assert!(names.contains(&"layout-load"));
        assert!(names.contains(&"layout-list"));
        // Self-referential tools excluded
        assert!(!names.contains(&"mcp"));
        assert!(!names.contains(&"schema"));
        // `state` declares the pane's own state over the event socket; no IPC
        // method sits behind it, so advertising it would publish a tool that
        // cannot dispatch.
        assert!(!names.contains(&"state"));
        // Plugin admin stays out: install waits on a human, the rest are
        // local state, and `pluginInstall` is deliberately not a tool.
        assert!(!names.contains(&"plugin-install"));
        assert!(!names.contains(&"plugin-list"));
        assert!(!names.contains(&"plugin-run"));
    }
}
