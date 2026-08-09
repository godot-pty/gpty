//! Concept matching — the "If This, Then That" brain.
//!
//! Every line of terminal output is tested against every registered
//! [`Concept`]'s regex trigger. When a match is found, an [`Event`] is
//! broadcast on the pub-sub channel, and terminals with matching labels
//! receive the associated [`Action`] commands.
//!
//! These are **pure functions** — no I/O, no async, no channels. They are
//! called from the engine's terminal tasks.

use tokio::sync::broadcast;

use crate::types::{CaptureMode, Concept, Event};

/// Test every concept's regex against `line`.
///
/// For each match, broadcast an [`Event`] on the channel.
///
/// Returns the name and capture mode of the first matching concept
/// that has a non-`SingleLine` capture mode, so the engine can enter
/// capture state. Disabled concepts are skipped entirely.
pub fn match_and_broadcast(
    source_id: u32,
    concepts: &[Concept],
    tx: &broadcast::Sender<Event>,
    line: &str,
) -> Option<(String, CaptureMode)> {
    let mut capture = None;
    for concept in concepts {
        if !concept.enabled {
            continue;
        }
        if let Some(caps) = concept.trigger_regex.captures(line) {
            let mut captures = Vec::with_capacity(caps.len());
            for c in caps.iter() {
                captures.push(c.map(|m| m.as_str().to_string()).unwrap_or_default());
            }
            let ev = Event {
                topic: concept.name.clone(),
                payload: line.to_string(),
                source_pane: source_id,
                captures,
            };
            log::info!("[Pane {source_id}] Broadcasting event: {:?}", ev.topic);
            let _ = tx.send(ev);
            // Only the first capture-mode concept wins
            if capture.is_none() && concept.capture_mode != CaptureMode::SingleLine {
                capture = Some((concept.name.clone(), concept.capture_mode));
            }
        }
    }
    capture
}

/// Given an incoming event, return the commands whose destination labels
/// match this terminal.
///
/// This is called from the terminal that **receives** the event (the
/// "Then That" side).
///
/// # Self-reaction prevention
///
/// If `my_id == event.source_pane`, returns an empty vector. This prevents
/// infinite feedback loops where a terminal's own output triggers a concept
/// that injects a command back into itself.
pub fn matching_commands(
    my_id: u32,
    my_labels: &[String],
    concepts: &[Concept],
    event: &Event,
) -> Vec<String> {
    if event.source_pane == my_id {
        return Vec::new();
    }
    let mut commands = Vec::new();
    for concept in concepts.iter().filter(|c| c.name == event.topic) {
        for action in &concept.destinations {
            if my_labels.contains(&action.target_label) {
                let mut cmd = action.command_template.clone();
                // Protect literal {{ with placeholder, then restore after
                let ph = "\x00OB\x00";
                cmd = cmd.replace("{{", ph);
                cmd = cmd.replace("{payload}", &event.payload);
                for (i, cap) in event.captures.iter().enumerate() {
                    cmd = cmd.replace(&format!("{{{i}}}"), cap);
                }
                // Clear remaining {N} for missing capture groups
                let re = regex::Regex::new(r"\{\d+\}").unwrap();
                cmd = re.replace_all(&cmd, "").to_string();
                cmd = cmd.replace(ph, "{");
                commands.push(cmd);
            }
        }
    }
    commands
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{Action, CaptureMode};
    use regex::Regex;

    fn make_concept(name: &str, pattern: &str, target_label: &str, cmd: &str) -> Concept {
        Concept {
            name: name.into(),
            trigger_regex: Regex::new(pattern).unwrap(),
            enabled: true,
            capture_mode: CaptureMode::SingleLine,
            destinations: vec![Action {
                command_template: cmd.into(),
                target_label: target_label.into(),
            }],
        }
    }

    fn make_event(topic: &str, source: u32) -> Event {
        Event {
            topic: topic.into(),
            payload: "test".into(),
            source_pane: source,
            captures: vec![],
        }
    }

    // ── matching_commands ──────────────────────────────────────────

    #[test]
    fn matching_commands_self_reaction_prevented() {
        let concepts = vec![make_concept("crash", "crash", "backend", "restart")];
        let event = make_event("crash", 1);
        let labels = vec!["backend".to_string()];
        let cmds = matching_commands(1, &labels, &concepts, &event);
        assert!(cmds.is_empty(), "self-reaction should return empty");
    }

    #[test]
    fn matching_commands_label_match() {
        let concepts = vec![make_concept("crash", "crash", "backend", "restart")];
        let event = make_event("crash", 1);
        let labels = vec!["backend".to_string()];
        let cmds = matching_commands(2, &labels, &concepts, &event);
        assert_eq!(cmds, vec!["restart"]);
    }

    #[test]
    fn matching_commands_label_mismatch() {
        let concepts = vec![make_concept("crash", "crash", "backend", "restart")];
        let event = make_event("crash", 1);
        let labels = vec!["observer".to_string()];
        let cmds = matching_commands(2, &labels, &concepts, &event);
        assert!(cmds.is_empty());
    }

    #[test]
    fn matching_commands_multiple_actions() {
        let concepts = vec![Concept {
            name: "crash".into(),
            trigger_regex: Regex::new("crash").unwrap(),
            enabled: true,
            capture_mode: CaptureMode::SingleLine,
            destinations: vec![
                Action {
                    command_template: "a".into(),
                    target_label: "x".into(),
                },
                Action {
                    command_template: "b".into(),
                    target_label: "y".into(),
                },
            ],
        }];
        let event = make_event("crash", 1);
        let labels = vec!["x".to_string(), "y".to_string()];
        let cmds = matching_commands(2, &labels, &concepts, &event);
        assert_eq!(cmds, vec!["a", "b"]);
    }

    // ── match_and_broadcast ────────────────────────────────────────

    #[test]
    fn match_and_broadcast_no_match() {
        let concepts = vec![make_concept("crash", "crash", "x", "cmd")];
        let (tx, mut rx) = broadcast::channel(8);
        match_and_broadcast(1, &concepts, &tx, "all good");
        assert!(rx.try_recv().is_err());
    }

    #[test]
    fn match_and_broadcast_hit() {
        let concepts = vec![make_concept("crash", "(?i)crash|panic", "x", "cmd")];
        let (tx, mut rx) = broadcast::channel(8);
        match_and_broadcast(1, &concepts, &tx, "system panic!");
        let ev = rx.try_recv().expect("should have received event");
        assert_eq!(ev.topic, "crash");
        assert_eq!(ev.source_pane, 1);
    }

    #[test]
    fn match_and_broadcast_multiple_concepts() {
        let concepts = vec![
            make_concept("a", "alpha", "x", "cmd_a"),
            make_concept("b", "beta", "x", "cmd_b"),
        ];
        let (tx, mut rx) = broadcast::channel(8);
        match_and_broadcast(1, &concepts, &tx, "beta release");
        let ev = rx.try_recv().expect("should have one event");
        assert_eq!(ev.topic, "b");
        assert!(rx.try_recv().is_err());
    }

    #[test]
    fn match_and_broadcast_skips_disabled() {
        let mut c = make_concept("crash", "crash", "x", "cmd");
        c.enabled = false;
        let concepts = vec![c];
        let (tx, mut rx) = broadcast::channel(8);
        match_and_broadcast(1, &concepts, &tx, "crash detected");
        assert!(
            rx.try_recv().is_err(),
            "disabled concept should not broadcast"
        );
    }

    #[test]
    fn match_and_broadcast_returns_capture_mode() {
        let mut c = make_concept("cat_cmd", "cat", "code_viewer", "");
        c.capture_mode = CaptureMode::UntilStop {
            stop_timeout_ms: 300,
            stop_on_input: true,
        };
        let concepts = vec![c];
        let (tx, _rx) = broadcast::channel(8);
        let result = match_and_broadcast(1, &concepts, &tx, "cat file.txt");
        assert!(result.is_some(), "UntilStop concept should return capture info");
        let (name, mode) = result.unwrap();
        assert_eq!(name, "cat_cmd");
        assert_eq!(
            mode,
            CaptureMode::UntilStop {
                stop_timeout_ms: 300,
                stop_on_input: true,
            }
        );
    }

    #[test]
    fn match_and_broadcast_singleline_returns_none() {
        let concepts = vec![make_concept("crash", "crash", "x", "cmd")];
        let (tx, _rx) = broadcast::channel(8);
        let result = match_and_broadcast(1, &concepts, &tx, "crash detected");
        assert!(
            result.is_none(),
            "SingleLine concept should not trigger capture"
        );
    }
}
