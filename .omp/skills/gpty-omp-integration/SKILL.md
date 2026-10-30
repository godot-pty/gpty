---
name: gpty-omp-integration
description: "Using gpty terminal workspace from Oh My Pi — spawn terminals, inject commands, manage panes via MCP"
---

# gpty OMP Integration

gpty is a multi-PTY terminal emulator with a tiling grid GUI. It exposes a full MCP server for AI agents to spawn, manage, and inject commands into terminal panes.

## Setup

1. Ensure `gpty` is in your PATH (build with `cargo build -p gpty-cli` or install from [releases](https://github.com/godot-pty/gpty/releases))
2. The MCP config is shipped as `mcp.json` in the gpty repo root — OMP discovers it automatically or place it at `.omp/mcp.json`

## Available Tools

| Tool | Description |
|---|---|
| `new-pane` | Spawn a new pane (terminal, code_viewer, file_tree, observer). Supports split direction, shell command, and title. |
| `list-panes` | List all active panes with IDs, types, and labels. |
| `kill-pane` | Close a pane by ID. Use `"active"` for the focused pane. |
| `focus-pane` | Focus a specific pane by ID. |
| `inject` | Send text to a terminal pane's PTY (trailing newline added). |
| `layout-save` | Save the current workspace layout with a name. |
| `layout-load` | Restore a saved workspace layout by name. |
| `layout-list` | List all saved layout names. |
| `daemon-start` | Start the gpty GUI daemon if not running. |
| `daemon-stop` | Stop the running gpty GUI. |
| `daemon-status` | Check if the GUI daemon is running. |
| `version` | Print gpty version info. |

## Usage Patterns

### Spawn a terminal and run a command

```json
{"method": "tools/call", "params": {"name": "new-pane", "arguments": {"pane_type": "terminal", "command": "cargo build", "split": "right"}}}
```

### Monitor a pane while working

```json
// List panes to find the target
{"method": "tools/call", "params": {"name": "list-panes", "arguments": {}}}

// Inject a command into pane T2
{"method": "tools/call", "params": {"name": "inject", "arguments": {"pane_id": "T2", "text": "echo hello"}}}
```

### Save/restore workspace layouts

```json
// Save the current layout
{"method": "tools/call", "params": {"name": "layout-save", "arguments": {"name": "debug-session"}}}

// Restore it later
{"method": "tools/call", "params": {"name": "layout-load", "arguments": {"name": "debug-session"}}}
```

### Lifecycle management

The CLI auto-spawns the GUI via daemon mode. If you need explicit control:

```bash
gpty daemon status   # check if GUI is running
gpty daemon start    # start the GUI
gpty daemon stop     # stop the GUI

### Multi-stream output — thinking vs. response

Spawn dedicated display panes running `cat`. The `inject` tool sends text as stdin — a `bash` shell would execute it, but `cat` just echoes:

```bash
# Create display panes
gpty new-pane -t terminal --title "Thinking" --command "cat" --split right
gpty new-pane -t terminal --title "Response" --command "cat" --split bottom

# Inject display text (appears in pane, NOT executed)
gpty inject T2 -t "Analyzing the codebase..."
gpty inject T3 -t "Here is the fix: change line 42..."
```

**Why `cat`?** `inject` writes to the pane's PTY stdin. A `bash` shell interprets it as a command. `cat` just prints it. Each `inject` call produces one newline-terminated line.

**Typical OMP session layout:**

| Pane | Shell | Purpose |
|---|---|---|
| T1 | `bash` | User interaction — NEVER inject into this |
| Thinking | `cat` | OMP's stream-of-consciousness reasoning |
| Response | `cat` | OMP's final deliverable text |

**Requires OMP harness support for multi-stream output** — the harness must route thinking text to one MCP tool (`inject` with thinking pane ID) and response text to another (`inject` with response pane ID). gpty provides the pipes; OMP decides where to point them.

## Pane Types

| Type | Description |
|---|---|
| `terminal` | PTY-backed shell session |
| `code_viewer` | Read-only CodeEdit display — receives concept captures |
| `file_tree` | Directory listing via DirAccess |
| `observer` | Display-only pane for monitoring output |

## Notes

- All `pane_id` values are labels like `T1`, `T2`, `C1`, etc. Use `"active"` for the currently focused pane.
- The `inject` tool appends a trailing newline automatically.
- The daemon auto-spawns the GUI when any tool is called if it's not already running (unless `--no-daemon`).
- Pane labels are stable — `T1` stays `T1` until killed.
