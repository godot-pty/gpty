---
name: godot-graph-edit-canvas
description: "Build a GraphEdit node-editor canvas in Godot 4 (nodes, ports, frames, save/compile) without hitting its internal-child, chrome-overlap, and sizing traps — use when adding a node/graph editing UI."
---

# GraphEdit canvas recipe (Godot 4.7, proven in gpty's Concept Graph)

## Structure

- `GraphEdit` extends `Control`; `GraphNode` and `GraphFrame` extend `GraphElement` (a `Container`).
- A `GraphNode`'s size comes from its children: add one `VBoxContainer` at `position = Vector2(10, 38)` and set `custom_minimum_size` on the node (graph nodes were 356 px wide with a 320 px fields box).
- Ports: `set_slot(0, enable_left, 0, color_left, enable_right, 0, color_right)`. Type `0` for all ports; one port per side.
- Frames group a rule: create `GraphFrame` (title, `autoshrink_enabled = true`, `autoshrink_margin`), add it **before** the nodes so it renders behind, then `attach_graph_element_to_frame(node.name, frame.name)` (both are `StringName` node names).

## Traps that cost real time

1. **Never clear `get_children()` to rebuild the canvas.** GraphEdit owns internal children (connection layer, minimap container, view-menu popup); deleting them makes every later interaction log `connections_layer is missing`. Remove only `child is GraphElement`.
2. **Floating chrome sits at the canvas origin in viewport space** (zoom buttons/label, grid buttons, arrange button, minimap button, view menu) and covers the first node's title at the default scroll offset. Set `show_zoom_buttons/show_zoom_label/show_grid_buttons/show_arrange_button/show_minimap_button/show_menu = false`, `minimap_enabled = false`; zoom stays on ctrl+wheel.
3. `connection_request` does **not** auto-connect: validate, then either call `connect_node()` or skip it and rebuild. GraphEdit allows multiple wires per port unless the editor enforces one.
4. The canvas transform: `graph_pos ≈ (local - size/2) / zoom + scroll_offset` (exact at zoom 1.0).
5. Node names cannot contain `:`; use a per-editor counter (`n0`, `n1`, …) and keep id → name maps in dictionaries, not in the node name.

## Architecture that keeps it testable

- Put all logic in a pure `class_name` model (no UI): build canvas from data, validate, compile back, serialize layout. Inject the regex/data validator as a `Callable` so headless tests need no engine services.
- Keep positions in one dictionary keyed by canvas node id; serialize with the ids rewritten to canonical keys at save time so a rename keeps its position.
- The UI layer just maps model dicts to `GraphNode` fields and forwards edits to the model. Route the gesture handlers (`_on_connection_request`, `_on_delete_nodes_request`, …) through ordinary methods so a headless smoke can call exactly what the signal would call.

## Verification

- Prefer objective probes over screenshots for geometry: assert `graph.connections.size() == edges.size()` and that no two `Rect2(position_offset, size)` intersect. Vision models miss thin wires at full-window scale.
- For layout, screenshot with a real display (`DisplayServer.get_name() != "headless"` + `await RenderingServer.frame_post_draw` + `viewport.get_texture().get_image().save_png()`); `--headless` never emits `frame_post_draw` and hangs a script that awaits it.
- A full-window overlay must `move_child(overlay, -1)` on open (z_index is rendering-only in Godot picking).
