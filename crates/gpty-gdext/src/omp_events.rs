//! Capability-scoped semantic events emitted by the optional OMP extension.
//!
//! This channel is intentionally separate from workspace-control IPC. A
//! terminal capability can only append bounded observability events for that
//! terminal; it cannot create panes, inject input, or stop gpty.

#[cfg(unix)]
use std::collections::{HashMap, VecDeque};
#[cfg(unix)]
use std::sync::atomic::{AtomicBool, Ordering};
#[cfg(unix)]
use std::sync::{LazyLock, Mutex};

#[cfg(unix)]
use gpty_ipc::server::{HandlerFn, IpcServer};
use serde_json::Value;
#[cfg(unix)]
use serde_json::json;
#[cfg(unix)]
use std::time::Duration;

#[cfg(unix)]
const PROTOCOL_VERSION: u64 = 1;
#[cfg(unix)]
const MAX_GLOBAL_EVENTS: usize = 256;
#[cfg(unix)]
const MAX_SESSION_EVENTS: usize = 64;
#[cfg(unix)]
const MAX_ID_LEN: usize = 128;
#[cfg(unix)]
const MAX_THINKING_BYTES: usize = 8 * 1024;
/// Extension `seq` counters reset in each new omp process; accept the rollover.
#[cfg(unix)]
const SEQ_RESET_CEILING: u64 = 128;

#[cfg(unix)]
const ALLOWED_EVENTS: &[&str] = &[
    "omp.session.bound",
    "omp.session.shutdown",
    "omp.agent.started",
    "omp.agent.settled",
    "omp.turn.started",
    "omp.turn.finished",
    "omp.tool.started",
    "omp.tool.finished",
    "omp.reasoning.delta",
];

#[cfg(unix)]
#[derive(Debug)]
struct SessionCapability {
    capability: String,
    last_seq: u64,
}

#[derive(Debug, Clone)]
pub struct OmpSemanticEvent {
    pub terminal_session_id: String,
    pub omp_session_id: String,
    pub seq: u64,
    pub event: Value,
}

#[cfg(unix)]
static SESSIONS: LazyLock<Mutex<HashMap<String, SessionCapability>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
#[cfg(unix)]
static EVENTS: LazyLock<Mutex<VecDeque<OmpSemanticEvent>>> =
    LazyLock::new(|| Mutex::new(VecDeque::new()));
#[cfg(unix)]
static STARTED: AtomicBool = AtomicBool::new(false);

/// Register one PTY lifetime and return its unguessable session/capability.
#[cfg(unix)]
pub fn register_terminal() -> std::io::Result<(String, String)> {
    let session_id = random_hex(16)?;
    let capability = random_hex(32)?;
    SESSIONS.lock().unwrap().insert(
        session_id.clone(),
        SessionCapability {
            capability: capability.clone(),
            last_seq: 0,
        },
    );
    Ok((session_id, capability))
}

#[cfg(not(unix))]
pub fn register_terminal() -> std::io::Result<(String, String)> {
    Err(std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "OMP event bridge is not yet supported on this platform",
    ))
}

#[cfg(unix)]
pub fn unregister_terminal(session_id: &str) {
    SESSIONS.lock().unwrap().remove(session_id);
    EVENTS
        .lock()
        .unwrap()
        .retain(|event| event.terminal_session_id != session_id);
}

#[cfg(not(unix))]
pub fn unregister_terminal(_session_id: &str) {}

#[cfg(unix)]
pub fn drain_events() -> Vec<OmpSemanticEvent> {
    EVENTS.lock().unwrap().drain(..).collect()
}

#[cfg(not(unix))]
pub fn drain_events() -> Vec<OmpSemanticEvent> {
    Vec::new()
}

#[cfg(unix)]
fn random_hex(bytes: usize) -> std::io::Result<String> {
    use std::io::Read;
    let mut raw = vec![0_u8; bytes];
    std::fs::File::open("/dev/urandom")?.read_exact(&mut raw)?;
    let mut out = String::with_capacity(bytes * 2);
    for byte in raw {
        use std::fmt::Write;
        let _ = write!(out, "{byte:02x}");
    }
    Ok(out)
}

#[cfg(unix)]
fn constant_time_eq(left: &str, right: &str) -> bool {
    if left.len() != right.len() {
        return false;
    }
    left.bytes()
        .zip(right.bytes())
        .fold(0_u8, |diff, (a, b)| diff | (a ^ b))
        == 0
}

#[cfg(unix)]
fn bounded_string<'a>(value: &'a Value, key: &str, max: usize) -> Option<&'a str> {
    value.get(key)?.as_str().filter(|text| text.len() <= max)
}

#[cfg(unix)]
fn accept_event_seq(session: &mut SessionCapability, seq: u64) -> bool {
    if seq <= session.last_seq {
        if seq >= session.last_seq || seq > SEQ_RESET_CEILING {
            return false;
        }
        session.last_seq = 0;
    }
    session.last_seq = seq;
    true
}

#[cfg(unix)]
fn event_handler() -> HandlerFn {
    std::sync::Arc::new(|params| {
        Box::pin(async move {
            let version = params.get("v").and_then(Value::as_u64);
            let terminal_id = bounded_string(&params, "terminal_session_id", MAX_ID_LEN);
            let capability = bounded_string(&params, "capability", 128);
            let omp_session_id =
                bounded_string(&params, "omp_session_id", MAX_ID_LEN).unwrap_or("");
            let seq = params.get("seq").and_then(Value::as_u64);
            let event = params.get("event").and_then(Value::as_object);

            let (Some(terminal_id), Some(capability), Some(seq), Some(event)) =
                (terminal_id, capability, seq, event)
            else {
                return Err(gpty_ipc::protocol::JsonRpcError::new(
                    -32602,
                    "invalid OMP event payload",
                ));
            };
            if version != Some(PROTOCOL_VERSION) {
                return Err(gpty_ipc::protocol::JsonRpcError::new(
                    -32602,
                    "unsupported OMP event protocol",
                ));
            }

            let event_value = Value::Object(event.clone());
            let Some(name) = bounded_string(&event_value, "name", MAX_ID_LEN) else {
                return Err(gpty_ipc::protocol::JsonRpcError::new(
                    -32602,
                    "missing event name",
                ));
            };
            if !ALLOWED_EVENTS.contains(&name) {
                return Err(gpty_ipc::protocol::JsonRpcError::new(
                    -32602,
                    "unsupported OMP event",
                ));
            }
            if name == "omp.reasoning.delta"
                && bounded_string(&event_value, "text", MAX_THINKING_BYTES).is_none()
            {
                return Err(gpty_ipc::protocol::JsonRpcError::new(
                    -32602,
                    "invalid reasoning delta",
                ));
            }

            {
                let mut sessions = SESSIONS.lock().unwrap();
                let Some(session) = sessions.get_mut(terminal_id) else {
                    return Err(gpty_ipc::protocol::JsonRpcError::new(
                        -32002,
                        "unknown or expired terminal session",
                    ));
                };
                if !constant_time_eq(&session.capability, capability) {
                    return Err(gpty_ipc::protocol::JsonRpcError::new(
                        -32001,
                        "invalid event capability",
                    ));
                }
                if !accept_event_seq(session, seq) {
                    return Err(gpty_ipc::protocol::JsonRpcError::new(
                        -32003,
                        "stale event sequence",
                    ));
                }

                let mut queue = EVENTS.lock().unwrap();
                let per_session = queue
                    .iter()
                    .filter(|queued| queued.terminal_session_id == terminal_id)
                    .count();
                if queue.len() >= MAX_GLOBAL_EVENTS || per_session >= MAX_SESSION_EVENTS {
                    return Err(gpty_ipc::protocol::JsonRpcError::new(
                        -32004,
                        "event queue full",
                    ));
                }
                queue.push_back(OmpSemanticEvent {
                    terminal_session_id: terminal_id.to_string(),
                    omp_session_id: omp_session_id.to_string(),
                    seq,
                    event: event_value,
                });
            }

            Ok(json!({"accepted": true, "next_seq": seq + 1}))
        })
    })
}

/// Start the dedicated OMP event listener once per process.
///
/// `serve()` only returns on an unrecoverable I/O error (e.g. a bind
/// failure). The spawned supervisor retries with bounded backoff, so the
/// channel recovers without needing a new terminal spawn to re-trigger it.
pub fn ensure_server_started() {
    #[cfg(unix)]
    if !STARTED.swap(true, Ordering::Relaxed) {
        let socket_path = gpty_ipc::transport::default_event_socket_path();
        crate::RUNTIME.spawn(async move {
            let mut backoff = Duration::from_secs(1);
            loop {
                let mut server = IpcServer::new(&socket_path);
                server.register("ompEvent", event_handler());
                log::info!("OMP event server starting on {socket_path}");
                if let Err(error) = server.serve().await {
                    log::error!("OMP event server error: {error}; retrying in {backoff:?}");
                }
                tokio::time::sleep(backoff).await;
                backoff = (backoff * 2).min(Duration::from_secs(30));
            }
        });
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    fn reset() {
        SESSIONS.lock().unwrap().clear();
        EVENTS.lock().unwrap().clear();
    }

    #[test]
    fn constant_time_comparison_matches_exactly() {
        assert!(constant_time_eq("secret", "secret"));
        assert!(!constant_time_eq("secret", "secreu"));
        assert!(!constant_time_eq("secret", "short"));
    }

    #[test]
    fn accept_event_seq_allows_extension_counter_reset() {
        let mut session = SessionCapability {
            capability: "cap".into(),
            last_seq: 12,
        };
        assert!(accept_event_seq(&mut session, 1));
        assert_eq!(session.last_seq, 1);
        assert!(accept_event_seq(&mut session, 2));
        assert_eq!(session.last_seq, 2);
    }

    #[test]
    fn accept_event_seq_rejects_true_duplicates() {
        let mut session = SessionCapability {
            capability: "cap".into(),
            last_seq: 5,
        };
        assert!(!accept_event_seq(&mut session, 5));
        assert_eq!(session.last_seq, 5);
    }

    #[test]
    fn unregister_expires_session_and_queued_events() {
        reset();
        SESSIONS.lock().unwrap().insert(
            "terminal".into(),
            SessionCapability {
                capability: "cap".into(),
                last_seq: 0,
            },
        );
        EVENTS.lock().unwrap().push_back(OmpSemanticEvent {
            terminal_session_id: "terminal".into(),
            omp_session_id: "omp".into(),
            seq: 1,
            event: json!({"name": "omp.agent.started"}),
        });
        unregister_terminal("terminal");
        assert!(SESSIONS.lock().unwrap().is_empty());
        assert!(EVENTS.lock().unwrap().is_empty());
    }
}
