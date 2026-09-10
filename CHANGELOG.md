# Changelog

Log all notable changes to the project. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `single_line` concepts mean **notify-only**: a trigger match is published on the event socket (`{type: concept, event: matched, mode: single_line, name, source}`) and nothing else happens — no capture, no routing, no output taken from the pane. The Settings → Concepts editor offers the mode again, and hides the target and stop-condition fields for it. A missing or unknown `capture_mode` still captures. Metadata only: the matched line is never published.

### Security

- **Concept definitions can no longer execute commands.** A concept is data: a regex trigger, a stop condition, and a routing target. Until now it could also carry a command template that was written into a target pane's PTY — reachable from terminal output (any program that printed a matching line) and from a Ctrl+click on a matching line, both with no authentication, no consent prompt, and no notice. A third-party `concepts.json` was therefore arbitrary code execution with an attacker-chosen trigger, aimed at whatever pane matched, repeatable and silent; the click path shipped in v0.5.2. Removed: `command_template`, `substitute_template`, `shell_quote`, `matching_commands`, the engine's event-injection branch and the pub-sub channel that existed only to carry it, `match_concepts_on_line`, the Ctrl+click handler, and the concept label plumbing (`TerminalConfig.labels`, `labels_json`, `_concept_labels`). Legacy `cmd` keys in a user file are ignored on parse and stripped on save; the Settings → Concepts dialog no longer collects one. See [SECURITY.md](SECURITY.md) for the threat model behind the change.
- **Workspace Trust now covers everything that executes in a restored pane.** The gate compared only the legacy `shell` key, while restore consumed `command` > `shell` and passed `shell_args` and `shell_env` through untouched. A downloaded profile could therefore spawn `/bin/bash -c "curl … | sh"` (argv) or add a `command` override with no prompt at all — the argv half was the live one. The env half turned out to be unreachable: `_restore_into` applies tile settings before `apply_to_terminal`, which overwrites `shell_env` with the user's global, so a restored tile's env never reaches a child. That ordering also silently discards a user's own per-pane env on every restore; it is tracked with the v0.5.5 env model, where it must be fixed (fixing it alone would hand file-supplied env back to the attacker). `PaneTypes.tile_spawns_untrusted` checks program, argv, and environment against the user's defaults, and the workspace-restore path uses the same predicate.
- **Startup-evaluation environment variables are refused from configuration.** `PROMPT_COMMAND`, `BASH_ENV`, `ENV`, `SHELLOPTS`, `PS4`, `ZDOTDIR`, `PERL5OPT`, `PERL5LIB`, `PYTHONSTARTUP`, `NODE_OPTIONS`, `RUBYOPT`, `LESSOPEN`, `GIT_SSH_COMMAND`, `GIT_EXTERNAL_DIFF`, `GIT_PAGER`, and `PAGER` are now blocked at the spawn choke point alongside the dynamic-loader keys: a shell or the next tool runs what they contain, so a layout carrying one could otherwise get code execution without naming a command. (The restored-tile path turned out to be unreachable — see the Workspace Trust entry above — but these keys still arrive through the user's own global `shell_env`, and this list is the floor the v0.5.5 env model builds on.) Users can still set them from inside a shell.
- **The Inspector's child process no longer inherits workspace-control credentials.** The OMP and adapter children were spawned with the GUI's full environment, including `GPTY_SECRET`/`GPTY_SOCKET` (and, for a GUI started inside a pane, that pane's event capability). Both backends now strip `gpty_core::pty::STRIPPED_INHERITED_ENV_KEYS`.
- **Grid geometry from saved layouts is bounded.** `start_shell`/`resize_grid` clamped dimensions only from below and `sanitize_tile` never bounded a stored `rows`/`cols`, so a crafted tile allocated a 10¹²-cell grid at spawn. Both boundaries clamp at 500 × 2000.
- **Search results are capped.** A one-character pattern over 100 000 scrollback lines materialised every match on each keystroke and re-walked them every frame; the grid search now stops at 10 000.
- **MCP `tools/call` is restricted to advertised tools.** Any name was mapped to an IPC method, reaching methods that were never published as tools (including `shutdown`).
- **CI runs least-privilege.** `ci.yml` declares `permissions: contents: read` instead of inheriting the repository default token scope, which was handed to a third-party audit action.
- Added [SECURITY.md](SECURITY.md): threat model, reporting process, hardening that must not be weakened, and known limitations.

### Fixed

- Window titlebar controls used the wrong glyphs — maximize showed a keypad, restore a phone, and the window-mode picker a folder. They now render arrows-out / arrows-in / monitor (codepoints verified against the bundled font).

## [0.5.2] — 2026-09-09

### Added

- Agent-state detection — a display-only `AgentState` (idle/working/needs-attention/completed/failed) per terminal with tiered detection: Tier 1 accepts capability-authenticated events (authoritative: `agent.started` → working, `agent.settled` → completed, tool errors → needs-attention, session end → idle); Tier 2 accepts the published `gpty_state=<value>` OSC declaration (whitelisted, single-shot, rate-limited, alt-screen/capture-replay/resize suppressed); Tier 3 adds conservative failure regex patterns with 60 s TTL decay and non-zero shell exits. The state and its detection tier surface through `pane-status` (`agent_state`, `agent_state_tier`).
- Generic event vocabulary — the event socket translates the OMP extension's wire names to adapter-neutral names at the trust boundary (`session.bound`, `agent.started`, `agent.settled`, `turn.started`, `turn.finished`, `tool.call`, `tool.finished`, `thinking.delta`); Reasoning and Tier 1 agent-state detection consume the generic contract.
- Windows event listener — the OMP event socket now serves on Windows as a named pipe (`\\.\pipe\gpty-events`) with per-PTY `GPTY_EVENT_*` injection on every platform; capability entropy comes from `getrandom` instead of `/dev/urandom`. The shipped extension still needs a named-pipe transport to use it there (ecosystem follow-up), but Reasoning is no longer fail-closed at the gPTY layer.
- CLI backend for Inspector — a `cli` backend beside `mock`/`omp`: runs a configured adapter command (argv, never shell-evaluated) as a subprocess NDJSON bridge — one JSON request line per prompt in, `thinking`/`delta`/`done`/`error`/`status` frames out. Cancelling kills the child (`kill_on_drop`, no orphans); the next prompt respawns. Inspector pane settings gain a Command row; the command persists in the layout state (sanitized like shell args).
- Titlebar agent-state badges — a Phosphor badge on each terminal titlebar mirrors the agent state: spinner (Working), check (Completed), warning (Failed), pulsing amber (NeedsAttention); hidden while Idle. Display only.
- Settings panel polish — per-tab "Reset tab to defaults" buttons (full-width, centered) replace the all-tabs reset; the color scheme row gains a reset button; every UI color gains an individual reset; Appearance color pickers gain OK/Cancel (Cancel restores the pre-open color); the Edit/Add Concept dialog opens at 90% of the settings menu width.

### Changed

- UI chrome colors (wrapper background/border, pane titlebars, sidebar, window titlebar) now live-apply to existing panes when changed — no app restart required.
- Color row labels share a fixed-width column so all color pickers align.
- The settings panel is wider and its tab font slightly smaller so all six tabs always fit without clipping into the overflow dropdown.

### Fixed

- Pane settings popup could render but ignore every click: Godot 4 GUI input picking uses reverse tree order and ignores `z_index`, so later-added workspace grids ate the popup's input. Overlays now move to the end of the tree when opened; the same fix covers the global settings panel and command palette. The palette also had its first toggle inverted (created visible, first press hid it).
- Pane settings popup stayed open over a killed/swapped pane and every interaction then errored on the freed body. The popup now closes on kill and type-swap and self-closes whenever its target is torn down.
- Restarted terminals showed a growing pile of old prompt lines ("as if Enter was pressed"): the plain-text parser committed a history row on every bare carriage return, and shells reprint the prompt on each resize. Bare CR no longer commits, and scrollback restore collapses runs of identical rows.


## [0.5.1] — 2026-09-09

### Added

- Persistent scrollback — the SQLite+FTS5 history store is wired into pane lifecycle, keyed by stable `attachment_id` (schema v2; pre-v2 rows dropped as unrecoverable). The newest `history_lines` rows are restored into each pane's scrollback on restart and back `pane-read` across restarts.
- `history_lines` setting — caps persisted scrollback per pane (default 10 000, clamped 100–100 000) in Settings → Terminal.
- History search — the terminal search bar gains a Live/History scope toggle; History mode runs FTS5 queries against the pane's persisted scrollback and lists matching lines (click copies to clipboard).
- Workspaces — named pane sets (up to 8) with keep-alive panes: switching hides/shows grids instead of killing PTYs, so background commands keep running. Add/switch/close/rename via the sidebar's Workspaces section (`Ctrl+PageUp`/`Ctrl+PageDown` to switch); saved to `user://workspaces.json`, with one-shot migration of the legacy `layout.json` (replaces the `LayoutManager` autoload). Concept captures and agent events keep routing from hidden workspaces.
- Sidebar polish — content margins (right ≈ scrollbar width), measured section heights that never truncate rows, icon+text action buttons (Settings/Reset/Search), and active-row accents across the workspaces, profiles, and panes sections.
- Profile rename — double-click a user profile in the sidebar to rename it inline (persisted, dedupe-suffixed like profile creation).
- Live pane-API smoke — `scripts/smoke-pane-api` boots the GUI headless with sandboxed user data and drives new-pane, pane-status, inject, pane-wait, pane-read, broadcast, pane-run (exit code), and kill-pane end-to-end, plus the event socket's `subscribe`/`eventsPoll` fan-out; wired into `ci-check` and the CI `gut-tests` job.

### Changed

- History retention trims the oldest rows beyond `history_lines` amortized over every 100 committed lines.
- `start_shell` no longer attaches a history store keyed by the per-node `id` counter (rows collided across panes and orphaned across restarts).
- `pane-run` executes commands through the configured shell (`<shell> -c <command>`) — compound commands (`&&`, pipes, globs) now work; the command is passed as a sanitized argument (`shell_args`), never as the program itself. Empty commands are rejected.
- Clicking any pane makes it the active pane — the status bar and sidebar accent follow. Only terminals take keyboard focus; read-only panes (Reasoning, code viewer, file tree) swallow keys, so typing no longer reaches a terminal you just left.
- New workspaces start as a blank slate instead of auto-spawning a terminal.

### Fixed

- Pane API unreachable: `pane-read`, `pane-status`, `pane-run`, `pane-wait`, and `broadcast` were never registered on the GUI IPC server, so every CLI call returned `Unknown method`.
- Targeted pane API calls always failed with "not found": `paneRead`/`paneStatus`/`paneWait` guarded on `has_method("_terminal")`, but `_terminal` is a property, not a method. Guards now check `is TerminalPane`.
- Toasts rendered half-hidden under the status bar — they now float above it.
- The docs site could bake Hugo's own README as the project overview — the deploy now extracts only the `hugo` binary and smoke-checks the baked overview.

## [0.5.0] — 2026-09-03

### Added

- ADE repositioning — gpty is now positioned as a graphical Agent Development Environment: a PTY foundation with a public, agent-facing API. README, docs site, and CLI copy updated; the shipped "OMP Workspace" profile is now "Agent Workspace" (attachment ids unchanged).
- Ecosystem presets — built-in profiles for herdr, lazygit, nvim, claude, and OMP, backed by per-tile `command` support in profile restore (every command routed through `sanitize_shell`).
- Pane env markers — `GPTY_ENV=1` and `GPTY_PANE_ID` injected as trusted runtime vars at spawn (blocked from untrusted env), so agents inside a pane can prove where they are.
- Stable public pane IDs — every pane gets a persisted `attachment_id` (auto-generated when absent); `new-pane` returns it and `list-panes` reports `id` plus the display `label`. Targeting accepts either.
- Pane API — `pane-read` (plain-text screen plus scrollback), `pane-status` (pid, running, exit code, idle time; no argument lists every pane), `pane-run` (spawn a command), and `pane-wait` (waitForOutput: server-held wait on a Rust `regex` scan of recent output, up to 60 s).
- Event subscriptions — `subscribe` / `eventsPoll` on the event socket for concept matches and pane spawn/kill, with bounded per-subscriber queues.
- Broadcast and pane tags — panes carry sanitized tags; `broadcast` injects text into every tagged terminal pane. MCP tools grow from 14 to 19.
- Agent skill — `skills/gpty/SKILL.md` (shipped with the CLI via `gpty --skill`) teaches coding agents the full control surface, guarded by `GPTY_ENV=1`.
- In-app update checker — startup GitHub-release check with a `check_updates` setting; notify-only and silent on failure.
- About tab — Settings shows the live app version, the pinned IPC protocol version, and the repo URL; the status bar shows the version as well.

### Changed

- The IPC `version` response is sourced from the crate (`CARGO_PKG_VERSION`) instead of a hardcoded literal.
- The palette command list lives in one place (`PaneTypes.build_palette_commands()`).
- Remote `tag_name` values are validated as semver before any display.
- Docs baseURL points at the current org; origin-story page and re-sequenced overview added.

### Fixed

- OMP `rpc_chunk` base64 decoding hardened (`as_chunks` handling).
- README build instructions corrected (`cargo build -p gpty`).
- MCP tool enumeration in the agent guide matches the shipped tools.

## [0.4.0] — 2026-08-19

### Added

- Inspector pane — private, tool-free, iterative OMP Q&A via a session-owned `GptyAi` (`session_open` / `session_prompt` / `session_poll` / `session_cancel` / `session_close`). It does not attach to a terminal-hosted OMP TUI. Set pane `backend` to `omp` (optional `GPTY_OMP`).
- Reasoning pane — passive projection of documented OMP reasoning from one terminal, selected by `source_attachment_id`. Never starts jobs or accepts concept captures.
- OMP event channel — second local socket (`gpty-events.sock`) accepting only `ompEvent`, authenticated with a per-PTY capability injected at spawn. Shipped `@gpty/omp-events` extension is dormant unless all four `GPTY_EVENT_*` variables are present.
- Shipped "OMP Workspace" profile (Terminal + Inspector + Reasoning). Built-in profiles are not written to the user store and cannot be deleted from the sidebar.
- Stable pane `attachment_id` for companion links across save/restore (not ephemeral labels like `T1`).
- Safe Markdown rendering — CommonMark/GFM is converted to sanitized Godot BBCode in Rust, Inspector/Reasoning streams are render-debounced, and Markdown files in code-viewer panes support rendered/source toggling.

### Changed

- Legacy `observer` layouts migrate before type validation: `stream=thinking` becomes Reasoning, otherwise Inspector. CLI `--pane-type observer` warns and creates Inspector. Legacy observer-target *concepts* are disabled at merge/save time rather than migrated.
- Concepts that target Inspector (`git_log`, `cargo_check`) ship disabled so captured terminal output is not sent to a model without explicit opt-in; Inspector panes additionally gate captures behind `accept_concept_captures` (default off).
- Child PTYs no longer inherit `GPTY_SECRET`, `GPTY_SOCKET`, or `GPTY_GUI`. Untrusted env cannot set `GPTY_EVENT_*` / session ids.
- Pane labels reuse the highest closed number only: `max(existing)+1` — closing the newest pane recycles its number, middle gaps are never filled.
- Reasoning turn caps are user settings (Settings → Reasoning): max turns (1–64) and max turn bytes (4 KiB–1 MiB), clamped and persisted.
- Toast notifications for unrouted captures name the source pane (`…from T1`).

### Fixed

- Concept routing now requires receivers to advertise capability and confirm delivery before captured bytes are acknowledged; Reasoning panes and failed Inspector starts fall through to another receiver or flush safely back to the terminal.
- Resize no longer triggers concept captures or toasts: `Resize` is not treated as user input for `stop_on_input`, and post-resize shell redraws are suppressed for 750 ms. Alternate-screen output (full-screen TUI redraws) is never concept-matched.
- Terminal resize hardening: transient collapsed pane sizes during split/spawn churn can no longer collapse the grid (cell-dimension floors at event and apply time); redundant SIGWINCH is skipped when dimensions are unchanged; grid growth keeps the visible text and cursor anchored (xterm-style) without ever deleting rows from alternate- or primary-screen TUIs.
- Terminal emulator answers application queries: DSR cursor-position reports and mode reports generated by the emulator are forwarded to the child PTY. Full-screen TUIs that query the cursor after SIGWINCH (e.g. the OMP TUI) now re-render in place instead of re-anchoring their transcript.
- Reasoning accordion: width is viewport-aware (scrollbar accounted for, no right-edge clipping), truncation at the turn cap re-closes Markdown code fences, and auto-follow no longer yanks the view during a deliberate scroll-up.
- Code-viewer panes clear stale content when a configured file path is invalid, and rendered Markdown documents open at the top.

## [0.3.2] — 2026-08-13

### Added

- IPC hardening — optional `GPTY_SECRET` shared-secret authentication for the IPC channel; mismatched or missing secrets are rejected with `-32001`
- IPC hardening — request-size cap (64 KiB, `-32600` on overflow) and connection cap (16 concurrent, 30 s timeout) on the IPC server
- Workspace cleanup script — `scripts/clean` removes stale IPC sockets (skipping live listeners), Godot import caches, and standalone `dist/` outputs; `--dry-run` preview and `--all` deep mode; user data never touched
- Standalone app builder — `scripts/build` produces a runnable application bundle for the host platform

### Security

- Concept command injection fixed — `{payload}`/`{N}` template values are shell-quoted (POSIX single quotes) before injection, and substitution is single-pass so payload text cannot trigger nested substitutions. Existing user templates that pre-quote values (`echo '{payload}'`) must drop their own quotes.
- Concept cost bounded — concept count (128), trigger/command lengths, action counts, and `stop_timeout_ms` are capped at parse time; output lines over 16 KiB are never regex-matched; capture buffers finalize early past 4 MiB.
- PTY env sanitized — dynamic-loader variables (`LD_PRELOAD`, `LD_AUDIT`, `LD_LIBRARY_PATH`, `DYLD_*`) and malformed keys are dropped from pane/profile envs at spawn.
- `GPTY_SOCKET`/`GPTY_GUI` hijacking mitigated — the CLI/MCP refuse insecure socket files (wrong owner or open permissions) before sending anything, and `GPTY_GUI` auto-spawn validates the binary.
- Layout restore hardened — malformed tile data (wrong types, unknown pane types, out-of-range grid geometry) is skipped or clamped instead of crashing; code viewer and file tree pane paths must be absolute.

### Changed

- Default IPC socket path moved from `/tmp/gpty.sock` to a per-user runtime directory (`$XDG_RUNTIME_DIR/gpty.sock`, fallbacks `/run/user/<uid>/gpty.sock` and `/tmp/gpty-<uid>.sock`; macOS `$TMPDIR`); the socket file is chmod 0600 and cross-UID peers are rejected on Linux/macOS
- `gpty daemon` auto-spawn no longer launches a second GUI when the running one requires authentication; `daemon status` reports the auth state
- App name displayed as gPTY across the UI, docs, and tooling
- Documentation overhaul — MCP integration section in the root README, accurate GDExtension API tables, IPC architecture and method docs, and a test-coverage guide with explicit gaps; the superseded CLI architecture plan was consolidated into the crate READMEs
- Test suite expansion — capture lifecycle extracted into a unit-testable `CaptureSession`, CLI commands round-trip against a mock IPC server, concept routing extracted into a GUT-testable `ConceptRouter`, gdext IPC tests serialized with per-test sockets, and a GDExtension FFI smoke test (135 GUT tests total)

### Fixed

- Keyboard — printable keys no longer collide with special-key scancodes in the Godot→evdev mapping (`z`/`Z` sent a keypad-multiply sequence, `;` `<` `=` `>` `?` `@` sent F1–F6, `` ` `` sent keypad-enter); they now reach the shell as themselves
- Terminal shortcuts documented — `Ctrl+V` is passed through to the shell as a literal `^V` (readline quoted-insert, vim visual-block); paste remains `Ctrl+Shift+V`
- Shortcut decoupling — `Ctrl+Shift+C` is now copy-only (silent no-op without a selection); code-viewer spawn moved to `Ctrl+Shift+D`. The dual copy-or-spawn binding is gone.
- Text selection survives modifier presses — pressing Shift/Ctrl/Alt no longer clears the current selection
- Global settings apply to every terminal, and the titlebar setting is honored in all spawn and restore paths
- Cursor blink toggle redraws the terminal immediately
- Concept editor no longer crashes when opened with an empty workspace (no terminal panes) — the Add Concept button is disabled until a terminal exists

[0.5.2]: https://github.com/godot-pty/gpty/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/godot-pty/gpty/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/godot-pty/gpty/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/godot-pty/gpty/compare/v0.3.2...v0.4.0
[0.3.2]: https://github.com/godot-pty/gpty/compare/v0.3.1...v0.3.2

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
