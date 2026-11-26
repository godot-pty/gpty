# Agent Guide

Rust + Godot multi PTY emulator with a tiling grid GUI.

## Guides

This file holds the rules every change needs. The detailed rules live in one page per topic; read the ones your change touches before editing.

| Guide | Read it when |
|---|---|
| [Quick reference](docs/content/docs/agents/quick-reference.md) | Invariable rules cheat sheet for Rust, GDScript, PTY, security and CI |
| [Testing](docs/content/docs/agents/testing.md) | Writing or running tests, the gate commands, the UI/UX assessment method |
| [Defect classes](docs/content/docs/agents/defect-classes.md) | Writing a bug fix, triaging a defect, or running the per-release defect review |
| [Rust conventions](docs/content/docs/agents/rust.md) | Touching anything under `crates/` |
| [GDScript conventions](docs/content/docs/agents/gdscript.md) | Touching anything under `godot/` |
| [GDScript performance](docs/content/docs/agents/gdscript-performance.md) | Auditing a GDScript hot path, or deciding whether work belongs in Rust |
| [Concept capture](docs/content/docs/agents/concept-capture.md) | Concepts, triggers, stop conditions, routing |
| [Inspector, Reasoning, and OMP](docs/content/docs/agents/inspector-reasoning-omp.md) | The agent-observability panes |
| [Plugin manifest](docs/content/docs/agents/plugins.md) | Plugin manifests, catalog, install and trust |
| [Security rules](docs/content/docs/agents/security.md) | Any change near IPC, PTY, the filesystem, plugins, networking, or secrets (read before editing) |
| [Pitfalls and tool notes](docs/content/docs/agents/pitfalls.md) | Before debugging, and before touching an FFI or CLI boundary: the known traps |
| [Pitfalls: GDScript](docs/content/docs/agents/pitfalls-gdscript.md) | Godot UI, nodes, theme tokens, styling, signals, and viewport traps |
| [Pitfalls: Rust & FFI](docs/content/docs/agents/pitfalls-rust.md) | gdext, Variant packing, thread boundaries, stores, and FFI rules |
| [Pitfalls: Terminal & PTY](docs/content/docs/agents/pitfalls-terminal.md) | ANSI/VTE parsing, SGR, escape codes, alt screen, and ConPTY traps |
| [Pitfalls: Platform & CI](docs/content/docs/agents/pitfalls-platform-ci.md) | Windows paths/DACL, macOS Mach-O, namespaces, and cache traps |
| [Repository map](docs/content/docs/agents/repo-map.md) | Finding which module or file owns a behaviour, or where a new file belongs |
| [Roadmap workflow](docs/content/docs/agents/roadmap-workflow.md) | Picking tasks, row syntax, priority ordering, screenshots, and roadmap maintenance |
| [Releasing](RELEASING.md) | Preparing or cutting a release, or changing the release workflow |
| Agent skills (`skill://<name>`) | Any task: load the matching skill before the first edit - bodies live in `.omp/skills/<name>/SKILL.md` |

## Project Structure

- Stack: Rust (edition 2024, `crates/`) backend + Godot (4.7, `godot/`) GDScript frontend via `gdext` (0.5); entry point `godot/scenes/main.tscn` → `workspace.gd` (root `Control` node).
- Crates: `gpty-core` (PTY spawn, vte parser, alacritty grid, capture, history, vault), `gpty-ai` (Inspector backends: mock, private OMP RPC, CLI NDJSON bridge; no tools), `gpty-ipc` (JSON-RPC transport, client, server), `gpty-gdext` (the GDExtension: `GptyTerminal`, `GptyAi`, `GptyCliView`, `GptyMarkdown`, `GptyMedia`), `gpty` (in `crates/gpty-cli`: CLI + MCP), `gpty-media` (pinned FFmpeg backend), `gpty-plugin` (installed-plugin store the CLI and GDExtension share).
- Godot: `godot/scenes/autoloads/` (managers + persistence base), `terminal/` (workspace, pane rendering and input, IPC dispatch, tile lifecycle), `ui/` (chrome, overlays, theme, graph canvas), `panes/` (one body per pane type); tests in `godot/tests/{unit,integration}`, the capture harness in `godot/tests/bench/`.
- The file-by-file map with one-line roles is [Repository map](docs/content/docs/agents/repo-map.md) - read it to find which module owns a behaviour.

## Commands

See [CONTRIBUTING.md](CONTRIBUTING.md) for all development, build, test, and CLI commands.

### Data Flow

```
Shell → PTY I/O thread → vte parser → alacritty_terminal grid → Arc<Mutex<TermGrid>> → GptyTerminal (gdext) → GDScript _draw()
```

```
CLI → Unix socket (gpty.sock) → IpcServer (tokio) → PENDING_IPC queue → GDScript _poll_ipc_requests() → workspace methods → IPC_RESPONDERS → CLI response
```

```
OMP TUI (user-launched in a terminal) → @gpty/omp-events extension → gpty-events.sock (ompEvent) → omp_events.rs translates to the generic vocabulary (session.bound, agent.started, turn.started, tool.call, thinking.delta, …) → GptyTerminal.drain_agent_events() → Reasoning pane + Tier 1 agent-state badges

Any pane program → `gpty state <value>` → gpty-events.sock (ompEvent, the pane's own capability) → `state.declared` → Tier 1 agent-state badge (the declaration path on Windows, where ConPTY consumes the `gpty_state` OSC)
```

```
Inspector prompt → GptyAi.session_open/session_prompt → private omp --mode rpc --no-tools --no-session process → session_poll envelopes
```

```
cli_view pane config (command + shell_args) → GptyCliView.start(argv) → CliProcess (piped child, merged stdout/stderr) → line queue → GptyCliView.poll_lines → CliViewPane body
```

```
media pane → GptyMedia.open(JSON) → gpty-media MediaSession worker thread (pinned FFmpeg demux/decode) → bounded RGBA/PCM queues → GptyMedia.poll_video/poll_audio → pane
```

## MCP Integration

gPTY ships an MCP server (`gpty mcp`) that exposes 27 tools for AI agent integration.
AI agents and coding harnesses can discover these via the `mcp.json` that's at the root of the repository.

```json
// mcp.json - Coding harnesses should discover this automatically
{"mcpServers": {"gpty": {"command": "gpty", "args": ["mcp"]}}}
```

Tools: `new-pane`, `list-panes`, `workspace-list`, `kill-pane`, `focus-pane`, `move-pane`, `inject`, `profile-save`, `profile-load`, `profile-list`, `daemon-start`, `daemon-stop`, `daemon-status`, `concept-list`, `concept-toggle`, `pane-read`, `pane-status`, `pane-view`, `pane-set`, `pane-settings`, `pane-run`, `pane-wait`, `broadcast`, `vault-search`, `vault-read`, `vault-weight`, `version`.

`tools/call` validates the requested name against `schema::mcp_tool_names()` before dispatch: the kebab→camel mapping turns any string into an IPC method, so without the gate a client reaches methods that were never published as tools (e.g. `shutdown`).

A tool's arguments travel under the ids clap gives them (`pane_type`), while the handler reads the CLI's wire key (`type`). `commands/wire.rs` is the one translation: it derives each argument's JSON type from the clap definition (an `Append` list, a boolean flag, an integer field), renames the handful of ids that differ (`RENAMES`), and refuses an unknown key (naming the nearest valid one), a value of the wrong JSON type, or a contradictory pair with `-32602`. A new argument needs no second list; a *renamed* wire key needs an entry in that table, and `wire_keys_are_the_keys_the_handlers_read` fails if a translated key is one no handler reads.

The MCP tool schemas are auto-generated from clap command definitions in `crates/gpty-cli/src/commands/schema.rs`. Nested subcommands (`daemon`, `profile`) are flattened into prefixed tools. Self-referential tools (`mcp`, `schema`) are excluded.

A tool call the handler refuses is a *successful* `tools/call` response with `isError: true`, the handler's own sentence in the text content, and its code in `structuredContent`; JSON-RPC errors are reserved for a malformed call (the argument translation's `-32602`, an unknown tool or method) and a dead endpoint. Refusals travel flat end to end: the GUI's drain loop answers the handler's `{code, message}` error object itself, and the Rust edge builds the JSON-RPC error from it, so a CLI or MCP caller reads the sentence instead of a stringified envelope.

See `skill://gpty-omp-integration` (body at `.omp/skills/gpty-omp-integration/SKILL.md`) for usage patterns.

## Roadmap workflow

`ROADMAP.md` is an index, and the roadmap itself is a **prioritized queue** split into one page per release chain under `docs/content/docs/roadmap/` (`v0.1.md` … `v1.0.md`, then `future.md`; the Hugo site renders them as children of the Roadmap section, and `docs/content/docs/roadmap/_index.md` renders `ROADMAP.md` as the section's front page). Each row's evidence lives on `docs/content/docs/roadmap/details/<area>.md`, keyed by a stable `AREA-N` ID.

- **Execution guide & gates:** Read [Roadmap workflow](docs/content/docs/agents/roadmap-workflow.md) and load `skill://gpty-roadmap-task` (body at `.omp/skills/gpty-roadmap-task/SKILL.md`) before working a row: they carry the execution order, per-area gates, row format (`| status | [AREA-N](details/area.md#area-n) | **Title** |`), ID rules, priority rules, screenshot conventions, and close-out contract. `scripts/roadmap` is the reader/writer (`next`, `show`, `next-id`, `close`, `rearea`, `stats`, `release-check`).
- **Picking the next task:** The next task is always the first unchecked row (⬜) in the *earliest unfinished release*. Row order *is* priority; `./scripts/roadmap next` prints the ID, title and detail path, and `./scripts/roadmap show <ID>` prints the record. IDs are identity, never order.
- **Row identity:** An ID is allocated once (`./scripts/roadmap next-id <AREA>`) and never renumbered or reused; its prefix is the area, so there is no Area column. Moving a row between releases keeps its ID and detail section. A closed row carries a `Commits:` line written by `./scripts/roadmap close`; an obsolete row is `🚫` with the reason in its detail, never deleted.
- **Priority ordering:** Data-loss and correctness first, then reachable security, headline features, robustness and tests, low-reachability hardening, polish, and release-time work.
- **Defects & follow-ups:** A defect or follow-up discovered mid-task gets its own row in priority position (a new ID) with actionable evidence rather than being fixed silently or folded into unrelated commits.

## ADE Architecture Boundary

gPTY is evolving from a multi-terminal emulator into an ADE - a graphical PTY foundation with a public, agent-facing API:

| Layer | Owner | Content |
|---|---|---|
| L4 | ecosystem | Agent CLIs & apps: claude code, codex, opencode, OMP, vim, btop |
| L3 | ecosystem (open market) | Orchestration: agent waits, pane states, plugin workflows (herdr-class) |
| L2 | gPTY | Control surface: JSON-RPC socket, CLI, MCP, event socket |
| L1 | gPTY | PTY foundation: PTY lifecycle, grid, capture, history, security |
| L0 | OS | /dev/ptmx, ConPTY, sockets |

- **gPTY owns L0–L2; L3 is an open market.** gPTY ships a thin built-in L3 (concept routing, Inspector sessions, profile restore) but never absorbs an orchestrator's state machine into core. Herdr-class tools are guests (they run in panes today) and substrate consumers (they drive the public API), not competitors to clone.
- **Observe/display, never orchestrate.** Core observes and displays agent state (badges, status); it never manages or orchestrates it (no agent runtime, no wait/block state machine). Primitives only: `paneStatus`, `waitForOutput`, events.
- **Non-goals** (do not re-propose without new evidence):
  - `pane-pipe` MCP tool - the concept engine already routes pane output; a generic pipe is a broad-trigger concept.
  - `layout-apply-preset` workflow automation - plugin territory (events + actions).
  - First-party `gpty herdr *` subcommands - couples gPTY core to a foreign, versioned socket protocol with an auth model gPTY does not control (L3 creep).
  - Native third-party GDScript/Rust pane plugins in v1 - `PaneTypes.ALL` is the layout-trust anchor; a plugin-registered registry lets profile files instantiate arbitrary code at restore time. `cli_view` (stdout streaming) is the v1 plugin UI; a native pane SDK needs its own trust design.
  - `ToolRunning` state via exit codes - foreground-command exits are not reliably attributable in a PTY.
  - Webview/WebSocket panes - a new trust boundary; not v1.
- **Positioning & naming:** the wedge is GUI + public-API PTY foundation + concept engine + Windows + hardening. Keep the `gpty` name (2026-09 decision): rebranding is positioning, not renaming. Two-tier naming convention: the display name is `gPTY` (UI, docs, prose); machine-facing identifiers stay lowercase/actual - `gpty` binary, crates, repo, and socket paths; `GPTY_*` env vars; `GptyTerminal`; `@gpty/omp-events`.

## Logging

- **A program's output is not log material.** Pane output, a captured buffer, injected or pasted text, environment values and an agent backend's stderr are never logged above `debug`, and never written to a file by default. Ids, paths, counts, PIDs, error discriminants and mode bits are fine.
- **The rule is enforced, not remembered.** `scripts/check-log-hygiene` (run by `ci-check`) fails a `log::*!` whose format string or arguments name program content (`text`, `data`, `output`, `payload`, `stdout`, `stderr`, `line`, `input`, `capture`, `content`, `body`, `prompt`, `command`, `argv`, `env`) unless the call carries a `// log-ok: <why it is safe>` marker, and the marker is a claim a reviewer checks.
- **Backend stderr has one path.** `gpty_ai::logtext::spawn_drain` strips escape sequences and control characters, bounds each line to `MAX_LINE_BYTES`, logs at `debug` and fills the bounded `StderrTail` that rides the failure message a user sees. A failed `omp` start-up appends that tail to its error; the `cli` backend answers a non-zero exit with it. Do not add a second drain and do not raise the level.
- **No log file by default.** `project.godot` leaves Godot's file logging off; a launch that turns it on (`--log-file`) inside the user directory has that directory repaired to 0700 and its `*.log` files to 0600 at start-up (`BasePersistenceManager.secure_user_root`, through the same `owner_only` primitive the stores use).

## Licensing

- Core is **GPL-3.0-or-later** ([LICENSE](LICENSE)); [LICENSE-EXCEPTIONS.md](LICENSE-EXCEPTIONS.md) holds the two section 7 additional permissions. Plugins, extensions, adapters, and pane types are **not** required to be GPLv3, which is why the bundled `extensions/gpty-omp-events` ships MIT and `godot/addons/gut` stays MIT. Do NOT "correct" a bundled permissive license into GPLv3, and never add license headers to JSON.
- Data files (profiles, workspaces, layouts, concepts, settings) carry no copyleft: user-authored ones are the user's own, and the shipped `godot/*.json` defaults are Apache-2.0. The engine and pane code that reads them stays GPLv3.
- First-party code is GPLv3 everywhere it is declared: `license = "GPL-3.0-or-later"` in every `crates/*/Cargo.toml`, `license=('GPL-3.0-or-later')` in `dist/aur/PKGBUILD`. Keep them in sync when adding a crate or package.
- Release artifacts must carry `LICENSE` and `LICENSE-EXCEPTIONS.md` next to the binaries (GPLv3 §4/§6 requires giving recipients a copy of the license). `.github/workflows/release-build.yml`'s `export` job stages both copies into all three archives and publishes a `SHA256SUMS` covering every asset (`release.yml` calls that shared build workflow from the tag) - keep both when editing that job. Every uploaded asset is also build-provenance attested (`actions/attest-build-provenance`, needing `id-token: write` + `attestations: write`), so `gh attestation verify` binds a download to the workflow run that produced it. Supply-chain rules for the workflows: every third-party action is pinned to a full commit SHA with the version in a trailing comment, and every CI download (Godot editor, Godot export templates, Hugo) is checksum-verified against the vendor's published sums before use - the tag is mutable, the hash is the pin.

## Commits

- Format: [Conventional Commits](https://www.conventionalcommits.org/) - `feat(scope):`, `fix(scope):`, `chore(scope):`, `docs(scope):`
- DCO: every commit carries a `Signed-off-by` trailer (`git commit -s`); `githooks/commit-msg` refuses a commit without one.
- Scopes: `settings`, `terminal`, `layout`, `workspace`, `sidebar`, `ui`, `gdext`, `core`, `cli`, `ipc`, `profiles`, `concepts`, `icons`, `ci`, `ai`, `inspector`, `media`, `plugin`, `wiki`, `deps`, `docs`, `build`, `sec`, `project` (aligned with core crates, subsystems, and roadmap areas).
- Every `fix` commit carries a `Cause: <class>` trailer naming one value from [Defect classes](docs/content/docs/agents/defect-classes.md) (`scripts/fix-forensics --classes` prints them); `githooks/commit-msg` refuses one without. `external` covers dependency advisories, upstream API changes and retired runners. If a fix honestly fits no class the taxonomy is missing one - add it to the guide and to `scripts/fix-forensics` in the same commit.
- A commit that advances a roadmap row carries a `Roadmap: <ID>` trailer (e.g. `Roadmap: GUI-188`); `./scripts/roadmap close <ID>` reads it to fill the row's `Commits:` line.
- Workflow: use the commit skill (`skill://commit`, body at `.omp/skills/commit/SKILL.md`) to discover changes, group them logically and write the message. The hooks are the enforcement layer: `pre-commit` runs `./scripts/ci-check --fast` (fmt, workflow lint, clippy), `pre-push` runs the full `./scripts/ci-check`; install them with `./scripts/install-hooks` once per clone.
- Skills protocol compatibility: Skills are stored at `.omp/skills/<name>/SKILL.md`. OMP routes them natively via `skill://<name>`. Non-OMP agent harnesses (Antigravity, Claude Code, Cursor, Copilot) can navigate directly to `.omp/skills/<name>/SKILL.md`.
- Never commit without the full suite passing. `cargo fmt`/`cargo clippy` also run in pre-commit - run them explicitly before staging to avoid amend churn.
- Land through the merge queue: after approval, `gh pr merge --auto --merge` enqueues the PR; never click **Update branch** or run `gh pr update-branch`. Auto-merge is enabled and head branches are deleted on merge (`scripts/branch-prune` cleans local ones).
- A failing test: fix the source, not the test. Update a test only when the behaviour change is intentional and documented in the commit body; a test-only commit without a source change is a red flag.
- `git commit -n` / `git push --no-verify` bypass the hooks: emergencies only, and say why in the commit body.
