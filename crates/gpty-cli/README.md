# gpty-cli

CLI for controlling the gpty terminal workspace over JSON-RPC IPC. Connects to a running gpty GUI instance (auto-spawns one unless `--no-daemon` is passed).

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
| `new-pane` | Open a new pane (`-t` type, `-c` command, `-s` split, `-f` focus) |
| `list-panes` | List all active panes with IDs, types, and positions |
| `kill-pane` | Close a pane by ID or `"active"` |
| `focus-pane` | Focus a pane by ID |
| `inject` | Send text to a terminal pane by ID |
| `schema` | Output JSON Schema describing all commands (`--format mcp` for MCP manifest) |
| `mcp` | Run as MCP server over stdio (for AI tool integration) |
| `daemon` | Manage the GUI: `start`, `stop`, `status` |
| `layout` | Layout management: `save <name>`, `load <name>`, `list` |
| `version` | Print version info |

## Global Flags

| Flag | Description |
|------|-------------|
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
