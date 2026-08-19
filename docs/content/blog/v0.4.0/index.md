---
title: gpty v0.4.0
date: 2026-08-19
---

Seventh release — private Inspector Q&A, passive Reasoning projection, and the first OMP observability bridge.

<!--more-->

![Screenshot](/images/v0.4.0_1.png)

**Inspector pane.** A dedicated, private, tool-free Q&A surface. Each pane owns one in-memory session (`omp --mode rpc` with tools, extensions, skills, and rules all disabled) — it never attaches to or scrapes the terminal-hosted OMP TUI. Capture-to-Inspector concepts ship disabled, and panes gate captures behind an explicit opt-in.

**Reasoning pane.** A passive projection of documented OMP lifecycle events from one terminal of your choice, linked by a stable attachment id. Turn history stays in RAM for the current session only; nothing is written to layouts or profiles.

**OMP event channel.** A second local socket (`gpty-events.sock`) accepts only the `ompEvent` method, authenticated with a per-terminal capability injected at spawn. The shipped `@gpty/omp-events` extension is dormant unless explicitly linked and all four activation variables are present. Unix-only for now; Windows fails closed.

**OMP Workspace profile.** A built-in recommended layout — Terminal, Inspector, and Reasoning side by side. Built-in profiles can't be overwritten or deleted from the sidebar.

**Safe Markdown everywhere.** Inspector and Reasoning streams render through a Rust CommonMark→BBCode converter with HTML and BBCode escaped; code-viewer panes gain a rendered/source toggle for Markdown files.

**Terminal fixes.** Resize cascades no longer collapse the grid or scroll through history: transient pane sizes are floored, redundant SIGWINCH is skipped, grid growth keeps text anchored, and the emulator now answers cursor-position queries so full-screen TUIs re-render in place.

**Release**

- Download the standalone binary from [GitHub Releases](https://github.com/godot-pty/gpty/releases/tag/v0.4.0).
- Full changelog: [CHANGELOG.md](https://github.com/godot-pty/gpty/blob/main/CHANGELOG.md#040--2026-08-19).
- Source: [github.com/godot-pty/gpty](https://github.com/godot-pty/gpty).
