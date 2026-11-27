---
title: "Repository map"
weight: 90
---

The file-by-file map, one line per module's role. Read it to find which module
owns a behaviour; it is a map, not an inventory - `rg --files <dir>` enumerates.

```
gpty/
├── Cargo.toml                  # Workspace root
├── rust-toolchain.toml         # Pinned Rust 1.96.0 for local and CI builds
├── AGENTS.md                   # Agent guide core; topic pages live in docs/content/docs/agents/
├── ROADMAP.md                  # Opening text + links to the release-chain pages
├── CHANGELOG.md                # Opening text + links to the per-release pages
├── RELEASING.md                # Canonical release process; the agent checklist is .omp/skills/release/SKILL.md
├── docs/
│   ├── content/docs/agents/    # Agent guide topic pages (Rust, GDScript, security, ...)
│   ├── content/docs/roadmap/   # Queue: one page per release chain (v0.N.md, future.md); details/<area>.md holds each row's evidence, screenshots/<chain>.md the captures
│   ├── content/docs/changelog/ # One page per release (vX.Y.Z.md)
│   ├── content/wiki/           # Knowledge-base vault; scripts/build-wiki packs it into godot/knowledge.json
│   ├── data/cost-history.json  # Memory-cost ledger; scripts/render-cost-chart draws the README chart from it
│   ├── data/capabilities/      # Capability catalogue, one JSON per area (state, not the queue); scripts/check-capabilities gates it
│   └── static/images/          # Release screenshots, roadmap evidence images, the generated cost chart
├── LICENSE
├── LICENSE-EXCEPTIONS.md       # GPLv3 §7 permissions: plugins + data stay non-copyleft
├── scripts/                    # CI runner and setup scripts
│   ├── ci-check                # Run all CI checks locally (--fast for quick)
│   ├── check-secrets           # Refuse credential formats in the git index (ci-check --fast)
│   ├── check-macos-minos       # Fail a Mach-O slice built for a newer macOS than the app
│   ├── check-github-settings   # Read back rulesets, release environment and Actions policy
│   ├── bot-token               # Mint the gpty-bot app installation token (--check for setup)
│   ├── pr                      # Push/open/wait/land a branch through the merge queue
│   ├── git-askpass-token       # GIT_ASKPASS helper used by scripts/pr
│   ├── build-wiki              # Pack docs/content/wiki into godot/knowledge.json
│   ├── build-docs              # Pack the README's Markdown closure into godot/docs.json
│   ├── roadmap                 # Roadmap ledger: next, show, next-id, close, rearea, stats, release-check
│   ├── install-hooks           # Symlink githooks into .git/hooks/
│   ├── install-cli             # Install a release bundle behind a stable PATH link
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
│   │       ├── scheme.rs       # Colour-scheme import: native JSON, Alacritty, iTerm2, Base16, legacy CSV
│   │       ├── store.rs        # Shared SQLite store plumbing: write lock, damaged-file recovery
│   │       ├── vault.rs        # SQLite + FTS5 vault index (wiki pane's notes and search)
│   │       ├── agent_state.rs  # AgentState: the three-tier, display-only agent detection model
│   │       ├── links.rs        # Wikilink parse/resolve (pure); the vault store owns when they run
│   │       ├── lock.rs         # lock_or_warn: a poisoned lock skips the work, never aborts
│   │       ├── escstring.rs    # Bounds the OSC/ESC payload vte would otherwise grow unbounded
│   │       ├── hardening.rs    # Keeps GPTY_SECRET out of a pane's reach (Windows process DACL)
│   │       └── owner_only.rs   # 0600/0700 modes for gPTY's own files, repaired on the way in
│   ├── gpty-media/            # Media backend: pinned FFmpeg binding, sessions, packed frames/PCM
│   │   ├── components.txt     # Closed FFmpeg component set (build recipe ↔ runtime allowlists)
│   │   ├── src/
│   │   │   ├── lib.rs         # Path gate, caps, allowlists, module map
│   │   │   ├── probe.rs       # Open/inspect, demuxer aliases, stream selection
│   │   │   ├── session.rs     # Decode thread, bounded queues, seek/epoch, RGBA/PCM
│   │   │   ├── error.rs       # Stable error codes
│   │   │   └── source.rs      # The one place a validated path becomes bytes (never FFmpeg's own open)
│   │   └── tests/             # Fixtures (generated), decode/seek/path tests, binding rules
│   ├── gpty-cli/               # CLI workspace control over JSON-RPC IPC
│   │   ├── Cargo.toml
│   │   ├── skills/gpty/SKILL.md # Bundled agent skill, printed by `gpty --skill`
│   │   └── src/
│   │       ├── main.rs         # clap CLI entry point
│   │       ├── plugin_manifest.rs # gpty-plugin.toml schema, caps and validator
│   │       ├── tests.rs        # In-crate roundtrip tests (real IPC server on a temp socket)
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
│   │           ├── layout.rs
│   │           ├── move_pane.rs
│   │           ├── pane_view.rs
│   │           ├── pane_set.rs
│   │           ├── pane_settings.rs
│   │           ├── settings_args.rs
│   │           ├── plugin.rs
│   │           ├── state.rs
│   │           ├── vault.rs
│   │           └── wire.rs
│   ├── gpty-ipc/               # Shared JSON-RPC 2.0 IPC transport, client, and server
│   │   └── src/
│   │       ├── protocol.rs     # JSON-RPC 2.0 Request, Response, JsonRpcError
│   │       ├── transport.rs    # Platform socket connection (Unix, named pipe)
│   │       ├── server.rs       # Async IPC server with handler registry
│   │       ├── client.rs       # Async IPC client with connect/call/timeout
│   │       ├── lib.rs          # Public surface: protocol, transport, server, client
│   │       └── test_env.rs     # EnvVar guard: tests that set process env serialise through it
│   ├── gpty-plugin/            # Installed-plugin state shared by the CLI and the GDExtension
│   │   └── src/
│   │       ├── lib.rs          # Module map: schema (caps) + store (plugins.json, content/runtime dirs)
│   │       ├── schema.rs       # Caps the manifest validator and the store both enforce
│   │       └── store.rs        # plugins.json + per-plugin content/runtime dirs; atomic writes, additive keys ignored, a shape mismatch names the version skew, the read is bounded by MAX_STORE_BYTES
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
│           ├── media_api.rs    # GptyMedia: JSON + packed arrays over gpty-media
│           ├── diagnostics.rs  # log → Godot console bridge (warn+ from the gpty crates)
│           ├── store_api.rs    # Owner-only check/repair facet for the user:// stores
│           └── vault_ipc.rs    # vaultSearch/vaultRead answered natively on the blocking pool
├── extensions/
│   └── gpty-omp-events/        # Explicit OMP plugin; dormant unless GPTY_EVENT_* is set
├── fuzz/                       # cargo-fuzz workspace: its own lockfile, not a repository member
│   ├── Cargo.toml              # targets + pinned deps; `cargo +nightly fuzz run <target>`
│   ├── fuzz_targets/           # grid_feed, line_parser, ipc_request, vault_links, markdown, ai_frame, media_probe
│   └── corpus/                 # committed seeds; libFuzzer's 40-hex discoveries are gitignored
└── godot/                      # Godot 4.7 project
    ├── project.godot
    ├── gpty.gdextension
    ├── concepts.default.json   # Shipped default concepts
    ├── profiles.default.json   # Shipped recommended layouts (Agent Workspace, Knowledge Base)
    ├── knowledge.json          # Generated wiki bundle (scripts/build-wiki)
    ├── docs.json               # Generated documentation bundle (scripts/build-docs)
    ├── assets/                 # Brand assets
    │   ├── boot_splash.png     # Committed launch frame (application/boot_splash/image)
    │   └── fonts/Phosphor-Regular.ttf # UI icon font
    ├── fonts/                  # DejaVu Sans Mono (the terminal's font)
    ├── shaders/                # Bundled shaders (referenced by code, not a scene)
    │   ├── window_opacity.gdshader # Whole-window alpha veil (Workspace.apply_window_alpha)
    │   └── effects/            # The closed terminal-effect table's shaders (UiEffects)
    │       ├── crt.gdshader    # Static scanlines, a phosphor mask and a vignette
    │       └── grain.gdshader  # Animated film grain, 30 Hz in a half-res buffer
    └── scenes/
        ├── main.tscn
        ├── autoloads/          # Singleton managers
        │   ├── base_persistence_manager.gd
        │   ├── settings_manager.gd
        │   ├── profile_manager.gd
        │   ├── concept_manager.gd
        │   ├── workspace_store.gd  # Named workspace (tab set) persistence
        │   ├── pane_env_store.gd   # User-owned per-pane env, keyed by attachment_id
        │   ├── pane_cwd_store.gd   # User-owned per-pane directory, keyed by workspace id + attachment_id
        │   ├── pane_scheme_store.gd # User-owned per-pane colour scheme, keyed by attachment_id
        │   ├── saved_command_store.gd # User-owned saved commands (name / one line / run flag), in palette order
        │   ├── pane_inspector_store.gd # User-owned Inspector aim (prompt + switches), keyed by attachment_id
        │   ├── trusted_store.gd    # Workspace Trust consent memory (builtins + plugins)
        │   ├── link_weights_store.gd # User-owned declared link weights (display-only)
        │   ├── vault_registry.gd   # User-owned vault roots the socket's vault verbs may read
        │   ├── focus_manager.gd
        │   ├── toast_manager.gd
        │   ├── shortcut_manager.gd
        │   ├── update_checker.gd
        │   └── knowledge_store.gd  # Bundled knowledge base: seed + resolver over knowledge.json
        ├── terminal/
        │   ├── workspace.gd        # Root controller, workspace switching, concept routing, profile restore
        │   ├── ipc_handlers.gd     # WorkspaceIpcHandlers - pane-API/IPC method dispatch (extracted)
        │   ├── concept_router.gd   # Pure concept-event routing (extracted, testable)
        │   ├── plugin_review_text.gd # Pure plugin-review dialog text (extracted, testable)
        │   ├── terminal_pane.gd    # Control-based renderer, keyboard, mouse, selection, history search
        │   ├── terminal_fonts.gd   # Byte-only font loader (a data path never reaches load())
        │   ├── terminal_manager.gd # Tile lifecycle, split/kill/swap/spawn
        │   ├── pane_transitions.gd # Pane-transition registry, settings resolution and tween runner
        │   ├── pane_effects.gd     # Per-pane effect host: the ground material/buffer and the cue
        │   ├── tile_drag.gd        # Divider-drag state machine (extracted)
        │   └── divider_handles.gd  # Divider grab bands: one handle per divider segment
        ├── ui/
        │   ├── sidebar.gd           # Three modes: the column, a 48 px icon rail, a 20 px handle; one flyout
        │   ├── sidebar_flyout.gd    # The section flyout beside the rail (lazy rows, one card)
        │   ├── settings_panel.gd    # The rail/content/preview Settings card (sticky Resets, Back/Forward)
        │   ├── settings_preview.gd  # The Motion/Effects preview column and its sample playback
        │   ├── settings_sample.gd   # The scratch Control the previews animate (pane chrome + ground)
        │   ├── effect_surface.gd    # The effect layer the pane, the preview and the sidebar share
        │   ├── overlay_panel.gd     # Overlay keyboard contract (focus, Escape, focus return)
        │   ├── command_palette.gd   # Ctrl+Shift+P command list (OverlayPanel)
        │   ├── palette_model.gd     # Palette entries, matching and ranking (pure)
        │   ├── shortcut_catalog.gd  # The Shortcuts tab's keyboard list as data (chords from the binding registry)
        │   ├── shortcut_guide.gd    # The empty workspace guide: clickable live keycap + every binding (data-driven)
        │   ├── keyboard_focus.gd   # The keyboard-entry walk + the toolbar-ring pair
        │   ├── status_bar.gd
        │   ├── toast_overlay.gd
        │   ├── scroll_hints.gd     # The two scroll chevrons a pane overlays on a scrolling body
        │   ├── window_chrome.gd    # Titlebar + window-mode/fullscreen and opacity-flag handling (extracted)
        │   ├── markdown_view.gd     # Safe, debounced Markdown RichTextLabel
        │   ├── markdown_anchors.gd  # Pure ATX heading scan for fragment/line navigation
        │   ├── docs_bundle.gd       # Validated, lazily loaded view of godot/docs.json
        │   ├── docs_viewer.gd       # Settings > About: README + linked docs, Back/Forward
        │   ├── nav_history.gd       # Bounded back/forward trail with a pinned root (pure)
        │   ├── vault_graph_canvas.gd # Shared contract for the two vault link-graph presentations
        │   ├── graph_theme.gd # The graph's own closed theme table (default, planetary)
        │   ├── vault_graph_model.gd # Pure vault link-graph normalize/layout/hit-test
        │   ├── link_weights.gd      # Pure declared-weight vocabulary (paths, range, lookup)
        │   ├── vault_graph_view.gd  # Planar, custom-drawn vault link-graph canvas
        │   ├── vault_graph_3d.gd    # Orbital (3D) vault map: SubViewport, RigidBody3D nodes, spring edges
        │   ├── scheme_library.gd   # Shipped + imported colour schemes: listing, capped read, import id
        │   ├── scheme_picker.gd    # One colour-scheme OptionButton (library, reset item, Import…)
        │   ├── ui_palette.gd       # The chrome colours in two complete sets (dark/light) and the active one
        │   ├── color_swatch.gd     # The words a colour swatch carries: opacity reading, "unset", tooltip
        │   ├── ui_tokens.gd        # The type scale, spacing, radius and the WCAG contrast maths
        │   ├── ui_motion.gd        # The motion policy (Off/Subtle/Full) every animation reads
        │   ├── ui_effects.gd       # The closed effect table (ambient + cue) and intensity policy
        │   ├── display_rate.gd     # The window's screen and refresh rate, behind seams
        │   ├── ui_theme.gd         # The one Theme, built from the palette and applied at the root
        │   ├── app_dialog.gd       # The one modal builder (theme, grouped buttons, selectable body)
        │   ├── section_help.gd      # The shared "Help" affordance a section header carries (glyph → action → chord table)
        │   ├── feedback_text.gd     # Pure Feedback issue title/body/URL builder (build facts only, capped)
        │   ├── external_link.gd     # The one outbound-link path: OS.shell_open, clipboard fallback, WARN toast
        │   ├── accessibility.gd    # Accessible surface owner: names, values, published text (A11y)
        │   ├── a11y_content.gd     # A published content node: a Control that writes its own a11y role
        │   ├── agent_badge.gd      # Title-bar agent-state badge: the four silhouettes, painted
        │   ├── icons.gd            # Phosphor icon constants
        │   ├── concept_graph_editor.gd # GraphEdit overlay: the visual concept-rule editor
        │   ├── concept_graph_model.gd  # Pure rule-chain model: placement, layout and edit operations
        │   ├── menu_items.gd           # The one native PopupMenu item builder (icon, words, tooltip, metadata)
        │   └── pane_settings_panel.gd  # Pane settings overlay; delegates to the pane's own builder
        └── panes/
            ├── pane_body.gd        # Base class + routed-content contract
            ├── pane_types.gd       # Pane registry, sanitizers
            ├── backend_choice.gd   # Inspector backend vocabulary (aliases, dropdown rows)
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
