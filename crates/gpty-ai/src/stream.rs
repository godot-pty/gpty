//! Mapping from OMP RPC events to session events.

use serde_json::Value;

use crate::types::AiEvent;

pub fn events_from_rpc_frame(frame: &Value, saw_answer: &mut bool) -> Vec<AiEvent> {
    match frame.get("type").and_then(Value::as_str) {
        Some("agent_start") => vec![AiEvent::TurnBegin],
        Some("message_update") => classify_message_update(frame, saw_answer),
        _ => Vec::new(),
    }
}

fn classify_message_update(frame: &Value, saw_answer: &mut bool) -> Vec<AiEvent> {
    let Some(event) = frame.get("assistantMessageEvent") else {
        return Vec::new();
    };
    let kind = event.get("type").and_then(Value::as_str).unwrap_or("");
    let delta = event
        .get("delta")
        .and_then(Value::as_str)
        .or_else(|| event.get("text").and_then(Value::as_str))
        .unwrap_or("");
    if delta.is_empty() {
        return Vec::new();
    }
    match kind {
        "thinking_delta" | "reasoning_delta" | "thinking" => {
            vec![AiEvent::Thinking {
                text: delta.to_string(),
            }]
        }
        "text_delta" => {
            let mut events = Vec::new();
            if !*saw_answer {
                *saw_answer = true;
                events.push(AiEvent::AnswerStarted);
            }
            events.push(AiEvent::Delta {
                text: delta.to_string(),
            });
            events
        }
        _ => Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn thinking_and_answer_channels_are_distinct() {
        let mut saw_answer = false;
        let thinking = events_from_rpc_frame(
            &json!({
                "type": "message_update",
                "assistantMessageEvent": {"type": "thinking_delta", "delta": "hmm"}
            }),
            &mut saw_answer,
        );
        let answer = events_from_rpc_frame(
            &json!({
                "type": "message_update",
                "assistantMessageEvent": {"type": "text_delta", "delta": "yes"}
            }),
            &mut saw_answer,
        );
        assert!(matches!(thinking[0], AiEvent::Thinking { .. }));
        assert_eq!(answer[0], AiEvent::AnswerStarted);
        assert!(matches!(answer[1], AiEvent::Delta { .. }));
    }
}
