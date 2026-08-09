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
    Resize { rows: u16, cols: u16 },
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
        let _ = self.stdin_tx.send(StdinInput::Raw(text.as_bytes().to_vec()));
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

        tokio::spawn(run_terminal_task(task_ctx, pty_handle, pty_rx, stdin_rx, None));

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
        task_ctx.capture_queue = Arc::clone(&capture_queue);
        task_ctx.capture_buffers = Arc::clone(&capture_buffers);

        let task = tokio::spawn(run_terminal_task(
            task_ctx, pty_handle, pty_rx, stdin_rx, Some(grid_clone),
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

struct TaskContext {
    id: u32,
    labels: Vec<String>,
    concepts: Arc<std::sync::RwLock<Vec<Concept>>>,
    rx: broadcast::Receiver<Event>,
    tx: broadcast::Sender<Event>,
    // Capture state
    capture_buffer: Vec<Vec<u8>>,
    active_capture_name: Option<String>,
    active_capture_target: Option<String>,
    capture_deadline: Option<tokio::time::Instant>,
    capture_event_id: u64,
    capture_buffers: Arc<Mutex<HashMap<u64, Vec<Vec<u8>>>>>,
    capture_queue: Arc<Mutex<Vec<CapturedOutput>>>,
}

impl TaskContext {
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
            capture_buffer: Vec::new(),
            active_capture_name: None,
            active_capture_target: None,
            capture_deadline: None,
            capture_event_id: 0,
            capture_buffers: Arc::new(Mutex::new(HashMap::new())),
            capture_queue: Arc::new(Mutex::new(Vec::new())),
        }
    }
}

/// Feed raw bytes to the grid if present.
fn feed_grid(grid: &Option<Arc<Mutex<TermGrid>>>, bytes: &[u8]) {
    if let Some(g) = grid {
        if let Ok(mut locked) = g.lock() {
            locked.feed(bytes);
        }
    }
}

/// Store a line in the grid history.
fn store_line(grid: &Option<Arc<Mutex<TermGrid>>>, line: &str) {
    if let Some(g) = grid {
        if let Ok(mut locked) = g.lock() {
            locked.store_line(line);
        }
    }
}

/// Emit a completed capture to the queue and store raw bytes for
/// later flush/acknowledge.
fn finalize_capture(ctx: &mut TaskContext) {
    let id = ctx.capture_event_id;
    ctx.capture_event_id += 1;

    // Extract plain-text lines from buffered raw bytes
    let mut lp = crate::parser::LineParser::new();
    let mut lines = Vec::new();
    for chunk in &ctx.capture_buffer {
        let parsed = lp.feed(chunk);
        lines.extend(parsed);
    }


    let concept_name = ctx.active_capture_name.take().unwrap_or_default();
    let target = ctx.active_capture_target.take().unwrap_or_default();
    let raw_bytes = std::mem::take(&mut ctx.capture_buffer);
    if let Ok(mut bufs) = ctx.capture_buffers.lock() {
        bufs.insert(id, raw_bytes);
    }

    if let Ok(mut queue) = ctx.capture_queue.lock() {
        queue.push(CapturedOutput {
            id,
            concept_name,
            lines,
            target_pane_type: target,
        });
    }

    ctx.capture_deadline = None;
}

/// Handle a command (FlushCapture / AcknowledgeCapture) from GDScript.
fn handle_command(input: &StdinInput, grid: &Option<Arc<Mutex<TermGrid>>>, capture_buffers: &Arc<Mutex<HashMap<u64, Vec<Vec<u8>>>>>) {
    match input {
        StdinInput::FlushCapture(id) => {
            if let Ok(mut bufs) = capture_buffers.lock() {
                if let Some(chunks) = bufs.remove(id) {
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
        }
        StdinInput::AcknowledgeCapture(id) => {
            if let Ok(mut bufs) = capture_buffers.lock() {
                if let Some(chunks) = bufs.remove(id) {
                    let mut all_bytes: Vec<u8> = Vec::new();
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
                            // chunk and never reached the grid. Prepend \n so
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
        }
        _ => {}
    }
}
/// Check whether the active capture concept has `stop_on_input` set.
fn capture_stops_on_input(ctx: &TaskContext) -> bool {
    if let Some(ref name) = ctx.active_capture_name {
        if let Ok(concepts) = ctx.concepts.read() {
            return concepts.iter().any(|c| {
                c.name == *name
                    && matches!(c.capture_mode, CaptureMode::UntilStop { stop_on_input: true, .. })
            });
        }
    }
    false
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
                if ctx.active_capture_name.is_some() {
                    finalize_capture(&mut ctx);
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
                            let _ = pty_handle.write_line(&cmd);
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

                if ctx.active_capture_name.is_some() {
                    // In capture mode: buffer raw bytes, don't feed grid
                    ctx.capture_buffer.push(bytes);
                    if let Some(deadline) = ctx.capture_deadline {
                        let now = tokio::time::Instant::now();
                        if deadline > now {
                            timeout_sleep.as_mut().reset(deadline);
                        } else {
                            // Deadline passed — finalize now
                            finalize_capture(&mut ctx);
                            timeout_sleep.as_mut().reset(tokio::time::Instant::now() + INACTIVE_DURATION);
                        }
                    }
                } else {
                    // Normal mode: run match_and_broadcast for SingleLine
                    // concepts (event broadcast for command injection).
                    // UntilStop concepts are matched on stdin, not here.
                    for line in &lines {
                        let concepts_guard = ctx.concepts.read().unwrap();
                        let _ = concept::match_and_broadcast(
                            ctx.id, &concepts_guard, &ctx.tx, line,
                        );
                        drop(concepts_guard);
                    }
                    feed_grid(&grid, &bytes);
                    for line in &lines {
                        store_line(&grid, line);
                    }
                }
            }
            msg = stdin_rx.recv() => {
                let Some(input) = msg else { break; };
                // Check if user input should stop capture
                if ctx.active_capture_name.is_some() && capture_stops_on_input(&ctx) {
                    finalize_capture(&mut ctx);
                    timeout_sleep.as_mut().reset(tokio::time::Instant::now() + INACTIVE_DURATION);
                }
                match &input {
                    StdinInput::Line(line) => {
                        // Match UntilStop concepts on user input (Enter).
                        // This avoids false triggers from Tab completion,
                        // command echo, and shell output noise.
                        if ctx.active_capture_name.is_none() {
                            let concepts_guard = ctx.concepts.read().unwrap();
                            for concept in concepts_guard.iter() {
                                if !concept.enabled { continue; }
                                if concept.trigger_regex.is_match(line) {
                                    if let CaptureMode::UntilStop { stop_timeout_ms, .. } = &concept.capture_mode {
                                        let target = concept.destinations.first()
                                            .map(|a| a.target_label.clone())
                                            .unwrap_or_default();
                                        ctx.active_capture_name = Some(concept.name.clone());
                                        ctx.active_capture_target = Some(target);
                                        let deadline = tokio::time::Instant::now()
                                            + Duration::from_millis(*stop_timeout_ms);
                                        ctx.capture_deadline = Some(deadline);
                                        timeout_sleep.as_mut().reset(deadline);
                                        break;
                                    }
                                }
                            }
                            drop(concepts_guard);
                        }
                        let _ = pty_handle.write_line(line);
                    }
                    StdinInput::Raw(data) => {
                        let _ = pty_handle.write_bytes(data);
                    }
                    StdinInput::Resize { rows, cols } => {
                        let _ = pty_handle.resize(*rows, *cols);
                        if let Some(g) = &grid {
                            if let Ok(mut locked) = g.lock() {
                                locked.resize(*rows as usize, *cols as usize);
                            }
                        }
                    }
                    StdinInput::FlushCapture(_) | StdinInput::AcknowledgeCapture(_) => {
                        handle_command(&input, &grid, &ctx.capture_buffers);
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::TerminalConfig;
    use std::time::Duration;

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
                if rows.iter().any(|r| r.iter().any(|c| c.ch == 'e' || c.ch == 'h')) {
                    found = true;
                    break;
                }
            }
        }
        assert!(found, "Grid should have received and rendered the input text");
    }
}
