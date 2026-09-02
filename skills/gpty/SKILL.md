---
name: gpty
description: Control the gpty terminal workspace from inside a gpty-managed pane.
---

# gpty

## Guardrail

If the environment variable `GPTY_ENV` is not set to `1`, stop and state that you are not inside a gpty-managed pane. Everything below assumes `GPTY_ENV=1`.

## Overview

You are running inside one pane of a gpty terminal workspace. Use the `gpty` CLI (or the gpty MCP server) to create, inspect, and drive the other panes in the grid. `GPTY_PANE_ID` identifies the pane you currently occupy.

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

`gpty list-panes` reports every pane and its id. Direct scrollback reads are not yet shipped; until they are, watch the target pane's grid directly or route its output to a concept capture.

### Waiting for output patterns (upcoming)

These tools are not yet available and must not be relied on:

- `waitForOutput` — server-owned pattern wait with a timeout.
- `agent-status-list` — list agent state across panes.
- `broadcast-input` — send input to a tagged set of panes.

## Installation

Copy this file into your agent's skills directory, or run `gpty --skill` to print it and save the output wherever your agent loads skills from.

- Claude Code: `~/.claude/skills/gpty/SKILL.md`
- codex: `~/.codex/skills/gpty/SKILL.md`
- opencode: `~/.config/opencode/skills/gpty/SKILL.md`
- OMP: your project or global skills directory (see OMP `skill://` routing)
