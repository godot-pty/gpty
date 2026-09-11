# gpty-cli

CLI for controlling the gpty terminal workspace over JSON-RPC IPC. Connects to a running gpty GUI instance (auto-spawns one unless `--no-daemon` is passed). Pane types are validated client-side with "did you mean?" suggestions before any IPC round-trip.

## Getting it

Release bundles ship this CLI beside the GUI — `gpty-gui` on Linux and Windows, `gPTY.app` on macOS — and the CLI starts that GUI on demand, so a downloaded bundle needs no toolchain. From a source checkout, `cargo build -p gpty` (or `cargo build --workspace`) puts the binary in `target/debug/gpty`.

## Role in the Workspace

| Crate | Role | Depends On |
|-------|------|------------|
| `gpty-core` | Engine library (PTY, ANSI, grid, concepts) | — |
| `gpty-ipc` | IPC transport + protocol | `gpty-core` |
| `gpty-gdext` | Godot 4 GDExtension bridge + IPC server | `gpty-core`, `gpty-ipc` |
| **`gpty-cli`** | **CLI for workspace control** | `gpty-ipc` |

## Usage

```bash
# Open a new terminal pane
gpty new-pane --type terminal

# Open a new pane with a custom command and focus
gpty new-pane -t terminal -c "htop" -f

# List all active panes
gpty list-panes

# Close a pane
gpty kill-pane T1

# Focus a pane
gpty focus-pane T2

# Send text to a terminal pane
gpty inject T1 --text "ls -la"

# Read a pane's output (screen + scrollback)
gpty pane-read T1 --lines 200

# Pane status; no pane = every pane's status
gpty pane-status T1
gpty pane-status

# Run a command in a new pane
gpty pane-run --command "cargo test"

# Wait for output matching a regex (Rust syntax, up to 60 s)
gpty pane-wait T1 --pattern "tests passed" --timeout-ms 30000

# Inject into every pane carrying a tag
gpty new-pane --tags ci
gpty broadcast --tags ci --text "make test"

# Manage concept triggers
gpty concept list
gpty concept toggle cat_command

# Print the bundled agent skill (for coding agents inside a pane)
gpty --skill

# Output JSON Schema for AI tool integration
gpty schema
gpty schema --format mcp

# Run as MCP server over stdio
gpty mcp

# Manage the GUI daemon
gpty daemon start
gpty daemon status
gpty daemon stop

# Save, load, and list workspace layouts
gpty layout save mysetup
gpty layout load mysetup
gpty layout list

# Machine-readable JSON output
gpty list-panes --json

# Print version info
gpty version
```

## Subcommands

| Command | Description |
|---------|-------------|
| `new-pane` | Open a new pane (`-t, --pane-type` terminal/code_viewer/file_tree/inspector/reasoning, `-c, --command` command, `-s, --split` split, `-f, --focus` focus, `--tags` broadcast tags). `observer` is a deprecated alias for `inspector`. |
| `list-panes` | List all active panes with stable ids, labels, types, and positions |
| `kill-pane` | Close a pane by id or `"active"` |
| `focus-pane` | Focus a pane by id |
| `inject` | Send text to a terminal pane by id |
| `pane-read` | Read a pane's plain-text output (screen + scrollback, `--lines` 1–2000) |
| `pane-status` | Status primitives for a pane (`pid`, `running`, `exit_code`, `idle_ms`); no argument lists every pane |
| `pane-run` | Run a command in a new terminal pane (`--command`) |
| `pane-wait` | Wait for a pane's output to match a regex (`--pattern`, `--timeout-ms` 100–60000) |
| `broadcast` | Inject text into every pane carrying one of the given `--tags` |
| `concept` | List or toggle concept triggers (`list`, `toggle <name>`) |
| `schema` | Output JSON Schema describing all commands (`--format mcp` for MCP manifest) |
| `mcp` | Run as MCP server over stdio (for AI tool integration) |
| `daemon` | Manage the GUI: `start`, `stop`, `status` |
| `layout` | Layout management: `save <name>`, `load <name>`, `list` |
| `version` | Print version info |

## Global Flags

| Flag | Description |
|------|-------------|
| `--skill` | Print the bundled agent skill (SKILL.md) and exit |
| `--json` | Machine-readable JSON output |
| `--socket <path>` | Override IPC socket path |
| `--timeout <ms>` | Connection timeout in milliseconds (default 5000) |
| `--no-daemon` | Don't auto-spawn the GUI if not running |
| `-v`, `--verbose` | Verbose output to stderr |

## Key Dependencies

| Crate | Version | Role |
|-------|---------|------|
| `gpty-ipc` | path | IPC transport + client |
| `clap` | 4 | CLI argument parsing |
| `anyhow` | 1 | Error handling |
| `serde_json` | 1 | JSON output |
| `dirs` | 6 | Platform directories (GUI binary discovery) |
| `tokio` | 1 | Async runtime |
