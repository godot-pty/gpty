# godopty-cli

Control the godopty terminal workspace from the command line over JSON-RPC IPC.

## Role in the Workspace

| Crate | Role | Depends On |
|-------|------|------------|
| `godopty-core` | Engine library (PTY, ANSI, grid, concepts) | — |
| `godopty-ipc` | IPC transport + protocol (JSON-RPC 2.0) | `godopty-core` |
| `godopty-gdext` | Godot 4 GDExtension bridge + IPC server | `godopty-core`, `godopty-ipc` |
| **`godopty-cli`** | **CLI client for workspace control** | `godopty-ipc` |

## Usage

```bash
# Open a new terminal pane
godopty new-pane --type terminal

# Open a code viewer with a command
godopty new-pane --type code_viewer --split right

# List all panes (human-readable table)
godopty list-panes
godopty list-panes --json          # machine-readable

# Send text to a terminal
godopty inject T1 --text "echo hello"

# Focus a specific pane
godopty focus-pane T2

# Close a pane
godopty kill-pane T1
godopty kill-pane active           # close the focused pane

# Save/load workspace layouts
godopty layout save my-layout
godopty layout load my-layout
godopty layout list

# Daemon management
godopty daemon status              # is the GUI running?
godopty daemon stop                # quit the GUI
godopty --no-daemon new-pane       # don't auto-spawn GUI

# Schema for AI tool integration
godopty schema                     # JSON Schema (draft 2020-12)
godopty schema --format mcp        # MCP tools manifest

# Run as MCP server over stdio
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | godopty mcp

# Print version
godopty version
```

## How it works

1. `godopty` connects to the GUI's IPC socket (`/tmp/godopty.sock` on Linux).
2. If the GUI isn't running, `godopty` auto-spawns it (unless `--no-daemon`).
3. Commands are serialized as JSON-RPC 2.0 requests and sent over the socket.
4. The GUI's IPC server dispatches to workspace methods and returns JSON responses.
5. `--json` flag prints raw JSON; otherwise output is human-formatted.

## Key Dependencies

| Crate | Version | Role |
|-------|---------|------|
| `godopty-ipc` | path | IPC client (JSON-RPC over Unix socket) |
| `clap` | 4 | CLI argument parsing |
| `serde_json` | 1 | JSON serialization |
| `tokio` | 1 | Async runtime |
| `anyhow` | 1 | Error handling |
| `dirs` | 5 | Platform directory paths |
| `env_logger` | 0.11 | Logging (RUST_LOG) |
| `log` | 0.4 | Log facade |
