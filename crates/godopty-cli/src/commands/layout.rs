use godopty_ipc::client::IpcClient;
use crate::LayoutAction;

pub async fn run(client: &IpcClient, action: &LayoutAction, json: bool) -> anyhow::Result<()> {
    match action {
        LayoutAction::Save { name } => {
            let params = serde_json::json!({"name": name});
            super::call_and_format(client, "layoutSave", params, json).await
        }
        LayoutAction::Load { name } => {
            let params = serde_json::json!({"name": name});
            super::call_and_format(client, "layoutLoad", params, json).await
        }
        LayoutAction::List => {
            let resp = client.call("layoutList", None).await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&resp)?);
            } else if let Some(ref err) = resp.error {
                anyhow::bail!("rpc error {}: {}", err.code, err.message);
            } else if let Some(ref result) = resp.result {
                if let Some(layouts) = result.get("layouts").and_then(|v| v.as_array()) {
                    for l in layouts {
                        if let Some(s) = l.as_str() {
                            println!("{s}");
                        }
                    }
                }
            }
            Ok(())
        }
    }
}
