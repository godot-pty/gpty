---
title: gpty v0.1.0
date: 2026-07-21
---

First release!

<!--more-->

![Home](/images/v0.1.0_1.png)

**Terminal engine**

- `gpty-core` handles PTY spawning via `portable-pty`
- ANSI parsing via `vte`
- A full terminal grid via `alacritty_terminal`. 
- Damage-tracked rendering keeps the Godot frontend fast.

**Tiling grid**

- Split panes vertically or horizontally inside nested `SplitContainer` nodes.
- Four pane types: terminal, code viewer (`CodeEdit`), file tree, and observer.
- `Alt+Arrow` navigates between panes geographically.

**Concept engine.**
- Define regex triggers that match terminal output and inject commands into labelled panes.
- Two capture modes: `SingleLine` broadcasts immediately, `UntilStop` buffers command output and routes it to receiver panes.
- Default concepts ship for 'cat' and port conflicts.

**Profiles and persistence.** 

- Save terminal layouts as named profiles.
- Settings, profiles, and layout state auto-save to `user://`.
- Everything persists across restarts.

**Release**

- Download the standalone binary for your platform from [GitHub Releases](https://github.com/gpty/gpty/releases/tag/v0.1.0).
- Changelog: [github.com/gpty/gpty/CHANGELOG](https://github.com/gpty/gpty/blob/main/CHANGELOG.md).
- Source: [github.com/gpty/gpty](https://github.com/gpty/gpty).
