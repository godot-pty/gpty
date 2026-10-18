use crate::Cli;
use clap::CommandFactory;

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
    let _props = serde_json::Map::new();
    let mut one_of = Vec::new();
    for sub in cmd.get_subcommands() {
        let mut sub_props = serde_json::Map::new();
        for arg in sub.get_arguments() {
            let id = arg.get_id().to_string();
            let mut arg_schema = serde_json::json!({"type": "string", "description": arg.get_help().unwrap_or_default().to_string()});
            let vals = arg.get_possible_values();
            if !vals.is_empty() {
                let enums: Vec<_> = vals
                    .iter()
                    .map(|v| serde_json::Value::String(v.get_name().to_string()))
                    .collect();
                arg_schema["enum"] = serde_json::Value::Array(enums);
            }
            if arg.is_required_set() {
                sub_props.insert(id.clone(), arg_schema);
            } else {
                sub_props.insert(id, arg_schema);
            }
        }
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

pub fn build_mcp_tools_inline(cmd: &clap::Command) -> serde_json::Value {
    let mut tools = Vec::new();
    for sub in cmd.get_subcommands() {
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
        let nested: Vec<_> = sub.get_subcommands().collect();
        if !nested.is_empty() {
            for nested_sub in nested {
                let nested_name = format!("{}-{}", name, nested_sub.get_name());
                let desc = nested_sub.get_about().unwrap_or_default().to_string();
                let (properties, required) = build_args_schema(nested_sub);
                tools.push(build_tool(&nested_name, &desc, properties, required));
            }
        } else {
            let desc = sub.get_about().unwrap_or_default().to_string();
            let (properties, required) = build_args_schema(sub);
            tools.push(build_tool(&name, &desc, properties, required));
        }
    }
    serde_json::json!({ "tools": tools })
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

fn build_args_schema(
    sub: &clap::Command,
) -> (serde_json::Map<String, serde_json::Value>, Vec<String>) {
    let mut properties = serde_json::Map::new();
    let mut required = Vec::new();
    for arg in sub.get_arguments() {
        let id = arg.get_id().to_string();
        let mut arg_schema = serde_json::json!({"type": "string", "description": arg.get_help().unwrap_or_default().to_string()});
        let vals = arg.get_possible_values();
        if !vals.is_empty() {
            let enums: Vec<_> = vals
                .iter()
                .map(|v| serde_json::Value::String(v.get_name().to_string()))
                .collect();
            arg_schema["enum"] = serde_json::Value::Array(enums);
        }
        properties.insert(id.clone(), arg_schema);
        if arg.is_required_set() {
            required.push(id);
        }
    }
    (properties, required)
}

fn build_tool(
    name: &str,
    desc: &str,
    properties: serde_json::Map<String, serde_json::Value>,
    required: Vec<String>,
) -> serde_json::Value {
    serde_json::json!({
        "name": name,
        "description": desc,
        "inputSchema": {
            "type": "object",
            "properties": properties,
            "required": required,
        }
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
