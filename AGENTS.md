# Agent Guide

Rust + Godot multi PTY emulator with a tiling grid GUI.

## Project Structure

- Stack: Rust (edition 2024) backend + Godot (4.7) with a GDScript frontend via `gdext` (0.5)
- Entry point: `godot/scenes/main.tscn` → `workspace.gd` (root `Control` node)

```
gpty/
├── Cargo.toml                  # Workspace root
├── AGENTS.md
├── LICENSE
├── scripts/                    # CI runner and setup scripts
│   ├── ci-check                # Run all CI checks locally (--fast for quick)
│   └── install-hooks           # Symlink githooks into .git/hooks/
├── githooks/                   # Git hook scripts
│   ├── pre-commit              # Fast checks (fmt, workflow lint, clippy)
│   ├── pre-push                # Full CI suite before push
│   └── commit-msg              # Conventional Commits enforcement
├── crates/
│   ├── gpty-core/              # PTY spawning, ANSI parsing, alacritty_terminal grid, pub-sub
│   │   └── src/
│   │       ├── lib.rs          # Module map + data-flow diagram
│   │       ├── types.rs        # Concept, Event, Action, CaptureMode, CapturedOutput
│   │       ├── concept.rs      # Regex matching + label routing (pure fns)
│   │       ├── engine.rs       # WorkspaceEngine, capture state machine, SpawnedTerminal
│   │       ├── pty.rs          # portable-pty spawn + dedicated I/O thread
│   │       ├── parser.rs       # vte → plain-text LineParser
│   │       ├── term.rs         # alacritty_terminal grid + CellInfo + damage tracking
│   │       ├── color.rs        # ANSI color → RGB
│   │       ├── keymap.rs       # Key event → byte sequence
│   │       └── history.rs      # SQLite scrollback store
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
│   │           ├── schema.rs
│   │           ├── mcp.rs
│   │           ├── daemon.rs
│   │           └── layout.rs
│   ├── gpty-ipc/               # Shared JSON-RPC 2.0 IPC transport, client, and server
│   │   └── src/
│   │       ├── protocol.rs     # JSON-RPC 2.0 Request, Response, JsonRpcError
│   │       ├── types.rs        # IPC domain types (NewPaneParams, PaneInfo, …)
│   │       ├── transport.rs    # Platform socket connection (Unix, named pipe)
│   │       ├── server.rs       # Async IPC server with handler registry
│   │       └── client.rs       # Async IPC client with connect/call/timeout
│   └── gpty-gdext/             # GDExtension cdylib: GptyTerminal GodotClass
│       └── src/lib.rs
└── godot/                      # Godot 4.7 project
    ├── project.godot
    ├── gpty.gdextension
    ├── concepts.default.json   # Shipped default concepts
    ├── fonts/                  # DejaVu Sans Mono + Phosphor icons
    └── scenes/
        ├── main.tscn
        ├── autoloads/          # Singleton managers
        │   ├── base_persistence_manager.gd
        │   ├── settings_manager.gd
        │   ├── profile_manager.gd
        │   ├── concept_manager.gd
        │   ├── layout_manager.gd
        │   ├── focus_manager.gd
        │   ├── toast_manager.gd
        │   ├── shortcut_manager.gd
        │   └── update_checker.gd
        ├── terminal/
        │   ├── workspace.gd        # Root controller, concept routing, profile restore
        │   ├── terminal_pane.gd    # Control-based renderer, keyboard, selection
        │   └── terminal_manager.gd # Tile lifecycle, split/kill/swap/spawn
        ├── ui/
        │   ├── sidebar.gd
        │   ├── settings_panel.gd
        │   ├── toast_overlay.gd
        │   └── icons.gd            # Phosphor icon constants
        └── panes/
            ├── pane_body.gd        # Base class
            ├── code_viewer.gd
            ├── file_tree.gd
            └── observer_pane.gd
```

## Commands

See [CONTRIBUTING.md](CONTRIBUTING.md) for all development, build, test, and CLI commands.

### Data Flow

```
Shell → PTY I/O thread → vte parser → alacritty_terminal grid → Arc<Mutex<TermGrid>> → GptyTerminal (gdext) → GDScript _draw()
```

```
CLI → Unix socket → IpcServer (tokio) → PENDING_IPC queue → GDScript _poll_ipc_requests() → workspace methods → IPC_RESPONDERS → CLI response
```

## MCP Integration

gpty ships an MCP server (`gpty mcp`) that exposes 12 tools for AI agent integration.
AI agents and coding harnesses can discover these via the `mcp.json` that's at the root of the repository.

```json
// mcp.json — Coding harnesses should discover this automatically
{"mcpServers": {"gpty": {"command": "gpty", "args": ["mcp"]}}}
```

Tools: `new-pane`, `list-panes`, `kill-pane`, `focus-pane`, `inject`, `layout-save`, `layout-load`, `layout-list`, `daemon-start`, `daemon-stop`, `daemon-status`, `version`.

The MCP tool schemas are auto-generated from clap command definitions in `crates/gpty-cli/src/commands/schema.rs`. Nested subcommands (`daemon`, `layout`) are flattened into prefixed tools. Self-referential tools (`mcp`, `schema`) are excluded.

See `skill://gpty-omp-integration` for usage patterns.

## Testing

- Tests live in `godot/tests/` — `unit/` for pure-logic classes, `integration/` for scene-tree tests.
- Mocking autoloads: Use `MockAutoloads.setup()` / `teardown()` in `before_each`/`after_each`.
- Persistence managers (`SettingsManager`, `ProfileManager`, `LayoutManager`) are mocked via `set_script()` on the existing autoload node, redirecting `_read_file`/`_write_file` to an in-memory Dictionary - avoids touching disk and preserves Godot 4 global name bindings. (`SettingsManager` etc. are static constants — never `free()` autoload nodes).
- Signal testing: GDScript lambdas cannot capture outer primitives. Use GUT's `watch_signals(node)` + `assert_signal_emitted(node, "signal_name")` instead of `node.signal.connect(func(): captured_var = true)`.
- Type checks: `body is SomeClass` requires a compile-time class name. For runtime type discrimination, use `body._pane_type()` string discriminators.
- Headless resource leaks: GUT warnings about unfreed children and GDExtension `RID`/`ObjectDB` leaks are benign in headless mode — the dummy render server doesn't track GDExtension resources. Production renderer handles these correctly.

## Conventions

### Rust

- Edition: 2024 (requires Rust ≥ 1.85)
- Format: standard `rustfmt`
- Async runtime: `tokio` (global `LazyLock` runtime in gdext)
- Grid sharing: `Arc<Mutex<TermGrid>>` — lock briefly, clone the grid, release
- Thread Safety: Godot's SceneTree is strictly single-threaded. NEVER call Godot methods, mutate nodes, or emit signals directly from background `tokio` threads. Instead, queue the state changes for GDScript to poll, or use Godot's thread-safe `call_deferred()`.
- Lifecycle & Teardown: When a `GptyTerminal` is destroyed (e.g., `queue_free()` in Godot), the Rust side MUST ensure the spawned shell and background `tokio` tasks are cleanly terminated (via the `Drop` trait) to prevent zombie processes or memory leaks.

### GDScript

- Indentation: tabs
- Icons: All glyphs live in `icons.gd` as `const` strings (Phosphor Regular PUA codepoints via `\uXXXX`). To add: pick from phosphoricons.com, get the codepoint, add a `const`. Call `Icons.style_button(btn)` after setting `btn.text`.
- Profiles: named terminal-layout snapshots (`user://profiles.json`). `ProfileManager` autoload manages CRUD + `profiles_changed` signal. Save dialog is built inline in `workspace.gd` (not a separate scene). Profile activation clears the workspace (`_reset()`) then rebuilds tiles — follows `_do_restore()` pattern.
- JSON → typed arrays: `JSON.parse()` returns untyped `Array`. Assignment to `Array[Dictionary]` fails at runtime. Always iterate and build the typed array element-by-element: `for item in raw: if item is Dictionary: typed.append(item)`.
- Private members: underscore prefix (`_cell_w`, `_settings_panel`)
- Config vars: `_cfg_` prefix (`_cfg_cursor_shape`)
- Persistence: Managers extend `BasePersistenceManager` — provides `_read_file(path)` / `_write_file(path, data)`, sets `PROCESS_MODE_ALWAYS`. Subclasses override `_on_init()` instead of `_ready()`. Never inline `FileAccess.open()` — use `_read_file`/`_write_file`.
- Directory layout: Scripts are grouped by role: `autoloads/` (7 managers + 1 base), `terminal/` (core terminal), `ui/` (sidebar, settings, toast), `panes/` (specialty pane types). `project.godot` autoload paths and `preload()`/`load()` calls use the full `res://scenes/<dir>/<file>.gd` path.
- Settings pipeline: `_cfg_*` → `_save_settings()` → `user://settings.json`. To add a new setting: (1) add `_cfg_` var, (2) add UI control, (3) add one line to `_apply_settings_to()`. `_build_wrapper()` calls it automatically — no other wiring needed.
- Terminal spawning: `_build_wrapper()` is the sole entry point; all paths go through it
- Layout Constraints: The tiling grid relies on Godot `Control` nodes. Prefer using Godot's built-in Size Flags (Expand/Fill) inside containers (`HBoxContainer`/`VBoxContainer`) over manual pixel math. When manual math is absolutely required (like terminal cell reflows), hook into `_notification(NOTIFICATION_RESIZED)`.
- Pub-Sub Bridge: To handle `WorkspaceEngine` events (like regex concept triggers) in Godot, GDScript must poll the Rust backend in `_process()` or rely on Rust calling `call_deferred("emit_signal", ...)`.

### Concept Capture System

- Two capture modes: `SingleLine` (broadcast Event for command injection) and `UntilStop { stop_timeout_ms, stop_on_input }` (buffer output until timeout or user input).
- UntilStop matching: `match_and_broadcast` matches on PTY output lines. When it returns `Some((name, UntilStop{..}, target))`, the engine enters capture mode — subsequent PTY output is buffered, not fed to the grid. On timeout or user input, `finalize_capture()` queues a `CapturedOutput` event.
- Capture lifecycle:
  - PTY output feeds `LineParser` → lines flow to `match_and_broadcast` (engine.rs PTY output handler).
  - If a concept matches and has `UntilStop` capture mode → engine enters capture state, buffers raw bytes, suppresses grid feed.
  - Timeout or user input → `finalize_capture()` queues `CapturedOutput` with plain-text lines and target label.
  - GDScript polls via `drain_concept_events()` each frame, routes to receiver pane by `target_pane_type`.
  - Receiver found → `acknowledge_capture` (bytes discarded). No receiver → `flush_capture` (bytes replayed to grid) + toast.
- Prompt restoration: Shell prompts lack trailing `\n` so `LineParser` never emits them. On acknowledge, raw bytes after last `\n` are extracted and fed to grid with `\r\n` prefix for correct cursor positioning.
- Default concepts: Shipped in `godot/concepts.default.json`. `ConceptManager._merge_concepts()` deep-merges defaults + user concepts (user keys overlay default keys). Trigger migration updates old regex patterns to new ones.
- Concept event routing: `workspace.gd._process()` polls all terminal panes, drains events, routes to receiver pane by `_pane_type()`. No receiver → toast + flush.

### Security

- Concept Engine ReDoS: The `gpty-core` crate MUST always use the standard Rust `regex` crate. PCRE or back-tracking engines are strictly prohibited to prevent ReDoS (Regex Denial of Service) attacks when parsing large amounts of terminal output.
- OSC 52 Clipboard Syncing: `parser.rs` currently discards all terminal escape sequences, keeping copy/paste safely bound to Godot UI inputs. Do NOT implement OSC 52 clipboard injection/syncing without placing it behind an explicit Godot confirmation dialog to prevent drive-by clipboard hijacking.

### Commits

- Format: [Conventional Commits](https://www.conventionalcommits.org/) — `feat(scope):`, `fix(scope):`, `chore(scope):`
- Scopes: `settings`, `terminal`, `layout`, `sidebar`, `gdext`, `core`, `cli`, `ipc`, `profiles`, `concepts`, `icons`, `ci`
- Workflow: Use the commit skill (`skill://commit`) to discover changes, group them logically, and produce correctly-formatted messages. The git hooks (pre-commit, commit-msg, pre-push) are the enforcement layer that catches bypasses.
- CI gates: `pre-commit` runs fast checks (fmt, workflow lint, clippy). `pre-push` runs the full `./scripts/ci-check` suite. Install with `./scripts/install-hooks` once per clone.

### Commit Discipline

- Use the commit skill (`skill://commit`) as the normal workflow — it handles grouping, README freshness, and Conventional Commits.
- The git hooks are the safety net: pre-commit catches fmt/lint issues, commit-msg enforces message format, pre-push runs the full CI suite.
- NEVER commit without running `./scripts/ci-check` first. If it fails, fix the failures before committing.
- `cargo fmt` and `cargo clippy` run automatically in the pre-commit hook — but run them explicitly before staging to avoid amend churn.
- If a test fails: fix the SOURCE code, not the test. Only update a test if the behavior change is intentional AND documented in the commit message body.
- Test-only commits without corresponding source changes are a red flag. If you find yourself tweaking a test "just to make it pass," STOP — the test is catching a real issue or the test expectations are wrong. Either way, a commit must include both the source fix and the test update together.
- Push only after the full suite passes. The pre-push hook enforces this; `git push --no-verify` bypasses it — use ONLY in emergencies, and expect CI to catch what you skipped.
- If you must bypass: document why in the commit message body.

### Pitfalls

- `Drop` impl for external resources: Any Rust struct holding a child process (`portable_pty::Child`) or I/O thread MUST implement `Drop` to call `.kill()`. Otherwise closing a terminal in Godot orphans the shell process and reader thread.
- `tokio::select!` None branches: When a channel returns `None` (closed), `select!` disables that branch but keeps polling others instantly — causing 100% CPU. Bind to a variable first (`msg = rx.recv()`), then `let Ok(v) = msg else { break; }`.
- vte `Perform::execute` CR/LF: PTY output uses CRLF pairs. The vte parser calls `execute` per byte. If you commit on both `\r` and `\n`, every line produces a spurious empty string. Track `last_was_cr` and skip the `\n` commit when preceded by `\r`.
- `alacritty_terminal` display_iter: returns negative line numbers for scrollback history rows. Never cast directly to `usize` — it wraps to a huge value. Always add the grid's `display_offset()` to normalize: `let line = (indexed.point.line.0 + offset) as usize`.
- GDScript `\UXXXXXXXX` escape: GDScript only supports `\uXXXX` (4-hex-digit BMP). `\UXXXXXXXX` (8-digit) does not exist — the parser mangles it. For non-BMP codepoints, use `char(0x10XXXX)` in `static var` initializers. Prefer BMP alternatives; this project's icons use Phosphor PUA codepoints (U+E000–U+F8FF), all expressible as `const` with `\uXXXX`.
- Typed arrays break Rust FFI: gdext `Array<Variant>` parameters reject GDScript's `Array[Dictionary]` at runtime ("expected array of type Untyped, got Builtin(DICTIONARY)"). Always pass untyped `Array` across the FFI boundary. Prefer `func f(arr: Array)` over `func f(arr: Array[Dictionary])` when the array originates from or goes to Rust.
- Multi-line `for` array colon: `for x in [...]` with a multi-line array literal requires `]:` at the end. Forgetting the colon produces a parse error at an unrelated line. Double-check after replacing inline array content.
- Godot typed Arrays: `Array[T]` won't accept plain `Array`. If you type a parameter, check all call sites use matching types (`var x: Array[Control] = []`).
- GDExtension rebuilds: After changing `#[func]` signatures or adding methods, rebuild with `cargo build -p gpty-gdext` and restart Godot.
- GDScript default params: Evaluated at definition time, not call time. `func f(x := some_var)` captures the value of `some_var` when the script loads. Use `func f(x := -1)` and check `if x < 0: x = some_var` inside the body for runtime-evaluated defaults.
- `extends Node` won't render `Control` children: Only `Control` nodes can render child `Control`s (Labels, Buttons, etc.). If you add a Label to a plain `Node`, it's invisible. Use `extends Control` for UI containers and set `z_index` for layering.
- `tokio::time::Instant::now() + Duration::MAX` panics: The addition overflows. Use a safe large constant like `Duration::from_secs(86400 * 365)` (1 year) for inactive timeout sleeps.
- `tokio::pin!` + `reset()` for capture timeouts: Use `tokio::pin!(sleep)` and `sleep.as_mut().reset(deadline)` to re-arm a timeout without recreating it each iteration. One `select!` branch, no code duplication.
- `continue` in `for` does not skip trailing code: A `continue` inside a `for` loop only skips the current iteration — code BELOW the loop still executes. Use `break` + a boolean flag to conditionally skip post-loop grid feeding.
- Concept regex on PTY output: `match_and_broadcast` checks every line of PTY output against all concepts. `SingleLine` concepts broadcast events for command injection. `UntilStop` concepts start capture mode — their return value from `match_and_broadcast` MUST be used to set `active_capture_name` and `active_capture_target`. Ignoring the return value (`let _ = match_and_broadcast(...)`) silently disables UntilStop capture.
- Tab completion triggers concept matches: Bash reprints the prompt and partial command when showing autocomplete candidates. This reprinted line has no trailing `\n`, so `LineParser` never emits it. Tab completion never triggers concept matching.
- Raw-byte buffering for grid replay: Never buffer parsed lines for later grid replay — the alacritty_terminal ANSI state machine needs raw bytes with escape sequences intact. Buffer `Vec<Vec<u8>>` (chunks), replay with `feed_grid(board, chunk)`.
- Rendering Performance: GDScript `_draw` is slow when calling `draw_rect`/`draw_string` character-by-character. Avoid generating heavy data structures (like `Dictionary`) per-cell across the FFI boundary. Prefer packing data into flat arrays (`PackedByteArray`, `PackedInt32Array`) in Rust, and batch rendering operations line-by-line in Godot.
- Resize Rate Limiting: Firing SIGWINCH heavily on every frame during window drag will overwhelm the child PTY process. Always debounce or rate-limit terminal `_on_resize` events before passing them to the backend.
- Scrollback vs. PageUp/Down: `terminal_pane.gd:_handle_keyboard` intercepts PageUp/Down for scrollback navigation. These never reach the PTY, so programs like `less` or `vim` cannot receive them. Users must use alternative keys (`b`/`f` in `less`, `Ctrl+B`/`Ctrl+F` in vim).
- Alt key handling: For Alt+letter combos, the Rust keymap returns `None`, expecting the GDScript layer to prepend `\x1b` (ESC). `_handle_keyboard` does this in the `_key_to_text` fallback path.
- PTY Enter key: The Enter key MUST send `\r` (CR) to the PTY, not `\n`. `pty.rs:write_line` appends `\r`. The PTY terminal driver translates `\r` → `\n` in canonical mode; raw-mode programs read `\r` directly.

- `tokio::task::JoinHandle` drop detaches: dropping a `JoinHandle` does NOT abort the task — it keeps running until it exits naturally. For explicit cleanup (e.g., in a `Drop` impl), call `handle.abort()`.
- `std::sync::Once` poisoning: if the closure passed to `Once::call_once` panics, the `Once` is permanently poisoned — all subsequent calls panic too. For lazy init that spawns fallible work, use `AtomicBool::swap(true, Relaxed)` or `Mutex<Option<...>>` instead.

- **Resize cascades from layout changes**: When panes are added/removed, remaining terminals receive multiple `NOTIFICATION_RESIZED` events in rapid succession. Even when calculated rows×cols are identical, each `resize_grid()` call triggers a full grid re-wrap and sync, producing a visible "scrolling through history" animation. Fix: `TermGrid::resize()` must return early if dimensions are unchanged. Also apply a pixel-level check in the GDScript debounce to avoid redundant calls.
- Shared static state in integration tests: tests that mutate shared `static` state (queues, maps) must clean up in ALL exit paths — including timeout, error, and panic branches. A stale queue entry from one test will break the next test. Write a `clear_state()` helper and call it in every test.

### Agent Tool Notes

- **gdext `#[func]` parameter types: ONLY `GString`, `bool`, and `i64` are reliably marshaled as input parameters.** `Array<Variant>`, `Dictionary`, and bare `Variant` all silently fail — the GDScript call succeeds but the Rust body never executes. Workaround: serialize complex data to JSON in GDScript (`JSON.stringify()`), pass as `GString`, deserialize in Rust with `serde_json::from_str`.
- **Empty `cmd` in concept actions: concept actions with `"cmd": ""` are valid (capture-only — output is captured but no command is injected). Do NOT filter them out with `!cmd.is_empty()` guards — the `target` label is needed for routing even when `cmd` is empty. Only require `!target.is_empty()`.
- **Concept push startup race: GDExtension classes aren't registered when autoloads initialize.** `ConceptManager._on_init()` must defer its push via `call_deferred("_push_to_rust")`. A `GptyTerminal.new()` created during autoload init produces a zombie object whose `#[func]` methods silently no-op. Use `ClassDB.instantiate("GptyTerminal")` inside `call_deferred` — this works once Godot's class database is ready. A secondary push from `workspace.gd` via `await create_timer(2.0)` serves as fallback.

- GDScript `///` comments: GDScript uses `#` or `##` for comments. Rust-style `///` causes a parse error. Always use `##` for doc comments in GDScript.
- Edit tool on structured formats (YAML, TOML, Markdown frontmatter): the line-based `edit` tool can corrupt delimiter-sensitive files (YAML `---` blocks, TOML `[sections]`, frontmatter bounds). When editing config files, workflow YAML, or Hugo content, prefer `eval` with Python (`yaml.safe_load`, `tomllib`) to parse → modify → serialize. Reserve `edit` for Rust, GDScript, and plain Markdown where line semantics hold.

## Notes

- `terminal_pane.gd` is the sole renderer (Control-based); the legacy Node2D `terminal.gd` was removed.
- Font-size changes now auto-recalculate cell metrics via a setter on `font_size` — no need to recreate terminals.
- The global tokio runtime is initialized once at GDExtension init and shared across all GptyTerminal nodes.
