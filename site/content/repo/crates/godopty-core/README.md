# godopty-core

Library crate for the godopty multi-PTY emulator. This is the engine — all terminal lifecycle, ANSI parsing, concept matching, capture buffering, and grid management live here.

## Module Layout

| Module | Purpose | Key Types |
|--------|---------|-----------|
| [`types`](src/types.rs) | Data vocabulary shared across all modules | `Concept`, `Event`, `Action`, `TerminalConfig`, `CaptureMode`, `CapturedOutput` |
| [`concept`](src/concept.rs) | Pure functions for regex matching and command routing | `match_and_broadcast()`, `matching_commands()` |
| [`engine`](src/engine.rs) | Runtime orchestrator; spawns terminal tasks, capture state machine | `WorkspaceEngine`, `PtyTerminalHandle`, `SpawnedTerminal`, `TaskContext` |
| [`pty`](src/pty.rs) | Cross-platform PTY lifecycle via `portable-pty` | `PtyHandle` |
| [`parser`](src/parser.rs) | Strips ANSI escape sequences; extracts plain-text lines | `LineParser` |
| [`term`](src/term.rs) | Full terminal grid + damage tracking via `alacritty_terminal` | `TermGrid`, `CellInfo`, `GridUpdate` |
| [`color`](src/color.rs) | ANSI color mapping — named, indexed, true-color → RGB | `color_to_rgb()` |
| [`keymap`](src/keymap.rs) | Keyboard event → byte sequence translation | `key_event_to_bytes()` |
| [`history`](src/history.rs) | SQLite-backed scrollback history store | `HistoryStore` |

## Concept Capture System

The engine supports two capture modes:

- `SingleLine`: Per-line regex matching. On match, broadcasts an `Event` on the pub-sub channel. Receiving terminals with matching labels inject the action's command template into their PTY stdin.
- `UntilStop { stop_timeout_ms, stop_on_input }`: Command-output capture. On match, the terminal enters capture mode — all subsequent PTY output is buffered as raw bytes (never fed to the grid). The capture ends on timeout (silence for N ms) or user input. The captured output is routed via GDScript to a receiver pane (e.g., code viewer) or flushed back to the terminal grid.

Key functions: `finalize_capture()`, `handle_command()`, `capture_stops_on_input()`, `feed_grid()`, `store_line()`.

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
