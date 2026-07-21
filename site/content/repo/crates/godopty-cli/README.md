# godopty-cli

Headless CLI prototype — validates the godopty Rust engine without Godot.

## Usage

```bash
# Mock terminals — validates the pub-sub engine with synthetic output
cargo run --bin godopty-cli

# Real PTYs — validates the full PTY → vte → pub-sub pipeline
cargo run --bin godopty-cli -- --pty

# Terminal grid — validates alacritty_terminal ANSI processing + color grid
cargo run --bin godopty-cli -- --term

# Verbose logging
RUST_LOG=debug cargo run --bin godopty-cli
```

## Demo Descriptions

- Mock (`default`): 3 labelled terminals, 2 concepts (`crash_detected`, `port_conflict`). Verifies regex matching, broadcast routing, and label-gated action delivery — no PTY involved.
- PTY (`--pty`): Spawns 2 real bash sessions. Injects a trigger command into Terminal 1; verifies that Terminal 2 receives and executes the matching action.
- Term (`--term`): Feeds a crafted ANSI string (with SGR colors and formatting) into `alacritty_terminal::Term`. Prints the resulting grid with ANSI-colored output for visual verification.

## Concept Definitions

Concepts are built in `build_concepts()` in `main.rs`. They use the full `Concept` struct with `enabled`, `capture_mode`, and `destinations` fields.
