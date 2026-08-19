//! Prompt assembly and capture truncation (capture is untrusted).

use crate::types::{DEFAULT_INSPECTOR_SYSTEM_PROMPT, MAX_CAPTURE_BYTES, ObservationRequest};

/// Truncate UTF-8 safely to at most `max_bytes`, appending a marker when cut.
pub fn truncate_utf8(input: &str, max_bytes: usize) -> String {
    if input.len() <= max_bytes {
        return input.to_string();
    }
    let marker = "\n\n[truncated]";
    let budget = max_bytes.saturating_sub(marker.len());
    let mut end = budget.min(input.len());
    while end > 0 && !input.is_char_boundary(end) {
        end -= 1;
    }
    let mut out = input[..end].to_string();
    out.push_str(marker);
    out
}

/// Build the user message body sent to backends.
pub fn build_user_message(req: &ObservationRequest) -> String {
    let capture = truncate_utf8(&req.capture, MAX_CAPTURE_BYTES);
    let mut parts = Vec::new();
    if !req.concept_name.is_empty() {
        parts.push(format!("Concept: {}", req.concept_name));
    }
    if !req.source_pane.is_empty() {
        parts.push(format!("Source pane: {}", req.source_pane));
    }
    parts.push("Captured output:".to_string());
    parts.push("```text".to_string());
    parts.push(capture);
    parts.push("```".to_string());
    parts.join("\n")
}

/// Resolve system prompt (pane override or default).
pub fn resolve_system_prompt(req: &ObservationRequest) -> String {
    let trimmed = req.system_prompt.trim();
    if trimmed.is_empty() {
        DEFAULT_INSPECTOR_SYSTEM_PROMPT.to_string()
    } else {
        truncate_utf8(trimmed, 8 * 1024)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::BackendKind;

    #[test]
    fn truncate_respects_char_boundary() {
        let s = "é".repeat(10);
        let out = truncate_utf8(&s, 5);
        assert!(out.contains("[truncated]"));
        assert!(out.is_char_boundary(out.len()));
    }

    #[test]
    fn build_user_message_includes_fence() {
        let req = ObservationRequest {
            backend: BackendKind::Mock,
            capture: "boom".into(),
            concept_name: "fail".into(),
            source_pane: "T1".into(),
            system_prompt: String::new(),
            cwd: String::new(),
            model: String::new(),
        };
        let msg = build_user_message(&req);
        assert!(msg.contains("Concept: fail"));
        assert!(msg.contains("Source pane: T1"));
        assert!(msg.contains("```text\nboom\n```"));
    }

    #[test]
    fn empty_system_prompt_uses_default() {
        let req = ObservationRequest {
            backend: BackendKind::Mock,
            capture: String::new(),
            concept_name: String::new(),
            source_pane: String::new(),
            system_prompt: "  ".into(),
            cwd: String::new(),
            model: String::new(),
        };
        assert_eq!(resolve_system_prompt(&req), DEFAULT_INSPECTOR_SYSTEM_PROMPT);
    }
}
