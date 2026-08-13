# Changelog

Log all notable changes to the project. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).


## [Unreleased]

### Added

- IPC hardening — optional `GPTY_SECRET` shared-secret authentication for the IPC channel; mismatched or missing secrets are rejected with `-32001`
- IPC hardening — request-size cap (64 KiB, `-32600` on overflow) and connection cap (16 concurrent, 30 s timeout) on the IPC server
- Workspace cleanup script — `scripts/clean` removes stale IPC sockets (skipping live listeners), Godot import caches, and standalone `dist/` outputs; `--dry-run` preview and `--all` deep mode; user data never touched

### Changed

- Default IPC socket path moved from `/tmp/gpty.sock` to a per-user runtime directory (`$XDG_RUNTIME_DIR/gpty.sock`, fallbacks `/run/user/<uid>/gpty.sock` and `/tmp/gpty-<uid>.sock`; macOS `$TMPDIR`); the socket file is chmod 0600 and cross-UID peers are rejected on Linux/macOS
- `gpty daemon` auto-spawn no longer launches a second GUI when the running one requires authentication; `daemon status` reports the auth state

### Fixed

- Keyboard — printable keys no longer collide with special-key scancodes in the Godot→evdev mapping (`z`/`Z` sent a keypad-multiply sequence, `;` `<` `=` `>` `?` `@` sent F1–F6, `` ` `` sent keypad-enter); they now reach the shell as themselves
- Terminal shortcuts documented — `Ctrl+V` is passed through to the shell as a literal `^V` (readline quoted-insert, vim visual-block); paste remains `Ctrl+Shift+V`
- Shortcut decoupling — `Ctrl+Shift+C` is now copy-only (silent no-op without a selection); code-viewer spawn moved to `Ctrl+Shift+D`. The dual copy-or-spawn binding is gone.

[unreleased]: https://github.com/godot-pty/gpty/compare/v0.3.1...HEAD

## [0.3.1] — 2026-08-12

### Added

- `gpty concept list` / `gpty concept toggle` CLI subcommands for managing concept automations
- `concept-list` / `concept-toggle` MCP tools exposing concept management to AI agents
- Pre-push CI gate — git hooks (pre-commit, commit-msg, pre-push) and the local `scripts/ci-check` runner
- Windows compile check in CI — a `rust-windows` job on windows-latest, so platform-specific errors surface on push, not at tag time

### Changed

- MCP tool schemas tightened; nested `daemon` and `layout` subcommands flattened into prefixed tools; `mcp.json` added at the repo root for coding-harness auto-discovery
- Documentation restructured — crate READMEs nested under Overview in the docs sidebar, dev setup consolidated into CONTRIBUTING.md, gPTY naming made consistent

### Fixed

- Windows release build — the IPC server now serves per-connection named-pipe instances (`connect()` per instance) instead of the nonexistent `accept()`; fixes the v0.3.0 Windows build failure
- Concept startup race — concepts pushed via `ClassDB.instantiate` on the first frame instead of a dummy `GptyTerminal` whose `#[func]` calls silently no-op'd
- Concept capture — `UntilStop` mode triggers from PTY output rather than stdin echo; capture-only concepts with an empty `cmd` are honored
- Concept enable/disable toggle applies state correctly
- Concepts cross the gdext FFI boundary as JSON strings, bypassing the `Array[Dictionary]` marshaling bug
- Terminal copy/paste — `Ctrl+Shift+V` paste restored, `Ctrl+Shift+C` copy exempt from the ShortcutManager intercept, code viewer spawn moved to `Ctrl+Shift+C`
- MCP kebab-case tool names mapped to camelCase IPC methods; daemon tools handled locally
- Pane resize cascade — no-op `resize_grid` skipped when dimensions are unchanged, removing the scroll-through-history artifact when panes close

[0.3.1]: https://github.com/godot-pty/gpty/releases/tag/v0.3.1

## [0.3.0] — 2026-08-09

### Added

- CLI binary (`gpty`) for pane control over JSON-RPC IPC via Unix socket / named pipe
- IPC bridge: Rust `IpcServer` ↔ GDScript polling via `drain_ipc_requests`/`respond_ipc`
- `gpty new-pane`, `list-panes`, `kill-pane`, `focus-pane`, `inject` subcommands
- `gpty layout save/load/list` for named workspace profiles
- MCP server (`gpty mcp`) — Model Context Protocol over stdio for AI tool integration (tools/list, tools/call, initialize)
- Daemon mode (`gpty daemon start/stop/status`) — CLI auto-spawns GUI if not running via `GPTY_GUI`
- JSON Schema generation (`gpty schema`) for AI tool discovery (`--format json-schema` and `--format mcp`)
- `gpty-ipc` crate: shared IPC protocol, client, server, and platform transport
- `gpty --version` reports protocol version

### Changed

- Reset button moved from between Settings and Profiles to below the pane list, with red destructive styling
- Settings and Reset buttons decouple Phosphor icon rendering from ASCII text using Label+HBox pattern
- "New:" pane button label renamed to "Add Pane:" with updated styling

[0.3.0]: https://github.com/godot-pty/gpty/releases/tag/v0.3.0

## [0.2.0] — 2026-08-08

### Added

- Three-mode window system: OS decorated, borderless windowed, fullscreen — all with custom titlebar in non-OS modes
- Per-pane titlebar buttons: minimize, position-swap (shows popup to swap with another pane), type-swap (changes pane type), settings, close
- Sidebar pane rows with full action button set matching the titlebar
- Bottom status bar showing active pane info, FPS/ms, and window mode indicator
- "Show titlebar" toggle in Settings → System to hide per-pane titlebars
- Window mode dropdown in sidebar and Settings panel, synced via shared `WINDOW_MODE_LABELS`
- Auto-spawn one terminal on first launch (no saved layout)
- Workspace Trust dialog: warns before restoring layouts saved with a different shell

### Changed

- System tab moved to first position in Settings panel
- Window mode dropdown labels unified to "OS" / "Windowed" / "Windowless"
- FPS/metrics moved from sidebar to bottom status bar
- Sidebar "Add Pane" dropdown replaced with 4 icon buttons per pane type + "+16" bulk spawn via command palette
- Titlebar mode-toggle button removed; mode switching via sidebar/settings dropdown only
- `_toggle_borderless` shortcut (Ctrl+Shift+F11) and `_toggle_custom_window_mode` removed

### Fixed

- Layout persistence: save on `_exit_tree()` instead of unreliable `WM_CLOSE_REQUEST`
- Window mode persisted correctly on restart (was silently defaulting to 0)
- Settings persisted on exit (were not saved in `_exit_tree`)
- Window mode application order: always reset to `WINDOW_MODE_WINDOWED` before applying target mode
- Titlebar Phosphor icon rendering via `Label` child nodes
- Profile trust dialog no longer shows redundant "replace layout?" confirmation
- `as` keyword renamed to `adj_saved` in terminal_manager.gd
- Titlebar drag-to-move: background and label `mouse_filter` set to `IGNORE`

[0.2.0]: https://github.com/godot-pty/gpty/releases/tag/v0.2.0

## [0.1.0] — 2026-07-21

### Added

- Multi-PTY terminal emulator with tiling grid GUI
- `gpty-core` library: PTY spawning (`portable-pty`), ANSI parsing (`vte`), terminal grid (`alacritty_terminal`), concept pub-sub engine
- `gpty-gdext` GDExtension: `GptyTerminal` GodotClass with damage-tracked grid rendering
- `gpty-cli` binary: mock, `--pty`, and `--term` demo modes
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

[0.1.0]: https://github.com/godot-pty/gpty/releases/tag/v0.1.0
