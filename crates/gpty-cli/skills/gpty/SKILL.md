---
name: gpty
description: Control the gPTY terminal workspace from inside a gPTY-managed pane.
---

# gPTY

## Guardrail

If the environment variable `GPTY_ENV` is not set to `1`, stop and state that you are not inside a gPTY-managed pane. Everything below assumes `GPTY_ENV=1`.

## Overview

You are running inside one pane of a gPTY terminal workspace. Use the `gpty` CLI (or the gpty MCP server) to create, inspect, and drive the other panes in the grid. `GPTY_PANE_ID` identifies the pane you currently occupy.

## MCP tools and CLI equivalents

| MCP tool | CLI equivalent |
| --- | --- |
| `new-pane` | `gpty new-pane --pane-type terminal` |
| `list-panes` | `gpty list-panes` |
| `kill-pane` | `gpty kill-pane <pane>` |
| `focus-pane` | `gpty focus-pane <pane>` |
| `inject` | `gpty inject <pane> --text "..."` |
| `layout-save` | `gpty layout save <name>` |
| `layout-load` | `gpty layout load <name>` |
| `layout-list` | `gpty layout list` |
| `daemon-start` | `gpty daemon start` |
| `daemon-stop` | `gpty daemon stop` |
| `daemon-status` | `gpty daemon status` |
| `concept-list` | `gpty concept list` |
| `concept-toggle` | `gpty concept toggle <name>` |
| `vault-search` | `gpty vault search <vault> <pattern>` |
| `vault-read` | `gpty vault read <vault> <path>` |
| `vault-weight` | `gpty vault weight <vault> <src> <target> --weight N` |
| `version` | `gpty version` |

The CLI starts a GUI on demand for `new-pane` and `layout load`; the MCP
server never starts one implicitly - if a tool call finds no GUI, the answer
says so and names `daemon-start`, which is the explicit bootstrap over MCP.

### Discovery and what this skill leaves out

- `gpty schema` prints the full command set as JSON Schema (`--format mcp` for the MCP tool manifest). It needs no running GUI and is generated from the same definitions as `gpty --help`, so it is the authority when this table and the binary disagree.
- `gpty mcp` is the MCP server itself, speaking over stdio. You are already using it if the tools above appear in your tool list; it is not something to call from a shell recipe.
- `gpty plugin` installs and manages plugins, which run code as the user. Installing one is a human decision made in a review dialog in the GUI. Never install, enable, or remove a plugin on your own; if a task needs one, tell the user which and why.

## Coordination recipes

### Split a pane and run a test suite

```
gpty new-pane --pane-type terminal --command "cargo test" --title "tests"
```

### Read another pane's output

`gpty list-panes` reports every pane by stable id (`id`) and display label (`label`).
Read a pane's screen plus scrollback:

```
gpty pane-read <pane> --lines 200
```

### Run a command and watch its status

```
gpty pane-run --command "cargo test"
gpty pane-status <pane>        # pid, running, exit_code, exit_reason, idle_ms
gpty pane-status               # every pane (agent-status-list)
```

The no-pane form is one API call and answers
`{panes: [{pane_id, label, type, status}]}`; a pane without status primitives
(a non-terminal) carries `status: null`, so the list is complete rather than
silently shorter.

### Stream a command's output into a pane

`cli_view` runs argv directly (no shell, no PTY) and shows its stdout in the
pane body - the no-terminal way to watch a tool that just needs to print:

```
gpty new-pane --pane-type cli_view --command git --arg status --arg --short
gpty pane-read V1 --lines 100
```

Arguments after `--arg` are passed verbatim (no shell evaluation), and
`pane-read` returns the body text, so you can check on it later.

### Waiting for output patterns

`gpty pane-wait <pane> --pattern "tests passed" --timeout-ms 30000` blocks until the
pane's recent output matches (Rust regex syntax), then prints the matching line.

### Query the knowledge base (Markdown vault)

All three commands take the vault's absolute directory. Search and read are
read-only: nothing in the vault is written. `weight` writes only your own
declared-weight store (never the vault, never the index) and is display-only.

```
gpty vault search ~/notes "ownership lifetimes"   # {results, total, truncated}
gpty vault read ~/notes notes/idea.md             # {path, text, truncated, crlf, mtime, size}
```

Search re-indexes notes whose mtime/size changed before querying, so a note
edited outside gPTY is visible to the next search - no pane needs to reopen
the vault. Terms are ANDed and notes are stemmed; `--limit` accepts 1–500
(default 20). A hit names the vault-relative `path`, which is what `read`
takes. `truncated: true` on a search means the walk hit its 2000-note cap, so
results are partial; on a read it means the note is larger than the 1 MiB
display cap and the text stops there. A refusal (missing note, path outside
the vault) is a JSON-RPC error whose `data.code` is stable (`not_found`,
`bad_path`, …).

### Curate link weights (display only)

```
gpty vault weight ~/notes notes/a.md notes/b.md --weight 40   # {vault, src, target, weight}
gpty vault weight ~/notes notes/a.md notes/b.md --clear       # weight: 0
```

An optional authored override of the link graph's measured mention count, 1–100.
It changes edge thickness, the canvas layout springs and link-panel ordering -
nothing else: it can never hide an edge, gate navigation, write to the vault or
count as consent. The store (`user://link_weights.json`) belongs to the running
GUI, so this command needs one and never starts it.

### Fan-out with tags

Create panes with tags (`gpty new-pane --tags ci,backend`), then inject into every
matching pane at once: `gpty broadcast --tags ci --text "make test"`. Text is written
verbatim - the target shell interprets it.

### Declare your pane's agent state

```
gpty state working
```

Sets the state badge on the pane you are running in - one of `idle`, `working`,
`needs-attention`, `completed`, `failed`. It takes no target: it reads the
credentials gPTY injected into your pane and submits the declaration over the
event socket, so it works wherever a pane does, Windows included (ConPTY
consumes the `gpty_state` OSC that Unix agents print instead). It is display
only - it never triggers actions, captures, or layout changes - and there is no
MCP tool for it, since an MCP client is not inside a pane.

### Subscribe to events

Over the event socket (`gpty-events.sock`): `subscribe` returns a `subscription_id`;
`eventsPoll` drains bounded JSON events (concept matches, pane spawn/kill,
`state.declared`).

## Installation

Copy this file into your agent's skills directory, or run `gpty --skill` to print it and save the output wherever your agent loads skills from.

- Claude Code: `~/.claude/skills/gpty/SKILL.md`
- codex: `~/.codex/skills/gpty/SKILL.md`
- opencode: `~/.config/opencode/skills/gpty/SKILL.md`
- OMP: your project or global skills directory (see OMP `skill://` routing)
