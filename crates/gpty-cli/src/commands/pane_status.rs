use gpty_ipc::client::IpcClient;

/// `pane-status <pane>`: status primitives for one pane.
/// `pane-status` (no pane): agent-status-list — every pane plus its status.
///
/// The no-pane mode is the same `paneStatus` method with no target, answered
/// by the GUI as one `{panes: [{pane_id, label, type, status}]}` document.
/// Building it here instead (a `listPanes` plus one call per pane) made the
/// `--json` mode print the pane list rather than the statuses, and left the
/// MCP tool — which dispatches straight to `paneStatus` — unable to answer
/// its own no-argument form.
pub async fn run(client: &IpcClient, pane_id: Option<&str>, json: bool) -> anyhow::Result<()> {
    let params = match pane_id {
        Some(id) => serde_json::json!({"pane_id": id}),
        None => serde_json::json!({}),
    };
    super::call_and_format(client, "paneStatus", params, json).await
}
