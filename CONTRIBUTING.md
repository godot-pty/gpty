# Contributing

## Setup

**Prerequisites**: Rust >= 1.85 (tested with 1.96), Godot 4.4+ (tested with 4.7) with GDExtension support, Linux (primary target) or Windows 11.

```bash
# Clone
git clone https://github.com/godot-pty/gpty.git gpty
cd gpty
```

### Install git hooks (one-time per clone)

```bash
./scripts/install-hooks
```

This installs pre-commit (fast checks: fmt, lint, clippy), commit-msg (Conventional Commits enforcement), and pre-push (full CI suite). Run `./scripts/ci-check` directly to validate changes before committing.

### Build and test

```bash
# Build the GDExtension library (required before running Godot)
cargo build -p gpty-gdext
cp target/debug/libgpty_gdext.so godot/bin/libgpty_gdext.linux.x86_64.so

# Run all CI checks locally (fmt, clippy, tests, GUT, audit)
./scripts/ci-check

# Fast checks only (fmt, clippy)
./scripts/ci-check --fast

# Rust tests only
cargo test --workspace

# Rust type-check (fast, no codegen)
cargo check

# Godot (GUT) tests only
godot --headless --path godot --import
godot --headless --path godot -s addons/gut/gut_cmdln.gd -d -gdir=res://tests/unit -gdir=res://tests/integration

# Release build + local export
cargo build -p gpty-gdext --release
cp target/release/libgpty_gdext.so godot/bin/libgpty_gdext.linux.x86_64.so
godot --headless --path godot --export-release "Linux/X11" dist/gpty

# Open in Godot editor
cd godot && godot -e
```

### CLI (control a running GUI)

```bash
cargo run --bin gpty -- new-pane --pane-type terminal
cargo run --bin gpty -- list-panes
cargo run --bin gpty -- schema          # JSON Schema for AI tools
cargo run --bin gpty -- schema --format mcp  # MCP tools manifest
```

Verbose logging: `RUST_LOG=debug cargo run --bin gpty -- version`

## Project Structure

| Crate | Role |
|---|---|
| `gpty-core` | Library: PTY spawning, ANSI parsing, alacritty_terminal grid, concept/pub-sub engine |
| `gpty-ipc` | JSON-RPC 2.0 IPC transport, client, and server for workspace control |
| `gpty-cli` | CLI binary: workspace control over JSON-RPC IPC |
| `gpty-gdext` | GDExtension cdylib: `GptyTerminal` GodotClass bridging Rust ↔ GDScript |

See [AGENTS.md](AGENTS.md) for the full directory tree, module-level documentation, and detailed coding conventions.

## Code Style

See [AGENTS.md](AGENTS.md) for the complete GDScript and Rust conventions, pitfalls, and patterns. Key highlights:

- **GDScript**: tabs, `_` prefix for private members, `_cfg_` prefix for config vars
- **Rust**: edition 2024, `rustfmt`, `tokio` async runtime, never call Godot from background threads

## Pull Request Process

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run `./scripts/ci-check` — ensure all checks pass
5. Add or update tests as applicable
6. Submit a pull request

## Commit Format

[Conventional Commits](https://www.conventionalcommits.org/): `type(scope): description`

Types: `feat`, `fix`, `refactor`, `chore`, `docs`, `test`, `style`, `ci`

Scopes: `settings`, `terminal`, `layout`, `sidebar`, `gdext`, `core`, `cli`, `ipc`, `profiles`, `concepts`, `icons`, `ci`

Use the commit skill (`skill://commit`) for the recommended workflow. The commit-msg hook enforces this format automatically.

## Testing

- **Automated**: `./scripts/ci-check` runs the full suite (Rust + GUT + audit). CI runs on every push to `main` and every PR.
- **Manual pre-release**: [docs/content/docs/testing.md](docs/content/docs/testing.md) — smoke tests for CLI bridge, daemon lifecycle, UI shortcuts, and error paths that require a running GUI.
- Test format: `Given / When / Then` with expected output. See the manual checklist for examples.

## Security

See [AGENTS.md](AGENTS.md) for the full security rules, including Concept Engine ReDoS prevention and OSC 52 clipboard restrictions.

## License

Apache 2.0 (see [LICENSE](LICENSE)).
