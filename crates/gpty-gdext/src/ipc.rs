//! IPC bridge — connects the `gpty-ipc` server to GDScript polling.
//!
//! ## Architecture
//!
//! - An `IpcServer` runs in a tokio task, started at GDExtension init.
//! - `version` requests are handled locally (no GDScript needed).
//! - All other requests are pushed into `PENDING_REQUESTS` with a oneshot
//!   stored in `PENDING_RESPONSES`. GDScript polls `drain_ipc_requests()`
//!   each frame, processes the request, and calls `respond_ipc()`.
//! - The fallback handler imposes a 5-second timeout: if GDScript hasn't
//!   responded by then, the client receives an error.

use std::collections::{HashMap, VecDeque};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};

use gpty_ipc::server::{HandlerFn, IpcServer};
use gpty_ipc::transport;
use tokio::sync::oneshot;

/// A pending IPC request queued for GDScript.
#[derive(Debug)]
pub struct IpcRequest {
    pub id: u64,
    pub method: String,
    pub params: String,
}

/// Queue of requests waiting for GDScript polling.
pub static PENDING_REQUESTS: std::sync::LazyLock<Mutex<VecDeque<IpcRequest>>> =
    std::sync::LazyLock::new(|| Mutex::new(VecDeque::new()));

/// Pending response channels keyed by request ID.
#[allow(clippy::type_complexity)]
pub static PENDING_RESPONSES: std::sync::LazyLock<Mutex<HashMap<u64, oneshot::Sender<(bool, String)>>>> =
    std::sync::LazyLock::new(|| Mutex::new(HashMap::new()));
/// Remove and return all pending requests.
pub fn drain_requests() -> Vec<IpcRequest> {
    let mut queue = PENDING_REQUESTS.lock().unwrap();
    queue.drain(..).collect()
}

/// Complete a pending request's oneshot channel.
pub fn complete_response(id: u64, success: bool, result_json: String) {
    let mut map = PENDING_RESPONSES.lock().unwrap();
    if let Some(tx) = map.remove(&id) {
        let _ = tx.send((success, result_json));
    } else {
        log::warn!("respond_ipc: no pending request for id {id}");
    }
}

/// Make a handler that routes a named method through the pending queue.
fn make_gdscript_handler(method: String) -> HandlerFn {
    std::sync::Arc::new(move |params| {
        let params_json = serde_json::to_string(&params).unwrap_or_default();

        static NEXT_ID: Mutex<u64> = Mutex::new(0);
        let id = {
            let mut n = NEXT_ID.lock().unwrap();
            *n += 1;
            *n
        };

        let (tx, rx) = oneshot::channel();

        {
            let mut queue = PENDING_REQUESTS.lock().unwrap();
            queue.push_back(IpcRequest {
                id,
                method: method.clone(),
                params: params_json,
            });
        }
        {
            let mut map = PENDING_RESPONSES.lock().unwrap();
            map.insert(id, tx);
        }

        Box::pin(async move {
            match tokio::time::timeout(std::time::Duration::from_secs(5), rx).await {
                Ok(Ok((true, result))) => {
                    Ok(serde_json::from_str(&result).unwrap_or(serde_json::Value::Null))
                }
                Ok(Ok((false, result))) => Err(gpty_ipc::protocol::JsonRpcError::new(
                    -32000,
                    result,
                )),
                Ok(Err(_)) => Err(gpty_ipc::protocol::JsonRpcError::new(
                    -32000,
                    "internal error: response channel closed",
                )),
                Err(_elapsed) => {
                    // Clean up both the response channel and the queue entry
                    let mut map = PENDING_RESPONSES.lock().unwrap();
                    map.remove(&id);
                    let mut queue = PENDING_REQUESTS.lock().unwrap();
                    queue.retain(|req| req.id != id);
                    Err(gpty_ipc::protocol::JsonRpcError::new(
                        -32000,
                        "timeout waiting for GUI response",
                    ))
                }
            }
        })
    })
}

/// Version handler — responds locally without GDScript involvement.
fn version_handler() -> HandlerFn {
    std::sync::Arc::new(|_params| {
        Box::pin(async move {
            Ok(serde_json::json!({
                "version": env!("CARGO_PKG_VERSION"),
                "protocol": "2.0"
            }))
        })
    })
}

/// Shutdown handler — responds instantly then exits the process.
fn shutdown_handler() -> HandlerFn {
    std::sync::Arc::new(|_params| {
        Box::pin(async move {
            std::process::exit(0);
        })
    })
}


static STARTED: AtomicBool = AtomicBool::new(false);

/// Ensure the IPC server is started (idempotent).
pub fn ensure_server_started() {
    if !STARTED.swap(true, Ordering::Relaxed) {
        let socket_path = default_socket();
        crate::RUNTIME.spawn(async move {
            start_ipc_server_inner(&socket_path).await;
        });
    }
}

/// Start the IPC server on the given socket path (must run inside the tokio runtime).
pub async fn start_ipc_server_inner(socket_path: &str) {
    let mut server = IpcServer::new(socket_path);

    // version is handled locally — needed by daemon ensure_running().
    server.register("version", version_handler());
    server.register("shutdown", shutdown_handler());

    // All other methods route through GDScript.
    let gdscript_methods = [
        "newPane",
        "listPanes",
        "killPane",
        "focusPane",
        "inject",
        "layoutSave",
        "layoutLoad",
        "layoutList",
    ];
    for method_name in gdscript_methods {
        server.register(method_name, make_gdscript_handler(method_name.to_string()));
    }

    log::info!("IPC server starting on {}", socket_path);
    if let Err(e) = server.serve().await {
        log::error!("IPC server error: {e}");
    }
}

/// Return the default socket path for this platform.
pub fn default_socket() -> String {
    transport::default_socket_path()
}

// ── Tests ────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// Clear all static state between tests.
    fn clear_state() {
        PENDING_REQUESTS.lock().unwrap().clear();
        PENDING_RESPONSES.lock().unwrap().clear();
    }

    // A1. drain_returns_empty_when_no_requests
    #[test]
    fn drain_returns_empty_when_no_requests() {
        clear_state();
        let result = drain_requests();
        assert!(result.is_empty());
    }

    // A2. drain_returns_all_queued_requests
    #[test]
    fn drain_returns_all_queued_requests() {
        clear_state();
        {
            let mut queue = PENDING_REQUESTS.lock().unwrap();
            queue.push_back(IpcRequest {
                id: 1,
                method: "newPane".into(),
                params: r#"{"type":"terminal"}"#.into(),
            });
            queue.push_back(IpcRequest {
                id: 2,
                method: "listPanes".into(),
                params: "{}".into(),
            });
        }
        let drained = drain_requests();
        assert_eq!(drained.len(), 2);
        assert_eq!(drained[0].id, 1);
        assert_eq!(drained[0].method, "newPane");
        assert_eq!(drained[1].id, 2);
        assert_eq!(drained[1].method, "listPanes");
        // Queue should be empty after drain
        assert!(PENDING_REQUESTS.lock().unwrap().is_empty());
    }

    // A3. respond_completes_oneshot
    #[tokio::test]
    async fn respond_completes_oneshot() {
        clear_state();
        let (tx, mut rx) = oneshot::channel();
        {
            let mut map = PENDING_RESPONSES.lock().unwrap();
            map.insert(42, tx);
        }
        complete_response(42, true, r#"{"ok":true}"#.into());
        let (success, json) = rx.try_recv().expect("response should be available");
        assert!(success);
        assert_eq!(json, r#"{"ok":true}"#);
    }

    // A4. respond_unknown_id_does_not_panic
    #[test]
    fn respond_unknown_id_does_not_panic() {
        clear_state();
        complete_response(999, false, String::new());
        // No assertion needed — the test passes if it doesn't panic.
    }
}

// ── Integration tests (B1-B3) ────────────────────────────────
// These start a real IPC server on a temp socket and verify
// client-server interaction without needing Godot/GDScript.

#[cfg(test)]
mod integration_tests {
    use super::*;
    use gpty_ipc::client::IpcClient;
    use std::time::Duration;

    fn start_test_server() -> String {
        let socket_path = format!("/tmp/gpty-ipc-test-{}.sock", std::process::id());
        let _ = std::fs::remove_file(&socket_path);
        let sp = socket_path.clone();
        crate::RUNTIME.spawn(async move {
            start_ipc_server_inner(&sp).await;
        });
        std::thread::sleep(Duration::from_millis(100));
        socket_path
    }

    fn make_client(socket_path: &str) -> IpcClient {
        IpcClient::new(socket_path, Duration::from_secs(10))
    }

    // B1: version responds locally without GDScript polling
    #[tokio::test]
    async fn version_handler_responds_locally() {
        let socket_path = start_test_server();
        let client = make_client(&socket_path);
        let resp = client.call("version", None).await.expect("version should succeed");
        assert!(resp.error.is_none());
        let result = resp.result.expect("should have result");
        assert_eq!(result["version"], env!("CARGO_PKG_VERSION"));
        assert_eq!(result["protocol"], "2.0");
        let _ = std::fs::remove_file(&socket_path);
    }

    // B2: GDScript-routed method times out without polling
    #[tokio::test]
    async fn gdscript_method_times_out() {
        let socket_path = start_test_server();
        let client = make_client(&socket_path);
        let resp = client.call("listPanes", None).await.expect("should get response");
        assert!(resp.result.is_none(), "expected error, not success");
        let err = resp.error.expect("should have error");
        assert_eq!(err.code, -32000);
        assert!(err.message.contains("timeout"));
        let _ = std::fs::remove_file(&socket_path);
    }

    // B3: GDScript roundtrip via pending queue
    #[tokio::test]
    async fn gdscript_roundtrip_via_queue() {
        let socket_path = start_test_server();
        let client_path = socket_path.clone();

        // Spawn client call in background
        let handle = tokio::spawn(async move {
            let c = IpcClient::new(&client_path, Duration::from_secs(10));
            c.call("newPane", Some(serde_json::json!({"type": "terminal"})))
                .await
                .expect("newPane should get response")
        });

        // Poll for the pending request
        let request = loop {
            let drained = drain_requests();
            if let Some(req) = drained.into_iter().next() {
                break req;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        };
        assert_eq!(request.method, "newPane");

        // Simulate GDScript responding
        complete_response(
            request.id,
            true,
            r#"{"pane_id":"T1","type":"terminal"}"#.into(),
        );

        let resp = handle.await.expect("client task should complete");
        assert!(resp.error.is_none());
        let result = resp.result.expect("should have result");
        assert_eq!(result["pane_id"], "T1");
        assert_eq!(result["type"], "terminal");

        let _ = std::fs::remove_file(&socket_path);
    }
}
