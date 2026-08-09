use std::io::{self, BufRead, Write};

use clap::CommandFactory;
use gpty_ipc::client::IpcClient;
use gpty_ipc::protocol::{JsonRpcError, Request, build_error, build_response};

/// Run as an MCP server over stdio: read JSON-RPC from stdin, forward to IPC, write to stdout.
pub async fn run(client: &IpcClient) -> anyhow::Result<()> {
    let stdin = io::stdin();
    let mut stdout = io::stdout();

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

        let resp = match req.method.as_str() {
            "tools/list" => {
                let cmd = crate::Cli::command();
                let tools = super::schema::build_mcp_tools_inline(&cmd);
                build_response(req.id, tools)
            }
            "tools/call" => {
                let params = req.params.unwrap_or(serde_json::Value::Null);
                let tool_name = params.get("name").and_then(|v| v.as_str()).unwrap_or("");
                let args = params
                    .get("arguments")
                    .cloned()
                    .unwrap_or(serde_json::Value::Null);
                match client.call(tool_name, Some(args)).await {
                    Ok(r) => {
                        if let Some(err) = r.error {
                            build_error(req.id, err)
                        } else {
                            build_response(req.id, r.result.unwrap_or(serde_json::Value::Null))
                        }
                    }
                    Err(e) => build_error(
                        req.id,
                        JsonRpcError::new(JsonRpcError::INTERNAL_ERROR, e.to_string()),
                    ),
                }
            }
            "initialize" => build_response(
                req.id,
                serde_json::json!({
                    "protocolVersion": "2024-11-05",
                    "serverInfo": {"name": "gpty", "version": env!("CARGO_PKG_VERSION")},
                    "capabilities": {"tools": {}}
                }),
            ),
            _ => build_error(
                req.id,
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
