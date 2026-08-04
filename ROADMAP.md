# Roadmap

Planned features for future releases. Tracked in detail via [GitHub Issues](https://github.com/godopty/godopty/issues).

## v0.2.0 — UI/UX

- [x] Standalone export — first successful CI release for Linux, macOS, Windows
- [x] Full-screen mode — decorated, borderless, and fullscreen with custom titlebar
- [x] Drag-and-drop pane swapping
- [x] Drag-to-resize tile edges
- [x] Session auto-save — restore PTY sessions with scrollback on relaunch
- [x] Workspace Trust — warn before spawning PTY from untrusted layout files

## v0.3.0 — CLI & AI Integration

- [ ] CLI binary — `godopty` for pane control, IPC via Unix socket / named pipe
- [ ] MCP server — Model Context Protocol integration for Gemini CLI
- [ ] Daemon mode — CLI spawns GUI if not running
- [ ] JSON Schema — `godopty schema` for AI tool discovery
- [ ] Tab/workspace switching — multiple named workspaces per session

## v0.4.0

- [ ] SQLite + FTS5 history backend — infinite scrollback with full-text search
- [ ] Visual Concept Graph — build concept automations visually using Godot's GraphEdit
- [ ] In-app update checker
- [ ] GPU-accelerated rendering — rasterize grid to single texture (fontdue)
- [ ] UI Thread DoS mitigation — frame-rate cap against PTY flood

## Future

- [ ] Package-managed installs (AUR, apt, dnf, Flatpak)
- [ ] macOS code signing + notarization
- [ ] Windows code signing
- [ ] Dynamic Shaders — CRT effects, glassmorphism
- [ ] Reactive Environments — tint on panic, particles on success
- [ ] Native AI Observer Pane — LLM API queries, Markdown rendering
- [ ] FFI fuzz testing — garbage binary data into `TermGrid::feed()`
