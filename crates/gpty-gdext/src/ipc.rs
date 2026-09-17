//! IPC bridge — connects the `gpty-ipc` server to GDScript polling.
//!
//! ## Architecture
//!
//! - An `IpcServer` runs in a tokio task, started at GDExtension init.
//! - `version` requests are handled locally (no GDScript needed).
//! - All other requests are pushed into `PENDING_REQUESTS` with a oneshot
//!   stored in `PENDING_RESPONSES`. GDScript polls `drain_ipc_requests()`
//!   each frame, processes the request, and calls `respond_ipc()`.
//! - The fallback handler imposes a per-method timeout: 5 s for the
//!   poll-loop methods, 70 s for `paneWait` (whose answer is held until the
//!   pattern matches or the request's own ≤60 s deadline), and 300 s for
//!   `pluginInstall`'s human-answered review dialog. If GDScript hasn't
//!   responded by then, the client receives an error.

use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{LazyLock, Mutex};

use gpty_ipc::server::{HandlerFn, IpcServer};
use gpty_ipc::transport;
use tokio::sync::oneshot;

/// A pending IPC request queued for GDScript.
#[derive(Debug)]
pub struct IpcRequest {
    pub id: u64,
    pub method: String,
    pub params: String,
    /// When this request's fallback deadline fires (`fallback_timeout` for the
    /// method). GDScript is told the time remaining so a dialog whose answer
    /// nobody gives can close when the request dies, instead of outliving it
    /// and turning a late click into a response no channel is listening for.
    pub deadline: std::time::Instant,
}

/// Queue of requests waiting for GDScript polling.
pub static PENDING_REQUESTS: std::sync::LazyLock<Mutex<VecDeque<IpcRequest>>> =
    std::sync::LazyLock::new(|| Mutex::new(VecDeque::new()));

/// Pending response channels keyed by request ID.
#[allow(clippy::type_complexity)]
pub static PENDING_RESPONSES: std::sync::LazyLock<
    Mutex<HashMap<u64, oneshot::Sender<(bool, String)>>>,
> = std::sync::LazyLock::new(|| Mutex::new(HashMap::new()));
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

/// The fallback deadline for a GDScript-answered request. The poll loop
/// answers in milliseconds; 5 s covers a stalled frame comfortably.
const GDS_RESPONSE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);
/// The fallback deadline for `pluginInstall`, whose answer waits on a human
/// reading the review dialog.
const PLUGIN_REVIEW_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(300);
/// The fallback deadline for `paneWait`, whose answer is held until the
/// pattern matches or the *request's own* deadline (up to 60 s) passes —
/// GDScript's `_poll_pending_waits` answers at the later of the two, so the
/// fallback must outlive the method's published ceiling or a slow match is
/// reported as `-32000 timeout waiting for GUI response` (the 5 s default
/// made `pane-wait --timeout-ms 60000` a lie: it could never wait past 5 s).
const PANE_WAIT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(70);

/// The fallback deadline for a routed method. Deferred-answer methods
/// (`paneWait`, `pluginInstall`) need deadlines that cover their contracts;
/// everything else answers from the poll loop in milliseconds.
fn fallback_timeout(method_name: &str) -> std::time::Duration {
    match method_name {
        "paneWait" => PANE_WAIT_TIMEOUT,
        "pluginInstall" => PLUGIN_REVIEW_TIMEOUT,
        _ => GDS_RESPONSE_TIMEOUT,
    }
}

/// One request as GDScript receives it, built here rather than in the FFI
/// layer so the shape and the deadline derivation are unit-tested.
#[derive(Debug, PartialEq, Eq)]
pub struct RequestDocument {
    pub id: u64,
    pub method: String,
    pub params: String,
    /// Milliseconds until this request's fallback deadline; 0 once it has
    /// passed. A deferred-answer method reads 0 as "the request is already
    /// gone — do not open a dialog nobody can answer".
    pub timeout_ms: u64,
}

pub fn request_document(req: &IpcRequest) -> RequestDocument {
    request_document_at(req, std::time::Instant::now())
}

fn request_document_at(req: &IpcRequest, now: std::time::Instant) -> RequestDocument {
    RequestDocument {
        id: req.id,
        method: req.method.clone(),
        params: req.params.clone(),
        timeout_ms: req.deadline.saturating_duration_since(now).as_millis() as u64,
    }
}

/// Make a handler that routes a named method through the pending queue.
fn make_gdscript_handler(method: String, timeout: std::time::Duration) -> HandlerFn {
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
                deadline: std::time::Instant::now() + timeout,
            });
        }
        {
            let mut map = PENDING_RESPONSES.lock().unwrap();
            map.insert(id, tx);
        }

        Box::pin(async move {
            match tokio::time::timeout(timeout, rx).await {
                Ok(Ok((true, result))) => {
                    Ok(serde_json::from_str(&result).unwrap_or(serde_json::Value::Null))
                }
                Ok(Ok((false, result))) => {
                    Err(gpty_ipc::protocol::JsonRpcError::new(-32000, result))
                }
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

/// Shutdown handler — answers the client, then asks the GUI to quit.
///
/// `process::exit(0)` used to run *before* the reply, which cost both ends:
/// the client saw an empty socket and reported `invalid response: empty
/// response` for a stop that had already happened, and the exit skipped every
/// teardown — the workspace and settings saves, and whatever scrollback a
/// pane's writer still held. The reply is now written and the quit runs
/// through the scene tree, so `_exit_tree` does the saving.
///
/// This thread must not quit the tree itself: Godot's SceneTree is
/// single-threaded, so the request is a flag that GDScript polls.
static SHUTDOWN_REQUESTED: AtomicBool = AtomicBool::new(false);

/// Take a pending quit request (true once, then false again).
pub fn take_shutdown_request() -> bool {
    SHUTDOWN_REQUESTED.swap(false, Ordering::Relaxed)
}

/// Why this instance could not serve the pane API, for the GUI to show before
/// it quits (taken once, then gone).
///
/// A control socket that cannot bind means this process is a window with no
/// API: the user would have two workspaces and only one of them reachable,
/// which is exactly the state the bind refusal exists to prevent. The reason
/// travels to GDScript so the window can say what happened instead of
/// vanishing.
static STARTUP_FAILURE: LazyLock<Mutex<Option<String>>> = LazyLock::new(|| Mutex::new(None));

pub fn take_startup_failure() -> Option<String> {
    let mut slot = gpty_core::lock::lock_or_warn(&STARTUP_FAILURE, "startup failure")?;
    slot.take()
}

fn shutdown_handler() -> HandlerFn {
    std::sync::Arc::new(|_params| {
        Box::pin(async move {
            SHUTDOWN_REQUESTED.store(true, Ordering::Relaxed);
            Ok(serde_json::json!({"shutting_down": true}))
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
    if let Ok(secret) = std::env::var("GPTY_SECRET")
        && !secret.is_empty()
    {
        server.set_secret(secret);
    }

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
        "paneRead",
        "paneStatus",
        "paneRun",
        "paneWait",
        "broadcast",
        "layoutSave",
        "layoutLoad",
        "layoutList",
        "conceptList",
        "conceptToggle",
        // Deferred-answer methods (see `fallback_timeout`): the plugin
        // install review waits on a human, pane-wait holds until the
        // pattern matches or its own deadline.
        "pluginInstall",
        // A notification, not a request the user drives: `gpty plugin
        // uninstall|enable|disable` fires it after writing the store so a
        // running GUI drops the plugin's profiles live (the refresh is
        // synchronous, so the CLI's answer means the list is up to date).
        "pluginsChanged",
    ];
    for method_name in gdscript_methods {
        server.register(
            method_name,
            make_gdscript_handler(method_name.to_string(), fallback_timeout(method_name)),
        );
    }

    log::info!("IPC server starting on {}", socket_path);
    if let Err(e) = server.serve().await {
        // The server never started, so this instance cannot serve the pane
        // API. Quitting is the correct outcome — a second window whose socket
        // was refused is a workspace nothing can reach — and the reason is
        // recorded for the GUI to show as it goes. `serve()` returns only
        // before the accept loop, so any error here is fatal to the API.
        log::error!("IPC server error: {e}");
        // One short line for the toast (the log above carries the path and the
        // reason): a toast is read at a glance, and `OS.alert` is not an option
        // here — it shells out to zenity/kdialog and *waits for a human*, which
        // hangs a headless run (measured: the smoke's second instance never
        // quit).
        let reason = if e.kind() == std::io::ErrorKind::AlreadyExists {
            "Another gPTY window is already running — this one will close.".to_string()
        } else {
            "gPTY could not start its control socket — this window will close.".to_string()
        };
        if let Some(mut slot) = gpty_core::lock::lock_or_warn(&STARTUP_FAILURE, "startup failure") {
            *slot = Some(reason);
        }
        SHUTDOWN_REQUESTED.store(true, Ordering::Relaxed);
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
    use serial_test::serial;

    /// Clear all static state between tests.
    fn clear_state() {
        PENDING_REQUESTS.lock().unwrap().clear();
        PENDING_RESPONSES.lock().unwrap().clear();
    }

    // A1. drain_returns_empty_when_no_requests
    #[test]
    #[serial]
    fn drain_returns_empty_when_no_requests() {
        clear_state();
        let result = drain_requests();
        assert!(result.is_empty());
    }

    // A2. drain_returns_all_queued_requests
    #[test]
    #[serial]
    fn drain_returns_all_queued_requests() {
        clear_state();
        {
            let mut queue = PENDING_REQUESTS.lock().unwrap();
            let now = std::time::Instant::now();
            queue.push_back(IpcRequest {
                id: 1,
                method: "newPane".into(),
                params: r#"{"type":"terminal"}"#.into(),
                deadline: now + GDS_RESPONSE_TIMEOUT,
            });
            queue.push_back(IpcRequest {
                id: 2,
                method: "listPanes".into(),
                params: "{}".into(),
                deadline: now + GDS_RESPONSE_TIMEOUT,
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
    #[serial]
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
    #[serial]
    fn respond_unknown_id_does_not_panic() {
        clear_state();
        complete_response(999, false, String::new());
        // No assertion needed — the test passes if it doesn't panic.
    }

    // A5. the deferred-answer methods get deadlines that cover their
    // contracts, everything else keeps the poll-loop default
    #[test]
    fn deferred_methods_get_contract_covering_fallbacks() {
        assert_eq!(fallback_timeout("paneWait"), PANE_WAIT_TIMEOUT);
        assert_eq!(fallback_timeout("pluginInstall"), PLUGIN_REVIEW_TIMEOUT);
        assert_eq!(fallback_timeout("newPane"), GDS_RESPONSE_TIMEOUT);
        assert_eq!(fallback_timeout("layoutLoad"), GDS_RESPONSE_TIMEOUT);
        assert!(
            PANE_WAIT_TIMEOUT >= std::time::Duration::from_secs(60),
            "the paneWait fallback must outlive the method's own deadline"
        );
    }

    // A6. the drained document carries the request's *remaining* deadline —
    // 0 once it has passed, never a wrapped value
    #[test]
    fn request_document_carries_the_remaining_deadline() {
        let now = std::time::Instant::now();
        let req = IpcRequest {
            id: 7,
            method: "pluginInstall".into(),
            params: r#"{"id":"owner/demo"}"#.into(),
            deadline: now + PLUGIN_REVIEW_TIMEOUT,
        };
        let fresh = request_document_at(&req, now);
        assert_eq!(fresh.id, 7);
        assert_eq!(fresh.method, "pluginInstall");
        assert_eq!(fresh.params, r#"{"id":"owner/demo"}"#);
        assert!(
            fresh.timeout_ms > 299_000 && fresh.timeout_ms <= 300_000,
            "a fresh request reports (nearly) its whole deadline: {}",
            fresh.timeout_ms
        );

        let halfway = request_document_at(&req, now + std::time::Duration::from_secs(100));
        assert!(
            halfway.timeout_ms > 199_000 && halfway.timeout_ms <= 200_000,
            "the deadline is the time remaining, not the configured duration: {}",
            halfway.timeout_ms
        );

        let late = request_document_at(
            &req,
            now + PLUGIN_REVIEW_TIMEOUT + std::time::Duration::from_secs(5),
        );
        assert_eq!(
            late.timeout_ms, 0,
            "an expired request reports 0, not a wrapped value"
        );
    }

    // A7. the queued request's deadline is its method's fallback, so the value
    // the GUI is handed is the one that will actually kill the request — one
    // source of truth, not a second constant in GDScript.
    #[test]
    #[serial]
    fn a_queued_request_carries_its_methods_fallback_deadline() {
        clear_state();
        let handler =
            make_gdscript_handler("pluginInstall".into(), fallback_timeout("pluginInstall"));
        // Invoking the handler queues the request synchronously and returns the
        // future (dropped here; `clear_state` cleans both maps).
        let future = handler(serde_json::json!({"id": "owner/demo"}));
        let drained = drain_requests();
        assert_eq!(drained.len(), 1);
        let doc = request_document(&drained[0]);
        assert_eq!(doc.method, "pluginInstall");
        assert!(
            doc.timeout_ms > 299_000 && doc.timeout_ms <= 300_000,
            "the GUI must be told the review's own deadline: {}",
            doc.timeout_ms
        );
        drop(future);
        clear_state();
    }
}

// ── Integration tests (B1-B3) ────────────────────────────────
// These start a real IPC server on a temp socket and verify
// client-server interaction without needing Godot/GDScript.

#[cfg(test)]
mod integration_tests {
    use super::*;
    use gpty_ipc::client::IpcClient;
    use serial_test::serial;
    use std::time::Duration;

    /// Clear process-global pending state so a panicked or timed-out test
    /// cannot poison the next one. Shared state MUST be cleaned in every
    /// exit path (AGENTS.md pitfall).
    fn clear_state() {
        PENDING_REQUESTS.lock().unwrap().clear();
        PENDING_RESPONSES.lock().unwrap().clear();
    }

    fn start_test_server(name: &str) -> String {
        let socket_path = format!("/tmp/gpty-ipc-test-{}-{name}.sock", std::process::id());
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
    #[serial]
    async fn version_handler_responds_locally() {
        clear_state();
        let socket_path = start_test_server("b1_version");
        let client = make_client(&socket_path);
        let resp = client
            .call("version", None)
            .await
            .expect("version should succeed");
        let result = resp.result.expect("should have result");
        assert_eq!(result["version"], env!("CARGO_PKG_VERSION"));
        assert_eq!(result["protocol"], "2.0");
        let _ = std::fs::remove_file(&socket_path);
    }
    // B4: a bind refused because another instance holds the socket must leave
    // this process asking to quit, with a reason the GUI can show — the
    // alternative is a second window whose workspace nothing can reach.
    #[tokio::test]
    #[serial]
    async fn a_refused_bind_records_the_failure_and_asks_to_quit() {
        let socket_path = format!("/tmp/gpty-ipc-test-{}-refused.sock", std::process::id());
        let _ = std::fs::remove_file(&socket_path);
        // A live listener stands in for the other instance.
        let live = tokio::net::UnixListener::bind(&socket_path).expect("bind");

        // Returns as soon as `serve()` refuses, so no polling is needed.
        start_ipc_server_inner(&socket_path).await;

        assert!(
            take_shutdown_request(),
            "a refused bind must ask the GUI to quit"
        );
        let reason = take_startup_failure().unwrap_or_default();
        assert!(
            reason.contains("Another gPTY window is already running"),
            "the reason must name the cause, got: {reason}"
        );
        assert!(
            reason.contains("this one will close"),
            "the reason is the line the user reads before the window goes, got: {reason}"
        );
        assert!(
            take_startup_failure().is_none(),
            "the reason is taken once, like the quit request"
        );
        let flag = take_shutdown_request();
        assert!(
            !flag,
            "the quit request is single-shot too, so a shown dialog cannot re-trigger"
        );

        drop(live);
        let _ = std::fs::remove_file(&socket_path);
    }

    // B2: GDScript-routed method times out without polling
    #[tokio::test]
    #[serial]
    async fn gdscript_method_times_out() {
        clear_state();
        let socket_path = start_test_server("b2_timeout");
        let client = make_client(&socket_path);
        let resp = client
            .call("listPanes", None)
            .await
            .expect("should get response");
        assert!(resp.result.is_none(), "expected error, not success");
        let err = resp.error.expect("should have error");
        assert_eq!(err.code, -32000);
        assert!(err.message.contains("timeout"));
        let _ = std::fs::remove_file(&socket_path);
    }

    // B3: GDScript roundtrip via pending queue
    #[tokio::test]
    #[serial]
    async fn gdscript_roundtrip_via_queue() {
        clear_state();
        let socket_path = start_test_server("b3_roundtrip");
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
