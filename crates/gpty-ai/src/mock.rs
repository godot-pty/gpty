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
        let (first, second) = split_at_midpoint(&summary);
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

/// Split `text` near its byte midpoint, never inside a character.
///
/// The mock streams its answer as two deltas; the cut is moved back to the
/// nearest character boundary so a capture full of multi-byte characters
/// cannot panic `split_at` or produce an invalid delta.
fn split_at_midpoint(text: &str) -> (&str, &str) {
    let midpoint = (0..=text.len() / 2)
        .rev()
        .find(|index| text.is_char_boundary(*index))
        .unwrap_or(0);
    text.split_at(midpoint)
}

#[cfg(test)]
mod tests {
    use super::split_at_midpoint;

    #[test]
    fn midpoint_moves_back_to_a_character_boundary() {
        // 12 bytes, midpoint 6 is inside the second emoji (bytes 4..8).
        let (first, second) = split_at_midpoint("🙂🙂🙂");
        assert_eq!(
            first, "🙂",
            "the cut moves back to byte 4, not forward to 8"
        );
        assert_eq!(second, "🙂🙂");
    }

    #[test]
    fn midpoint_keeps_every_byte_for_any_mix_of_widths() {
        // 1-, 2-, 3- and 4-byte characters at every offset: the two halves
        // must always reassemble the input, and the first half is never
        // longer than the midpoint nor shorter than the midpoint minus the
        // widest character's continuation bytes.
        let unit = "aé€🙂";
        for repeat in 1..6 {
            let text = unit.repeat(repeat);
            let (first, second) = split_at_midpoint(&text);
            assert_eq!(format!("{first}{second}"), text, "no byte lost or invented");
            assert!(first.len() <= text.len() / 2, "never past the midpoint");
            assert!(
                first.len() + 3 >= text.len() / 2,
                "moves back by at most one character's continuation bytes: {} vs {}",
                first.len(),
                text.len() / 2
            );
        }
    }

    #[test]
    fn midpoint_of_ascii_is_exact_and_of_nothing_is_nothing() {
        assert_eq!(split_at_midpoint("abcdef"), ("abc", "def"));
        assert_eq!(split_at_midpoint(""), ("", ""));
        // One character, wider than half itself: everything lands in the
        // second half rather than splitting it.
        assert_eq!(split_at_midpoint("🙂"), ("", "🙂"));
    }
}
