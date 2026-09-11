extends GutTest
# Pane edge resize: the strip the user grabs, and the drag it starts.
#
# Defends the failure where the pane body covered the whole wrapper, so the
# wrapper's own gui_input only ever fired inside its 1 px stylebox border: the
# resize cursor flashed for a frame and the 4 px edge test was unreachable.

var _scene: Control
var _tm: TerminalManager

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = "/bin/sh"
	SettingsManager.cfg_default_rows = 24
	SettingsManager.cfg_default_cols = 80
	_scene = TestScene.create()
	add_child_autofree(_scene)
	_tm = TerminalManager.new()

func after_each():
	if _ws and is_instance_valid(_ws):
		if _ws.get_parent():
			_ws.get_parent().remove_child(_ws)
		_ws.free()
	_ws = null
	for t in _tm.tiles:
		if t.wrapper:
			t.wrapper.free()
	_tm.tiles.clear()
	_tm.last_body = null
	MockAutoloads.teardown()

## Spawn `count` panes, lay their wrappers out side by side, and return them.
func _laid_out_wrappers(count: int) -> Array[Control]:
	var wrappers: Array[Control] = []
	for i in count:
		var body = _tm.spawn_pane("code_viewer", {})
		assert_not_null(body)
		var w: Control = _tm.tiles[i].wrapper
		_scene.add_child(w)
		w.position = Vector2(i * 200, 0)
		w.size = Vector2(200, 300)
		wrappers.append(w)
	await get_tree().process_frame
	await get_tree().process_frame
	return wrappers

# ── The grab area ──────────────────────────────────────────────────────

func test_every_edge_has_a_strip_with_the_resize_cursor():
	var wrappers := await _laid_out_wrappers(1)
	var w: Control = wrappers[0]
	for edge in TerminalManager.EDGE_EDGES:
		var strip: Control = w.get_node_or_null("EdgeHost/Edge" + edge.capitalize())
		assert_not_null(strip, "a %s edge strip must exist" % edge)
		assert_eq(strip.mouse_filter, Control.MOUSE_FILTER_STOP,
			"the %s strip must own the pointer" % edge)
		var want = Control.CURSOR_HSIZE if edge in ["left", "right"] else Control.CURSOR_VSIZE
		assert_eq(strip.mouse_default_cursor_shape, want,
			"hovering the %s edge must show the resize cursor" % edge)

func test_edge_band_belongs_to_the_strip_not_the_body():
	var wrappers := await _laid_out_wrappers(1)
	var w: Control = wrappers[0]
	var body: Control = _tm._find_body(w)
	var title: Control = w.get_node_or_null("BodyVBox/TitleBar")
	# 3 px inside each edge: inside the old 4 px threshold, and squarely over
	# the pane's own content before this fix (the body, or the title bar in the
	# top band). The strip must own that point now.
	var probes := {
		"left": w.get_global_rect().position + Vector2(3, 150),
		"right": w.get_global_rect().position + Vector2(w.size.x - 3, 150),
		"top": w.get_global_rect().position + Vector2(100, 3),
		"bottom": w.get_global_rect().position + Vector2(100, w.size.y - 3),
	}
	for edge in probes:
		var strip: Control = w.get_node("EdgeHost/Edge" + edge.capitalize())
		var underneath: Control = title if edge == "top" and title else body
		assert_true(strip.get_global_rect().has_point(probes[edge]),
			"a point 3 px inside the %s edge must land on the strip (strip %s, point %s)"
				% [edge, strip.get_global_rect(), probes[edge]])
		assert_true(underneath.get_global_rect().has_point(probes[edge]),
			"the %s band must overlap real pane content, not empty space (%s vs %s)"
				% [edge, underneath.get_global_rect(), probes[edge]])

func test_interior_is_not_a_resize_target():
	var wrappers := await _laid_out_wrappers(1)
	var w: Control = wrappers[0]
	var middle: Vector2 = w.get_global_rect().get_center()
	for edge in TerminalManager.EDGE_EDGES:
		var strip: Control = w.get_node("EdgeHost/Edge" + edge.capitalize())
		assert_false(strip.get_global_rect().has_point(middle),
			"the %s strip must stay on the edge" % edge)

# ── The drag ───────────────────────────────────────────────────────────

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

func test_dragging_a_right_edge_resizes_both_tiles():
	var wrappers := await _laid_out_wrappers(2)
	var left_span: int = _tm.tiles[0].cspan
	var right_span: int = _tm.tiles[1].cspan
	var start: Vector2 = wrappers[0].get_global_rect().position + Vector2(wrappers[0].size.x, 150)

	# A press on the strip starts the drag...
	_tm._on_edge_strip_input(_press_at(start), wrappers[0], "right")
	assert_true(_tm.drag_active(), "a press on the edge strip must start a drag")

	# ...and raw motion (which the pane body would otherwise consume) drives it.
	assert_true(_tm.drive_edge_drag(_motion_at(start + Vector2(40, 0))),
		"motion during a drag belongs to the drag")
	assert_gt(_tm.tiles[0].cspan, left_span,
		"dragging a right edge right must grow that pane")
	assert_lt(_tm.tiles[1].cspan, right_span, "the neighbour must give up the space")

	watch_signals(_tm)
	_tm.drive_edge_drag(_release_at(start + Vector2(40, 0)))
	assert_false(_tm.drag_active(), "the release must end the drag")
	assert_signal_emitted(_tm, "tiles_resized", "ending a drag must relayout the grid")

func test_drag_survives_leaving_the_strip():
	var wrappers := await _laid_out_wrappers(2)
	var start: Vector2 = wrappers[0].get_global_rect().position + Vector2(wrappers[0].size.x, 150)
	_tm.begin_edge_drag(wrappers[0], "right", start)
	# 60 px into the neighbouring pane: nowhere near the strip.
	var far := start + Vector2(60, 20)
	assert_true(_tm.drive_edge_drag(_motion_at(far)),
		"the drag must keep working once the pointer is over another pane")

func test_motion_without_a_drag_is_left_alone():
	var wrappers := await _laid_out_wrappers(1)
	assert_false(_tm.drive_edge_drag(_motion_at(wrappers[0].get_global_rect().get_center())),
		"motion with no drag in flight must reach the panes")

# ── Live resize (a real workspace, so the wrappers actually move) ──────

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

var _ws: Control
var _host: Control

## A real workspace with two panes. The wrappers only move when
## `tiles_resized` reaches `_apply_layout`, which is the wiring a drag
## without live feedback would silently skip.
func _workspace_with_two_panes() -> Array[Control]:
	_host = Control.new()
	_host.size = Vector2(1200, 800)
	add_child_autofree(_host)
	_ws = WorkspaceScript.new()
	_host.add_child(_ws)
	# The workspace takes its geometry from main.tscn's anchors; here it has to
	# be given one, or every rect is degenerate and a drag cannot move anything.
	_ws.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame
	var tm: TerminalManager = _ws._tm
	tm.spawn_pane("terminal", {})
	_ws._apply_layout()
	await get_tree().process_frame
	await get_tree().process_frame
	var wrappers: Array[Control] = []
	for t in tm.tiles:
		wrappers.append(t.wrapper)
	return wrappers

func _cell_total(tm: TerminalManager) -> int:
	var total := 0
	for t in tm.tiles:
		total += t.cspan
	return total

## The drag has to behave like a tmux divider: follow the pointer in whole
## cells while the button is held, and never lose a cell. Mouse motion arrives
## in 1-3 px steps, so a per-step delta would round to zero and a partially
## applied move used to leave the panes not adding up.
func test_drag_follows_the_pointer_step_by_step():
	var wrappers := await _workspace_with_two_panes()
	var tm: TerminalManager = _ws._tm
	var rect: Rect2 = wrappers[0].get_global_rect()
	var start := Vector2(rect.position.x + rect.size.x - 2.0, rect.position.y + rect.size.y * 0.5)
	var width_before: float = rect.size.x

	tm.begin_edge_drag(wrappers[0], "right", start)
	for step in 8:
		tm.drive_edge_drag(_motion_at(start + Vector2(12 * (step + 1), 0)))
		assert_eq(_cell_total(tm), PaneTypes.GRID,
			"after step %d the panes must still add up to the grid" % (step + 1))
	assert_gt(wrappers[0].get_global_rect().size.x, width_before,
		"the pane must follow the pointer while dragging, not only on release")

	var grown: float = wrappers[0].get_global_rect().size.x
	tm.drive_edge_drag(_release_at(start + Vector2(96, 0)))
	await get_tree().process_frame
	assert_almost_eq(wrappers[0].get_global_rect().size.x, grown, 1.0,
		"releasing must not move the divider back")
	assert_false(tm.drag_active(), "the release ends the drag")

## Dragging past the neighbour's minimum stops there instead of collapsing it.
func test_drag_stops_at_the_minimum_pane_size():
	var wrappers := await _workspace_with_two_panes()
	var tm: TerminalManager = _ws._tm
	var rect: Rect2 = wrappers[0].get_global_rect()
	var start := Vector2(rect.position.x + rect.size.x - 2.0, rect.position.y + rect.size.y * 0.5)
	tm.begin_edge_drag(wrappers[0], "right", start)
	tm.drive_edge_drag(_motion_at(start + Vector2(4000, 0)))
	tm.drive_edge_drag(_release_at(start + Vector2(4000, 0)))
	assert_eq(_cell_total(tm), PaneTypes.GRID, "the grid must stay full")
	assert_eq(tm.tiles[1].cspan, PaneTypes.MIN_TILE,
		"the neighbour stops at MIN_TILE rather than vanishing")

## The layout that ships as "Agent Workspace", and the one that never resized:
## a full-height pane beside two stacked ones. A divider moves every tile on
## the far side, and the neighbour test has to match by *overlap* — demanding
## equal extents left the tall pane's edge with no neighbour at all.
func test_full_height_pane_drags_against_two_stacked_neighbours():
	var wrappers := await _workspace_with_two_panes()
	var tm: TerminalManager = _ws._tm
	tm.spawn_pane("terminal", {})
	await get_tree().process_frame
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
	var rect: Rect2 = wrappers[0].get_global_rect()
	var start := Vector2(rect.position.x + rect.size.x - 2.0, rect.position.y + rect.size.y * 0.5)
	tm.begin_edge_drag(wrappers[0], "right", start)
	tm.drive_edge_drag(_motion_at(start + Vector2(tm.tiles[0].cspan * 8.0, 0)))
	tm.drive_edge_drag(_release_at(start + Vector2(tm.tiles[0].cspan * 8.0, 0)))

	assert_gt(tm.tiles[0].cspan, tall,
		"the full-height pane must grow when its divider is dragged")
	assert_lt(tm.tiles[1].cspan, right_w, "the top-right pane must give up space")
	assert_lt(tm.tiles[2].cspan, right_w, "the bottom-right pane must give up space too")
	assert_eq(tm.tiles[1].cspan, tm.tiles[2].cspan,
		"stacked neighbours on one divider shrink together")
	# The stacked panes share the right-hand column, so summing every cspan
	# would count that column twice: the divider holds when the two column
	# widths are the grid.
	assert_eq(tm.tiles[0].cspan + tm.tiles[1].cspan, g,
		"the two columns must still fill the grid")

## The failure this file exists for: Godot's pick decides who gets the press,
## and the pane body consumed every event over the pane — the press has to
## land on the strip now, with no help from the test.
func test_press_on_the_band_starts_a_drag_through_gui_picking():
	var wrappers := await _laid_out_wrappers(2)
	var w: Control = wrappers[0]
	var rect: Rect2 = w.get_global_rect()
	var at := Vector2(rect.position.x + rect.size.x - 2.0, rect.position.y + rect.size.y * 0.5)
	Input.parse_input_event(_press_at(at))
	Input.flush_buffered_events()
	await get_tree().process_frame
	assert_true(_tm.drag_active(),
		"a press 2 px inside the edge must reach the strip, not start a selection")
	Input.parse_input_event(_release_at(at))
	Input.flush_buffered_events()
