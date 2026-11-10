# Control API

gPTY exposes one method set through three doors: a JSON-RPC socket, the `gpty` CLI, and an MCP server. The methods describe panes, layouts, concepts, and vaults; the doors differ in transport and in who is expected to use them.

The API is a control surface, not an orchestration layer. It can create a pane, type into it, read its output, wait for a pattern, and report status. It cannot decide what an agent should do next, and nothing in the API starts an agent for you.

## The three doors

| Door | Transport | Who uses it | Starts a GUI? |
|---|---|---|---|
| IPC | Newline-delimited JSON-RPC 2.0 over a Unix socket or named pipe | Programs that speak the protocol directly | No |
| CLI | The `gpty` binary, one request per invocation | Shells, scripts, agents inside a pane | Only `new-pane` and `layout load` |
| MCP | JSON-RPC over stdio, one tool per method | Agent harnesses outside gPTY | Never; `daemon-start` is explicit |

All three reach the same handlers in the running GUI. The CLI is a stateless client: it connects, sends one request, reads the answer, and exits. The MCP server is the same client underneath, wrapped in a tool interface.

## The methods

| Method | Params | Answers |
|---|---|---|
| `newPane` | `type`, `command?`, `split?` (`left`/`right`/`top`/`bottom`), `title?`, `focus?`, `tags?` | `{pane_id, label, type}` |
| `listPanes` | — | `{panes: [{id, label, type, title, col, row, tags, …}], count}` |
| `killPane` | `pane_id` | `{success}` |
| `focusPane` | `pane_id` | `{success}` |
| `inject` | `pane_id`, `text` | `{success}` |
| `paneRead` | `pane_id`, `lines?` (1–2000) | `{text}` — screen plus scrollback |
| `paneStatus` | `pane_id?` | One status document, or `{panes: [...]}` for every pane |
| `paneRun` | `command` | `{pane_id, label, type}` |
| `paneWait` | `pane_id`, `pattern`, `timeout_ms?` (100–60000) | `{matched, line?}` or `{matched: false, timed_out}` |
| `broadcast` | `tags`, `text` | `{success, count}` |
| `layoutSave` | `name` | `{success, name}` |
| `layoutLoad` | `name` | `{success}` |
| `layoutList` | — | `{layouts: [string]}` |
| `conceptList` | — | `{concepts: [{name, enabled, trigger, actions, …}]}` |
| `conceptToggle` | `name` | `{success, name}` |
| `vaultSearch` | `vault_path`, `pattern`, `limit?` (1–500) | `{results: [{path, title, snippet}], total, truncated}` |
| `vaultRead` | `vault_path`, `path` | `{path, text, truncated, crlf, mtime, size}`, or an error whose `code` is `outside_vault` when the note resolves outside the vault |
| `vaultWeight` | `vault_path`, `src`, `target`, `weight?` | The declared weight, or a clear |
| `version` | — | `{version, protocol}` |
| `shutdown` | — | `{success}` |

`newPane` and `paneRun` run their `command` **through the configured shell** (`-c`, or `/c` for `cmd.exe`) — a command line, the same authority `inject` has, so `&&`, pipes and globs work. A program is not settable through the API at all: a profile and a saved layout tile are the two surfaces that own one. Both methods hold their answer until the new pane's child has started, so a shell that cannot be started answers an error naming it and closes the tile instead of reporting a pane that can never run anything.

`vaultSearch`, `vaultRead` and `vaultWeight` answer only inside a vault root the user has **registered** - the user-owned `user://vaults.json`, whose only writer is the pane settings UI. A Wiki pane showing a directory is not enough (the pane reads it; the API does not answer for it), and the shipped knowledge base registers itself when a pane opens it. An unregistered root is refused with `-32000` and `data.code = "not_registered"`, so a client cannot use these methods to read Markdown under a directory the user never opened.

The `layout*` methods are named for the arrangement they restore, but in this build they save, load, and list **profiles**: `layoutSave` captures the active workspace as a reusable profile, and `layoutLoad` replaces the active workspace with that profile's tiles. See [[profile]] for the trust rules that apply to loading one, and [[layout]] for the arrangement itself.

The MCP door adds tools that are client-side rather than IPC methods: `daemon-start`, `daemon-stop`, `daemon-status`, and the layout/concept wrappers. It exposes 22 tools in total. Two CLI verbs are deliberately not tools: `state` (it reads the credentials of the pane it runs in) and the plugin verbs (install/enable/remove changes what code runs as you, so a human does it).

## Pane identity and status

A pane is addressed by its attachment ID (`T1`, `C1`, `W1`, …) or by `"active"` for the focused pane. A status document carries:

| Field | Meaning |
|---|---|
| `pid` | The child process, or null once it is gone |
| `running` | A live terminal task with no exit code |
| `exit_code` | The child's exit code, when one was recorded |
| `exit_reason` | `exited`, `task_ended`, or null while running |
| `idle_ms` | Time since the last output; measured on bytes arriving from the platform terminal, so it also grows while a child is simply quiet - and on Windows while the console host sits on an unterminated escape string, which emits nothing ([[conpty]]) |
| `foreground_job` | Whether a command at the shell prompt owns the terminal - exact on Unix (the PTY's foreground process group, so `cmd &` does not count), `null` on Windows/ConPTY, which cannot tell |
| `child_alive` | Whether the spawned child has not been reaped. It stays true for a pane whose terminal task ended while its child survived, which is exactly the case `running` cannot express - see [[ipc]] on why the two are separate |
| `agent_state`, `agent_state_tier` | The display-only badge and which tier supplied it |

`paneRun` opens a new terminal pane through the configured shell; it does not reuse an existing pane. `paneWait` is a regex match against recent output, not a promise about future output: it is held server-side until the pattern appears or the deadline passes. `paneRead` is a snapshot, so a caller that needs a stream should poll or subscribe to events instead.

## Design rules

- **The GUI owns state.** There is no daemon that mirrors the workspace and can disagree with it. If no GUI is running, only the commands that can satisfy a fresh workspace may start one.
- **One definition.** The CLI, MCP schemas, and IPC method list are generated from the same clap definitions; a tool cannot drift from `gpty --help` without failing a test.
- **Validation at the edge.** Request size is capped at 64 KiB, the server accepts at most 16 connections, and each handler has a budget. A window holds at most 96 live panes across every workspace (`Workspace.MAX_LIVE_PANES`), so `new-pane` and `pane-run` answer with the limit instead of starting a process per call without end, and a layout or profile file with more tiles restores what fits and reports the rest. The CLI validates pane types before connecting, with suggestions.
- **No ambient authority.** The socket is owner-only and peer-checked on Unix. An optional shared secret keeps other users out, but it is not a boundary against a program inside a pane, which is a child of the GUI.

The separate event socket is not part of this API: it carries events and cannot create panes, inject input, or shut down the app. See [[omp-events]].

## Which door to use

- **Inside a pane, in a shell:** the CLI. `GPTY_ENV=1` confirms you are in a managed pane, and `GPTY_PANE_ID` names it.
- **Outside gPTY, in an agent harness:** MCP. It is stdio, declares its tools, and never opens a window implicitly.
- **From another program:** the JSON-RPC socket directly. It is the smallest contract and the one the other two are built on.

## Related

- [[gpty]]
- [[ipc]]
- [[cli]]
- [[mcp]]
- [[pane]]
- [[agent-workflow]]
