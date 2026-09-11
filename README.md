[gPTY](https://godot-pty.github.io/gpty/) - a PTY foundation built on Godot and Rust. Provides a tiling grid for panes (terminal, code, file-tree, etc.), a concept capture engine, and a JSON-RPC/MCP control surface so AI agents and automation tools can spawn panes, inject text, and observe output on terminals without scraping a TUI.

## Overview

<div align="center">

  [![Build](https://img.shields.io/github/actions/workflow/status/godot-pty/gpty/ci.yml?branch=main)](https://github.com/godot-pty/gpty/actions/workflows/ci.yml)
  ![GitHub Downloads (all assets, all releases)](https://img.shields.io/github/downloads/godot-pty/gpty/total)
  &nbsp;&nbsp;&nbsp; <img src="https://img.shields.io/badge/Built%20With:-gray" alt="Built With">
  <img src="https://img.shields.io/badge/Gemini-8E75B2?logo=googlegemini&logoColor=white" alt="Gemini">
  <img src="https://img.shields.io/badge/DeepSeek-4D6BFE?logo=deepseek&logoColor=white" alt="DeepSeek">
  <img src="https://img.shields.io/badge/Claude-D97757?logo=claude&logoColor=white" alt="Claude">

</div>

- **PTY** - Spawn and manage independent shell sessions in a resizable tiling grid. Full `DEC STD 070` via `alacritty_terminal`: `16`/`256`/`true color`, scrollback with regex search, wrapped text selection.
- **Public API** - JSON-RPC IPC socket + CLI (`gpty new-pane`, `gpty inject`, …) + MCP server. AI agents, scripts, and orchestrators drive the workspace over a documented, versioned protocol.
- **Concept engine** - RegEx triggers on PTY output capture the reply and route it into adjacent panes (code viewer, Inspector). Write your own or ship the defaults. Concepts capture and display only - they never inject input into a shell.
- **Agent observability** - Reasoning pane passively projects documented agent lifecycle events (OMP, extensible); Inspector pane runs a private, tool-free Q&A session. Observability only - gpty never orchestrates agent state.
- **Persistence** - Scrollback, settings, workspaces (named tab sets), and profiles auto-save to SQLite/JSON and restore on restart; full-text search across each pane's persisted history.
- **Cross-platform** - Standalone binaries for Linux, macOS, and Windows. No Godot or Rust toolchain required to run.
- **Documentation** - https://godot-pty.github.io/gpty/
- The vast majority of this codebase, including most of the Godot UI layout and the Rust (`gpty-core`) GDExtension bridge, was generated using LLMs; and as such, the underlying code may contain unidiomatic patterns and/or bugs.

| Component | Choice | Rationale |
|----------|--------|-----------|
| PTY library | `portable-pty` | Cross-platform (Linux `/dev/ptmx` + Windows ConPTY) with a single API |
| ANSI parsing | `vte` crate | Fast Rust ANSI state machine |
| Async runtime | `tokio` | Per-terminal tasks; channel-driven capture state machine |
| I/O threading | Dedicated `std::thread` per PTY | Predictable blocking reads; bridges to tokio via `mpsc` |
| Concept capture | Rust `regex` over parsed `LineParser` output | Linear-time matching (ReDoS-safe); captures buffer raw bytes for grid-faithful replay |
| Grid rendering | `alacritty_terminal` | Full DEC STD 070 grid state machine; pass arrays to Godot `_draw()` |
| Godot bridge | `gdext 0.5` | Native GDExtension for Godot 4.7+ |
| Rust edition | 2024 | Requires Rust >= 1.85 |

---

## Installation & Usage

Standalone binaries (no Godot install required) are published on [GitHub Releases](https://github.com/godot-pty/gpty/releases) for Linux, macOS, and Windows.

| Platform | Package |
|---|---|
| Linux | `gpty-v0.5.3-linux-x86_64.tar.gz` - extract and run `./gpty` |
| macOS | `gpty-v0.5.3-macos.zip` - unzip, right-click the `.app` → Open |
| Windows | `gpty-v0.5.3-windows-x86_64.zip` - unzip and run `gpty.exe` |

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

See [SECURITY.md](SECURITY.md) for the threat model, reporting process, and what gpty does *not* defend against. Implementation rules - the Concept Engine's ReDoS stance, PTY environment sanitization, IPC hardening, OSC 52 restrictions - live in [AGENTS.md](AGENTS.md#security).

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup instructions, build commands, testing, code style, and the pull request process.

---

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for the complete versioned changes and history.

---

## License

gPTY is free software, licensed under the **GNU General Public License, version 3 or later** — see [LICENSE](LICENSE) for the full text.

[LICENSE-EXCEPTIONS.md](LICENSE-EXCEPTIONS.md) adds two permissions under section 7 of that license, so the ecosystem side stays permissive:

- **Plugins, extensions, and adapters are not required to be GPLv3.** Anything that works with gPTY over its CLI, JSON-RPC, MCP, or event interfaces — including native pane types — may be licensed under Apache-2.0, MIT, or any other terms you choose, and shipped alongside gPTY without obligation.
- **Configuration and data files carry no copyleft.** Profiles, workspaces, layouts, concepts, and settings are yours to license however you like; the default `*.json` files shipped with gPTY are Apache-2.0.

Copyright (C) 2026 Neil Pathare.

gPTY is distributed in the hope that it will be useful, but absolutely without any warranty and assumes no liability for any usage by end-users; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
