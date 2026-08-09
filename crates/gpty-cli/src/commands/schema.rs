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
        let desc = sub.get_about().unwrap_or_default().to_string();
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
        tools.push(serde_json::json!({
            "name": name,
            "description": desc,
            "inputSchema": {
                "type": "object",
                "properties": properties,
                "required": required,
            }
        }));
    }
    serde_json::json!({ "tools": tools })
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
        assert!(names.contains(&"new-pane"));
        assert!(names.contains(&"list-panes"));
        assert!(names.contains(&"kill-pane"));
        assert!(names.contains(&"inject"));
    }
}
