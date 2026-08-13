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
