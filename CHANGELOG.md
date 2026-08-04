# Changelog

Log all notable changes to the project. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] — unreleased

### Added

- **CLI rewrite**: `godopty` binary for workspace control over JSON-RPC IPC
  - Subcommands: `new-pane`, `list-panes`, `kill-pane`, `focus-pane`, `inject`, `layout`, `daemon`, `schema`, `mcp`, `version`
  - `--json` flag for machine-readable output; human-formatted tables for `list-panes`
  - `--no-daemon` flag to skip auto-spawning the GUI
  - Levenshtein-based "did you mean?" suggestions for invalid pane types
- **`godopty-ipc` crate**: JSON-RPC 2.0 transport, protocol, client, and server
  - Unix domain socket transport (Linux/macOS) with named pipe stub (Windows)
  - Handler registry with async dispatch; newline-delimited JSON framing
  - `GODOPTY_SOCKET` env var override for socket path
- **IPC server in gdext**: tokio server bridges JSON-RPC to GDScript main thread
  - `on_stage_init(InitStage::Scene)` auto-starts the IPC server
  - `drain_ipc_requests()` / `respond_ipc()` static methods polled from `_process()`
  - Oneshot channel dispatch with 30s timeout; 10 registered IPC methods
- **`godopty schema`**: JSON Schema (draft 2020-12) and MCP tools manifest generation from clap command tree
- **MCP server**: `godopty mcp` runs over stdio, forwarding tools/list and tools/call to IPC
- **Daemon management**: `godopty daemon start/stop/status`, auto-spawn GUI on CLI use
- **PaneType enum** in `godopty-core`: Terminal, CodeViewer, FileTree, Observer with serde support
- **`parking_lot::Mutex`** for IPC statics (no poisoning overhead)

### Changed

- Binary renamed from `godopty-cli` to `godopty`
- All crate versions aligned to `0.3.0`
- CLI dependencies: replaced `regex` with `clap`, `serde_json`, `anyhow`, `dirs`

## [0.2.0] — unreleased

### Added

- Three-mode window system: decorated, borderless (with custom titlebar), fullscreen
- Drag-to-resize tile edges with 4px edge detection and cursor change
- Pane swapping: double-click title bar → popup menu to swap pane types
- Workspace Trust dialog: warns before spawning PTYs from untrusted layout files
- Window mode control in Settings UI (System tab) with debounced apply
- Window position/size persistence across decorated ↔ fullscreen transitions

### Changed

- Titlebar maximize/restore icon toggles based on current window mode
- Profile activation now checks workspace trust before restoring PTY sessions

## [0.1.0] — 2026-07-21

### Added

- Multi-PTY terminal emulator with tiling grid GUI
- `godopty-core` library: PTY spawning (`portable-pty`), ANSI parsing (`vte`), terminal grid (`alacritty_terminal`), concept pub-sub engine
- `godopty-gdext` GDExtension: `GodoptyTerminal` GodotClass with damage-tracked grid rendering
- `godopty-cli` binary: mock, `--pty`, and `--term` demo modes
- Tiling grid: split vertically/horizontally, kill, expand, and nested `SplitContainer` layout
- Pane types: terminal, code viewer (`CodeEdit`), file tree (`Tree`), observer
- Concept engine: regex triggers → labelled actions with `{payload}`/`{N}` variable substitution
- Concept capture: `UntilStop` mode buffers command output and routes to receiver panes with bidirectional handshake; prompt restoration on acknowledge
- Default concepts shipped (`concepts.default.json`) with enable/disable toggle and deep-merge migration from user overrides
- Settings persistence: cursor shape/blink/thickness, scroll sensitivity, default dimensions, font family/size, UI theme colors, color palette schemes — all auto-saved to `user://settings.json`
- Profile manager: named layout snapshots saved to `user://profiles.json`
- Layout auto-save/restore via `user://layout.json`
- Scrollback with `scroll_up`/`scroll_down`, scrollback indicator, and `Ctrl+F` regex search
- Wrapped text selection for copy/paste
- Toast notification system (info, warn, error) with replace-on-new behavior
- Centralized icon system (`icons.gd`) using Phosphor icon font
- Keyboard shortcuts: `Ctrl+N` (spawn), `Ctrl+W` (close), `Ctrl+B` (sidebar), `Ctrl+P` (command palette), `Ctrl+Shift+R` (reset)
- `Alt+Arrow` geographic pane focus navigation
- Sidebar: pane list with focus, minimize/maximize, swap, kill, and profile save/load
- Command palette with fuzzy command matching
- Title bar per pane with label prefix and action buttons
- Scrollback history stored in SQLite
- Standalone export presets (Linux, macOS, Windows) with CI release workflow
- 60 Rust tests (core + integration) and 40+ GDScript unit/integration tests

[0.3.0]: https://github.com/godopty/godopty/releases/tag/v0.3.0
[0.2.0]: https://github.com/godopty/godopty/releases/tag/v0.2.0
[0.1.0]: https://github.com/godopty/godopty/releases/tag/v0.1.0
