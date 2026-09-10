---
title: gpty v0.5.2
date: 2026-09-09
---

v0.5.2 is the Agent State & Adapters release: terminals now *report* what an agent is doing — through authenticated events, a published OSC declaration, or plain heuristics — and the titlebar shows it at a glance. The event channel speaks an adapter-neutral vocabulary on every platform, and Inspector gains a generic CLI backend so any agent CLI can answer questions.

<!--more-->

![Screenshot](/images/v0.5.2_1.png)

**Agent-state badges.** Every terminal titlebar now carries a small status badge: a spinner while an agent turn is in flight, a check when it settles, a warning on failure, and a pulsing amber warning when it needs attention. The state is a *display projection* — it never feeds decisions.

**Tiered detection.** Behind the badge sits a three-tier `AgentState` model. Tier 1 — capability-authenticated events from the agent's own extension (authoritative). Tier 2 — the published `gpty_state=<value>` OSC declaration: any program can declare its state with a single escape sequence, strictly whitelisted and rate-limited. Tier 3 — conservative heuristics (test-failure patterns, non-zero shell exits) with a 60-second decay. `gpty pane-status` reports the state and which tier set it.

**A generic event vocabulary.** The event socket now translates adapter-specific wire names into one neutral contract (`agent.started`, `turn.started`, `tool.call`, `thinking.delta`, …) at the trust boundary. Reasoning consumes the generic names, and future adapters speak them from day one. The listener also serves Windows named pipes — per-terminal `GPTY_EVENT_*` injection happens on every platform.

**A CLI backend for Inspector.** Inspector's backend picker gains `cli`: configure any adapter command (argv, never shell-evaluated) that speaks a minimal NDJSON contract — one request line per prompt in, `thinking`/`delta`/`done`/`error` frames out. Cancelling kills the child cleanly; the next prompt respawns it. Adapters use only each CLI's documented hooks — never tokens, never TUI scraping.

**Settings fixes.** Per-tab reset buttons, per-color resets, OK/Cancel on color pickers, live-applied UI colors, and a settings panel whose six tabs always fit. Under the hood: the pane-settings popup no longer goes dead after its pane is closed, and restarted terminals no longer grow piles of old prompt lines (a bare carriage return used to commit a history row on every shell redraw).

**Release**

- Download the standalone binary from [GitHub Releases](https://github.com/godot-pty/gpty/releases/tag/v0.5.2).
- Full changelog: [CHANGELOG.md](https://github.com/godot-pty/gpty/blob/main/CHANGELOG.md#052--2026-09-09).
- Source: [github.com/godot-pty/gpty](https://github.com/godot-pty/gpty).
