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
| `version` | `gpty version` |

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
gpty pane-status <pane>        # pid, running, exit_code, idle_ms
gpty pane-status               # every pane (agent-status-list)
```

### Waiting for output patterns

`gpty pane-wait <pane> --pattern "tests passed" --timeout-ms 30000` blocks until the
pane's recent output matches (Rust regex syntax), then prints the matching line.

### Fan-out with tags

Create panes with tags (`gpty new-pane --tags ci,backend`), then inject into every
matching pane at once: `gpty broadcast --tags ci --text "make test"`. Text is written
verbatim — the target shell interprets it.

### Subscribe to events

Over the event socket (`gpty-events.sock`): `subscribe` returns a `subscription_id`;
`eventsPoll` drains bounded JSON events (concept matches, pane spawn/kill).

## Installation

Copy this file into your agent's skills directory, or run `gpty --skill` to print it and save the output wherever your agent loads skills from.

- Claude Code: `~/.claude/skills/gpty/SKILL.md`
- codex: `~/.codex/skills/gpty/SKILL.md`
- opencode: `~/.config/opencode/skills/gpty/SKILL.md`
- OMP: your project or global skills directory (see OMP `skill://` routing)
