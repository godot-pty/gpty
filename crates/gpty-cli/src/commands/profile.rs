use crate::ProfileAction;
use gpty_ipc::client::IpcClient;

pub async fn run(client: &IpcClient, action: &ProfileAction, json: bool) -> anyhow::Result<()> {
    match action {
        ProfileAction::Save { name } => {
            let params = serde_json::json!({"name": name});
            super::call_and_format(client, "profileSave", params, json).await
        }
        ProfileAction::Load { name } => {
            let params = serde_json::json!({"name": name});
            super::call_and_format(client, "profileLoad", params, json).await
        }
        ProfileAction::List => {
            let resp = client.call("profileList", None).await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&resp)?);
            } else if resp.error.is_none()
                && let Some(result) = &resp.result
                && let Some(profiles) = result.get("profiles").and_then(|v| v.as_array())
            {
                for l in profiles {
                    if let Some(s) = l.as_str() {
                        println!("{s}");
                    }
                }
            }
            super::check_error(&resp)
        }
    }
}
