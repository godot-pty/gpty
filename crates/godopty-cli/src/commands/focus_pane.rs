use godopty_ipc::client::IpcClient;

pub async fn run(client: &IpcClient, pane_id: &str, json: bool) -> anyhow::Result<()> {
    let params = serde_json::json!({"pane_id": pane_id});
    super::call_and_format(client, "focusPane", params, json).await
}
