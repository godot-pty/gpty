//! `gpty state <value>` — declare the agent state of the pane this program
//! runs in.
//!
//! The declaration travels over the **event** socket, not the control socket:
//! a program inside a pane holds exactly one credential, the per-PTY event
//! capability injected at spawn (`GPTY_EVENT_SOCKET`,
//! `GPTY_TERMINAL_SESSION_ID`, `GPTY_EVENT_CAPABILITY`), and a state
//! declaration is display-only. On Windows this is *the* declaration path:
//! ConPTY re-renders its own model and consumes the `gpty_state` OSC before the
//! pane's parser can see it, so a program that lights the badge on Linux has
//! nothing to print there.

use std::time::Duration;

use gpty_ipc::client::IpcClient;

/// Wire event submitted to the event socket (generic name: `state.declared`).
pub const WIRE_EVENT: &str = "gpty.state.declared";

/// Event protocol version the listener accepts.
const PROTOCOL_VERSION: u64 = 1;

/// Declaration values, mirroring `gpty_core::agent_state::AgentState`
/// (`from_declaration`). This copy exists to fail before a round trip and to
/// name the choices in the error; the socket's whitelist stays authoritative.
pub const VALID_STATES: &[&str] = &["idle", "working", "needs-attention", "completed", "failed"];

/// The per-PTY credentials a pane injects into every child's environment.
#[derive(Debug, Clone)]
pub(crate) struct Credentials {
    pub socket_path: String,
    pub terminal_session_id: String,
    pub capability: String,
    pub pane_id: String,
}

/// Map the pane's injected environment to credentials.
///
/// `get` has `std::env::var`'s shape so the mapping and its error messages are
/// testable without touching the process environment — and without the
/// parallel-test race that mutating it would bring.
pub(crate) fn credentials_from_env(
    get: impl Fn(&str) -> Option<String>,
) -> anyhow::Result<Credentials> {
    let required = |key: &str| {
        get(key)
            .filter(|value| !value.is_empty())
            .ok_or_else(|| anyhow::anyhow!("not running inside a gpty pane ({key} is unset)"))
    };
    Ok(Credentials {
        socket_path: required("GPTY_EVENT_SOCKET")?,
        terminal_session_id: required("GPTY_TERMINAL_SESSION_ID")?,
        capability: required("GPTY_EVENT_CAPABILITY")?,
        pane_id: get("GPTY_PANE_ID").unwrap_or_default(),
    })
}

/// Declare this pane's state, reading the credentials the pane injected.
pub async fn run(value: &str, json: bool, timeout: Duration) -> anyhow::Result<()> {
    if !VALID_STATES.contains(&value) {
        anyhow::bail!(
            "invalid state: \"{value}\"\nValid states: {}",
            VALID_STATES.join(", ")
        );
    }
    let credentials = credentials_from_env(|key| std::env::var(key).ok())?;
    declare(&credentials, value, json, timeout).await
}

/// Submit one declaration and report the answer.
pub(crate) async fn declare(
    credentials: &Credentials,
    value: &str,
    json: bool,
    timeout: Duration,
) -> anyhow::Result<()> {
    let client = IpcClient::new(credentials.socket_path.clone(), timeout);
    let response = client
        .call(
            "ompEvent",
            Some(serde_json::json!({
                "v": PROTOCOL_VERSION,
                "terminal_session_id": credentials.terminal_session_id,
                "capability": credentials.capability,
                "event": {"name": WIRE_EVENT, "state": value},
            })),
        )
        .await?;
    if let Some(error) = &response.error {
        // A pane environment that outlived its listener (the GUI restarted, or
        // the shell was re-parented) still carries credentials for a session the
        // running listener never registered. The code alone does not say what to
        // do about it, and there is nothing to retry.
        let hint = if error.code == -32002 {
            "\n  this pane's terminal session is not registered with the running \
             gpty (a stale environment) — run this from a live pane"
        } else {
            ""
        };
        anyhow::bail!("rpc error {}: {}{hint}", error.code, error.message);
    }
    if json {
        println!("{}", serde_json::to_string_pretty(&response)?);
    } else {
        let pane = if credentials.pane_id.is_empty() {
            "this pane".to_string()
        } else {
            credentials.pane_id.clone()
        };
        println!("declared \"{value}\" for {pane}");
    }
    Ok(())
}
