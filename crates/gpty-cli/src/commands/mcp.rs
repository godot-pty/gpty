use std::io::{self, BufRead, Write};

use clap::CommandFactory;
use gpty_ipc::client::IpcClient;
use gpty_ipc::protocol::{JsonRpcError, Request, build_error, build_response};

/// Map a kebab-case MCP tool name to the camelCase IPC method the GUI
/// registers: `pane-read` → `paneRead`, `broadcast` → `broadcast`.
///
/// Derived rather than table-driven: the tool name and the method name are
/// the same identifier in two conventions, and a table silently drifts as
/// soon as a command is added. The previous table omitted `pane-*` and
/// `concept-*`, so six tools answered -32601.
fn tool_to_ipc_method(tool_name: &str) -> String {
    let mut out = String::with_capacity(tool_name.len());
    let mut upper_next = false;
    for ch in tool_name.chars() {
        match ch {
            '-' => upper_next = true,
            _ if upper_next => {
                out.extend(ch.to_uppercase());
                upper_next = false;
            }
            _ => out.push(ch),
        }
    }
    out
}

/// Handle daemon tools locally (no IPC needed). Returns Some(result) if handled, None if not a daemon tool.
async fn run_daemon_tool(tool_name: &str, client: &IpcClient) -> Option<serde_json::Value> {
    match tool_name {
        "daemon-start" => {
            Some(serde_json::json!({"status": "GUI daemon auto-spawns on first tool call"}))
        }
        "daemon-stop" => match client.call("shutdown", Some(serde_json::Value::Null)).await {
            Ok(r) => r.result,
            Err(_) => Some(serde_json::json!({"status": "GUI not running"})),
        },
        "daemon-status" => match client.call("version", None).await {
            Ok(r) => r.result,
            Err(_) => Some(serde_json::json!({"version": null, "status": "not running"})),
        },
        _ => None,
    }
}

/// Run as an MCP server over stdio: read JSON-RPC from stdin, forward to IPC, write to stdout.
pub async fn run(client: &IpcClient) -> anyhow::Result<()> {
    let stdin = io::stdin();
    let mut stdout = io::stdout();

    // Computed once: `tools/call` must reject any name that is not an
    // advertised tool (see `mcp_tool_names`).
    let allowed_tools = super::schema::mcp_tool_names(&crate::Cli::command());

    for line in stdin.lock().lines() {
        let line = line?;
        let line = line.trim().to_string();
        if line.is_empty() {
            continue;
        }

        let req: Request = match serde_json::from_str(&line) {
            Ok(r) => r,
            Err(e) => {
                let resp = build_error(
                    0,
                    JsonRpcError::new(JsonRpcError::PARSE_ERROR, format!("Parse error: {e}")),
                );
                writeln!(stdout, "{}", serde_json::to_string(&resp)?)?;
                stdout.flush()?;
                continue;
            }
        };

        if req.is_notification() {
            continue;
        }

        // Present for every request that reaches here (notifications are
        // dropped above); fall back to 0 only to satisfy the response builder.
        let id = req.id.unwrap_or(0);

        let resp = match req.method.as_str() {
            "tools/list" => {
                let cmd = crate::Cli::command();
                let tools = super::schema::build_mcp_tools_inline(&cmd);
                build_response(id, tools)
            }
            "tools/call" => {
                let params = req.params.unwrap_or(serde_json::Value::Null);
                let tool_name = params.get("name").and_then(|v| v.as_str()).unwrap_or("");
                let args = params
                    .get("arguments")
                    .cloned()
                    .unwrap_or(serde_json::Value::Null);

                if !allowed_tools.iter().any(|name| name == tool_name) {
                    build_error(
                        id,
                        JsonRpcError::new(
                            JsonRpcError::INVALID_PARAMS,
                            format!("Unknown tool: {tool_name}"),
                        ),
                    )
                // Daemon tools are handled locally (no GUI needed)
                } else if let Some(result) = run_daemon_tool(tool_name, client).await {
                    build_response(id, result)
                } else {
                    // Map kebab-case tool name to camelCase IPC method
                    let ipc_method = tool_to_ipc_method(tool_name);
                    match client.call(&ipc_method, Some(args)).await {
                        Ok(r) => {
                            if let Some(err) = r.error {
                                build_error(id, err)
                            } else {
                                build_response(id, r.result.unwrap_or(serde_json::Value::Null))
                            }
                        }
                        Err(e) => build_error(
                            id,
                            JsonRpcError::new(JsonRpcError::INTERNAL_ERROR, e.to_string()),
                        ),
                    }
                }
            }
            "initialize" => build_response(
                id,
                serde_json::json!({
                    "protocolVersion": "2024-11-05",
                    "serverInfo": {"name": "gpty", "version": env!("CARGO_PKG_VERSION")},
                    "capabilities": {"tools": {}}
                }),
            ),
            _ => build_error(
                id,
                JsonRpcError::new(
                    JsonRpcError::METHOD_NOT_FOUND,
                    format!("Unknown MCP method: {}", req.method),
                ),
            ),
        };

        writeln!(stdout, "{}", serde_json::to_string(&resp)?)?;
        stdout.flush()?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Methods the GUI registers on the control socket
    /// (`crates/gpty-gdext/src/ipc.rs`). A tool that resolves to anything
    /// else fails at runtime with -32601 and no test would notice.
    const WORKSPACE_METHODS: &[&str] = &[
        "newPane",
        "listPanes",
        "killPane",
        "focusPane",
        "inject",
        "paneRead",
        "paneStatus",
        "paneRun",
        "paneWait",
        "broadcast",
        "layoutSave",
        "layoutLoad",
        "layoutList",
        "conceptList",
        "conceptToggle",
        "version",
    ];

    /// Every advertised MCP tool must resolve to a registered IPC method.
    /// `daemon-*` tools are answered locally and never reach the socket.
    #[test]
    fn every_mcp_tool_maps_to_a_registered_ipc_method() {
        let tools = crate::commands::schema::build_mcp_tools_inline(&crate::Cli::command());
        let names: Vec<&str> = tools["tools"]
            .as_array()
            .expect("schema exposes a tools array")
            .iter()
            .map(|t| t["name"].as_str().expect("every tool has a name"))
            .collect();
        assert!(!names.is_empty(), "schema must expose tools");

        let mut mapped = Vec::new();
        for name in &names {
            if name.starts_with("daemon-") {
                continue;
            }
            let method = tool_to_ipc_method(name);
            assert!(
                WORKSPACE_METHODS.contains(&method.as_str()),
                "MCP tool '{name}' maps to IPC method '{method}', which the GUI does not register"
            );
            mapped.push(method);
        }

        // No two tools may collapse onto the same method, and the mapping
        // must cover every registered method — both would silently make one
        // tool unreachable while the per-name assertions above still passed.
        let mut unique = mapped.clone();
        unique.sort();
        unique.dedup();
        assert_eq!(unique.len(), mapped.len(), "two tools map to one method");
        assert_eq!(unique.len(), WORKSPACE_METHODS.len());
    }
}
