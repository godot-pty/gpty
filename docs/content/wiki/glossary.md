# Glossary

One place for the words this wiki uses without re-defining them. Each entry links to the note that explains it properly; where no note exists, the definition is the whole story.

| Term | What it means here |
|---|---|
| Agent state | A display-only badge (idle, working, needs attention, completed, failed) describing what an agent in a terminal is doing. See [[agent-state]]. |
| ANSI escape sequence | Bytes beginning with ESC that move the cursor, change colors, or switch screens instead of printing. See [[ansi-escape-sequences]]. |
| Attachment ID | The stable per-pane identifier (`T1`, `pane-8f3a1c2d`, or a name you set) that the control API and per-pane environment use. See [[pane]]. |
| Capture | The output a concept buffers after its trigger matches, until a stop condition ends it. See [[capture]]. |
| Concept | A named rule: a regex trigger, optional extra conditions, and actions that route captured output to a pane type. It never executes anything. See [[concepts]]. |
| ConPTY | Windows' pseudo console, the platform counterpart to a Unix PTY. See [[conpty]]. |
| Control API | The one method set exposed three ways: the JSON-RPC socket, the `gpty` CLI, and the MCP server. See [[control-api]]. |
| Declared link weight | An authored 1–100 weight for one wiki link, layered over its measured mention count. Display only. See [[declared-link-weights]]. |
| Event socket | A second local socket (`gpty-events.sock`) carrying capability-scoped agent and pane events. It cannot control the workspace. See [[omp-events]]. |
| FTS5 | SQLite's full-text search extension, used for scrollback history and vault notes. See [[history]] and [[vault]]. |
| gdext | The Rust binding for Godot's GDExtension interface; the bridge between the Rust engine and the Godot UI. See [[architecture]]. |
| Ghost | A link-graph node for a mention whose target does not resolve to any note. See [[link-graph]]. |
| Grid | The rows-by-columns cell state a terminal emulator maintains, not the tiling layout of panes. See [[terminal-grid]]. |
| IPC | Inter-process communication over the control socket. The GUI owns workspace state; clients send requests. See [[ipc]]. |
| Layout | The arrangement of panes inside one workspace: geometry plus per-tile settings. See [[layout]]. |
| MCP | Model Context Protocol, the stdio tool interface gPTY exposes to agent harnesses. See [[mcp]]. |
| Note | A `.md` file inside a vault. See [[vault]]. |
| OMP | An agent CLI that can emit lifecycle events to gPTY through the bundled extension. See [[omp-events]]. |
| Pane | The visible unit: a tile in the tiling grid plus a body. See [[pane]]. |
| Profile | A named set of tiles that can be activated into a workspace. See [[profile]]. |
| PTY | Pseudo-terminal: the kernel interface that makes a program believe it is talking to a terminal. See [[pty]]. |
| Scrollback | Output that has left the visible grid but is still available above it. See [[scrollback]]. |
| Shell | The program that reads commands and starts other programs; the default program inside a terminal pane. See [[shell]]. |
| Tile | The grid cell, geometry, and chrome of a pane, as distinct from its body. See [[pane]]. |
| TUI | A full-screen terminal application that paints its own interface with cursor addressing. See [[full-screen-tui]]. |
| Vault | A directory of Markdown notes, browsed and edited by the Wiki pane. See [[vault]]. |
| Wikilink | A mention written as double brackets (target, optional alias, optional heading) that becomes a graph edge. See [[wikilinks]]. |
| Workspace | A tab containing its own layout of panes. See [[workspace]]. |
| Workspace Trust | The consent gate that asks before a restored tile runs a different program or argv. See [[workspace-trust]]. |

## Related

- [[index]]
- [[gpty]]
- [[terminal-foundations]]
- [[pane]]
- [[vault]]
