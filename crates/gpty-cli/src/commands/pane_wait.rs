use std::time::Duration;

use gpty_ipc::client::IpcClient;

/// Block until a pane's output matches `pattern` or the deadline passes.
/// The server holds the response, so this derives a client with a read
/// timeout that outlives the server-side deadline (the global `--timeout`
/// is a connection budget, not a wait budget) — from the *dispatched*
/// client, so the endpoint is whatever `--socket`/`GPTY_SOCKET` resolved to.
pub async fn run(
    client: &IpcClient,
    pane_id: &str,
    pattern: &str,
    timeout_ms: u64,
    json: bool,
) -> anyhow::Result<()> {
    let server_timeout = timeout_ms.clamp(100, 60_000);
    let wait_client = client.with_timeout(Duration::from_millis(server_timeout + 2_000));
    let params = serde_json::json!({
        "pane_id": pane_id,
        "pattern": pattern,
        "timeout_ms": server_timeout,
    });
    super::call_and_format(&wait_client, "paneWait", params, json).await
}
