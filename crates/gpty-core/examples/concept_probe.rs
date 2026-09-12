//! Measures what concept matching costs a pane that is being flooded.
//!
//! Every output line is tested against every enabled concept
//! (`concept::match_line`), so the aggregate cost is lines × concepts × regex —
//! on the PTY-output path and on the typed-input path alike. Two measurements:
//!
//! 1. `match_line` in isolation: ns per line for the shipped default set, a
//!    hand-authored library at the concept cap (128 short triggers), and the
//!    ceiling the parser's caps allow (128 concepts, each a 1024-byte trigger
//!    plus 8 conditions of 1024 bytes), over flood-sized, shell-sized and
//!    maximum-length lines.
//! 2. The real engine under a `yes` flood of ~1 KiB lines: how fast a pane
//!    consumes PTY output, and how much CPU the process burns, with no
//!    concepts, the default set, and the ceiling set.
//!
//!     cargo run --release -p gpty-core --example concept_probe
//!
//! Recorded on the v0.5.4 tree, before and after `ConceptMatcher` added its
//! combined `RegexSet` gate (median of a 5 s flood, ~1 KiB / 30 B lines):
//!
//! | pane flood                        | per-concept loop | gated matcher |
//! |-----------------------------------|------------------|---------------|
//! | 1 KiB lines, no concepts          | 79.9 MB/s        | 81.9 MB/s     |
//! | 1 KiB lines, default set          | 79.7 MB/s        | 81.1 MB/s     |
//! | 1 KiB lines, 128 typical triggers | 53.0 MB/s        | 73.9 MB/s     |
//! | 1 KiB lines, at the caps' ceiling | 5.8 MB/s         | 73.3 MB/s     |
//! | 30 B lines, 128 typical triggers  | 8.6 MB/s         | 44.9 MB/s     |
//! | 30 B lines, at the caps' ceiling  | 26.3 MB/s        | 52.5 MB/s     |
//!
//! Per line, the gate costs 2851 → 64 ns for 128 typical triggers on a 30-byte
//! line and 2.56 ms → 20 µs for the ceiling set on a maximum-length line; a
//! single-concept set pays ~0.1 µs more per line (17 → 19 ns on short lines)
//! for the combined pass. Compiling the gate takes 0.2 ms (default set),
//! 3.6 ms (128 typical triggers) and 27 ms (the ceiling set).
//!
//! Linux only (reads /proc for CPU time).

use std::time::{Duration, Instant};

use gpty_core::concept::{
    ConceptMatcher, MAX_CONCEPTS, MAX_CONDITIONS, MAX_TRIGGER_LEN, concepts_from_json,
};
use gpty_core::engine::WorkspaceEngine;
use gpty_core::parser::MAX_LINE_LEN;
use gpty_core::types::{Concept, TerminalConfig};

/// Us (system + user) this process has burned so far.
fn cpu_seconds() -> f64 {
    let Ok(stat) = std::fs::read_to_string("/proc/self/stat") else {
        return 0.0;
    };
    // Field 14 and 15 (1-based) are utime/stime in clock ticks, after the
    // parenthesised comm — which may itself contain spaces, so split there.
    let Some(rest) = stat.rsplit_once(')') else {
        return 0.0;
    };
    let fields: Vec<&str> = rest.1.split_whitespace().collect();
    let ticks: f64 = fields.get(11).and_then(|v| v.parse().ok()).unwrap_or(0.0)
        + fields.get(12).and_then(|v| v.parse().ok()).unwrap_or(0.0);
    ticks / 100.0
}

/// The shipped concept set, through the real parser.
fn shipped_defaults() -> Vec<Concept> {
    let raw = include_str!("../../../godot/concepts.default.json");
    let value: serde_json::Value =
        serde_json::from_str(raw).expect("shipped concepts are valid JSON");
    concepts_from_json(&value["concepts"].to_string())
}

/// A hand-authored library at the concept cap: 128 short, shape-typical
/// triggers.
fn user_library() -> Vec<Concept> {
    let items: Vec<serde_json::Value> = (0..MAX_CONCEPTS)
        .map(|i| {
            serde_json::json!({
                "name": format!("tool-{i}"),
                "trigger": format!(r"(?:^|[$#>]\s)\b(?:tool{i}|cmd{i})\s+\S"),
                "actions": [{"target": "code_viewer"}],
            })
        })
        .collect();
    concepts_from_json(&serde_json::Value::Array(items).to_string())
}

/// The ceiling the parser's caps allow: 128 concepts, each a trigger of
/// `MAX_TRIGGER_LEN` bytes and `MAX_CONDITIONS` conditions of the same size.
///
/// `shape` picks what the patterns are made of, because the regex engine's
/// prefilters decide the cost: an alternation of literals is found by
/// aho-corasick (fast), while a char-class repetition offers nothing to search
/// for and scans the whole line per regex (slow). Both are legal concepts.
fn ceiling_set(shape: &str) -> Vec<Concept> {
    fn pattern(shape: &str) -> String {
        let unit = match shape {
            "literals" => "(?:alfa|bravo|charlie|delta|echo|foxtrot|golf|hotel)",
            _ => "(?:[a-z0-9]{3}[-_])",
        };
        let repeats = (MAX_TRIGGER_LEN - "(?:)".len() - 4) / unit.len();
        format!(
            "(?:{}){{{repeats}}}",
            unit.trim_start_matches("(?:").trim_end_matches(')')
        )
    }

    let conditions: Vec<String> = (0..MAX_CONDITIONS).map(|_| pattern(shape)).collect();
    let items: Vec<serde_json::Value> = (0..MAX_CONCEPTS)
        .map(|i| {
            serde_json::json!({
                "name": format!("ceiling-{i}"),
                "trigger": pattern(shape),
                "conditions": conditions,
                "enabled": true,
                "actions": [{"target": "code_viewer"}],
            })
        })
        .collect();
    let parsed = concepts_from_json(&serde_json::Value::Array(items).to_string());
    assert_eq!(
        parsed.len(),
        MAX_CONCEPTS,
        "the ceiling set must parse — otherwise the caps are not what we measured"
    );
    assert_eq!(parsed[0].conditions.len(), MAX_CONDITIONS);
    parsed
}

/// Mean ns per `match_line` call, measured over a time budget rather than a
/// fixed count: the ceiling sets are orders of magnitude slower per call.
fn ns_per_line(concepts: &[Concept], line: &str) -> f64 {
    let budget = Duration::from_millis(300);
    let mut calls = 0u64;
    let start = Instant::now();
    while start.elapsed() < budget {
        for _ in 0..32 {
            std::hint::black_box(gpty_core::concept::match_line(concepts, line));
        }
        calls += 32;
    }
    start.elapsed().as_nanos() as f64 / calls as f64
}

/// The shipped entry point ([`ConceptMatcher`]) against the plain per-concept
/// loop: the matcher adds one combined `RegexSet` pass over the line, which
/// answers the common case (no trigger matches at all) without paying each
/// regex's own prologue. Only a hit runs the ordered loop, so the verdict is
/// identical either way — `concept::tests::matcher_agrees_with_match_line_on_
/// every_pair` pins that.
fn matcher_ns_per_line(matcher: &ConceptMatcher, line: &str) -> f64 {
    let budget = Duration::from_millis(300);
    let mut calls = 0u64;
    let start = Instant::now();
    while start.elapsed() < budget {
        for _ in 0..32 {
            std::hint::black_box(matcher.match_line(line));
        }
        calls += 32;
    }
    start.elapsed().as_nanos() as f64 / calls as f64
}

fn report_match_costs() {
    let sets: [(&str, Vec<Concept>); 4] = [
        ("default", shipped_defaults()),
        ("user-128", user_library()),
        ("ceiling-literals", ceiling_set("literals")),
        ("ceiling-noprefilter", ceiling_set("noprefilter")),
    ];
    let lines: [(&str, String); 4] = [
        ("flood 30 B", "y".repeat(30)),
        ("shell 200 B", "x".repeat(200)),
        ("log 1 KiB", "log line ".repeat(128)),
        ("max 16 KiB", "z".repeat(MAX_LINE_LEN)),
    ];

    println!("\n── matching cost (1 core, per line) ─────────────────────────────────────");
    println!(
        "{:<22} {:>12} {:>12} {:>12} {:>10}",
        "concept set", "line", "loop ns", "matcher ns", "speedup"
    );
    for (set_name, concepts) in &sets {
        let enabled = concepts.iter().filter(|c| c.enabled).count();
        let compile = Instant::now();
        let matcher = ConceptMatcher::new(concepts.clone());
        let compile_ms = compile.elapsed().as_secs_f64() * 1000.0;
        for (line_name, line) in &lines {
            let ns = ns_per_line(concepts, line);
            let shipped = matcher_ns_per_line(&matcher, line);
            println!(
                "{:<22} {:>12} {:>12.0} {:>12.0} {:>9.1}x",
                format!("{set_name} ({enabled})"),
                line_name,
                ns,
                shipped,
                ns / shipped
            );
        }
        println!("{:>22} matcher compiled in {compile_ms:.1} ms", "");
    }
}

/// Flood one pane for `seconds` and report how fast it consumed output and how
/// much CPU that cost. `line_len` sets the length of the repeated line.
async fn flood(label: &str, concepts: Vec<Concept>, line_len: usize, seconds: u64) {
    let word = "F".repeat(line_len);
    let command = format!("yes {word}");
    let engine = WorkspaceEngine::new(concepts);
    let spawned = engine
        .spawn_terminal_with_grid(
            TerminalConfig { id: 1 },
            "sh",
            &["-c", &command],
            &[],
            &[],
            24,
            80,
        )
        .await
        .expect("spawn");

    // Let the shell start before timing.
    tokio::time::sleep(Duration::from_millis(300)).await;
    let cpu_start = cpu_seconds();
    let start = Instant::now();
    let mut last_generation = spawned.grid.lock().map(|g| g.generation).unwrap_or(0);
    let mut last_sample = Instant::now();
    let mut samples: Vec<f64> = Vec::new();
    while start.elapsed() < Duration::from_secs(seconds) {
        tokio::time::sleep(Duration::from_millis(500)).await;
        let generation = spawned.grid.lock().map(|g| g.generation).unwrap_or(0);
        let dt = last_sample.elapsed().as_secs_f64();
        samples.push((generation - last_generation) as f64 * 4096.0 / dt / 1e6);
        last_generation = generation;
        last_sample = Instant::now();
    }
    let wall = start.elapsed().as_secs_f64();
    let cpu = cpu_seconds() - cpu_start;
    samples.sort_by(|a, b| a.partial_cmp(b).unwrap());
    println!(
        "{:<24} {:>10.1} MB/s  (median)  cpu {:>5.2} cores",
        label,
        samples[samples.len() / 2],
        cpu / wall
    );
    drop(engine);
}

#[tokio::main(flavor = "multi_thread")]
async fn main() {
    report_match_costs();

    let seconds: u64 = std::env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(6);
    println!("\n── pane flood, {seconds}s per run ───────────────────────────────────────");
    flood("1 KiB lines, no concepts", Vec::new(), 1024, seconds).await;
    flood(
        "1 KiB lines, default set",
        shipped_defaults(),
        1024,
        seconds,
    )
    .await;
    flood("1 KiB lines, user-128", user_library(), 1024, seconds).await;
    flood(
        "1 KiB lines, ceiling-noprefilter",
        ceiling_set("noprefilter"),
        1024,
        seconds,
    )
    .await;
    flood("30 B lines, no concepts", Vec::new(), 28, seconds).await;
    flood("30 B lines, user-128", user_library(), 28, seconds).await;
    flood(
        "30 B lines, ceiling-noprefilter",
        ceiling_set("noprefilter"),
        28,
        seconds,
    )
    .await;
}
