use gpty_ipc::client::IpcClient;

pub async fn run(client: &IpcClient, pane_id: &str, lines: i64, json: bool) -> anyhow::Result<()> {
    let params = serde_json::json!({"pane_id": pane_id, "lines": lines});
    super::call_and_format(client, "paneRead", params, json).await
}
