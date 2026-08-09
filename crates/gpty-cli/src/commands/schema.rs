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

    #[test]
    fn json_schema_is_valid_json() {
        let schema = clap_command_to_json_schema(&crate::Cli::command());
        let json_str = serde_json::to_string(&schema).unwrap();
        // Must parse as valid JSON.
        let _parsed: serde_json::Value = serde_json::from_str(&json_str).unwrap();
    }

    #[test]
    fn mcp_tools_is_valid_json() {
        let tools = build_mcp_tools_inline(&crate::Cli::command());
        let json_str = serde_json::to_string(&tools).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&json_str).unwrap();
        // Must have a "tools" array.
        assert!(parsed.get("tools").and_then(|v| v.as_array()).is_some());
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
    }
}
