# gpty-gdext

Godot 4 GDExtension that bridges the Rust terminal engine to Godot's renderer.

`GptyTerminal` is a headless `Node2D` bridge owning the Rust grid; the visible
terminal is the `Control`-based renderer
`godot/scenes/terminal/terminal_pane.gd`, which polls
`get_grid_updates_packed()` and draws in `_draw()`.

## Building

```bash
# From the workspace root
cargo build -p gpty-gdext

# The shared library is at:
target/debug/libgpty_gdext.so
```

## Running in Godot

1. Open the `godot/` directory in the Godot editor
2. The `.gdextension` file auto-loads the shared library
3. Open `scenes/main.tscn` and press F5

## GDScript API

### GptyTerminal (extends Node2D)

#### Terminal lifecycle

| Method | Returns | Description |
|--------|---------|-------------|
| `start_shell(cmd: String, rows: int, cols: int, envs: String)` | void | Start a PTY session |
| `send_text(text: String)` | void | Send raw text to PTY (no newline) |
| `send_line(text: String)` | void | Send a line to PTY (appends `\n`) |
| `resize_grid(rows: int, cols: int)` | void | Resize grid + send SIGWINCH |
| `set_palette(hex_csv: String)` | void | Load color scheme (16 hex colors, CSV) |

#### Grid & rendering

| Method | Returns | Description |
|--------|---------|-------------|
| `get_grid_updates_packed(force_full: bool)` | `Dictionary` | Grid update in packed arrays — see [Grid Update Dictionary](#grid-update-dictionary) |
| `get_grid_generation()` | `int` | Monotonic counter, changes on grid update |
| `get_cursor_row()` | `int` | Cursor row (0-based, -1 if none) |
| `get_cursor_col()` | `int` | Cursor column (0-based) |
| `get_cursor_shape()` | `int` | 0=Block, 1=Underline, 2=Beam |
| `get_title()` | `String` | Terminal window title (OSC) |
| `get_rows()` | `int` | Grid row count |
| `get_cols()` | `int` | Grid column count |

#### Scrollback & search

| Method | Returns | Description |
|--------|---------|-------------|
| `scroll_up(lines: int)` | void | Scroll back in history |
| `scroll_down(lines: int)` | void | Scroll forward in history |
| `scroll_reset()` | void | Reset scroll to follow output |
| `get_scroll_offset()` | `int` | Lines above visible viewport |
| `get_history_size()` | `int` | Total scrollback lines available |
| `search_grid(pattern: String)` | `Dictionary` | Search scrollback for regex pattern |
| `key_to_bytes(keycode, shift, alt, ctrl, meta)` | `PackedByteArray` | Convert key event to terminal byte sequence |

#### Concept engine

| Method | Returns | Description |
|--------|---------|-------------|
| `set_global_concepts(concepts_json: String)` | void | Replace all concepts in the engine (JSON array of concept objects; parse caps and timeout clamp in `gpty_core::concept::concepts_from_json`) |
| `get_global_concepts()` | `Array` | Get all concepts as Dict array |
| `match_concepts_on_line(line: String)` | `Array` | Match concepts against a line; returns `[{name, cmd}]` with shell-quoted substitution |
| `drain_concept_events()` | `Array` | Drain completed capture events from this terminal |
| `acknowledge_capture(event_id: int)` | void | Discard captured bytes (receiver consumed output) |
| `flush_capture(event_id: int)` | void | Feed captured bytes to grid (no receiver) |

#### IPC bridge (static methods)

| Method | Returns | Description |
|--------|---------|-------------|
| `drain_ipc_requests()` | `Array` | Drain queued IPC requests for GDScript dispatch |
| `respond_ipc(id, success, result_json)` | void | Respond to a drained IPC request |

#### Grid Update Dictionary

`get_grid_updates_packed()` returns one of two shapes. Both carry flat
per-cell arrays: `fg`/`bg` are `PackedColorArray`, `attrs` is
`PackedInt32Array` (bit flags: 1 bold, 2 italic, 4 underline, 8 inverse,
16 wide), and `chars` is an `Array` of strings.

Full update (`is_full = true`, first fetch or `force_full`):
```gdscript
{
    "is_full": true,
    "rows": 24, "cols": 80,          # int — grid dimensions
    "chars": ["line0", "line1", …],  # Array[String] — one string per row
    "fg": PackedColorArray(…),       # len = rows × cols
    "bg": PackedColorArray(…),
    "attrs": PackedInt32Array(…),
}
```

Partial update (`is_full = false`, damaged cells only):
```gdscript
{
    "is_full": false,
    "indices": PackedInt32Array(…),  # cell index = row * cols + col
    "chars": ["A", "B", …],          # Array[String] — one string per cell
    "fg": PackedColorArray(…),
    "bg": PackedColorArray(…),
    "attrs": PackedInt32Array(…),
}
```

### Tips

- Use `get_grid_generation()` to skip redundant grid polls when idle
- The renderer uses `get_grid_updates_packed()` to fetch only damaged cells, merging into `_cell_cache`
- If the grid mutex is held by the background task, `get_grid_rows()` returns `[]`
