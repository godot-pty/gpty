use godopty_ipc::client::IpcClient;

pub async fn run(client: &IpcClient, pane_id: &str, text: &str, json: bool) -> anyhow::Result<()> {
    let params = serde_json::json!({"pane_id": pane_id, "text": text});
    super::call_and_format(client, "inject", params, json).await
}
