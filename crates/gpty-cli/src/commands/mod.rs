//! Command dispatch — maps CLI subcommands to IPC RPC calls.

pub mod concept;
pub mod daemon;
pub(crate) mod focus_pane;
pub(crate) mod inject;
pub(crate) mod kill_pane;
pub(crate) mod layout;
pub(crate) mod list_panes;
pub mod mcp;
pub(crate) mod new_pane;
pub mod schema;

use crate::Commands;
use gpty_ipc::client::IpcClient;
use gpty_ipc::protocol::Response;

/// Dispatch a CLI command to the appropriate handler.
pub async fn dispatch(cmd: &Commands, client: &IpcClient, json: bool) -> anyhow::Result<()> {
    match cmd {
        Commands::NewPane {
            pane_type,
            command,
            split,
            title,
            focus,
        } => {
            new_pane::run(
                client,
                pane_type,
                command.as_deref(),
                split,
                title.as_deref(),
                *focus,
                json,
            )
            .await
        }
        Commands::ListPanes => list_panes::run(client, json).await,
        Commands::KillPane { pane_id } => kill_pane::run(client, pane_id, json).await,
        Commands::FocusPane { pane_id } => focus_pane::run(client, pane_id, json).await,
        Commands::Inject { pane_id, text } => inject::run(client, pane_id, text, json).await,
        Commands::Daemon { action } => daemon::run_action(action, client, json).await,
        Commands::Concept { action } => concept::run(client, action, json).await,
        Commands::Layout { action } => layout::run(client, action, json).await,
        Commands::Schema { .. } | Commands::Version | Commands::Mcp => {
            unreachable!("handled before dispatch")
        }
    }
}

/// Format a JSON-RPC response for output.
pub fn format_response(resp: &Response, json: bool) -> anyhow::Result<()> {
    if json {
        println!("{}", serde_json::to_string_pretty(resp)?);
    } else if let Some(ref err) = resp.error {
        anyhow::bail!("rpc error {}: {}", err.code, err.message);
    } else if let Some(ref result) = resp.result {
        println!("{}", serde_json::to_string_pretty(result)?);
    }
    Ok(())
}

/// Call a method and handle the response.
pub async fn call_and_format(
    client: &IpcClient,
    method: &str,
    params: serde_json::Value,
    json: bool,
) -> anyhow::Result<()> {
    let resp = client.call(method, Some(params)).await?;
    format_response(&resp, json)
}
