extends GutTest
# Pane resize: the divider handle layer, the unit-snapped preview, and the
# release that must reach the GUI.
#
# Defends the four defects the v0.8.3 row "Resizing a pane is smooth" closed:
#   - the per-pane 6 px strips sat inside the wrapper's 1 px border, so two
#     neighbours left those two pixels dead between them (a 14 px target with a
#     2 px hole) and no hover feedback said where the divider was;
#   - a drag consumed the button release, so the viewport's mouse focus went
#     stale and the resize cursor stayed an arrow until another click;
#   - the preview moved by raw pixels while the commit rounded to whole units,
#     so the divider hopped up to half a unit (~16 px on a 1920 px window) on
#     release;
#   - a continuous drag reset the pane's quiet-period resize debounce on every
#     motion, so the text never followed the divider at all.

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

## A host Control sized like a window: the workspace takes its geometry from
## main.tscn's anchors, so a test has to give it one.
var _host: Control
var _ws: Control

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()

func after_each():
	if _ws:
		if _ws.get_parent():
			_ws.get_parent().remove_child(_ws)
		_ws.free()
	_ws = null
	if _host and is_instance_valid(_host):
		_host.free()
	_host = null
	MockAutoloads.teardown()

## A real workspace holding exactly `types.size()` panes, in spawn order.
##
## The restore's startup terminal is killed first, so a test that asks for
## `code_viewer` panes pays for no shell at all, and the tile count is exactly
## what the argument names (a restored layout always has its own first pane).
func _workspace(types: Array) -> Array[Control]:
	_host = Control.new()
	_host.size = Vector2(1200, 800)
	add_child(_host)
	_ws = WorkspaceScript.new()
	_host.add_child(_ws)
	_ws.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame
	if not _ws._tm.tiles.is_empty():
		var startup = _ws._tm._find_body(_ws._tm.tiles[0].wrapper)
		if startup != null:
			_ws._tm.kill(startup)
	for t in types:
		# The workspace's own spawn path, so the pane is a real child of the
		# grid: a detached body never runs `_ready` (no font metrics, no
		# `_process`, so no shell) and its size would not follow the layout.
		_ws._spawn_pane(str(t), {})
	_ws._apply_layout()
	await get_tree().process_frame
	await get_tree().process_frame
	return _wrappers()

func _wrappers() -> Array[Control]:
	var wrappers: Array[Control] = []
	for t in _ws._tm.tiles:
		wrappers.append(t.wrapper)
	return wrappers

func _layer() -> DividerHandles:
	return _ws._grid.get_node_or_null("DividerHandles") as DividerHandles

## The divider line (grid units) a side-by-side pair shares.
func _shared_line() -> int:
	var t = _ws._tm.tiles[0]
	return int(t.col + t.cspan)

func _tile_state(tm: TerminalManager) -> Array:
	var state := []
	for t in tm.tiles:
		state.append([int(t.col), int(t.row), int(t.cspan), int(t.rspan)])
	return state

## True when the tiles cover the grid exactly once — no gap (what a resize that
## forgets some tiles leaves behind) and no overlap.
func _layout_covers_grid(tm: TerminalManager) -> bool:
	var g: int = PaneTypes.GRID
	var seen := {}
	for t in tm.tiles:
		for r in range(int(t.row), int(t.row + t.rspan)):
			for c in range(int(t.col), int(t.col + t.cspan)):
				var key := Vector2i(c, r)
				if seen.has(key):
					return false
				seen[key] = true
	return seen.size() == g * g

func _cell_total(tm: TerminalManager) -> int:
	var total := 0
	for t in tm.tiles:
		total += t.cspan
	return total

func _motion_at(pos: Vector2) -> InputEventMouseMotion:
	var e := InputEventMouseMotion.new()
	e.global_position = pos
	e.position = pos
	return e

func _release_at(pos: Vector2) -> InputEventMouseButton:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = false
	e.global_position = pos
	e.position = pos
	return e

func _press_at(pos: Vector2) -> InputEventMouseButton:
	var e := _release_at(pos)
	e.pressed = true
	return e

## A point inside the first handle's band: the handle layer is the grid's
## child, so its own rect is the grid's pixel space.
func _handle_point(handle: Control) -> Vector2:
	return handle.global_position + handle.size * 0.5

# ── The band ───────────────────────────────────────────────────────────

func test_one_handle_sits_on_a_divider_and_none_on_a_border():
	var wrappers := await _workspace(["code_viewer", "code_viewer"])
	var layer := _layer()
	assert_not_null(layer, "every workspace grid carries a handle layer")
	assert_eq(layer._segments.size(), 1,
		"two panes share one divider: one band, not four edge strips")
	var handle: Control = layer._pool[0]
	assert_true(handle.visible, "the divider's band is visible")
	assert_eq(handle.mouse_filter, Control.MOUSE_FILTER_STOP,
		"the band must take the pointer it advertises")
	assert_eq(handle.mouse_default_cursor_shape, Control.CURSOR_HSIZE,
		"a vertical divider shows the horizontal resize cursor")
	assert_almost_eq(handle.size.x, float(DividerHandles.HIT), 0.01,
		"one band across the divider, with no dead strip between two strips")
	# The band is centred on the line the wrappers meet at, and spans the grid.
	var line_px: float = float(wrappers[0].offset_right)
	assert_almost_eq(handle.position.x + handle.size.x * 0.5, line_px, 0.6,
		"the band must be centred on the divider")
	assert_almost_eq(handle.size.y, _ws._grid.size.y, 1.0,
		"a full-height divider's band spans the grid")

func test_every_band_reads_the_axis_cursor():
	await _workspace(["code_viewer", "code_viewer"])
	var tm: TerminalManager = _ws._tm
	var half: int = int(PaneTypes.GRID * 0.5)
	for i in 2:
		tm.tiles[i].row = half * i
		tm.tiles[i].rspan = PaneTypes.GRID - half
		tm.tiles[i].col = 0
		tm.tiles[i].cspan = PaneTypes.GRID
	_ws._apply_layout()
	var layer := _layer()
	assert_eq(layer._segments.size(), 1)
	assert_eq(layer._segments[0]["axis"], "y", "the divider between stacked panes is horizontal")
	assert_eq(layer._pool[0].mouse_default_cursor_shape, Control.CURSOR_VSIZE,
		"a horizontal divider shows the vertical resize cursor")

func test_a_single_pane_offers_no_handle():
	await _workspace(["code_viewer"])
	var layer := _layer()
	assert_eq(layer._segments.size(), 0, "a single pane has no divider to drag")
	assert_false(_ws._tm.begin_line_drag("x", 30, Vector2.ZERO),
		"a single pane must not start a resize drag")

## A divider whose two sides are both at MIN_TILE has nowhere to go: it must
## not advertise a resize the press cannot honour (the single-pane rule,
## applied per line).
func test_a_divider_with_no_travel_offers_no_handle():
	await _workspace(["code_viewer", "code_viewer"])
	var tm: TerminalManager = _ws._tm
	tm.tiles[0].col = 0; tm.tiles[0].row = 0
	tm.tiles[0].cspan = PaneTypes.MIN_TILE; tm.tiles[0].rspan = PaneTypes.GRID
	tm.tiles[1].col = PaneTypes.MIN_TILE; tm.tiles[1].row = 0
	tm.tiles[1].cspan = PaneTypes.MIN_TILE; tm.tiles[1].rspan = PaneTypes.GRID
	_ws._apply_layout()
	assert_false(bool(_ws._tm.divider_limits("x", PaneTypes.MIN_TILE).get("ok", true)),
		"a divider with both sides at MIN_TILE must report no travel")
	var handle: Control = _layer()._pool[0]
	assert_eq(handle.mouse_filter, Control.MOUSE_FILTER_IGNORE,
		"an immovable divider must not take the pointer")
	assert_eq(handle.mouse_default_cursor_shape, Control.CURSOR_ARROW,
		"an immovable divider must not show a resize cursor")
	assert_false(_ws._tm.begin_line_drag("x", PaneTypes.MIN_TILE, Vector2.ZERO),
		"an immovable divider must not start a drag")

## The failure this file exists for: Godot's pick decides who gets the press,
## and the layer is one Control per divider segment — the press must land on it
## with no help from the test.
func test_a_press_on_the_band_starts_a_drag_through_gui_picking():
	await _workspace(["code_viewer", "code_viewer"])
	var handle: Control = _layer()._pool[0]
	var at := _handle_point(handle)
	Input.parse_input_event(_press_at(at))
	Input.flush_buffered_events()
	await get_tree().process_frame
	assert_true(_ws._tm.drag_active(),
		"a press on the divider band must reach the handle, not a pane")
	Input.parse_input_event(_release_at(at))
	Input.flush_buffered_events()
	await get_tree().process_frame
	assert_false(_ws._tm.drag_active(), "the release ends the drag")

# ── The drag ───────────────────────────────────────────────────────────

func test_motion_previews_and_the_model_moves_only_on_release():
	var wrappers := await _workspace(["code_viewer", "code_viewer"])
	var tm: TerminalManager = _ws._tm
	var model_before := _tile_state(tm)
	var unit: float = wrappers[0].size.x / float(tm.tiles[0].cspan)
	var start := _handle_point(_layer()._pool[0])
	var width_before: float = wrappers[0].size.x

	assert_true(tm.begin_line_drag("x", _shared_line(), start),
		"a divider with travel must start a drag")
	watch_signals(tm)
	assert_true(tm.drive_edge_drag(_motion_at(start + Vector2(40, 0))),
		"motion during a drag belongs to the drag")
	var step := int(round(40.0 / unit))
	assert_eq(_tile_state(tm), model_before,
		"the preview must leave the tile model untouched — only the release commits")
	assert_signal_not_emitted(tm, "tiles_resized",
		"a motion must not relayout the grid — the release does that")
	assert_almost_eq(wrappers[0].size.x, width_before + step * unit, 0.6,
		"the preview moves the divider whole grid units at a time")

	var previewed: float = wrappers[0].size.x
	tm.drive_edge_drag(_release_at(start + Vector2(40, 0)))
	await get_tree().process_frame
	assert_signal_emit_count(tm, "tiles_resized", 1, "one release, one relayout")
	assert_almost_eq(wrappers[0].size.x, previewed, 0.6,
		"the release must not move the divider: what was shown is what is committed")
	assert_false(tm.drag_active(), "the release ends the drag")

func test_the_release_is_handed_back_to_the_gui():
	var wrappers := await _workspace(["code_viewer", "code_viewer"])
	var tm: TerminalManager = _ws._tm
	var start := _handle_point(_layer()._pool[0])
	watch_signals(tm)
	tm.begin_line_drag("x", _shared_line(), start)
	# (GUT's third argument here is the emission index, not a message.)
	assert_signal_emitted_with_parameters(tm, "divider_drag_started", ["x"])
	assert_true(tm.drive_edge_drag(_motion_at(start + Vector2(20, 0))),
		"the motion belongs to the drag and is consumed")
	# The release must not be consumed: the viewport only resets its mouse focus
	# on a release it sees, and a stale focus is the resize cursor that stayed
	# an arrow until the next click.
	assert_false(tm.drive_edge_drag(_release_at(start + Vector2(20, 0))),
		"the release must continue to the GUI")
	assert_false(tm.drag_active(), "the drag is over all the same")
	assert_signal_emitted(tm, "divider_drag_finished",
		"the panes are asked for their final reflow after the commit")
	assert_not_null(wrappers[0], "the wrappers stay valid across the drag")

## A drag is absolute from the press, so backtracking over it is safe: a drag
## that returns to where it started must commit no change.
func test_drag_returning_to_the_press_point_restores_the_layout():
	var wrappers := await _workspace(["code_viewer", "code_viewer"])
	var tm: TerminalManager = _ws._tm
	var model_before := _tile_state(tm)
	var start := _handle_point(_layer()._pool[0])
	var width_before: float = wrappers[0].size.x
	tm.begin_line_drag("x", _shared_line(), start)
	tm.drive_edge_drag(_motion_at(start + Vector2(45, 0)))
	tm.drive_edge_drag(_motion_at(start))
	tm.drive_edge_drag(_release_at(start))
	await get_tree().process_frame
	assert_eq(_tile_state(tm), model_before, "returning to the press point must commit no change")
	assert_almost_eq(wrappers[0].size.x, width_before, 0.6,
		"the divider must be back where the drag started")

## The preview clamps to the same limits the commit does: the neighbour stops
## at MIN_TILE, not only when the button comes up.
func test_the_drag_stops_at_the_minimum_pane_size():
	var wrappers := await _workspace(["code_viewer", "code_viewer"])
	var tm: TerminalManager = _ws._tm
	var unit: float = wrappers[0].size.x / float(tm.tiles[0].cspan)
	var start := _handle_point(_layer()._pool[0])
	tm.begin_line_drag("x", _shared_line(), start)
	tm.drive_edge_drag(_motion_at(start + Vector2(4000, 0)))
	assert_almost_eq(wrappers[1].size.x, unit * PaneTypes.MIN_TILE, 0.6,
		"the neighbour must not preview smaller than MIN_TILE")
	tm.drive_edge_drag(_release_at(start + Vector2(4000, 0)))
	assert_eq(tm.tiles[1].cspan, PaneTypes.MIN_TILE,
		"the commit lands on MIN_TILE, not past it")
	assert_eq(_cell_total(tm), PaneTypes.GRID, "the grid must stay full")

func test_drag_survives_leaving_the_band():
	var wrappers := await _workspace(["code_viewer", "code_viewer"])
	var tm: TerminalManager = _ws._tm
	var start := _handle_point(_layer()._pool[0])
	tm.begin_line_drag("x", _shared_line(), start)
	# 60 px into the neighbouring pane: nowhere near the band.
	assert_true(tm.drive_edge_drag(_motion_at(start + Vector2(60, 20))),
		"the drag must keep working once the pointer is over another pane")
	assert_not_null(wrappers[1], "the neighbour keeps its wrapper")

func test_motion_without_a_drag_is_left_alone():
	var wrappers := await _workspace(["code_viewer", "code_viewer"])
	assert_false(_ws._tm.drive_edge_drag(_motion_at(wrappers[0].get_global_rect().get_center())),
		"motion with no drag in flight must reach the panes")

## The layout that ships as "Agent Workspace", and the one that never resized:
## a full-height pane beside two stacked ones. A divider moves every tile on the
## far side, so the grab point is the line, not one pane's edge.
func test_full_height_pane_drags_against_two_stacked_neighbours():
	await _workspace(["code_viewer", "code_viewer", "code_viewer"])
	var tm: TerminalManager = _ws._tm
	assert_eq(tm.tiles.size(), 3, "three panes for the stacked layout")
	var g: int = PaneTypes.GRID
	# 0: full-height left; 1: top-right; 2: bottom-right.
	tm.tiles[0].col = 0; tm.tiles[0].row = 0
	tm.tiles[0].cspan = int(g * 0.6); tm.tiles[0].rspan = g
	tm.tiles[1].col = int(g * 0.6); tm.tiles[1].row = 0
	tm.tiles[1].cspan = g - int(g * 0.6); tm.tiles[1].rspan = int(g * 0.5)
	tm.tiles[2].col = int(g * 0.6); tm.tiles[2].row = int(g * 0.5)
	tm.tiles[2].cspan = g - int(g * 0.6); tm.tiles[2].rspan = g - int(g * 0.5)
	_ws._apply_layout()
	await get_tree().process_frame

	var tall: int = tm.tiles[0].cspan
	var right_w: int = tm.tiles[1].cspan
	var line: int = int(tm.tiles[0].col + tm.tiles[0].cspan)
	var start := _handle_point(_layer()._pool[0])
	assert_true(tm.begin_line_drag("x", line, start), "the vertical divider starts a drag")
	tm.drive_edge_drag(_motion_at(start + Vector2(tall * 8.0, 0)))
	tm.drive_edge_drag(_release_at(start + Vector2(tall * 8.0, 0)))

	assert_gt(tm.tiles[0].cspan, tall,
		"the full-height pane must grow when its divider is dragged")
	assert_lt(tm.tiles[1].cspan, right_w, "the top-right pane must give up space")
	assert_lt(tm.tiles[2].cspan, right_w, "the bottom-right pane must give up space too")
	assert_eq(tm.tiles[1].cspan, tm.tiles[2].cspan,
		"stacked neighbours on one divider shrink together")
	assert_eq(tm.tiles[0].cspan + tm.tiles[1].cspan, g,
		"the two columns must still fill the grid")

## A divider is a line across the whole window: dragging any part of it moves
## every tile whose edge lies on it — in the preview as well as on commit.
func test_one_line_moves_every_tile_on_it():
	await _workspace(["code_viewer", "code_viewer", "code_viewer", "code_viewer"])
	var tm: TerminalManager = _ws._tm
	var g: int = PaneTypes.GRID
	var half: int = int(g * 0.5)
	# 2x2: 0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right.
	for i in 4:
		tm.tiles[i].col = half * (i % 2)
		tm.tiles[i].cspan = g - half
		tm.tiles[i].row = half * int(i / 2)
		tm.tiles[i].rspan = g - half
	_ws._apply_layout()
	await get_tree().process_frame
	assert_true(_layout_covers_grid(tm), "the 2x2 layout must start gapless")
	var model_before := _tile_state(tm)
	var bl: Control = tm.tiles[2].wrapper
	var br: Control = tm.tiles[3].wrapper
	var bl_top: float = bl.get_global_rect().position.y
	var br_top: float = br.get_global_rect().position.y
	# Grab the horizontal line where it crosses the left column: both bottom
	# panes sit on it, so both must move.
	var layer := _layer()
	var horiz := {}
	for seg in layer._segments:
		if seg["axis"] == "y":
			horiz = seg
	assert_false(horiz.is_empty(), "a 2x2 layout has a horizontal divider")
	var rect := DividerHandles.handle_rect(horiz, _ws._grid.size, PaneTypes.GRID)
	var start := rect.position + Vector2(rect.size.x * 0.25, rect.size.y * 0.5) + layer.global_position
	tm.begin_line_drag("y", int(horiz["line"]), start)
	tm.drive_edge_drag(_motion_at(start + Vector2(0, 12)))
	assert_gt(bl.get_global_rect().position.y, bl_top,
		"the pane below must preview with the divider")
	assert_almost_eq(br.get_global_rect().position.y, br_top + (bl.get_global_rect().position.y - bl_top), 0.6,
		"the pane in the other column must preview on the same line")
	assert_eq(_tile_state(tm), model_before,
		"the preview must not touch the tile model mid-drag")
	tm.drive_edge_drag(_release_at(start + Vector2(0, 12)))
	assert_true(_layout_covers_grid(tm),
		"a drag must leave no gap or overlap between the panes")
	assert_eq(tm.tiles[2].row, tm.tiles[3].row,
		"both bottom panes must commit to the same row (one straight divider)")
	assert_eq(tm.tiles[0].row + tm.tiles[0].rspan, tm.tiles[2].row,
		"the top-left pane must end exactly where the bottom-left one starts")
	assert_eq(tm.tiles[1].row + tm.tiles[1].rspan, tm.tiles[3].row,
		"the top-right pane must end exactly where the bottom-right one starts")

# ── Live reflow ────────────────────────────────────────────────────────

## The drag must reach the panes: their quiet-period debounce becomes a
## throttle while the button is held, and the released geometry is applied
## without waiting for a quiet period that the drag already broke.
func test_the_drag_flag_reaches_the_panes_and_the_final_reflow_lands():
	await _workspace(["terminal", "terminal"])
	var tm: TerminalManager = _ws._tm
	var bodies: Array = []
	for t in tm.tiles:
		var body: Control = tm._find_body(t.wrapper)
		assert_true(body is TerminalPane, "the reflow half needs terminal panes")
		bodies.append(body)
	for body in bodies:
		var deadline := Time.get_ticks_msec() + 30000
		while not body.child_start_resolved() and Time.get_ticks_msec() < deadline:
			await get_tree().process_frame
		assert_true(body.child_start_resolved(), "the pane's shell must start")
	for body in bodies:
		assert_false(body._drag_resizing, "no drag is in flight yet")
	var cols_pre: int = bodies[0].cols

	var start := _handle_point(_layer()._pool[0])
	assert_true(tm.begin_line_drag("x", _shared_line(), start))
	for body in bodies:
		assert_true(body._drag_resizing,
			"every pane must throttle its reflow while the divider moves")

	tm.drive_edge_drag(_motion_at(start + Vector2(40, 0)))
	# One frame for the container to hand the wrappers' new rects to the
	# bodies: before it, `_grid_for_size(body.size)` is still the old size and
	# the loop below would pass without a reflow ever happening.
	await get_tree().process_frame
	# Mid-drag: the pane reflows on the throttle while the button is still
	# down. This is the half that makes the text follow the divider; without it
	# the grid would only settle after the release.
	for body in bodies:
		var mid_fitted: Vector2i = body._grid_for_size(body.size)
		var mid_deadline := Time.get_ticks_msec() + 3000
		while Time.get_ticks_msec() < mid_deadline \
				and (body.cols != mid_fitted.x or body.rows != mid_fitted.y):
			await get_tree().process_frame
			mid_fitted = body._grid_for_size(body.size)
		assert_eq(Vector2i(body.cols, body.rows), mid_fitted,
			"the text must follow the divider while the drag runs")
		assert_true(body._drag_resizing,
			"that reflow must happen inside the drag, not after it")
	assert_gt(bodies[0].cols, cols_pre,
		"the pane the divider grew must take the extra columns mid-drag")

	tm.drive_edge_drag(_release_at(start + Vector2(40, 0)))
	for body in bodies:
		assert_false(body._drag_resizing, "the flag clears with the drag")

	# One final reflow: the pane's grid matches the rect the release left it
	# with, without another resize event to prompt it.
	for body in bodies:
		var deadline := Time.get_ticks_msec() + 5000
		var fitted: Vector2i = body._grid_for_size(body.size)
		while Time.get_ticks_msec() < deadline \
				and (body.cols != fitted.x or body.rows != fitted.y):
			await get_tree().process_frame
			fitted = body._grid_for_size(body.size)
		assert_eq(Vector2i(body.cols, body.rows), fitted,
			"the released geometry must be reflowed without a further size change")
