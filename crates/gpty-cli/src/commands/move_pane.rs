use gpty_ipc::client::IpcClient;

pub async fn run(
    client: &IpcClient,
    panes: &[String],
    workspace: &str,
    json: bool,
) -> anyhow::Result<()> {
    let params = serde_json::json!({"pane": panes, "workspace": workspace});
    super::call_and_format(client, "movePane", params, json).await
}
