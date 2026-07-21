# Roadmap

Planned features for future releases. Tracked in detail via [GitHub Issues](https://github.com/godopty/godopty/issues).

## v0.2.0

- [ ] Standalone export — first successful CI release for Linux, macOS, Windows
- [ ] Drag-and-drop pane swapping
- [ ] Drag-to-resize tile edges
- [ ] Session auto-save — restore PTY sessions with scrollback on relaunch
- [ ] SQLite + FTS5 history backend — infinite scrollback with full-text search
- [ ] Workspace Trust — warn before spawning PTY from untrusted layout files

## v0.3.0

- [ ] Tab/workspace switching — multiple named workspaces per session
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
