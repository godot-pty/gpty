# gpty

gPTY, a Godot-based Rust multi-PTY emulator desktop application for creating, expanding, and orchestrating terminal sessions in a grid-based GUI.

## Overview

- Reactive Automation: Rather than acting as a passive text pipe, the terminal reads its own output. The built-in pub-sub engine detects matched patterns and automatically executes actions (fixes, restarts, or notifications) in adjacent panes.
- Unrestricted Aesthetics: Built on Godot to support fluid animations, instant theming, and rich UI overlays without the memory overhead of an embedded browser.
- Zero-Friction Tiling: Managing multiple panes relies on a native graphical grid and drag-and-drop (coming soon) mechanics, bypassing the need to memorize complex keyboard multiplexer bindings.
- Open source, no telemetry, no logins.

---

| Component | Choice | Rationale |
|----------|--------|-----------|
| PTY library | `portable-pty` | Cross-platform (Linux `/dev/ptmx` + Windows ConPTY) with a single API |
| ANSI parsing | `vte` crate | Fast Rust ANSI state machine |
| Async runtime | `tokio` | Native `broadcast` channel for 1:N pub-sub |
| I/O threading | Dedicated `std::thread` per PTY | Predictable blocking reads; bridges to tokio via `mpsc` |
| Pub-sub | `tokio::sync::broadcast(1024)` | 1:N fan-out, lagged-receiver protection, self-reaction prevention |
| Grid rendering | `alacritty_terminal` | Full DEC STD 070 grid state machine; pass arrays to Godot `_draw()` |
| Godot bridge | `gdext 0.5` | Native GDExtension for Godot 4.7+ |
| Rust edition | 2024 | Requires Rust >= 1.85 |

---

## Installation

Standalone binaries (no Godot install required) are published on [GitHub Releases](https://github.com/godot-pty/gpty/releases) for Linux, macOS, and Windows.

| Platform | Package |
|---|---|
| Linux | `gpty-v0.3.0-linux-x86_64.tar.gz` — extract and run `./gpty` |
| macOS | `gpty-v0.3.0-macos.zip` — unzip, right-click the `.app` → Open |
| Windows | `gpty-v0.3.0-windows-x86_64.zip` — unzip and run `gpty.exe` |
---

## Features

### Terminals
- Multi-PTY grid with split, kill, and expand operations
- Full DEC STD 070 terminal emulation via `alacritty_terminal`
- Color schemes with configurable palettes (16-color, 256-color, true color)
- Scrollback with regex search (`Ctrl+F`)
- Wrapped text selection for copy/paste
- Configurable cursor shape, blink, and thickness

### Automation
- Concept engine: regex triggers fire actions (command injection or output capture)
- Capture mode routes command output to code viewer panes
- Default concepts shipped; user concepts persisted and editable via settings UI
- `{payload}` and `{N}` variable substitution in action templates

### UI
- Hardware-accelerated Godot renderer with damage tracking
- Three-mode window system: OS decorated, borderless, fullscreen
- Custom titlebar with minimize, maximize/restore, close
- Tiling grid with drag-to-resize edges and pane position swapping
- Sidebar with window mode dropdown, per-pane-type spawn buttons, and full per-pane action buttons
- Bottom status bar showing active pane info, FPS, and window mode
- Settings panel: fonts, colors, cursor, scroll, window mode, titlebar toggle, concept editor
- Toast notifications (info, warn, error)
- Command palette (`Ctrl+P`)

### Persistence
- Settings auto-save/load via `user://settings.json`
- Layout auto-save/restore on startup via `user://layout.json`
- Named profile snapshots via `user://profiles.json`
- Scrollback history stored in SQLite

### Pane Types
- Terminal — PTY-backed shell sessions
- Code Viewer — read-only `CodeEdit` display, receives concept captures
- File Tree — directory listing via `DirAccess`
- Observer — display-only pane for monitoring output

See [CHANGELOG.md](CHANGELOG.md) for version history and [ROADMAP.md](ROADMAP.md) for planned features.

---

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup instructions, build commands, testing, code style, and the pull request process.

## CLI Usage

The `gpty` binary controls a running GUI over JSON-RPC IPC. Build it with `cargo build -p gpty-cli` (or `cargo build --workspace`).

Once the GUI is running (launched from Godot or a release binary), the CLI connects over a Unix socket (`/tmp/gpty.sock` on Linux, or `GPTY_SOCKET` env var):

```bash
# Check if the GUI is running
gpty version

# Spawn a new terminal pane
gpty new-pane --pane-type terminal

# List all active panes
gpty list-panes

# Send text to a pane (by label, e.g. T1)
gpty inject T1 --text "echo hello"

# Close a pane
gpty kill-pane T1

# Save and load named layouts
gpty layout save my-setup
gpty layout load my-setup
gpty layout list

# Manage the GUI daemon
gpty daemon status
gpty daemon stop

# Generate AI tool manifests (no GUI needed)
gpty schema
gpty schema --format mcp

# Run as MCP server over stdio (no GUI needed)
echo '{"jsonrpc":"2.0","id":1,"method":"initialize"}' | gpty mcp
```

See `gpty --help` for all subcommands and flags.

## Concept System

Concepts are the core orchestration primitive: a regular expression trigger paired with labelled actions.

```rust
Concept {
    name: "port_conflict",
    trigger_regex: Regex::new(r"(?i)address.*already.*in\s*use").unwrap(),
    destinations: vec![Action {
        command_template: "echo '[Auto] Port conflict detected - consider lsof -i'",
        target_label: "observer",
    }],
}
```

How it works:
1. PTY output bytes stream through the `vte` parser
2. The parser strips ANSI escape sequences and extracts visible text lines
3. Each line is tested against every registered concept's `trigger_regex`
4. On match, an `Event` is broadcast on the `tokio::sync::broadcast` channel
5. Every terminal task receives the event, checks its labels against each action's `target_label`
6. Matching terminals inject the `command_template` into their PTY's stdin

Self-reaction loops are prevented: a terminal ignores events where `source_pane == my_id`.

Security Warning: The Concept Engine is designed to execute commands automatically based on terminal output. Do not bind destructive or high-privilege actions (like `rm` or `sudo`) to easily spoofable regex triggers. An attacker could intentionally print matching text to trick your terminal into executing the action payload.

### Use Cases

- Auto-Restarting Watchers: Detect a segmentation fault or panic string in a backend server pane, and automatically inject a restart command into an adjacent management pane.
- Port Conflict Resolution: Detect an "Address already in use" error and immediately run an `lsof` or `kill` command to clear the bound port.
- AI Observer: Pipe error blocks (such as a Python traceback or Rust compiler error) to a local language model, displaying a plain-English explanation and a proposed fix in a secondary pane.
- Automated Documentation: Match specific compiler error codes and automatically open the relevant local or web documentation in an adjacent window.

---


## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup instructions, code style, and the pull request process.

---

## License

This project is licensed under the Apache License, Version 2.0 -- see [LICENSE](LICENSE) for details.
