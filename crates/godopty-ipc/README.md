# godopty-ipc

JSON-RPC 2.0 IPC transport, client, and server for godopty workspace control.

## Role in the Workspace

| Crate | Role | Depends On |
|-------|------|------------|
| `godopty-core` | Engine library (PTY, ANSI, grid, concepts) | — |
| **`godopty-ipc`** | **IPC transport + protocol** | `godopty-core` |
| `godopty-gdext` | Godot 4 GDExtension bridge + IPC server | `godopty-core`, `godopty-ipc` |
| `godopty-cli` | CLI client for workspace control | `godopty-ipc` |

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

- **Linux**: Unix domain socket at `/tmp/godopty.sock` (override with `GODOPTY_SOCKET`)
- **macOS**: `$TMPDIR/godopty.sock`
- **Windows**: Named pipe `\\.\pipe\godopty`

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
| `godopty-core` | path | Engine types (`PaneType`, `TerminalConfig`) |
| `serde` | 1 | Serialization framework |
| `serde_json` | 1 | JSON encoding |
| `tokio` | 1 | Async I/O + sync primitives |
| `thiserror` | 2 | Error derive macro |
| `parking_lot` | 0.12 | Fast Mutex (no poisoning) |
| `log` | 0.4 | Log facade |
