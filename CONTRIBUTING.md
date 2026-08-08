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

# CLI demos (no Godot needed)
cargo run --bin gpty              # mock pub-sub
cargo run --bin gpty -- --pty     # real PTY
cargo run --bin gpty -- --term    # alacritty_terminal grid

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
|`gpty-cli`|CLI binary: three demo modes (mock, `--pty`, `--term`)|
|`gpty-gdext`|GDExtension cdylib: `GptyTerminal` GodotClass bridging Rust ↔ GDScript|

## PR Process

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Ensure tests pass (add new tests as applicable)
5. Submit a pull request

### Commit Format

[Conventional Commits](https://www.conventionalcommits.org/): `feat(scope):`, `fix(scope):`, `chore(scope):`

Scopes: `settings`, `terminal`, `layout`, `sidebar`, `gdext`, `core`, `cli`

## Security

- **Concept Engine ReDoS**: Always use the standard Rust `regex` crate. PCRE or back-tracking engines are prohibited.
- **OSC 52 Clipboard**: Do not implement OSC 52 clipboard injection/syncing without placing it behind an explicit Godot confirmation dialog.

## License

Apache 2.0 (see `LICENSE`).
