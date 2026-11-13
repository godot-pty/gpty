use gpty_ipc::client::IpcClient;

pub async fn run(client: &IpcClient, json: bool) -> anyhow::Result<()> {
    let resp = client.call("workspaceList", None).await?;
    if json {
        println!("{}", serde_json::to_string_pretty(&resp)?);
    } else if resp.error.is_none()
        && let Some(result) = &resp.result
    {
        if let Some(list) = result.get("workspaces").and_then(|v| v.as_array()) {
            if list.is_empty() {
                println!("No workspaces.");
            } else {
                for w in list {
                    let name = w.get("name").and_then(|v| v.as_str()).unwrap_or("?");
                    let active = w.get("active").and_then(|v| v.as_bool()).unwrap_or(false);
                    let panes = w.get("panes").and_then(|v| v.as_i64()).unwrap_or(0);
                    let mark = if active { "*" } else { " " };
                    println!("{mark} {name}  ({panes} pane(s))");
                }
            }
        } else {
            println!("{}", serde_json::to_string_pretty(result)?);
        }
    }
    super::check_error(&resp)
}
