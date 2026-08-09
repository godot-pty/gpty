# Contributing

## Setup

- **Rust**: Edition 2024, requires Rust ≥ 1.85
- **Godot**: 4.7 with GDExtension support
- **Build**: `cargo build -p gpty-gdext`

```bash
# Build the GDExtension shared library
cargo build -p gpty-gdext

# Run all Rust unit tests
cargo test -p gpty-core

# Type-check Rust only (fast)
cargo check

# CLI (control running gpty GUI over IPC)
cargo run --bin gpty -- new-pane --type terminal
cargo run --bin gpty -- list-panes
cargo run --bin gpty -- schema          # JSON Schema for AI tools
cargo run --bin gpty -- schema --format mcp  # MCP tools manifest

# Open in Godot editor (after building gdext)
cd godot && godot -e
```

## Code Style

### GDScript

- **Indentation**: tabs
- **Private members**: underscore prefix (`_cell_w`, `_settings_panel`)
- **Config vars**: `_cfg_` prefix (`_cfg_cursor_shape`)
- **Export pattern**: `@export var` for Inspector-settable properties

### Rust

- **Edition**: 2024
- **Format**: standard `rustfmt`
- **Async runtime**: `tokio`
- **Thread safety**: Never call Godot methods from background threads. Queue state changes for GDScript to poll, or use `call_deferred()`.

## Project Structure

|Crate|Role|
|---|---|
|`gpty-core`|Library: PTY spawning, ANSI parsing, alacritty_terminal grid, concept/pub-sub engine|
|`gpty-ipc`|JSON-RPC 2.0 IPC transport, client, and server for workspace control|
|`gpty-cli`|CLI binary: workspace control over JSON-RPC IPC|
|`gpty-gdext`|GDExtension cdylib: `GptyTerminal` GodotClass bridging Rust ↔ GDScript|

## PR Process

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Ensure tests pass (add new tests as applicable)
5. Submit a pull request

## Testing

- **Automated**: `cargo test --workspace` (Rust) + `godot --headless --path godot -s addons/gut/gut_cmdln.gd ...` (GDScript). CI runs on every push.
- **Manual pre-release**: [docs/content/docs/testing.md](docs/content/docs/testing.md) — smoke tests for CLI bridge, daemon lifecycle, UI shortcuts, and error paths that require a running GUI.
- Test format: `Given / When / Then` with expected output. See the manual checklist for examples.

### Commit Format

[Conventional Commits](https://www.conventionalcommits.org/): `feat(scope):`, `fix(scope):`, `chore(scope):`

Scopes: `settings`, `terminal`, `layout`, `sidebar`, `gdext`, `core`, `cli`, `ipc`

## Security

- **Concept Engine ReDoS**: Always use the standard Rust `regex` crate. PCRE or back-tracking engines are prohibited.
- **OSC 52 Clipboard**: Do not implement OSC 52 clipboard injection/syncing without placing it behind an explicit Godot confirmation dialog.

## License

Apache 2.0 (see `LICENSE`).
