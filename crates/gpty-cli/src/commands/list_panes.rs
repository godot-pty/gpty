use gpty_ipc::client::IpcClient;

pub async fn run(client: &IpcClient, json: bool) -> anyhow::Result<()> {
    let resp = client.call("listPanes", None).await?;
    if json {
        println!("{}", serde_json::to_string_pretty(&resp)?);
    } else if let Some(ref err) = resp.error {
        anyhow::bail!("rpc error {}: {}", err.code, err.message);
    } else if let Some(ref result) = resp.result {
        // Pretty-print as a table.
        if let Some(panes) = result.get("panes").and_then(|v| v.as_array()) {
            if panes.is_empty() {
                println!("No panes.");
            } else {
                println!(
                    "{:<6} {:<14} {:<20} {:>3} {:>3} {:>3} {:>3}  FOCUS",
                    "ID", "TYPE", "TITLE", "COL", "ROW", "CW", "RH"
                );
                println!("{}", "-".repeat(80));
                for p in panes {
                    let id = p.get("id").and_then(|v| v.as_str()).unwrap_or("?");
                    let ty = p.get("type").and_then(|v| v.as_str()).unwrap_or("?");
                    let title = p.get("title").and_then(|v| v.as_str()).unwrap_or("");
                    let col = p.get("col").and_then(|v| v.as_i64()).unwrap_or(0);
                    let row = p.get("row").and_then(|v| v.as_i64()).unwrap_or(0);
                    let cspan = p.get("cspan").and_then(|v| v.as_i64()).unwrap_or(0);
                    let rspan = p.get("rspan").and_then(|v| v.as_i64()).unwrap_or(0);
                    let focused = p.get("focused").and_then(|v| v.as_bool()).unwrap_or(false);
                    let mark = if focused { "*" } else { " " };
                    println!(
                        "{mark:<1}{id:<5} {ty:<14} {title:<20} {col:>3} {row:>3} {cspan:>3} {rspan:>3}  {focused}"
                    );
                }
            }
        } else {
            println!("{}", serde_json::to_string_pretty(result)?);
        }
    }
    Ok(())
}
