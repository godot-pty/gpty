use gpty_ipc::client::IpcClient;

/// Inject `text` into every terminal pane carrying at least one of `tags`.
/// Text is written verbatim; the target shell interprets it (same as inject).
pub async fn run(
    client: &IpcClient,
    tags: &[String],
    text: &str,
    json: bool,
) -> anyhow::Result<()> {
    let params = serde_json::json!({"tags": tags, "text": text});
    super::call_and_format(client, "broadcast", params, json).await
}
