//! Deterministic, multi-turn local session backend.

use tokio::sync::mpsc;

use crate::prompt::truncate_utf8;
use crate::registry::{EventSink, SessionCommand};
use crate::types::{AiEvent, BackendKind, MAX_CAPTURE_BYTES, SessionOpenRequest};

pub struct MockBackend;

pub(crate) async fn run_mock_session(
    mut commands: mpsc::UnboundedReceiver<SessionCommand>,
    sink: EventSink,
    _config: SessionOpenRequest,
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
                backend: BackendKind::Mock.as_str().into(),
            },
        );
        if cancel.is_cancelled() {
            sink.emit(turn_id, &run_id, AiEvent::Cancelled);
            continue;
        }

        let capture = truncate_utf8(&request.capture, MAX_CAPTURE_BYTES);
        sink.emit(
            turn_id,
            &run_id,
            AiEvent::Prompt {
                text: capture.clone(),
            },
        );
        sink.emit(turn_id, &run_id, AiEvent::TurnBegin);
        sink.emit(
            turn_id,
            &run_id,
            AiEvent::Thinking {
                text: format!(
                    "Inspecting {} captured lines ({} bytes) using a deterministic local backend.\n",
                    capture.lines().count(),
                    capture.len()
                ),
            },
        );
        sink.emit(turn_id, &run_id, AiEvent::AnswerStarted);

        let summary = format!(
            "## Observation\n\n\
             **Concept:** {}\n\
             **Source:** {}\n\n\
             ### Captured output\n\n\
             ```text\n{}\n```\n",
            if request.concept_name.is_empty() {
                "(none)"
            } else {
                &request.concept_name
            },
            if request.source_pane.is_empty() {
                "(unknown)"
            } else {
                &request.source_pane
            },
            capture,
        );
        let midpoint = summary.len() / 2;
        let midpoint = (0..=midpoint)
            .rev()
            .find(|index| summary.is_char_boundary(*index))
            .unwrap_or(0);
        let (first, second) = summary.split_at(midpoint);
        sink.emit(
            turn_id,
            &run_id,
            AiEvent::Delta {
                text: first.to_string(),
            },
        );
        tokio::task::yield_now().await;
        if cancel.is_cancelled() {
            sink.emit(turn_id, &run_id, AiEvent::Cancelled);
            continue;
        }
        sink.emit(
            turn_id,
            &run_id,
            AiEvent::Delta {
                text: second.to_string(),
            },
        );
        sink.emit(turn_id, &run_id, AiEvent::Done { text: summary });
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn midpoint_is_safe_for_unicode() {
        let text = "🙂🙂🙂";
        let midpoint = text.len() / 2;
        let midpoint = (0..=midpoint)
            .rev()
            .find(|index| text.is_char_boundary(*index))
            .unwrap();
        let _ = text.split_at(midpoint);
    }
}
