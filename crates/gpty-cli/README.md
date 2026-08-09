# gpty-cli

Headless CLI prototype that validates the gpty Rust engine in isolation — no Godot, no GUI. Every subsystem is exercised through three self-contained demo modes.

## Role in the Workspace

| Crate | Role | Depends On |
|-------|------|------------|
| `gpty-core` | Engine library (PTY, ANSI, grid, concepts) | — |
| `gpty-gdext` | Godot 4 GDExtension bridge | `gpty-core` |
| **`gpty-cli`** | **Headless integration tests** | `gpty-core` |

Unlike `gpty-gdext` which wraps the engine for Godot's renderer, the CLI exercises the engine directly — useful for rapid iteration, debugging regressions, and validating protocol-level behavior without launching Godot.

## Usage

```bash
# Mock terminals — validates the pub-sub engine with synthetic output
cargo run --bin gpty

# Real PTYs — validates the full PTY → vte → pub-sub pipeline
cargo run --bin gpty -- --pty

# Terminal grid — validates alacritty_terminal ANSI processing + color grid
cargo run --bin gpty -- --term

# Verbose logging
RUST_LOG=debug cargo run --bin gpty
```

## Demo Modes

### Mock (`default`)

Spawns 3 labelled terminals (`backend`, `frontend`, `observer`) with synthetic output on a timer. Verifies:

- Regex matching (`crash_detected`, `port_conflict`)
- Broadcast routing to the correct terminal by label
- Label-gated action delivery (wrong label → action ignored)
- Engine lifecycle (spawn, tick, shutdown)

No PTY involved — the engine is fed `Vec<u8>` directly.

### Real PTY (`--pty`)

Spawns 2 real bash sessions. Terminal 1 receives a trigger command; Terminal 2 receives and executes the matching action injected into its PTY stdin. Verifies:

- `portable-pty` cross-platform PTY spawn (`/dev/ptmx` on Linux)
- vte ANSI escape sequence parsing
- `LineParser` plain-text line extraction
- End-to-end concept routing through a live shell

### Terminal Grid (`--term`)

Feeds a crafted ANSI string (with SGR colors, bold, italic, underline) into `alacritty_terminal::Term`. Prints the resulting grid to stdout with ANSI color codes for visual verification of:

- SGR foreground/background color parsing
- Bold, italic, underline attribute flags
- Grid damage tracking (no-op on non-damaged cells)
- Cursor positioning and line wrapping

## Concept Definitions

Concepts are defined in `build_concepts()` and shared across all demo modes:

| Concept | Trigger (regex) | Mode | Destinations |
|---------|-----------------|------|-------------|
| `crash_detected` | `(?i)crash\|panic\|segfault\|SIGSEGV` | `SingleLine` | `backend` ← `echo '[Auto] Restart attempt triggered by crash'` |
| `port_conflict` | `(?i)address.*already.*in\s*use` | `SingleLine` | `observer` ← `echo '[Auto] Port conflict detected — consider lsof -i'` |

Both concepts use `CaptureMode::SingleLine` — each matching line broadcasts an `Event` on the pub-sub channel. The receiving terminal with the matching label injects the command template into its PTY stdin.

## Key Dependencies

| Crate | Version | Role |
|-------|---------|------|
| `gpty-core` | path | Engine library (all terminal logic) |
| `tokio` | 1 | Async runtime (multi-threaded) |
| `regex` | 1 | Concept trigger patterns |
| `env_logger` | 0.11 | Logging (RUST_LOG) |
| `log` | 0.4 | Log facade |
