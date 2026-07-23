//! # godopty-cli
//!
//! CLI prototype. Runs without Godot to validate the Rust engine in isolation.
//!
//! ## Modes
//!
//! | Flag | Demo | Validates |
//! |------|------|-----------|
//! | _(none)_ | Mock terminals | Pub-sub engine with synthetic output |
//! | `--pty` | Real PTYs | End-to-end PTY+vte+pub-sub pipeline |
//! | `--term` | Terminal grid | alacritty_terminal grid rendering in the console |

use godopty_core::engine::WorkspaceEngine;
use godopty_core::term::TermGrid;
use godopty_core::types::{Action, CaptureMode, Concept, TerminalConfig};
use regex::Regex;

// ── Demo constants ─────────────────────────────────────────────────────

const MOCK_INTERVAL_MS: u64 = 2000;
const OBSERVER_INTERVAL_MS: u64 = 5000;
const STANDBY_INTERVAL_MS: u64 = 10000;
const BASH_INIT_DELAY_SECS: u64 = 1;
const DEMO_DURATION_SECS: u64 = 3;
const GRID_ROWS: usize = 5;
const GRID_COLS: usize = 40;

#[tokio::main]
async fn main() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
        .format_timestamp_millis()
        .init();

    let args: Vec<String> = std::env::args().collect();

    if args.iter().any(|a| a == "--term") {
        run_term_demo();
    } else if args.iter().any(|a| a == "--pty") {
        run_pty_demo().await;
    } else {
        run_mock_demo().await;
    }
}

// ── Mock demo ──────────────────────────────────────────────────────────

async fn run_mock_demo() {
    log::info!("=== godopty Phase 1: Mock Terminal Demo ===");

    let concepts = build_concepts();
    let engine = WorkspaceEngine::new(concepts);

    engine
        .spawn_mock_terminal(
            TerminalConfig {
                id: 1,
                labels: vec!["backend".into()],
            },
            vec![
                "INFO  server: listening on 0.0.0.0:8080".into(),
                "ERROR server: Address 8080 already in use".into(),
                "WARN  worker: connection reset by peer".into(),
                "thread 'main' panicked at src/main.rs:42".into(),
                "FATAL kernel: segfault at 0x0 ip 00007f...".into(),
            ],
            MOCK_INTERVAL_MS,
        )
        .await;

    engine
        .spawn_mock_terminal(
            TerminalConfig {
                id: 2,
                labels: vec!["observer".into()],
            },
            vec!["[observer] watching for events...".into()],
            OBSERVER_INTERVAL_MS,
        )
        .await;

    engine
        .spawn_mock_terminal(
            TerminalConfig {
                id: 3,
                labels: vec!["backend".into()],
            },
            vec!["[backend standby] waiting for restart signal...".into()],
            STANDBY_INTERVAL_MS,
        )
        .await;

    log::info!("Engine running. Press Ctrl+C to stop.");
    tokio::signal::ctrl_c()
        .await
        .expect("failed to install Ctrl+C handler");
    log::info!("Shutting down.");
}

// ── Real-PTY demo ──────────────────────────────────────────────────────

async fn run_pty_demo() {
    log::info!("=== godopty Phase 1: Real-PTY Demo ===");

    let concepts = build_concepts();
    let engine = WorkspaceEngine::new(concepts);

    let term1 = engine
        .spawn_pty_terminal(
            TerminalConfig {
                id: 1,
                labels: vec!["backend".into()],
            },
            "/bin/bash",
            &["--norc"],
            &[],
        )
        .await
        .expect("Failed to spawn PTY for Terminal 1");

    let _term2 = engine
        .spawn_pty_terminal(
            TerminalConfig {
                id: 2,
                labels: vec!["observer".into()],
            },
            "/bin/bash",
            &["--norc"],
            &[],
        )
        .await
        .expect("Failed to spawn PTY for Terminal 2");

    log::info!("PTYs spawned. Waiting for bash to initialize...");
    tokio::time::sleep(tokio::time::Duration::from_secs(BASH_INIT_DELAY_SECS)).await;

    // Inject a command that triggers the port_conflict concept.
    // The chain: bash executes echo → vte parses output →
    // regex matches → Terminal 2 (observer) receives injected command.
    log::info!(">>> Injecting: echo 'ERROR: Address 8080 already in use'");
    term1.send_line("echo 'ERROR: Address 8080 already in use'");

    tokio::time::sleep(tokio::time::Duration::from_secs(DEMO_DURATION_SECS)).await;
    log::info!("Demo complete. Shutting down.");
}

// ── Terminal grid demo (Phase 2a) ──────────────────────────────────────

/// Validates that `alacritty_terminal` processes ANSI escape sequences and
/// produces a correct character grid with color attributes.
///
/// Feeds a known ANSI string into `TermGrid`, then prints the resulting
/// grid to stdout with ANSI color codes so the user can visually verify
/// correctness.
fn run_term_demo() {
    println!("=== godopty Phase 2a: Terminal Grid Demo ===\n");

    let mut grid = TermGrid::new(GRID_ROWS, GRID_COLS);

    // Feed a string with SGR formatting:
    // - "Normal " in default colors
    // - "RED" in bright red on default bg
    // - " back to normal" in default
    // - "BOLD" in bright green
    // - newline to commit the row
    let input = b"Normal \x1b[91mRED\x1b[0m back to normal\x1b[92mBOLD\x1b[0m\r\n";
    grid.feed(input);

    // Feed a second row with background colors
    let input2 = b"\x1b[44m\x1b[97m  Blue bg, white fg  \x1b[0m\r\n";
    grid.feed(input2);

    // Feed more text to show cursor advancement
    let input3 = b"Row 3: just plain text.\r\n";
    grid.feed(input3);

    let rows = grid.renderable_rows();
    println!("Grid: {} rows × {} cols\n", rows.len(), grid.num_cols());

    for (i, row) in rows.iter().enumerate() {
        // First pass: print the characters
        print!("Row {i}: ");
        for cell in row {
            print!("{}", cell.ch);
        }
        println!();

        // Second pass: print ANSI-colored version for visual verification
        print!("      ");
        for cell in row {
            // Use true-color ANSI escape to render the cell's colors
            let [fr, fg, fb] = cell.fg;
            let [br, bg, bb] = cell.bg;
            print!(
                "\x1b[38;2;{fr};{fg};{fb}m\x1b[48;2;{br};{bg};{bb}m{}",
                cell.ch
            );
        }
        println!("\x1b[0m");
    }

    println!("\nGrid demo complete. Verify:");
    println!("  - Row 0: 'RED' should be in red");
    println!("  - Row 0: 'BOLD' should be in green");
    println!("  - Row 1: blue background with white text");
    println!("  - Row 2: plain default-colored text");
}

// ── Shared concept registry ────────────────────────────────────────────

/// Build the concept registry used by all demo modes.
/// Currently registers "crash_detected" and "port_conflict" triggers.
fn build_concepts() -> Vec<Concept> {
    vec![
        Concept {
            name: "crash_detected".into(),
            trigger_regex: Regex::new(r"(?i)crash|panic|segfault|SIGSEGV")
                .expect("invalid crash_detected regex"),
            enabled: true,
            capture_mode: CaptureMode::SingleLine,
            destinations: vec![Action {
                command_template: "echo '[Auto] Restart attempt triggered by crash'".into(),
                target_label: "backend".into(),
            }],
        },
        Concept {
            name: "port_conflict".into(),
            trigger_regex: Regex::new(r"(?i)address.*already.*in\s*use")
                .expect("invalid port_conflict regex"),
            enabled: true,
            capture_mode: CaptureMode::SingleLine,
            destinations: vec![Action {
                command_template: "echo '[Auto] Port conflict detected — consider lsof -i'".into(),
                target_label: "observer".into(),
            }],
        },
    ]
}
