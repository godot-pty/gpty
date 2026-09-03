use gpty_ipc::client::IpcClient;

pub async fn run(client: &IpcClient, command: &str, json: bool) -> anyhow::Result<()> {
    let params = serde_json::json!({"command": command});
    super::call_and_format(client, "paneRun", params, json).await
}
