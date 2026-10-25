# CLI

`gpty` is the command-line client for a running gPTY workspace: one subcommand per action, one connection per invocation, no session to maintain. It is one of the three doors onto the [[control-api|Control API]] — the other two being the raw [[ipc|JSON-RPC socket]] and the [[mcp|MCP server]].

## What the CLI is for

The CLI is what a shell script, a Makefile, a coding agent inside a pane, or a human in a terminal uses to touch the workspace. It turns flags into a single JSON-RPC request, prints the result, and exits. That design keeps it composable: you can put it in a pipeline, call it from any language, and rely on the exit code.

Two behaviors follow from "no session":

| Behavior | Meaning |
|---|---|
| Stateless | Each invocation connects, sends one request, reads one response, exits |
| Client-side validation | Pane types and argument shapes are rejected before any round-trip, with "did you mean?" suggestions |

The second point matters for automation: a typo in a pane type fails immediately with a useful message instead of a socket timeout or a remote error.

## Subcommands

| Command | What it does |
|---|---|
| `new-pane` | Open a pane. `-t/--pane-type` (terminal, code_viewer, file_tree, inspector, reasoning, cli_view, wiki, media), `-c/--command`, `--arg` (repeatable, `cli_view` argv), `-s/--split`, `-f/--focus`, `--tags` |
| `list-panes` | Every pane with id, label, type, and grid position |
| `kill-pane` | Close a pane by id, or `"active"` for the focused one |
| `focus-pane` | Focus a pane by id |
| `inject` | Send text to a terminal pane by id |
| `pane-read` | Screen plus scrollback text (`--lines` 1–2000) |
| `pane-status` | Status of one pane, or of every pane when no id is given |
| `pane-run` | Run a command in a new terminal pane (`--command`) |
| `pane-wait` | Wait for output matching a regex (`--pattern`, `--timeout-ms` 100–60000) |
| `state` | Declare the current pane's agent state (`idle`, `working`, `needs-attention`, `completed`, `failed`) |
| `broadcast` | Inject text into every pane carrying one of `--tags` |
| `vault` | `search <vault> <pattern>` (`--limit` 1–500), `read <vault> <path>`, `weight <vault> <src> <target> --weight N` / `--clear` |
| `concept` | `list`, `toggle <name>` |
| `schema` | Print JSON Schema for all commands; `--format mcp` for the MCP tool manifest |
| `mcp` | Run as an MCP server over stdio |
| `daemon` | `start`, `stop`, `status` |
| `layout` | `save <name>`, `load <name>`, `list` |
| `plugin` | `install <owner>/<repo>[@ref]`, `list`, `enable`/`disable <id>`, `uninstall <id>`, `logs <id>`, `run <id> <action>`, `validate <path>` |
| `version` | Version information |

`observer` is a deprecated alias for `inspector`: `new-pane` translates it and prints a warning; manifests refuse it outright. `pane-run` deliberately does not reuse `inject`: it spawns a fresh terminal pane, which is what you want when the command should have its own scrollback and exit status rather than typing into someone else's shell.

`vault weight` is the one `vault` verb that writes anything, and the only thing it writes is gPTY's own declared-weight store (`user://link_weights.json`) — never a note, never the index. It also needs a running GUI, because that store belongs to the workspace. `search` and `read` do not need one.

## Global flags

| Flag | Effect |
|---|---|
| `--skill` | Print the bundled agent skill (the instructions shipped for agents inside a pane) and exit |
| `--json` | Machine-readable output; failures keep exit code 1 and print the JSON-RPC error envelope |
| `--socket <path>` | Override the IPC socket path |
| `--timeout <ms>` | Connection timeout in milliseconds (default 5000) |
| `--no-daemon` | Never auto-spawn the GUI, even for the two commands that otherwise would |
| `-v`, `--verbose` | Verbose output on stderr |

`--json` is the switch to reach for in automation. Without it, results are printed for a human; with it, every command answers with the JSON document the socket returned. A failure is still exit code 1, and the envelope's `error.data.code` is the stable discriminator — `not_found`, `bad_path`, `outside_vault` and friends — so a script can branch on the failure kind instead of parsing a message.

## Examples

Open a pane and give it work:

```bash
gpty new-pane --pane-type terminal --command "cargo test" --focus
```

Run a command in a fresh pane, then check on it:

```bash
gpty pane-run --command "cargo test"
gpty pane-status
```

Wait for a pattern, then read the result — the two calls compose into "run, wait, capture":

```bash
gpty pane-wait T1 --pattern "tests passed" --timeout-ms 30000
gpty pane-read T1 --lines 200
```

Search a vault and read a hit:

```bash
gpty vault search ~/notes "ownership" --limit 20
gpty vault read ~/notes notes/idea.md
```

Tell the workspace what the pane you are running in is doing:

```bash
gpty state working
```

`state` is different from everything else in the table. It takes no target: it reads the credentials gPTY injected into the current pane (`GPTY_TERMINAL_SESSION_ID`, `GPTY_EVENT_CAPABILITY`, `GPTY_EVENT_SOCKET`, `GPTY_EVENT_PROTOCOL=1`), submits over the event socket, and is display only. It never triggers concepts, actions, or layout changes, and it is not an MCP tool because an MCP client is not inside a pane.

## Statelessness and auto-spawn

The rule is narrow on purpose: the CLI starts the GUI only for `new-pane` and `layout load`. Both are requests whose entire meaning is "make a workspace appear" — refusing them because nothing is open would be pedantic. A query (`list-panes`, `pane-read`, `version`, `vault search`) never opens a window: a monitor that polls every second should not be able to litter the desktop with GUIs.

`--no-daemon` disables even the two, so a CI job or a script that must not touch the user's session can guarantee it. With `--no-daemon` and no running GUI, the command fails rather than silently starting a second workspace.

When the CLI does spawn a GUI, it does so as a separate OS process — the CLI binary never links Godot. It finds the GUI through the `GPTY_GUI` environment variable (validated before use) or beside its own executable (`gpty-gui`, `gpty-editor`), then polls the socket until it answers.

## Schema and skill output

Two flags exist for machines and agents rather than people. `gpty schema` prints a JSON Schema for every command, generated from the same clap definitions that produce `--help`, so it cannot drift from the binary; `--format mcp` prints the MCP tool manifest instead. `gpty --skill` prints the bundled skill text that tells a coding agent how to drive the workspace from inside a pane — see [[agent-workflow|Agent Workflow]] for the recipes it carries.

## Related

[[control-api]] · [[ipc]] · [[mcp]] · [[agent-workflow]] · [[gpty]]
