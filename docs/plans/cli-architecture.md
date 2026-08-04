# godopty CLI Architecture

## 1. North Star

A single `godopty` binary that:

1. **Controls the Godot GUI** — opens/splits/closes panes, queries layout state, injects commands into terminals
2. **Is AI-tool-native** — exposes its capabilities as JSON Schema, always accepts `--json` for machine-readable output
3. **Is self-documenting** — `--help` at every level, "did you mean?" suggestions on typos, `godopty schema` outputs a complete JSON Schema
4. **Works from anywhere** — if the GUI isn't running, it spawns it; if the env var isn't set, it finds the socket at a well-known path

## 2. Architecture

### 2.1 Process Model

```
┌──────────────────────────────────────────────────────────┐
│  godopty (Godot GUI)                                     │
│  ┌──────────────────────┐  ┌──────────────────────────┐  │
│  │  GDScript workspace  │  │  GDExtension (Rust)      │  │
│  │                      │◄─┤  - WorkspaceEngine        │  │
│  │  - TerminalManager   │  │  - GodoptyTerminal nodes  │  │
│  │  - Sidebar           │  │  - tokio runtime          │  │
│  └────────┬─────────────┘  │  - IPC server (UNIX/TCP)  │  │
│           │                └──────────┬───────────────┘  │
│           │                           │                   │
│           │  GDScript → Rust FFI      │  IPC socket       │
│           │  (existing, unchanged)    │  /tmp/godopty.sock│
│           │                           │                   │
└───────────┼───────────────────────────┼───────────────────┘
            │                           │
            │                           ▼
            │               ┌───────────────────────┐
            │               │  godopty CLI binary   │
            │               │  (same Rust workspace)│
            │               │                       │
            │               │  godopty new-pane     │
            │               │  godopty list-panes   │
            │               │  godopty schema       │
            │               │  godopty daemon       │
            │               └───────────────────────┘
            │
            ▼
   Godot rendering pipeline
   (Control-based _draw, existing)
```

The GUI owns the **single source of truth** for pane state. The CLI is a **stateless client** that sends commands over IPC. No state duplication, no two-headed ownership.

### 2.2 IPC Transport

| Platform | Transport | Default Path |
|----------|-----------|-------------|
| Linux    | Unix domain socket | `/tmp/godopty.sock` |
| macOS    | Unix domain socket | `$TMPDIR/godopty.sock` |
| Windows  | Named pipe | `\\.\pipe\godopty` |

The GUI binds the socket at startup. The CLI connects, sends a JSON-RPC 2.0 request, reads the response, and exits. No persistent connection needed — stateless request/response is simpler and avoids connection management bugs.

**Fallback discovery**: `GODOPTY_SOCKET` env var overrides the default path. The GUI sets this for child PTY sessions it spawns, so shells launched *inside* GodoPTY always find the socket.

### 2.3 JSON-RPC 2.0 Protocol

Every CLI command maps to a JSON-RPC method. The protocol is versioned — `godopty.listPanes` etc.

**Request** (CLI → GUI):
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "newPane",
  "params": {
    "type": "observer",
    "command": "tail -f /var/log/syslog",
    "split": "bottom",
    "title": "Syslog"
  }
}
```

**Success response** (GUI → CLI):
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "pane_id": "O3",
    "type": "observer",
    "title": "Syslog"
  }
}
```

**Error response**:
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "error": {
    "code": -32001,
    "message": "Grid is full — cannot split further",
    "data": {
      "suggestion": "Close a pane first with 'godopty kill-pane <id>'",
      "current_panes": 4,
      "max_panes": 16
    }
  }
}
```

### 2.4 Daemon Mode

When the CLI can't connect to the socket, it checks whether the Godot GUI binary exists at a known path. If it does, it spawns it as a detached child process, then polls the socket until ready (with a timeout). This is the "just works" guarantee for AI tools.

```
CLI start
  │
  ├─ Socket found & responsive? ──▶ Send command, print result, exit 0
  │
  └─ Socket not found:
       │
       ├─ GUI binary exists? ──▶ spawn GUI, poll socket, send command, exit
       │
       └─ No binary ──▶ Print error: "godopty GUI not running and binary not found at /usr/bin/godopty-gui. Start the GUI first or set GODOPTY_SOCKET."
                        Exit 1
```

**Important constraint**: The CLI does NOT link against Godot or Godot libraries. It spawns the GUI as a separate OS process. The daemon binary path is discovered via:

1. `GODOPTY_GUI` env var (explicit override)
2. Same directory as the CLI binary (`godopty-gui` / `godopty-gui.exe`)
3. `$PATH` lookup

This keeps the CLI binary small (< 10 MB) and avoids pulling Godot's ~80 MB runtime into every tool invocation.

## 3. CLI Design

### 3.1 Subcommand Tree

```
godopty
├── new-pane       Open a new pane in the current workspace
│   --type, -t     Pane type: terminal, code-viewer, file-tree, observer
│   --command, -c  Initial command (terminal/observer only)
│   --split, -s    Split direction: left, right, top, bottom
│   --title        Display title (defaults to command or type name)
│   --focus, -f    Grab keyboard focus after creation (default: true)
│
├── list-panes     List all active panes
│   --json         Machine-readable output
│
├── kill-pane      Close a pane
│   <pane-id>      Pane label (e.g., T1, O3, C2) or "active" for focused
│
├── focus-pane     Focus a specific pane
│   <pane-id>
│
├── inject         Send text/command to a terminal pane
│   <pane-id>
│   --text, -t     Text to inject (appended with newline for commands)
│
├── schema         Output JSON Schema describing all commands and params
│   --format       Output format: json-schema (default), openapi, mcp
│
├── daemon         Manage the GUI daemon
│   start          Start GUI if not running
│   stop           Stop GUI gracefully
│   status         Is the GUI running? (exit code 0/1)
│
├── layout         Workspace layout management
│   save <name>    Save current layout as a named profile
│   load <name>    Load a saved layout
│   list           List saved layouts (--json)
│
└── version        Print version and build info
    --json
```

### 3.2 Flags

Every subcommand inherits these global flags:

| Flag | Effect |
|------|--------|
| `--json` | All output is JSON. Errors are JSON too (attempt to parse stderr). |
| `--socket <path>` | Override IPC socket path |
| `--timeout <ms>` | Max wait for socket connection (default: 5000) |
| `--no-daemon` | Don't spawn GUI if not running; fail immediately |
| `--verbose, -v` | Print connection/daemon lifecycle to stderr |

### 3.3 `--json` Contract

When `--json` is present, stdout is a single JSON object or array. stderr is suppressed unless the IPC itself fails (connection refused, timeout) — in which case stderr gets a JSON error object with `"jsonrpc":"2.0","error":{...}`.

**Human output** (no `--json`):
```
$ godopty list-panes
T1  Terminal    bash          col:0 row:0  12x6
O2  Observer    tail -f log   col:6 row:0  6x6
C3  Code Viewer README.md     col:0 row:6  12x6
```

**JSON output** (`--json`):
```json
{
  "panes": [
    {"id": "T1", "type": "terminal", "title": "bash", "command": "/bin/bash", "col": 0, "row": 0, "cspan": 12, "rspan": 6, "focused": true},
    {"id": "O2", "type": "observer", "title": "tail -f log", "command": "tail -f /var/log/app.log", "col": 6, "row": 0, "cspan": 6, "rspan": 6, "focused": false},
    {"id": "C3", "type": "code_viewer", "title": "README.md", "file": "README.md", "col": 0, "row": 6, "cspan": 12, "rspan": 6, "focused": false}
  ],
  "count": 3
}
```

### 3.4 Schema Auto-Generation

`godopty schema` walks the `clap` `Command` tree and generates a JSON Schema:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "godopty CLI",
  "description": "Control the godopty terminal workspace",
  "type": "object",
  "properties": {
    "subcommand": {
      "enum": ["new-pane", "list-panes", "kill-pane", "focus-pane", "inject", "schema", "daemon", "layout", "version"]
    }
  },
  "oneOf": [
    {
      "if": {"properties": {"subcommand": {"const": "new-pane"}}},
      "then": {
        "properties": {
          "type": {"enum": ["terminal", "code-viewer", "file-tree", "observer"], "description": "Pane type"},
          "command": {"type": "string", "description": "Initial command"},
          "split": {"enum": ["left", "right", "top", "bottom"], "default": "bottom"},
          "title": {"type": "string"},
          "focus": {"type": "boolean", "default": true}
        },
        "required": ["type"]
      }
    }
    // ... oneOf branch per subcommand
  ]
}
```

This is the machine-readable contract AI tools consume. They run `godopty schema` once at startup and cache the result.

### 3.5 Error Hints (Did You Mean?)

Clap's built-in suggestions are good but only work for flag names. We add suggestion logic for pane IDs and type names:

```
$ godopty new-pane --type obsever
error: invalid value 'obsever' for '--type <TYPE>'
  Did you mean 'observer'?

  Valid types: terminal, code-viewer, file-tree, observer
```

```
$ godopty kill-pane T5
error: no pane with id 'T5'
  Active panes: T1, O2, C3
  Did you mean 'T1'?
```

These run on the CLI side (not requiring an IPC round-trip for type validation). Pane ID validation requires `list-panes` state, which can be cached briefly or validated server-side.

## 4. MCP (Model Context Protocol) Integration

### 4.1 MCP Server

The `godopty` binary itself acts as an MCP server via stdio transport. When invoked as `godopty mcp`, it:

1. Reads JSON-RPC MCP messages from stdin
2. Translates them to our IPC commands
3. Writes MCP responses to stdout
4. Logs to stderr

**MCP tool definitions** (auto-generated from `godopty schema --format mcp`):

```json
{
  "tools": [
    {
      "name": "godopty_new_pane",
      "description": "Split the godopty workspace and open a new pane. Opens a new terminal, code viewer, or observer pane.",
      "inputSchema": {
        "type": "object",
        "properties": {
          "type": {"enum": ["terminal", "code-viewer", "file-tree", "observer"], "description": "Type of pane to open"},
          "command": {"type": "string", "description": "Command to run in terminal or observer pane"},
          "split": {"enum": ["left", "right", "top", "bottom"], "default": "bottom"},
          "title": {"type": "string", "description": "Custom title for the pane"}
        },
        "required": ["type"]
      }
    },
    {
      "name": "godopty_list_panes",
      "description": "List all active panes in the godopty workspace with their IDs, types, and positions.",
      "inputSchema": {
        "type": "object",
        "properties": {}
      }
    },
    {
      "name": "godopty_inject",
      "description": "Send a command or text to an existing terminal pane. Use to run commands without blocking.",
      "inputSchema": {
        "type": "object",
        "properties": {
          "pane_id": {"type": "string", "description": "Pane ID (e.g. T1)"},
          "text": {"type": "string", "description": "Text or command to inject"}
        },
        "required": ["pane_id", "text"]
      }
    }
  ]
}
```

### 4.2 Gemini CLI Integration Pattern

Gemini's MCP client connects to `godopty mcp` via stdio. When the user says "watch the logs while I run tests", Gemini:

1. Calls `godopty_list_panes` to check current state
2. Calls `godopty_new_pane` with `type: observer, command: "tail -f test.log", split: right`
3. Calls `godopty_new_pane` with `type: terminal, command: "cargo test", split: bottom`
4. Calls `godopty_inject` with `pane_id: T2, text: "cargo test"` (alternative path)

### 4.3 Claude Code Integration Pattern

Claude Code doesn't speak MCP natively — it uses a bash tool. Integration is via project config:

**`.claude/settings.json`** or project instructions:
```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{
          "type": "command",
          "command": "if echo \"$CLAUDE_BASH_OUTPUT\" | grep -q 'watching\|long-running'; then true; fi"
        }]
      }
    ]
  }
}
```

**`.claude/instructions.md`**:
```
You have access to the `godopty` CLI for managing terminal panes in the
godopty workspace. Use it to keep long-running commands from blocking
the chat.

- `godopty new-pane --type observer --command "tail -f <file>"` — watch logs
- `godopty new-pane --type terminal --command "<cmd>"` — run a command
- `godopty list-panes --json` — check current layout
- `godopty inject <id> --text "<cmd>"` — send command to existing terminal

Prefer splitting long builds/tests into their own pane so you can
continue working.
```

### 4.4 OMP (Oh My Pi) Integration Pattern

OMP's subagent task runner calls `godopty` deterministically. In a managed skill:

```bash
# When OMP spawns a subagent worker, wrap it in an observer pane
godopty new-pane --type observer --command "omp agent $AGENT_ID --watch" --title "agent:$AGENT_ID"
```

The LLM never decides to use godopty — the framework always routes worker output there.

## 5. Implementation Plan

### Phase 1: IPC Foundation (crate: `godopty-ipc`)

**New crate**: `crates/godopty-ipc/`

- `mod transport` — Unix socket + Windows named pipe abstraction behind a `trait IpcTransport`
- `mod protocol` — JSON-RPC 2.0 types: `Request`, `Response`, `Error`, `Params`
- `mod server` — `IpcServer` that binds, accepts, dispatches to a handler registry
- `mod client` — `IpcClient` with connect timeout, retry, daemon-fallback logic

**Server integration** (in `godopty-gdext`):
- At GDExtension init, spawn a tokio task that runs `IpcServer::bind()`
- Register handlers that call into GDScript via `call_deferred`:
  - `newPane` → `workspace._spawn_pane(type, opts)`
  - `listPanes` → collects pane metadata from `TerminalManager.tiles`
  - `killPane` → `workspace._kill(body)`
  - `focusPane` → `body.grab_focus()`
  - `inject` → `terminal.write_to_pty(text)`
  - `layoutSave/Load/List` → `ProfileManager`
- `call_deferred` constraint: GDScript runs on the main thread, so IPC handlers must be async and resolve their JSON-RPC responses when GDScript signals completion. Use oneshot channels: IPC handler → `call_deferred` → GDScript fn → Rust callback → oneshot sender → IPC response.

**Client implementation** (in `godopty-cli`):
- Replace the current demo code with `clap` derive-based CLI
- Each subcommand handler creates an `IpcClient`, sends a request, prints the response
- `--json` mode: serialize the `Response`/`Error` directly
- Human mode: format with `termion`/`crossterm` tables

### Phase 2: CLI Rebuild (crate: `godopty-cli`)

**Rewrite `main.rs`** around `clap`:

```rust
#[derive(Parser)]
#[command(name = "godopty", version, about)]
struct Cli {
    #[command(subcommand)]
    command: Commands,

    #[arg(long, global = true)]
    json: bool,

    #[arg(long, global = true, default_value = default_socket())]
    socket: PathBuf,

    #[arg(long, global = true, default_value = "5000")]
    timeout: u64,

    #[arg(long, global = true)]
    no_daemon: bool,
}
```

**Subcommand handlers**:
- `new_pane::run(args, client)` — validate type enum locally, send `newPane` RPC
- `list_panes::run(args, client)` — send `listPanes` RPC, format output
- `kill_pane::run(args, client)` — resolve "active" pane ID, send `killPane` RPC
- `inject::run(args, client)` — send `inject` RPC
- `schema::run(args)` — no IPC needed; walks clap `Command` and emits JSON Schema
- `daemon::run(args, client)` — start/stop/status of GUI process

**Daemon logic** (in `daemon.rs`):
- `Daemon::find_gui_binary()` — env var, sibling dir, PATH
- `Daemon::spawn()` — `std::process::Command` with `std::process::Stdio::null()` for stdin, detached
- `Daemon::poll_socket(timeout)` — exponential backoff, max 5s

### Phase 3: MCP Server (crate: `godopty-mcp`)

**New crate**: `crates/godopty-mcp/`

This is a thin layer. It:
1. Reads MCP JSON-RPC from stdin line-by-line
2. Translates MCP tool calls to our IPC methods
3. Writes MCP responses to stdout

Alternatively, fold this into `godopty-cli` as a `godopty mcp` subcommand — avoids a separate binary. The MCP stdio transport is just our existing JSON-RPC protocol over stdin/stdout instead of a Unix socket.

**Decision**: Fold into CLI as `mcp` subcommand. The IPC client already handles JSON-RPC; MCP is just a different transport with the same payloads. Reuse the `IpcClient` against a virtual transport backed by stdin/stdout.

### Phase 4: Schema & Self-Documentation

**`godopty schema`**:
- Walks `clap`'s `Command` at runtime (clap exposes this via `Command::get_subcommands()`, arg metadata)
- Recursively builds JSON Schema with `oneOf` dispatch on subcommand
- `--format mcp` emits MCP tool definitions
- `--format openapi` emits OpenAPI 3.1 path items

**Error suggestions**:
- Implement `clap::error::ErrorFormatter` for "did you mean?" type suggestions
- Pane ID validation: on `kill-pane`/`focus-pane`/`inject` with missing/invalid ID, optionally do a quick `listPanes` lookup and suggest nearest match (Levenshtein distance)

### Phase 5: Daemon + Packaging

- The Godot export pipeline produces `godopty-gui` (the Godot executable)
- The Rust workspace builds `godopty` (the CLI)
- Both are installed side-by-side so the CLI can find the GUI
- CI: build both, bundle in release archives

## 6. Crate Map

```
crates/
├── godopty-core/       # Unchanged — engine, PTY, parser, term, types
├── godopty-ipc/        # NEW — transport, protocol, client, server
├── godopty-cli/        # REWRITTEN — clap CLI + subcommand handlers + daemon logic + MCP
└── godopty-gdext/      # MODIFIED — adds IpcServer at init, handler registry
```

`godopty-ipc` depends on `godopty-core` (for `TerminalConfig`, `PaneType` etc. as shared types). `godopty-cli` depends on `godopty-ipc` (client-side). `godopty-gdext` depends on `godopty-ipc` (server-side).

## 7. Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| Stateless JSON-RPC over Unix socket | No connection mgmt, no reconnection logic, trivial to test with `nc -U` |
| Pane IDs are strings (T1, O2, C3) not UUIDs | Human-readable, already exist in `PaneTypes.label_prefix` + counter |
| Schema auto-generation from clap | Single source of truth — no drift between code and schema |
| Fold MCP into CLI, not separate binary | One less binary to distribute; MCP is just a transport variant |
| CLI does NOT link Godot | Keeps CLI ~5 MB vs ~100 MB; daemon spawns GUI as OS process |
| `call_deferred` bridge for IPC→GDScript | Godot is single-threaded; all GDScript mutations must go through main thread |

## 8. Developer Experience

### 8.1 Discoverability

```
$ godopty --help
Control the godopty terminal workspace from the command line.

Usage: godopty <COMMAND>

Commands:
  new-pane    Open a new pane in the workspace
  list-panes  List all active panes
  kill-pane   Close a pane
  focus-pane  Focus a specific pane
  inject      Send text to a terminal pane
  schema      Output JSON Schema describing all commands
  daemon      Manage the GUI daemon process
  layout      Save/load workspace layouts
  version     Print version info
  mcp         Run as an MCP (Model Context Protocol) server over stdio
  help        Print this message or the help of the given subcommand(s)

Options:
      --json         Machine-readable JSON output
      --socket <PATH>  Override IPC socket path [env: GODOPTY_SOCKET]
      --timeout <MS>   Max wait for socket connection [default: 5000]
      --no-daemon    Don't spawn GUI if not running
  -v, --verbose      Print connection lifecycle to stderr
  -h, --help         Print help
  -V, --version      Print version
```

### 8.2 Graceful Degradation

```
$ godopty new-pane --type terminal
error: Could not connect to godopty GUI
  Socket: /tmp/godopty.sock (not found)
  The GUI is not running and --no-daemon is set.
  Start the GUI manually or run without --no-daemon.

$ godopty new-pane --type terminal
Starting godopty GUI...
Waiting for socket /tmp/godopty.sock... connected.
✓ Terminal T1 opened (bash)

$ godopty new-pane --type terminal --command "htop"
✗ T2 opened, but htop is a full-screen TUI — it may not render correctly
  via IPC. Use godopty focus-pane T2 to interact with it directly.
```

### 8.3 AI Tool Workflows

**Claude Code: "run the test suite and show me the failures"**

```bash
# Claude runs these via its bash tool:
godopty new-pane --type terminal --title "Test Suite" --command "cargo test 2>&1 | tee /tmp/test-output.txt"
godopty new-pane --type observer --title "Failures" --command "grep 'FAILED' /tmp/test-output.txt"
```

**Gemini CLI: "set up a dev environment for this Rust project"**

Gemini reads `godopty schema --format mcp`, sees the tool definitions, and:
1. Opens a terminal running `cargo watch -x check`
2. Opens a code viewer on `src/main.rs`
3. Opens a terminal for ad-hoc commands
4. All by calling `godopty_new_pane` with appropriate params

**OMP: "delegate this refactor to 3 subagents"**

OMP's task runner, configured with a skill:
```bash
for agent in AuthLoader DbMigrator UiRefactor; do
  godopty new-pane --type observer --command "omp agent $agent --watch" --title "$agent"
done
```

## 9. Edge Cases & Error Handling

| Scenario | Behavior |
|----------|----------|
| GUI not running, `--no-daemon` | Error with socket path, exit 1 |
| GUI not running, daemon mode | Spawn GUI, poll socket (5s timeout), retry command |
| GUI binary not found | Error with search paths, suggest `GODOPTY_GUI` env var |
| Grid full (max tiles) | Error with suggestion to close a pane first |
| Invalid pane type | "Did you mean?" before IPC round trip |
| Invalid pane ID | Server-side validation, returns active pane list in error data |
| Socket permissions denied | Suggest `chmod`, show socket owner |
| Concurrent CLI calls | Stateless requests — each is independent. Server serializes via tokio mutex |
| CLI during GUI shutdown | SIGTERM is caught, pending requests get error response, socket cleaned up |
| Windows named pipe limit | Single pipe with multiplexed JSON-RPC — no connection-per-request |

## 10. Non-Goals (for v0.2.0)

- **Streaming output** — `inject` sends text, but there's no "tail output into this CLI" pipe. That's a separate concern (websocket or gRPC streaming) for later.
- **Remote connections** — the IPC socket is local-only. No TCP, no auth, no TLS. This is a single-user desktop tool.
- **Config management via CLI** — settings changes go through the Godot settings panel. The CLI reflects, doesn't mutate, config.
- **Plugin system** — the MCP + JSON Schema surface is the extension point. No dynamic loading.

## 11. Testing Strategy

| Layer | How |
|-------|-----|
| `godopty-ipc` transport | Unit tests with Unix socket pairs (`socketpair`) |
| `godopty-ipc` protocol | Round-trip serialize/deserialize with `serde_json` |
| `godopty-ipc` server | In-process mock handler registry |
| `godopty-cli` commands | Integration tests: spawn real GUI in CI, run CLI commands, assert JSON output |
| MCP integration | `echo '{"jsonrpc":"2.0",...}' \| godopty mcp` smoke test |
| Schema generation | Assert `godopty schema` outputs valid JSON Schema that passes `jsonschema` validation |
| Daemon lifecycle | Mock the spawn, assert fallback paths |
