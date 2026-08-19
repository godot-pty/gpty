# gpty-core

Library crate for the gpty multi-PTY emulator. This is the engine — all terminal lifecycle, ANSI parsing, concept matching, capture buffering, and grid management live here.

## Module Layout

| Module | Purpose | Key Types |
|--------|---------|-----------|
| [`types`](src/types.rs) | Data vocabulary shared across all modules | `Concept`, `Event`, `Action`, `TerminalConfig`, `CaptureMode`, `CapturedOutput`, `PaneType` |
| [`concept`](src/concept.rs) | Pure functions for regex matching and command routing | `match_and_broadcast()`, `matching_commands()` |
| [`engine`](src/engine.rs) | Runtime orchestrator; spawns terminal tasks, capture state machine | `WorkspaceEngine`, `PtyTerminalHandle`, `SpawnedTerminal`, `TaskContext` |
| [`pty`](src/pty.rs) | Cross-platform PTY lifecycle via `portable-pty` | `PtyHandle` |
| [`parser`](src/parser.rs) | Strips ANSI escape sequences; extracts plain-text lines | `LineParser` |
| [`term`](src/term.rs) | Full terminal grid + damage tracking via `alacritty_terminal` | `TermGrid`, `CellInfo`, `GridUpdate` |
| [`color`](src/color.rs) | ANSI color mapping — named, indexed, true-color → RGB | `color_to_rgb()` |
| [`keymap`](src/keymap.rs) | Keyboard event → byte sequence translation | `key_event_to_bytes()` |
| [`history`](src/history.rs) | SQLite-backed scrollback history store | `HistoryStore` |

## Concept System

Concepts are the core orchestration primitive: a regular expression trigger paired with labelled actions.

```rust
Concept {
    name: "port_conflict",
    trigger_regex: Regex::new(r"(?i)address.*already.*in\s*use").unwrap(),
    destinations: vec![Action {
        command_template: "echo '[Auto] Port conflict detected - consider lsof -i'",
        target_label: "inspector",
    }],
}
```

How it works:
1. PTY output bytes stream through the `vte` parser
2. The parser strips ANSI escape sequences and extracts visible text lines
3. Each line is tested against every registered concept's `trigger_regex`
4. On match, an `Event` is broadcast on the `tokio::sync::broadcast` channel
5. Every terminal task receives the event, checks its labels against each action's `target_label`
6. Matching terminals inject the `command_template` into their PTY's stdin

Self-reaction loops are prevented: a terminal ignores events where `source_pane == my_id`.

Security Warning: The Concept Engine is designed to execute commands automatically based on terminal output. Do not bind destructive or high-privilege actions (like `rm` or `sudo`) to easily spoofable regex triggers. An attacker could intentionally print matching text to trick your terminal into executing the action payload.

The engine supports two concept capture modes:

- `SingleLine`: Per-line regex matching. On match, broadcasts an `Event` on the pub-sub channel. Receiving terminals with matching labels inject the action's command template into their PTY stdin.
- `UntilStop { stop_timeout_ms, stop_on_input }`: Command-output capture. On match, the terminal enters capture mode — all subsequent PTY output is buffered as raw bytes (never fed to the grid). The capture ends on timeout (silence for N ms) or user input. The captured output is routed via GDScript to a receiver pane (e.g., code viewer) or flushed back to the terminal grid.

Key functions: `finalize_capture()`, `handle_command()`, `capture_stops_on_input()`, `feed_grid()`, `store_line()`.

### Use Cases

- Auto-Restarting Watchers: Detect a segmentation fault or panic string in a backend server pane, and automatically inject a restart command into an adjacent management pane.
- Port Conflict Resolution: Detect an "Address already in use" error and immediately run an `lsof` or `kill` command to clear the bound port.
- Inspector: Optionally route captured error blocks (a Python traceback or Rust compiler error) to a private, tool-free Inspector session. Shipped concepts that do this are disabled until the user opts in.
- Automated Documentation: Match specific compiler error codes and automatically open the relevant local or web documentation in an adjacent window.

## Why Flat?

All modules are single files in `src/`. When a module grows beyond ~200 lines or needs helper files, it will be promoted to `src/<name>/mod.rs`. This keeps navigation simple during prototyping while leaving room for future nesting.

## Key Dependencies

| Crate | Version | Role |
|-------|---------|------|
| `portable-pty` | 0.9 | Cross-platform PTY (Linux `/dev/ptmx`, Windows ConPTY) |
| `vte` | 0.15 | ANSI/VT100 escape sequence parser |
| `alacritty_terminal` | 0.26 | Full terminal grid emulator |
| `tokio` | 1.52 | Async runtime + broadcast channel |
| `regex` | 1.12 | Concept trigger patterns |
| `rusqlite` | 0.31 | SQLite history storage |
| `serde` | 1 | Serialization framework (derive support) |
| `serde_json` | 1 | JSON encoding for IPC + schema output |
