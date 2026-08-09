---
title: gpty v0.2.0
date: 2026-08-08
---

Second release.

<!--more-->

![Screenshot](/images/v0.2.0_1.png)

**Window modes.** Three-mode window system — OS decorated, borderless windowed, and fullscreen. Per-pane titlebar with minimize, swap, settings, and close buttons. Custom titlebar in non-OS modes. Drag to move.

**Status bar.** Bottom bar showing active pane info, FPS/ms, and the current window mode indicator. Sidebar pane rows now match the full action button set from the titlebar.

**Layout persistence fixed.** Save on `_exit_tree()` instead of unreliable `WM_CLOSE_REQUEST`. Window mode and settings persist correctly across restarts. Profile trust dialog warns before restoring layouts saved with a different shell.

**Auto-spawn.** First launch with no saved layout spawns one terminal automatically.

**Release**

- Download the standalone binary from [GitHub Releases](https://github.com/godot-pty/gpty/releases/tag/v0.2.0).
- Full changelog: [CHANGELOG.md](https://github.com/godot-pty/gpty/blob/main/CHANGELOG.md#020--2026-08-08).
- Source: [github.com/godot-pty/gpty](https://github.com/godot-pty/gpty).
