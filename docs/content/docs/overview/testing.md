---
title: Testing
weight: 6
---

gpty's test strategy combines automated CI checks with a manual pre-release smoke test suite. Automated tests cover all pure-logic paths in Rust and GDScript; manual tests cover GUI interaction, IPC bridge roundtrips, and daemon lifecycle that require a running Godot instance.

## Automated (CI)

Run on every push and pull request:

```bash
# Rust — unit tests, integration tests, doctests
cargo test --workspace
cargo clippy -- -D warnings
cargo fmt --check

# GDScript — unit + integration tests
godot --headless --path godot --import
godot --headless --path godot -s addons/gut/gut_cmdln.gd -d \
  -gdir=res://tests/unit -gdir=res://tests/integration
```

**Rust coverage:** core engine (parser, keymap, grid, concept routing, capture state machine, history), IPC types + protocol, CLI schema generation, GDExtension FFI functions.

**GDScript coverage:** concept merge/save/load, terminal manager tile lifecycle (spawn, kill, swap, labels, grid-full refusal), settings save/load roundtrip, profile CRUD, layout save/restore, sidebar signal emission, pane settings application, IPC routing logic (error format, listPanes, killPane, layoutList), palette command generation.

**Known gaps (not automatable in headless CI):**
- `Workspace` class cannot be instantiated in headless GUT (depends on `GptyTerminal` GDExtension class). Workspace-level logic (concept event routing, IPC polling dispatch) is tested manually.
- Real PTY spawning is `#[ignore]` in Rust tests — slow and environment-dependent. Tested manually on Linux and Windows.

## Manual pre-release checklist

Run before tagging a release. Requires a built GDExtension library and a running Godot instance.

### Setup

```bash
cargo build -p gpty-gdext
cp target/debug/libgpty_gdext.so godot/bin/libgpty_gdext.linux.x86_64.so
godot --path godot &
```

All CLI commands below assume `GPTY_SOCKET=/tmp/gpty.sock` (the default on Linux) or the `GPTY_SOCKET` env var is set.

---

### IPC bridge — CLI-to-GUI roundtrip

**Given** the GUI is running with at least one auto-spawned terminal
**When** CLI commands are issued
**Then** the GUI responds correctly

| # | Command | Expected |
|---|---------|----------|
| 1 | `gpty version` | `gpty 0.3.0` / `protocol: 2.0` |
| 2 | `gpty new-pane --pane-type code_viewer` | Pane `C1` appears in sidebar |
| 3 | `gpty new-pane --pane-type file_tree` | Pane `F1` appears in sidebar |
| 4 | `gpty new-pane --pane-type observer` | Pane `O1` appears in sidebar |
| 5 | `gpty list-panes` | JSON array with 4 entries (T1, C1, F1, O1), correct `type` fields |
| 6 | `gpty inject T1 --text "echo hello"` | "hello" appears in T1 terminal |
| 7 | `gpty focus-pane C1` | C1 highlighted in sidebar |
| 8 | `gpty kill-pane F1` | F1 removed, `list-panes` shows 3 panes |
| 9 | `gpty kill-pane NOPE` | Error: "Pane 'NOPE' not found" |
| 10 | `gpty layout save my-setup` | Returns `{"success":true,"name":"my-setup"}` |
| 11 | `gpty layout list` | "my-setup" in layouts array |
| 12 | `gpty layout load my-setup` | Workspace restored to saved state |

---

### Daemon lifecycle

**Given** the GUI is running

| # | Command | Expected |
|---|---------|----------|
| 13 | `gpty daemon status` | "gpty GUI is running (v0.3.0)" |
| 14 | `gpty daemon stop` | GUI exits cleanly, no zombie processes (`ps aux | grep gpty`) |
| 15 | `gpty daemon status` | "gpty GUI is not running." with exit code 1 |
| 16 | `gpty --no-daemon version` | "could not connect to gpty GUI" error |
| 17 | `gpty version` (GUI not running) | Auto-spawns GUI, then responds with version |

---

### Standalone commands (no GUI needed)

| # | Command | Expected |
|---|---------|----------|
| 18 | `gpty schema` | Valid JSON Schema with `oneOf` array of subcommands |
| 19 | `gpty schema --format mcp` | Valid MCP manifest with `{"tools": [...]}` |
| 20 | `echo '{"jsonrpc":"2.0","id":1,"method":"initialize"}' \| gpty mcp` | Server info with `protocolVersion`, `serverInfo`, `capabilities` |
| 21 | `echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \| gpty mcp` | Tools array matching all CLI subcommands |

---

### Error paths

| # | Command | Expected |
|---|---------|----------|
| 22 | `gpty kill-pane NONEXISTENT` | Error: "Pane 'NONEXISTENT' not found" |
| 23 | `gpty inject C1 --text "test"` | Error: "Pane 'C1' is not a terminal" (code_viewer can't receive injection) |
| 24 | Spam `gpty new-pane --pane-type code_viewer` until full | Eventually returns "Grid is full" error |

---

### UI regression

**Given** the GUI is running with at least two panes

| # | Action | Expected |
|---|--------|----------|
| 25 | `Ctrl+N` | New terminal pane spawns |
| 26 | `Ctrl+W` | Focused pane closes |
| 27 | `Ctrl+B` | Sidebar toggles visible/hidden |
| 28 | `Ctrl+P` | Command palette opens, fuzzy search works |
| 29 | `Alt+Arrow` | Focus moves between adjacent panes geographically |
| 30 | Drag tile edge | Pane resizes, adjacent pane compensates |
| 31 | Sidebar window mode dropdown | Cycle OS → Borderless → Fullscreen, window responds correctly |
| 32 | Settings panel (sidebar gear icon) | Opens, change font size → terminal re-renders, change persists after restart |
| 33 | Profile save (sidebar save icon) | Save current layout, quit, relaunch, load from sidebar → layout restored |

---

### Concept engine regression

**Given** the GUI is running with a terminal pane and default concepts loaded

| # | Action | Expected |
|---|--------|----------|
| 34 | In terminal: `cat somefile` | Concept triggers, output captured and routed to code_viewer pane (auto-created if needed) |
| 35 | In terminal: `git diff` | Concept triggers (if enabled), output appears in code_viewer |

---

### Platform-specific

| # | Platform | Check |
|---|----------|-------|
| 36 | Linux | Export release: `godot --headless --path godot --export-release "Linux/X11" dist/gpty` produces working binary |
| 37 | macOS | `.app` bundle launches, code signing not required for local testing |
| 38 | Windows | `gpty.exe` launches, ConPTY terminal works |

---

## Test case format

New manual test cases follow this pattern:

```
**Given** preconditions (state before the test)
**When** action performed
**Then** expected observable outcome
```

For CLI commands, include the exact command and expected output format. For UI actions, describe the gesture and the visual change.
