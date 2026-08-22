//! Long-lived Oh-My-Pi (`omp --mode rpc`) session backend.

use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader, Lines};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

use crate::backend::BackendError;
use crate::binary::resolve_omp_binary;
use crate::prompt::{build_user_message, resolve_system_prompt, truncate_utf8};
use crate::registry::{CancelSignal, EventSink, SessionCommand};
use crate::stream::events_from_rpc_frame;
use crate::types::{AiEvent, BackendKind, SessionOpenRequest, SessionPromptRequest};

const PROMPT_TIMEOUT: Duration = Duration::from_secs(120);
const START_TIMEOUT: Duration = Duration::from_secs(30);
const CANCEL_WAIT: Duration = Duration::from_secs(2);
const MAX_REASSEMBLED_FRAME_BYTES: usize = 64 * 1024 * 1024;
const MAX_CHUNKS: usize = 4096;
static NEXT_COMMAND_ID: AtomicU64 = AtomicU64::new(1);

pub struct OmpBackend {
    pub extra_args: Vec<String>,
    pub timeout: Duration,
}

impl Default for OmpBackend {
    fn default() -> Self {
        Self {
            extra_args: Vec::new(),
            timeout: PROMPT_TIMEOUT,
        }
    }
}

pub(crate) async fn run_omp_session(
    mut commands: mpsc::UnboundedReceiver<SessionCommand>,
    sink: EventSink,
    config: SessionOpenRequest,
) {
    let mut process = OmpProcess::spawn(&config, &[]).await;
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
                backend: BackendKind::Omp.as_str().into(),
            },
        );
        sink.emit(
            turn_id,
            &run_id,
            AiEvent::Prompt {
                text: truncate_utf8(&request.capture, 400),
            },
        );

        let result = match process.as_mut() {
            Ok(process) => {
                process
                    .prompt(&config, &request, &cancel, turn_id, &run_id, &sink)
                    .await
            }
            Err(message) => Err(BackendError::Message(message.clone())),
        };
        if let Err(error) = result {
            sink.emit(
                turn_id,
                &run_id,
                AiEvent::Error {
                    message: error.to_string(),
                },
            );
        }
    }
    if let Ok(process) = process.as_mut() {
        process.shutdown().await;
    }
}

struct OmpProcess {
    child: Child,
    stdin: ChildStdin,
    lines: Lines<BufReader<ChildStdout>>,
    decoder: RpcFrameDecoder,
    stderr_task: JoinHandle<()>,
}

impl OmpProcess {
    async fn spawn(config: &SessionOpenRequest, extra_args: &[String]) -> Result<Self, String> {
        let binary = resolve_omp_binary().ok_or_else(|| {
            "omp binary not found (install Oh-My-Pi or set GPTY_OMP to an absolute path)"
                .to_string()
        })?;
        let observation = crate::types::ObservationRequest {
            backend: BackendKind::Omp,
            capture: String::new(),
            concept_name: String::new(),
            source_pane: String::new(),
            system_prompt: config.system_prompt.clone(),
            cwd: config.cwd.clone(),
            model: config.model.clone(),
        };
        let mut command = Command::new(&binary);
        command
            .arg("--mode")
            .arg("rpc")
            .arg("--no-session")
            .arg("--no-tools")
            .arg("--no-extensions")
            .arg("--no-skills")
            .arg("--no-rules")
            .arg("--system-prompt")
            .arg(resolve_system_prompt(&observation))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        if !config.cwd.is_empty() {
            command.arg("--cwd").arg(&config.cwd);
            command.current_dir(&config.cwd);
        }
        if !config.model.is_empty() {
            command.arg("--model").arg(&config.model);
        }
        command.args(extra_args);

        let mut child = command
            .spawn()
            .map_err(|error| format!("failed to spawn omp at {}: {error}", binary.display()))?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| "omp stdin missing".to_string())?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| "omp stdout missing".to_string())?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| "omp stderr missing".to_string())?;
        let stderr_task = tokio::spawn(async move {
            let mut reader = BufReader::new(stderr);
            let mut buffer = [0_u8; 4096];
            loop {
                match reader.read(&mut buffer).await {
                    Ok(0) | Err(_) => break,
                    Ok(count) => {
                        let text = String::from_utf8_lossy(&buffer[..count]);
                        log::warn!("omp stderr: {}", text.trim_end());
                    }
                }
            }
        });
        let mut process = Self {
            child,
            stdin,
            lines: BufReader::new(stdout).lines(),
            decoder: RpcFrameDecoder::default(),
            stderr_task,
        };
        let ready = tokio::time::timeout(START_TIMEOUT, process.next_frame())
            .await
            .map_err(|_| "timeout waiting for omp ready".to_string())?
            .map_err(|error| error.to_string())?
            .ok_or_else(|| "omp stdout closed before ready".to_string())?;
        if ready.get("type").and_then(Value::as_str) != Some("ready") {
            process
                .wait_for_type("ready", START_TIMEOUT)
                .await
                .map_err(|error| error.to_string())?;
        }
        process
            .write(json!({
                "id": next_id(),
                "type": "negotiate_protocol",
                "protocolVersion": 2
            }))
            .await
            .map_err(|error| error.to_string())?;
        Ok(process)
    }

    async fn prompt(
        &mut self,
        config: &SessionOpenRequest,
        request: &SessionPromptRequest,
        cancel: &CancelSignal,
        turn_id: u64,
        run_id: &str,
        sink: &EventSink,
    ) -> Result<(), BackendError> {
        if cancel.is_cancelled() {
            sink.emit(turn_id, run_id, AiEvent::Cancelled);
            return Ok(());
        }
        let message = build_user_message(&request.as_observation(config));
        self.write(json!({"id": next_id(), "type": "prompt", "message": message}))
            .await?;

        let deadline = tokio::time::Instant::now() + PROMPT_TIMEOUT;
        let mut assembled = String::new();
        let mut saw_answer = false;
        loop {
            let frame = tokio::select! {
                biased;
                _ = cancel.notified() => {
                    self.abort_and_wait().await;
                    sink.emit(turn_id, run_id, AiEvent::Cancelled);
                    return Ok(());
                }
                _ = tokio::time::sleep_until(deadline) => {
                    self.abort_and_wait().await;
                    return Err(BackendError::Message("omp prompt timed out".into()));
                }
                frame = self.next_frame() => frame?,
            };
            let Some(frame) = frame else {
                return Err(BackendError::Message("omp stdout closed early".into()));
            };
            if self.handle_extension_ui(&frame).await? {
                continue;
            }
            match frame.get("type").and_then(Value::as_str) {
                Some("agent_start") | Some("message_update") => {
                    for event in events_from_rpc_frame(&frame, &mut saw_answer) {
                        if let AiEvent::Delta { text } = &event {
                            assembled.push_str(text);
                        }
                        sink.emit(turn_id, run_id, event);
                    }
                }
                Some("agent_end")
                    if frame.get("willContinue").and_then(Value::as_bool) != Some(true)
                        && frame.get("isTerminal").and_then(Value::as_bool) != Some(false) =>
                {
                    sink.emit(turn_id, run_id, AiEvent::Done { text: assembled });
                    return Ok(());
                }
                Some("prompt_result")
                    if frame.get("agentInvoked").and_then(Value::as_bool) == Some(false) =>
                {
                    sink.emit(turn_id, run_id, AiEvent::Done { text: assembled });
                    return Ok(());
                }
                Some("response")
                    if frame.get("success").and_then(Value::as_bool) == Some(false) =>
                {
                    let command = frame.get("command").and_then(Value::as_str).unwrap_or("?");
                    if command == "prompt" || command == "parse" {
                        let message = frame
                            .get("error")
                            .and_then(Value::as_str)
                            .unwrap_or("omp command failed");
                        return Err(BackendError::Message(format!("omp {command}: {message}")));
                    }
                }
                _ => {}
            }
        }
    }

    async fn abort_and_wait(&mut self) {
        if self
            .write(json!({"id": next_id(), "type": "abort"}))
            .await
            .is_err()
        {
            self.kill_and_wait().await;
            return;
        }
        let deadline = tokio::time::Instant::now() + CANCEL_WAIT;
        loop {
            let frame = tokio::select! {
                _ = tokio::time::sleep_until(deadline) => {
                    self.kill_and_wait().await;
                    return;
                }
                frame = self.next_frame() => frame,
            };
            match frame {
                Ok(Some(frame))
                    if matches!(
                        frame.get("type").and_then(Value::as_str),
                        Some("agent_end" | "prompt_result")
                    ) =>
                {
                    return;
                }
                Ok(Some(_)) => {}
                Ok(None) | Err(_) => {
                    self.kill_and_wait().await;
                    return;
                }
            }
        }
    }

    async fn next_frame(&mut self) -> Result<Option<Value>, BackendError> {
        loop {
            let Some(line) = self.lines.next_line().await? else {
                return Ok(None);
            };
            if line.trim().is_empty() {
                continue;
            }
            let physical: Value = serde_json::from_str(&line).map_err(|error| {
                BackendError::Message(format!("invalid omp RPC frame: {error}"))
            })?;
            if let Some(frame) = self.decoder.push(physical)? {
                return Ok(Some(frame));
            }
        }
    }

    async fn wait_for_type(
        &mut self,
        wanted: &str,
        timeout: Duration,
    ) -> Result<Value, BackendError> {
        let deadline = tokio::time::Instant::now() + timeout;
        loop {
            let frame = tokio::time::timeout_at(deadline, self.next_frame())
                .await
                .map_err(|_| {
                    BackendError::Message(format!("timeout waiting for omp {wanted}"))
                })??;
            let Some(frame) = frame else {
                return Err(BackendError::Message(format!(
                    "omp stdout closed before {wanted}"
                )));
            };
            if self.handle_extension_ui(&frame).await? {
                continue;
            }
            if frame.get("type").and_then(Value::as_str) == Some(wanted) {
                return Ok(frame);
            }
        }
    }

    async fn handle_extension_ui(&mut self, frame: &Value) -> Result<bool, BackendError> {
        if frame.get("type").and_then(Value::as_str) != Some("extension_ui_request") {
            return Ok(false);
        }
        if let Some(id) = frame.get("id").and_then(Value::as_str) {
            self.write(json!({
                "type": "extension_ui_response",
                "id": id,
                "cancelled": true
            }))
            .await?;
        }
        Ok(true)
    }

    async fn write(&mut self, value: Value) -> Result<(), BackendError> {
        let mut line = serde_json::to_string(&value)
            .map_err(|error| BackendError::Message(error.to_string()))?;
        line.push('\n');
        self.stdin.write_all(line.as_bytes()).await?;
        self.stdin.flush().await?;
        Ok(())
    }

    async fn kill_and_wait(&mut self) {
        let _ = self.child.kill().await;
        let _ = tokio::time::timeout(CANCEL_WAIT, self.child.wait()).await;
    }

    async fn shutdown(&mut self) {
        self.kill_and_wait().await;
        self.stderr_task.abort();
    }
}

impl Drop for OmpProcess {
    fn drop(&mut self) {
        let _ = self.child.start_kill();
        self.stderr_task.abort();
    }
}

fn next_id() -> String {
    format!("gpty-{}", NEXT_COMMAND_ID.fetch_add(1, Ordering::Relaxed))
}

#[derive(Default)]
struct RpcFrameDecoder {
    pending: Option<PendingChunks>,
}

struct PendingChunks {
    id: String,
    count: usize,
    byte_length: usize,
    next_index: usize,
    bytes: Vec<u8>,
}

impl RpcFrameDecoder {
    fn push(&mut self, frame: Value) -> Result<Option<Value>, BackendError> {
        if frame.get("type").and_then(Value::as_str) != Some("rpc_chunk") {
            if self.pending.is_some() {
                return Err(BackendError::Message(
                    "OMP rpc_chunk sequence was interrupted".into(),
                ));
            }
            return Ok(Some(frame));
        }

        let id = required_str(&frame, "chunkId")?;
        let index = required_usize(&frame, "index")?;
        let count = required_usize(&frame, "count")?;
        let byte_length = required_usize(&frame, "byteLength")?;
        let data = required_str(&frame, "data")?;
        if count == 0
            || count > MAX_CHUNKS
            || byte_length == 0
            || byte_length > MAX_REASSEMBLED_FRAME_BYTES
            || index >= count
        {
            return Err(BackendError::Message(
                "invalid or oversized OMP rpc_chunk metadata".into(),
            ));
        }
        if self.pending.is_none() {
            if index != 0 {
                return Err(BackendError::Message(
                    "OMP rpc_chunk sequence did not start at index 0".into(),
                ));
            }
            self.pending = Some(PendingChunks {
                id: id.to_string(),
                count,
                byte_length,
                next_index: 0,
                bytes: Vec::with_capacity(byte_length),
            });
        }
        let pending = self.pending.as_mut().expect("pending initialized");
        if pending.id != id
            || pending.count != count
            || pending.byte_length != byte_length
            || pending.next_index != index
        {
            self.pending = None;
            return Err(BackendError::Message(
                "invalid or interleaved OMP rpc_chunk sequence".into(),
            ));
        }
        decode_base64_into(data, &mut pending.bytes, pending.byte_length)?;
        pending.next_index += 1;
        if pending.next_index != pending.count {
            return Ok(None);
        }

        let pending = self.pending.take().expect("complete pending sequence");
        if pending.bytes.len() != pending.byte_length {
            return Err(BackendError::Message(
                "OMP rpc_chunk byteLength mismatch".into(),
            ));
        }
        let text = String::from_utf8(pending.bytes)
            .map_err(|_| BackendError::Message("OMP rpc_chunk payload is not UTF-8".into()))?;
        let logical = serde_json::from_str(&text).map_err(|error| {
            BackendError::Message(format!("invalid reassembled RPC JSON: {error}"))
        })?;
        Ok(Some(logical))
    }
}

fn required_str<'a>(value: &'a Value, key: &str) -> Result<&'a str, BackendError> {
    value
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| BackendError::Message(format!("rpc_chunk missing {key}")))
}

fn required_usize(value: &Value, key: &str) -> Result<usize, BackendError> {
    value
        .get(key)
        .and_then(Value::as_u64)
        .and_then(|number| usize::try_from(number).ok())
        .ok_or_else(|| BackendError::Message(format!("rpc_chunk missing {key}")))
}

fn decode_base64_into(input: &str, output: &mut Vec<u8>, limit: usize) -> Result<(), BackendError> {
    if !input.len().is_multiple_of(4) {
        return Err(BackendError::Message("invalid rpc_chunk base64".into()));
    }
    for chunk in input.as_bytes().as_chunks::<4>().0 {
        let a = base64_value(chunk[0])?;
        let b = base64_value(chunk[1])?;
        let c_pad = chunk[2] == b'=';
        let d_pad = chunk[3] == b'=';
        if c_pad && !d_pad {
            return Err(BackendError::Message(
                "invalid rpc_chunk base64 padding".into(),
            ));
        }
        let c = if c_pad { 0 } else { base64_value(chunk[2])? };
        let d = if d_pad { 0 } else { base64_value(chunk[3])? };
        let needed = 1 + usize::from(!c_pad) + usize::from(!d_pad);
        if output.len().saturating_add(needed) > limit {
            return Err(BackendError::Message(
                "rpc_chunk decoded beyond advertised byteLength".into(),
            ));
        }
        output.push((a << 2) | (b >> 4));
        if !c_pad {
            output.push((b << 4) | (c >> 2));
        }
        if !d_pad {
            output.push((c << 6) | d);
        }
    }
    Ok(())
}

fn base64_value(byte: u8) -> Result<u8, BackendError> {
    match byte {
        b'A'..=b'Z' => Ok(byte - b'A'),
        b'a'..=b'z' => Ok(byte - b'a' + 26),
        b'0'..=b'9' => Ok(byte - b'0' + 52),
        b'+' => Ok(62),
        b'/' => Ok(63),
        _ => Err(BackendError::Message(
            "invalid rpc_chunk base64 character".into(),
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rpc_chunks_reassemble_strictly() {
        let mut decoder = RpcFrameDecoder::default();
        let first = json!({
            "type":"rpc_chunk", "chunkId":"one", "index":0, "count":2,
            "byteLength":16, "data":"eyJ0eXBlIjoi"
        });
        let second = json!({
            "type":"rpc_chunk", "chunkId":"one", "index":1, "count":2,
            "byteLength":16, "data":"cmVhZHkifQ=="
        });
        assert!(decoder.push(first).unwrap().is_none());
        let frame = decoder.push(second).unwrap().unwrap();
        assert_eq!(frame, json!({"type":"ready"}));
    }

    #[test]
    fn rpc_chunks_reject_interleaving_and_oversize() {
        let mut decoder = RpcFrameDecoder::default();
        decoder
            .push(json!({
                "type":"rpc_chunk", "chunkId":"one", "index":0, "count":2,
                "byteLength":2, "data":"eA=="
            }))
            .unwrap();
        assert!(
            decoder
                .push(json!({"type":"ready"}))
                .unwrap_err()
                .to_string()
                .contains("interrupted")
        );
        assert!(
            RpcFrameDecoder::default()
                .push(json!({
                    "type":"rpc_chunk", "chunkId":"x", "index":0, "count":1,
                    "byteLength":MAX_REASSEMBLED_FRAME_BYTES + 1, "data":"eA=="
                }))
                .is_err()
        );
    }
}
