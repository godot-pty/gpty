use crate::ConceptAction;
use gpty_ipc::client::IpcClient;

/// Dispatch a concept subcommand to the IPC handler.
pub async fn run(client: &IpcClient, action: &ConceptAction, json: bool) -> anyhow::Result<()> {
    match action {
        ConceptAction::List => {
            super::call_and_format(client, "conceptList", serde_json::json!({}), json).await
        }
        ConceptAction::Toggle { name } => {
            super::call_and_format(
                client,
                "conceptToggle",
                serde_json::json!({"name": name}),
                json,
            )
            .await
        }
    }
}
