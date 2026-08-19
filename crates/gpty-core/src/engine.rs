//! The central pub-sub orchestrator.
//!
//! [`WorkspaceEngine`] is the runtime coordinator. It owns the broadcast
//! channel, the concept registry, and spawns every terminal task (mock or
//! real-PTY-backed) as an isolated tokio task. Each task:
//!
//! 1. **Listens** for incoming [`Event`]s on the broadcast channel
//! 2. **Produces** events by running its output through [`crate::concept::match_and_broadcast`]
//! 3. **Injects** commands via the PTY writer when a matching event arrives
//! 4. **Captures** output when a `UntilStop` concept fires, buffering
//!    subsequent output until a stop condition (timeout or user input).

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::{broadcast, mpsc};

use crate::concept;
use crate::term::TermGrid;
use crate::types::{CaptureMode, CapturedOutput, Concept, Event, TerminalConfig};

// ── Stdin input discrimination ────────────────────────────────────────

/// Commands sent to a PTY from the outside (keyboard or concept actions).
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
    tx: broadcast::Sender<Event>,
    concepts: Arc<std::sync::RwLock<Vec<Concept>>>,
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
    _task: tokio::task::JoinHandle<()>,
}

impl Drop for SpawnedTerminal {
    fn drop(&mut self) {
        self._task.abort();
    }
}

// ── WorkspaceEngine ───────────────────────────────────────────────────

impl WorkspaceEngine {
    pub fn new(concepts: Vec<Concept>) -> Self {
        let (tx, _) = broadcast::channel(1024);
        Self {
            tx,
            concepts: Arc::new(std::sync::RwLock::new(concepts)),
        }
    }

    pub async fn spawn_mock_terminal(
        &self,
        config: TerminalConfig,
        mock_outputs: Vec<String>,
        interval_ms: u64,
    ) {
        let mut rx = self.tx.subscribe();
        let tx = self.tx.clone();
        let concepts = Arc::clone(&self.concepts);
        let id = config.id;
        let labels = config.labels;

        tokio::spawn(async move {
            let mut interval =
                tokio::time::interval(tokio::time::Duration::from_millis(interval_ms));
            let mut idx = 0usize;
            loop {
                tokio::select! {
                    event = rx.recv() => {
                        if let Ok(event) = event {
                            let commands =
                                concept::matching_commands(id, &labels, &concepts.read().unwrap(), &event);
                            for cmd in commands {
                                log::info!("[Pane {id}] Received '{:?}'. Would execute: {cmd}", event.topic);
                            }
                        }
                    }
                    _ = interval.tick() => {
                        if let Some(line) = mock_outputs.get(idx) {
                            concept::match_and_broadcast(id, &concepts.read().unwrap(), &tx, line);
                            idx = (idx + 1) % mock_outputs.len();
                        }
                    }
                }
            }
        });
    }

    pub async fn spawn_pty_terminal(
        &self,
        config: TerminalConfig,
        command: &str,
        args: &[&str],
        envs: &[String],
    ) -> Result<PtyTerminalHandle, Box<dyn std::error::Error + Send + Sync>> {
        let (pty_tx, pty_rx) = mpsc::unbounded_channel::<Vec<u8>>();
        let pty_handle = crate::pty::PtyHandle::spawn(config.id, command, args, envs, pty_tx)?;
        let (stdin_tx, stdin_rx) = mpsc::unbounded_channel::<StdinInput>();

        let task_ctx = TaskContext::new(
            config.id,
            config.labels,
            Arc::clone(&self.concepts),
            self.tx.subscribe(),
            self.tx.clone(),
        );

        tokio::spawn(run_terminal_task(
            task_ctx, pty_handle, pty_rx, stdin_rx, None,
        ));

        Ok(PtyTerminalHandle {
            id: config.id,
            stdin_tx,
        })
    }

    pub async fn spawn_terminal_with_grid(
        &self,
        config: TerminalConfig,
        command: &str,
        args: &[&str],
        envs: &[String],
        rows: usize,
        cols: usize,
    ) -> Result<SpawnedTerminal, Box<dyn std::error::Error + Send + Sync>> {
        let (pty_tx, pty_rx) = mpsc::unbounded_channel::<Vec<u8>>();
        let pty_handle = crate::pty::PtyHandle::spawn(config.id, command, args, envs, pty_tx)?;
        let (stdin_tx, stdin_rx) = mpsc::unbounded_channel::<StdinInput>();

        let grid = Arc::new(Mutex::new(TermGrid::new(rows, cols)));
        let grid_clone = Arc::clone(&grid);

        let capture_queue: Arc<Mutex<Vec<CapturedOutput>>> = Arc::new(Mutex::new(Vec::new()));
        let capture_buffers: Arc<Mutex<HashMap<u64, Vec<Vec<u8>>>>> =
            Arc::new(Mutex::new(HashMap::new()));

        let mut task_ctx = TaskContext::new(
            config.id,
            config.labels,
            Arc::clone(&self.concepts),
            self.tx.subscribe(),
            self.tx.clone(),
        );
        task_ctx.session =
            CaptureSession::new(Arc::clone(&capture_buffers), Arc::clone(&capture_queue));

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

fn concept_match_suppressed(
    deadline: Option<tokio::time::Instant>,
    now: tokio::time::Instant,
) -> bool {
    deadline.is_some_and(|d| now < d)
}

struct TaskContext {
    id: u32,
    labels: Vec<String>,
    concepts: Arc<std::sync::RwLock<Vec<Concept>>>,
    rx: broadcast::Receiver<Event>,
    tx: broadcast::Sender<Event>,
    session: CaptureSession,
    suppress_pty_concept_match_until: Option<tokio::time::Instant>,
}

impl TaskContext {
    fn pty_concept_match_suppressed(&self, now: tokio::time::Instant) -> bool {
        concept_match_suppressed(self.suppress_pty_concept_match_until, now)
    }
    fn new(
        id: u32,
        labels: Vec<String>,
        concepts: Arc<std::sync::RwLock<Vec<Concept>>>,
        rx: broadcast::Receiver<Event>,
        tx: broadcast::Sender<Event>,
    ) -> Self {
        Self {
            id,
            labels,
            concepts,
            rx,
            tx,
            session: CaptureSession::new(
                Arc::new(Mutex::new(HashMap::new())),
                Arc::new(Mutex::new(Vec::new())),
            ),
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

/// Owns the UntilStop capture state machine: buffering, deadline, and
/// finalization into the shared chunk store and event queue.
///
/// Extracted from `run_terminal_task` so the capture lifecycle is
/// unit-testable without a real PTY.
struct CaptureSession {
    buffer: Vec<Vec<u8>>,
    bytes: usize,
    active_name: Option<String>,
    active_target: Option<String>,
    deadline: Option<tokio::time::Instant>,
    next_event_id: u64,
    buffers: Arc<Mutex<HashMap<u64, Vec<Vec<u8>>>>>,
    queue: Arc<Mutex<Vec<CapturedOutput>>>,
}

impl CaptureSession {
    fn new(
        buffers: Arc<Mutex<HashMap<u64, Vec<Vec<u8>>>>>,
        queue: Arc<Mutex<Vec<CapturedOutput>>>,
    ) -> Self {
        Self {
            buffer: Vec::new(),
            bytes: 0,
            active_name: None,
            active_target: None,
            deadline: None,
            next_event_id: 0,
            buffers,
            queue,
        }
    }

    fn is_active(&self) -> bool {
        self.active_name.is_some()
    }

    fn begin(&mut self, name: String, target: String, deadline: tokio::time::Instant) {
        self.active_name = Some(name);
        self.active_target = Some(target);
        self.deadline = Some(deadline);
    }

    fn deadline(&self) -> Option<tokio::time::Instant> {
        self.deadline
    }

    /// Feed PTY output while capturing. Returns true when the session
    /// finalized itself (byte cap exceeded or deadline passed).
    fn feed_output(&mut self, bytes: Vec<u8>, now: tokio::time::Instant) -> bool {
        if !self.is_active() {
            return false;
        }
        self.bytes += bytes.len();
        self.buffer.push(bytes);
        let over_cap = self.bytes > MAX_CAPTURE_BYTES;
        let past_deadline = self.deadline.is_some_and(|d| now >= d);
        if over_cap || past_deadline {
            self.finalize();
            true
        } else {
            false
        }
    }

    /// Emit the completed capture to the queue and store raw bytes for
    /// later flush/acknowledge. Resets all capture state.
    fn finalize(&mut self) -> Option<CapturedOutput> {
        /// Maximum number of buffered captures before dropping oldest.
        /// Prevents unbounded memory growth if GDScript stops polling.
        const MAX_BUFFERED: usize = 64;
        if !self.is_active() {
            return None;
        }
        let id = self.next_event_id;
        self.next_event_id += 1;

        // Extract plain-text lines from buffered raw bytes
        let mut lp = crate::parser::LineParser::new();
        let mut lines = Vec::new();
        for chunk in &self.buffer {
            let parsed = lp.feed(chunk);
            lines.extend(parsed);
        }

        let concept_name = self.active_name.take().unwrap_or_default();
        let target = self.active_target.take().unwrap_or_default();
        let raw_bytes = std::mem::take(&mut self.buffer);
        self.bytes = 0;
        if let Ok(mut bufs) = self.buffers.lock() {
            if bufs.len() >= MAX_BUFFERED
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
        if let Ok(mut queue) = self.queue.lock() {
            if queue.len() >= MAX_BUFFERED {
                queue.remove(0);
            }
            queue.push(event.clone());
        }

        self.deadline = None;
        Some(event)
    }

    /// True when the active concept's `UntilStop` mode stops on user input.
    fn stops_on_input(&self, concepts: &[Concept]) -> bool {
        let Some(name) = self.active_name.as_deref() else {
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
        let mut bufs = self.buffers.lock().ok()?;
        bufs.remove(id)
    }

    /// Match typed input against enabled UntilStop concepts; returns the
    /// (name, target, timeout duration) to start a capture session.
    fn match_until_stop(
        concepts: &[Concept],
        line: &str,
    ) -> Option<(String, String, std::time::Duration)> {
        for concept in concepts {
            if !concept.enabled {
                continue;
            }
            if concept.trigger_regex.is_match(line)
                && let CaptureMode::UntilStop {
                    stop_timeout_ms, ..
                } = &concept.capture_mode
            {
                let target = concept
                    .destinations
                    .first()
                    .map(|a| a.target_label.clone())
                    .unwrap_or_default();
                return Some((
                    concept.name.clone(),
                    target,
                    std::time::Duration::from_millis(*stop_timeout_ms),
                ));
            }
        }
        None
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
            msg = ctx.rx.recv() => {
                match msg {
                    Ok(event) => {
                        let concepts_guard = ctx.concepts.read().unwrap();
                        let cmds = concept::matching_commands(
                            ctx.id, &ctx.labels, &concepts_guard, &event,
                        );
                        drop(concepts_guard);
                        for cmd in cmds {
                            if let Err(e) = pty_handle.write_line(&cmd) {
                                log::error!("[Pane {}] PTY write error (concept cmd): {e}", ctx.id);
                            }
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(skipped)) => {
                        log::warn!("[Pane {}] Lagged behind broadcast, skipped {skipped} events", ctx.id);
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
            msg = pty_rx.recv() => {
                let Some(bytes) = msg else { break; };
                let lines = line_parser.feed(&bytes);

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
                    // Normal mode: match concepts against output lines.
                    // SingleLine concepts broadcast events for command injection.
                    // UntilStop concepts start capture mode to buffer subsequent output.
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
                            let capture = concept::match_and_broadcast(
                                ctx.id, &concepts_guard, &ctx.tx, line,
                            );
                            if !ctx.session.is_active()
                                && let Some((name, CaptureMode::UntilStop { stop_timeout_ms, .. }, target)) = capture
                            {
                                let deadline = tokio::time::Instant::now()
                                    + Duration::from_millis(stop_timeout_ms);
                                ctx.session.begin(name, target, deadline);
                                timeout_sleep.as_mut().reset(deadline);
                            }
                            drop(concepts_guard);
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
                            if let Some((name, target, dur)) =
                                CaptureSession::match_until_stop(&concepts_guard, line)
                            {
                                let deadline = tokio::time::Instant::now() + dur;
                                ctx.session.begin(name, target, deadline);
                                timeout_sleep.as_mut().reset(deadline);
                            }
                            drop(concepts_guard);
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
        if let Some(g) = &grid
            && let Ok(mut locked) = g.lock()
        {
            for reply in locked.drain_replies() {
                if let Err(e) = pty_handle.write_bytes(&reply) {
                    log::error!("[Pane {}] PTY write error (reply): {e}", ctx.id);
                }
            }
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{CaptureMode, Concept, TerminalConfig};
    use regex::Regex;
    #[tokio::test]
    async fn test_spawn_terminal_and_resize() {
        let engine = WorkspaceEngine::new(vec![]);
        let config = TerminalConfig {
            id: 42,
            labels: vec![],
        };

        #[cfg(windows)]
        let cmd = "cmd.exe";
        #[cfg(not(windows))]
        let cmd = "sh";

        let spawned = engine
            .spawn_terminal_with_grid(config, cmd, &[], &[], 24, 80)
            .await
            .expect("Failed to spawn terminal");

        spawned.handle.resize_pty(50, 100);

        for _ in 0..10 {
            tokio::time::sleep(Duration::from_millis(10)).await;
            if let Ok(grid) = spawned.grid.lock() {
                if grid.num_rows() == 50 && grid.num_cols() == 100 {
                    break;
                }
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
        let (mut session, bufs, queue) = test_session();
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
        let (mut session, bufs, queue) = test_session();
        let now = tokio::time::Instant::now();
        session.begin("c".into(), "t".into(), now); // deadline == now
        assert!(session.feed_output(b"x".to_vec(), now));
        assert!(!session.is_active());
        assert_eq!(queue.lock().unwrap().len(), 1);
        assert!(bufs.lock().unwrap().contains_key(&0));
    }

    #[test]
    fn session_feed_output_finalizes_on_cap() {
        let (mut session, _, queue) = test_session();
        let now = tokio::time::Instant::now();
        session.begin("c".into(), "t".into(), now + Duration::from_secs(60));
        let flood = vec![b'x'; MAX_CAPTURE_BYTES + 1];
        assert!(session.feed_output(flood, now));
        assert_eq!(queue.lock().unwrap().len(), 1);
    }

    #[test]
    fn session_feed_output_ignores_when_inactive() {
        let (mut session, bufs, queue) = test_session();
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
        let (mut session, _, _) = test_session();
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

    #[test]
    fn session_match_until_stop_returns_target_and_duration() {
        let mut c = Concept::new("cat", Regex::new("^cat").unwrap(), vec![]);
        c.capture_mode = CaptureMode::UntilStop {
            stop_timeout_ms: 300,
            stop_on_input: true,
        };
        let mut single = Concept::new("echo", Regex::new("^echo").unwrap(), vec![]);
        single.capture_mode = CaptureMode::SingleLine;
        let mut disabled = Concept::new("off", Regex::new("^off").unwrap(), vec![]);
        disabled.enabled = false;
        disabled.capture_mode = CaptureMode::UntilStop {
            stop_timeout_ms: 300,
            stop_on_input: true,
        };
        let concepts = vec![c, single, disabled];
        let m = CaptureSession::match_until_stop(&concepts, "cat file").expect("cat should match");
        assert_eq!(m.0, "cat");
        assert_eq!(m.1, "");
        assert_eq!(m.2, Duration::from_millis(300));
        assert!(CaptureSession::match_until_stop(&concepts, "echo hi").is_none());
        assert!(CaptureSession::match_until_stop(&concepts, "off thing").is_none());
    }
}
