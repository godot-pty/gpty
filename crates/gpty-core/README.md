# gpty-core

Library crate for the gpty multi-PTY emulator. This is the engine — all terminal lifecycle, ANSI parsing, concept matching, capture buffering, and grid management live here.

## Module Layout

| Module | Purpose | Key Types |
|--------|---------|-----------|
| [`types`](src/types.rs) | Data vocabulary shared across all modules | `Concept`, `Action`, `TerminalConfig`, `CaptureMode`, `CapturedOutput`, `PaneType` |
| [`concept`](src/concept.rs) | Pure functions for trigger matching and capture routing | `match_line()` |
| [`agent_state`](src/agent_state.rs) | Tiered, display-only agent-state detection (events / OSC / heuristics) | `AgentState`, `StateTier`, `AgentStateTracker` |
| [`engine`](src/engine.rs) | Runtime orchestrator; spawns terminal tasks, capture state machine | `WorkspaceEngine`, `PtyTerminalHandle`, `SpawnedTerminal`, `TaskContext` |
| [`pty`](src/pty.rs) | Cross-platform PTY lifecycle via `portable-pty` | `PtyHandle` |
| [`parser`](src/parser.rs) | Strips ANSI escape sequences; extracts plain-text lines | `LineParser` |
| [`term`](src/term.rs) | Full terminal grid + damage tracking via `alacritty_terminal` | `TermGrid`, `CellInfo`, `GridUpdate` |
| [`color`](src/color.rs) | ANSI color mapping — named, indexed, true-color → RGB | `color_to_rgb()` |
| [`keymap`](src/keymap.rs) | Keyboard event → byte sequence translation | `key_event_to_bytes()` |
| [`history`](src/history.rs) | SQLite-backed scrollback history store and its write-behind thread | `HistoryStore`, `PaneHistory` |

## Concept System

Concepts capture terminal output and route it to a pane: a regular expression
trigger, a stop condition, and a target pane kind.

```rust
Concept {
    name: "cat_command",
    trigger_regex: Regex::new(r"(?:^|[$#>]\s)\bcat\s+\S").unwrap(),
    enabled: true,
    capture_mode: CaptureMode::UntilStop { stop_timeout_ms: 300, stop_on_input: true },
    destinations: vec![Action { target_label: "code_viewer".into() }],
}
```

How it works:
1. PTY output bytes stream through the `vte` parser
2. The parser strips ANSI escape sequences and extracts visible text lines
3. Each line is tested against every registered concept's `trigger_regex`
4. On an `UntilStop` match the terminal enters capture mode and buffers raw
   bytes; a `SingleLine` match is queued as a notice and stops here
5. The capture ends on timeout (silence for N ms) or user input
6. GDScript drains the completed capture and routes its text to the first pane
   whose type matches the action's `target_label` — with no receiver, the raw
   bytes are replayed into the grid

**Concepts never execute anything.** A concept definition is data: it starts a
capture and chooses which pane kind displays the result. It cannot write to a
PTY. That is deliberate — the trigger is a regex over terminal output, which is
untrusted, so a concept that could act would be an execution primitive driven by
whatever a program happens to print. `capture_mode` is `UntilStop` (capture and route) or `SingleLine`
(notify-only: the match is published on the event socket and nothing is
captured, routed, or shown); a missing or unknown value captures, and a legacy
`cmd` key in an action is ignored.

Key functions: `match_line()`, `finalize_capture()`, `handle_command()`, `feed_grid()`, `store_line()`.

### Use Cases

- Read the code you just catted: `cat README.md` in a shell pane opens the file in a code viewer pane.
- Error triage: route a compiler error block, a traceback, or a failing test log to the Inspector — gated behind its own opt-in (`accept_concept_captures`), because captured output leaves the terminal.
- Diff and log review: `git diff` / `git log` output lands in a viewer pane instead of eating scrollback.
- Documentation lookup: match a compiler error code and open the relevant snippet or link in an adjacent pane.

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
