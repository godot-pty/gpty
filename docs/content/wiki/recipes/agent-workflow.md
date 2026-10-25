# Agent Workflow

An agent is useful in gPTY when it can open panes, run work in them, and read what came back. This note is the sequence for that, from both places an agent can stand: inside one pane of the grid, and outside the app entirely.

## Two positions, two doors

The same method set is reachable three ways — a JSON-RPC socket, the `gpty` CLI, and an MCP server. Which door you use depends less on taste than on where you are running.

| Position | Door | May start the GUI? |
|---|---|---|
| Inside a gPTY pane | `gpty` CLI over the control socket | yes, for `new-pane` and `layout load` only |
| Outside, as an MCP client | `gpty mcp`, JSON-RPC over stdio | never; `daemon-start` is the bootstrap |

Both speak to a single running workspace, so the GUI is the state. Nothing an agent does here creates a second window: a `new-pane` call lands as a tile beside the others.

## Inside a pane: confirm the guardrail first

A pane injects `GPTY_ENV`, `GPTY_PANE_ID` and the event-socket credentials into every program it spawns. An agent that was launched elsewhere has none of them.

1. Run `echo "$GPTY_ENV"`. If it does not print `1`, you are not inside a gPTY-managed pane — say so and stop rather than guessing at pane ids.
2. Run `gpty --skill` to print the bundled agent skill, and `gpty schema` for the full command set as JSON Schema. The schema needs no GUI and is generated from the same definitions as `--help`, so it wins when documentation and binary disagree.
3. Run `gpty list-panes` to see the current grid by stable id (`T1`, `C1`, `I1`, and so on) and display label.

## Recipe: split, run tests, wait, read

Prerequisites: a running GUI, and an agent whose `GPTY_ENV` is `1`.

1. Open a pane that runs the command immediately: `gpty new-pane -t terminal -c "cargo test" -f`. The call answers with the new pane's id, label and type — say `T2`.
2. Wait for the line that tells you it ended: `gpty pane-wait T2 --pattern "test result" --timeout-ms 60000`. The pattern is Rust regex syntax; the timeout is 100–60,000 ms and the wait is held server-side, so a dead pane does not hang your client past the bound.
3. Read the tail: `gpty pane-read T2 --lines 200`. This is the plain-text screen plus scrollback, up to 2,000 lines.
4. Check how it exited: `gpty pane-status T2` answers `pid`, `running`, `exit_code`, `exit_reason` and `idle_ms`.

What you should see: a new tile appears on the first step, the wait returns the matching line, the read shows the test output, and the status carries the exit code the shell reported.

If it does not work: a wait that matches nothing fails on its timeout rather than returning an empty success. `pane-read` is a snapshot, not a stream — call it again for new output, or use the wait between calls. And `pane-run --command "cargo test"` always opens a *new* pane; it does not reuse `T2`.

## Recipe: fan out with tags

Tags are how one message reaches many panes without listing ids.

1. Create panes carrying a tag: `gpty new-pane --tags ci`. Tags follow the attachment-id pattern (lowercase, up to 32 characters), and a pane holds up to 16.
2. Send the same text to every tagged pane: `gpty broadcast --tags ci --text "make test"`.

The text is written verbatim; the shell in each pane interprets it, so quoting and newlines are the shell's business, not the API's. Use this for "run the suite everywhere", not for structured commands you cannot afford to have half-executed in a pane that is mid-prompt.

## Declare what you are doing

`gpty state working` sets the badge on the pane the command runs in — one of `idle`, `working`, `needs-attention`, `completed`, `failed`. It takes no target: it reads the credentials the pane injected and submits over the event socket. It is display only and never triggers actions, captures or layout changes. There is deliberately no MCP tool for it, because an MCP client is not inside a pane.

## Outside a pane: the MCP door

1. Start the app if it is not running: `gpty daemon start`. From an MCP client, the equivalent is the `daemon-start` tool.
2. Launch the server: `gpty mcp`. It speaks JSON-RPC over stdio and exposes 22 tools covering the same operations — pane lifecycle, `inject`, `pane-read`, `pane-status`, `pane-run`, `pane-wait`, `broadcast`, layouts, concepts, the vault reads and weights, `daemon-*` and `version`.
3. Check health with `gpty daemon status`, and stop the app with `gpty daemon stop` when the harness is done.

MCP never auto-spawns a workspace. A tool call that finds no GUI answers with that fact and names `daemon-start`, which is the explicit bootstrap. This is a safety property: a background model server should not be able to open a desktop application as a side effect of a query.

## Guardrails worth keeping

- Installing, enabling or removing a plugin is a human decision: installation ends in a review dialog in the GUI, and a plugin's actions run with your user's privileges. If a task needs one, name it and why rather than doing it.
- A concept cannot execute anything. Its trigger is a regex over untrusted terminal output and its only effect is routing text to a pane that accepts content, so captured output is data, never a command.
- Nothing above is a stream. Every read is a snapshot of a pane, and `pane-wait` is the mechanism for "tell me when".

## Related

- [[control-api]]
- [[cli]]
- [[mcp]]
- [[pane]]
- [[agent-state]]
