//! One private, bounded, in-memory AI session.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use tokio::sync::{Notify, mpsc};
use tokio::task::JoinHandle;

use crate::backend::BackendInfo;
use crate::binary::resolve_omp_binary;
use crate::cli::run_cli_session;
use crate::mock::run_mock_session;
use crate::omp::run_omp_session;
use crate::types::{
    AiEvent, AiEventEnvelope, BackendKind, EventChannel, SessionOpenRequest, SessionPromptRequest,
};

const MAX_QUEUED_EVENTS: usize = 2048;
static NEXT_SESSION_ID: AtomicU64 = AtomicU64::new(1);

/// Bounded outbound queue with accounting for what the bound costs.
///
/// An adapter can emit faster than the pane drains, and the queue has to stay
/// bounded, so the oldest envelopes are evicted. Counting the evictions is
/// what lets the consumer be told its answer is missing its beginning instead
/// of rendering a silently truncated reply.
#[derive(Default)]
struct EventQueue {
    events: VecDeque<AiEventEnvelope>,
    dropped: u64,
}

impl EventQueue {
    fn push(&mut self, envelope: AiEventEnvelope) {
        if self.events.len() == MAX_QUEUED_EVENTS {
            self.events.pop_front();
            self.dropped += 1;
        }
        self.events.push_back(envelope);
    }

    /// Drain up to `max` envelopes, prefixing a notice when earlier events
    /// were dropped. The notice is itself an envelope so it travels the same
    /// path as everything else and the pane renders it without special cases.
    fn drain(
        &mut self,
        max: usize,
        session_id: &str,
        sequence: &AtomicU64,
    ) -> Vec<AiEventEnvelope> {
        let dropped = std::mem::take(&mut self.dropped);
        let count = max.clamp(1, MAX_QUEUED_EVENTS).min(self.events.len());
        let mut out: Vec<AiEventEnvelope> = self.events.drain(..count).collect();
        if dropped > 0 {
            out.insert(
                0,
                AiEventEnvelope {
                    session_id: session_id.to_string(),
                    turn_id: 0,
                    run_id: String::new(),
                    sequence: sequence.fetch_add(1, Ordering::Relaxed),
                    channel: EventChannel::Lifecycle,
                    event: AiEvent::Status {
                        message: format!("{dropped} earlier events dropped (output arrived faster than it could be read)"),
                    },
                },
            );
        }
        out
    }
}

pub(crate) struct CancelSignal {
    cancelled: AtomicBool,
    notify: Notify,
}

impl CancelSignal {
    fn new() -> Self {
        Self {
            cancelled: AtomicBool::new(false),
            notify: Notify::new(),
        }
    }

    pub(crate) fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
        self.notify.notify_waiters();
    }

    pub(crate) fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::Acquire)
    }

    pub(crate) async fn notified(&self) {
        if self.is_cancelled() {
            return;
        }
        self.notify.notified().await;
    }
}

pub(crate) enum SessionCommand {
    Prompt {
        turn_id: u64,
        run_id: String,
        request: SessionPromptRequest,
        cancel: Arc<CancelSignal>,
    },
    Close,
}

#[derive(Clone)]
pub(crate) struct EventSink {
    session_id: String,
    queue: Arc<Mutex<EventQueue>>,
    sequence: Arc<AtomicU64>,
    active: Arc<Mutex<Option<ActiveRun>>>,
}

impl EventSink {
    pub(crate) fn emit(&self, turn_id: u64, run_id: &str, event: AiEvent) {
        let terminal = event.is_terminal();
        let envelope = AiEventEnvelope {
            session_id: self.session_id.clone(),
            turn_id,
            run_id: run_id.to_string(),
            sequence: self.sequence.fetch_add(1, Ordering::Relaxed),
            channel: event.channel(),
            event,
        };
        if let Ok(mut queue) = self.queue.lock() {
            queue.push(envelope);
        }
        if terminal
            && let Ok(mut active) = self.active.lock()
            && active.as_ref().is_some_and(|run| run.run_id == run_id)
        {
            *active = None;
        }
    }
}

struct ActiveRun {
    run_id: String,
    cancel: Arc<CancelSignal>,
}

/// A single bridge-owned conversation and backend process.
pub struct AiSession {
    id: String,
    config: SessionOpenRequest,
    queue: Arc<Mutex<EventQueue>>,
    sequence: Arc<AtomicU64>,
    next_turn: AtomicU64,
    active: Arc<Mutex<Option<ActiveRun>>>,
    command_tx: mpsc::UnboundedSender<SessionCommand>,
    task: Mutex<Option<JoinHandle<()>>>,
    closed: AtomicBool,
}

impl AiSession {
    pub fn open(
        runtime: &tokio::runtime::Handle,
        config: SessionOpenRequest,
    ) -> Result<Arc<Self>, String> {
        if config.backend == BackendKind::Omp && resolve_omp_binary().is_none() {
            return Err("omp backend unavailable (install Oh-My-Pi or set GPTY_OMP)".into());
        }
        if config.backend == BackendKind::Cli && config.command.is_empty() {
            return Err("cli backend requires a command (Inspector pane settings)".into());
        }
        if !config.cwd.is_empty() && !std::path::Path::new(&config.cwd).is_absolute() {
            return Err("cwd must be absolute when set".into());
        }

        let id = NEXT_SESSION_ID.fetch_add(1, Ordering::Relaxed).to_string();
        let queue = Arc::new(Mutex::new(EventQueue::default()));
        let active = Arc::new(Mutex::new(None));
        let sequence = Arc::new(AtomicU64::new(1));
        let sink = EventSink {
            session_id: id.clone(),
            queue: Arc::clone(&queue),
            sequence: Arc::clone(&sequence),
            active: Arc::clone(&active),
        };
        let (command_tx, command_rx) = mpsc::unbounded_channel();
        let worker_config = config.clone();
        let task = match config.backend {
            BackendKind::Mock => runtime.spawn(run_mock_session(command_rx, sink, worker_config)),
            BackendKind::Omp => runtime.spawn(run_omp_session(command_rx, sink, worker_config)),
            BackendKind::Cli => runtime.spawn(run_cli_session(command_rx, sink, worker_config)),
        };

        Ok(Arc::new(Self {
            id,
            config,
            queue,
            sequence,
            next_turn: AtomicU64::new(1),
            active,
            command_tx,
            task: Mutex::new(Some(task)),
            closed: AtomicBool::new(false),
        }))
    }

    pub fn id(&self) -> &str {
        &self.id
    }

    pub fn backend(&self) -> BackendKind {
        self.config.backend
    }

    pub fn prompt(&self, request: SessionPromptRequest) -> Result<(u64, String), String> {
        if self.closed.load(Ordering::Acquire) {
            return Err("session is closed".into());
        }
        let mut active = self
            .active
            .lock()
            .map_err(|_| "session state poisoned".to_string())?;
        if active.is_some() {
            return Err("a turn is already running".into());
        }
        let turn_id = self.next_turn.fetch_add(1, Ordering::Relaxed);
        let run_id = format!("{}-{turn_id}", self.id);
        let cancel = Arc::new(CancelSignal::new());
        *active = Some(ActiveRun {
            run_id: run_id.clone(),
            cancel: Arc::clone(&cancel),
        });
        if self
            .command_tx
            .send(SessionCommand::Prompt {
                turn_id,
                run_id: run_id.clone(),
                request,
                cancel,
            })
            .is_err()
        {
            *active = None;
            return Err("backend worker stopped".into());
        }
        Ok((turn_id, run_id))
    }

    pub fn poll(&self, max_events: usize) -> Vec<AiEventEnvelope> {
        let Ok(mut queue) = self.queue.lock() else {
            return Vec::new();
        };
        queue.drain(max_events, &self.id, &self.sequence)
    }

    pub fn cancel(&self) -> bool {
        let Ok(active) = self.active.lock() else {
            return false;
        };
        let Some(run) = active.as_ref() else {
            return false;
        };
        run.cancel.cancel();
        true
    }

    pub fn close(&self) {
        if self.closed.swap(true, Ordering::AcqRel) {
            return;
        }
        self.cancel();
        let _ = self.command_tx.send(SessionCommand::Close);
    }

    pub fn list_backends() -> Vec<BackendInfo> {
        vec![
            BackendInfo {
                kind: BackendKind::Mock,
                name: "Mock",
                available: true,
            },
            BackendInfo {
                kind: BackendKind::Omp,
                name: "Oh-My-Pi (omp RPC)",
                available: resolve_omp_binary().is_some(),
            },
            BackendInfo {
                kind: BackendKind::Cli,
                name: "CLI bridge (NDJSON)",
                available: true,
            },
        ]
    }
}

impl Drop for AiSession {
    fn drop(&mut self) {
        self.close();
        if let Ok(mut task) = self.task.lock()
            && let Some(task) = task.take()
        {
            task.abort();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn prompt(text: &str) -> SessionPromptRequest {
        SessionPromptRequest {
            capture: text.into(),
            concept_name: "test".into(),
            source_pane: "T1".into(),
        }
    }

    async fn wait_terminal(session: &AiSession) -> Vec<AiEventEnvelope> {
        let mut all = Vec::new();
        for _ in 0..100 {
            tokio::time::sleep(std::time::Duration::from_millis(5)).await;
            all.extend(session.poll(128));
            if all.iter().any(|event| event.event.is_terminal()) {
                return all;
            }
        }
        panic!("session did not finish");
    }

    #[tokio::test]
    async fn mock_session_supports_sequential_turns() {
        let session = AiSession::open(
            &tokio::runtime::Handle::current(),
            SessionOpenRequest::default(),
        )
        .unwrap();
        let (first_turn, first_run) = session.prompt(prompt("one")).unwrap();
        let first = wait_terminal(&session).await;
        let (second_turn, second_run) = session.prompt(prompt("two")).unwrap();
        let second = wait_terminal(&session).await;

        assert_eq!((first_turn, second_turn), (1, 2));
        assert_ne!(first_run, second_run);
        assert!(first.iter().all(|event| event.turn_id == 1));
        assert!(second.iter().all(|event| event.turn_id == 2));
        assert!(second[0].sequence > first.last().unwrap().sequence);
    }

    #[tokio::test]
    async fn sessions_do_not_fan_out_events() {
        let a = AiSession::open(
            &tokio::runtime::Handle::current(),
            SessionOpenRequest::default(),
        )
        .unwrap();
        let b = AiSession::open(
            &tokio::runtime::Handle::current(),
            SessionOpenRequest::default(),
        )
        .unwrap();
        a.prompt(prompt("private")).unwrap();
        let events = wait_terminal(&a).await;
        assert!(!events.is_empty());
        assert!(b.poll(128).is_empty());
    }

    #[tokio::test]
    async fn active_turn_rejects_another_prompt() {
        let session = AiSession::open(
            &tokio::runtime::Handle::current(),
            SessionOpenRequest::default(),
        )
        .unwrap();
        session.prompt(prompt("one")).unwrap();
        assert_eq!(
            session.prompt(prompt("two")).unwrap_err(),
            "a turn is already running"
        );
    }

    fn delta_envelope(text: &str) -> AiEventEnvelope {
        AiEventEnvelope {
            session_id: "s".into(),
            turn_id: 1,
            run_id: "r".into(),
            sequence: 0,
            channel: EventChannel::Answer,
            event: AiEvent::Delta { text: text.into() },
        }
    }

    #[test]
    fn eviction_is_counted_and_announced_once() {
        let mut queue = EventQueue::default();
        for i in 0..(MAX_QUEUED_EVENTS + 3) {
            queue.push(delta_envelope(&i.to_string()));
        }
        assert_eq!(
            queue.events.len(),
            MAX_QUEUED_EVENTS,
            "queue must stay bounded"
        );
        assert_eq!(queue.dropped, 3);

        let sequence = AtomicU64::new(10);
        let drained = queue.drain(4, "s", &sequence);

        // The notice precedes the surviving events, so a consumer that fell
        // behind is told its answer is missing its beginning.
        assert_eq!(drained.len(), 5);
        assert!(
            matches!(&drained[0].event, AiEvent::Status { message } if message.contains('3')),
            "first envelope must announce the gap, got {:?}",
            drained[0].event
        );
        assert_eq!(drained[0].sequence, 10);
        assert!(
            matches!(&drained[1].event, AiEvent::Delta { text } if text == "3"),
            "the oldest surviving event follows the notice"
        );
        assert_eq!(
            queue.dropped, 0,
            "the gap is reported once, not on every drain"
        );
    }

    #[test]
    fn drain_without_drops_has_no_notice() {
        let mut queue = EventQueue::default();
        queue.push(delta_envelope("a"));
        let sequence = AtomicU64::new(1);

        let drained = queue.drain(4, "s", &sequence);
        assert_eq!(drained.len(), 1);
        assert!(matches!(&drained[0].event, AiEvent::Delta { .. }));
    }
}
