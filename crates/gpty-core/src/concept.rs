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
) -> Option<(String, CaptureMode, String)> {
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
            let _ = tx.send(ev);
            // Only the first capture-mode concept wins
            if capture.is_none() && concept.capture_mode != CaptureMode::SingleLine {
                let target = concept
                    .destinations
                    .first()
                    .map(|a| a.target_label.clone())
                    .unwrap_or_default();
                capture = Some((concept.name.clone(), concept.capture_mode, target));
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
                let cmd =
                    substitute_template(&action.command_template, &event.payload, &event.captures);
                if !cmd.is_empty() {
                    commands.push(cmd);
                }
            }
        }
    }
    commands
}

/// Quote a value for safe interpolation into a command that will be typed
/// into a PTY. Substituted values come from untrusted terminal output and
/// must never reach the shell unescaped.
///
/// Uses POSIX single-quote quoting (`'` → `'\''`), which sh, bash, zsh,
/// and fish all parse identically. Control characters are replaced with
/// spaces first. Empty values become `''`.
fn shell_quote(value: &str) -> String {
    let sanitized: String = value
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    if sanitized.is_empty() {
        return "''".to_string();
    }
    format!("'{}'", sanitized.replace('\'', "'\\''"))
}

/// Substitute `{payload}` and `{N}` capture tokens in a concept command
/// template. Every substituted value is shell-quoted via [`shell_quote`].
///
/// Single pass: substituted values are never re-scanned, so payload text
/// containing `{0}` cannot trigger a second substitution. `{{` emits a
/// literal `{`; tokens for missing capture groups are removed; any other
/// `{` is kept as-is.
pub fn substitute_template(template: &str, payload: &str, captures: &[String]) -> String {
    let mut out = String::with_capacity(template.len() + 16);
    let mut i = 0usize;
    while i < template.len() {
        let rest = &template[i..];
        if !rest.starts_with('{') {
            let c = rest.chars().next().expect("non-empty rest");
            out.push(c);
            i += c.len_utf8();
            continue;
        }
        let after = &template[i + 1..];
        if after.starts_with("payload}") {
            out.push_str(&shell_quote(payload));
            i += 1 + "payload}".len();
        } else if after.starts_with('{') {
            out.push('{');
            i += 2;
        } else if let Some(close) = after.find('}') {
            let digits = &after[..close];
            if !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()) {
                if let Ok(n) = digits.parse::<usize>()
                    && n < captures.len()
                {
                    out.push_str(&shell_quote(&captures[n]));
                }
                i += 1 + close + 1;
            } else {
                out.push('{');
                i += 1;
            }
        } else {
            out.push('{');
            i += 1;
        }
    }
    out
}

/// Caps applied when parsing concept definitions from JSON.
///
/// Concepts arrive from user-editable config files (`user://concepts.json`)
/// and are matched against every line of terminal output — unbounded
/// counts, regexes, command sizes, or capture timeouts would be DoS vectors.
pub const MAX_CONCEPTS: usize = 128;
pub const MAX_TRIGGER_LEN: usize = 1024;
pub const MAX_CMD_LEN: usize = 4096;
pub const MAX_ACTIONS: usize = 32;
pub const MAX_STOP_TIMEOUT_MS: u64 = 600_000;

/// Parse concept definitions from the JSON payload pushed by GDScript
/// (an Array of objects). Invalid entries are skipped; counts, lengths,
/// and the capture timeout are capped per the `MAX_*` constants. The
/// timeout clamp prevents `Instant::now() + Duration` overflow panics
/// in the engine.
pub fn concepts_from_json(json: &str) -> Vec<Concept> {
    use crate::types::Action;

    let Ok(value) = serde_json::from_str::<serde_json::Value>(json) else {
        return Vec::new();
    };
    let serde_json::Value::Array(arr) = value else {
        return Vec::new();
    };
    let mut concepts = Vec::new();
    let mut truncated = false;
    for item in &arr {
        if concepts.len() >= MAX_CONCEPTS {
            truncated = true;
            break;
        }
        let name = item["name"].as_str().unwrap_or("").to_string();
        if name.is_empty() || name.len() > 256 {
            continue;
        }
        let trigger = item["trigger"].as_str().unwrap_or("");
        if trigger.is_empty() || trigger.len() > MAX_TRIGGER_LEN {
            continue;
        }
        let Ok(re) = regex::Regex::new(trigger) else {
            continue;
        };
        let enabled = item["enabled"].as_bool().unwrap_or(true);
        let cap_mode = match item["capture_mode"].as_str() {
            Some("until_stop") => {
                let stop_ms = item["stop_timeout_ms"]
                    .as_u64()
                    .unwrap_or(300)
                    .clamp(1, MAX_STOP_TIMEOUT_MS);
                let stop_input = item["stop_on_input"].as_bool().unwrap_or(true);
                CaptureMode::UntilStop {
                    stop_timeout_ms: stop_ms,
                    stop_on_input: stop_input,
                }
            }
            _ => CaptureMode::SingleLine,
        };
        let mut actions = Vec::new();
        if let Some(acts) = item["actions"].as_array() {
            for a in acts {
                let cmd = a["cmd"].as_str().unwrap_or("").to_string();
                if cmd.len() > MAX_CMD_LEN {
                    continue;
                }
                let target = a["target"].as_str().unwrap_or("").to_string();
                if !target.is_empty() {
                    actions.push(Action {
                        command_template: cmd,
                        target_label: target,
                    });
                }
            }
            actions.truncate(MAX_ACTIONS);
        }
        concepts.push(Concept {
            name,
            trigger_regex: re,
            enabled,
            capture_mode: cap_mode,
            destinations: actions,
        });
    }
    if truncated {
        log::warn!("concept limit reached: only the first {MAX_CONCEPTS} concepts were loaded");
    }
    concepts
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
        assert!(
            result.is_some(),
            "UntilStop concept should return capture info"
        );
        let (name, mode, target) = result.unwrap();
        assert_eq!(name, "cat_cmd");
        assert_eq!(target, "code_viewer");
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

    // ── substitute_template ───────────────────────────────────────

    #[test]
    fn substitute_template_quotes_payload() {
        let caps = vec!["m".to_string()];
        assert_eq!(
            substitute_template("echo {payload}", "hello world", &caps),
            "echo 'hello world'"
        );
    }

    #[test]
    fn substitute_template_escapes_embedded_quote() {
        let caps = Vec::new();
        assert_eq!(
            substitute_template("echo {payload}", "x'; rm -rf /; echo '", &caps),
            r#"echo 'x'\''; rm -rf /; echo '\'''"#
        );
    }

    #[test]
    fn substitute_template_double_brace_is_literal() {
        let caps = Vec::new();
        assert_eq!(
            substitute_template("echo {{hello", "x", &caps),
            "echo {hello"
        );
    }

    #[test]
    fn substitute_template_missing_capture_removed() {
        let caps = vec!["m".to_string()];
        assert_eq!(substitute_template("echo {5}", "x", &caps), "echo ");
    }

    #[test]
    fn substitute_template_is_single_pass() {
        // Payload containing {0} must not be re-scanned and re-substituted.
        let caps = vec!["m".to_string(), "g1".to_string()];
        assert_eq!(
            substitute_template("echo {payload}", "a{0}b", &caps),
            "echo 'a{0}b'"
        );
    }

    #[test]
    fn substitute_template_empty_payload_is_quoted() {
        let caps = Vec::new();
        assert_eq!(substitute_template("echo {payload}", "", &caps), "echo ''");
    }

    #[test]
    fn substitute_template_sanitizes_control_chars() {
        let caps = Vec::new();
        assert_eq!(
            substitute_template("echo {payload}", "a\x1bb", &caps),
            "echo 'a b'"
        );
    }

    #[test]
    fn substitute_template_capture_groups() {
        let caps = vec!["full".to_string(), "one".to_string(), "two".to_string()];
        assert_eq!(
            substitute_template("cmd {0} {1} {2}", "p", &caps),
            "cmd 'full' 'one' 'two'"
        );
    }

    #[test]
    fn substitute_template_stray_brace_kept() {
        let caps = Vec::new();
        assert_eq!(
            substitute_template("echo {notatoken}", "x", &caps),
            "echo {notatoken}"
        );
    }

    // ── concepts_from_json ────────────────────────────────────────

    #[test]
    fn concepts_from_json_rejects_invalid_input() {
        assert!(concepts_from_json("not json").is_empty());
        assert!(concepts_from_json("{\"a\":1}").is_empty());
    }

    #[test]
    fn concepts_from_json_skips_invalid_regex_and_bad_names() {
        let json = r#"[
            {"name": "", "trigger": "x"},
            {"name": "ok", "trigger": "("},
            {"name": "good", "trigger": "^cat", "capture_mode": "until_stop",
             "actions": [{"cmd": "", "target": "code_viewer"}]}
        ]"#;
        let concepts = concepts_from_json(json);
        assert_eq!(concepts.len(), 1);
        assert_eq!(concepts[0].name, "good");
    }

    #[test]
    fn concepts_from_json_clamps_timeout() {
        let json = r#"[
            {"name": "c", "trigger": "x", "capture_mode": "until_stop",
             "stop_timeout_ms": 4000000000}
        ]"#;
        let concepts = concepts_from_json(json);
        match concepts[0].capture_mode {
            CaptureMode::UntilStop {
                stop_timeout_ms, ..
            } => {
                assert_eq!(stop_timeout_ms, MAX_STOP_TIMEOUT_MS);
            }
            _ => panic!("expected until_stop capture mode"),
        }
    }

    #[test]
    fn concepts_from_json_truncates_count() {
        let mut items = String::from("[");
        for i in 0..(MAX_CONCEPTS + 10) {
            if i > 0 {
                items.push(',');
            }
            items.push_str(&format!(r#"{{"name": "c{i}", "trigger": "x"}}"#));
        }
        items.push(']');
        assert_eq!(concepts_from_json(&items).len(), MAX_CONCEPTS);
    }

    #[test]
    fn concepts_from_json_skips_oversized_trigger() {
        let long = "a".repeat(MAX_TRIGGER_LEN + 1);
        let json = format!(r#"[{{"name": "c", "trigger": "{long}"}}]"#);
        assert!(concepts_from_json(&json).is_empty());
    }

    #[test]
    fn concepts_from_json_caps_cmd_and_actions() {
        let long_cmd = "x".repeat(MAX_CMD_LEN + 1);
        let mut acts = String::new();
        for i in 0..(MAX_ACTIONS + 10) {
            if i > 0 {
                acts.push(',');
            }
            acts.push_str(&format!(r#"{{"cmd": "e{i}", "target": "t"}}"#));
        }
        let json = format!(
            r#"[{{"name": "c", "trigger": "x", "actions": [{{"cmd": "{long_cmd}", "target": "t"}}, {acts}]}}]"#
        );
        let concepts = concepts_from_json(&json);
        assert_eq!(concepts[0].destinations.len(), MAX_ACTIONS);
        assert_eq!(concepts[0].destinations[0].command_template, "e0");
    }
}
