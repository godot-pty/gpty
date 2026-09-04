---
title: gpty v0.5.0
date: 2026-09-03
---

v0.5.0 marks the ADE release milestone - an agent-facing API on top of the PTY foundation; stable pane IDs, pane read/status/run/wait, event subscriptions, broadcast, and a shipped agent skill.

<!--more-->

![Screenshot](/images/v0.5.0_1.png)

**The ADE foundation.** gpty is now positioned as a graphical Agent Development Environment — a PTY foundation with a public API. Agents inside a pane get `GPTY_ENV=1` and `GPTY_PANE_ID`; panes carry stable public IDs; and the CLI grew five new commands: `pane-read`, `pane-status`, `pane-run`, `pane-wait`, and `broadcast` — all mirrored in the MCP server (19 tools).

**Substrate primitives.** `pane-wait` holds a server-side wait on a Rust-regex scan of recent output; `pane-status` reports pid, running, exit code, and idle time. Concept matches and pane spawn/kill fan out over the event socket via `subscribe` / `eventsPoll`. No agent state machine in core — primitives only, orchestration stays an open market.

**Out of the box.** Five ecosystem presets (herdr, lazygit, nvim, claude, OMP) restore one full-screen terminal each; the shipped `Agent Workspace` profile pairs a terminal with Inspector and Reasoning. `gpty --skill` prints the bundled agent skill for Claude Code, codex, opencode, and OMP.

**Release**

- Download the standalone binary from [GitHub Releases](https://github.com/godot-pty/gpty/releases/tag/v0.5.0).
- Full changelog: [CHANGELOG.md](https://github.com/godot-pty/gpty/blob/main/CHANGELOG.md#050--2026-09-03).
- Source: [github.com/godot-pty/gpty](https://github.com/godot-pty/gpty).
