//! Capability-scoped semantic events emitted by the optional OMP extension.
//!
//! This channel is intentionally separate from workspace-control IPC. A
//! terminal capability can only append bounded observability events for that
//! terminal; it cannot create panes, inject input, or stop gpty.

use std::collections::{HashMap, VecDeque};

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use std::sync::{LazyLock, Mutex};

use gpty_ipc::server::{HandlerFn, IpcServer};
use serde_json::Value;

use serde_json::json;

use std::time::{Duration, Instant};

const PROTOCOL_VERSION: u64 = 1;

/// Bounds on the queue between the event socket and the frame's drain.
///
/// The old 64-per-session cap was smaller than a single frame's burst of
/// reasoning deltas once the GUI was busy: the socket answered `event queue
/// full`, the extension's fire-and-forget producer swallowed it, and the
/// pane's text lost chunks mid-sentence. The producer now coalesces (one
/// event per 16 ms), so these caps only absorb a stalled GUI; the byte bound
/// is the one that actually limits memory, since a single delta may carry
/// 8 KiB.
const MAX_GLOBAL_EVENTS: usize = 4096;

const MAX_SESSION_EVENTS: usize = 1024;

/// Global byte budget for queued events (~4 MiB, drained every frame).
const MAX_QUEUED_BYTES: usize = 4 * 1024 * 1024;

/// At most one "events are being rejected" warning per this interval: a
/// stalled GUI could otherwise flood the log with one line per delta.
const DROP_WARN_INTERVAL: Duration = Duration::from_secs(5);

const MAX_ID_LEN: usize = 128;

const MAX_THINKING_BYTES: usize = 8 * 1024;
/// Longest accepted state declaration value. `needs-attention` is the longest
/// name the vocabulary has; the cap only bounds what this socket accepts.
const MAX_STATE_LEN: usize = 32;
/// Extension `seq` counters reset in each new omp process; accept the rollover.
const SEQ_RESET_CEILING: u64 = 128;

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
    // gpty-native rather than an adapter's: a program inside a pane
    // declaring its own display state through `gpty state`. It rides this
    // socket because the per-PTY event capability is the only credential a
    // pane's child holds — and it is the Windows answer for the
    // `gpty_state` OSC, which ConPTY consumes before it can reach the pane.
    "gpty.state.declared",
];

/// Adapter-neutral event vocabulary. The extension speaks OMP-specific
/// names on the wire (protocol v1); gpty translates them at this trust
/// boundary so everything downstream — Reasoning, AgentState Tier 1,
/// future adapters — consumes one generic contract.
const GENERIC_EVENT_NAMES: &[(&str, &str)] = &[
    ("omp.session.bound", "session.bound"),
    ("omp.session.shutdown", "session.shutdown"),
    ("omp.agent.started", "agent.started"),
    ("omp.agent.settled", "agent.settled"),
    ("omp.turn.started", "turn.started"),
    ("omp.turn.finished", "turn.finished"),
    ("omp.tool.started", "tool.call"),
    ("omp.tool.finished", "tool.finished"),
    ("omp.reasoning.delta", "thinking.delta"),
    ("gpty.state.declared", "state.declared"),
];

/// Translate a wire event name to the generic vocabulary. Unknown names
/// pass through unchanged — the allowlist gates what reaches this point.
pub fn to_generic_name(name: &str) -> &str {
    for (wire, generic) in GENERIC_EVENT_NAMES {
        if *wire == name {
            return generic;
        }
    }
    name
}

/// Kind and cap of one allowlisted field.
enum FieldKind {
    /// String, with a maximum length in bytes.
    Str(usize),
    /// Non-negative integer.
    Int,
    Bool,
}

/// The fields each generic event may carry. Everything else in the incoming
/// object is dropped at this boundary.
///
/// This is the allowlist AGENTS.md requires: the OMP extension is a separately
/// installable component and its payload is untrusted data, so a field that has
/// not been reviewed here — a prompt, an answer, tool arguments or results, or
/// whatever a future extension adds — must never reach Reasoning, Tier 1 agent
/// state, or the event-socket subscribers.
const ALLOWED_FIELDS: &[(&str, &[(&str, FieldKind)])] = &[
    (
        "session.bound",
        &[
            ("reason", FieldKind::Str(64)),
            ("emitted_at_ms", FieldKind::Int),
        ],
    ),
    ("session.shutdown", &[("emitted_at_ms", FieldKind::Int)]),
    ("agent.started", &[("emitted_at_ms", FieldKind::Int)]),
    ("agent.settled", &[("emitted_at_ms", FieldKind::Int)]),
    (
        "turn.started",
        &[
            ("turn_index", FieldKind::Int),
            ("started_at_ms", FieldKind::Int),
            ("emitted_at_ms", FieldKind::Int),
        ],
    ),
    (
        "turn.finished",
        &[
            ("turn_index", FieldKind::Int),
            ("emitted_at_ms", FieldKind::Int),
        ],
    ),
    (
        "tool.call",
        &[
            ("tool_call_id", FieldKind::Str(MAX_ID_LEN)),
            ("tool_name", FieldKind::Str(MAX_ID_LEN)),
            ("emitted_at_ms", FieldKind::Int),
        ],
    ),
    (
        "tool.finished",
        &[
            ("tool_call_id", FieldKind::Str(MAX_ID_LEN)),
            ("tool_name", FieldKind::Str(MAX_ID_LEN)),
            ("is_error", FieldKind::Bool),
            ("emitted_at_ms", FieldKind::Int),
        ],
    ),
    (
        "thinking.delta",
        &[
            ("text", FieldKind::Str(MAX_THINKING_BYTES)),
            ("emitted_at_ms", FieldKind::Int),
        ],
    ),
    // A declaration's value. The handler rejects a submission whose value is
    // not in `AgentState::from_declaration` — the allowlist would drop it and
    // leave an empty declaration that silently does nothing — so this row
    // bounds the shape and the vocabulary stays the one in gpty-core.
    (
        "state.declared",
        &[("state", FieldKind::Str(MAX_STATE_LEN))],
    ),
];

/// Translate a wire event into the generic vocabulary, copying **only** the
/// allowlisted fields for that event: the output object is built here rather
/// than edited in place, so an unknown field cannot ride along. `None` when
/// the event name has no allowlist entry (the handler rejects the submission).
fn translate_event(event: &serde_json::Map<String, Value>) -> Option<Value> {
    let name = event.get("name")?.as_str()?;
    let generic = to_generic_name(name);
    let (_, fields) = ALLOWED_FIELDS.iter().find(|(known, _)| *known == generic)?;
    let mut out = serde_json::Map::with_capacity(fields.len() + 1);
    out.insert("name".to_string(), Value::String(generic.to_string()));
    for (field, kind) in *fields {
        let Some(value) = event.get(*field) else {
            continue;
        };
        let copied = match kind {
            FieldKind::Str(max) => value
                .as_str()
                .filter(|text| text.len() <= *max)
                .map(|text| Value::String(text.to_string())),
            FieldKind::Int => value
                .as_i64()
                .filter(|number| *number >= 0)
                .map(|number| Value::Number(number.into())),
            FieldKind::Bool => value.as_bool().map(Value::Bool),
        };
        if let Some(copied) = copied {
            out.insert((*field).to_string(), copied);
        }
    }
    Some(Value::Object(out))
}

#[derive(Debug)]
struct SessionCapability {
    capability: String,
    last_seq: u64,
}

#[derive(Debug, Clone)]
pub struct OmpSemanticEvent {
    pub terminal_session_id: String,
    pub omp_session_id: String,
    /// The producer's sequence number, or 0 when it supplied none — a
    /// declaration submitted by a fresh process per call (`gpty state`)
    /// carries no stream position to advance.
    pub seq: u64,
    pub event: Value,
    /// Serialized size, accounted against [`MAX_QUEUED_BYTES`].
    bytes: usize,
}

/// The pending-event queue plus its byte total, so the memory bound is O(1)
/// rather than a walk of the queue on every submission.
#[derive(Default)]
struct EventQueue {
    events: VecDeque<OmpSemanticEvent>,
    bytes: usize,
}

impl EventQueue {
    fn has_room(&self, terminal_id: &str, bytes: usize) -> bool {
        if self.events.len() >= MAX_GLOBAL_EVENTS
            || self.bytes.saturating_add(bytes) > MAX_QUEUED_BYTES
        {
            return false;
        }
        let per_session = self
            .events
            .iter()
            .filter(|queued| queued.terminal_session_id == terminal_id)
            .count();
        per_session < MAX_SESSION_EVENTS
    }
}

static SESSIONS: LazyLock<Mutex<HashMap<String, SessionCapability>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

static EVENTS: LazyLock<Mutex<EventQueue>> = LazyLock::new(|| Mutex::new(EventQueue::default()));

/// Cumulative counters for the Reasoning pane's diagnostics (`omp_event_stats`
/// and `GPTY_REASONING_DEBUG`). Counters, not gauges: the pane derives rates.
#[derive(Default, Clone, Copy)]
struct EventCounters {
    accepted: u64,
    accepted_bytes: u64,
    rejected_queue_full: u64,
    rejected_oversized: u64,
    drained_events: u64,
    drained_bytes: u64,
}

static COUNTERS: LazyLock<Mutex<EventCounters>> =
    LazyLock::new(|| Mutex::new(EventCounters::default()));

/// Last drop warning, so a stalled drain cannot log one line per delta.
static LAST_DROP_WARN: LazyLock<Mutex<Option<Instant>>> = LazyLock::new(|| Mutex::new(None));

/// JSON snapshot of the event pipeline's counters and queue depth.
///
/// Static data about the process, not a terminal: the Reasoning pane prints it
/// when `GPTY_REASONING_DEBUG` is set, and a test can assert the drop counters.
pub fn stats_json() -> String {
    let counters = COUNTERS.lock().map(|c| *c).unwrap_or_default();
    let (queued_events, queued_bytes) = EVENTS
        .lock()
        .map(|queue| (queue.events.len(), queue.bytes))
        .unwrap_or((0, 0));
    json!({
        "accepted": counters.accepted,
        "accepted_bytes": counters.accepted_bytes,
        "rejected_queue_full": counters.rejected_queue_full,
        "rejected_oversized": counters.rejected_oversized,
        "drained_events": counters.drained_events,
        "drained_bytes": counters.drained_bytes,
        "queued_events": queued_events,
        "queued_bytes": queued_bytes,
        "max_queued_bytes": MAX_QUEUED_BYTES,
        "max_session_events": MAX_SESSION_EVENTS,
    })
    .to_string()
}

fn note_counter(update: impl FnOnce(&mut EventCounters)) {
    if let Ok(mut counters) = COUNTERS.lock() {
        update(&mut counters);
    }
}

/// A bounded, rate-limited diagnostic: dropping observability events is a
/// real loss, but a burst would otherwise bury the console.
fn warn_dropped(reason: &str) {
    let now = Instant::now();
    let Ok(mut last) = LAST_DROP_WARN.lock() else {
        return;
    };
    if last.is_some_and(|at| now.saturating_duration_since(at) < DROP_WARN_INTERVAL) {
        return;
    }
    *last = Some(now);
    let (queued_events, queued_bytes) = EVENTS
        .lock()
        .map(|queue| (queue.events.len(), queue.bytes))
        .unwrap_or((0, 0));
    log::warn!(
        "OMP event rejected ({reason}; {queued_events} queued / {queued_bytes} bytes): \
         agent observability is losing events"
    );
}

// ── Event subscriptions (gpty → clients over the event socket) ─────────
// Subscribers receive bounded JSON event lines via `eventsPoll`. Push
// transport (server-initiated writes on a held connection) is not v1.

/// One client's event poll cursor.
struct Subscription {
    queue: VecDeque<String>,
    /// Last `eventsPoll` for this id. A subscriber that never polls — or a
    /// client that reconnects instead of reusing its id — used to hold its slot
    /// for the process lifetime, so 64 abandoned subscriptions exhausted the cap
    /// permanently and the events queued for them were never freed.
    last_poll: Instant,
}

static SUBSCRIPTIONS: LazyLock<Mutex<HashMap<String, Subscription>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

static NEXT_SUB_ID: AtomicU64 = AtomicU64::new(1);

const MAX_SUBSCRIPTIONS: usize = 64;

/// How long a subscription may go unpolled before its slot is released.
/// Generous compared with any real poll loop, so a live subscriber is never
/// dropped between polls.
const SUBSCRIPTION_IDLE: Duration = Duration::from_secs(120);

const MAX_QUEUED_EVENTS: usize = 256;

/// True when `sub` has not been polled for [`SUBSCRIPTION_IDLE`]. Takes `now`
/// so the rule is testable without moving a monotonic clock backwards.
fn subscription_expired(sub: &Subscription, now: Instant) -> bool {
    now.saturating_duration_since(sub.last_poll) >= SUBSCRIPTION_IDLE
}

/// Drop subscriptions whose client stopped polling, releasing their slots and
/// the events queued for them.
fn release_idle_subscriptions(subs: &mut HashMap<String, Subscription>, now: Instant) {
    subs.retain(|_, sub| !subscription_expired(sub, now));
}

/// Fan an event out to every active subscription queue (bounded).
pub fn emit_event(event_json: &str) {
    if let Some(mut subs) = gpty_core::lock::lock_or_warn(&SUBSCRIPTIONS, "event subscriptions") {
        release_idle_subscriptions(&mut subs, Instant::now());
        for sub in subs.values_mut() {
            if sub.queue.len() >= MAX_QUEUED_EVENTS {
                sub.queue.pop_front();
            }
            sub.queue.push_back(event_json.to_string());
        }
    }
}

fn subscribe_handler() -> HandlerFn {
    std::sync::Arc::new(|_params| {
        Box::pin(async move {
            let sub_id = format!("sub-{}", NEXT_SUB_ID.fetch_add(1, Ordering::Relaxed));
            if let Some(mut subs) =
                gpty_core::lock::lock_or_warn(&SUBSCRIPTIONS, "event subscriptions")
            {
                // A slot whose client stopped polling is free again.
                release_idle_subscriptions(&mut subs, Instant::now());
                if subs.len() < MAX_SUBSCRIPTIONS {
                    subs.insert(
                        sub_id.clone(),
                        Subscription {
                            queue: VecDeque::new(),
                            last_poll: Instant::now(),
                        },
                    );
                    return Ok(json!({ "subscription_id": sub_id }));
                }
            }
            Err(gpty_ipc::protocol::JsonRpcError::new(
                -32001,
                "subscription limit reached",
            ))
        })
    })
}

fn events_poll_handler() -> HandlerFn {
    std::sync::Arc::new(|params| {
        Box::pin(async move {
            let sub_id = params
                .get("subscription_id")
                .and_then(Value::as_str)
                .unwrap_or("");
            let limit = params
                .get("limit")
                .and_then(Value::as_u64)
                .unwrap_or(64)
                .min(256) as usize;
            if let Some(mut subs) =
                gpty_core::lock::lock_or_warn(&SUBSCRIPTIONS, "event subscriptions")
                && let Some(sub) = subs.get_mut(sub_id)
            {
                sub.last_poll = Instant::now();
                let events: Vec<Value> = sub
                    .queue
                    .drain(..limit.min(sub.queue.len()))
                    .filter_map(|s| serde_json::from_str(&s).ok())
                    .collect();
                return Ok(json!({ "events": events }));
            }
            Err(gpty_ipc::protocol::JsonRpcError::new(
                -32002,
                "unknown subscription",
            ))
        })
    })
}

static STARTED: AtomicBool = AtomicBool::new(false);

/// Register one PTY lifetime and return its unguessable session/capability.
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

pub fn unregister_terminal(session_id: &str) {
    SESSIONS.lock().unwrap().remove(session_id);
    if let Ok(mut queue) = EVENTS.lock() {
        let mut removed = 0;
        queue.events.retain(|event| {
            let keep = event.terminal_session_id != session_id;
            if !keep {
                removed += event.bytes;
            }
            keep
        });
        queue.bytes = queue.bytes.saturating_sub(removed);
    }
}

/// Take every queued event for the frame's drain.
///
/// The byte total goes with them: a drained event no longer occupies the
/// queue, so the next burst starts from the real depth.
pub fn drain_events() -> Vec<OmpSemanticEvent> {
    let (events, bytes) = match EVENTS.lock() {
        Ok(mut queue) => {
            let bytes = queue.bytes;
            queue.bytes = 0;
            (queue.events.drain(..).collect::<Vec<_>>(), bytes)
        }
        Err(_) => return Vec::new(),
    };
    if !events.is_empty() {
        note_counter(|counters| {
            counters.drained_events = counters.drained_events.saturating_add(events.len() as u64);
            counters.drained_bytes = counters.drained_bytes.saturating_add(bytes as u64);
        });
    }
    events
}

fn random_hex(bytes: usize) -> std::io::Result<String> {
    let mut raw = vec![0_u8; bytes];
    getrandom::getrandom(&mut raw).map_err(std::io::Error::other)?;
    let mut out = String::with_capacity(bytes * 2);
    for byte in raw {
        use std::fmt::Write;
        let _ = write!(out, "{byte:02x}");
    }
    Ok(out)
}

fn constant_time_eq(left: &str, right: &str) -> bool {
    if left.len() != right.len() {
        return false;
    }
    left.bytes()
        .zip(right.bytes())
        .fold(0_u8, |diff, (a, b)| diff | (a ^ b))
        == 0
}

fn bounded_string<'a>(value: &'a Value, key: &str, max: usize) -> Option<&'a str> {
    value.get(key)?.as_str().filter(|text| text.len() <= max)
}

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

fn event_handler() -> HandlerFn {
    std::sync::Arc::new(|params| {
        Box::pin(async move {
            let version = params.get("v").and_then(Value::as_u64);
            let terminal_id = bounded_string(&params, "terminal_session_id", MAX_ID_LEN);
            let capability = bounded_string(&params, "capability", 128);
            let omp_session_id =
                bounded_string(&params, "omp_session_id", MAX_ID_LEN).unwrap_or("");
            // Optional: the OMP extension always sends one, but `gpty state`
            // runs as a fresh process per declaration and has no counter to
            // continue. The capability authorizes a submission; a sequence
            // only orders one long-lived producer's own stream, so it is
            // checked when it is present (the gate further down).
            let seq = params.get("seq").and_then(Value::as_u64);
            let event = params.get("event").and_then(Value::as_object);

            let (Some(terminal_id), Some(capability), Some(event)) =
                (terminal_id, capability, event)
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

            let Some(name) = event.get("name").and_then(Value::as_str) else {
                return Err(gpty_ipc::protocol::JsonRpcError::new(
                    -32602,
                    "missing event name",
                ));
            };
            if name.len() > MAX_ID_LEN || !ALLOWED_EVENTS.contains(&name) {
                return Err(gpty_ipc::protocol::JsonRpcError::new(
                    -32602,
                    "unsupported OMP event",
                ));
            }
            // A reasoning delta without usable text carries nothing; the
            // allowlist would drop the field, so reject it as malformed.
            if name == "omp.reasoning.delta"
                && event
                    .get("text")
                    .and_then(Value::as_str)
                    .is_none_or(|text| text.len() > MAX_THINKING_BYTES)
            {
                note_counter(|counters| {
                    counters.rejected_oversized = counters.rejected_oversized.saturating_add(1);
                });
                warn_dropped("reasoning delta over the 8 KiB cap");
                return Err(gpty_ipc::protocol::JsonRpcError::new(
                    -32602,
                    "invalid reasoning delta",
                ));
            }
            // A declaration must name a real state, for the same reason: the
            // allowlist would drop an unknown value and leave a declaration
            // that silently does nothing, where the caller can be told.
            if name == "gpty.state.declared"
                && event
                    .get("state")
                    .and_then(Value::as_str)
                    .and_then(gpty_core::agent_state::AgentState::from_declaration)
                    .is_none()
            {
                return Err(gpty_ipc::protocol::JsonRpcError::new(
                    -32602,
                    "invalid state declaration",
                ));
            }
            let Some(translated) = translate_event(event) else {
                return Err(gpty_ipc::protocol::JsonRpcError::new(
                    -32602,
                    "unsupported OMP event",
                ));
            };
            // Accounted against the queue's memory budget. The allowlist has
            // already bounded the fields, so this is bounded too.
            let event_bytes = serde_json::to_string(&translated)
                .map(|encoded| encoded.len())
                .unwrap_or(0);

            let next_seq = {
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
                if let Some(seq) = seq
                    && !accept_event_seq(session, seq)
                {
                    return Err(gpty_ipc::protocol::JsonRpcError::new(
                        -32003,
                        "stale event sequence",
                    ));
                }

                let mut queue = EVENTS.lock().unwrap();
                if !queue.has_room(terminal_id, event_bytes) {
                    drop(queue);
                    note_counter(|counters| {
                        counters.rejected_queue_full =
                            counters.rejected_queue_full.saturating_add(1);
                    });
                    warn_dropped("event queue full");
                    return Err(gpty_ipc::protocol::JsonRpcError::new(
                        -32004,
                        "event queue full",
                    ));
                }
                queue.events.push_back(OmpSemanticEvent {
                    terminal_session_id: terminal_id.to_string(),
                    omp_session_id: omp_session_id.to_string(),
                    seq: seq.unwrap_or(0),
                    event: translated,
                    bytes: event_bytes,
                });
                queue.bytes = queue.bytes.saturating_add(event_bytes);

                // The next sequence this session expects — its own counter,
                // which an unsequenced submission leaves untouched (so it
                // still answers a producer that supplies one next time).
                session.last_seq.saturating_add(1)
            };
            note_counter(|counters| {
                counters.accepted = counters.accepted.saturating_add(1);
                counters.accepted_bytes =
                    counters.accepted_bytes.saturating_add(event_bytes as u64);
            });

            Ok(json!({"accepted": true, "next_seq": next_seq}))
        })
    })
}

/// Start the dedicated OMP event listener once per process.
///
/// `serve()` only returns on an unrecoverable I/O error (e.g. a bind
/// failure). The spawned supervisor retries with bounded backoff, so the
/// channel recovers without needing a new terminal spawn to re-trigger it.
pub fn ensure_server_started() {
    if !STARTED.swap(true, Ordering::Relaxed) {
        let socket_path = gpty_ipc::transport::default_event_socket_path();
        crate::RUNTIME.spawn(async move {
            let mut backoff = Duration::from_secs(1);
            loop {
                let mut server = IpcServer::new(&socket_path);
                server.register("ompEvent", event_handler());
                server.register("subscribe", subscribe_handler());
                server.register("eventsPoll", events_poll_handler());
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

    /// Serializes the tests that reach the process-global session and event
    /// queues: cargo runs one binary's tests on parallel threads, and an event
    /// queued by one test is visible to another test's `drain_events()`.
    static QUEUES: Mutex<()> = Mutex::new(());

    fn reset() {
        SESSIONS.lock().unwrap().clear();
        {
            let mut queue = EVENTS.lock().unwrap();
            queue.events.clear();
            queue.bytes = 0;
        }
        *COUNTERS.lock().unwrap() = EventCounters::default();
        *LAST_DROP_WARN.lock().unwrap() = None;
    }

    fn queued_event(terminal_id: &str, bytes: usize) -> OmpSemanticEvent {
        OmpSemanticEvent {
            terminal_session_id: terminal_id.to_string(),
            omp_session_id: "omp-test".into(),
            seq: 0,
            event: json!({"name": "thinking.delta", "text": "x"}),
            bytes,
        }
    }

    #[test]
    fn the_queue_absorbs_a_frame_burst_and_bounds_both_axes() {
        let _guard = QUEUES.lock().unwrap_or_else(|p| p.into_inner());
        let mut queue = EventQueue::default();

        // The old cap (64) was below one frame's burst of reasoning deltas.
        for _ in 0..MAX_SESSION_EVENTS {
            assert!(queue.has_room("terminal-a", 1));
            let event = queued_event("terminal-a", 1);
            queue.bytes += event.bytes;
            queue.events.push_back(event);
        }
        assert!(
            !queue.has_room("terminal-a", 1),
            "one session cannot exceed its share"
        );
        assert!(
            queue.has_room("terminal-b", 1),
            "a chatty terminal must not starve another"
        );

        let byte_bound = EventQueue::default();
        assert!(byte_bound.has_room("a", MAX_QUEUED_BYTES));
        assert!(
            !byte_bound.has_room("a", MAX_QUEUED_BYTES + 1),
            "the queue's memory is bounded by bytes, not only by count"
        );
    }

    #[test]
    fn drain_returns_the_queue_and_records_what_it_moved() {
        let _guard = QUEUES.lock().unwrap_or_else(|p| p.into_inner());
        reset();
        {
            let mut queue = EVENTS.lock().unwrap();
            for bytes in [10, 20] {
                let event = queued_event("terminal-a", bytes);
                queue.bytes += event.bytes;
                queue.events.push_back(event);
            }
        }
        let drained = drain_events();
        assert_eq!(drained.len(), 2);
        assert_eq!(drained[0].bytes + drained[1].bytes, 30);
        assert!(EVENTS.lock().unwrap().events.is_empty());
        assert_eq!(EVENTS.lock().unwrap().bytes, 0, "the byte total resets");

        let stats: serde_json::Value = serde_json::from_str(&stats_json()).unwrap();
        assert_eq!(stats["drained_events"], 2);
        assert_eq!(stats["drained_bytes"], 30);
        assert_eq!(stats["queued_events"], 0);
        assert_eq!(stats["queued_bytes"], 0);
        reset();
    }

    #[test]
    fn unregistering_a_terminal_frees_its_queued_bytes() {
        let _guard = QUEUES.lock().unwrap_or_else(|p| p.into_inner());
        reset();
        {
            let mut queue = EVENTS.lock().unwrap();
            for (terminal, bytes) in [("a", 10), ("b", 20)] {
                let event = queued_event(terminal, bytes);
                queue.bytes += event.bytes;
                queue.events.push_back(event);
            }
        }
        unregister_terminal("a");
        let queue = EVENTS.lock().unwrap();
        assert_eq!(queue.events.len(), 1);
        assert_eq!(queue.bytes, 20, "only the removed terminal's bytes go");
        drop(queue);
        reset();
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
    fn generic_vocabulary_mapping() {
        for (wire, generic) in [
            ("omp.session.bound", "session.bound"),
            ("omp.session.shutdown", "session.shutdown"),
            ("omp.agent.started", "agent.started"),
            ("omp.agent.settled", "agent.settled"),
            ("omp.turn.started", "turn.started"),
            ("omp.turn.finished", "turn.finished"),
            ("omp.tool.started", "tool.call"),
            ("omp.tool.finished", "tool.finished"),
            ("omp.reasoning.delta", "thinking.delta"),
            ("gpty.state.declared", "state.declared"),
        ] {
            assert_eq!(to_generic_name(wire), generic, "wire name {wire}");
        }
        assert_eq!(to_generic_name("omp.unknown"), "omp.unknown");
    }

    #[test]
    fn translation_keeps_only_allowlisted_fields() {
        let event = json!({
            "name": "omp.tool.finished",
            "tool_name": "bash",
            "tool_call_id": "call-1",
            "is_error": true,
            "emitted_at_ms": 1234,
            // Fields an extension must never get to forward:
            "prompt": "SECRET PROMPT",
            "answer": "SECRET ANSWER",
            "tool_args": {"cmd": "rm -rf /"},
            "tool_result": "SECRET OUTPUT",
        });
        let translated = translate_event(event.as_object().unwrap()).expect("allowlisted event");
        assert_eq!(translated["name"], "tool.finished");
        assert_eq!(translated["tool_name"], "bash");
        assert_eq!(translated["tool_call_id"], "call-1");
        assert_eq!(translated["is_error"], true);
        assert_eq!(translated["emitted_at_ms"], 1234);
        for forbidden in ["prompt", "answer", "tool_args", "tool_result"] {
            assert!(
                translated.get(forbidden).is_none(),
                "'{forbidden}' must not cross the translation boundary: {translated}"
            );
        }
    }

    #[test]
    fn translation_drops_badly_typed_and_oversized_fields() {
        let event = json!({
            "name": "omp.tool.started",
            "tool_name": "bash",
            "tool_call_id": "x".repeat(MAX_ID_LEN + 1),
            "is_error": true,
        });
        let translated = translate_event(event.as_object().unwrap()).expect("allowlisted event");
        assert_eq!(translated["tool_name"], "bash");
        assert!(
            translated.get("tool_call_id").is_none(),
            "an oversized id is dropped, not truncated into a different id"
        );
        assert!(
            translated.get("is_error").is_none(),
            "tool.started carries no is_error — an unlisted field stays out"
        );
    }

    #[test]
    fn translation_rejects_events_without_an_allowlist_entry() {
        let unknown = json!({"name": "omp.unknown", "text": "x"});
        assert!(translate_event(unknown.as_object().unwrap()).is_none());
        let missing_name = json!({"text": "x"});
        assert!(translate_event(missing_name.as_object().unwrap()).is_none());
    }

    #[test]
    fn oversized_thinking_delta_text_is_dropped() {
        let event = json!({
            "name": "omp.reasoning.delta",
            "text": "x".repeat(MAX_THINKING_BYTES + 1),
        });
        let translated = translate_event(event.as_object().unwrap()).expect("allowlisted event");
        assert_eq!(translated["name"], "thinking.delta");
        assert!(
            translated.get("text").is_none(),
            "over-cap text must not be forwarded"
        );
    }

    #[test]
    fn idle_subscriptions_are_released_but_live_ones_survive() {
        let base = Instant::now();
        let mut subs = HashMap::new();
        subs.insert(
            "stale".to_string(),
            Subscription {
                queue: VecDeque::new(),
                last_poll: base,
            },
        );
        subs.insert(
            "live".to_string(),
            Subscription {
                queue: VecDeque::new(),
                last_poll: base + SUBSCRIPTION_IDLE - Duration::from_secs(1),
            },
        );
        release_idle_subscriptions(&mut subs, base + SUBSCRIPTION_IDLE);
        assert!(
            !subs.contains_key("stale"),
            "a slot unpolled for the idle window must be freed"
        );
        assert!(
            subs.contains_key("live"),
            "a subscription polled just now stays"
        );
    }

    /// End-to-end form of the leak: with every slot held by a client that
    /// stopped polling, the next subscribe must reuse one instead of failing.
    #[test]
    fn subscribe_frees_a_slot_its_client_abandoned() {
        let Some(abandoned_at) =
            Instant::now().checked_sub(SUBSCRIPTION_IDLE + Duration::from_secs(1))
        else {
            return; // monotonic clock too young for the test to mean anything
        };
        {
            let mut subs = SUBSCRIPTIONS.lock().unwrap();
            subs.clear();
            for i in 0..MAX_SUBSCRIPTIONS {
                subs.insert(
                    format!("abandoned-{i}"),
                    Subscription {
                        queue: VecDeque::new(),
                        last_poll: abandoned_at,
                    },
                );
            }
        }
        let handler = subscribe_handler();
        let runtime = tokio::runtime::Runtime::new().unwrap();
        let result = runtime.block_on(handler(json!({})));
        assert!(result.is_ok(), "an idle slot must be reusable: {result:?}");
        let remaining = SUBSCRIPTIONS.lock().unwrap();
        assert_eq!(
            remaining.len(),
            1,
            "the abandoned slots are released, only the new subscription remains"
        );
        drop(remaining);
        SUBSCRIPTIONS.lock().unwrap().clear();
    }

    #[test]
    fn unregister_expires_session_and_queued_events() {
        let _guard = QUEUES.lock().unwrap();
        reset();
        SESSIONS.lock().unwrap().insert(
            "terminal".into(),
            SessionCapability {
                capability: "cap".into(),
                last_seq: 0,
            },
        );
        EVENTS.lock().unwrap().events.push_back(OmpSemanticEvent {
            terminal_session_id: "terminal".into(),
            omp_session_id: "omp".into(),
            seq: 1,
            event: json!({"name": "omp.agent.started"}),
            bytes: 0,
        });
        unregister_terminal("terminal");
        assert!(SESSIONS.lock().unwrap().is_empty());
        let queue = EVENTS.lock().unwrap();
        assert!(queue.events.is_empty());
        assert_eq!(queue.bytes, 0);
    }

    /// The declaration path end to end: a registered session, the real
    /// handler, and the queue's own view of what arrived.
    #[test]
    fn a_state_declaration_is_accepted_without_a_sequence() {
        let _guard = QUEUES.lock().unwrap();
        reset();
        let (session_id, capability) = register_terminal().expect("registration");
        let handler = event_handler();
        let runtime = tokio::runtime::Runtime::new().unwrap();
        let result = runtime.block_on(handler(json!({
            "v": PROTOCOL_VERSION,
            "terminal_session_id": session_id,
            "capability": capability,
            "event": {"name": "gpty.state.declared", "state": "needs-attention"},
        })));
        assert!(
            result.is_ok(),
            "an unsequenced declaration must be accepted: {result:?}"
        );
        let mine: Vec<_> = drain_events()
            .into_iter()
            .filter(|event| event.terminal_session_id == session_id)
            .collect();
        assert_eq!(mine.len(), 1, "exactly one event for this session");
        assert_eq!(mine[0].event["name"], "state.declared");
        assert_eq!(mine[0].event["state"], "needs-attention");
        assert_eq!(
            mine[0].seq, 0,
            "a submission without a sequence carries no position"
        );
        unregister_terminal(&session_id);
    }

    /// Refused before the session lookup, so the caller hears about a typo
    /// instead of watching a declaration silently do nothing.
    #[test]
    fn a_declaration_with_an_unknown_state_is_rejected() {
        let handler = event_handler();
        let runtime = tokio::runtime::Runtime::new().unwrap();
        let error = runtime
            .block_on(handler(json!({
                "v": PROTOCOL_VERSION,
                "terminal_session_id": "any",
                "capability": "any",
                "event": {"name": "gpty.state.declared", "state": "wroking"},
            })))
            .expect_err("a value outside the vocabulary must be refused");
        assert_eq!(error.code, -32602, "got: {error:?}");
        assert!(
            error.message.contains("state declaration"),
            "the refusal must name what it refused: {}",
            error.message
        );
    }
}
