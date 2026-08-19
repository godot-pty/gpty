# Roadmap

The source of truth for all gpty features — past, present, and planned.
GitHub Issues are used for user-reported bugs and discussions, not roadmap tracking.

## Future

- [ ] Package-managed installs — distribute gpty through system package managers (AUR, apt, dnf, Flatpak) for native installation and updates
- [ ] macOS code signing + notarization — sign and notarize the macOS .app bundle to satisfy Gatekeeper requirements
- [ ] Windows code signing — Authenticode sign the Windows .exe to avoid SmartScreen warnings
- [ ] Dynamic Shaders — GPU shader-based visual effects for terminal backgrounds and overlays (CRT scanlines, glassmorphism, noise)
- [ ] Reactive Environments — ambient visual feedback triggered by concept engine events (e.g., red tint when a test fails, green particles on build success)
- [ ] Inspector / Reasoning follow-ups — host-tools bridge and OpenAI-compatible HTTP still planned. Claude/Gemini adapters only after OMP is stable, using each CLI's documented hooks (never token reuse or TUI scraping).
- [ ] FFI fuzz testing — automated fuzz testing of the terminal grid's binary interface to catch crashes and security issues

## v0.4.0

- [x] Inspector + Reasoning panes — private tool-free OMP Q&A and passive documented-reasoning projection, with a dedicated event socket and `@gpty/omp-events` extension
- [ ] SQLite + FTS5 history backend — wire the existing `HistoryStore` (SQLite + FTS5, tested but unused in production) into pane lifecycle and session restore. Scrollback is currently lost on restart; this makes it persistent and full-text searchable.
- [ ] Tab/workspace switching — switch between independent sets of panes within the same window. Each workspace has its own layout, profile, and scrollback. Deferred from v0.3.0.
- [ ] Visual Concept Graph — build concept automations visually using Godot's GraphEdit node editor. Drag-and-drop nodes for triggers, conditions, and actions without writing regex by hand.
- [ ] In-app update checker — check for new GitHub releases on startup and notify users when an update is available
- [ ] App version & build info — display the running app version (matching `gpty version` and the IPC protocol version) and build information in the app UI, e.g. in Settings or an About dialog
- [ ] GPU-accelerated rendering — rasterize terminal cells to a single GPU texture using fontdue for glyph rasterization, replacing the per-cell GDScript `_draw()` loop
- [ ] UI Thread DoS mitigation — rate-limit terminal rendering when a PTY floods output (e.g., `cat /dev/urandom`), preventing the UI thread from locking up

## v0.3.2 — Security Hardening & Test Coverage

- [x] IPC security — peer-UID check, optional `GPTY_SECRET`, request/connection caps, and client-side `GPTY_SOCKET`/`GPTY_GUI` validation against env hijacking
- [x] Concept engine security — shell-quoted template substitution, parse caps (count, lengths, timeout clamp), line and capture bounds
- [x] PTY env sanitization — dynamic-loader variable blocklist applied at spawn
- [x] Layout restore trust — tile validation, typed settings application, absolute pane paths
- [x] Workspace cleanup script — `scripts/clean` removes stale sockets, import caches, and build outputs
- [x] Standalone app builder — `scripts/build` produces a runnable bundle for the host platform
- [x] Documentation overhaul — MCP integration, crate README accuracy, testing guide with explicit gaps
- [x] Test coverage expansion — capture lifecycle, CLI mock-server roundtrips, concept routing, gdext FFI smoke

## v0.3.1 — Stability & Windows Support

- [x] Windows named-pipe IPC — per-connection named-pipe instances on the server (v0.3.0 never compiled on Windows); local cross-check via xwin/clang-cl plus the CI `rust-windows` job keeps it green
- [x] Concept engine reliability — startup registration race fixed (`ClassDB.instantiate` on first frame), `UntilStop` capture triggers from PTY output, capture-only concepts with empty `cmd` supported
- [x] Concept management via CLI and MCP — `gpty concept list` / `gpty concept toggle` plus matching `concept-list`/`concept-toggle` MCP tools
- [x] Release-quality CI gate — pre-push git hooks, local `scripts/ci-check` runner, and a Windows compile job catching platform breakage before tagging
- [x] Documentation hub — docs sidebar restructure (crate READMEs under Overview), dev setup consolidated into CONTRIBUTING.md

## v0.3.0 — CLI & AI Integration

- [x] CLI binary (`gpty`) — control a running GUI over JSON-RPC IPC. Supports new-pane, list-panes, kill-pane, focus-pane, inject, and layout management. Auto-spawns the GUI daemon if it's not already running.
- [x] MCP server — Model Context Protocol integration. Run `gpty mcp` to expose terminal workspace control as tools for AI agents (Claude, Gemini, etc.). Agents can spawn panes, inject text, and manage layouts.
- [x] Daemon mode — CLI lifecycle management for the GUI. `gpty daemon start|stop|status` starts, stops, or checks the running GUI process.
- [x] JSON Schema — `gpty schema` outputs a JSON Schema describing all CLI commands and their parameters. `--format mcp` produces an MCP tools manifest. Enables AI tool discovery without hardcoded manifests.
- [x] IPC bridge — Rust `IpcServer` on a background tokio task accepts Unix socket connections, parses JSON-RPC, and queues requests. GDScript polls `drain_ipc_requests()` each frame and dispatches to workspace methods, then responds via `respond_ipc()`.

## v0.2.0 — UI/UX

- [x] Standalone export — first CI release producing self-contained binaries for Linux, macOS, and Windows. No Godot editor or Rust toolchain required to run — just download and launch.
- [x] Full-screen mode — three window modes: OS-decorated, borderless, and fullscreen. Custom-drawn titlebar with minimize, maximize/restore, and close buttons. Toggle via sidebar or keyboard shortcut.
- [x] Pane position and type swapping — swap panes between grid positions or change a pane's type (terminal ↔ code viewer) via sidebar buttons and popup menus.
- [x] Drag-to-resize tile edges — drag the splitter handles between panes to resize grid columns and rows. Built on Godot `HSplitContainer`/`VSplitContainer` with a Rust tile layout engine enforcing minimum sizes.
- [x] Session auto-save — layout and pane state persist across application restarts. PTY sessions are recreated with fresh shells on relaunch (process state and scrollback are not restored — see the v0.4.0 SQLite history item).
- [x] Workspace Trust — layouts loaded from external sources show a confirmation dialog before spawning PTY processes. Prevents malicious layout files from executing arbitrary commands.

## v0.1.0 — Core Engine

- [x] Multi-PTY terminal emulator — spawn and manage multiple shell sessions in a tiling grid. Each session is an independent PTY with its own shell process, environment, and working directory.
- [x] Tiling grid layout — split panes horizontally or vertically, resize by dragging splitter handles. Built on a Rust tile layout engine that enforces minimum pane dimensions and redistributes space when panes are added or removed.
- [x] ANSI/vte parsing — full SGR color and cursor positioning via alacritty_terminal. Handles 16-color, 256-color, and true color (24-bit) sequences. Strips escape sequences for concept matching.
- [x] Concept engine — regex-based trigger/action matching with label routing. Every line of PTY output is tested against registered concept patterns. Matching lines broadcast events on a pub-sub channel; panes with matching labels execute the associated action.
- [x] SingleLine capture mode — each matching line triggers an event on the pub-sub channel. Receiving panes inject the action's command template into their PTY stdin, enabling cross-pane automation.
- [x] Settings persistence — font size, cursor shape, window mode, and other preferences saved to `user://settings.json`. Settings auto-load on startup and auto-save on change via a debounced save timer.
- [x] Phosphor icon set — 100+ icons for toolbar, sidebar, and pane action buttons. Unicode PUA codepoints rendered via the bundled Phosphor Regular font. Icons are exposed as `const` strings in `icons.gd`.
- [x] Sidebar with pane list — collapsible left panel showing all tiles with focus, kill, minimize, and swap buttons per pane. Also exposes window mode toggle and per-pane-type spawn buttons.
- [x] Control-based renderer — terminal grid drawn in GDScript via `_draw()`. Rust packs cell data (chars, foreground, background, attributes) into flat arrays; GDScript unpacks and renders them line-by-line with damage tracking for incremental updates.
