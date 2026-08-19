# gpty-ipc

JSON-RPC 2.0 IPC transport, client, and server for gpty workspace control.

## Role in the Workspace

| Crate | Role | Depends On |
|-------|------|------------|
| `gpty-core` | Engine library (PTY, ANSI, grid, concepts) | — |
| **`gpty-ipc`** | **IPC transport + protocol** | `gpty-core` |
| `gpty-gdext` | Godot 4 GDExtension bridge + IPC server | `gpty-core`, `gpty-ipc` |
| `gpty-cli` | CLI client for workspace control | `gpty-ipc` |

## Modules

| Module | Purpose |
|--------|---------|
| [`protocol`](src/protocol.rs) | JSON-RPC 2.0 types: `Request`, `Response`, `JsonRpcError` with builders |
| [`types`](src/types.rs) | IPC domain types: `NewPaneParams`, `PaneInfo`, `InjectParams`, etc. |
| [`transport`](src/transport.rs) | Platform-specific socket connection (Unix domain, named pipe) |
| [`server`](src/server.rs) | Async IPC server: bind socket, accept connections, dispatch to handlers |
| [`client`](src/client.rs) | Async IPC client: connect, send request, read response with timeout |

## Architecture

The GUI owns the workspace state — the CLI is a **stateless client**: each
invocation connects, sends one JSON-RPC request, reads the response, and
exits. No persistent connection, no connection management.

```text
gpty CLI ──▶ socket / named pipe ──▶ IpcServer (gdext, tokio task)
                                     │  queues PENDING_REQUESTS
                                     ▼
                     GDScript _process() polls drain_ipc_requests()
                     → workspace._handle_ipc_method() mutates the scene
                     → respond_ipc() completes the pending oneshot
```

The GUI scene tree is single-threaded, so requests are never handled on
the socket thread: the server queues them and GDScript polls each frame
(`crates/gpty-gdext/src/ipc.rs`). `version` and `shutdown` are answered
locally in Rust; every other method round-trips through GDScript with a
5-second fallback timeout, and the response flows back through a oneshot
channel.

**Daemon auto-spawn** (`gpty-cli`): when the socket isn't reachable, the
CLI spawns the GUI as a separate OS process — the CLI never links Godot —
and polls the socket until ready. The GUI binary is discovered via the
`GPTY_GUI` env var (validated before use) or beside the CLI executable
(`gpty-gui`, `gpty-editor`).

## Protocol

All communication is newline-delimited JSON-RPC 2.0 over a platform socket:

- **Linux**: Unix domain socket at `$XDG_RUNTIME_DIR/gpty.sock` (fallbacks: `/run/user/<uid>/gpty.sock`, `/tmp/gpty-<uid>.sock`; override with `GPTY_SOCKET`)
- **macOS**: `$TMPDIR/gpty.sock` (fallback `/tmp/gpty-<uid>.sock`; override with `GPTY_SOCKET`)
- **Windows**: Named pipe `\\.\pipe\gpty`

### Example

Request:
```json
{"jsonrpc":"2.0","id":1,"method":"newPane","params":{"type":"terminal","command":"/bin/bash","focus":true}}
```

Response:
```json
{"jsonrpc":"2.0","id":1,"result":{"pane_id":"T1","type":"terminal"}}
```

Error:
```json
{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"Unknown method: badMethod"}}
```

## Security

The IPC channel controls the whole workspace, so the server hardens the
channel against other local users:

- **Socket placement**: Linux defaults to `$XDG_RUNTIME_DIR/gpty.sock` (a
  per-user, 0700 directory); the socket file itself is chmod 0600.
- **Peer UID check**: on Linux/macOS the server verifies the connecting
  process runs as the same effective UID as the server and drops mismatches.
- **Shared secret (optional)**: set `GPTY_SECRET` when launching the GUI and
  for every client (CLI, MCP). The server rejects requests with a missing or
  mismatched `gpty_secret` field (`-32001`).
- **Request size cap**: request lines over 64 KiB get an `-32600` error.
- **Connection cap**: at most 16 concurrent connections; slow connections
  are dropped after 30 s.

## Event socket (OMP observability)

A **second** listener, `default_event_socket_path()`, sits beside the
control socket (`gpty.sock` → `gpty-events.sock`). It accepts only the
JSON-RPC method `ompEvent`. It does not honor `GPTY_SOCKET` or
`GPTY_SECRET`, is not an MCP tool, and cannot create panes, inject
input, or shut down gpty.

Each PTY receives ephemeral `GPTY_TERMINAL_SESSION_ID`,
`GPTY_EVENT_CAPABILITY`, `GPTY_EVENT_SOCKET`, and `GPTY_EVENT_PROTOCOL=1`
at spawn. A leaked capability is scoped to that terminal.

**Platform:** event submission is **Unix-only** (Linux/macOS). gpty starts
the `gpty-events.sock` listener and injects `GPTY_EVENT_*` only on Unix
(`gpty-gdext/src/omp_events.rs`). On Windows, control IPC uses named pipes
and works; the event listener is not implemented yet, activation variables
are not injected, and Reasoning / `@gpty/omp-events` stay dormant
(fail-closed). A future Windows port will likely mirror control IPC with a
separate named pipe, not `GPTY_SOCKET`.

See `crates/gpty-gdext/src/omp_events.rs` and
`extensions/gpty-omp-events/`.

## Methods

| Method | Params | Result |
|--------|--------|--------|
| `newPane` | `type`, `command?`, `split?`, `title?`, `focus?` | `{pane_id, type}` |
| `listPanes` | — | `{panes: [{id, type, title, col, row, ...}], count}` |
| `killPane` | `pane_id` | `{success: true}` |
| `focusPane` | `pane_id` | `{success: true}` |
| `inject` | `pane_id`, `text` | `{success: true}` |
| `layoutSave` | `name` | `{success, name}` |
| `layoutLoad` | `name` | `{success}` |
| `layoutList` | — | `{layouts: [string]}` |
| `conceptList` | — | `{concepts: [{name, enabled, trigger, actions, …}]}` |
| `conceptToggle` | `name` | `{success, name}` |
| `version` | — | `{version, protocol}` |
| `shutdown` | — | `{success: true}` |

## Key Dependencies

| Crate | Version | Role |
|-------|---------|------|
| `gpty-core` | path | Engine types (`PaneType`, `TerminalConfig`) |
| `serde` | 1 | Serialization framework |
| `serde_json` | 1 | JSON encoding |
| `tokio` | 1 | Async I/O + sync primitives |
| `thiserror` | 2 | Error derive macro |
| `parking_lot` | 0.12 | Fast Mutex (no poisoning) |
| `log` | 0.4 | Log facade |
