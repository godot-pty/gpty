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

use crate::commands;
use crate::{DaemonAction, LayoutAction};

/// Start an `IpcServer` on a unique temp socket registered with the
/// given handlers. Each handler receives the request params and returns
/// the result value. Returns the socket path.
async fn start_server<F>(name: &str, handlers: Vec<(&str, F)>) -> String
where
    F: Fn(Value) -> Value + Send + Sync + 'static,
{
    let handlers: Vec<(&str, HandlerFn)> = handlers
        .into_iter()
        .map(|(method, f)| {
            let handler: HandlerFn = Arc::new(move |params| {
                let result: Result<Value, gpty_ipc::protocol::JsonRpcError> = Ok(f(params));
                Box::pin(async move { result })
            });
            (method, handler)
        })
        .collect();
    start_server_with(name, handlers).await
}

/// The same, for handlers that must take time (a held response) — the sync
/// wrapper above cannot sleep on the server's task.
async fn start_server_with(name: &str, handlers: Vec<(&str, HandlerFn)>) -> String {
    let socket_path = format!(
        "{}/gpty-cli-roundtrip-{}-{name}.sock",
        std::env::temp_dir().display(),
        std::process::id()
    );
    let _ = std::fs::remove_file(&socket_path);
    let mut server = IpcServer::new(socket_path.clone());
    for (method, handler) in handlers {
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
        &[],
        "bottom",
        None,
        true,
        &["ci".to_string()],
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
    assert!(
        params.get("args").is_none(),
        "no argv means no `args` key on the wire: {params}"
    );
}

#[tokio::test]
async fn cli_view_roundtrip_carries_argv() {
    let seen: Arc<Mutex<Option<Value>>> = Arc::new(Mutex::new(None));
    let seen_h = Arc::clone(&seen);
    let socket = start_server(
        "cli_view",
        vec![("newPane", {
            move |params: Value| {
                *seen_h.lock().unwrap() = Some(params.clone());
                serde_json::json!({"pane_id": "V1", "type": "cli_view"})
            }
        })],
    )
    .await;
    let client = IpcClient::new(&socket, Duration::from_secs(5));
    commands::new_pane::run(
        &client,
        "cli_view",
        Some("/bin/sh"),
        &["-c".to_string(), "printf marker".to_string()],
        "bottom",
        None,
        true,
        &[],
        true,
    )
    .await
    .expect("cli_view new-pane should succeed");
    let _ = std::fs::remove_file(&socket);

    let params = seen
        .lock()
        .unwrap()
        .take()
        .expect("server handler should have been called");
    assert_eq!(params["type"], "cli_view");
    assert_eq!(params["command"], "/bin/sh");
    assert_eq!(
        params["args"],
        serde_json::json!(["-c", "printf marker"]),
        "argv must reach the GUI as an ordered string array"
    );
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
    let err = commands::new_pane::run(
        &client,
        "obsever",
        None,
        &[],
        "bottom",
        None,
        true,
        &[],
        true,
    )
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

#[test]
fn skill_flag_output_contains_guardrail() {
    let skill = crate::SKILL;
    assert!(
        skill.contains("GPTY_ENV"),
        "bundled SKILL.md must carry the GPTY_ENV guardrail"
    );
}

/// The declaration reaches the event socket as the listener expects it: the
/// `ompEvent` method, the wire name, the state, and the pane's capability.
#[tokio::test]
async fn state_declaration_roundtrip() {
    let seen: Arc<Mutex<Option<Value>>> = Arc::new(Mutex::new(None));
    let seen_h = Arc::clone(&seen);
    let socket = start_server(
        "state",
        vec![("ompEvent", {
            move |params: Value| {
                *seen_h.lock().unwrap() = Some(params.clone());
                serde_json::json!({"accepted": true, "next_seq": 1})
            }
        })],
    )
    .await;
    let credentials = commands::state::Credentials {
        socket_path: socket.clone(),
        terminal_session_id: "session-1".into(),
        capability: "cap-1".into(),
        pane_id: "pane-abc".into(),
    };
    commands::state::declare(
        &credentials,
        "needs-attention",
        true,
        Duration::from_secs(5),
    )
    .await
    .expect("a declaration should succeed");
    let _ = std::fs::remove_file(&socket);

    let params = seen
        .lock()
        .unwrap()
        .take()
        .expect("server handler should have been called");
    assert_eq!(
        params["v"], 1,
        "the listener accepts protocol version 1 only"
    );
    assert_eq!(params["terminal_session_id"], "session-1");
    assert_eq!(params["capability"], "cap-1");
    assert_eq!(params["event"]["name"], commands::state::WIRE_EVENT);
    assert_eq!(params["event"]["state"], "needs-attention");
    assert!(
        params.get("seq").is_none(),
        "a fresh process per declaration has no counter to continue"
    );
}

/// A pane injects exactly three credentials; anything else means the command
/// was not run from one, and the message has to name what is missing.
#[test]
fn state_credentials_come_from_the_pane_environment() {
    let full = |key: &str| match key {
        "GPTY_EVENT_SOCKET" => Some("/run/user/1000/gpty-events.sock".to_string()),
        "GPTY_TERMINAL_SESSION_ID" => Some("session-1".to_string()),
        "GPTY_EVENT_CAPABILITY" => Some("cap-1".to_string()),
        "GPTY_PANE_ID" => Some("pane-abc".to_string()),
        _ => None,
    };
    let credentials = commands::state::credentials_from_env(full).expect("all present");
    assert_eq!(credentials.socket_path, "/run/user/1000/gpty-events.sock");
    assert_eq!(credentials.terminal_session_id, "session-1");
    assert_eq!(credentials.capability, "cap-1");
    assert_eq!(credentials.pane_id, "pane-abc");

    // An empty value is unset: a layout can carry an empty variable, and a
    // capability of "" would only fail later as a confusing rpc error.
    for missing in [
        "GPTY_EVENT_SOCKET",
        "GPTY_TERMINAL_SESSION_ID",
        "GPTY_EVENT_CAPABILITY",
    ] {
        let error = commands::state::credentials_from_env(|key| {
            if key == missing {
                Some(String::new())
            } else {
                full(key)
            }
        })
        .expect_err("a missing credential must fail");
        assert!(
            error.to_string().contains(missing),
            "the error must name {missing}: {error}"
        );
    }
}

#[tokio::test]
async fn invalid_state_never_reaches_socket() {
    let error = commands::state::run("wroking", false, Duration::from_secs(5))
        .await
        .expect_err("an unknown state must fail client-side");
    let message = error.to_string();
    assert!(
        message.contains("needs-attention"),
        "the refusal must list the valid states: {message}"
    );
}

/// The install review handshake: the CLI sends the manifest summary over
/// `pluginInstall` and the GUI's verdict decides whether anything installs.
#[tokio::test]
async fn plugin_install_review_accepts() {
    let seen: Arc<Mutex<Option<Value>>> = Arc::new(Mutex::new(None));
    let seen_h = Arc::clone(&seen);
    let socket = start_server(
        "plugin_review_accept",
        vec![("pluginInstall", {
            move |params: Value| {
                *seen_h.lock().unwrap() = Some(params.clone());
                serde_json::json!({"accepted": true})
            }
        })],
    )
    .await;
    let client = IpcClient::new(&socket, Duration::from_secs(5));
    let summary = serde_json::json!({
        "id": "owner/demo",
        "name": "Demo",
        "version": "1.0.0",
        "revision": "a1b2c3d4e5f6",
        "source": "github.com/owner/demo",
        "actions": [],
    });
    let accepted = commands::plugin::review_install(&client, &summary)
        .await
        .expect("an accepted review is a successful handshake");
    assert!(accepted);
    let _ = std::fs::remove_file(&socket);

    let params = seen
        .lock()
        .unwrap()
        .take()
        .expect("server handler should have been called");
    assert_eq!(params["id"], "owner/demo");
    assert_eq!(params["revision"], "a1b2c3d4e5f6");
    assert_eq!(params["name"], "Demo");
}

/// A decline is a verdict, not an error: the CLI reports it as a refusal and
/// the caller refuses to install.
#[tokio::test]
async fn plugin_install_review_declines() {
    let socket = start_server(
        "plugin_review_decline",
        vec![(
            "pluginInstall",
            |_params: Value| serde_json::json!({"accepted": false}),
        )],
    )
    .await;
    let client = IpcClient::new(&socket, Duration::from_secs(5));
    let accepted = commands::plugin::review_install(
        &client,
        &serde_json::json!({"id": "owner/demo", "revision": "a1b2c3d4e5f6"}),
    )
    .await
    .expect("a decline still arrives as a handshake answer");
    assert!(!accepted, "declined means the CLI must not install");
    let _ = std::fs::remove_file(&socket);
}

/// No GUI answering (disconnected, `--no-daemon` with nothing running) is
/// the fail-closed side of the handshake: the install must not proceed on
/// silence, so the client error propagates.
#[tokio::test]
async fn plugin_install_review_fails_closed_without_a_gui() {
    let missing = format!(
        "{}/gpty-cli-roundtrip-no-such-socket.sock",
        std::env::temp_dir().display()
    );
    let _ = std::fs::remove_file(&missing);
    let client = IpcClient::new(&missing, Duration::from_secs(2));
    let error = commands::plugin::review_install(
        &client,
        &serde_json::json!({"id": "owner/demo", "revision": "a1b2c3d4e5f6"}),
    )
    .await
    .expect_err("no listener must fail the review");
    assert!(!error.to_string().is_empty());
}

/// `pane-wait --socket <path>` used to be silently ignored: the command built
/// its own client from the platform default socket, so neither the flag nor
/// `GPTY_SOCKET` had any effect on it while every other command honored them.
/// It now derives its client from the dispatched one, so the resolved endpoint
/// is the one that carries the request.
#[tokio::test]
async fn pane_wait_reaches_the_resolved_socket() {
    let socket = start_server(
        "pane_wait_socket",
        vec![(
            "paneWait",
            |_params: Value| serde_json::json!({"matched": true, "line": "from-test-server"}),
        )],
    )
    .await;
    // Exactly how `main.rs` builds the dispatched client from `--socket` /
    // `GPTY_SOCKET` / the platform default.
    let client = IpcClient::new(&socket, Duration::from_secs(5));
    commands::pane_wait::run(&client, "pane-x", "needle", 500, true)
        .await
        .expect("pane-wait must reach the server its socket names");
    let _ = std::fs::remove_file(&socket);
}

/// The wait's own deadline, not the connection budget: the server holds the
/// response until the pattern matches or `timeout_ms` passes, so the command
/// must not give up while the answer is still coming.
#[tokio::test]
async fn pane_wait_outlives_the_connection_budget() {
    let held: HandlerFn = Arc::new(|_params| {
        Box::pin(async {
            tokio::time::sleep(Duration::from_millis(300)).await;
            Ok(serde_json::json!({"matched": true, "line": "late"}))
        })
    });
    let socket = start_server_with("pane_wait_budget", vec![("paneWait", held)]).await;
    // A budget that expires long before the server answers: using the
    // dispatched client as-is would time the wait out.
    let client = IpcClient::new(&socket, Duration::from_millis(50));
    commands::pane_wait::run(&client, "pane-x", "needle", 500, true)
        .await
        .expect("a held response must outlive the connection budget");
    let _ = std::fs::remove_file(&socket);
}

/// The admin actions' notification. A running GUI has to re-read the plugin
/// store after `uninstall`/`enable`/`disable` — before this it kept listing an
/// uninstalled plugin's profiles until a restart — but the CLI must stay
/// usable with no GUI, and an admin action must not start one. So the notice
/// is best-effort in exactly one direction: delivered when a GUI is
/// listening, dropped silently when none is, and never in place of the
/// action's own answer.
#[tokio::test]
async fn plugin_admin_notice_reaches_a_gui_and_is_silent_without_one() {
    let seen: Arc<Mutex<Option<Value>>> = Arc::new(Mutex::new(None));
    let seen_h = Arc::clone(&seen);
    let socket = start_server(
        "plugins_changed",
        vec![("pluginsChanged", {
            move |params: Value| {
                *seen_h.lock().unwrap() = Some(params.clone());
                serde_json::json!({"refreshed": true})
            }
        })],
    )
    .await;

    commands::plugin::notify_store_changed(&socket, "uninstall", "godot-pty/gpty-omp", Ok(()))
        .await
        .expect("notifying a listening GUI must succeed");
    let sent = seen
        .lock()
        .unwrap()
        .clone()
        .expect("the GUI must receive the notice");
    assert_eq!(sent["action"], "uninstall", "the action travels");
    assert_eq!(
        sent["id"], "godot-pty/gpty-omp",
        "and the plugin it changed"
    );

    // No GUI: the socket is absent, so nothing is delivered — and that is
    // not the admin action's problem.
    let absent = format!(
        "{}/gpty-cli-roundtrip-{}-no-gui.sock",
        std::env::temp_dir().display(),
        std::process::id()
    );
    let _ = std::fs::remove_file(&absent);
    commands::plugin::notify_store_changed(&absent, "disable", "godot-pty/gpty-omp", Ok(()))
        .await
        .expect("a missing GUI must not fail the admin action");

    // A failed action surfaces its own error and sends nothing: the store was
    // never written, so there is nothing for the GUI to re-read.
    *seen.lock().unwrap() = None;
    let error = commands::plugin::notify_store_changed(
        &socket,
        "disable",
        "godot-pty/gpty-omp",
        Err(anyhow::anyhow!("plugin `x` is not installed")),
    )
    .await
    .expect_err("the action's error must surface");
    assert!(error.to_string().contains("not installed"));
    assert!(
        seen.lock().unwrap().is_none(),
        "a failed action must not notify: {sent:?}"
    );

    let _ = std::fs::remove_file(&socket);
}

// ── GUI spawn policy ──────────────────────────────────────────────────
//
// Which commands may start a GUI, what a command with no GUI says, and what
// a GUI that cannot start reports. The live path (against a real GUI) is the
// smoke's job; these are the decisions and the diagnostics.

/// Every command's side of the gate, so a new subcommand cannot pick one by
/// accident: `may_autospawn` is exhaustive, and this table is the record of
/// what each side means.
#[test]
fn spawn_policy_is_deliberate_per_command() {
    let cases: &[(&[&str], bool)] = &[
        // A fresh GUI can satisfy these two.
        (&["gpty", "new-pane"], true),
        (&["gpty", "layout", "load", "Agent Workspace"], true),
        // Everything else needs a workspace that already exists.
        (&["gpty", "list-panes"], false),
        (&["gpty", "kill-pane", "T1"], false),
        (&["gpty", "focus-pane", "T1"], false),
        (&["gpty", "inject", "T1", "--text", "hi"], false),
        (&["gpty", "pane-read", "T1"], false),
        (&["gpty", "pane-status"], false),
        (&["gpty", "pane-run", "--command", "ls"], false),
        (&["gpty", "pane-wait", "T1", "--pattern", "x"], false),
        (
            &["gpty", "broadcast", "--tags", "ci", "--text", "hi"],
            false,
        ),
        (&["gpty", "concept", "list"], false),
        (&["gpty", "concept", "toggle", "cat"], false),
        (&["gpty", "layout", "save", "Saved"], false),
        (&["gpty", "layout", "list"], false),
        (&["gpty", "daemon", "status"], false),
        (&["gpty", "daemon", "stop"], false),
        (&["gpty", "mcp"], false),
        (&["gpty", "state", "idle"], false),
        (&["gpty", "schema"], false),
        (&["gpty", "version"], false),
        // Handled in their own arms before the gate: `plugin install` starts
        // a GUI for the review dialog itself and `daemon start` is the one
        // explicit spawner, so neither may fall through to the generic gate.
        (&["gpty", "plugin", "install", "owner/repo"], false),
        (&["gpty", "plugin", "list"], false),
    ];
    for (argv, expected) in cases {
        let cli = <crate::Cli as clap::Parser>::try_parse_from(*argv)
            .unwrap_or_else(|e| panic!("{argv:?} did not parse: {e}"));
        let command = cli.command.as_ref().expect("a subcommand was parsed");
        assert_eq!(crate::may_autospawn(command), *expected, "argv: {argv:?}");
    }
}

/// A missing listener is recognized through whatever context a command has
/// wrapped around the client error — that is what routes the never-spawn set
/// and `--no-daemon` to the shared hint instead of a raw connect error.
#[tokio::test]
async fn a_missing_listener_is_recognized_as_not_running() {
    let missing = format!(
        "{}/gpty-cli-roundtrip-{}-spawn-policy.sock",
        std::env::temp_dir().display(),
        std::process::id()
    );
    let _ = std::fs::remove_file(&missing);
    let client = IpcClient::new(&missing, Duration::from_secs(1));
    let error = client
        .call("listPanes", None)
        .await
        .expect_err("no listener must fail");
    let error = anyhow::Error::new(error);
    assert!(commands::daemon::is_not_running(&error), "{error}");
    let wrapped = error.context("while listing panes");
    assert!(
        commands::daemon::is_not_running(&wrapped),
        "context must not hide the cause: {wrapped}"
    );
    assert_eq!(
        commands::daemon::NO_GUI_HINT,
        "no gpty GUI is running (start one with `gpty daemon start`)"
    );
}

/// A refusal is not absence: a regular file where the socket should be keeps
/// its own message (the client validates before sending anything), so the
/// no-GUI hint cannot mask a hijack guard.
#[cfg(unix)]
#[tokio::test]
async fn a_refused_endpoint_is_not_reported_as_not_running() {
    let path = format!(
        "{}/gpty-cli-roundtrip-{}-not-a-socket",
        std::env::temp_dir().display(),
        std::process::id()
    );
    std::fs::write(&path, b"not a socket").unwrap();
    let client = IpcClient::new(&path, Duration::from_secs(1));
    let error = anyhow::Error::new(
        client
            .call("listPanes", None)
            .await
            .expect_err("a regular file is refused"),
    );
    assert!(!commands::daemon::is_not_running(&error), "{error}");
    let _ = std::fs::remove_file(&path);
}

/// `--no-daemon` and `daemon start` contradict each other; the flag wins so
/// "never spawn" stays true everywhere.
#[tokio::test]
async fn daemon_start_refuses_under_no_daemon() {
    let error = commands::daemon::run(
        &DaemonAction::Start,
        "/nonexistent/gpty.sock",
        Duration::from_secs(1),
        false,
        true,
    )
    .await
    .expect_err("--no-daemon and start contradict each other");
    assert!(error.to_string().contains("--no-daemon"), "{error}");
}

/// The endpoint `start_server` will bind, so a test can point the CLI at it
/// before a server exists there (the auto-spawn case).
#[cfg(unix)]
fn spawn_socket(name: &str) -> String {
    let path = format!(
        "{}/gpty-cli-roundtrip-{}-{name}.sock",
        std::env::temp_dir().display(),
        std::process::id()
    );
    let _ = std::fs::remove_file(&path);
    path
}

/// An executable script standing in for the GUI binary; whatever proves the
/// spawner ran is a file the script writes. `validate_gui_binary` holds it to
/// an absolute, user-owned, private regular file — hence the 0700 mode.
#[cfg(unix)]
fn fake_gui(name: &str, body: &str) -> std::path::PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let path =
        std::env::temp_dir().join(format!("gpty-cli-fake-gui-{}-{name}", std::process::id()));
    std::fs::write(&path, format!("#!/bin/sh\n{body}")).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
    path
}

/// `GPTY_GUI` is process-global, and cargo runs a binary's tests on parallel
/// threads: every test that points the spawner at a fake GUI holds this lock
/// and restores the previous value on drop (including on panic).
#[cfg(unix)]
fn spawn_env_lock() -> std::sync::MutexGuard<'static, ()> {
    static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
    LOCK.lock().unwrap_or_else(|e| e.into_inner())
}

#[cfg(unix)]
struct GuiOverride {
    previous: Option<std::ffi::OsString>,
}

#[cfg(unix)]
impl GuiOverride {
    fn set(path: &std::path::Path) -> Self {
        let previous = std::env::var_os("GPTY_GUI");
        unsafe { std::env::set_var("GPTY_GUI", path) };
        Self { previous }
    }
}

#[cfg(unix)]
impl Drop for GuiOverride {
    fn drop(&mut self) {
        unsafe {
            match self.previous.take() {
                Some(value) => std::env::set_var("GPTY_GUI", value),
                None => std::env::remove_var("GPTY_GUI"),
            }
        }
    }
}

/// The spawner runs only when the endpoint is genuinely empty: a live server
/// is never shadowed by a freshly started GUI.
#[cfg(unix)]
#[tokio::test]
async fn a_running_gui_is_never_spawned_over() {
    let _guard = spawn_env_lock();
    let socket = spawn_socket("spawn_live");
    let marker = std::env::temp_dir().join(format!("gpty-cli-spawn-live-{}", std::process::id()));
    let _ = std::fs::remove_file(&marker);
    let gui = fake_gui(
        "live",
        &format!("echo started >> {}\nsleep 2\n", marker.display()),
    );
    let _override = GuiOverride::set(&gui);
    let _server = start_server(
        "spawn_live",
        vec![(
            "version",
            |_p: Value| serde_json::json!({"version": "9.9.9"}),
        )],
    )
    .await;

    commands::daemon::ensure_running(&socket, Duration::from_secs(2))
        .await
        .expect("a running GUI needs no spawn");
    assert!(
        !marker.exists(),
        "a live endpoint must not be spawned over ({marker:?})"
    );
    let _ = std::fs::remove_file(&marker);
    let _ = std::fs::remove_file(&gui);
    let _ = std::fs::remove_file(&socket);
}

/// A dead endpoint starts the discovered GUI exactly once — not once per
/// poll — and a GUI that never binds is reported against the endpoint.
#[cfg(unix)]
#[tokio::test]
async fn a_dead_endpoint_spawns_once_and_reports_the_timeout() {
    let _guard = spawn_env_lock();
    let socket = spawn_socket("spawn_dead");
    let marker = std::env::temp_dir().join(format!("gpty-cli-spawn-dead-{}", std::process::id()));
    let _ = std::fs::remove_file(&marker);
    let gui = fake_gui(
        "dead",
        &format!("echo started >> {}\nsleep 3\n", marker.display()),
    );
    let _override = GuiOverride::set(&gui);

    let error = commands::daemon::ensure_running(&socket, Duration::from_millis(900))
        .await
        .expect_err("a GUI that never binds must fail");
    assert!(
        error.to_string().contains("did not answer"),
        "the failure names the endpoint and the timeout: {error}"
    );
    let attempts = std::fs::read_to_string(&marker).unwrap_or_default();
    assert_eq!(
        attempts.lines().count(),
        1,
        "the GUI is spawned exactly once, not once per poll: {attempts:?}"
    );
    let _ = std::fs::remove_file(&marker);
    let _ = std::fs::remove_file(&gui);
}

/// A GUI that cannot start is reported with its own words, and at once:
/// waiting out the whole budget with the child's stderr discarded is what the
/// old spawner did.
#[cfg(unix)]
#[tokio::test]
async fn a_gui_that_dies_reports_its_own_output() {
    let _guard = spawn_env_lock();
    let socket = spawn_socket("dead_gui");
    let gui = fake_gui("dies", "echo 'boom: no display' >&2\nexit 3\n");
    let _override = GuiOverride::set(&gui);

    let started = std::time::Instant::now();
    let error = commands::daemon::ensure_running(&socket, Duration::from_secs(30))
        .await
        .expect_err("a GUI that exits cannot serve");
    let message = error.to_string();
    assert!(message.contains("boom: no display"), "{message}");
    assert!(message.contains("exited immediately"), "{message}");
    assert!(
        started.elapsed() < Duration::from_secs(5),
        "the child's exit must end the wait, not the 30 s budget: {message}"
    );
    let _ = std::fs::remove_file(&gui);
}

/// Whoever brings the endpoint up wins: one that appears during the wait is
/// adopted. This is the concurrent-`new-pane` property — the loser's GUI
/// refuses the bind (one instance owns the endpoint) and this call reaches
/// the winner.
#[cfg(unix)]
#[tokio::test]
async fn a_gui_that_appears_during_the_wait_is_adopted() {
    let _guard = spawn_env_lock();
    let socket = spawn_socket("late_gui");
    let gui = fake_gui("late", "sleep 3\n");
    let _override = GuiOverride::set(&gui);

    let waiting = {
        let socket = socket.clone();
        tokio::spawn(async move {
            commands::daemon::ensure_running(&socket, Duration::from_secs(5)).await
        })
    };
    tokio::time::sleep(Duration::from_millis(700)).await;
    let late = start_server(
        "late_gui",
        vec![(
            "version",
            |_p: Value| serde_json::json!({"version": "1.2.3"}),
        )],
    )
    .await;
    assert_eq!(late, socket, "the test server must bind the awaited path");

    let result = waiting.await.expect("the wait task must not panic");
    assert!(result.is_ok(), "{result:?}");
    let _ = std::fs::remove_file(&late);
    let _ = std::fs::remove_file(&gui);
}

/// `daemon status` reports and never starts what it checks; `daemon stop`
/// with nothing running is an idempotent no-op. The marker script proves
/// neither touched the spawner.
#[cfg(unix)]
#[tokio::test]
async fn daemon_status_never_spawns_and_stop_is_a_no_op() {
    let _guard = spawn_env_lock();
    let marker = std::env::temp_dir().join(format!("gpty-cli-spawn-name-{}", std::process::id()));
    let _ = std::fs::remove_file(&marker);
    let gui = fake_gui(
        "status",
        &format!("echo started >> {}\nsleep 2\n", marker.display()),
    );
    let _override = GuiOverride::set(&gui);
    let socket = spawn_socket("status_stop");

    let code = commands::daemon::run(
        &DaemonAction::Status,
        &socket,
        Duration::from_secs(1),
        false,
        false,
    )
    .await
    .expect("status reports a missing GUI, it does not fail");
    assert_eq!(code, 1, "not running is a nonzero status");

    let code = commands::daemon::run(
        &DaemonAction::Stop,
        &socket,
        Duration::from_secs(1),
        false,
        false,
    )
    .await
    .expect("stopping nothing is a no-op");
    assert_eq!(code, 0, "stopping nothing reaches the desired state");

    assert!(
        !marker.exists(),
        "status/stop must never start a GUI ({marker:?})"
    );
    let _ = std::fs::remove_file(&marker);
    let _ = std::fs::remove_file(&gui);
}
