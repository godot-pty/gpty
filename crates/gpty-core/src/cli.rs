//! Plain-text CLI backend for the `cli_view` pane: one child process whose
//! stdout and stderr are merged into a queue of complete lines.
//!
//! The pane renders those lines as text ("plugin UI v1") — no terminal state,
//! no ANSI interpretation, no grid. A `cli_view` runs a line producer, so
//! lines are the whole contract. The command is always argv (`program` plus
//! `args`, never a shell), so a saved tile cannot smuggle in shell syntax.
//!
//! Each pipe is drained by its own OS thread and every line lands in one
//! shared queue. The queue is bounded ([`QUEUE_LINES`]): when it fills, the
//! reader stops reading, the pipe's kernel buffer fills, and the child's
//! `write` blocks — backpressure, not loss. Dropping lines instead would leave
//! a CLI's output silently incomplete, which is worse for a plugin UI than
//! making the child wait a frame. Teardown ([`CliProcess::stop`], `Drop`)
//! kills the child together with its process group and closes the queue, so a
//! reader blocked on a full queue cannot hold the pipe open and keep the child
//! alive.

use std::collections::VecDeque;
use std::io::Read;
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::Duration;

use crate::lock::lock_or_warn;

/// Complete lines the pane may leave undrained before the readers block.
///
/// This is the memory bound for a flooding child, and the pane drains the
/// whole queue once per frame, so its effective size is `QUEUE_LINES ×`
/// (average line length) — a handful of MiB in the worst case, and normally
/// nothing like it. The same policy as [`crate::pty::OUTPUT_QUEUE_CHUNKS`]:
/// once the queue is full the reader stops reading, the pipe fills, and the
/// child's `write` blocks. Nothing is dropped while the process runs.
pub const QUEUE_LINES: usize = 512;

/// Bytes of a single line that are held before the line is split and emitted
/// in pieces.
///
/// A line is only complete at a newline, and a child may never write one: a
/// minified bundle or a byte dump would grow the pending buffer until the
/// process died. Splitting at this bound keeps memory flat — a too-long line
/// shows up as several lines rather than as an allocation that has no ceiling.
pub const MAX_LINE_BYTES: usize = 16 * 1024;

/// Bytes read from one pipe per syscall.
const READ_BUF_SIZE: usize = 4096;

/// How long [`CliProcess::stop`] waits for the reaped exit status.
///
/// SIGKILL takes effect within microseconds, so the first `try_wait` after the
/// kill normally already sees the child. The bounded loop exists so the reaped
/// status is deterministic — a child left a zombie is a pid that never comes
/// back, and a `cli_view` restarted from pane settings replaces children
/// repeatedly — without hanging a teardown on a child stuck in an
/// uninterruptible syscall, where no signal helps and `wait` would block
/// forever.
const REAP_ATTEMPTS: u32 = 20;
const REAP_INTERVAL: Duration = Duration::from_millis(5);

/// Reason recorded when this side ended the child.
const KILLED: &str = "killed";
/// Reason recorded when the child ended on its own.
const EXITED: &str = "exited";

/// A running CLI: the child process plus the reader threads feeding its queue.
pub struct CliProcess {
    program: String,
    args: Vec<String>,
    child: Child,
    queue: Arc<LineQueue>,
    /// Reader threads, detached on drop — never joined. A grandchild that
    /// escaped the process group (its own `setsid`) can hold a pipe open past
    /// the kill, and a teardown must not wait on that; the threads exit by
    /// themselves once the pipe closes or the queue is closed.
    _readers: Vec<thread::JoinHandle<()>>,
    /// Exit code once the child has been reaped.
    exit_code: Option<i32>,
    /// `None` while the child runs, then [`EXITED`] or [`KILLED`].
    exit_reason: Option<&'static str>,
}

impl CliProcess {
    /// Spawn `program` with `args` and start draining its pipes.
    ///
    /// `program` is held to the same standard as a terminal's command
    /// ([`crate::pty::validate_program`]): a bare name is resolved through the
    /// `PATH` the child will inherit, and an absolute path must not name a
    /// file another user could have written. The child also never sees the
    /// workspace-control credentials this GUI process holds
    /// ([`crate::pty::STRIPPED_INHERITED_ENV_KEYS`]) — a `cli_view` runs a
    /// third-party CLI from a tile, and a tile is not a reason to hand one the
    /// control socket. stdin is `/dev/null`: a CLI here reports, it does not
    /// prompt.
    pub fn spawn(program: &str, args: &[String]) -> Result<CliProcess, String> {
        crate::pty::validate_program(program, std::env::var("PATH").ok().as_deref())?;

        let mut cmd = Command::new(program);
        cmd.args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        for key in crate::pty::STRIPPED_INHERITED_ENV_KEYS {
            cmd.env_remove(key);
        }
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            // Its own process group, so the kill in `stop()` can take the
            // whole tree: a CLI that starts helpers (a build, a watcher) would
            // otherwise leave them running with our pipe still open.
            cmd.process_group(0);
        }

        let mut child = cmd
            .spawn()
            .map_err(|e| format!("failed to spawn {program}: {e}"))?;
        // Both pipes were requested above, so a missing one is a platform
        // failure: reap the child instead of leaking it.
        let (Some(stdout), Some(stderr)) = (child.stdout.take(), child.stderr.take()) else {
            let _ = child.kill();
            let _ = child.wait();
            return Err(format!("no pipes for child {program}"));
        };

        let queue = Arc::new(LineQueue::new());
        let mut readers = Vec::with_capacity(2);
        for (stream, label) in [
            (Box::new(stdout) as Box<dyn Read + Send>, "stdout"),
            (Box::new(stderr) as Box<dyn Read + Send>, "stderr"),
        ] {
            let queue = Arc::clone(&queue);
            match thread::Builder::new()
                .name(format!("cli-view-{label}"))
                .spawn(move || read_lines(stream, &queue, label))
            {
                Ok(handle) => readers.push(handle),
                Err(e) => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(format!("failed to start the {label} reader: {e}"));
                }
            }
        }

        Ok(CliProcess {
            program: program.to_string(),
            args: args.to_vec(),
            child,
            queue,
            _readers: readers,
            exit_code: None,
            exit_reason: None,
        })
    }

    /// Drain every complete line queued since the last call (non-blocking).
    pub fn poll_lines(&self) -> Vec<String> {
        self.queue.drain()
    }

    /// OS process id of the child while it is alive, `None` once it has
    /// exited or been stopped.
    pub fn pid(&self) -> Option<u32> {
        self.running().then(|| self.child.id())
    }

    /// The child's status as JSON: `program`, `args`, `pid`, `running`,
    /// `exit_code`, `exit_reason`.
    ///
    /// Built here rather than in the Godot bridge so the tested artifact and
    /// the answer GDScript parses are the same bytes.
    pub fn status_json(&mut self) -> String {
        self.refresh();
        status_json_for(
            &self.program,
            &self.args,
            self.pid(),
            self.running(),
            self.exit_code,
            self.exit_reason,
        )
    }

    /// Kill the child and its process group, then release the readers.
    ///
    /// Idempotent: the FFI's `Drop` calls it after an explicit stop.
    pub fn stop(&mut self) {
        if self.exit_reason.is_some() {
            return;
        }
        // A child that ended on its own before anyone polled it did not get
        // killed: reap it first so the recorded reason is true. Both the pane's
        // Stop button and the pane closing land here.
        self.refresh();
        if self.exit_reason.is_some() {
            return;
        }
        self.exit_reason = Some(KILLED);
        // The group first, so a helper the CLI started cannot outlive it, and
        // so the child cannot spawn more on its way out. The child is a group
        // leader (`process_group(0)` above), so its pgid is its pid and a
        // negative pid signals exactly its descendants.
        #[cfg(unix)]
        {
            // SAFETY: `kill(2)` with a negative pid signals the group led by
            // that pid. It is our own child's pid, and the group was created
            // for it, so the signal cannot reach this process.
            unsafe {
                libc::kill(-(self.child.id() as i32), libc::SIGKILL);
            }
        }
        let _ = self.child.kill();
        self.reap();
        // Nothing will drain the queue again; wake any reader blocked on a
        // full queue so it can finish reading to EOF and end its thread.
        self.queue.close();
    }

    /// Whether the child is still running.
    fn running(&self) -> bool {
        self.exit_reason.is_none()
    }

    /// Record the exit status if the child has ended on its own.
    ///
    /// A child killed by us already has its reason; a child that exited while
    /// nobody polled is reaped here, which is what turns `running` false
    /// without a blocking wait.
    fn refresh(&mut self) {
        if self.exit_reason.is_some() {
            return;
        }
        match self.child.try_wait() {
            Ok(Some(status)) => {
                self.exit_code = status.code();
                self.exit_reason = Some(EXITED);
            }
            Ok(None) => {}
            // Reaped elsewhere: the child is gone, and the reason we can still
            // state is that it exited (we did not stop it — that path sets the
            // reason before calling `kill`).
            Err(_) => self.exit_reason = Some(EXITED),
        }
    }

    /// Bounded reap after the kill, so the exit status is deterministic.
    fn reap(&mut self) {
        for _ in 0..REAP_ATTEMPTS {
            match self.child.try_wait() {
                Ok(Some(status)) => {
                    self.exit_code = status.code();
                    return;
                }
                Ok(None) => thread::sleep(REAP_INTERVAL),
                Err(_) => return,
            }
        }
    }
}

impl Drop for CliProcess {
    fn drop(&mut self) {
        self.stop();
    }
}

/// The status of a pane that has no process at all — one that never started,
/// or an FFI node that was just constructed. The same field set as
/// [`CliProcess::status_json`], so GDScript parses one shape; `pid` and
/// `exit_code` are absent because nothing ever ran, and `exit_reason` stays
/// `null` because nothing ever ended.
pub fn idle_status_json() -> String {
    status_json_for("", &[], None, false, None, None)
}

/// One status shape for both the live and the never-started case.
fn status_json_for(
    program: &str,
    args: &[String],
    pid: Option<u32>,
    running: bool,
    exit_code: Option<i32>,
    exit_reason: Option<&'static str>,
) -> String {
    #[derive(serde::Serialize)]
    struct Status<'a> {
        program: &'a str,
        args: &'a [String],
        pid: Option<u32>,
        running: bool,
        exit_code: Option<i32>,
        exit_reason: Option<&'static str>,
    }

    serde_json::to_string(&Status {
        program,
        args,
        pid,
        running,
        exit_code,
        exit_reason,
    })
    .unwrap_or_default()
}

/// Read `stream` to EOF, queueing the lines it produced.
fn read_lines(mut stream: Box<dyn Read + Send>, queue: &LineQueue, label: &'static str) {
    let mut buf = [0u8; READ_BUF_SIZE];
    let mut pending = Vec::new();
    loop {
        match stream.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                let mut lines = Vec::new();
                push_chunk(&mut pending, &buf[..n], &mut lines, MAX_LINE_BYTES);
                queue.push(lines);
            }
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => {
                // The queue still holds everything read so far and the pane
                // shows it; a broken pipe only ends this half of the output.
                log::warn!("[cli_view {label}] read error: {e}");
                break;
            }
        }
    }
    // A stream that ends without a trailing newline still ends a line
    // (`printf 'done'`): flush it, or the tail of every such run is lost.
    let mut lines = Vec::new();
    flush_pending(&mut pending, &mut lines);
    queue.push(lines);
}

/// Take the pending bytes as one line, dropping a CR that CRLF left behind.
fn take_line(pending: &mut Vec<u8>) -> String {
    let end = if pending.last() == Some(&b'\r') {
        pending.len() - 1
    } else {
        pending.len()
    };
    let line = String::from_utf8_lossy(&pending[..end]).into_owned();
    pending.clear();
    line
}

/// Append the complete lines in `chunk` to `out`.
///
/// Pure and spawn-free, so the boundary cases (a split line, CRLF, a piece
/// longer than `max`) are unit-testable without a child process. `pending`
/// carries the partial line between calls; it never holds more than `max`
/// bytes.
fn push_chunk(pending: &mut Vec<u8>, chunk: &[u8], out: &mut Vec<String>, max: usize) {
    for &byte in chunk {
        if byte == b'\n' {
            out.push(take_line(pending));
            continue;
        }
        // Checked before the push, so a piece is at most `max` bytes and a
        // line ending exactly on the boundary leaves no empty remainder.
        if pending.len() >= max {
            out.push(String::from_utf8_lossy(pending).into_owned());
            pending.clear();
        }
        pending.push(byte);
    }
}

/// Emit the trailing partial line, if the stream ended mid-line.
fn flush_pending(pending: &mut Vec<u8>, out: &mut Vec<String>) {
    if !pending.is_empty() {
        out.push(take_line(pending));
    }
}

/// The line queue shared by both readers and the pane.
struct LineQueue {
    state: Mutex<QueueState>,
    /// Signalled by [`LineQueue::drain`] so a blocked reader can push.
    space: Condvar,
}

struct QueueState {
    lines: VecDeque<String>,
    /// Set by [`LineQueue::close`]: teardown, so nothing waits for space again.
    closed: bool,
}

impl LineQueue {
    fn new() -> Self {
        Self {
            state: Mutex::new(QueueState {
                lines: VecDeque::new(),
                closed: false,
            }),
            space: Condvar::new(),
        }
    }

    /// Append `lines`, blocking while the queue is full.
    fn push(&self, lines: Vec<String>) {
        let Some(mut state) = lock_or_warn(&self.state, "cli_view line queue") else {
            return;
        };
        for line in lines {
            while state.lines.len() >= QUEUE_LINES && !state.closed {
                state = match self.space.wait(state) {
                    Ok(guard) => guard,
                    // A poisoned lock cannot skip the wait (this is the wait),
                    // and the queue's contents survive a panic intact.
                    Err(poisoned) => poisoned.into_inner(),
                };
            }
            if state.closed {
                // Teardown: nobody will drain this queue again, and a reader
                // blocked here would hold the pipe open, leaving the child
                // blocked on its next write. Discard and keep reading until
                // EOF, which is what lets this thread end.
                return;
            }
            state.lines.push_back(line);
        }
    }

    /// Take everything queued.
    fn drain(&self) -> Vec<String> {
        let Some(mut state) = lock_or_warn(&self.state, "cli_view line queue") else {
            return Vec::new();
        };
        let out: Vec<String> = state.lines.drain(..).collect();
        if !out.is_empty() {
            self.space.notify_all();
        }
        out
    }

    /// Refuse further lines and wake every blocked reader.
    fn close(&self) {
        let Some(mut state) = lock_or_warn(&self.state, "cli_view line queue") else {
            return;
        };
        state.closed = true;
        self.space.notify_all();
    }
}

#[cfg(test)]
mod line_tests {
    use super::*;

    /// Feed `chunks` through the assembly helper and return the lines.
    fn lines(chunks: &[&[u8]], max: usize) -> Vec<String> {
        let mut pending = Vec::new();
        let mut out = Vec::new();
        for chunk in chunks {
            push_chunk(&mut pending, chunk, &mut out, max);
        }
        flush_pending(&mut pending, &mut out);
        out
    }

    #[test]
    fn push_chunk_splits_a_multi_line_chunk() {
        assert_eq!(
            lines(&[b"one\ntwo\nthree\n"], MAX_LINE_BYTES),
            ["one", "two", "three"]
        );
    }

    #[test]
    fn push_chunk_joins_a_line_split_across_chunks() {
        assert_eq!(
            lines(&[b"hel", b"lo wor", b"ld\nnext\n"], MAX_LINE_BYTES),
            ["hello world", "next"]
        );
    }

    #[test]
    fn push_chunk_strips_carriage_returns() {
        assert_eq!(
            lines(&[b"one\r\ntwo\r\n"], MAX_LINE_BYTES),
            ["one", "two"],
            "a CRLF stream must not leave a CR at the end of every line"
        );
        assert_eq!(lines(&[b"\r\n"], MAX_LINE_BYTES), [""]);
    }

    #[test]
    fn push_chunk_flushes_a_trailing_partial_line() {
        assert_eq!(
            lines(&[b"complete\nno-newline"], MAX_LINE_BYTES),
            ["complete", "no-newline"]
        );
    }

    #[test]
    fn push_chunk_splits_a_line_past_the_byte_cap() {
        let out = lines(&[b"0123456789abcdef"], 8);
        assert_eq!(
            out,
            ["01234567", "89abcdef"],
            "a line longer than the cap must be split, not buffered or dropped"
        );
    }

    #[test]
    fn push_chunk_keeps_a_line_that_ends_on_the_byte_cap() {
        assert_eq!(
            lines(&[b"12345678\n"], 8),
            ["12345678"],
            "a full piece followed by a newline is one line, not a line and a blank"
        );
    }
}

#[cfg(all(test, unix))]
mod process_tests {
    use super::*;
    use serde_json::Value;
    use std::time::Instant;

    /// Spawn `/bin/sh -c <script>`, which is present wherever these tests run.
    fn shell(script: &str) -> CliProcess {
        CliProcess::spawn("/bin/sh", &["-c".to_string(), script.to_string()])
            .expect("spawning /bin/sh")
    }

    /// Poll until `count` lines have arrived, or the deadline passes.
    fn collect(process: &CliProcess, count: usize) -> Vec<String> {
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut lines = Vec::new();
        while lines.len() < count && Instant::now() < deadline {
            lines.extend(process.poll_lines());
            if lines.len() < count {
                thread::sleep(Duration::from_millis(10));
            }
        }
        lines
    }

    /// Poll `status_json` until the child is reaped, or the deadline passes.
    fn wait_for_exit(process: &mut CliProcess) -> Value {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let status: Value =
                serde_json::from_str(&process.status_json()).expect("status_json is JSON");
            if status["running"] == Value::Bool(false) {
                return status;
            }
            assert!(Instant::now() < deadline, "child never exited: {status}");
            thread::sleep(Duration::from_millis(10));
        }
    }

    /// Whether `pid` stops existing within `deadline`.
    ///
    /// `kill(pid, 0)` races the reaper — a just-killed process is briefly a
    /// zombie, which still answers 0 — so the check polls rather than samples.
    fn gone_within(pid: i32, deadline: Duration) -> bool {
        let until = Instant::now() + deadline;
        loop {
            // SAFETY: signal 0 delivers nothing and only performs the
            // existence check. The pid is one this test spawned.
            if unsafe { libc::kill(pid, 0) } != 0 {
                return true;
            }
            if Instant::now() >= until {
                return false;
            }
            thread::sleep(Duration::from_millis(20));
        }
    }

    #[test]
    fn stdout_lines_arrive_then_the_child_is_reaped() {
        let mut process = shell("printf 'one\\ntwo\\nthree\\n'");
        assert_eq!(collect(&process, 3), ["one", "two", "three"]);
        let status = wait_for_exit(&mut process);
        assert_eq!(status["exit_code"], Value::from(0));
        assert_eq!(status["exit_reason"], Value::from(EXITED));
        assert_eq!(status["pid"], Value::Null);
    }

    #[test]
    fn a_stream_that_ends_without_a_newline_still_reports_its_last_line() {
        let mut process = shell("printf 'no-newline'");
        assert_eq!(collect(&process, 1), ["no-newline"]);
        let status = wait_for_exit(&mut process);
        assert_eq!(status["exit_reason"], Value::from(EXITED));
    }

    #[test]
    fn stderr_is_merged_into_the_same_queue() {
        let process = shell("printf 'out\\n'; printf 'err\\n' 1>&2");
        let mut lines = collect(&process, 2);
        // The two pipes are read concurrently, so the order between them is
        // not ours to fix — only that both streams reach the one queue.
        lines.sort();
        assert_eq!(lines, ["err", "out"]);
    }

    #[test]
    fn status_reports_the_plan_and_a_live_pid() {
        let mut process = shell("sleep 30");
        let status: Value = serde_json::from_str(&process.status_json()).unwrap();
        assert_eq!(status["program"], Value::from("/bin/sh"));
        assert_eq!(status["args"][1], Value::from("sleep 30"));
        assert_eq!(status["running"], Value::Bool(true));
        assert_eq!(status["exit_reason"], Value::Null);
        assert_eq!(status["exit_code"], Value::Null);
        assert_eq!(status["pid"], Value::from(process.pid().unwrap()));
    }

    #[test]
    fn stop_kills_the_child_and_its_process_group() {
        // `sh -c '<cmd> &'` puts the helper in the same group as the shell,
        // which is what `stop()` must take with it: a surviving helper would
        // keep our pipe open and go on running.
        let mut process = shell("sleep 30 & echo $!; wait");
        let lines = collect(&process, 1);
        let helper: i32 = lines[0]
            .trim()
            .parse()
            .expect("the helper's pid on the first line");

        process.stop();
        let status: Value = serde_json::from_str(&process.status_json()).unwrap();
        assert_eq!(status["running"], Value::Bool(false));
        assert_eq!(status["exit_reason"], Value::from(KILLED));
        assert_eq!(status["pid"], Value::Null);
        assert!(process.poll_lines().is_empty());
        assert!(
            gone_within(helper, Duration::from_secs(5)),
            "helper {helper} survived its process group"
        );
        // Idempotent: a second stop is a no-op, not a second kill.
        process.stop();
        let again: Value = serde_json::from_str(&process.status_json()).unwrap();
        assert_eq!(again, status);
    }

    #[test]
    fn stopping_a_child_that_exited_on_its_own_reports_exited() {
        let mut process = shell("printf 'bye\\n'");
        assert_eq!(collect(&process, 1), ["bye"]);
        // `printf` is the last thing the shell does, so it is gone by now and
        // its status has not been read yet (`poll_lines` does not reap).
        // Sleeping is the only way to sit on that state: the unreaped child is
        // this process's zombie, so nothing outside can observe it.
        thread::sleep(Duration::from_millis(300));
        process.stop();
        let status: Value = serde_json::from_str(&process.status_json()).unwrap();
        assert_eq!(
            status["exit_reason"],
            Value::from(EXITED),
            "a child that finished on its own was not killed by the stop"
        );
        assert_eq!(status["exit_code"], Value::from(0));
    }

    #[test]
    fn spawn_refuses_a_program_another_user_could_have_written() {
        let error = match CliProcess::spawn("/nonexistent/gpty-cli-view-test", &[]) {
            Ok(_) => panic!("a missing absolute path must be refused"),
            Err(error) => error,
        };
        assert!(
            error.contains("/nonexistent/gpty-cli-view-test"),
            "the refusal must name the program: {error}"
        );
    }
}
