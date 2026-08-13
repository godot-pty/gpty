//! In-crate roundtrip tests: a real `gpty-ipc` server on a temp socket
//! plus the real CLI command handlers. Binary crates cannot host `tests/`
//! integration tests, so this module lives in `src/`.
//!
//! The server chmods its socket 0600, satisfying the client-side socket
//! validation (`transport::validate_socket_path`).

use std::sync::{Arc, Mutex};
use std::time::Duration;

use gpty_ipc::client::IpcClient;
use gpty_ipc::server::{HandlerFn, IpcServer};
use serde_json::Value;

use crate::LayoutAction;
use crate::commands;

/// Start an `IpcServer` on a unique temp socket registered with the
/// given handlers. Each handler receives the request params and returns
/// the result value. Returns the socket path.
async fn start_server<F>(name: &str, handlers: Vec<(&str, F)>) -> String
where
    F: Fn(Value) -> Value + Send + Sync + 'static,
{
    let socket_path = format!(
        "{}/gpty-cli-roundtrip-{}-{name}.sock",
        std::env::temp_dir().display(),
        std::process::id()
    );
    let _ = std::fs::remove_file(&socket_path);
    let mut server = IpcServer::new(socket_path.clone());
    for (method, f) in handlers {
        let handler: HandlerFn = Arc::new(move |params| {
            let result: Result<Value, gpty_ipc::protocol::JsonRpcError> = Ok(f(params));
            Box::pin(async move { result })
        });
        server.register(method, handler);
    }
    tokio::spawn(async move {
        let _ = server.serve().await;
    });
    // Yield to the runtime so the server task binds, then poll for the
    // socket file (a blocking sleep would stall the test runtime).
    for _ in 0..100 {
        if std::path::Path::new(&socket_path).exists() {
            return socket_path;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    socket_path
}

#[tokio::test]
async fn new_pane_roundtrip_params_and_output() {
    let seen: Arc<Mutex<Option<Value>>> = Arc::new(Mutex::new(None));
    let seen_h = Arc::clone(&seen);
    let socket = start_server(
        "new_pane",
        vec![("newPane", {
            move |params: Value| {
                *seen_h.lock().unwrap() = Some(params.clone());
                serde_json::json!({"pane_id": "T1", "type": "terminal"})
            }
        })],
    )
    .await;
    let client = IpcClient::new(&socket, Duration::from_secs(5));
    commands::new_pane::run(
        &client,
        "terminal",
        Some("htop"),
        "bottom",
        None,
        true,
        true,
    )
    .await
    .expect("new-pane should succeed");
    let _ = std::fs::remove_file(&socket);

    let params = seen
        .lock()
        .unwrap()
        .take()
        .expect("server handler should have been called");
    assert_eq!(params["type"], "terminal");
    assert_eq!(params["command"], "htop");
    assert_eq!(params["focus"], true);
}

#[tokio::test]
async fn inject_roundtrip() {
    let seen: Arc<Mutex<Option<Value>>> = Arc::new(Mutex::new(None));
    let seen_h = Arc::clone(&seen);
    let socket = start_server(
        "inject",
        vec![("inject", {
            move |params: Value| {
                *seen_h.lock().unwrap() = Some(params.clone());
                serde_json::json!({"success": true})
            }
        })],
    )
    .await;
    let client = IpcClient::new(&socket, Duration::from_secs(5));
    commands::inject::run(&client, "T1", "echo hi", false)
        .await
        .expect("inject should succeed");
    let _ = std::fs::remove_file(&socket);

    let params = seen
        .lock()
        .unwrap()
        .take()
        .expect("server handler should have been called");
    assert_eq!(params["pane_id"], "T1");
    assert_eq!(params["text"], "echo hi");
}

#[tokio::test]
async fn invalid_pane_type_never_reaches_server() {
    let calls: Arc<Mutex<u32>> = Arc::new(Mutex::new(0));
    let calls_h = Arc::clone(&calls);
    let socket = start_server(
        "invalid",
        vec![("newPane", {
            move |_params: Value| {
                *calls_h.lock().unwrap() += 1;
                serde_json::json!({"pane_id": "X"})
            }
        })],
    )
    .await;
    let client = IpcClient::new(&socket, Duration::from_secs(5));
    let err = commands::new_pane::run(&client, "obsever", None, "bottom", None, true, true)
        .await
        .expect_err("invalid pane type must fail client-side");
    let _ = std::fs::remove_file(&socket);

    let msg = err.to_string();
    assert!(msg.contains("did you mean"), "error should suggest: {msg}");
    assert!(
        msg.contains("observer"),
        "error should name observer: {msg}"
    );
    assert_eq!(
        *calls.lock().unwrap(),
        0,
        "server must not be contacted for an invalid pane type"
    );
}

#[tokio::test]
async fn layout_list_roundtrip() {
    let calls: Arc<Mutex<u32>> = Arc::new(Mutex::new(0));
    let calls_h = Arc::clone(&calls);
    let socket = start_server(
        "layout_list",
        vec![("layoutList", {
            move |_params: Value| {
                *calls_h.lock().unwrap() += 1;
                serde_json::json!({"layouts": ["a", "b"]})
            }
        })],
    )
    .await;
    let client = IpcClient::new(&socket, Duration::from_secs(5));
    commands::layout::run(&client, &LayoutAction::List, true)
        .await
        .expect("layout list should succeed");
    let _ = std::fs::remove_file(&socket);
    assert_eq!(
        *calls.lock().unwrap(),
        1,
        "layout list must reach the server exactly once"
    );
}
