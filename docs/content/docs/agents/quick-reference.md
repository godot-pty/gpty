---
title: "Quick reference"
weight: 10
---

Top invariable rules and invariants across the project. Read this card for fast lookup; detailed rationale and edge cases live in the dedicated topic guides.

## Architecture & Boundaries

- **L0–L2 Owned, L3/L4 Open Market:** gPTY owns the PTY foundation (L1) and public control surface (L2: JSON-RPC socket, CLI, MCP, events). Orchestration (L3) and agents (L4) are guests; core never absorbs orchestrator state machines or background runners.
- **Observe and Display, Never Orchestrate:** Core displays agent state (badges, status); it does not manage agent lifecycles or background blocks. Primitives only: `paneStatus`, `waitForOutput`, events.
- **Public API Boundary:** The MCP tool list is auto-generated from clap commands in `crates/gpty-cli/src/commands/schema.rs`. All agent verbs travel through documented tools and methods.
- **Display Name vs. Identifier:** UI and prose use `gPTY`. Machine identifiers stay lowercase: `gpty` binary, crate names, repo, socket paths, env vars (`GPTY_*`).

## Godot & GDScript Invariants

- **Single-Threaded SceneTree:** Godot's SceneTree is strictly single-threaded. Background Rust threads must NEVER call Godot methods or mutate nodes directly. Queue updates for GDScript polling or use `call_deferred()`.
- **No NUL in Strings:** Godot strings cannot hold `\u0000` (NUL is decoded as `\uFFFD` and triggers parser warnings at load). Never use NUL checks in GDScript; validate path and string terminators in Rust.
- **`TextEdit` Deferred Signals:** Programmatic assignment `text = ...` emits `text_set`, not `text_changed`. `text_changed` is emitted only by edits and is deferred by one frame (`call_deferred`). In tests, use simulated typing drivers rather than direct assignment.
- **Untyped Arrays Across FFI:** gdext `Array<Variant>` parameters reject typed GDScript arrays like `Array[Dictionary]` at runtime. Always pass untyped `Array` across the GDExtension boundary.
- **Geometry & Custom Minimum Size:** In Godot 4.7+, a container layout requires `custom_minimum_size`. A stylebox's content margins define its minimum dimensions; an empty track or all-zero box collapses sizing.
- **Escape Key & GUI Input:** In Godot 4.7.2, `_gui_input` is delivered exclusively to the focused control and does not bubble to ancestors. Intercept Escape at an input stage with focus checks rather than in container `_gui_input`.

## Rust & GDExtension Invariants

- **Short-Lived Grid Lock:** `TermGrid` is wrapped in `Arc<Mutex<TermGrid>>`. Acquire the lock briefly, extract or clone needed damage/cells, and drop the guard immediately. Never hold locks across blocking I/O or tokio yields.
- **Clean Teardown via `Drop`:** When a `GptyTerminal` is freed (`queue_free()`), Rust teardown must terminate spawned shells and cancel tokio tasks in `Drop` to prevent orphaned processes and zombie threads.
- **Tokio Runtime:** One process-wide `LazyLock` tokio runtime in `gpty-gdext` is shared across all terminal instances. Never instantiate ad-hoc tokio runtimes.
- **Blocking Operations on Worker Pools:** SQLite operations, vault index passes, and file reads must run on `spawn_blocking` or dedicated threads, never on the main GUI thread polling IPC.
- **No Unwinding Panics Across FFI:** Panics crossing the C/FFI boundary cause undefined behavior or process aborts. Catch errors in Rust and return structured error JSON or default values.

## Security, Logging & Ownership

- **Output Is Never Log Material:** Pane output, captured terminal buffers, injected/pasted text, environment values, and backend stderr are never logged above `debug`, and never written to disk by default. Enforced by `scripts/check-log-hygiene`.
- **Owner-Only Files (0700 / 0600):** Runtime directories and state files (`user://`, SQLite databases, sockets, scratch files) must be created and repaired to 0700 (directories) and 0600 (files). Enforced via `owner_only` helpers.
- **Regular File & Path Gates:** Any path read by the GUI or backend must be validated as an absolute, local, regular file (`fstat`/`is_file`, `O_NONBLOCK | O_NOFOLLOW`). FIFOs, special devices, and directory traversals are rejected before open.
- **Timing Invariance:** Authentication token checks (`GPTY_SECRET`) must compare bytes in constant time without early-exit branch leaks.

## Testing & CI Gates

- **Safe Fixture Paths:** Fixtures go through `TestPaths` only - `fresh_dir("name")` for a fixed-name directory (it clears the previous run's leftover first), `remove_tree(path)` for cleanup, and `is_safe_path_under(path, root, windows)` when a comparison is needed, because a raw prefix compare cannot agree on `C:\` from the environment and `C:/` after `path_join`. Never call `DirAccess.open("")` (which opens the project root).
- **Fast Local Gate:** Run `./scripts/ci-check --fast` before staging. It checks formatting (`cargo fmt`), workflow lint, docs validity (`scripts/docs-check`), clippy, GDExtension surface, log hygiene, and theme tokens.
- **Windowed vs. Headless:** Headless Godot runs have a 0×0 or 64×64 root viewport, no display driver, no hover states, and no tooltips. Layout, pixel-diff, and pointer tests must run headed or set viewport sizes explicitly.
- **No `--no-verify`:** Never bypass commit hooks (`git commit -n`) or push hooks without documenting an emergency justification in the commit body.
