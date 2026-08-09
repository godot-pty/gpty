use std::process::{Command, Stdio};
use std::time::Duration;

use crate::DaemonAction;
use gpty_ipc::client::IpcClient;

pub async fn ensure_running(socket_path: &str, timeout: Duration) -> anyhow::Result<()> {
    let client = IpcClient::new(socket_path, Duration::from_secs(1));
    match client.call("version", None).await {
        Ok(_) => return Ok(()),
        Err(_) => {
            if let Some(gui_path) = find_gui_binary() {
                log::info!("spawning GUI: {}", gui_path.display());
                let _child = Command::new(&gui_path)
                    .stdin(Stdio::null())
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .spawn()?;
                let deadline = tokio::time::Instant::now() + timeout;
                while tokio::time::Instant::now() < deadline {
                    let probe = IpcClient::new(socket_path, Duration::from_secs(1));
                    if probe.call("version", None).await.is_ok() {
                        return Ok(());
                    }
                    tokio::time::sleep(Duration::from_millis(300)).await;
                }
            }
        }
    }
    Err(anyhow::anyhow!("could not connect to gpty GUI"))
}

fn find_gui_binary() -> Option<std::path::PathBuf> {
    if let Ok(path) = std::env::var("GPTY_GUI") {
        let p = std::path::PathBuf::from(path);
        if p.exists() {
            return Some(p);
        }
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            for name in &["gpty-editor", "gpty-gui"] {
                let p = dir.join(name);
                if p.exists() {
                    return Some(p);
                }
            }
        }
    }
    None
}

pub async fn run_action(
    action: &DaemonAction,
    client: &IpcClient,
    json: bool,
) -> anyhow::Result<()> {
    match action {
        DaemonAction::Start => {
            println!("GUI daemon should already be running (or auto-spawned).");
            Ok(())
        }
        DaemonAction::Stop => {
            super::call_and_format(client, "shutdown", serde_json::json!({}), json).await
        }
        DaemonAction::Status => match client.call("version", None).await {
            Ok(resp) => {
                if json {
                    println!("{}", serde_json::to_string_pretty(&resp)?);
                } else if let Some(ref result) = resp.result {
                    let v = result
                        .get("version")
                        .and_then(|v| v.as_str())
                        .unwrap_or("unknown");
                    println!("gpty GUI is running (v{v})");
                } else {
                    println!("gpty GUI is running.");
                }
                Ok(())
            }
            Err(_) => {
                println!("gpty GUI is not running.");
                std::process::exit(1);
            }
        },
    }
}
