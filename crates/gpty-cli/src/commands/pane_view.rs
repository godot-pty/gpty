use gpty_ipc::client::IpcClient;

/// Change what a pane shows - the wiki link graph, a note, its view mode.
///
/// Display-only, so it carries no Workspace Trust decision (nothing spawns)
/// and does not take the keyboard: the pane is updated without being
/// activated, which is what lets a script drive a workspace a person is
/// typing in. That also means an empty call must fail: a round-trip that
/// changes nothing and answers `success` reads as "the pane did what I
/// asked", so it is refused here before the socket rather than by the GUI.
pub async fn run(
    client: &IpcClient,
    pane_id: &str,
    graph: bool,
    note: Option<&str>,
    mode: Option<&str>,
    json: bool,
) -> anyhow::Result<()> {
    if !graph && note.is_none() && mode.is_none() {
        anyhow::bail!("pane-view needs one of --graph, --note or --mode");
    }
    let mut params = serde_json::json!({"pane_id": pane_id});
    if graph {
        params["graph"] = serde_json::Value::Bool(true);
    }
    if let Some(note) = note {
        params["note"] = serde_json::Value::String(note.to_string());
    }
    if let Some(mode) = mode {
        params["mode"] = serde_json::Value::String(mode.to_string());
    }
    super::call_and_format(client, "paneView", params, json).await
}
