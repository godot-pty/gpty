---
title: gpty v0.3.0
date: 2026-08-09
---

Third release — CLI, MCP, and AI integration.

<!--more-->

![Screenshot](/images/v0.3.0_1.png)

**CLI binary.** Control a running gpty GUI from the command line over JSON-RPC IPC. Spawn panes, list active panes, inject text, kill panes, and manage daemon lifecycle — all from the terminal.

```bash
gpty new-pane --pane-type terminal
gpty list-panes
gpty inject T1 --text "echo hello"
gpty daemon status
```

**MCP server.** AI tools like Gemini CLI can discover and invoke gpty operations via the Model Context Protocol. Run `gpty mcp` over stdio for tool listing and invocation.

**Daemon mode.** The CLI auto-spawns the GUI if it's not already running. `gpty daemon start/stop/status` manages the lifecycle.

**JSON Schema.** `gpty schema` generates machine-readable tool manifests (JSON Schema and MCP formats) for AI agent integration — no GUI required.

**Sidebar refinements.** Reset button repositioned with red destructive styling. Settings and Reset buttons decouple Phosphor icon rendering from ASCII text for reliable display across Godot versions.

**Release**

- Download the standalone binary from [GitHub Releases](https://github.com/godot-pty/gpty/releases/tag/v0.3.0).
- Full changelog: [CHANGELOG.md](https://github.com/godot-pty/gpty/blob/main/CHANGELOG.md#030--2026-08-09).
- Source: [github.com/godot-pty/gpty](https://github.com/godot-pty/gpty).
