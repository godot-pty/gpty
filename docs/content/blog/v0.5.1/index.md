---
title: gpty v0.5.1
date: 2026-09-09
---

v0.5.1 makes gPTY persistent: scrollback survives restarts and becomes full-text searchable (with a new search UI), named workspaces keep panes alive across switches, and the whole pane API is exercised by a live smoke test in CI.

<!--more-->

![Screenshot](/images/v0.5.1_1.png)

**Persistent scrollback.** The SQLite+FTS5 history store is now wired into every pane, keyed by the stable `attachment_id`. The newest `history_lines` rows (a new setting, default 10 000) restore into scrollback on restart, and `pane-read` reaches them. The terminal search bar gains a Live/History toggle — History mode runs FTS5 queries against the persisted store and lists matching lines (click to copy).

![History search and the sidebar Workspaces section](/images/v0.5.1_2.png)

**Workspaces.** Up to eight named pane sets in one window, managed from the sidebar's Workspaces section. Switching hides and shows grids instead of killing PTYs — background commands keep running. Workspaces persist to `workspaces.json`, with a one-shot migration from the old single-layout file.

**A polished sidebar.** Content margins, measured section heights (no more truncated rows or phantom scrollbars), icon+text action buttons, and active-row accents across workspaces, profiles, and panes. User profiles rename inline with a double-click.

**Pane API fixes and a shell-executing pane-run.** The pane-API methods were registered but never routed on the GUI IPC server — `pane-read`, `pane-status`, `pane-run`, `pane-wait`, and `broadcast` now work end-to-end (the new live smoke proves it, including the event socket). `pane-run` executes through the configured shell, so compound commands like `cargo test && git push` work.

**Release**

- Download the standalone binary from [GitHub Releases](https://github.com/godot-pty/gpty/releases/tag/v0.5.1).
- Full changelog: [CHANGELOG.md](https://github.com/godot-pty/gpty/blob/main/CHANGELOG.md#051--2026-09-09).
- Source: [github.com/godot-pty/gpty](https://github.com/godot-pty/gpty).
