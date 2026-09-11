use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

use crate::DaemonAction;
use gpty_ipc::client::IpcClient;
use gpty_ipc::protocol::JsonRpcError;

/// True when a response carries an authentication failure (code -32001).
fn auth_denied(resp: &gpty_ipc::protocol::Response) -> bool {
    resp.error
        .as_ref()
        .is_some_and(|e| e.code == JsonRpcError::UNAUTHORIZED)
}

const AUTH_HINT: &str =
    "GUI requires GPTY_SECRET authentication; set GPTY_SECRET to match the running GUI";

pub async fn ensure_running(socket_path: &str, timeout: Duration) -> anyhow::Result<()> {
    // Fail fast on insecure socket files (GPTY_SOCKET env hijack) instead
    // of quietly trying to spawn a GUI on a socket we refuse to use.
    if let Err(e) = gpty_ipc::transport::validate_socket_path(socket_path) {
        anyhow::bail!("refusing to use {socket_path}: {e}");
    }
    let client = IpcClient::new(socket_path, Duration::from_secs(1));
    match client.call("version", None).await {
        Ok(resp) if resp.error.is_none() => return Ok(()),
        Ok(resp) if auth_denied(&resp) => anyhow::bail!(AUTH_HINT),
        _ => {
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
                    match probe.call("version", None).await {
                        Ok(resp) if resp.error.is_none() => return Ok(()),
                        Ok(resp) if auth_denied(&resp) => anyhow::bail!(AUTH_HINT),
                        _ => {}
                    }
                    tokio::time::sleep(Duration::from_millis(300)).await;
                }
            }
        }
    }
    Err(anyhow::anyhow!("could not connect to gpty GUI"))
}

/// GUI names to look for beside the CLI: release bundles and `/usr/lib/gpty`
/// hold the export as `gpty-gui` while the CLI owns `gpty`.
const GUI_SIBLING_NAMES: [&str; 2] = ["gpty-editor", "gpty-gui"];

/// macOS bundle layout, relative to the directory holding the bundle.
const MACOS_APP_INTERNALS: &str = "gPTY.app/Contents/MacOS/gPTY";

fn find_gui_binary() -> Option<PathBuf> {
    if let Ok(path) = std::env::var("GPTY_GUI") {
        let p = PathBuf::from(path);
        if gpty_ipc::transport::validate_gui_binary(&p) {
            log::warn!("spawning GUI from GPTY_GUI override: {}", p.display());
            return Some(p);
        }
        log::warn!(
            "ignoring GPTY_GUI override (failed validation): {}",
            p.display()
        );
    }
    let exe = std::env::current_exe().ok()?;
    let dir = exe.parent()?;
    let home = dirs::home_dir();
    let gui = gui_candidates(dir, home.as_deref())
        .into_iter()
        .find(|candidate| launchable(candidate))?;
    log::info!("spawning GUI: {}", gui.display());
    Some(gui)
}

/// GUI locations to try, in priority order: an export shipped beside the CLI
/// (release bundle, `/usr/lib/gpty`), then the macOS bundle — which the release
/// zip puts next to the CLI and a normal install puts under `/Applications`.
fn gui_candidates(exe_dir: &Path, home: Option<&Path>) -> Vec<PathBuf> {
    let mut candidates: Vec<PathBuf> = GUI_SIBLING_NAMES
        .iter()
        .map(|name| exe_dir.join(name))
        .collect();
    candidates.push(exe_dir.join(MACOS_APP_INTERNALS));
    candidates.push(Path::new("/Applications").join(MACOS_APP_INTERNALS));
    if let Some(home) = home {
        candidates.push(home.join("Applications").join(MACOS_APP_INTERNALS));
    }
    candidates
}

/// A discovered GUI must be an absolute regular file that no one else can
/// write. Unlike the `GPTY_GUI` override it need not be owned by this user:
/// an app under `/Applications` is normally root-owned.
fn launchable(path: &Path) -> bool {
    if !path.is_absolute() {
        return false;
    }
    let Ok(meta) = std::fs::metadata(path) else {
        return false;
    };
    if !meta.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if meta.mode() & 0o022 != 0 {
            return false;
        }
    }
    true
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
            Ok(resp) if auth_denied(&resp) => {
                println!(
                    "gpty GUI is running but requires GPTY_SECRET authentication (mismatched GPTY_SECRET)."
                );
                std::process::exit(1);
            }
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

#[cfg(test)]
mod tests {
    use super::*;

    /// A private temp file, mirroring the `validate_gui_binary` tests.
    fn temp_file(name: &str, mode: u32) -> PathBuf {
        let path = std::env::temp_dir().join(format!("gpty-{name}-{}", std::process::id()));
        std::fs::write(&path, b"#!/bin/sh\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(mode)).unwrap();
        }
        #[cfg(not(unix))]
        let _ = mode;
        path
    }

    #[test]
    fn bundle_sibling_outranks_system_locations() {
        let candidates = gui_candidates(Path::new("/opt/gpty"), Some(Path::new("/home/u")));
        assert_eq!(candidates[0], PathBuf::from("/opt/gpty/gpty-editor"));
        assert_eq!(candidates[1], PathBuf::from("/opt/gpty/gpty-gui"));
        assert!(
            candidates.contains(&PathBuf::from("/opt/gpty/gPTY.app/Contents/MacOS/gPTY")),
            "the macOS zip extracts the CLI next to the bundle"
        );
        assert!(candidates.contains(&PathBuf::from("/Applications/gPTY.app/Contents/MacOS/gPTY")));
        assert!(candidates.contains(&PathBuf::from(
            "/home/u/Applications/gPTY.app/Contents/MacOS/gPTY"
        )));
    }

    #[test]
    fn user_applications_dir_needs_a_home() {
        let candidates = gui_candidates(Path::new("/opt/gpty"), None);
        assert_eq!(
            candidates
                .iter()
                .filter(|c| c.to_string_lossy().contains("Applications"))
                .count(),
            1,
            "without a home directory only the system /Applications candidate is offered"
        );
    }

    #[test]
    fn launchable_requires_a_private_regular_file() {
        let ok = temp_file("gui-ok", 0o755);
        assert!(launchable(&ok));

        let world_writable = temp_file("gui-world-writable", 0o777);
        #[cfg(unix)]
        assert!(
            !launchable(&world_writable),
            "a candidate anyone can replace must not be spawned"
        );

        assert!(!launchable(Path::new("/nonexistent/gpty-gui")));
        assert!(!launchable(Path::new("gpty-gui")), "relative path");
        assert!(!launchable(&std::env::temp_dir()), "a directory");

        std::fs::remove_file(&ok).unwrap();
        std::fs::remove_file(&world_writable).unwrap();
    }
}
