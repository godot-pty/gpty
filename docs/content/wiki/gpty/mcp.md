# MCP

`gpty mcp` is a Model Context Protocol server over stdio: an AI harness that speaks MCP gets gPTY's workspace operations as tools, without writing socket code or shelling out. It is the third door onto the [[control-api|Control API]] — the same methods the [[cli|CLI]] exposes — reshaped into the tool-calling convention MCP defines.

## What the server is

The process reads newline-delimited JSON-RPC from stdin and writes answers to stdout. It implements the MCP handshake (`initialize`, answering protocol version `2024-11-05` with `serverInfo` naming `gpty`), discovery (`tools/list`), and dispatch (`tools/call`). Each `tools/call` is translated into one request on the [[ipc|control socket]]; the server holds a single client connection and forwards the result as tool output.

A stdio server is the right shape here because an MCP harness already owns the process: it spawns `gpty mcp`, keeps the pipes, and never needs a port, a URL, or a discovery file. There is nothing to secure on the network because there is no network.

Configure it the way your harness documents a stdio server: command `gpty`, argument `mcp`. The repo's root `mcp.json` is exactly that:

```json
{"mcpServers":{"gpty":{"command":"gpty","args":["mcp"]}}}
```

## The tool set

Twenty-two tools are published, mirroring CLI actions and kebab-cased:

| Area | Tools |
|---|---|
| Panes | `new-pane`, `list-panes`, `kill-pane`, `focus-pane`, `inject`, `pane-read`, `pane-status`, `pane-run`, `pane-wait` |
| Fan-out | `broadcast` |
| Layout | `layout-save`, `layout-load`, `layout-list` |
| Daemon | `daemon-start`, `daemon-stop`, `daemon-status` |
| Concepts | `concept-list`, `concept-toggle` |
| Vault | `vault-search`, `vault-read`, `vault-weight` |
| Misc | `version` |

Two CLI commands are deliberately **not** tools. `state` declares the agent state of the pane the command runs in and reaches the event socket, not the control socket — an MCP client has no pane, so advertising it would publish a tool that cannot dispatch. `plugin` installs and manages plugins: install waits on a human reading a review dialog, and the admin verbs touch local state rather than the workspace API. Both exclusions are enforced by a test, not a comment.

The heavy hitters for an agent are `pane-wait` and `pane-read`. Together they turn a terminal into a synchronous function call: run a command, wait for the line that means done, read the output. `pane-run` returns as soon as the pane exists, so the exit code is not the answer — `pane-status` is.

## The name gate

`tools/call` validates the requested tool name against `schema::mcp_tool_names()` before dispatch. This is not ceremony. Tool names are kebab-case and IPC methods are camel-case, so dispatch maps one to the other mechanically — and a mechanical mapping turns *any* string into a method name. Without the gate, a client that guesses `shutdown` — or any method that exists on the socket but was never published as a tool — would reach it. The allowed-name list is computed once at startup from the CLI definitions, so the gate and the advertised tool list cannot disagree.

The consequence for an MCP author is simple: if a tool is not in `tools/list`, calling it fails, even if the underlying control method exists.

## Where the schemas come from

Tool descriptions and argument schemas are generated from the clap command definitions in `crates/gpty-cli/src/commands/schema.rs`. Each subcommand becomes a tool, its arguments become JSON Schema properties with enums pulled from clap's possible values, and required-argument marking follows the clap definition.

Two transformations happen on the way. Nested subcommand groups are flattened: `daemon start` becomes `daemon-start`, `layout save` becomes `layout-save`. The concept and vault verbs are already flat. And the self-referential commands are skipped — `mcp` (the server describing itself as a tool makes no sense) and `schema` (an admin/discovery command, not a workspace action). Because both the schema and `--help` read the same definitions, `gpty schema --format mcp` is the authority whenever documentation and binary disagree.

## No auto-spawn

The [[cli|CLI]] starts a GUI on demand for `new-pane` and `layout load`. The MCP server never does: no tool call may open a window behind the user's back. When a call finds no GUI, the answer says so and names `daemon-start`, which is the one explicit bootstrap.

That asymmetry is deliberate. A CLI invocation is a deliberate act by a human or a script that named the command; an MCP client is a model calling tools in a loop, and it should not be able to fill the desktop with workspaces as a side effect of a retry. `daemon-start` exists so that "start the GUI" is a decision the model can make and the user can audit as a distinct tool call.

## MCP or CLI?

Both reach the same methods, so the choice is about where the caller lives.

| Situation | Use |
|---|---|
| A harness outside gPTY (an editor, a chat UI, a service) | MCP |
| A shell script, Makefile, or CI job | CLI |
| An agent running **inside** a gPTY pane | CLI, via the skill |
| Blocking on output until a pattern appears | Either; `pane-wait` in both |
| Declaring the current pane's state | CLI only (`state`) |
| Installing or validating a plugin | CLI only (`plugin`) |

The reason an in-pane agent uses the CLI is credentials and identity: the CLI reads `GPTY_*` from the pane's environment, so it knows which pane it is in and can declare state. An MCP server is a separate process spawned by the harness; it does not inherit the pane's injected identity in any meaningful way. The bundled skill, printed by `gpty --skill`, assumes the CLI for exactly this reason — see [[agent-workflow|Agent Workflow]].

## Related

[[control-api]] · [[cli]] · [[ipc]] · [[agent-workflow]] · [[gpty]]
