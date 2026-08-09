# Roadmap

Planned features for future releases. Tracked in detail via [GitHub Issues](https://github.com/godot-pty/gpty/issues).

## Future

- [ ] Package-managed installs (AUR, apt, dnf, Flatpak)
- [ ] macOS code signing + notarization
- [ ] Windows code signing
- [ ] Dynamic Shaders — CRT effects, glassmorphism
- [ ] Reactive Environments — tint on panic, particles on success
- [ ] Native AI Observer Pane — LLM API queries, Markdown rendering
- [ ] FFI fuzz testing — garbage binary data into `TermGrid::feed()`

## v0.4.0

- [ ] SQLite + FTS5 history backend — infinite scrollback with full-text search
- [ ] Tab/workspace switching — multiple named workspaces per session (deferred from v0.3.0)
- [ ] Visual Concept Graph — build concept automations visually using Godot's GraphEdit
- [ ] In-app update checker
- [ ] GPU-accelerated rendering — rasterize grid to single texture (fontdue)
- [ ] UI Thread DoS mitigation — frame-rate cap against PTY flood

## v0.3.0 — CLI & AI Integration

- [x] CLI binary — `gpty` for pane control, IPC via Unix socket / named pipe
- [x] MCP server — Model Context Protocol integration for Gemini CLI (`gpty mcp`)
- [x] Daemon mode — CLI spawns GUI if not running (`gpty daemon`)
- [x] JSON Schema — `gpty schema` for AI tool discovery
- [x] IPC bridge — Rust server ↔ GDScript polling via `drain_ipc_requests`/`respond_ipc`

## v0.3.1

- [ ] 


## v0.2.0 — UI/UX

- [x] Standalone export — first successful CI release for Linux, macOS, Windows
- [x] Full-screen mode — decorated, borderless, and fullscreen with custom titlebar
- [x] Drag-and-drop pane swapping
- [x] Drag-to-resize tile edges
- [x] Session auto-save — restore PTY sessions with scrollback on relaunch
- [x] Workspace Trust — warn before spawning PTY from untrusted layout files

## v0.1.0 — Core Engine

- [x] Multi-PTY terminal emulator — spawn and manage multiple shell sessions
- [x] Tiling grid layout — split panes horizontally/vertically, resize by dragging
- [x] ANSI/vte parsing — full SGR color, cursor positioning via alacritty_terminal
- [x] Concept engine — regex-based trigger/action matching with label routing
- [x] SingleLine capture mode — broadcast matched lines to designated terminals
- [x] Settings persistence — font size, cursor shape, window mode saved to disk
- [x] Phosphor icon set — 100+ icons for toolbar, sidebar, and pane buttons
- [x] Sidebar with pane list — overview of all tiles, focus/kill/minimize per pane
- [x] Control-based renderer — terminal grid drawn in GDScript with CellInfo FFI
