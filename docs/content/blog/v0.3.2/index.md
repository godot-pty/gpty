---
title: gpty v0.3.2
date: 2026-08-13
---

Fifth release — security hardening from an external audit, plus a round of test-coverage and documentation work.

<!--more-->

![Screenshot](/images/v0.3.2_1.png)

**Security hardening.** This release follows an external audit. IPC gained optional `GPTY_SECRET` shared-secret authentication, per-user socket placement, and request/connection caps. Concept `{payload}` template values are now shell-quoted before injection, concept parsing is capped, PTY environments are sanitized at spawn, and the CLI validates `GPTY_SOCKET`/`GPTY_GUI` overrides before trusting them.

**Trustworthy layouts.** Restoring a saved layout or profile now validates tile data — malformed entries are skipped or clamped instead of crashing, and pane file paths must be absolute.

**Terminal fixes.** Printable keys (`z`, punctuation) no longer collide with special-key scancodes, Ctrl+V passes through as literal `^V`, `Ctrl+Shift+C` is copy-only, and the concept editor no longer crashes on an empty workspace.

**Under the hood.** The capture lifecycle and concept routing are now unit-testable, CLI commands round-trip against a mock IPC server, and the GUT suite grew to 135 tests. A `scripts/build` standalone app builder and a `scripts/clean` workspace cleanup script ship with the repo.

**Release**

- Download the standalone binary from [GitHub Releases](https://github.com/godot-pty/gpty/releases/tag/v0.3.2).
- Full changelog: [CHANGELOG.md](https://github.com/godot-pty/gpty/blob/main/CHANGELOG.md#032--2026-08-13).
- Source: [github.com/godot-pty/gpty](https://github.com/godot-pty/gpty).
