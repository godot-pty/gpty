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
control socket (`gpty.sock` → `gpty-events.sock`). It does not honor
`GPTY_SOCKET` or `GPTY_SECRET`, is not an MCP tool, and cannot create
panes, inject input, or shut down gpty.

It registers three methods:

| Method | Auth | Purpose |
|--------|------|---------|
| `ompEvent` | `GPTY_EVENT_CAPABILITY` | Submit an event for a terminal |
| `subscribe` | none | Open a read-only subscription (max 64) |
| `eventsPoll` | none | Drain events for a subscription id |

Only submission is capability-gated. `subscribe`/`eventsPoll` are open to
any same-UID process: the event channel is not confidential from a peer
that already runs as this user, and the documented threat model accepts
that — but do not treat "only `ompEvent`" as the surface, and do not put
anything on this channel that must stay private from same-UID code.

Each PTY receives ephemeral `GPTY_TERMINAL_SESSION_ID`,
`GPTY_EVENT_CAPABILITY`, `GPTY_EVENT_SOCKET`, and `GPTY_EVENT_PROTOCOL=1`
at spawn. A leaked capability is scoped to that terminal.

**Platform:** the listener runs on Linux, macOS **and** Windows — it
serves `gpty-events.sock` on Unix and `\\.\pipe\gpty-events` on Windows,
and `GPTY_EVENT_*` is injected at spawn on every platform. The shipped
`@gpty/omp-events` extension still speaks only to a Unix socket, so on
Windows Reasoning stays dormant until an adapter with a named-pipe
transport exists. Control IPC is unaffected on either platform.

See `crates/gpty-gdext/src/omp_events.rs` and
`extensions/gpty-omp-events/`.

## Methods

| Method | Params | Result |
|--------|--------|--------|
| `newPane` | `type`, `command?`, `split?`, `title?`, `focus?`, `tags?` | `{pane_id, label, type}` |
| `listPanes` | — | `{panes: [{id, label, type, title, col, row, tags, …}], count}` |
| `killPane` | `pane_id` | `{success: true}` |
| `focusPane` | `pane_id` | `{success: true}` |
| `inject` | `pane_id`, `text` | `{success: true}` |
| `paneRead` | `pane_id`, `lines?` (1–2000) | `{text}` |
| `paneStatus` | `pane_id` | `{pid, running, exit_code, idle_ms}` |
| `paneRun` | `command` | `{pane_id, label, type}` (exit code via `paneStatus`) |
| `paneWait` | `pane_id`, `pattern`, `timeout_ms?` (100–60000) | `{matched, line?}` / `{matched: false, timed_out}` — response held server-side until match or deadline |
| `broadcast` | `tags`, `text` | `{success, count}` |
| `layoutSave` | `name` | `{success, name}` |
| `layoutLoad` | `name` | `{success}` |
| `layoutList` | — | `{layouts: [string]}` |
| `conceptList` | — | `{concepts: [{name, enabled, trigger, actions, …}]}` |
| `conceptToggle` | `name` | `{success, name}` |
| `version` | — | `{version, protocol}` |
| `shutdown` | — | `{success: true}` |

The event socket additionally serves `subscribe` (→ `{subscription_id}`) and
`eventsPoll` (→ `{events}`), draining bounded concept/pane events.

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
