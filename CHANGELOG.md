# Changelog

Log all notable changes to the project. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.3] — 2026-09-10

### Added

- `single_line` concepts mean **notify-only**: a trigger match is published on the event socket (`{type: concept, event: matched, mode: single_line, name, source}`) and nothing else happens — no capture, no routing, no output taken from the pane. The Settings → Concepts editor offers the mode again, and hides the target and stop-condition fields for it. A missing or unknown `capture_mode` still captures. Metadata only: the matched line is never published.
- **Terminal mouse reporting.** A pane forwards clicks, drags and wheel events to a child that enabled mouse tracking (`DECSET 1000`/`1002`/`1003`, encoded as SGR when `1006` is on and in the legacy X10 form otherwise, from the same cell mapping selection uses), so `nvim`'s mouse mode, `lazygit` and herdr's pop-ups work inside a pane instead of only seeing the pane's own selection. Only the events the enabled mode covers are forwarded — with tracking off nothing changes — and holding `Shift` keeps text selection reachable while an app has grabbed the mouse.

### Changed

- The pane titlebar on/off toggle moved from Settings → System to Settings → Appearance, next to the Title bar colour and the other chrome colours it belongs with. Nothing was missing — the setting and its checkbox existed, but a user looking for a titlebar setting looks at the pane or the chrome colours, not at System.
- The shipped recommended layout is now named **Agent Workspace** (it opens Terminal + Inspector + Reasoning). v0.5.0's notes promised that rename; the data file still said "OMP Workspace", so the de-OMP repositioning never actually reached a fresh install.
- **Rendering no longer costs the frame under load.** Text is drawn as one `draw_string` per run of cells that share font, color and underline state instead of one per cell (a full-screen repaint measured ~20 % cheaper), and a pane whose own grid fetch plus repaint exceeds a 4 ms per-frame budget looks at the grid less often — geometrically, down to ~10 Hz — instead of rebuilding its canvas every frame. That is what a flooding PTY (`cat /dev/urandom`, `yes`) used to do to the whole UI thread; a pane that keeps up is never throttled, and neither is a view you are scrolling yourself.
- Idle panes no longer repaint at all (the repaint is gated on the grid generation) and the per-frame per-pane FFI polls and focus walk moved off the frame.
- The pane search opens with `Ctrl+Shift+F`; plain `Ctrl+F` reaches the PTY again, as the docs always claimed (vim/less page-forward).

### Fixed

- **Pane edges could not be dragged.** Three defects stacked up: the resize handler ran on the wrapper's `gui_input` while the pane body fills the wrapper and consumes the mouse (so the 4 px edge test was unreachable — the cursor only flashed because the body's default arrow overwrote it); the drag passed the delta since the *previous* motion event to a routine that recomputes from the press (mouse motion arrives in 1-3 px steps that round to zero cells, so a slow drag moved nothing); and a partially applied move broke the neighbour lookup, which reverted the pane being dragged and left the grid not adding up. Each edge now has a 6 px strip that owns the resize cursor and starts the drag, and the move is recomputed from the press on every event, so the divider follows the pointer live and stops at the minimum pane size.
- **The layout grid is finer, and its unit has one definition.** A pane's geometry is measured in abstract grid units, and one unit *is* the drag's step: at 12 units a divider jumped ~83 px per cell, which is what made resizing feel jarring; it is 60 now, near a tmux character cell. The unit also lived in two places — `PaneTypes` owns it and `workspace.gd`, the sanitizer and the drag math read that one constant. A copy that drifted (the layout dividing by 12 while tiles were in 60) sized every restored pane several times the grid and drew it outside the visible area, so this is now a single definition with a test that asserts restored panes' on-screen rects, not just their spans.
- **A divider moves every pane on the far side of it.** Neighbours were matched by *identical* extents, which is only true in an evenly split layout: in the shipped Agent Workspace layout (one full-height pane beside two stacked ones) the tall pane's edge had no neighbour at all, so dragging it did nothing — while grabbing the neighbouring panes' edge happened to work, which is why resizing felt random. Neighbours are matched by overlap now, and the stacked panes move together.
- **Saved layouts keep their shares across the finer grid.** A layout written before the change is in 12 units; the payload states its unit, and when it does not, the unit is inferred from the tiling (a layout always fills its grid). Either way the geometry is scaled to the current grid on restore — without that, a restored half-width pane would have come back one fifth of the screen.
- Window titlebar controls used the wrong glyphs — maximize showed a keypad, restore a phone, and the window-mode picker a folder. They now render arrows-out / arrows-in / monitor (codepoints verified against the bundled font).
- **Captures survive their pane.** Closing, swapping or resetting a pane mid-capture, or letting the child exit, used to drop the buffered output (the terminal task was aborted past its finalize path, and nothing polls a dead pane's queue); the capture is now finalized and routed like any other. A notify-only concept can also no longer sit in front of a capture concept and starve it, and the shell's post-SIGWINCH repaint is no longer buffered into an active capture (where it appeared as a duplicated prompt).
- `pane-status`/`pane-run` report the exit code even when the child closes its pty a moment before it becomes reapable, instead of reporting nothing for a command that did exit.
- The Inspector's OMP session serves a turn on a fresh child when the previous one's pipes are already closed (the liveness probe has the same window as the exit-code race above), instead of failing a turn nothing ever received.
- A `cli` adapter that exits non-zero reports what it wrote to **stderr**. The drain is a separate task, so a summary taken the instant the child exits could come back empty and lose the adapter's own account of the failure; the exit path now gives the drain a bounded moment to reach EOF first.
- The position-swap popup resolves its targets when a row is clicked, so a pane killed while the popup is open no longer swaps the wrong pair or indexes past the end.
- Scrollback rows belonging to panes that no longer exist are reclaimed; the store stops growing with every pane id the workspace ever had.
- Search: the first `Enter` advances past the matches already on screen, and scrollback search accepts what a user actually types (`main.rs`, `error: x`) instead of failing as a raw FTS5 query.
- Keyboard focus moves to a surviving pane when the active one closes, instead of typing reaching nothing until the user clicks another pane.
- Settings are written through a sibling temp file and renamed into place, so a failed write can no longer truncate the store; an unsupported max-FPS value is shown instead of deselecting the control.
- Attachment ids stay unique when panes are attached, and disabling every concept takes effect immediately.
- The PTY reader and writer are opened before the child is spawned (a failure no longer leaves an unreachable shell), the shell is reaped if the reader thread cannot start, and emulator replies are written with the grid lock released so a child that stops reading cannot stall the pane's renderer.
- Scrollback persistence failures are reported instead of silently dropped.
- Input: numpad keys send their characters unless the app enabled keypad mode; modified `~`-terminated keys emit the correct CSI form; key auto-repeat no longer reaches the paste and search chords twice; a stored grid size is applied only before a tile is laid out.
- The cursor hides when the application hides it and follows the viewport when scrolling back.
- Inspector reliability: a turn's output no longer leaks into the next turn; dropped events are reported instead of silently truncating the answer; an untouched adapter argv is not re-split; adapter frames are capped while reading; the adapter's stderr is drained so it cannot deadlock; the OMP child is re-spawned rather than written into.
- IPC: the Windows event pipe sets the first-instance flag only for the first instance; a request without an id is treated as a notification instead of id 0.
- MCP `pane-*`/`concept-*` tools resolve to their IPC methods again, and `pane-read` returns scrollback as documented rather than only the viewport.

### Security

- **Workspace Trust shows what it will run.** The dialog named a category — "a different program, pass extra arguments, or set a different environment" — without naming the values, so approving it was a guess. It now lists the program, the argv, and each `environment:` entry, escaped and capped (the content comes from the file, not from us). `layoutLoad` over the control socket refuses an untrusted profile outright, since a CLI or MCP caller cannot answer a dialog.

- **Concept definitions can no longer execute commands.** A concept is data: a regex trigger, a stop condition, and a routing target. Until now it could also carry a command template that was written into a target pane's PTY — reachable from terminal output (any program that printed a matching line) and from a Ctrl+click on a matching line, both with no authentication, no consent prompt, and no notice. A third-party `concepts.json` was therefore arbitrary code execution with an attacker-chosen trigger, aimed at whatever pane matched, repeatable and silent; the click path shipped in v0.5.2. Removed: `command_template`, `substitute_template`, `shell_quote`, `matching_commands`, the engine's event-injection branch and the pub-sub channel that existed only to carry it, `match_concepts_on_line`, the Ctrl+click handler, and the concept label plumbing (`TerminalConfig.labels`, `labels_json`, `_concept_labels`). Legacy `cmd` keys in a user file are ignored on parse and stripped on save; the Settings → Concepts dialog no longer collects one. See [SECURITY.md](SECURITY.md) for the threat model behind the change.
- **Workspace Trust now covers everything that executes in a restored pane.** The gate compared only the legacy `shell` key, while restore consumed `command` > `shell` and passed `shell_args` and `shell_env` through untouched. A downloaded profile could therefore spawn `/bin/bash -c "curl … | sh"` (argv) or add a `command` override with no prompt at all — the argv half was the live one. The env half turned out to be unreachable: `_restore_into` applies tile settings before `apply_to_terminal`, which overwrites `shell_env` with the user's global, so a restored tile's env never reaches a child. That ordering also silently discards a user's own per-pane env on every restore; it is tracked with the v0.5.5 env model, where it must be fixed (fixing it alone would hand file-supplied env back to the attacker). `PaneTypes.tile_spawns_untrusted` checks program, argv, and environment against the user's defaults, and the workspace-restore path uses the same predicate.
- **Startup-evaluation environment variables are refused from configuration.** `PROMPT_COMMAND`, `BASH_ENV`, `ENV`, `SHELLOPTS`, `PS4`, `ZDOTDIR`, `PERL5OPT`, `PERL5LIB`, `PYTHONSTARTUP`, `NODE_OPTIONS`, `RUBYOPT`, `LESSOPEN`, `GIT_SSH_COMMAND`, `GIT_EXTERNAL_DIFF`, `GIT_PAGER`, and `PAGER` are now blocked at the spawn choke point alongside the dynamic-loader keys: a shell or the next tool runs what they contain, so a layout carrying one could otherwise get code execution without naming a command. (The restored-tile path turned out to be unreachable — see the Workspace Trust entry above — but these keys still arrive through the user's own global `shell_env`, and this list is the floor the v0.5.5 env model builds on.) Users can still set them from inside a shell.
- **The Inspector's child process no longer inherits workspace-control credentials.** The OMP and adapter children were spawned with the GUI's full environment, including `GPTY_SECRET`/`GPTY_SOCKET` (and, for a GUI started inside a pane, that pane's event capability). Both backends now strip `gpty_core::pty::STRIPPED_INHERITED_ENV_KEYS`.
- **Grid geometry from saved layouts is bounded.** `start_shell`/`resize_grid` clamped dimensions only from below and `sanitize_tile` never bounded a stored `rows`/`cols`, so a crafted tile allocated a 10¹²-cell grid at spawn. Both boundaries clamp at 500 × 2000.
- **Search results are capped.** A one-character pattern over 100 000 scrollback lines materialised every match on each keystroke and re-walked them every frame; the grid search now stops at 10 000.
- **MCP `tools/call` is restricted to advertised tools.** Any name was mapped to an IPC method, reaching methods that were never published as tools (including `shutdown`).
- **CI runs least-privilege.** `ci.yml` declares `permissions: contents: read` instead of inheriting the repository default token scope, which was handed to a third-party audit action.
- Added [SECURITY.md](SECURITY.md): threat model, reporting process, hardening that must not be weakened, and known limitations.
- **The Inspector's prompt cannot be escaped by its own content.** Untrusted capture is wrapped in a fence one backtick longer than the longest run inside it (capped) and `concept`/`pane` metadata is flattened to a single line, so a capture that prints ``` can no longer land as instructions.
- **Restored programs are validated beyond their own mode.** An absolute `command`/`shell` from a layout or profile must be a regular file owned by this user (or root), not group/other-writable, and its parent chain must not be shared-writable without the sticky bit — a downloaded profile can no longer run a binary another user could have replaced. The Inspector's adapter argv is held to the same rule.
- **Control credentials are refused from untrusted pane environments** (`GPTY_SECRET`/`GPTY_SOCKET` alongside the pane-marker and event-channel keys), and the control socket compares its secret without short-circuiting.
- **An unterminated OSC sequence is force-closed at 64 KiB.** vte's `std` build keeps OSC bytes in an unbounded buffer, so a program that emitted `ESC ]` without a terminator grew the parser's memory and left it stuck inside the string, swallowing every later line.

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

[0.5.3]: https://github.com/godot-pty/gpty/compare/v0.5.2...v0.5.3
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
