# Roadmap

The source of truth for all `gPTY` features; past, present, and planned.

- GitHub Issues will be used for user-reported bugs and discussions, not roadmap tracking.
- Boundary rules and non-goals live in AGENTS.md under "ADE Architecture Boundary".

## Future

- [ ] Dynamic Shaders — GPU shader-based visual effects for terminal backgrounds and overlays (CRT scanlines, glassmorphism, noise)
- [ ] Reactive Environments — ambient visual feedback triggered by concept engine events (e.g., red tint when a test fails, green particles on build success)
- [ ] Inspector / Reasoning follow-ups — host-tools bridge and OpenAI-compatible HTTP still planned. Provider-specific CLI adapters follow the v0.5.2 generic `CliBackend` lane: documented hooks/extensions only, never token reuse or TUI scraping.
- [ ] FFI fuzz testing — automated fuzz testing of the terminal grid's binary interface to catch crashes and security issues
- [ ] Instanced-quad renderer (alacritty-style glyph atlas + per-instance color) — evidence-gated: revisit only if render batching plus flood rate-limiting still shows frame-time pain. Godot already GPU-composites the canvas; a full Rust-side texture pipeline is deep custom work (atlas management, eviction, per-cell truecolor uploads) for a small incremental gain.

## v1.0.0 — Public Launch

Launch is deferred: `gPTY` stays below 1.0.0 until either the project gains a growing, active userbase or the 0.x feature-set is exhausted — code signing and broad distribution are only worth pursuing once one of those is true.

- [ ] Distribution — install.sh, Homebrew tap, AUR, winget (promoted from Future: launch blockers), and GitHub releases.
- [ ] Code signing — macOS notarization + Windows Authenticode (promoted from Future: SmartScreen/Gatekeeper warnings are launch-killers).
- [ ] Docs — agent guide, plugin authoring guide, socket API reference (from the existing schema generator), 60-second quick start.
- [ ] Community infrastructure — plugin registry live, examples repo, community channel.
- [ ] Launch criteria — first-class agent adapters, example plugins, the reference workflow demo (agent runs tests in a pane while the user watches in the GUI), and a working headless reattach story — all verified before the public launch post.

## v0.8.0 — Headless Daemon & Reattach

- [ ] `gptyd` extraction spike — move `WorkspaceEngine` + `IpcServer` + event socket into a standalone Rust daemon; the Godot app becomes a rendering client over the same JSON-RPC (Godot-headless mode is the interim only, not the destination). PTYs survive GUI close.
- [ ] Grid wire protocol — `term_get_diff` / `term_input` over the socket, reusing `TermGrid`'s packed flat arrays as the wire format.
- [ ] Attach/reattach — GUI close leaves the daemon running; reopen attaches to the live workspace; `gpty attach` over SSH; `HistoryStore` serves pane read and scrollback across restarts.
- [ ] Rust-side IPC param validation — deserialize and validate IPC request params in Rust (`gpty-ipc`) before dispatch. Promoted from Future: the daemon refactor is the natural home (Rust owns the request path end-to-end), and validating the pre-daemon GUI queue would be throwaway work. GDScript handlers remain untyped.

## v0.7.0 — Media Pane

- [ ] Media pane type — `media` in `PaneTypes.ALL`; plays local audio/video from an absolute file path validated by `sanitize_tile` (same trust rule as code_viewer/file_tree). Remote/URL streaming deferred — a separate trust boundary.
- [ ] Rust media backend — demux/decode in Rust: `symphonia` for audio; video decoding via pure-Rust codec crates or `ffmpeg` bindings (license review at design time: LGPL build vs pure-Rust). Output is packed flat arrays of decoded frames/samples — the same FFI packing pattern as the terminal grid.
- [ ] Video rendering — decoded frames uploaded as `ImageTexture` in GDScript; bounded frame queue so a high-bitrate stream cannot stall the UI thread (same discipline as PTY flood rate-limiting).
- [ ] Audio playback — decoded PCM streamed into Godot `AudioStreamGenerator`; A/V sync against the Godot clock; volume/mute controls.
- [ ] Playback controls — play/pause/seek/loop per pane; transport state surfaced through the existing `paneStatus` primitives.
- [ ] Format matrix — MP4/WebM/MKV containers, H.264/H.265/VP9/AV1 video, MP3/FLAC/Ogg/Opus audio; codec support documented per platform.
- [ ] Media security notes in AGENTS.md — media files are untrusted input: memory-safe/audited decoders only (the concept-engine ReDoS stance extended to codec parsing), demux/decode size caps, no sandboxing claims (plugin trust-model language).
- [ ] Standalone by design — ships alone with no dependency on or coupling with any other feature, so its A/V infrastructure risk gates nothing else.

## v0.6.0 — Knowledge Base & Wiki

- [ ] Wiki pane type — `wiki` in `PaneTypes.ALL`; opens a vault at an absolute directory path validated by `sanitize_tile` (same trust rule as code_viewer/file_tree).
- [ ] Vault model — local-first directory of plain Markdown files (potentially Obsidian-compatible: `.md` on disk, no proprietary format), indexed with full-text search in SQLite FTS5 (reuses the v0.5.1 history engine).
- [ ] Markdown editor & preview — edit notes with live preview through the existing sanitized Markdown→BBCode pipeline (v0.4.0); source/rendered toggle like code_viewer.
- [ ] Wikilinks & backlinks — `[[note-name]]` linking, per-note backlink panel, unresolved-link detection.
- [ ] Link graph view — Godot-drawn graph of notes as nodes and wikilinks as edges (GraphEdit experience from the v0.5.4 Visual Concept Graph).
- [ ] Agent access — vault search/read exposed via CLI and MCP so agents can query the knowledge base through the public pane-API primitives.
- [ ] Wiki security notes in AGENTS.md — vault content is user data but untrusted input to the renderer: sanitized Markdown pipeline only; wikilinks resolve within the vault (no arbitrary file reads).
- [ ] Placement note — scheduled ahead of v1.0.0: all prerequisites land earlier (v0.4.0 Markdown rendering, v0.5.1 FTS5, v0.5.4 Visual Concept Graph), and the wiki is not gated on any v1.0.0 launch criterion.

## v0.5.5 — Plugin Ecosystem

- [ ] Plugin manifest — `gpty-plugin.toml` (id, name, version, min_gpty_version, platforms, build/startup commands, actions, events, link handlers) plus gpty-native `[[concepts]]` and `[[profiles]]` sections so a plugin can be pure JSON — zero code.
- [ ] Plugin install & lifecycle — `gpty plugin install <owner>/<repo>@ref` (clone, manifest validation with size/count/path caps, review dialog reusing the Workspace Trust pattern, pinned revision, per-plugin log dir) and `list` / `enable` / `disable` / `run` / `logs`. The entire CLI is the plugin API (`GPTY_BIN_PATH`); commands are argv arrays, never shell-evaluated.
- [ ] `cli_view` pane — runs a command and streams stdout into a pane body: plugin UI v1 without a Godot SDK. Native third-party GDScript/Rust pane plugins deferred to a future SDK (`PaneTypes.ALL` is the layout-trust anchor; see AGENTS.md).
- [ ] Pane contract extension — `on_agent_state_changed(state)` in `PaneBody` for custom panes.
- [ ] Plugin registry — JSON index repo + browse page on the docs site; submission by PR.
- [ ] User-owned pane environment — a file must not carry env. Restore ignores a tile's `shell_env`, and per-pane env becomes a property the *user* grants: an app-written map keyed by `attachment_id` (`user://pane_env.json`, written only by the pane settings UI, never by profiles/workspaces), so a pane's env still survives restarts while no file can supply one. Profiles lose the ability to carry env by design (documented; a profile that needs it points at shell rc or asks the user to set it once). Companion fix: `_restore_into` currently applies tile settings *before* `apply_to_terminal`, which overwrites `shell_env` with the user's global — so per-pane env is silently discarded on restore (a bug) and no file-supplied env reaches a child (an accident, not a control). Fix the ordering only together with this item, or files regain env authority. Migration: restored tiles' env is dropped with a notice listing what was dropped — do NOT auto-adopt it into the store, since that would launder a hostile file's payload into the trusted map. `BLOCKED_ENV_KEYS` stops growing: it becomes the floor for user-authored, ambient, and plugin-supplied env instead of the primary defense, and the plugin lane may carry env in a manifest only behind the plugin review dialog. Rationale — env is spawn-time authority, not display config: module search paths (`PYTHONPATH`, `NODE_PATH`, `RUBYLIB`, `LUA_PATH`, `CLASSPATH`), build-tool override (`RUSTFLAGS`, `GOFLAGS`, `CC`, `LD`, `MAKEFLAGS`), git config-by-env (`GIT_CONFIG_GLOBAL`, `GIT_CONFIG_COUNT`/`_KEY_n` → `core.pager`, `alias.*=!cmd`, `core.sshCommand`), credential/agent hijack (`SSH_ASKPASS`, `SSH_AUTH_SOCK`), traffic redirection (`HTTPS_PROXY`, `SSL_CERT_FILE`, `PIP_INDEX_URL`, `NPM_CONFIG_REGISTRY`, `KUBECONFIG`, `DOCKER_HOST`), and credential helpers or agent sockets (`SSH_ASKPASS`, `SUDO_ASKPASS`, `SSH_AUTH_SOCK`, `KRB5CCNAME`, `GPG_AGENT_INFO`). The second pass also found the sanitizer's own gaps: `LD_DEBUG`/`GLIBC_TUNABLES`, `HOME`/`XDG_CONFIG_HOME` (a redirected HOME sources different rc files), `GIT_CONFIG_SYSTEM`, `GIT_DIR`/`GIT_WORK_TREE`, and no cap on the key set past the 64-line window. An enumerated blocklist cannot converge on a class like that. Decided over the cheaper alternative (D: stop persisting per-pane env entirely) because C keeps the user's own env across restarts.
- [ ] God-object split — continue splitting `workspace.gd` (~1350 lines) / `terminal_pane.gd` / `terminal_manager.gd` into focused files (workspaces block, persistence, polling, palette, profile/layout restore). IPC dispatch (`ipc_handlers.gd`) and window chrome (`window_chrome.gd`) were already extracted in v0.5.1; concept routing lives in `concept_router.gd`. Do it alongside the plugin work, which touches `workspace.gd` heavily. Two specific seams first: the duplicated enabled-concept filter (`ConceptManager._push_to_rust` vs `workspace.gd._push_concepts_to_engine` — the same defect had to be fixed twice, and only one copy is reached on each path) collapsing to one entry point; and the `GptyTerminal` `#[func]` surface (~38 exports on one class) splitting into grid/capture/IPC facets, since a plugin author otherwise has to reason about all of it to touch any of it.

## v0.5.4 — Visual Concept Graph

- [ ] Visual Concept Graph — build concept automations visually using Godot's GraphEdit node editor. Drag-and-drop nodes for triggers, conditions, and actions without writing regex by hand. (Deferred from v0.5.0.)

## v0.5.3 — Terminal Performance & Mouse

- [ ] Render batching — merge consecutive same-attribute cell runs into single draw calls (glyph-run batching) in `terminal_pane.gd` `_draw()`, cutting the per-frame canvas-item count; measure frame time under flood output and scroll before/after. (Deferred from v0.5.0.) Baseline from the v0.5.3 prep work: idle panes no longer repaint at all (the repaint is gated on the grid generation — measured 48–49 gate ticks/s per pane against 0 generation changes), so this item is now only about cost *under load*.
- [ ] UI Thread DoS mitigation — rate-limit terminal rendering when a PTY floods output (e.g., `cat /dev/urandom`), preventing the UI thread from locking up. (Deferred from v0.5.0.) Made more pressing by the same prep work: under flood the generation changes on every chunk, so the repaint gate is open every frame by definition — rate-limiting is the remaining lever, not an optimisation.
- [ ] Terminal mouse reporting — forward mouse events to the PTY when apps enable tracking (DECSET 1000/1002/1006, SGR-encoded), so herdr's built-in pop-ups, lazygit, and nvim mouse mode work inside panes. Mode state comes from `alacritty_terminal`; UI selection/scroll behavior unchanged when reporting is off.

### Hardening (audit follow-ups folded into this milestone)

- [x] Concept command execution removed — a concept definition was data that could act: a regex trigger over untrusted terminal output drove a `write_line` into a target pane (event path) and a Ctrl+click handler ran the first matching template in the pane itself. Both paths are gone (`command_template`, `substitute_template`, `shell_quote`, `matching_commands`, `match_concepts_on_line`, `_check_click_concept`), legacy `cmd` keys are ignored on parse and stripped on save, and the settings dialog no longer collects one. Shipped concepts were already capture-only; user-authored ones now can't be anything else.
- [x] Workspace Trust covers everything that executes — the gate examined only the legacy `shell` key while restore consumed `command` > `shell` and passed `shell_args`/`shell_env` through untouched, so a downloaded profile could run an arbitrary command (`["-c", "curl … | sh"]`) or a `PROMPT_COMMAND` payload with no prompt. `PaneTypes.tile_spawns_untrusted` now checks program, argv, and environment (compared against the user's own defaults), and the sidebar profile-activation and workspace-restore paths use it. **Correction (second pass):** the `layoutLoad` IPC handler calls `_do_activate` directly, so CLI/MCP-driven loads bypass the gate entirely, and the env clause turned out to gate a path that cannot execute — `_restore_into` applies tile settings *before* `apply_to_terminal`, which overwrites `shell_env` with the user's global, so a restored tile's env never reaches a child. The program/argv coverage is the part that was live; the IPC hole and the ordering bug are tracked below.
- [x] Startup-evaluation env keys blocked — `sanitize_envs` grew a second class: `BASH_ENV`, `ENV`, `PROMPT_COMMAND`, `SHELLOPTS`, `PS4`, `ZDOTDIR`, `PERL5OPT`, `PERL5LIB`, `PYTHONSTARTUP`, `NODE_OPTIONS`, `RUBYOPT`, `LESSOPEN`, `GIT_SSH_COMMAND`, `GIT_EXTERNAL_DIFF`, `GIT_PAGER`, `PAGER`. These make a shell or the next tool run what the value contains, so a layout could get code execution without ever naming a command. Users can still set them inside a shell.
- [x] Grid geometry ceiling — `start_shell`/`resize_grid` clamped dimensions only from below, and `PaneTypes.sanitize_tile` never bounded a stored `rows`/`cols`, so a crafted tile allocated a 10¹²-cell grid at spawn. Both boundaries now clamp (500 × 2000).
- [x] Control credentials quarantined from Inspector children — the OMP/adapter child inherited the GUI's whole environment, including `GPTY_SECRET`/`GPTY_SOCKET` (and, for a GUI started inside a pane, that pane's event capability). `SessionOpenRequest::strip_env` now carries `gpty_core::pty::STRIPPED_INHERITED_ENV_KEYS`, applied by both backends.
- [x] Live-search result cap — a one-character pattern over 100k scrollback lines materialised every match on every keystroke and walked them each frame; `TermGrid::search` stops at `MAX_SEARCH_RESULTS` (10 000).
- [x] MCP tool allowlist — `tools/call` mapped *any* name to an IPC method, reaching methods that were never published as tools (e.g. `shutdown`). It now rejects anything outside the advertised schema.
- [x] CI least privilege — every job inherited the repository default token scope; `ci.yml` now declares `permissions: contents: read`.
- [x] Security policy published — `SECURITY.md` records the threat model, the reporting process, the hardening that must not be weakened, and the known limitations.
- [x] Workspace Trust shows what it will run — `PaneTypes.untrusted_plan` renders the program, the argv, and each `environment:` entry it is asking the user to approve (control characters escaped, env lines capped at 8/tile and 24 dialog lines, every env line keeping its label so a value cannot forge a `program:` line), and `_untrusted_details()` feeds it into both the profile-activation and workspace-restore dialogs. 4 unit tests cover content, trusted→empty, labelling, escaping, and the caps.

### Security follow-ups (found by the same audit, not yet addressed)

- [ ] Unbounded PTY-output channel — `pty_rx` is an `mpsc::unbounded_channel`, so a pane that floods output faster than the terminal task drains it grows memory without limit (reachable with `cat /dev/urandom`). Bounding it is a design decision: a bounded channel blocks the reader thread and backpressures the child (correct, at the cost of latency), while dropping chunks corrupts grid state. Pick backpressure, then measure.
- [ ] PATH-resolved programs bypass `validate_executable` — a bare name is spawned as-is, and a tile that sets `PATH` decides which file that resolves to. Fix by resolving the name against the child's final `PATH` and validating the resolved file, rather than blocking `PATH`.
- [ ] Bracketed paste — combined (`Ctrl+Shift+V`) paste writes clipboard bytes verbatim: newlines submit each line to a shell, and pasted control bytes are injected raw. Track DECSET 2004 in the grid and wrap pastes in `ESC[200~`/`ESC[201~` (with a control-character guard when the application has not enabled it).
- [ ] History store write path — one blocking SQLite insert per output line under the shared grid mutex can stall the UI under flood, and the store has no byte cap (row cap only). Batch inserts off-thread and cap total bytes.
- [ ] Pane file sinks — `code_viewer` opens any absolute path with no size/type cap (a never-EOF device hangs the GUI), and `file_tree` hands attacker-named files to the OS default handler. Refuse non-regular files, cap the read, and confirm before `shell_open`.
- [ ] Persistence file-mode and symlink hardening — `.tmp` sibling writes use a predictable path and follow symlinks; scrollback is written with the process umask. Use `O_EXCL`+0600 temp files and set explicit modes.
- [ ] Peer-credential gaps — Windows named pipes have no peer check to fail closed on (same-UID model is the whole gate), and `peer_uid_matches` returns `true` on Unix platforms other than Linux/Android/macOS. Document and, where a portable API exists, wire it up.
- [ ] Shared-`/tmp` socket fallback — a world-writable fallback path can be squatted to deny the control surface (ownership/mode are validated, so it is DoS only). Prefer failing closed, or fall back to a per-user private directory.
- [ ] MCP/daemon edges — `gpty mcp` reads stdin lines without a size bound; daemon auto-spawn's fallback binary discovery skips `validate_gui_binary`; the `/tmp` socket path has a narrow pre-creation TOCTOU; the GUI spawned by the CLI inherits the caller's environment (undocumented).
- [ ] Duplicate `attachment_id` — the pane-settings apply path never re-runs `_ensure_unique_attachment_id`, so two panes can share a public id and id-targeted IPC resolves to the wrong pane.
- [ ] Store corruption handling — valid JSON with the wrong value types aborts a loader and can drop a whole workspace set; validate shape per key and skip bad entries instead.
- [ ] Event-channel hygiene — subscriptions are never released (64 slots leak per client), `reasoning.delta` re-renders the whole accumulated Markdown unthrottled, and unknown envelope fields pass the OMP translation boundary unchecked.
- [ ] Supply-chain follow-ups — actions are pinned to mutable tags, CI downloads Godot/Hugo without verification, release artifacts are unsigned and unchecksummed, `docs/setup.sh` interpolates remote release metadata unquoted, and the update checker reads its response body without a size cap.
- [x] Trust gate on the IPC restore path — `ipc_handlers.gd` `layoutLoad` called `ws._do_activate(profile)` directly while the gate lived in `_activate_profile`, so `gpty layout load <name>` and the `layout-load` MCP tool restore an untrusted profile with no consent step. An untrusted profile is now refused over IPC with an error pointing at the GUI; verified live against a running GUI.
- [x] Inspector prompt fence — `gpty-ai/src/prompt.rs` wrapped untrusted capture in a literal ``` fence with no escaping and interpolates `concept_name`/`source_pane` raw, so a capture containing a fence escapes the data block (omp-only, tool-free backend, so display-level). The fence now outgrows the longest backtick run in the capture (capped at 32) and metadata is flattened to one line.
- [x] A notify-only match must not shadow a capture — `concept::match_line` returned the first match and `apply_match` starts nothing for `SingleLine`, so a broad notify-only concept placed ahead of a capture concept silently suppresses that capture. Precedence is now explicit: capture outranks notify, first match wins within a class.
- [ ] Finalize an in-flight capture when a pane is dropped — `SpawnedTerminal::drop` calls `task.abort()`, so the documented finalize-on-close path never runs: closing, swapping, or resetting a pane mid-capture silently loses the capture instead of routing it.
- [ ] Post-resize suppression while capturing — the post-SIGWINCH window is consulted only in the non-capturing branch, so redraw bytes are buffered into the capture, routed as output, and consume the 4 MiB budget.
- [ ] Position-swap popup re-resolves its targets — `show_position_swap_popup` captures tile indices when it opens; killing a pane meanwhile swaps the wrong pair or indexes past the end, with no indication the target set changed.
- [ ] Triage corrections from the second pass — the persistence temp-file/symlink item needs a group/other-writable `user://` to matter (hardening, not reachability); the peer-credential item is overstated for Linux (check present, fails closed) and accurate for BSD/illumos/Windows; in the pane-file-sinks item the `code_viewer` half is a regular-file OOM while the `file_tree` half (`OS.shell_open` on a downloaded `.desktop`) is sharper and needs a scheme allowlist + confirmation like `markdown_view`; the never-EOF device hang is unproven — do not assert it.
- [ ] Concept matching under flood — aggregate cost is lines × enabled concepts × regex on both the output and typed-input paths; the rendering flood item above does not cover it. Measure and, if needed, cap matches per second.
- [x] Restored-executable parent-directory check — `pty::validate_executable` stats the program file only. A binary whose own mode is safe (0755) can still be swapped by another user when it sits in a group/other-writable directory without the sticky bit; `/tmp` is protected by default, other shared directories are not. Walk the parent chain and reject when any directory is writable by others without `+t`, then extend the existing test.
- [ ] Parallel test job in CI — `scripts/ci-check` runs `cargo test --test-threads=1`, and that serialisation hid a shared-static isolation bug in `crates/gpty-gdext/src/ipc.rs` until a multi-threaded run surfaced it. Add a CI job (or a ci-check step) that runs the workspace suite with default parallelism so this class fails loudly instead of intermittently. Observed during the v0.5.3 audit: the `gpty-ai` adapter tests (real child processes, timing assumptions) fail intermittently in a loaded parallel run and pass 3/3 serially and 3/3 when the machine is idle.
- [ ] Windows runtime smoke — the named-pipe event listener and the `first_pipe_instance` fix are verified by `cargo check` and source reading only: CI compiles the Windows target but never runs Godot on it. Add a `windows-latest` job that boots the GUI headless and drives the pane-API/CLI path, so Windows behaviour is observed rather than inferred.
- [ ] Scrollback retention across pane ids — history is keyed by `attachment_id` and rows for ids that no longer exist are never reclaimed (one development database: 3 311 rows across 556 ids, 56 MB, of which only 3 ids are live). Prune rows whose id appears in no workspace, or add a global cap, and surface the store's size in Settings.
- [ ] Seam contract tests — the audit's recurring defect shape was a documented contract with no test spanning the boundary where it is implemented (MCP tool name → IPC method, `paneRead`'s scrollback claim, the concept-routing label/id pair). Add one contract test per cross-module seam where both sides exist in-repo, starting with the `#[func]` export surface (name + arity) against its GDScript call sites.

## v0.5.2 — Agent State & Adapters

- [x] AgentState model — `AgentState` enum (Idle / Working / NeedsAttention / Completed / Failed) in `gpty-core`, with tiered detection: Tier 1 capability-authenticated events (authoritative), Tier 2 OSC state declaration (published standard; AGENTS.md constraints), Tier 3 regex/idle/exit heuristics (display-only). No `ToolRunning`-via-exit-code — foreground-command exits are not reliably attributable in a PTY.
- [x] Titlebar state badges — Phosphor status badges on pane titlebars in `terminal_pane.gd` (pulsing amber = NeedsAttention, spinner = Working, check = Completed, warning = Failed). Display only; badge state never feeds decisions.
- [x] Generic event vocabulary — adapter-neutral event names (`agent.started`, `turn.started`, `tool.call`, `thinking.delta`) mapped from the OMP extension's allowlist at the event-socket boundary; Reasoning and Tier 1 agent-state detection consume the generic contract. Same commit: update the AGENTS.md OMP-only data-flow diagram.
- [x] Windows event listener — named-pipe event listener closes the Unix-only gap (`omp_events.rs`); Reasoning stops being fail-closed on Windows.
- [x] Generic CLI backend — `CliBackend` in `gpty-ai` (subprocess NDJSON bridge) beside Mock/Omp, with a backend/model picker in Inspector pane settings. Adapters use only each CLI's documented hooks — never tokens, never TUI scraping.
- [x] In-app update checker — checks GitHub releases on startup and toasts when an update is available. Fixed the placeholder repo owner, sourced the current version from `GptyTerminal.get_app_version()`, gated on `OS.has_feature("editor")` (headless/test-safe), added the `check_updates` setting, and covered `_is_newer` with GUT tests. (Deferred from v0.5.0.)
- [x] App version & build info — Settings gains an About tab showing `gpty v<get_app_version()>`, the pinned IPC protocol version, and the repo URL; the status bar shows the live version as the rightmost entry. (Deferred from v0.5.0.)

## v0.5.1 — Persistence

- [x] SQLite + FTS5 history backend — wire the existing `HistoryStore` (SQLite + FTS5, tested but unused in production) into pane lifecycle and session restore. Scrollback is currently lost on restart; this makes it persistent and full-text searchable, and backs `paneRead` across restarts.
- [x] Workspace switching — switch between independent pane sets within the same window (sidebar Workspaces section, keep-alive PTYs). Each workspace has its own layout, profile, and scrollback. Deferred from v0.3.0; prerequisite for the daemon-era workspace model.
- [x] Scrollback restore on restart — reload persisted history lines by `attachment_id` when a pane reopens, so scrollback survives restarts (builds on the v0.5.0 stable public pane IDs).
- [x] History full-text search — surface the FTS5 store's `search()` in the terminal search UI so old output stays findable after restart.
- [x] History retention setting — `cfg_history_lines` (default 10 000) clamping the per-pane cap.
- [x] Live pane-API smoke — exercise the v0.5.0 surface end-to-end against a running GUI: `new-pane` → `inject` → `pane-read` → `pane-wait` → `broadcast` over tagged panes, plus `pane-status` exit codes from `pane-run` (Unit/GUT covered, but not smoke-tested live).
- [x] Event-socket smoke — extend the live smoke to cover `subscribe`/`eventsPoll` on `gpty-events.sock` (pane spawn/kill events). The control-socket pane API is smoke-covered; the event socket is not.
- [x] Palette test dedup — `test_palette.gd` now asserts against `PaneTypes.build_palette_commands()`; the command list lives in one place.

## v0.5.0 — ADE Foundation

- [x] Rebranding & positioning — README, docs landing, and CLI copy reposition gPTY as an ADE ("graphical ADE: a PTY foundation with a public API"). De-OMP the shipped defaults: "OMP Workspace" profile renamed to "Agent Workspace"; `@gpty/omp-events` remains the first adapter, not the identity. Name stays `gpty` (positioning, not renaming); display name is `gPTY`. Same commit: updated every "OMP Workspace" reference in AGENTS.md (structure comment + Inspector/Reasoning section) and the docs site.
- [x] Ecosystem presets — shipped profiles for herdr, lazygit, nvim, claude, and OMP in `profiles.default.json`, backed by per-tile `command` support in profile restore (`command` > legacy `shell` > default, all through `sanitize_shell`).
- [x] Stable public pane IDs — every pane auto-generates a persisted `attachment_id` (`pane-XXXXXXXX` via `PaneTypes.generate_attachment_id()`, `PaneBody.apply_settings` choke point); `newPane` returns it and `listPanes` reports `id` alongside the display `label`. AGENTS.md attachment-id bullet documents the public-id semantics.
- [x] Pane env markers — `GPTY_ENV=1` + `GPTY_PANE_ID` injected as trusted runtime vars at spawn (`start_shell` pane_id param; `GPTY_PANE_ID` falls back to the per-PTY session id); both keys blocked from untrusted env. AGENTS.md env-sanitization bullet updated with the new trusted vars.
- [x] Pane read/status/run/wait IPC — `paneRead` (plain text from grid + scrollback, capped), `paneStatus` (pid / running / exit_code / idle_ms primitives), `paneRun` (command spawn; exit via `paneStatus`), `waitForOutput` (`paneWait`: server-held response, Rust `regex` scan of a 512-line ring buffer, 60 s deadline). Substrate primitives only — no agent state machine in core.
- [x] Event subscription — `subscribe` / `eventsPoll` on the event socket (never the control socket); bounded per-subscriber queues fed by `GptyTerminal.emit_event` from concept matches and pane spawn/kill. Push transport deferred.
- [x] Agent skill — ship `skills/gpty/SKILL.md` + `gpty --skill` printing the release-matched copy (`include_str!`), with a `GPTY_ENV=1` guardrail; install locations documented for Claude Code, codex, opencode, and OMP. MCP schema verified free of a `skill` tool.
- [x] IPC version sourcing — the IPC `version` response now comes from the crate via the static `GptyTerminal.get_app_version()` (`env!("CARGO_PKG_VERSION")`, `crates/gpty-gdext/src/lib.rs`); `workspace.gd` no longer hardcodes "0.3.0".
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
- [x] Concept engine security — shell-quoted template substitution, parse caps (count, lengths, timeout clamp), line and capture bounds (template substitution removed in v0.5.3 along with command execution)
- [x] PTY env sanitization — dynamic-loader variable blocklist applied at spawn
- [x] Layout restore trust — tile validation, typed settings application, absolute pane paths
- [x] Workspace cleanup script — `scripts/clean` removes stale sockets, import caches, and build outputs
- [x] Standalone app builder — `scripts/build` produces a runnable bundle for the host platform
- [x] Documentation overhaul — MCP integration, crate README accuracy, testing guide with explicit gaps
- [x] Test coverage expansion — capture lifecycle, CLI mock-server roundtrips, concept routing, gdext FFI smoke

## v0.3.1 — Stability & Windows Support

- [x] Windows named-pipe IPC — per-connection named-pipe instances on the server (v0.3.0 never compiled on Windows); local cross-check via xwin/clang-cl plus the CI `rust-windows` job keeps it green
- [x] Concept engine reliability — startup registration race fixed (`ClassDB.instantiate` on first frame), `UntilStop` capture triggers from PTY output, capture-only concepts with empty `cmd` supported (the `cmd` field itself was removed in v0.5.3)
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
- [x] Concept engine — regex-based trigger/action matching with label routing. Every line of PTY output is tested against registered concept patterns. Matching lines broadcast events on a pub-sub channel; panes with matching labels execute the associated action. (Command execution removed in v0.5.3 — concepts are capture-and-route only.)
- [x] SingleLine capture mode — each matching line triggers an event on the pub-sub channel. Receiving panes inject the action's command template into their PTY stdin, enabling cross-pane automation. (The mode and its injection path were removed in v0.5.3; it never delivered an action before then — labels were always empty and every pane shared id 1.)
- [x] Settings persistence — font size, cursor shape, window mode, and other preferences saved to `user://settings.json`. Settings auto-load on startup and auto-save on change via a debounced save timer.
- [x] Phosphor icon set — 100+ icons for toolbar, sidebar, and pane action buttons. Unicode PUA codepoints rendered via the bundled Phosphor Regular font. Icons are exposed as `const` strings in `icons.gd`.
- [x] Sidebar with pane list — collapsible left panel showing all tiles with focus, kill, minimize, and swap buttons per pane. Also exposes window mode toggle and per-pane-type spawn buttons.
- [x] Control-based renderer — terminal grid drawn in GDScript via `_draw()`. Rust packs cell data (chars, foreground, background, attributes) into flat arrays; GDScript unpacks and renders them line-by-line with damage tracking for incremental updates.
