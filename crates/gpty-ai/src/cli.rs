//! Generic CLI session backend — a subprocess NDJSON bridge.
//!
//! Runs a user-configured command (argv, never shell-evaluated) and speaks
//! a minimal line-delimited JSON contract with it:
//!
//! **Request** — one JSON line per prompt on the child's stdin:
//! ```json
//! {"capture":"...","concept_name":"...","source_pane":"...",
//!  "system_prompt":"...","model":"..."}
//! ```
//!
//! **Response** — one JSON line per event on the child's stdout:
//! ```json
//! {"type":"thinking","text":"..."}
//! {"type":"delta","text":"..."}
//! {"type":"done","text":"..."}
//! {"type":"error","message":"..."}
//! {"type":"status","message":"..."}
//! ```
//!
//! Adapters (ecosystem) translate a CLI's documented hooks into this
//! contract — never tokens, never TUI scraping. One child process serves
//! one prompt; cancelling kills it (`kill_on_drop` guarantees no orphans
//! when the session closes), and the next prompt spawns a fresh child.

use std::process::Stdio;
use std::time::Duration;

use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::sync::mpsc;
use tokio::time::timeout;

use crate::prompt::truncate_utf8;
use crate::registry::{CancelSignal, EventSink, SessionCommand};
use crate::types::{AiEvent, BackendKind, SessionOpenRequest};

const PROMPT_TIMEOUT: Duration = Duration::from_secs(120);
/// Read timeout for a single frame line from the child.
const FRAME_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_FRAME_BYTES: usize = 64 * 1024;

pub struct CliBackend {
    pub timeout: Duration,
}

impl Default for CliBackend {
    fn default() -> Self {
        Self {
            timeout: PROMPT_TIMEOUT,
        }
    }
}

/// Split a saved command string into argv on whitespace. Never goes
/// through a shell — quoted arguments are not supported in v1.
pub fn argv_from_string(command: &str) -> Vec<String> {
    command.split_whitespace().map(str::to_string).collect()
}

pub(crate) async fn run_cli_session(
    mut commands: mpsc::UnboundedReceiver<SessionCommand>,
    sink: EventSink,
    config: SessionOpenRequest,
) {
    while let Some(command) = commands.recv().await {
        let SessionCommand::Prompt {
            turn_id,
            run_id,
            request,
            cancel,
        } = command
        else {
            break;
        };
        sink.emit(
            turn_id,
            &run_id,
            AiEvent::Started {
                backend: BackendKind::Cli.as_str().into(),
            },
        );
        sink.emit(
            turn_id,
            &run_id,
            AiEvent::Prompt {
                text: truncate_utf8(&request.capture, 400),
            },
        );
        let result = run_one_prompt(&config, &request, &cancel, turn_id, &run_id, &sink).await;
        if let Err(message) = result {
            sink.emit(
                turn_id,
                &run_id,
                AiEvent::Error {
                    message: message.to_string(),
                },
            );
        }
    }
}

/// One prompt = one child process run (spawn → request line → frames →
/// exit). Cancelling kills the child and reports Cancelled.
async fn run_one_prompt(
    config: &SessionOpenRequest,
    request: &crate::types::SessionPromptRequest,
    cancel: &CancelSignal,
    turn_id: u64,
    run_id: &str,
    sink: &EventSink,
) -> Result<(), String> {
    if config.command.is_empty() {
        return Err(
            "cli backend has no command configured (set it in Inspector pane settings)".into(),
        );
    }
    let child = spawn_child(config)?;
    let result = timeout(
        PROMPT_TIMEOUT,
        drive_child(child, config, request, cancel, turn_id, run_id, sink),
    )
    .await;
    match result {
        Err(_) => Err(format!(
            "cli backend timed out after {}s",
            PROMPT_TIMEOUT.as_secs()
        )),
        Ok(Err(message)) => Err(message),
        Ok(Ok(())) => {
            if cancel.is_cancelled() {
                sink.emit(turn_id, run_id, AiEvent::Cancelled);
            }
            Ok(())
        }
    }
}

fn spawn_child(config: &SessionOpenRequest) -> Result<Child, String> {
    let mut command = Command::new(&config.command[0]);
    command
        .args(&config.command[1..])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    if !config.cwd.is_empty() {
        command.current_dir(&config.cwd);
    }
    command
        .spawn()
        .map_err(|e| format!("failed to spawn {}: {e}", config.command[0]))
}

struct CliChild {
    child: Child,
    stdin: ChildStdin,
    lines: tokio::io::Lines<BufReader<ChildStdout>>,
}

async fn drive_child(
    mut child: Child,
    config: &SessionOpenRequest,
    request: &crate::types::SessionPromptRequest,
    cancel: &CancelSignal,
    turn_id: u64,
    run_id: &str,
    sink: &EventSink,
) -> Result<(), String> {
    let stdin = child
        .stdin
        .take()
        .ok_or_else(|| "cli backend: no stdin".to_string())?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| "cli backend: no stdout".to_string())?;
    let mut bridge = CliChild {
        child,
        stdin,
        lines: BufReader::new(stdout).lines(),
    };

    let request_line = serde_json::json!({
        "capture": request.capture,
        "concept_name": request.concept_name,
        "source_pane": request.source_pane,
        "system_prompt": config.system_prompt,
        "model": config.model,
    })
    .to_string();
    bridge
        .stdin
        .write_all(request_line.as_bytes())
        .await
        .map_err(|e| format!("cli backend write: {e}"))?;
    bridge
        .stdin
        .write_all(b"\n")
        .await
        .map_err(|e| format!("cli backend write: {e}"))?;

    loop {
        if cancel.is_cancelled() {
            bridge.child.kill().await.ok();
            bridge.child.wait().await.ok();
            return Ok(());
        }
        let line = match timeout(FRAME_TIMEOUT, bridge.lines.next_line()).await {
            Err(_) => {
                bridge.child.kill().await.ok();
                return Err("cli backend stopped emitting frames".into());
            }
            Ok(Err(e)) => return Err(format!("cli backend read: {e}")),
            Ok(Ok(None)) => break,
            Ok(Ok(Some(line))) => line,
        };
        relay_frame(&line, turn_id, run_id, sink)?;
    }
    // Child exited (EOF). Surface a non-zero exit as an error.
    let status = bridge
        .child
        .wait()
        .await
        .map_err(|e| format!("cli backend wait: {e}"))?;
    if !status.success() {
        return Err(format!(
            "cli backend exited with {}",
            status
                .code()
                .map(|c| c.to_string())
                .unwrap_or_else(|| "signal".into())
        ));
    }
    Ok(())
}

/// Validate one NDJSON frame line and relay it as an AiEvent. Unknown
/// frame types are ignored (forward-compatible); malformed lines error.
fn relay_frame(line: &str, turn_id: u64, run_id: &str, sink: &EventSink) -> Result<(), String> {
    if line.len() > MAX_FRAME_BYTES {
        return Err(format!("cli backend frame exceeds {MAX_FRAME_BYTES} bytes"));
    }
    let frame: Value =
        serde_json::from_str(line).map_err(|e| format!("cli backend frame not JSON: {e}"))?;
    let event = match frame.get("type").and_then(Value::as_str) {
        Some("thinking") => AiEvent::Thinking {
            text: frame
                .get("text")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
        },
        Some("delta") => AiEvent::Delta {
            text: frame
                .get("text")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
        },
        Some("done") => AiEvent::Done {
            text: frame
                .get("text")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
        },
        Some("error") => AiEvent::Error {
            message: frame
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("cli backend error")
                .to_string(),
        },
        Some("status") => AiEvent::Status {
            message: frame
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
        },
        _ => return Ok(()),
    };
    sink.emit(turn_id, run_id, event);
    Ok(())
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use crate::registry::AiSession;
    use crate::types::{AiEventEnvelope, SessionPromptRequest};
    use std::io::Write;

    /// Write an executable fake adapter script that speaks the NDJSON
    /// contract, returning its path and argv. Unique per call — tests run
    /// in parallel and must never share a script file.
    fn fake_adapter(script: &str) -> (std::path::PathBuf, Vec<String>) {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
        let dir = std::env::temp_dir();
        let path = dir.join(format!(
            "gpty_fake_adapter_{}_{}.sh",
            std::process::id(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        let mut file = std::fs::File::create(&path).unwrap();
        file.write_all(script.as_bytes()).unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        (path.clone(), vec![path.to_string_lossy().to_string()])
    }

    fn prompt(text: &str) -> SessionPromptRequest {
        SessionPromptRequest {
            capture: text.into(),
            concept_name: "test".into(),
            source_pane: "T1".into(),
        }
    }

    async fn wait_terminal(session: &AiSession) -> Vec<AiEventEnvelope> {
        let mut all = Vec::new();
        for _ in 0..200 {
            tokio::time::sleep(std::time::Duration::from_millis(5)).await;
            all.extend(session.poll(128));
            if all.iter().any(|event| event.event.is_terminal()) {
                return all;
            }
        }
        panic!("cli session did not finish");
    }

    #[tokio::test]
    async fn cli_session_relays_ndjson_frames() {
        let (_path, command) = fake_adapter(
            "#!/bin/sh\nread line\n\
             printf '%s\\n' '{\"type\":\"thinking\",\"text\":\"inspecting\"}'\n\
             printf '%s\\n' '{\"type\":\"delta\",\"text\":\"found one error\"}'\n\
             printf '%s\\n' '{\"type\":\"done\",\"text\":\"found one error\"}'\n",
        );
        let session = AiSession::open(
            &tokio::runtime::Handle::current(),
            SessionOpenRequest {
                backend: BackendKind::Cli,
                command,
                ..Default::default()
            },
        )
        .unwrap();
        let (turn, _run) = session.prompt(prompt("output here")).unwrap();
        let events = wait_terminal(&session).await;
        assert_eq!(turn, 1);
        assert!(
            events
                .iter()
                .any(|e| matches!(e.event, AiEvent::Thinking { .. }))
        );
        assert!(events.iter().any(|e| matches!(
            e.event,
            AiEvent::Delta { ref text } if text == "found one error"
        )));
        assert!(events.iter().any(|e| matches!(
            e.event,
            AiEvent::Done { ref text } if text == "found one error"
        )));
        session.close();
    }

    #[tokio::test]
    async fn cli_session_surfaces_child_error_frame() {
        let (_path, command) = fake_adapter(
            "#!/bin/sh\nread line\n\
             printf '%s\\n' '{\"type\":\"error\",\"message\":\"adapter exploded\"}'\n\
             exit 1\n",
        );
        let session = AiSession::open(
            &tokio::runtime::Handle::current(),
            SessionOpenRequest {
                backend: BackendKind::Cli,
                command,
                ..Default::default()
            },
        )
        .unwrap();
        session.prompt(prompt("x")).unwrap();
        let events = wait_terminal(&session).await;
        assert!(events
            .iter()
            .any(|e| matches!(&e.event, AiEvent::Error { message } if message.contains("adapter exploded")
                || message.contains("exited with"))));
        session.close();
    }

    #[tokio::test]
    async fn cli_session_rejects_empty_command() {
        let result = AiSession::open(
            &tokio::runtime::Handle::current(),
            SessionOpenRequest {
                backend: BackendKind::Cli,
                ..Default::default()
            },
        );
        assert!(result.is_err(), "empty cli command must fail to open");
        match result {
            Err(message) => assert!(message.contains("requires a command")),
            Ok(_) => panic!("open must fail"),
        }
    }

    #[test]
    fn argv_split_never_shell_evaluates() {
        assert_eq!(
            argv_from_string("my-adapter --model foo"),
            vec!["my-adapter", "--model", "foo"]
        );
        assert_eq!(argv_from_string("  a   b  "), vec!["a", "b"]);
        assert_eq!(argv_from_string(""), Vec::<String>::new());
    }
}
