# Contributing

## Prerequisites

- Rust >= 1.85 (tested with 1.96)
- Godot 4.4+ (tested with 4.7) with GDExtension support
- Linux (primary target), macOS (untested) or Windows 11 (untested).

## Setup

### Clone the repository

```bash
# Clone
git clone https://github.com/godot-pty/gpty.git gpty
cd gpty
```

### Install `git` hooks (one-time per clone)

```bash
./scripts/install-hooks
```

This installs:

- `pre-commit` (fast checks: `fmt`, `lint`, `clippy`)
- `commit-msg` (Conventional Commits enforcement)
- `pre-push` (full CI suite).

Run `./scripts/ci-check` directly to validate changes before committing.

### Build

One-shot standalone build (detects the host platform, builds gpty-gdext in release mode, and exports the app into `dist/`):

```bash
./scripts/build
```

Requires Godot on PATH with export templates installed for its version.
The manual steps below are what the script does internally.


```bash
# Build the GDExtension library (required before running Godot)
cargo build -p gpty-gdext
# Copy to the Godot project for local development
cp target/debug/libgpty_gdext.so godot/bin/libgpty_gdext.linux.x86_64.so

# Release build + local export
cargo build -p gpty-gdext --release
cp target/release/libgpty_gdext.so godot/bin/libgpty_gdext.linux.x86_64.so

godot --headless --path godot --import
godot --headless --path godot --export-release "Linux/X11" ../dist/gpty
```

### Clean

Remove build/test artifacts for a clean slate — stale IPC sockets, Godot import caches, and standalone `dist/` outputs:

```bash
./scripts/clean             # default: transient artifacts
./scripts/clean --dry-run   # list what would be removed
./scripts/clean --all       # also remove target/ and built gdext libraries
```

Sockets with a live listener (a running GUI or an in-flight test run) are never touched, and user data (`user://` settings, profiles, layouts, history.db) is preserved. Tracked files such as `dist/aur/` and `godot/.gutconfig.json` are left alone.


### MCP

Generate the current tools manifest: `cargo run --bin gpty -- schema --format mcp`

### Run

```bash
# Open in Godot editor
cd godot && godot -e

# Launch the GUI (backgrounded; add --headless for headless)
godot --path godot &
```

The GUI starts an IPC server on `$XDG_RUNTIME_DIR/gpty.sock` (or `GPTY_SOCKET` env var if set).
Once running, control it with the CLI:

```bash
cargo run --bin gpty -- version
cargo run --bin gpty -- new-pane -t terminal
cargo run --bin gpty -- list-panes
cargo run --bin gpty -- inject T1 -t "echo hello"
cargo run --bin gpty -- daemon stop
```

Standalone commands (no GUI needed):

```bash
cargo run --bin gpty -- schema                    # JSON Schema
cargo run --bin gpty -- schema --format mcp       # MCP tools manifest
echo '{"jsonrpc":"2.0","id":1,"method":"initialize"}' | cargo run --bin gpty -- mcp
```

### Test

- **Automated**: `./scripts/ci-check` runs the full suite (Rust + GUT + audit). CI runs on every push to `main` and every PR.
- **Manual pre-release**: [docs/content/docs/testing.md](docs/content/docs/testing.md) — smoke tests for CLI bridge, daemon lifecycle, UI shortcuts, and error paths that require a running GUI.
- Test format: `Given / When / Then` with expected output. See the manual checklist for examples.

```bash
# Rust tests only
cargo test --workspace    # Tests across core, gdext, cli
cargo test -p gpty-core   # Core library only

# Rust type-check (fast, no codegen)
cargo check

# Godot (GUT) tests only
godot --headless --path godot --import # Required before first run
godot --headless --path godot -s addons/gut/gut_cmdln.gd -d -gdir=res://tests/unit -gdir=res://tests/integration

# Run all CI checks locally (fmt, clippy, tests, GUT, audit)
./scripts/ci-check

# Fast checks only (fmt, clippy)
./scripts/ci-check --fast
```

### CLI (control a running GUI)

```bash
cargo run --bin gpty -- new-pane --pane-type terminal  # Create a new terminal pane
cargo run --bin gpty -- list-panes                     # List active panes
cargo run --bin gpty -- schema                         # JSON Schema for AI tools
cargo run --bin gpty -- schema --format mcp            # MCP tools manifest
```

Verbose logging: `RUST_LOG=debug cargo run --bin gpty -- version`

## Project Structure

See [AGENTS.md](AGENTS.md) for the full directory tree.

## Code Style

See [AGENTS.md](AGENTS.md) for the complete GDScript and Rust conventions, pitfalls, and patterns.

## Pull Request Process

1. Fork the repository.
2. Create your feature branch.
3. Make your changes.
4. Test your changes (functionally).
5. Run `./scripts/ci-check` — ensure all checks pass
6. Add or update test cases as applicable.
7. See [AGENTS.md](AGENTS.md) for commit information.
8. Submit a pull request.

## Security

See [AGENTS.md](AGENTS.md) for full security rules, including Concept Engine ReDoS prevention and OSC 52 clipboard restrictions.

## License

Apache 2.0 (see [LICENSE](LICENSE)).
