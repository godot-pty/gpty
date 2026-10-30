---
name: gpty-public-surface
description: "Add or change a gPTY control-surface verb or GDExtension method: route choice and registration lists, dispatch deadlines, GDScript handler and params validation, CLI subcommand plus the exhaustive may_autospawn choice, MCP auto-generation and its name gate, marshal rules, and the contract tests. Use when adding an IPC method, CLI command, MCP tool, or GDExtension export."
---

# gpty public surface

Two surfaces, one shape: a list in one language that must agree with a list in another. `skill://gpty-add-pane-type` is the pane-registry checklist; this is control-surface verbs and GDExtension methods. A mistake here is never a compile error — it is a method that answers "not found" to whichever caller finds it first, or a `#[func]` whose GDScript call succeeds while the Rust body never runs.

## A. Control surface: choose the route first

| Route | When | Where |
|---|---|---|
| Local Rust handler | needs no workspace state and no GDScript | `ipc.rs` `server.register(…)` — only `version` and `shutdown` |
| Native Rust handler | data that is not workspace state, and blocking work | `vault_ipc.rs` + `server.register` — the vault walk and SQLite run on the blocking pool so a query cannot stall the poll frame |
| GDScript | anything reading or mutating workspace state | add the name to `gdscript_methods` in `ipc.rs`, handle it in `ipc_handlers.gd` `handle(ws, method, params)` |

`crates/gpty-gdext/README.md` states the rule: new pane-API methods go in **both** the registration list and the handler module, unless they are directory-scoped like the vault pair.

## B. Dispatch mechanics (the parts that bite)

- **Deadline.** `fallback_timeout()` in `ipc.rs` maps `paneWait` → `PANE_WAIT_TIMEOUT`, `pluginInstall` → `PLUGIN_REVIEW_TIMEOUT`, everything else → `GDS_RESPONSE_TIMEOUT` (an answer from the poll loop, in ms). A deferred-answer method needs an arm there **and** in `dispatch_timeout()` — the server-side backstop is derived from the same pair.
- **Deferred answers live in the drain loop**, not the handler: `paneWait` registers a pending wait and `pluginInstall` opens the review dialog *before* dispatch, then a per-frame poll answers. A method that cannot answer in the same frame belongs there.
- **Params.** The Rust edge refuses a `params` that is not a JSON object with `-32602`; `WorkspaceIpcHandlers.request_params()` is the second layer because a GDScript call error on a mistyped value aborts the entire drain loop — every queued request then goes unanswered and each caller waits out its timeout. One bad value must cost one error response, never the batch.
- **Errors** return `{"error": {"code", "message"}}`; the drain loop turns that into JSON-RPC `success=false`. `-32602` for invalid params (same code as the Rust edge), `-32000` otherwise.
- **Results** are JSON-serialized by the loop; return a plain Dictionary/Array, not a pre-serialized string, unless the caller expects one.

## C. CLI subcommand

1. `main.rs` — an `enum Commands` variant with clap attributes.
2. `commands/mod.rs` — a dispatch arm calling `commands/<name>::run(client, …, json).await`.
3. `commands/<name>.rs` — build `serde_json::json!({…})` and call `super::call_and_format(client, "<camelCase method>", params, json)`.
4. **`may_autospawn()` in `main.rs` is exhaustive on purpose: a new subcommand must choose a side.** `true` only for commands a *fresh* GUI can satisfy (`new-pane`, `layout load`); everything else answers `daemon::NO_GUI_HINT`. Choosing wrong either opens a window that then fails the command, or refuses one a fresh GUI could have served.
5. The runtime is current-thread: no `spawn_blocking`, no `tokio::process`. Do not add a command that assumes workers.

## D. MCP comes for free — and that is the trap

- `commands/schema.rs` derives the tool list from clap: `get_about()` becomes the tool description, each arg's `get_help()` its parameter description; nested subcommands are flattened with prefixes and `mcp`/`schema` are excluded. There is no second list to edit.
- `tools/call` validates the name against `schema::mcp_tool_names()` before the kebab→camel mapping (`mcp.rs`). That gate is the only thing between a client and any method name it can spell — never widen or remove it.
- Update the docs that name the verb: `crates/gpty-cli/skills/gpty/SKILL.md` (printed by `gpty --skill`; `include_str!` from inside the crate, so it ships or it does not), `crates/gpty-cli/README.md`, AGENTS.md's tool list for an MCP tool, a wiki page, and a changelog row.

## E. GDExtension method

- Put the `#[func]` in the facet that owns the data: `grid_api.rs`, `history_api.rs`, `vault_api.rs`, `capture_api.rs`, `bridge_api.rs`, `media_api.rs`, or `lib.rs` — inside `#[godot_api]`, primary or `#[godot_api(secondary)]`. `check-ffi-surface` attributes each `#[func]` to the class named by its enclosing impl header and reports any `#[func]` outside a block.
- **Input marshalling**: only `GString`, `bool` and `i64` are reliable `#[func]` inputs. `Array<Variant>`, `Dictionary` and bare `Variant` silently fail — the GDScript call succeeds and the Rust body never runs. Complex input goes in as one JSON `GString`; collections go out as packed arrays, never per-cell dictionaries (`get_grid_updates_packed` is the model).
- GDScript must pass **untyped** `Array`: a typed `Array[Dictionary]` is rejected at runtime ("expected array of type Untyped").
- After adding a method or changing a signature: `cargo build -p gpty-gdext` and fully restart Godot — the editor keeps the old library mapped.
- Update `crates/gpty-gdext/README.md`'s surface table. `check-ffi-surface` also reads the README and `///`/`//!` comments: a backticked `name(...)` that is not a real export fails the gate.
- A **new class** (not a facet method) gets its own file, a `mod <file>;` in `lib.rs`, and a `ClassDB.instantiate` guard with a stale-extension status path in GDScript.

## F. Tests that catch what you missed

| Test | What it reads |
|---|---|
| `cargo test -p gpty-cli` | the contract test parses the real `ipc.rs` registrations, the `ipc_handlers.gd` arms, the `method ==` intercepts in `workspace.gd`, and every `client.call` literal, then asserts agreement with the advertised MCP tool names |
| `test_ipc_dispatch_contract.gd` | drives `WorkspaceIpcHandlers.handle` against a real `Workspace` — one instance per script, because each schedules a deferred concept push that must land while it is alive |
| `python3 scripts/smoke_pane_api.py` | the only test crossing CLI validation → Rust params → GUI registry on a real socket |
| `./scripts/check-ffi-surface` | `#[func]` exports against every GDScript call site, plus the crate's own prose |

## G. Gate

`./scripts/ci-check`. While iterating: `cargo build -p gpty-gdext` before any GUI/GUT run, and `godot --headless --path godot --import` after a new `class_name`.

## Maintenance

- The names here are the contract, not the locations: `gdscript_methods`, `fallback_timeout()`, `dispatch_timeout()`, `may_autospawn()`, `mcp_tool_names()`, `request_params()`, `call_and_format`. If one moved, re-locate it and keep the rule it encodes — the two lists must agree, and disagreement is runtime-only.
- The contract test catches drift only once the change is complete: it cannot invent a handler that was never written. Treat the checklist as the work and the test as the proof.
- If a new surface appears (another client, a socket protocol), add its registration list to the route table before writing any handler.
