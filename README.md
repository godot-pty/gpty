[gPTY](https://godot-pty.github.io/gpty/) - a graphical Agent Development Environment (ADE); a PTY foundation built on Godot and Rust. Provides a tiling terminal grid, a pub-sub concept engine, and a JSON-RPC/MCP control surface so AI agents and automation tools can spawn panes, inject text, and observe output without scraping a TUI.

## Built With

<p align="center">
  <img src="https://img.shields.io/badge/Gemini-8E75B2?style=for-the-badge&logo=googlegemini&logoColor=white" alt="Gemini">
  <img src="https://img.shields.io/badge/DeepSeek-4D6BFE?style=for-the-badge&logo=deepseek&logoColor=white" alt="DeepSeek">
  <img src="https://img.shields.io/badge/Claude-D97757?style=for-the-badge&logo=claude&logoColor=white" alt="Claude">
</p>

## Overview

- **PTY foundation** - Spawn and manage independent shell sessions in a resizable tiling grid. Full DEC STD 070 via `alacritty_terminal`: 16/256/true color, scrollback with regex search, wrapped text selection.
- **Public API** - JSON-RPC IPC socket + CLI (`gpty new-pane`, `gpty inject`, …) + MCP server. AI agents, scripts, and orchestrators drive the workspace over a documented, versioned protocol.
- **Concept engine** - RegEx triggers on PTY output automatically inject commands or capture output into adjacent panes. Write your own or ship defaults.
- **Agent observability** - Reasoning pane passively projects documented agent lifecycle events (OMP, extensible); Inspector pane runs a private, tool-free Q&A session. Observability only - gpty never orchestrates agent state.
- **Persistence** - Scrollback, settings, workspaces (named tab sets), and profiles auto-save to SQLite/JSON and restore on restart; full-text search across each pane's persisted history.
- **Cross-platform** - Standalone binaries for Linux, macOS, and Windows. No Godot or Rust toolchain required to run.
- **Documentation** - https://godot-pty.github.io/gpty/

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

## Installation & Usage

Standalone binaries (no Godot install required) are published on [GitHub Releases](https://github.com/godot-pty/gpty/releases) for Linux, macOS, and Windows.

| Platform | Package |
|---|---|
| Linux | `gpty-v0.5.2-linux-x86_64.tar.gz` - extract and run `./gpty` |
| macOS | `gpty-v0.5.2-macos.zip` - unzip, right-click the `.app` → Open |
| Windows | `gpty-v0.5.2-windows-x86_64.zip` - unzip and run `gpty.exe` |

### CLI

The `gpty` binary controls a running GUI over JSON-RPC IPC. Build it with `cargo build -p gpty` (or `cargo build --workspace`).

Once the GUI is running (launched from Godot or a release binary), the CLI connects over a Unix socket (`$XDG_RUNTIME_DIR/gpty.sock` on Linux, or `GPTY_SOCKET` env var):

```bash
# Check if the GUI is running
gpty version

# Print the bundled agent skill (for coding agents running inside a pane)
gpty --skill

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

### MCP integration

gpty ships an MCP (Model Context Protocol) server so AI agents and coding harnesses can control the workspace. The repo-root [`mcp.json`](mcp.json) declares it for auto-discovery:

```json
{"mcpServers": {"gpty": {"command": "gpty", "args": ["mcp"]}}}
```

- **Direct**: run `gpty mcp` over stdio - exposes a tool per CLI subcommand (`new-pane`, `list-panes`, `kill-pane`, `focus-pane`, `inject`, `pane-read`, `pane-status`, `pane-run`, `pane-wait`, `broadcast`, `layout-*`, `daemon-*`, `concept-*`, `version`).
- **Manifest**: `gpty schema --format mcp` prints the MCP tool manifest (JSON Schema, works without a running GUI) for hand-off to agent configurations.

Tool schemas are generated from the same clap definitions as the CLI (`crates/gpty-cli/src/commands/schema.rs`), so they cannot drift from `gpty --help`.

---

## Roadmap

See [ROADMAP.md](ROADMAP.md) for the full feature inventory.

---

## Security

See [AGENTS.md](AGENTS.md#security) for current security rules, including concerns around the Concept Engine, ReDoS prevention and OSC 52 clipboard restrictions.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup instructions, build commands, testing, code style, and the pull request process.

---

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for the complete versioned changes and history.

---

## License

This project is licensed under the Apache License, Version 2.0 - see [LICENSE](LICENSE) for details.
