---
title: gpty v0.3.1
date: 2026-08-12
---

Fourth release — stability, Windows support, and concept management.

<!--more-->

![Screenshot](/images/v0.3.1_1.png)

**Windows support fixed.** The v0.3.0 Windows build failed because the IPC server assumed Unix socket semantics. Named pipes now serve per-connection instances, and a Windows compile job in CI prevents platform-specific breakage from ever reaching tag time again.

**Concept engine reliability.** Concepts register correctly at startup (previously a race silently dropped them), `UntilStop` capture triggers from real PTY output, capture-only concepts with empty commands work, and concept toggles apply correctly.

**Concept management from anywhere.** `gpty concept list` and `gpty concept toggle` control concept automations from the CLI, and the matching `concept-list` / `concept-toggle` MCP tools expose them to AI agents.

**Terminal copy/paste.** `Ctrl+Shift+V` paste and `Ctrl+Shift+C` copy work in terminals again — the code viewer spawn shortcut moved to `Ctrl+Shift+C`.

**Release**

- Download the standalone binary from [GitHub Releases](https://github.com/godot-pty/gpty/releases/tag/v0.3.1).
- Full changelog: [CHANGELOG.md](https://github.com/godot-pty/gpty/blob/main/CHANGELOG.md#031--2026-08-12).
- Source: [github.com/godot-pty/gpty](https://github.com/godot-pty/gpty).
