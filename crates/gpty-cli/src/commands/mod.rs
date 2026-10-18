//! Command dispatch — maps CLI subcommands to IPC RPC calls.

pub(crate) mod broadcast;
pub mod concept;
pub mod daemon;
pub(crate) mod focus_pane;
pub(crate) mod inject;
pub(crate) mod kill_pane;
pub(crate) mod layout;
pub(crate) mod list_panes;
pub mod mcp;
pub(crate) mod new_pane;
pub(crate) mod pane_read;
pub(crate) mod pane_run;
pub(crate) mod pane_status;
pub(crate) mod pane_wait;
pub mod plugin;
pub mod schema;
pub mod state;
pub(crate) mod vault;

use crate::Commands;
use gpty_ipc::client::IpcClient;
use gpty_ipc::protocol::Response;
pub async fn dispatch(cmd: &Commands, client: &IpcClient, json: bool) -> anyhow::Result<()> {
    match cmd {
        Commands::NewPane {
            pane_type,
            command,
            args,
            split,
            title,
            focus,
            tags,
        } => {
            new_pane::run(
                client,
                pane_type,
                command.as_deref(),
                args,
                split,
                title.as_deref(),
                *focus,
                tags,
                json,
            )
            .await
        }
        Commands::ListPanes => list_panes::run(client, json).await,
        Commands::KillPane { pane_id } => kill_pane::run(client, pane_id, json).await,
        Commands::FocusPane { pane_id } => focus_pane::run(client, pane_id, json).await,
        Commands::Inject { pane_id, text } => inject::run(client, pane_id, text, json).await,
        Commands::PaneRead { pane_id, lines } => {
            pane_read::run(client, pane_id, *lines, json).await
        }
        Commands::PaneStatus { pane_id } => {
            pane_status::run(client, pane_id.as_deref(), json).await
        }
        Commands::PaneRun { command } => pane_run::run(client, command, json).await,
        Commands::PaneWait {
            pane_id,
            pattern,
            timeout_ms,
        } => pane_wait::run(client, pane_id, pattern, *timeout_ms, json).await,
        Commands::Broadcast { tags, text } => broadcast::run(client, tags, text, json).await,
        Commands::Vault { action } => vault::run(client, action, json).await,
        Commands::Concept { action } => concept::run(client, action, json).await,
        Commands::Layout { action } => layout::run(client, action, json).await,
        Commands::Schema { .. }
        | Commands::Version
        | Commands::Mcp
        | Commands::State { .. }
        | Commands::Daemon { .. }
        | Commands::Plugin { .. } => {
            unreachable!("handled before dispatch")
        }
    }
}

/// Format a JSON-RPC response for output.
///
/// A response that carries an error fails the command in **both** modes. The
/// JSON envelope is printed first, so `--json` keeps stdout parseable and the
/// exit status is the machine-readable success signal — without that, a
/// script probing with `--json` could not tell a completed command from a
/// refused one (and `daemon status --json`, which answers shaped JSON *and*
/// exits 1, was the one command that did it right).
pub fn format_response(resp: &Response, json: bool) -> anyhow::Result<()> {
    if json {
        println!("{}", serde_json::to_string_pretty(resp)?);
    } else if let Some(result) = &resp.result {
        println!("{}", serde_json::to_string_pretty(result)?);
    }
    check_error(resp)
}

/// Propagate a response's error after the caller has emitted its output.
///
/// Custom-output commands (`list-panes`, `layout list`, the all-panes
/// `pane-status`) print their own shapes and share this so the failure
/// message and the exit status stay one definition.
pub fn check_error(resp: &Response) -> anyhow::Result<()> {
    if let Some(err) = &resp.error {
        anyhow::bail!("rpc error {}: {}", err.code, err.message);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use gpty_ipc::protocol::{JsonRpcError, build_error, build_response};

    /// The envelope is printed for parsing, and the failure is propagated:
    /// `--json` is not a mode in which a refused command reports success.
    #[test]
    fn an_error_fails_the_command_in_both_output_modes() {
        let error = build_error(1, JsonRpcError::new(-32000, "refused"));
        assert!(
            format_response(&error, true).is_err(),
            "--json must still fail the command"
        );
        assert!(format_response(&error, false).is_err());

        let ok = build_response(1, serde_json::json!({"ok": true}));
        assert!(format_response(&ok, true).is_ok());
        assert!(format_response(&ok, false).is_ok());
    }

    #[test]
    fn check_error_is_the_shared_failure_rule() {
        let error = build_error(1, JsonRpcError::new(-32001, "nope"));
        let message = check_error(&error).unwrap_err().to_string();
        assert_eq!(message, "rpc error -32001: nope");
        assert!(check_error(&build_response(1, serde_json::json!(null))).is_ok());
    }
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
