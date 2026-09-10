//! The terminal-task orchestrator.
//!
//! [`WorkspaceEngine`] is the runtime coordinator. It owns the concept
//! registry and spawns every terminal task (mock or real-PTY-backed) as an
//! isolated tokio task. Each task:
//!
//! 1. Feeds PTY output through [`crate::concept::match_line`]
//! 2. **Captures** output when a concept fires, buffering subsequent
//!    output until a stop condition (timeout or user input)
//! 3. Queues the captured block for GDScript to route to a receiver pane
//!
//! A capture still in flight when its pane is torn down is finalized by
//! [`SpawnedTerminal`]'s `Drop` into the engine's orphan queue, which
//! GDScript drains and routes the same way.
//!
//! Nothing here writes to a child's stdin except real user input
//! ([`PtyTerminalHandle::send_line`] / `send_text`) and the resize control.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::mpsc;

use crate::agent_state::{AgentState, StateTier};
use crate::concept;
use crate::term::TermGrid;
use crate::types::{CaptureMode, CapturedOutput, Concept, ConceptNotice, TerminalConfig};

// ── Stdin input discrimination ────────────────────────────────────────

/// Commands sent to a PTY from the outside (keyboard or IPC injection).
enum StdinInput {
    Line(String),
    Raw(Vec<u8>),
    /// Resize the PTY — sends SIGWINCH to the child process.
    Resize {
        rows: u16,
        cols: u16,
    },
    /// Flush captured bytes to the grid (GDScript had no receiver).
    FlushCapture(u64),
    /// Discard captured bytes (GDScript routed them to a receiver).
    AcknowledgeCapture(u64),
}

// ── Public types ──────────────────────────────────────────────────────

pub struct WorkspaceEngine {
    concepts: Arc<std::sync::RwLock<Vec<Concept>>>,
    /// Captures finalized after their source pane was torn down. The pane's
    /// own queue dies with it, so this is the only way a capture that was
    /// still in flight when the pane closed reaches the workspace.
    orphaned_captures: Arc<Mutex<Vec<CapturedOutput>>>,
}

/// A handle to a spawned PTY terminal, allowing the caller to inject input.
pub struct PtyTerminalHandle {
    pub id: u32,
    stdin_tx: mpsc::UnboundedSender<StdinInput>,
}

impl PtyTerminalHandle {
    pub fn send_line(&self, text: &str) {
        let _ = self.stdin_tx.send(StdinInput::Line(text.to_string()));
    }

    pub fn send_text(&self, text: &str) {
        let _ = self
            .stdin_tx
            .send(StdinInput::Raw(text.as_bytes().to_vec()));
    }

    pub fn resize_pty(&self, rows: u16, cols: u16) {
        let _ = self.stdin_tx.send(StdinInput::Resize { rows, cols });
    }

    /// Tell the terminal task to flush a captured buffer to the grid.
    pub fn flush_capture(&self, id: u64) {
        let _ = self.stdin_tx.send(StdinInput::FlushCapture(id));
    }

    /// Tell the terminal task to discard a captured buffer.
    pub fn acknowledge_capture(&self, id: u64) {
        let _ = self.stdin_tx.send(StdinInput::AcknowledgeCapture(id));
    }
}

/// A spawned terminal with both input control and a renderable grid.
pub struct SpawnedTerminal {
    pub handle: PtyTerminalHandle,
    pub grid: Arc<Mutex<TermGrid>>,
    /// Queue of completed captures that GDScript drains.
    pub capture_queue: Arc<Mutex<Vec<CapturedOutput>>>,
    /// Queue of notify-only concept matches (`CaptureMode::SingleLine`) that
    /// GDScript drains and forwards to the event socket.
    pub notice_queue: Arc<Mutex<Vec<ConceptNotice>>>,
    /// Shared with the terminal task — see `Drop`.
    capture: CaptureSession,
    /// Sink for a capture that is still in flight when the pane goes away.
    orphaned: Arc<Mutex<Vec<CapturedOutput>>>,
    _task: tokio::task::JoinHandle<()>,
}

impl Drop for SpawnedTerminal {
    fn drop(&mut self) {
        // Aborting drops the task future, so the finalize-on-exit path at
        // the end of `run_terminal_task` — the one a closed pane relies on —
        // never runs. Finalize what the task had buffered into the engine's
        // orphan queue instead: the workspace keeps draining that queue and
        // routes the capture like any other.
        self._task.abort();
        self.capture.finalize_to(Arc::clone(&self.orphaned));
        // If the task did finalize on its own (a deadline or the byte cap
        // can fire between the abort and its next poll), the event sits on
        // the pane queue, which nothing polls for a pane that no longer
        // exists. Carry it over.
        if let Ok(mut queue) = self.capture_queue.lock()
            && !queue.is_empty()
        {
            for event in queue.drain(..) {
                push_bounded(&self.orphaned, event);
            }
        }
    }
}

// ── WorkspaceEngine ───────────────────────────────────────────────────

impl WorkspaceEngine {
    pub fn new(concepts: Vec<Concept>) -> Self {
        Self {
            concepts: Arc::new(std::sync::RwLock::new(concepts)),
            orphaned_captures: Arc::new(Mutex::new(Vec::new())),
        }
    }

    /// Take the captures whose pane was torn down while they were still in
    /// flight. The events are complete — there is nothing to acknowledge or
    /// flush, because the pane, its grid, and its raw-byte store died with it.
    pub fn drain_orphaned_captures(&self) -> Vec<CapturedOutput> {
        self.orphaned_captures
            .lock()
            .map(|mut queue| std::mem::take(&mut *queue))
            .unwrap_or_default()
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn spawn_terminal_with_grid(
        &self,
        config: TerminalConfig,
        command: &str,
        args: &[&str],
        envs: &[String],
        trusted_envs: &[(String, String)],
        rows: usize,
        cols: usize,
    ) -> Result<SpawnedTerminal, Box<dyn std::error::Error + Send + Sync>> {
        let (pty_tx, pty_rx) = mpsc::unbounded_channel::<Vec<u8>>();
        let pty_handle =
            crate::pty::PtyHandle::spawn(config.id, command, args, envs, trusted_envs, pty_tx)?;
        let (stdin_tx, stdin_rx) = mpsc::unbounded_channel::<StdinInput>();

        let grid = Arc::new(Mutex::new(TermGrid::new(rows, cols)));
        let grid_clone = Arc::clone(&grid);

        let capture_queue: Arc<Mutex<Vec<CapturedOutput>>> = Arc::new(Mutex::new(Vec::new()));
        let capture_buffers: Arc<Mutex<HashMap<u64, Vec<Vec<u8>>>>> =
            Arc::new(Mutex::new(HashMap::new()));
        let session = CaptureSession::new(capture_buffers, Arc::clone(&capture_queue));

        let notice_queue: Arc<Mutex<Vec<ConceptNotice>>> = Arc::new(Mutex::new(Vec::new()));

        let task_ctx = TaskContext::new(
            config.id,
            Arc::clone(&self.concepts),
            session.clone(),
            Arc::clone(&notice_queue),
        );

        let task = tokio::spawn(run_terminal_task(
            task_ctx,
            pty_handle,
            pty_rx,
            stdin_rx,
            Some(grid_clone),
        ));

        Ok(SpawnedTerminal {
            handle: PtyTerminalHandle {
                id: config.id,
                stdin_tx,
            },
            grid,
            capture_queue,
            notice_queue,
            capture: session,
            orphaned: Arc::clone(&self.orphaned_captures),
            _task: task,
        })
    }

    pub fn set_concepts(&self, concepts: Vec<Concept>) {
        if let Ok(mut w) = self.concepts.write() {
            *w = concepts;
        }
    }

    pub fn get_concepts(&self) -> Vec<Concept> {
        self.concepts.read().map(|c| c.clone()).unwrap_or_default()
    }
}

// ── Shared terminal task ──────────────────────────────────────────────

/// After SIGWINCH, TUIs redraw and re-emit visible screen content as fresh
/// PTY bytes. Skip concept matching on those lines — they are not new shell
/// events. User-initiated UntilStop triggers (typed Enter) are unaffected.
const POST_RESIZE_CONCEPT_SUPPRESS_MS: u64 = 750;

/// Current wall-clock time in unix milliseconds, for status primitives.
fn unix_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}
fn concept_match_suppressed(
    deadline: Option<tokio::time::Instant>,
    now: tokio::time::Instant,
) -> bool {
    deadline.is_some_and(|d| now < d)
}

struct TaskContext {
    id: u32,
    concepts: Arc<std::sync::RwLock<Vec<Concept>>>,
    session: CaptureSession,
    /// Notify-only matches, drained by GDScript and forwarded to the event
    /// socket. Dropped oldest-first, like the capture queue: a broad trigger
    /// must not grow memory if nobody is polling.
    notices: Arc<Mutex<Vec<ConceptNotice>>>,
    suppress_pty_concept_match_until: Option<tokio::time::Instant>,
}

impl TaskContext {
    fn pty_concept_match_suppressed(&self, now: tokio::time::Instant) -> bool {
        concept_match_suppressed(self.suppress_pty_concept_match_until, now)
    }

    /// Apply a concept match.
    ///
    /// `CaptureMode::SingleLine` is notify-only: the match is queued for the
    /// event channel and nothing else happens — no capture, no grid
    /// suppression, no pane involvement. `CaptureMode::UntilStop` starts a
    /// capture and returns its deadline so the caller can re-arm its timeout.
    fn apply_match(
        &mut self,
        matched: Option<(String, CaptureMode, String)>,
    ) -> Option<tokio::time::Instant> {
        match matched? {
            (name, CaptureMode::SingleLine, _) => {
                self.push_notice(name);
                None
            }
            (
                name,
                CaptureMode::UntilStop {
                    stop_timeout_ms, ..
                },
                target,
            ) if !self.session.is_active() => {
                let deadline = tokio::time::Instant::now() + Duration::from_millis(stop_timeout_ms);
                self.session.begin(name, target, deadline);
                Some(deadline)
            }
            _ => None,
        }
    }

    /// Queue a notify-only match, dropping the oldest when nobody has polled.
    fn push_notice(&self, concept_name: String) {
        const MAX_NOTICES: usize = 64;
        if let Ok(mut notices) = self.notices.lock() {
            if notices.len() >= MAX_NOTICES {
                notices.remove(0);
            }
            notices.push(ConceptNotice { concept_name });
        }
    }
    fn new(
        id: u32,
        concepts: Arc<std::sync::RwLock<Vec<Concept>>>,
        session: CaptureSession,
        notices: Arc<Mutex<Vec<ConceptNotice>>>,
    ) -> Self {
        Self {
            id,
            concepts,
            session,
            notices,
            suppress_pty_concept_match_until: None,
        }
    }
}

/// Feed raw bytes to the grid if present.
fn feed_grid(grid: &Option<Arc<Mutex<TermGrid>>>, bytes: &[u8]) {
    if let Some(g) = grid
        && let Ok(mut locked) = g.lock()
    {
        locked.feed(bytes);
    }
}

/// Store a line in the grid history.
fn store_line(grid: &Option<Arc<Mutex<TermGrid>>>, line: &str) {
    if let Some(g) = grid
        && let Ok(mut locked) = g.lock()
    {
        locked.store_line(line);
    }
}

/// Maximum raw bytes buffered per capture before it is finalized early.
/// Bounds memory when a capture-mode concept matches an output flood.
const MAX_CAPTURE_BYTES: usize = 4 * 1024 * 1024;

/// Maximum captures held by a queue nobody polls (a pane queue while
/// GDScript stalls, the engine's orphan queue). Drop-oldest.
const MAX_BUFFERED_CAPTURES: usize = 64;

/// Mutable capture state, shared between the terminal task and the
/// `SpawnedTerminal` handle.
///
/// The task buffers PTY output here; `SpawnedTerminal::drop` finalizes what
/// is still in flight, because aborting the task skips its own
/// finalize-on-exit path.
struct CaptureState {
    buffer: Vec<Vec<u8>>,
    bytes: usize,
    active_name: Option<String>,
    active_target: Option<String>,
    deadline: Option<tokio::time::Instant>,
    next_event_id: u64,
    /// Where finalized captures go: normally the pane's queue, which
    /// GDScript polls every frame.
    sink: Arc<Mutex<Vec<CapturedOutput>>>,
    /// Raw bytes of finalized captures, kept for flush/acknowledge.
    buffers: Arc<Mutex<HashMap<u64, Vec<Vec<u8>>>>>,
}

/// Shared handle to a pane's capture state machine: buffering, deadline, and
/// finalization into the sink and the raw-chunk store.
///
/// Extracted from `run_terminal_task` so the capture lifecycle is
/// unit-testable without a real PTY, and shared with `SpawnedTerminal` so
/// tearing a pane down can finalize a capture the task still holds.
#[derive(Clone)]
struct CaptureSession {
    state: Arc<Mutex<CaptureState>>,
}

/// Push onto a bounded capture queue, dropping the oldest.
fn push_bounded(queue: &Arc<Mutex<Vec<CapturedOutput>>>, event: CapturedOutput) {
    if let Ok(mut queue) = queue.lock() {
        if queue.len() >= MAX_BUFFERED_CAPTURES {
            queue.remove(0);
        }
        queue.push(event);
    }
}

/// Finalize the state behind an already-held lock: parse the buffered chunks
/// into plain-text lines, hand the raw bytes to the chunk store, and publish
/// the event to the sink. Resets all capture state.
fn finalize_state(state: &mut CaptureState) -> Option<CapturedOutput> {
    // Inactive session: nothing was buffered, nothing to emit.
    state.active_name.as_ref()?;
    let id = state.next_event_id;
    state.next_event_id += 1;

    // Extract plain-text lines from buffered raw bytes
    let mut lp = crate::parser::LineParser::new();
    let mut lines = Vec::new();
    for chunk in &state.buffer {
        let parsed = lp.feed(chunk);
        lines.extend(parsed);
    }

    let concept_name = state.active_name.take().unwrap_or_default();
    let target = state.active_target.take().unwrap_or_default();
    let raw_bytes = std::mem::take(&mut state.buffer);
    state.bytes = 0;
    if let Ok(mut bufs) = state.buffers.lock() {
        if bufs.len() >= MAX_BUFFERED_CAPTURES
            && let Some(oldest) = bufs.keys().min().copied()
        {
            bufs.remove(&oldest);
        }
        bufs.insert(id, raw_bytes);
    }

    let event = CapturedOutput {
        id,
        concept_name,
        lines,
        target_pane_type: target,
    };
    push_bounded(&state.sink, event.clone());

    state.deadline = None;
    Some(event)
}

impl CaptureSession {
    fn new(
        buffers: Arc<Mutex<HashMap<u64, Vec<Vec<u8>>>>>,
        sink: Arc<Mutex<Vec<CapturedOutput>>>,
    ) -> Self {
        Self {
            state: Arc::new(Mutex::new(CaptureState {
                buffer: Vec::new(),
                bytes: 0,
                active_name: None,
                active_target: None,
                deadline: None,
                next_event_id: 0,
                sink,
                buffers,
            })),
        }
    }

    fn is_active(&self) -> bool {
        self.state
            .lock()
            .map(|state| state.active_name.is_some())
            .unwrap_or(false)
    }

    fn begin(&self, name: String, target: String, deadline: tokio::time::Instant) {
        if let Ok(mut state) = self.state.lock() {
            state.active_name = Some(name);
            state.active_target = Some(target);
            state.deadline = Some(deadline);
        }
    }

    fn deadline(&self) -> Option<tokio::time::Instant> {
        self.state.lock().ok().and_then(|state| state.deadline)
    }

    /// Feed PTY output while capturing. Returns true when the session
    /// finalized itself (byte cap exceeded or deadline passed).
    fn feed_output(&self, bytes: Vec<u8>, now: tokio::time::Instant) -> bool {
        let Ok(mut state) = self.state.lock() else {
            return false;
        };
        if state.active_name.is_none() {
            return false;
        }
        state.bytes += bytes.len();
        state.buffer.push(bytes);
        let over_cap = state.bytes > MAX_CAPTURE_BYTES;
        let past_deadline = state.deadline.is_some_and(|d| now >= d);
        if over_cap || past_deadline {
            finalize_state(&mut state);
            true
        } else {
            false
        }
    }

    /// Emit the completed capture to the sink and store raw bytes for
    /// later flush/acknowledge. Resets all capture state.
    fn finalize(&self) -> Option<CapturedOutput> {
        let Ok(mut state) = self.state.lock() else {
            return None;
        };
        finalize_state(&mut state)
    }

    /// Finalize an in-flight capture into `sink` instead of this session's
    /// own queue.
    ///
    /// `SpawnedTerminal::drop` uses this: the pane's queue dies with the
    /// struct, so the capture goes to the engine's orphan queue, which the
    /// workspace keeps draining.
    fn finalize_to(&self, sink: Arc<Mutex<Vec<CapturedOutput>>>) -> Option<CapturedOutput> {
        let Ok(mut state) = self.state.lock() else {
            return None;
        };
        state.sink = sink;
        finalize_state(&mut state)
    }

    /// True when the active concept's `UntilStop` mode stops on user input.
    fn stops_on_input(&self, concepts: &[Concept]) -> bool {
        let Ok(state) = self.state.lock() else {
            return false;
        };
        let Some(name) = state.active_name.as_deref() else {
            return false;
        };
        concepts.iter().any(|c| {
            c.name == name
                && matches!(
                    c.capture_mode,
                    CaptureMode::UntilStop {
                        stop_on_input: true,
                        ..
                    }
                )
        })
    }

    /// Remove buffered chunks for a capture ID from the shared buffer map.
    fn take_chunks(&self, id: &u64) -> Option<Vec<Vec<u8>>> {
        let state = self.state.lock().ok()?;
        let mut bufs = state.buffers.lock().ok()?;
        bufs.remove(id)
    }
}

/// Handle a command (FlushCapture / AcknowledgeCapture) from GDScript.
fn handle_command(
    input: &StdinInput,
    grid: &Option<Arc<Mutex<TermGrid>>>,
    session: &CaptureSession,
) {
    match input {
        StdinInput::FlushCapture(id) => {
            if let Some(chunks) = session.take_chunks(id) {
                let mut lp = crate::parser::LineParser::new();
                for chunk in &chunks {
                    feed_grid(grid, chunk);
                    let parsed_lines = lp.feed(chunk);
                    for line in &parsed_lines {
                        store_line(grid, line);
                    }
                }
            }
        }
        StdinInput::AcknowledgeCapture(id) => {
            if let Some(chunks) = session.take_chunks(id) {
                let total: usize = chunks.iter().map(|c| c.len()).sum();
                let mut all_bytes = Vec::with_capacity(total);
                for chunk in &chunks {
                    all_bytes.extend_from_slice(chunk);
                }
                // The shell prompt has no trailing newline and was
                // never emitted by the line parser. Extract the raw
                // bytes after the last \n and feed them to the grid.
                if let Some(pos) = all_bytes.iter().rposition(|&b| b == b'\n') {
                    let prompt_bytes = &all_bytes[pos + 1..];
                    if !prompt_bytes.is_empty() {
                        // The \r\n from Enter was buffered with the trigger
                        // chunk and never reached the grid. Prepend \r\n so
                        // the prompt starts on a fresh line.
                        feed_grid(grid, b"\r\n");
                        feed_grid(grid, prompt_bytes);
                    }
                } else {
                    // No newline at all — entire buffer is the prompt
                    feed_grid(grid, b"\r\n");
                    feed_grid(grid, &all_bytes);
                }
            }
        }
        _ => {}
    }
}

async fn run_terminal_task(
    mut ctx: TaskContext,
    mut pty_handle: crate::pty::PtyHandle,
    mut pty_rx: mpsc::UnboundedReceiver<Vec<u8>>,
    mut stdin_rx: mpsc::UnboundedReceiver<StdinInput>,
    grid: Option<Arc<Mutex<TermGrid>>>,
) {
    // Initialize status primitives: pid and start time are known at spawn.
    if let Some(g) = &grid
        && let Ok(mut locked) = g.lock()
    {
        locked.status.pid = pty_handle.process_id();
        locked.status.started_unix_ms = unix_ms();
    }

    let mut line_parser = crate::parser::LineParser::new();

    // A safe "inactive" deadline (1 year from now) that won't overflow.
    const INACTIVE_DURATION: Duration = Duration::from_secs(86400 * 365);

    let timeout_sleep = tokio::time::sleep(INACTIVE_DURATION);
    tokio::pin!(timeout_sleep);

    loop {
        tokio::select! {
            _ = &mut timeout_sleep => {
                // Capture timeout fired
                if ctx.session.is_active() {
                    ctx.session.finalize();
                }
                timeout_sleep.as_mut().reset(tokio::time::Instant::now() + INACTIVE_DURATION);
            }
            msg = pty_rx.recv() => {
                let Some(bytes) = msg else { break; };
                // Update liveness: any PTY output means the pane was active.
                if let Some(g) = &grid
                    && let Ok(mut locked) = g.lock()
                {
                    locked.status.last_output_unix_ms = Some(unix_ms());
                }
                let lines = line_parser.feed(&bytes);
                // Tier 2 OSC declaration — spoofable by design, display
                // state only. Consumed here so the capture branch below
                // never sees stale declarations (capture-replay
                // suppression) and replayed bytes cannot re-declare state.
                let declared = line_parser.take_declared_state();

                if ctx.session.is_active() {
                    // In capture mode: buffer raw bytes, don't feed grid.
                    // feed_output finalizes on byte cap or deadline.
                    if ctx.session.feed_output(bytes, tokio::time::Instant::now()) {
                        timeout_sleep
                            .as_mut()
                            .reset(tokio::time::Instant::now() + INACTIVE_DURATION);
                    } else if let Some(deadline) = ctx.session.deadline() {
                        timeout_sleep.as_mut().reset(deadline);
                    }
                } else {
                    // Normal mode: match concepts against output lines. A
                    // match starts a capture — nothing is ever injected.
                    let now = tokio::time::Instant::now();
                    // Full-screen applications repaint themselves; their redraw
                    // lines are presentation, not shell output (e.g. an OMP TUI
                    // redrawing a transcript line containing "cat"). Never
                    // concept-match alternate-screen output.
                    let alt_screen = grid
                        .as_ref()
                        .and_then(|g| g.lock().ok())
                        .is_some_and(|g| g.is_alt_screen());
                    if !alt_screen && !ctx.pty_concept_match_suppressed(now) {
                        for line in &lines {
                            if line.len() > crate::parser::MAX_LINE_LEN {
                                // Oversized line — skip concept matching to bound
                                // regex cost. Grid and history still get it.
                                continue;
                            }
                            let concepts_guard = ctx.concepts.read().unwrap();
                            let matched = concept::match_line(&concepts_guard, line);
                            drop(concepts_guard);
                            if let Some(deadline) = ctx.apply_match(matched) {
                                timeout_sleep.as_mut().reset(deadline);
                            }
                        }
                        // Tier 2: OSC `gpty_state=<value>` declarations.
                        // Rate-limited — a prompt that reprints the
                        // declaration (or pasted text) must not churn the
                        // display state.
                        if let Some(state) = declared
                            && let Some(g) = &grid
                            && let Ok(mut locked) = g.lock()
                        {
                            let ok = locked
                                .agent_state
                                .last_declaration_unix_ms
                                .map(|t| {
                                    unix_ms().saturating_sub(t)
                                        >= crate::agent_state::DECLARATION_MIN_INTERVAL_MS
                                })
                                .unwrap_or(true);
                            if ok {
                                locked
                                    .agent_state
                                    .observe(StateTier::Tier2, state, unix_ms());
                                locked.agent_state.last_declaration_unix_ms =
                                    Some(unix_ms());
                            }
                        }
                        // Tier 3: conservative failure patterns + TTL decay.
                        if let Some(g) = &grid
                            && let Ok(mut locked) = g.lock()
                        {
                            for line in &lines {
                                if line.len() > crate::parser::MAX_LINE_LEN {
                                    continue;
                                }
                                if crate::agent_state::tier3_failure_match(line) {
                                    locked.agent_state.observe(
                                        StateTier::Tier3,
                                        AgentState::Failed,
                                        unix_ms(),
                                    );
                                    locked.agent_state.last_t3_signal_unix_ms =
                                        Some(unix_ms());
                                    break;
                                }
                            }
                            locked.agent_state.decay_t3(
                                unix_ms(),
                                crate::agent_state::TIER3_TTL_MS,
                            );
                        }
                    }
                    feed_grid(&grid, &bytes);
                    for line in &lines {
                        store_line(&grid, line);
                    }
                }
            }
            msg = stdin_rx.recv() => {
                let Some(input) = msg else { break; };
                // Only real user input (typed lines or raw keys) may stop an
                // active capture. Resize (SIGWINCH) and flush/acknowledge
                // commands share this channel but are internal plumbing —
                // letting them finalize a capture replays old output into
                // the grid and fires spurious "no receiver" toasts.
                let is_user_input = matches!(
                    &input,
                    StdinInput::Line(_) | StdinInput::Raw(_)
                );
                if is_user_input && ctx.session.is_active() {
                    let concepts_guard = ctx.concepts.read().unwrap();
                    if ctx.session.stops_on_input(&concepts_guard) {
                        ctx.session.finalize();
                        timeout_sleep
                            .as_mut()
                            .reset(tokio::time::Instant::now() + INACTIVE_DURATION);
                    }
                    drop(concepts_guard);
                }
                match &input {
                    StdinInput::Line(line) => {
                        // Match UntilStop concepts on user input (Enter).
                        // This avoids false triggers from Tab completion,
                        // command echo, and shell output noise.
                        if !ctx.session.is_active()
                            && line.len() <= crate::parser::MAX_LINE_LEN
                        {
                            let concepts_guard = ctx.concepts.read().unwrap();
                            let matched = concept::match_line(&concepts_guard, line);
                            drop(concepts_guard);
                            if let Some(deadline) = ctx.apply_match(matched) {
                                timeout_sleep.as_mut().reset(deadline);
                            }
                        }
                        if let Err(e) = pty_handle.write_line(line) {
                            log::error!("[Pane {}] PTY write error (stdin): {e}", ctx.id);
                        }
                    }
                    StdinInput::Raw(data) => {
                        if let Err(e) = pty_handle.write_bytes(data) {
                            log::error!("[Pane {}] PTY write error (raw): {e}", ctx.id);
                        }
                    }
                    StdinInput::Resize { rows, cols } => {
                        if let Err(e) = pty_handle.resize(*rows, *cols) {
                            log::error!("[Pane {}] PTY resize error: {e}", ctx.id);
                        }
                        if let Some(g) = &grid
                            && let Ok(mut locked) = g.lock() {
                                locked.resize(*rows as usize, *cols as usize);
                            }
                        ctx.suppress_pty_concept_match_until = Some(
                            tokio::time::Instant::now()
                                + Duration::from_millis(POST_RESIZE_CONCEPT_SUPPRESS_MS),
                        );
                    }
                    StdinInput::FlushCapture(_) | StdinInput::AcknowledgeCapture(_) => {
                        handle_command(&input, &grid, &ctx.session);
                    }
                }
            }
        }
        // Deliver emulator-generated replies (DSR cursor-position reports,
        // mode reports) to the child process. TUIs query the cursor after
        // SIGWINCH and fall back to broken re-anchoring without the answer.
        // Collect the replies under the lock, then write them with the guard
        // dropped: write_bytes blocks, and holding the grid mutex across a
        // blocking write stalls every consumer of that grid — including the
        // GDScript render poll — whenever the child stops draining its stdin.
        let replies = match &grid {
            Some(g) => g
                .lock()
                .map(|mut locked| locked.drain_replies())
                .unwrap_or_default(),
            None => Vec::new(),
        };
        for reply in replies {
            if let Err(e) = pty_handle.write_bytes(&reply) {
                log::error!("[Pane {}] PTY write error (reply): {e}", ctx.id);
            }
        }
    }

    // Task exit: the PTY read side closed, so the child has exited (or the
    // pane was torn down). A capture still in flight is finalized first: the
    // child is gone, so no timeout or keystroke will arrive to stop it and
    // its buffered output would otherwise be dropped unreported. This is the
    // `pane-run` case, where a command that triggers a concept and then exits
    // would lose the very output the concept was capturing.
    ctx.session.finalize();

    // Record the exit code for paneStatus/paneRun.
    if let Some(g) = &grid
        && let Ok(mut locked) = g.lock()
    {
        locked.status.exit_code = pty_handle.try_wait();
        // Tier 3 exit heuristic (display only): a shell that died with a
        // non-zero code failed; zero exits fall back to Idle.
        if let Some(code) = locked.status.exit_code
            && code != 0
        {
            locked
                .agent_state
                .observe(StateTier::Tier3, AgentState::Failed, unix_ms());
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{Action, CaptureMode, Concept, TerminalConfig};
    use regex::Regex;
    #[tokio::test]
    async fn test_spawn_terminal_and_resize() {
        let engine = WorkspaceEngine::new(vec![]);
        let config = TerminalConfig { id: 42 };

        #[cfg(windows)]
        let cmd = "cmd.exe";
        #[cfg(not(windows))]
        let cmd = "sh";

        let spawned = engine
            .spawn_terminal_with_grid(config, cmd, &[], &[], &[], 24, 80)
            .await
            .expect("Failed to spawn terminal");

        spawned.handle.resize_pty(50, 100);

        for _ in 0..10 {
            tokio::time::sleep(Duration::from_millis(10)).await;
            if let Ok(grid) = spawned.grid.lock()
                && grid.num_rows() == 50
                && grid.num_cols() == 100
            {
                break;
            }
        }

        if let Ok(grid) = spawned.grid.lock() {
            assert_eq!(grid.num_rows(), 50);
            assert_eq!(grid.num_cols(), 100);
        }

        spawned.handle.send_line("echo hello");

        let mut found = false;
        for _ in 0..50 {
            tokio::time::sleep(Duration::from_millis(20)).await;
            if let Ok(grid) = spawned.grid.lock() {
                let rows = grid.renderable_rows();
                if rows
                    .iter()
                    .any(|r| r.iter().any(|c| c.ch == 'e' || c.ch == 'h'))
                {
                    found = true;
                    break;
                }
            }
        }
        assert!(
            found,
            "Grid should have received and rendered the input text"
        );
    }

    /// Poll the spawned terminal's agent state until it leaves Idle.
    async fn wait_for_state(spawned: &SpawnedTerminal) -> crate::agent_state::AgentState {
        for _ in 0..100 {
            tokio::time::sleep(Duration::from_millis(20)).await;
            if let Ok(grid) = spawned.grid.lock() {
                let state = grid.agent_state.state;
                if state != crate::agent_state::AgentState::Idle {
                    return state;
                }
                if grid.status.exit_code.is_some() {
                    return state;
                }
            }
        }
        crate::agent_state::AgentState::Idle
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn osc_declaration_sets_tier2_state() {
        use crate::agent_state::AgentState;
        let engine = WorkspaceEngine::new(vec![]);
        let config = TerminalConfig { id: 51 };
        let spawned = engine
            .spawn_terminal_with_grid(
                config,
                "sh",
                &["-c", "printf '\\033]gpty_state=working\\007'; sleep 1"],
                &[],
                &[],
                24,
                80,
            )
            .await
            .expect("Failed to spawn terminal");
        assert_eq!(
            wait_for_state(&spawned).await,
            AgentState::Working,
            "an OSC gpty_state=working declaration must set Tier 2 state"
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn osc_declaration_ignores_unknown_values() {
        use crate::agent_state::AgentState;
        let engine = WorkspaceEngine::new(vec![]);
        let config = TerminalConfig { id: 52 };
        let spawned = engine
            .spawn_terminal_with_grid(
                config,
                "sh",
                &["-c", "printf '\\033]gpty_state=evi1\\007'; sleep 1"],
                &[],
                &[],
                24,
                80,
            )
            .await
            .expect("Failed to spawn terminal");
        assert_eq!(
            wait_for_state(&spawned).await,
            AgentState::Idle,
            "non-whitelisted declaration values must be ignored"
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn tier3_failure_pattern_sets_failed() {
        use crate::agent_state::AgentState;
        let engine = WorkspaceEngine::new(vec![]);
        let config = TerminalConfig { id: 53 };
        let spawned = engine
            .spawn_terminal_with_grid(
                config,
                "sh",
                &[
                    "-c",
                    "echo 'test result: FAILED. 2 passed; 1 failed'; sleep 1",
                ],
                &[],
                &[],
                24,
                80,
            )
            .await
            .expect("Failed to spawn terminal");
        assert_eq!(
            wait_for_state(&spawned).await,
            AgentState::Failed,
            "a Tier 3 failure pattern must set Failed"
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn shell_exit_nonzero_sets_failed() {
        use crate::agent_state::AgentState;
        let engine = WorkspaceEngine::new(vec![]);
        let config = TerminalConfig { id: 54 };
        let spawned = engine
            .spawn_terminal_with_grid(config, "sh", &["-c", "exit 3"], &[], &[], 24, 80)
            .await
            .expect("Failed to spawn terminal");
        assert_eq!(
            wait_for_state(&spawned).await,
            AgentState::Failed,
            "a shell exiting non-zero must set Failed (Tier 3)"
        );
    }

    fn test_session() -> (
        CaptureSession,
        Arc<Mutex<HashMap<u64, Vec<Vec<u8>>>>>,
        Arc<Mutex<Vec<CapturedOutput>>>,
    ) {
        let bufs: Arc<Mutex<HashMap<u64, Vec<Vec<u8>>>>> = Arc::new(Mutex::new(HashMap::new()));
        let queue: Arc<Mutex<Vec<CapturedOutput>>> = Arc::new(Mutex::new(Vec::new()));
        let session = CaptureSession::new(Arc::clone(&bufs), Arc::clone(&queue));
        (session, bufs, queue)
    }

    #[test]
    fn test_take_capture_chunks_empty() {
        let (session, _, _) = test_session();
        assert!(session.take_chunks(&42).is_none());
    }

    #[test]
    fn test_take_capture_chunks_removes_entry() {
        let (session, bufs, _) = test_session();
        {
            let mut locked = bufs.lock().unwrap();
            locked.insert(7, vec![b"hello".to_vec(), b"world".to_vec()]);
        }
        let result = session.take_chunks(&7);
        assert!(result.is_some());
        assert_eq!(result.unwrap().len(), 2);
        // Entry should be removed
        assert!(bufs.lock().unwrap().get(&7).is_none());
    }

    #[test]
    fn test_handle_command_flush_replays_to_grid() {
        let grid = Arc::new(Mutex::new(TermGrid::new(24, 80)));
        let grid_opt = Some(grid.clone());
        let (session, bufs, _) = test_session();
        {
            let mut locked = bufs.lock().unwrap();
            locked.insert(1, vec![b"hello\r\n".to_vec()]);
        }
        let input = StdinInput::FlushCapture(1);
        handle_command(&input, &grid_opt, &session);
        // After flush, chunks are consumed
        assert!(bufs.lock().unwrap().get(&1).is_none());
        // Grid should have the flushed content
        let locked = grid.lock().unwrap();
        let rows = locked.renderable_rows();
        let has_hello = rows.iter().any(|r| r.iter().any(|c| c.ch == 'h'));
        assert!(has_hello, "Grid should contain flushed text");
    }

    /// A resize (SIGWINCH) must NOT finalize an active UntilStop capture.
    /// Regression: resize shares the stdin channel with user input; the
    /// old code treated it as stop-on-input, which flushed the capture,
    /// replayed its bytes into the grid, and surfaced a spurious
    /// "no receiver" toast on every resize while a capture was live.
    #[cfg(unix)]
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn resize_does_not_finalize_active_capture() {
        let concept = Concept {
            name: "cat_test".into(),
            trigger_regex: Regex::new("cat").unwrap(),
            enabled: true,
            capture_mode: CaptureMode::UntilStop {
                stop_timeout_ms: 1000,
                stop_on_input: true,
            },
            destinations: vec![Action {
                target_label: "code_viewer".into(),
            }],
        };
        let engine = WorkspaceEngine::new(vec![concept]);
        let config = TerminalConfig { id: 77 };
        let spawned = engine
            .spawn_terminal_with_grid(config, "sh", &[], &[], &[], 24, 80)
            .await
            .expect("spawn");

        // Typed line matches the concept → capture begins (1 s timeout).
        spawned.handle.send_line("cat /dev/null");
        tokio::time::sleep(Duration::from_millis(200)).await;

        // Resize while the capture is live must not finalize it.
        spawned.handle.resize_pty(20, 60);
        tokio::time::sleep(Duration::from_millis(200)).await;
        assert_eq!(
            spawned.capture_queue.lock().unwrap().len(),
            0,
            "resize must not finalize an active capture"
        );

        // The timeout still finalizes it normally.
        tokio::time::sleep(Duration::from_millis(1200)).await;
        assert_eq!(
            spawned.capture_queue.lock().unwrap().len(),
            1,
            "capture timeout should still finalize"
        );
    }

    /// A `SingleLine` concept publishes the match and captures nothing: no
    /// capture event, no grid suppression, no pane involvement.
    #[cfg(unix)]
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn single_line_concept_notifies_without_capturing() {
        let concept = Concept {
            name: "notify_me".into(),
            trigger_regex: Regex::new("^notify me").unwrap(),
            enabled: true,
            capture_mode: CaptureMode::SingleLine,
            destinations: vec![],
        };
        let engine = WorkspaceEngine::new(vec![concept]);
        let config = TerminalConfig { id: 78 };
        let spawned = engine
            .spawn_terminal_with_grid(
                config,
                "sh",
                &["-c", "echo 'notify me now'; sleep 1"],
                &[],
                &[],
                24,
                80,
            )
            .await
            .expect("spawn");

        for _ in 0..50 {
            if !spawned.notice_queue.lock().unwrap().is_empty() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        {
            let notices = spawned.notice_queue.lock().unwrap();
            assert_eq!(notices.len(), 1, "the match must be published once");
            assert_eq!(notices[0].concept_name, "notify_me");
        }

        // Nothing was captured, and the matched line still reached the grid —
        // a notify-only match must not take the pane's output away.
        assert_eq!(
            spawned.capture_queue.lock().unwrap().len(),
            0,
            "a notify-only concept must not start a capture"
        );
        let rows = spawned.grid.lock().unwrap().renderable_rows();
        assert!(
            rows.iter().any(|r| r.iter().any(|c| c.ch == 'n')),
            "the matched line must still land in the grid"
        );
    }

    #[test]
    fn test_handle_command_acknowledge_restores_prompt() {
        let grid = Arc::new(Mutex::new(TermGrid::new(24, 80)));
        let grid_opt = Some(grid.clone());
        let (session, bufs, _) = test_session();
        {
            let mut locked = bufs.lock().unwrap();
            // Simulate buffered output with a trailing prompt line (no \n)
            locked.insert(2, vec![b"some output\nmore output\n$ prompt here".to_vec()]);
        }
        let input = StdinInput::AcknowledgeCapture(2);
        handle_command(&input, &grid_opt, &session);
        assert!(bufs.lock().unwrap().get(&2).is_none());
        let locked = grid.lock().unwrap();
        let rows = locked.renderable_rows();
        let prompt_found = rows.iter().any(|r| r.iter().any(|c| c.ch == 'p'));
        assert!(prompt_found, "Grid should contain the restored prompt");
    }

    #[test]
    fn test_handle_command_acknowledge_no_newline() {
        let grid = Arc::new(Mutex::new(TermGrid::new(24, 80)));
        let grid_opt = Some(grid.clone());
        let (session, bufs, _) = test_session();
        {
            let mut locked = bufs.lock().unwrap();
            // Entire buffer has no newline -- prompt only
            locked.insert(3, vec![b"$ ".to_vec()]);
        }
        let input = StdinInput::AcknowledgeCapture(3);
        handle_command(&input, &grid_opt, &session);
        assert!(bufs.lock().unwrap().get(&3).is_none());
    }

    #[test]
    fn test_handle_command_unknown_variant_preserves_state() {
        let grid = Arc::new(Mutex::new(TermGrid::new(24, 80)));
        let grid_opt = Some(grid.clone());
        let (session, bufs, _) = test_session();
        // Pre-populate capture buffers with known data
        {
            let mut locked = bufs.lock().unwrap();
            locked.insert(1, vec![b"captured data".to_vec()]);
        }
        // Feed content into the grid so we can verify it's untouched
        feed_grid(&grid_opt, b"original content\r\n");
        // Line variant is not FlushCapture or AcknowledgeCapture
        let input = StdinInput::Line("some command".into());
        handle_command(&input, &grid_opt, &session);
        // Buffers must be unchanged (unknown variant doesn't consume)
        assert!(
            bufs.lock().unwrap().get(&1).is_some(),
            "Unknown variant must not touch capture buffers"
        );
        // Grid content must be unchanged
        let locked = grid.lock().unwrap();
        let rows = locked.renderable_rows();
        let has_original = rows.iter().any(|r| r.iter().any(|c| c.ch == 'o'));
        assert!(has_original, "Unknown variant must not alter the grid");
    }

    // ── CaptureSession lifecycle ─────────────────────────────────

    #[test]
    fn session_begin_feed_finalize_queues_event() {
        let (session, bufs, queue) = test_session();
        let now = tokio::time::Instant::now();
        session.begin(
            "cat_cmd".into(),
            "code_viewer".into(),
            now + Duration::from_millis(300),
        );
        assert!(session.is_active());
        assert!(!session.feed_output(b"hi\n".to_vec(), now));
        let event = session.finalize().expect("finalize should emit event");
        assert_eq!(event.id, 0);
        assert_eq!(event.concept_name, "cat_cmd");
        assert_eq!(event.target_pane_type, "code_viewer");
        assert_eq!(event.lines, vec!["hi".to_string()]);
        assert!(!session.is_active());
        assert_eq!(queue.lock().unwrap().len(), 1);
        assert!(bufs.lock().unwrap().contains_key(&0));
    }

    #[test]
    fn session_feed_output_finalizes_on_deadline() {
        let (session, bufs, queue) = test_session();
        let now = tokio::time::Instant::now();
        session.begin("c".into(), "t".into(), now); // deadline == now
        assert!(session.feed_output(b"x".to_vec(), now));
        assert!(!session.is_active());
        assert_eq!(queue.lock().unwrap().len(), 1);
        assert!(bufs.lock().unwrap().contains_key(&0));
    }

    /// Lock one of the shared test queues. Recovers from poisoning so an
    /// assertion failure in an earlier test cannot cascade into later ones
    /// as a `PoisonError` instead of the failure being reported.
    fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
        mutex
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    #[test]
    fn session_finalize_to_publishes_into_the_orphan_sink() {
        let (session, bufs, queue) = test_session();
        let orphan: Arc<Mutex<Vec<CapturedOutput>>> = Arc::new(Mutex::new(Vec::new()));
        let now = tokio::time::Instant::now();
        session.begin(
            "cat_cmd".into(),
            "code_viewer".into(),
            now + Duration::from_secs(60),
        );
        assert!(!session.feed_output(b"orphaned output\n".to_vec(), now));

        let event = session
            .finalize_to(Arc::clone(&orphan))
            .expect("finalize should emit the in-flight capture");
        assert_eq!(event.concept_name, "cat_cmd");
        assert_eq!(event.lines, vec!["orphaned output".to_string()]);

        let orphaned = lock(&orphan);
        assert_eq!(
            orphaned.len(),
            1,
            "the orphan sink must receive the capture"
        );
        assert!(lock(&queue).is_empty(), "the pane queue must stay empty");
        assert!(lock(&bufs).contains_key(&0));
        assert!(!session.is_active());
    }

    /// Closing a pane mid-capture must not lose the capture: `SpawnedTerminal`
    /// aborts its task before the finalize-on-exit path can run, so `Drop`
    /// hands what the task had buffered to the engine's orphan queue, which
    /// the workspace keeps draining.
    #[cfg(unix)]
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn dropping_a_pane_finalizes_an_in_flight_capture() {
        let concept = Concept {
            name: "cat_test".into(),
            trigger_regex: Regex::new("cat").unwrap(),
            enabled: true,
            capture_mode: CaptureMode::UntilStop {
                stop_timeout_ms: 60_000,
                stop_on_input: true,
            },
            destinations: vec![Action {
                target_label: "code_viewer".into(),
            }],
        };
        let engine = WorkspaceEngine::new(vec![concept]);
        let config = TerminalConfig { id: 79 };
        let spawned = engine
            .spawn_terminal_with_grid(config, "sh", &[], &[], &[], 24, 80)
            .await
            .expect("spawn");

        // Typed line matches the concept → capture begins and stays live.
        spawned.handle.send_line("cat /dev/null");
        for _ in 0..50 {
            if spawned.capture.is_active() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        assert!(
            spawned.capture.is_active(),
            "the typed line must start a capture"
        );

        drop(spawned);

        let orphaned = engine.drain_orphaned_captures();
        assert_eq!(
            orphaned.len(),
            1,
            "a capture in flight when the pane is dropped must survive it"
        );
        assert_eq!(orphaned[0].concept_name, "cat_test");
        assert_eq!(orphaned[0].target_pane_type, "code_viewer");
        assert!(
            engine.drain_orphaned_captures().is_empty(),
            "draining must consume the orphaned capture"
        );
    }

    #[test]
    fn session_feed_output_finalizes_on_cap() {
        let (session, _, queue) = test_session();
        let now = tokio::time::Instant::now();
        session.begin("c".into(), "t".into(), now + Duration::from_secs(60));
        let flood = vec![b'x'; MAX_CAPTURE_BYTES + 1];
        assert!(session.feed_output(flood, now));
        assert_eq!(queue.lock().unwrap().len(), 1);
    }

    #[test]
    fn session_feed_output_ignores_when_inactive() {
        let (session, bufs, queue) = test_session();
        let now = tokio::time::Instant::now();
        assert!(!session.feed_output(b"x".to_vec(), now));
        assert!(queue.lock().unwrap().is_empty());
        assert!(bufs.lock().unwrap().is_empty());
    }

    #[test]
    fn session_stops_on_input_matches_flag() {
        let mut c = Concept::new("cat", Regex::new("cat").unwrap(), vec![]);
        c.capture_mode = CaptureMode::UntilStop {
            stop_timeout_ms: 300,
            stop_on_input: true,
        };
        let mut c2 = Concept::new("other", Regex::new("other").unwrap(), vec![]);
        c2.capture_mode = CaptureMode::UntilStop {
            stop_timeout_ms: 300,
            stop_on_input: false,
        };
        let (session, _, _) = test_session();
        let deadline = tokio::time::Instant::now() + Duration::from_secs(1);
        session.begin("cat".into(), "t".into(), deadline);
        assert!(session.stops_on_input(&[c]));
        assert!(!session.stops_on_input(&[c2]));
    }

    #[test]
    fn concept_match_suppressed_honors_post_resize_deadline() {
        let now = tokio::time::Instant::now();
        assert!(!concept_match_suppressed(None, now));
        assert!(concept_match_suppressed(
            Some(now + Duration::from_millis(100)),
            now,
        ));
        assert!(!concept_match_suppressed(
            Some(now - Duration::from_millis(1)),
            now,
        ));
    }
}
