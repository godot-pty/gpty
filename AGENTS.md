# Agent Guide

Rust + Godot multi PTY emulator with a tiling grid GUI.

## Guides

This file holds the rules every change needs. The detailed rules live in one page per topic; read the ones your change touches before editing.

| Guide | Read it when |
|---|---|
| [Testing](docs/content/docs/agents/testing.md) | Writing or running tests, the gate commands, the UI/UX assessment method |
| [Rust conventions](docs/content/docs/agents/rust.md) | Touching anything under `crates/` |
| [GDScript conventions](docs/content/docs/agents/gdscript.md) | Touching anything under `godot/` |
| [Concept capture](docs/content/docs/agents/concept-capture.md) | Concepts, triggers, stop conditions, routing |
| [Inspector, Reasoning, and OMP](docs/content/docs/agents/inspector-reasoning-omp.md) | The agent-observability panes |
| [Plugin manifest](docs/content/docs/agents/plugins.md) | Plugin manifests, catalog, install and trust |
| [Security rules](docs/content/docs/agents/security.md) | Any change near IPC, PTY, the filesystem, plugins, networking, or secrets (read before editing) |
| [Pitfalls and tool notes](docs/content/docs/agents/pitfalls.md) | Before debugging, and before touching an FFI or CLI boundary: the known traps |

## Project Structure

- Stack: Rust (edition 2024) backend + Godot (4.7) with a GDScript frontend via `gdext` (0.5)
- Entry point: `godot/scenes/main.tscn` → `workspace.gd` (root `Control` node)

```
gpty/
├── Cargo.toml                  # Workspace root
├── AGENTS.md                   # Agent guide core; topic pages live in docs/content/docs/agents/
├── ROADMAP.md                  # Opening text + links to the release-chain pages
├── CHANGELOG.md                # Opening text + links to the per-release pages
├── docs/
│   ├── content/docs/agents/    # Agent guide topic pages (Rust, GDScript, security, ...)
│   ├── content/docs/roadmap/   # One page per release chain (v0.N.md, future.md)
│   ├── content/docs/changelog/ # One page per release (vX.Y.Z.md)
│   └── static/images/          # Release screenshots + roadmap evidence images
├── LICENSE
├── LICENSE-EXCEPTIONS.md       # GPLv3 §7 permissions: plugins + data stay non-copyleft
├── scripts/                    # CI runner and setup scripts
│   ├── ci-check                # Run all CI checks locally (--fast for quick)
│   ├── install-hooks           # Symlink githooks into .git/hooks/
│   └── build                   # Build standalone app for the host platform
├── githooks/                   # Git hook scripts
│   ├── pre-commit              # Fast checks (fmt, workflow lint, clippy)
│   ├── pre-push                # Full CI suite before push
│   └── commit-msg              # Conventional Commits enforcement
├── crates/
│   ├── gpty-ai/                # Inspector backends (mock, private OMP RPC, CLI NDJSON bridge; no tools)
│   ├── gpty-core/              # PTY spawning, ANSI parsing, alacritty_terminal grid, capture
│   │   └── src/
│   │       ├── lib.rs          # Module map + data-flow diagram
│   │       ├── types.rs        # Concept, Action, CaptureMode, CapturedOutput
│   │       ├── concept.rs      # Trigger matching + capture routing (pure fns)
│   │       ├── engine.rs       # WorkspaceEngine, capture state machine, SpawnedTerminal
│   │       ├── pty.rs          # portable-pty spawn + dedicated I/O thread
│   │       ├── parser.rs       # vte → plain-text LineParser
│   │       ├── term.rs         # alacritty_terminal grid + CellInfo + damage tracking
│   │       ├── color.rs        # ANSI color → RGB
│   │       ├── keymap.rs       # Key event → byte sequence
│   │       ├── cli.rs          # CliProcess: piped argv child, line queue
│   │       ├── history.rs      # SQLite scrollback store
│   │       └── vault.rs        # SQLite + FTS5 vault index (wiki pane's notes and search)
│   ├── gpty-media/            # Media backend: pinned FFmpeg binding, sessions, packed frames/PCM
│   │   ├── components.txt     # Closed FFmpeg component set (build recipe ↔ runtime allowlists)
│   │   ├── src/
│   │   │   ├── lib.rs         # Path gate, caps, allowlists, module map
│   │   │   ├── probe.rs       # Open/inspect, demuxer aliases, stream selection
│   │   │   ├── session.rs     # Decode thread, bounded queues, seek/epoch, RGBA/PCM
│   │   │   └── error.rs       # Stable error codes
│   │   └── tests/             # Fixtures (generated), decode/seek/path tests, binding rules
│   ├── gpty-cli/               # CLI workspace control over JSON-RPC IPC
│   │   ├── Cargo.toml
│   │   └── src/
│   │       ├── main.rs         # clap CLI entry point
│   │       └── commands/       # Subcommand handlers
│   │           ├── mod.rs
│   │           ├── new_pane.rs
│   │           ├── list_panes.rs
│   │           ├── kill_pane.rs
│   │           ├── focus_pane.rs
│   │           ├── inject.rs
│   │           ├── pane_read.rs
│   │           ├── pane_status.rs
│   │           ├── pane_run.rs
│   │           ├── pane_wait.rs
│   │           ├── broadcast.rs
│   │           ├── schema.rs
│   │           ├── mcp.rs
│   │           ├── concept.rs
│   │           ├── daemon.rs
│   │           └── layout.rs
│   ├── gpty-ipc/               # Shared JSON-RPC 2.0 IPC transport, client, and server
│   │   └── src/
│   │       ├── protocol.rs     # JSON-RPC 2.0 Request, Response, JsonRpcError
│   │       ├── types.rs        # IPC domain types (NewPaneParams, PaneInfo, …)
│   │       ├── transport.rs    # Platform socket connection (Unix, named pipe)
│   │       ├── server.rs       # Async IPC server with handler registry
│   │       └── client.rs       # Async IPC client with connect/call/timeout
│   └── gpty-gdext/             # GDExtension cdylib: GptyTerminal + GptyAi + GptyCliView + GptyMarkdown
│       └── src/
│           ├── lib.rs          # GptyTerminal GodotClass: session lifecycle, input, grid access helpers
│           ├── grid_api.rs     # GptyTerminal grid facet: packed updates, cursor, scrolling, live search
│           ├── history_api.rs  # GptyTerminal history facet: flush, prune, FTS search, size on disk
│           ├── vault_api.rs    # GptyTerminal vault facet: note index, vault search (static)
│           ├── capture_api.rs  # GptyTerminal capture facet: engine-global concepts, per-pane captures
│           ├── bridge_api.rs   # GptyTerminal bridge facet: IPC queue, event fan-out, static metadata
│           ├── ai.rs           # Per-pane GptyAi session bridge
│           ├── ipc.rs          # Workspace-control IPC server
│           ├── omp_events.rs   # Capability-scoped OMP event socket
│           ├── cli_view.rs     # GptyCliView: argv child, streamed stdout
│           ├── markdown.rs     # Markdown → sanitized BBCode
│           └── media_api.rs    # GptyMedia: JSON + packed arrays over gpty-media
├── extensions/
│   └── gpty-omp-events/        # Explicit OMP plugin; dormant unless GPTY_EVENT_* is set
├── skills/
│   └── gpty/SKILL.md           # Bundled agent skill, printed by `gpty --skill`
└── godot/                      # Godot 4.7 project
    ├── project.godot
    ├── gpty.gdextension
    ├── concepts.default.json   # Shipped default concepts
    ├── profiles.default.json   # Shipped recommended layouts (Agent Workspace)
    ├── fonts/                  # DejaVu Sans Mono + Phosphor icons
    └── scenes/
        ├── main.tscn
        ├── autoloads/          # Singleton managers
        │   ├── base_persistence_manager.gd
        │   ├── settings_manager.gd
        │   ├── profile_manager.gd
        │   ├── concept_manager.gd
        │   ├── workspace_store.gd  # Named workspace (tab set) persistence
        │   ├── pane_env_store.gd   # User-owned per-pane env, keyed by attachment_id
        │   ├── trusted_store.gd    # Workspace Trust consent memory (builtins + plugins)
        │   ├── link_weights_store.gd # User-owned declared link weights (display-only)
        │   ├── focus_manager.gd
        │   ├── toast_manager.gd
        │   ├── shortcut_manager.gd
        │   └── update_checker.gd
        ├── terminal/
        │   ├── workspace.gd        # Root controller, workspace switching, concept routing, profile restore
        │   ├── ipc_handlers.gd     # WorkspaceIpcHandlers - pane-API/IPC method dispatch (extracted)
        │   ├── concept_router.gd   # Pure concept-event routing (extracted, testable)
        │   ├── plugin_review_text.gd # Pure plugin-review dialog text (extracted, testable)
        │   ├── terminal_pane.gd    # Control-based renderer, keyboard, mouse, selection, history search
        │   ├── terminal_manager.gd # Tile lifecycle, split/kill/swap/spawn
        │   └── tile_drag.gd        # Divider-drag state machine (extracted)
        ├── ui/
        │   ├── sidebar.gd
        │   ├── settings_panel.gd
        │   ├── status_bar.gd
        │   ├── toast_overlay.gd
        │   ├── window_chrome.gd    # Titlebar + window-mode/fullscreen handling (extracted)
        │   ├── markdown_view.gd     # Safe, debounced Markdown RichTextLabel
        │   ├── markdown_anchors.gd  # Pure ATX heading scan for fragment/line navigation
        │   ├── vault_graph_model.gd # Pure vault link-graph normalize/layout/hit-test
        │   ├── link_weights.gd      # Pure declared-weight vocabulary (paths, range, lookup)
        │   ├── vault_graph_view.gd  # Custom-drawn vault link-graph canvas
        │   ├── palette.gd           # Shared UI accent colors
        │   └── icons.gd            # Phosphor icon constants
        └── panes/
            ├── pane_body.gd        # Base class + routed-content contract
            ├── pane_types.gd       # Pane registry, sanitizers, palette command list
            ├── viewable_files.gd   # Closed table: which paths open in the viewer
            ├── media_files.gd      # Closed table + path gate for the media pane
            ├── code_viewer.gd
            ├── file_tree.gd
            ├── text_read.gd        # Shared read guard: regular-file gate + 1 MiB cap
            ├── inspector_pane.gd   # Private read-only OMP Q&A
            ├── cli_view_pane.gd    # Command stdout streamed into a pane body
            ├── reasoning_pane.gd   # Passive OMP reasoning projection
            ├── media_pane.gd       # Local audio/video playback
            └── wiki_pane.gd        # Vault browser and Markdown note editor
```

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

gPTY ships an MCP server (`gpty mcp`) that exposes 22 tools for AI agent integration.
AI agents and coding harnesses can discover these via the `mcp.json` that's at the root of the repository.

```json
// mcp.json - Coding harnesses should discover this automatically
{"mcpServers": {"gpty": {"command": "gpty", "args": ["mcp"]}}}
```

Tools: `new-pane`, `list-panes`, `kill-pane`, `focus-pane`, `inject`, `layout-save`, `layout-load`, `layout-list`, `daemon-start`, `daemon-stop`, `daemon-status`, `concept-list`, `concept-toggle`, `pane-read`, `pane-status`, `pane-run`, `pane-wait`, `broadcast`, `vault-search`, `vault-read`, `vault-weight`, `version`.

`tools/call` validates the requested name against `schema::mcp_tool_names()` before dispatch: the kebab→camel mapping turns any string into an IPC method, so without the gate a client reaches methods that were never published as tools (e.g. `shutdown`).

The MCP tool schemas are auto-generated from clap command definitions in `crates/gpty-cli/src/commands/schema.rs`. Nested subcommands (`daemon`, `layout`) are flattened into prefixed tools. Self-referential tools (`mcp`, `schema`) are excluded.

See `skill://gpty-omp-integration` for usage patterns.

## Roadmap workflow

`ROADMAP.md` is an index, and the roadmap itself is a **prioritized queue** split into one page per release chain under `docs/content/docs/roadmap/` (`v0.1.md` … `v1.0.md`, then `future.md`; the Hugo site renders them as children of the Roadmap section, and `docs/content/docs/roadmap/_index.md` renders `ROADMAP.md` as the section's front page). Work it like this:

- **Picking the next task** - the next task is the first unchecked row (⬜) in the *earliest unfinished release*: open the chain pages in version order, take the first chain that still has a ⬜, and take the first ⬜ on that page (a chain page lists its releases oldest-first, so an earlier release with a leftover ⬜ comes before a later one). The index marks each chain `released`, `in progress`, `planned` or `unscheduled`. Future is never picked from. No grouping by origin, no separate "carry-over" headings: within a release, row order *is* the priority, and the top row is the answer to "what's next".
- **Row format** - one row per line in the page's table: `| ✅ or ⬜ | AREA | **Title** - evidence, fix, tests |`. The Area is one of TERM, GUI, IPC, CLI, SEC, PLUGIN, WIKI, CONCEPT, MEDIA, AGENT, CORE, BUILD, DOCS, PROJECT. Escape a literal `|` in the text as `\|`, and keep `<` inside backticks (the site omits raw HTML). There is no size or discovered-date column: sizing was only a tie-break, and provenance is in git history and, where it matters, in the row text ("found by the October audit", "measured on commit …"). Titles stay unique; other rows and docs refer to a row by its bold title.
- **Ordering** (used when adding or re-prioritizing rows) - data-loss and correctness first, then security with a reachable path, then the release's own features, then robustness and tests, then low-reachability hardening, then polish, then work that can only happen at release time (tagging, packaging against a released artifact). Ties break toward the smaller item. The owner may promote the release's headline feature ahead of the hardening tail once the correctness and security block is closed; when it is done, say so in the row rather than leaving the queue ambiguous.
- **Future** - ideas that are not designed yet and work that says in its own text what evidence would start it. Anything concrete and committed belongs in a numbered release (new releases may be added beyond the current last one, and v1.0 stays last); when a Future entry is defined enough to build, move it into a release in priority position.
- **New rows found while working** - a defect or follow-up discovered mid-task does not get fixed silently, queued in a comment, or folded into an unrelated commit: add it to the right release as its own row, in priority position, with the evidence that makes it actionable (what breaks, how it was found, what the fix is). Fixing it immediately is fine when it is genuinely part of the current row's contract; otherwise it waits in the queue.
- **Evidence screenshots** - `docs/static/images/` holds two kinds of image, told apart by name. Release screenshots are `v<version>_<n>.png` (written by `scripts/screenshot-gpty`, used by the release blog entry and README). Evidence for a roadmap row is `issue-v<build>-<slug>.png`: `<build>` is the version the capture was taken on (an issue image is only true for that build, so a recapture adds a new file instead of replacing one), `<slug>` names what it shows. Never embed an image in a table cell. List the images in a `## Screenshots` section at the bottom of the chain page, each as a bold caption that names the row(s) it evidences by their bold titles and says what every numbered box marks (the numbers live in the image and nothing else explains them), then the image as `![what it shows](/images/<file>.png)`; the row itself can end with a short pointer such as "Screenshot (under Screenshots below): *Pane Settings*." Audits, assessments and design reviews are not committed as documents: their findings and outcomes become roadmap rows, the method goes in AGENTS.md, and only the captures a row points at are kept.
- **Completed rows** stay under their release with the evidence (what shipped, measured numbers, tests) - the release section doubles as the record. The changelog carries the user-facing summary at release time: one page per release under `docs/content/docs/changelog/` (`vX.Y.Z.md`), linked from the root `CHANGELOG.md`, which holds only its opening text and the link list.
- **Folded-up detail** - when a triage note, correction, or clarification exists for a row, it belongs *in* that row's text, not in a separate "corrections" row. A row that turns out to be partly done gets narrowed to what remains rather than left asserting a fixed problem.
- **Adding a chain** - create `docs/content/docs/roadmap/<slug>.md` with front matter (`title`, a `weight` after the previous chain's), a short paragraph on what the chain accomplishes, then one `## vX.Y.Z - Name` section per release with the table; link it from `ROADMAP.md` as `docs/content/docs/roadmap/<slug>.md` (the site rewrites that to a section-relative link).

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

## Licensing

- Core is **GPL-3.0-or-later** ([LICENSE](LICENSE)); [LICENSE-EXCEPTIONS.md](LICENSE-EXCEPTIONS.md) holds the two section 7 additional permissions. Plugins, extensions, adapters, and pane types are **not** required to be GPLv3, which is why the bundled `extensions/gpty-omp-events` ships MIT and `godot/addons/gut` stays MIT. Do NOT "correct" a bundled permissive license into GPLv3, and never add license headers to JSON.
- Data files (profiles, workspaces, layouts, concepts, settings) carry no copyleft: user-authored ones are the user's own, and the shipped `godot/*.json` defaults are Apache-2.0. The engine and pane code that reads them stays GPLv3.
- First-party code is GPLv3 everywhere it is declared: `license = "GPL-3.0-or-later"` in every `crates/*/Cargo.toml`, `license=('GPL-3.0-or-later')` in `dist/aur/PKGBUILD`. Keep them in sync when adding a crate or package.
- Release artifacts must carry `LICENSE` and `LICENSE-EXCEPTIONS.md` next to the binaries (GPLv3 §4/§6 requires giving recipients a copy of the license). `.github/workflows/release.yml` stages both copies into all three archives and publishes a `SHA256SUMS` covering every asset - keep both when editing that job. Every uploaded asset is also build-provenance attested (`actions/attest-build-provenance`, needing `id-token: write` + `attestations: write`), so `gh attestation verify` binds a download to the workflow run that produced it. Supply-chain rules for the workflows: every third-party action is pinned to a full commit SHA with the version in a trailing comment, and every CI download (Godot editor, Godot export templates, Hugo) is checksum-verified against the vendor's published sums before use - the tag is mutable, the hash is the pin.

## Commits

- Format: [Conventional Commits](https://www.conventionalcommits.org/) - `feat(scope):`, `fix(scope):`, `chore(scope):`
- Scopes: `settings`, `terminal`, `layout`, `workspace`, `sidebar`, `ui`, `gdext`, `core`, `cli`, `ipc`, `profiles`, `concepts`, `icons`, `ci`, `ai`, `inspector`
- Workflow: Use the commit skill (`skill://commit`) to discover changes, group them logically, and produce correctly-formatted messages. The git hooks (pre-commit, commit-msg, pre-push) are the enforcement layer that catches bypasses.
- CI gates: `pre-commit` runs fast checks (fmt, workflow lint, clippy). `pre-push` runs the full `./scripts/ci-check` suite. Install with `./scripts/install-hooks` once per clone.

## Commit Discipline

- Use the commit skill (`skill://commit`) as the normal workflow - it handles grouping, README freshness, and Conventional Commits.
- The git hooks are the safety net: pre-commit catches fmt/lint issues, commit-msg enforces message format, pre-push runs the full CI suite.
- NEVER commit without running `./scripts/ci-check` first. If it fails, fix the failures before committing.
- `cargo fmt` and `cargo clippy` run automatically in the pre-commit hook - but run them explicitly before staging to avoid amend churn.
- If a test fails: fix the SOURCE code, not the test. Only update a test if the behavior change is intentional AND documented in the commit message body.
- Test-only commits without corresponding source changes are a red flag. If you find yourself tweaking a test "just to make it pass," STOP - the test is catching a real issue or the test expectations are wrong. Either way, a commit must include both the source fix and the test update together.
- Push only after the full suite passes. The pre-push hook enforces this; `git push --no-verify` bypasses it - use ONLY in emergencies, and expect CI to catch what you skipped.
- If you must bypass: document why in the commit message body.
