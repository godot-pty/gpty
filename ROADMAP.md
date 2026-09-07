# Roadmap

The source of truth for all gpty features — past, present, and planned.
GitHub Issues are used for user-reported bugs and discussions, not roadmap tracking.

Strategic direction: gpty evolves from a multi-terminal emulator into an Agent Development Environment (ADE) — a graphical PTY foundation with a public, agent-facing API. Boundary rules and non-goals live in AGENTS.md under "ADE Architecture Boundary"; this file tracks the release plan.

## Future

- [ ] Dynamic Shaders — GPU shader-based visual effects for terminal backgrounds and overlays (CRT scanlines, glassmorphism, noise)
- [ ] Reactive Environments — ambient visual feedback triggered by concept engine events (e.g., red tint when a test fails, green particles on build success)
- [ ] Inspector / Reasoning follow-ups — host-tools bridge and OpenAI-compatible HTTP still planned. Provider-specific CLI adapters follow the v0.5.2 generic `CliBackend` lane: documented hooks/extensions only, never token reuse or TUI scraping.
- [ ] FFI fuzz testing — automated fuzz testing of the terminal grid's binary interface to catch crashes and security issues
- [ ] Instanced-quad renderer (alacritty-style glyph atlas + per-instance color) — evidence-gated: revisit only if render batching plus flood rate-limiting still shows frame-time pain. Godot already GPU-composites the canvas; a full Rust-side texture pipeline is deep custom work (atlas management, eviction, per-cell truecolor uploads) for a small incremental gain.
- [ ] Rust-side IPC param validation — deserialize and validate IPC request params in Rust (`gpty-ipc`) before queuing to GDScript; GDScript handlers remain untyped. (TEMP1 P2 carryover.)
- [x] Palette test dedup — `test_palette.gd` now asserts against `PaneTypes.build_palette_commands()`; the command list lives in one place. (TEMP1 test-hygiene carryover.)

## v1.0.0 — Public Launch

- [ ] Distribution — install.sh, Homebrew tap, AUR, winget (promoted from Future: launch blockers), and GitHub releases.
- [ ] Code signing — macOS notarization + Windows Authenticode (promoted from Future: SmartScreen/Gatekeeper warnings are launch-killers).
- [ ] Docs — agent guide, plugin authoring guide, socket API reference (from the existing schema generator), 60-second quick start.
- [ ] Community infrastructure — plugin registry live, examples repo, community channel.
- [ ] Launch criteria — 3+ first-class agent adapters, 10+ example plugins, the reference workflow demo (agent runs tests in a pane while the user watches in the GUI), and a working headless reattach story — all verified before the public launch post.

## v0.6.0 — Headless Daemon & Reattach

- [ ] `gptyd` extraction spike — move `WorkspaceEngine` + `IpcServer` + event socket into a standalone Rust daemon; the Godot app becomes a rendering client over the same JSON-RPC (Godot-headless mode is the interim only, not the destination). PTYs survive GUI close.
- [ ] Grid wire protocol — `term_get_diff` / `term_input` over the socket, reusing `TermGrid`'s packed flat arrays as the wire format.
- [ ] Attach/reattach — GUI close leaves the daemon running; reopen attaches to the live workspace; `gpty attach` over SSH; `HistoryStore` serves pane read and scrollback across restarts.

## v0.5.3 — Plugin Ecosystem

- [ ] Plugin manifest — `gpty-plugin.toml` (id, name, version, min_gpty_version, platforms, build/startup commands, actions, events, link handlers) plus gpty-native `[[concepts]]` and `[[profiles]]` sections so a plugin can be pure JSON — zero code.
- [ ] Plugin install & lifecycle — `gpty plugin install <owner>/<repo>@ref` (clone, manifest validation with size/count/path caps, review dialog reusing the Workspace Trust pattern, pinned revision, per-plugin log dir) and `list` / `enable` / `disable` / `run` / `logs`. The entire CLI is the plugin API (`GPTY_BIN_PATH`); commands are argv arrays, never shell-evaluated.
- [ ] `cli_view` pane — runs a command and streams stdout into a pane body: plugin UI v1 without a Godot SDK. Native third-party GDScript/Rust pane plugins deferred to a future SDK (`PaneTypes.ALL` is the layout-trust anchor; see AGENTS.md).
- [ ] Pane contract extension — `on_agent_state_changed(state)` in `PaneBody` for custom panes.
- [ ] Plugin registry — JSON index repo + browse page on the docs site; submission by PR.
- [ ] God-object split — split `workspace.gd` (1034 lines) / `terminal_pane.gd` (833) / `terminal_manager.gd` (624) into focused files (IPC dispatch, profile/layout restore, search subsystem); concept routing already lives in `concept_router.gd`. Do it alongside the plugin work, which touches `workspace.gd` heavily. (TEMP1 modularization carryover.)

## v0.5.2 — Agent State & Adapters

- [ ] AgentState model — `AgentState` enum (Idle / Working / NeedsAttention / Completed / Failed) in `gpty-core`, with tiered detection: Tier 1 capability-authenticated events (authoritative), Tier 2 OSC state declaration (published standard; AGENTS.md constraints), Tier 3 regex/idle/exit heuristics (display-only). No `ToolRunning`-via-exit-code — foreground-command exits are not reliably attributable in a PTY.
- [ ] Titlebar state badges — Phosphor status badges on pane titlebars in `terminal_pane.gd` (pulsing amber = NeedsAttention, spinner = Working, check = Completed, warning = Failed). Display only; badge state never feeds decisions.
- [ ] Generic event vocabulary — adapter-neutral event names (`agent.started`, `turn.started`, `tool.call`, `thinking.delta`) mapped from the OMP extension's allowlist; Reasoning consumes the generic contract. Same commit: update the AGENTS.md OMP-only data-flow diagram.
- [ ] Windows event listener — named-pipe event listener closes the Unix-only gap (`omp_events.rs`); Reasoning stops being fail-closed on Windows.
- [ ] Generic CLI backend — `CliBackend` in `gpty-ai` (subprocess NDJSON bridge) beside Mock/Omp, with a backend/model picker in Inspector pane settings. Adapters use only each CLI's documented hooks — never tokens, never TUI scraping.
- [ ] Visual Concept Graph — build concept automations visually using Godot's GraphEdit node editor. Drag-and-drop nodes for triggers, conditions, and actions without writing regex by hand. (Deferred from v0.5.0.)
- [x] In-app update checker — checks GitHub releases on startup and toasts when an update is available. Fixed the placeholder repo owner, sourced the current version from `GptyTerminal.get_app_version()`, gated on `OS.has_feature("editor")` (headless/test-safe), added the `check_updates` setting, and covered `_is_newer` with GUT tests. (Deferred from v0.5.0.)
- [x] App version & build info — Settings gains an About tab showing `gpty v<get_app_version()>`, the pinned IPC protocol version, and the repo URL; the status bar shows the live version as the rightmost entry. (Deferred from v0.5.0.)
- [ ] Render batching — merge consecutive same-attribute cell runs into single draw calls (glyph-run batching) in `terminal_pane.gd` `_draw()`, cutting the per-frame canvas-item count; measure frame time under flood output and scroll before/after. (Deferred from v0.5.0.)
- [ ] UI Thread DoS mitigation — rate-limit terminal rendering when a PTY floods output (e.g., `cat /dev/urandom`), preventing the UI thread from locking up. (Deferred from v0.5.0.)
- [ ] Terminal mouse reporting — forward mouse events to the PTY when apps enable tracking (DECSET 1000/1002/1006, SGR-encoded), so herdr's built-in pop-ups, lazygit, and nvim mouse mode work inside panes. Mode state comes from `alacritty_terminal`; UI selection/scroll behavior unchanged when reporting is off.

## v0.5.1 — Persistence

- [ ] SQLite + FTS5 history backend — wire the existing `HistoryStore` (SQLite + FTS5, tested but unused in production) into pane lifecycle and session restore. Scrollback is currently lost on restart; this makes it persistent and full-text searchable, and backs `paneRead` across restarts.
- [ ] Tab/workspace switching — switch between independent sets of panes within the same window. Each workspace has its own layout, profile, and scrollback. Deferred from v0.3.0; prerequisite for the daemon-era workspace model.
- [ ] Scrollback restore on restart — reload persisted history lines by `attachment_id` when a pane reopens, so scrollback survives restarts (builds on the v0.5.0 stable public pane IDs).
- [ ] History full-text search — surface the FTS5 store's `search()` in the terminal search UI so old output stays findable after restart.
- [ ] History retention setting — `cfg_history_lines` (default 10 000) clamping the per-pane cap.
- [ ] Live pane-API smoke — exercise the v0.5.0 surface end-to-end against a running GUI: `new-pane` → `inject` → `pane-read` → `pane-wait` → `broadcast` over tagged panes, plus `pane-status` exit codes from `pane-run`. Unit/GUT covered but never smoke-tested live.

## v0.5.0 — ADE Foundation

- [x] Rebranding & positioning — README, docs landing, and CLI copy reposition gpty as an ADE ("graphical ADE: a PTY foundation with a public API"). De-OMP the shipped defaults: "OMP Workspace" profile renamed to "Agent Workspace"; `@gpty/omp-events` remains the first adapter, not the identity. Name stays `gpty` (positioning, not renaming). Same commit: updated every "OMP Workspace" reference in AGENTS.md (structure comment + Inspector/Reasoning section) and the docs site.
- [x] Ecosystem presets — shipped profiles for herdr, lazygit, nvim, claude, and OMP in `profiles.default.json`, backed by per-tile `command` support in profile restore (`command` > legacy `shell` > default, all through `sanitize_shell`).
- [x] Stable public pane IDs — every pane auto-generates a persisted `attachment_id` (`pane-XXXXXXXX` via `PaneTypes.generate_attachment_id()`, `PaneBody.apply_settings` choke point); `newPane` returns it and `listPanes` reports `id` alongside the display `label`. AGENTS.md attachment-id bullet documents the public-id semantics.
- [x] Pane env markers — `GPTY_ENV=1` + `GPTY_PANE_ID` injected as trusted runtime vars at spawn (`start_shell` pane_id param; `GPTY_PANE_ID` falls back to the per-PTY session id); both keys blocked from untrusted env. AGENTS.md env-sanitization bullet updated with the new trusted vars.
- [x] Pane read/status/run/wait IPC — `paneRead` (plain text from grid + scrollback, capped), `paneStatus` (pid / running / exit_code / idle_ms primitives), `paneRun` (command spawn; exit via `paneStatus`), `waitForOutput` (`paneWait`: server-held response, Rust `regex` scan of a 512-line ring buffer, 60 s deadline). Substrate primitives only — no agent state machine in core.
- [x] Event subscription — `subscribe` / `eventsPoll` on the event socket (never the control socket); bounded per-subscriber queues fed by `GptyTerminal.emit_event` from concept matches and pane spawn/kill. Push transport deferred.
- [x] Agent skill — ship `skills/gpty/SKILL.md` + `gpty --skill` printing the release-matched copy (`include_str!`), with a `GPTY_ENV=1` guardrail; install locations documented for Claude Code, codex, opencode, and OMP. MCP schema verified free of a `skill` tool.
- [x] IPC version sourcing — the IPC `version` response now comes from the crate via the static `GptyTerminal.get_app_version()` (`env!("CARGO_PKG_VERSION")`, `crates/gpty-gdext/src/lib.rs`); `workspace.gd` no longer hardcodes "0.3.0". (TEMP1 carryover.)
- [x] MCP expansion — `pane-read`, `pane-status` (no-arg = agent-status-list), `pane-run`, `pane-wait`, `broadcast` (tagged fan-out) auto-generated from the new CLI commands; pane tags persist and sanitize like `attachment_id`. AGENTS.md MCP list updated (14 → 19).
- [x] ADE boundary & security rules in AGENTS.md — layer model, non-goals, and OSC/plugin/broadcast constraints (the "why not" record).

## v0.4.0 — Inspector & Reasoning

- [x] Inspector pane — private, tool-free, iterative OMP Q&A via a session-owned `GptyAi` (`session_open` / `session_prompt` / `session_poll` / `session_cancel` / `session_close`); does not attach to a terminal-hosted OMP TUI; pane `backend` setting (default `omp`)
- [x] Reasoning pane — passive projection of documented OMP reasoning from one terminal, selected by `source_attachment_id`; never starts jobs or accepts concept captures
- [x] OMP event channel — second local socket (`gpty-events.sock`) accepting only `ompEvent`, authenticated with a per-PTY capability injected at spawn; shipped `@gpty/omp-events` extension dormant unless all four `GPTY_EVENT_*` vars are present
- [x] "OMP Workspace" profile — shipped built-in (Terminal + Inspector + Reasoning), never written to the user store and not deletable
- [x] Stable pane `attachment_id` — persisted companion links across save/restore (not ephemeral labels like `T1`)
- [x] Safe Markdown rendering — CommonMark/GFM converted to sanitized Godot BBCode in Rust; render-debounced streams; code-viewer rendered/source toggle

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
