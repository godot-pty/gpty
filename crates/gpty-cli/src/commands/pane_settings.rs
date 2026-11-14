use gpty_ipc::client::IpcClient;

/// List the closed per-type settings table the GUI enforces.
///
/// The table is GDScript (`PaneTypes.settings_schema`), so this needs a running
/// GUI and never starts one. It is the discovery half of `pane-set`: a caller
/// that may set a pane's settings has to be able to ask what they are called,
/// and `file`/`ipc` say which source may set each one (`ipc: false` is the
/// user's own record, the pane's identity, or state a restore consumes).
pub async fn run(client: &IpcClient, json: bool) -> anyhow::Result<()> {
    super::call_and_format(client, "paneSettings", serde_json::json!({}), json).await
}
