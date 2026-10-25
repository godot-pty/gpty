# IPC

gPTY's inter-process control channel: a newline-delimited JSON-RPC 2.0 conversation over a local socket, where the GUI owns all workspace state and every client is a stateless caller. It is the transport under the [[control-api|Control API]]; the same method set also has a [[cli|command-line]] face and an [[mcp|MCP]] face.

## Why a socket exists at all

The workspace — panes, their PTYs, layouts, concepts, the wiki index — lives in one Godot process. Anything else that wants to act on it (a shell script, a coding agent in another pane, an editor plugin, a test harness) is a separate process. There is no safe way for another process to reach into the GUI's memory, so the GUI listens. Clients connect, send one request, read one answer, and leave.

## One state owner, many stateless clients

The GUI is the single writer. A CLI invocation does not cache pane lists, hold a connection, or remember a session: it connects, sends exactly one request, reads exactly one response, exits. Two `gpty list-panes` calls a second apart are unrelated events — no login, no reconnect logic, no client-side model to go stale.

The corollary is that the GUI must be running for a request to be answered. The CLI can start it on demand for two commands (`new-pane` and `layout load`); queries never spawn a window, and `--no-daemon` refuses even the two that would. The MCP server never spawns one at all.

## The request path

The socket thread is async and the scene tree is single-threaded, so a request is never handled on the socket thread. It is queued, and GDScript picks it up on the next frame:

```text
client ──▶ socket / named pipe ──▶ IpcServer (tokio task)
                                    │ queues the request
                                    ▼
                    GDScript _process() → drain_ipc_requests()
                    → workspace handler mutates the scene
                    → respond_ipc() completes the pending oneshot
                                    │
client ◀──────── response ──────────┘
```

`drain_ipc_requests()` hands back `{id, method, params, timeout_ms}`, where `timeout_ms` is what remains of the request's budget — a dialog that needs a human arms its own timer from it and cannot outlive the request. Deferred methods such as `paneWait` are held server-side: the connection stays open until the pattern matches or the deadline passes.

A method call is asynchronous from the GUI's point of view, and a long call does not block the frame loop — but it does occupy one connection slot.

## The wire

All traffic is newline-delimited JSON-RPC 2.0: one JSON object per line, both directions. A request:

```json
{"jsonrpc":"2.0","id":1,"method":"newPane","params":{"type":"terminal","command":"/bin/bash","focus":true}}
```

The answer:

```json
{"jsonrpc":"2.0","id":1,"result":{"pane_id":"T1","label":"T1","type":"terminal"}}
```

An error uses the standard envelope:

```json
{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"Unknown method: badMethod"}}
```

The client wrappers reshape them into command flags and tool arguments.

## Where the socket lives

| Platform | Path | Override |
|---|---|---|
| Linux | `$XDG_RUNTIME_DIR/gpty.sock`, then `/run/user/<uid>/gpty.sock`, then `/tmp/gpty-<uid>.sock` | `GPTY_SOCKET` |
| macOS | `$TMPDIR/gpty.sock`, then `/tmp/gpty-<uid>.sock` | `GPTY_SOCKET` |
| Windows | `\\.\pipe\gpty` | `GPTY_SOCKET` |

The fallbacks cover sessions with no runtime directory (a cron job, a stripped login); both sides derive the same list, so the client finds the bound endpoint.

## Control methods

| Method | Purpose |
|---|---|
| `newPane` | Create a pane; `type`, optional `command`, `split`, `title`, `focus`, `tags` |
| `listPanes` | Every pane with id, label, type, title, cell position, tags |
| `killPane` | Close a pane by id, or `"active"` for the focused one |
| `focusPane` | Focus a pane by id or `"active"` |
| `inject` | Write text to a terminal pane's PTY input, verbatim |
| `paneRead` | Plain text of a pane's screen plus scrollback (`lines` 1–2000) |
| `paneStatus` | Status document for one pane, or every pane when no id is given |
| `paneRun` | Run a command in a **new** terminal pane through the configured shell |
| `paneWait` | Hold the response until recent output matches a Rust regex (100–60000 ms) |
| `broadcast` | Inject text into every pane carrying one of the given tags |
| `layoutSave` | Save the active workspace's tiles as a named profile |
| `layoutLoad` | Activate a profile, replacing the active workspace's panes |
| `layoutList` | Names of the visible profiles |
| `conceptList` | Concept name, enabled flag, trigger, actions |
| `conceptToggle` | Enable or disable a concept by name |
| `vaultSearch` | FTS5 search over a Markdown vault (limit 1–500) |
| `vaultRead` | One note's text, with its size and mtime stamp |
| `vaultWeight` | Write or clear one declared link weight (display only) |
| `version` | GUI version and IPC protocol version |
| `shutdown` | Ask the GUI to exit |

`paneStatus` carries `pid`, `running`, `exit_code`, `exit_reason`, `idle_ms`, `agent_state`, and `agent_state_tier`; `exit_reason` is `exited`, `task_ended`, or null while running. With no pane it returns every tile, non-terminals carrying `status: null` so the list is complete rather than silently shorter.

## Why some methods are answered natively

`version` and `shutdown` are settled inside Rust — they describe or end the process, not the scene, and routing them through a frame would make them slower and less reliable. `vaultSearch` and `vaultRead` are answered natively too: a vault is a directory of files, not workspace state, and the walk plus the SQLite query run on the blocking pool instead of the GUI thread, so a large vault never stalls a frame.

`vaultWeight` is the exception that proves the rule. Its store is Godot's `user://link_weights.json`, so the write is routed to GDScript like every other stateful method — the split is by ownership.

## Security rules

The channel can create panes, inject keystrokes, and shut the workspace down, so it is hardened against other local users:

| Rule | Behavior |
|---|---|
| Socket placement | 0600 socket inside a per-user directory |
| Peer identity | Unix servers verify the connecting process shares the server's effective UID |
| One instance | A live endpoint is never replaced; only a crash leftover is rebound |
| Optional secret | `GPTY_SECRET` set on the GUI and clients; missing or mismatched yields `-32001` |
| Request size | Lines over 64 KiB are refused with `-32600` |
| Connections | At most 16 concurrent; 30 s I/O bounds on read and write |
| Handler budget | 30 s default, 75 s for `paneWait`, 305 s for `pluginInstall`; overrun answers `-32000` |

`GPTY_SECRET` keeps *other users* out. It is not a boundary against a program inside a pane: that program is a child of the GUI, inherits its environment, and can read the secret back.

## The second socket

Observability travels on a separate listener, `gpty-events.sock` (`\\.\pipe\gpty-events` on Windows), sitting beside the control socket. It is not an MCP tool, cannot create panes, inject input, or shut anything down, and does not honor `GPTY_SOCKET` or `GPTY_SECRET`. It serves three methods: `ompEvent` (capability-gated submission), `subscribe` (read-only, max 64 subscriptions), and `eventsPoll` (drain a subscription). Event types include pane spawn/kill, concept matches, declared agent state, and the OMP agent set — see [[omp-events|OMP Events]]. Keeping it separate means a program that only needs to report events never holds a handle that can drive the workspace.

## Related

[[control-api]] · [[cli]] · [[mcp]] · [[security-model]] · [[architecture]] · [[gpty]]
