use gpty_ipc::client::IpcClient;

/// Change a live pane's own settings through the GUI's closed per-type table.
///
/// One generic verb rather than a flag per pane type: the table lives in
/// GDScript (`PaneTypes.PANE_SETTINGS`) and `pane-settings` publishes it, so a
/// duplicate vocabulary here could only drift from the one the GUI enforces.
/// Display-only and focus-free, like `pane-view`: the pane is configured
/// without being activated, so a script can drive a workspace a person is
/// typing in. The answer reads the pane back — `changed` names the tile keys
/// whose value moved, so a value the pane normalizes is visible instead of
/// reported as a success the caller cannot check.
pub async fn run(
    client: &IpcClient,
    pane_id: &str,
    settings: &[String],
    json: bool,
) -> anyhow::Result<()> {
    let settings = super::settings_args::object_from(settings).map_err(anyhow::Error::msg)?;
    let params = serde_json::json!({"pane_id": pane_id, "settings": settings});
    super::call_and_format(client, "paneSet", params, json).await
}
