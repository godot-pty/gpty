# Architecture

gPTY is two runtimes in one process: a Rust engine that owns terminal and workspace state, and a Godot scene tree that draws it. A thin GDExtension layer is the only bridge between them. Understanding that split explains most of the app's behavior — including why the UI polls, why every API call is asynchronous under the hood, and why untrusted input is validated on both sides.

## The pieces

| Piece | Language | Owns |
|---|---|---|
| `gpty-core` | Rust | PTY lifecycle, ANSI parsing, the terminal grid, concepts and capture, scrollback history, the vault index, wikilinks |
| `gpty-ipc` | Rust | JSON-RPC 2.0 types, transport, server, client |
| `gpty-gdext` | Rust | The GDExtension classes (`GptyTerminal`, `GptyAi`, `GptyCliView`, `GptyMedia`, `GptyMarkdown`) and the control/event listeners |
| `gpty-cli` | Rust | The stateless `gpty` client and the MCP server |
| `gpty-ai` | Rust | Inspector backends: a mock and a private OMP RPC process |
| `gpty-media` | Rust | A pinned FFmpeg build, one decode session per file |
| `godot/` | GDScript | The scene tree, tiling grid, pane bodies, settings, dialogs, and all drawing |

The dependency arrows point one way: the engine does not know about Godot. The GDExtension knows both. The UI knows only the GDExtension API.

## Terminal data flow

```text
shell / TUI
   │ bytes
   ▼
PTY master ── dedicated OS thread ──► vte parser ──► alacritty_terminal grid
                                                       │ Arc<Mutex<TermGrid>>
                                                       ▼
                                        GptyTerminal (gdext)
                                                       │ packed updates
                                                       ▼
                                   terminal_pane.gd _draw()
```

Each PTY has its own blocking I/O thread. Output is parsed into the grid under a lock; the UI asks for the cells that changed since the last frame and paints them. A generation counter lets an idle UI skip the poll entirely. The full update shape and the packed arrays are documented in the GDExtension README; the important part is that the UI never owns the terminal state.

## Control data flow

```text
gpty CLI / MCP client
   │ JSON-RPC over a Unix socket or named pipe
   ▼
IpcServer (tokio task, gdext)
   │ queue
   ▼
GDScript drains once per frame ──► workspace / IPC handlers
   │                                      │
   └──────────── oneshot ◄────────────────┘
```

The Godot scene tree is single-threaded, so the socket thread never touches it. Requests are queued, GDScript drains them each frame, and the answer completes a oneshot the socket thread is waiting on. `version` and `shutdown` are answered in Rust; `vaultSearch` and `vaultRead` run natively off the GUI thread because a vault is a directory, not workspace state. Everything else round-trips through the UI.

This is also why the CLI is stateless: one invocation, one connection, one request, one response, exit. There is no persistent client session to lose.

## The other pipelines

```text
OMP extension ──► gpty-events.sock ──► omp_events.rs ──► drain_agent_events()
                                                            │
                                                            ▼
                                                   Reasoning pane + badges
```

```text
Inspector prompt ──► GptyAi ──► private omp --mode rpc --no-tools --no-session
                                      │
                                      ▼
                              session_poll envelopes
```

```text
cli_view config ──► CliProcess (argv child, merged stdout/stderr)
                        │ bounded line queue
                        ▼
                 cli_view_pane.poll_lines()
```

```text
media pane ──► GptyMedia ──► gpty-media worker thread (FFmpeg)
                                  │ bounded RGBA/PCM queues
                                  ▼
                         poll_video / poll_audio
```

These four are deliberately separate from the terminal path. An agent event cannot mutate a grid; a media decoder cannot block the GUI; an Inspector answer cannot reach a shell.

## The FFI contract

Everything crossing from Rust to GDScript is either a string or a packed array:

- Structured answers are JSON strings. The UI parses them and checks the shape before use.
- Grid and media frames are packed arrays with explicit dimensions.
- No Godot object is shared into the engine, and no engine lock is held across a UI call.

Every edge re-validates. A path from a layout, a profile, a vault, or a media file is checked at use, not only at load; an IPC request has a size cap and a handler budget; a captured terminal line is untrusted text. This is not redundancy for its own sake — a file is attacker-controlled input, and the UI and the engine are separate trust surfaces.

## Why Godot

Godot gives the project a real renderer and a scene tree without building either from scratch: custom `_draw()` for the grid, containers for the tiling layout, `RichTextLabel` for Markdown, custom canvases for the link graph and the concept editor, and an export path for three platforms. The cost is a second runtime and an FFI seam; the benefit is that a media pane, a graph canvas, and a settings dialog are ordinary UI work rather than terminal escape sequences.

The engine choice is deliberately boring: `portable-pty` for the PTY, `vte` for parsing, `alacritty_terminal` for grid semantics. The project is not trying to re-derive DEC STD 070; it is trying to build the workspace around a solid one.

## Repository map

| Path | What lives there |
|---|---|
| `crates/gpty-core/` | Engine and stores |
| `crates/gpty-ipc/` | Protocol and transport |
| `crates/gpty-gdext/` | Godot classes and servers |
| `crates/gpty-cli/` | CLI, MCP, plugin commands |
| `crates/gpty-ai/` | Inspector backends |
| `crates/gpty-media/` | FFmpeg media backend |
| `godot/scenes/terminal/` | Workspace, tiles, IPC dispatch, concept routing |
| `godot/scenes/panes/` | Pane bodies and the registry |
| `godot/scenes/ui/` | Sidebar, settings, Markdown, graphs, overlays |
| `godot/scenes/autoloads/` | Persistence and shared stores |
| `docs/content/` | Docs site, agent guides, roadmap, changelog |
| `docs/content/wiki/` | This vault |

[[contributing]] has the build, test, and commit commands.

## Related

- [[gpty]]
- [[contributing]]
- [[terminal-grid]]
- [[ipc]]
- [[control-api]]
- [[security-model]]
