use gpty_ipc::client::IpcClient;

/// `pane-status <pane>`: status primitives for one pane.
/// `pane-status` (no pane): agent-status-list — every pane plus its status.
pub async fn run(client: &IpcClient, pane_id: Option<&str>, json: bool) -> anyhow::Result<()> {
    if let Some(id) = pane_id {
        let params = serde_json::json!({"pane_id": id});
        return super::call_and_format(client, "paneStatus", params, json).await;
    }
    let resp = client.call("listPanes", None).await?;
    if json {
        println!("{}", serde_json::to_string_pretty(&resp)?);
        return Ok(());
    }
    let Some(result) = resp.result else {
        anyhow::bail!("listPanes returned no result");
    };
    let Some(panes) = result.get("panes").and_then(|v| v.as_array()) else {
        anyhow::bail!("listPanes returned no panes array");
    };
    let mut statuses = Vec::new();
    for p in panes {
        let id = p.get("id").and_then(|v| v.as_str()).unwrap_or("");
        let st = client
            .call("paneStatus", Some(serde_json::json!({"pane_id": id})))
            .await?;
        if let Some(s) = st.result {
            statuses.push(serde_json::json!({
                "pane_id": id,
                "label": p.get("label"),
                "type": p.get("type"),
                "status": s,
            }));
        }
    }
    println!(
        "{}",
        serde_json::to_string_pretty(&serde_json::json!({"panes": statuses}))?
    );
    Ok(())
}
