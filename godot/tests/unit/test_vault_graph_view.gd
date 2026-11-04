extends GutTest
# Unit tests for VaultGraphView — the canvas gestures and session state. The
# drawing itself is not asserted (headless has nothing to render), but every
# decision behind it is: click vs drag, ghost routing, zoom anchoring, the fit,
# and geometry surviving a re-query.

func _graph() -> Dictionary:
	return {
		"nodes": [
			{"id": "a.md", "label": "A", "ghost": false},
			{"id": "b.md", "label": "B", "ghost": false},
			{"id": "ghost:Missing", "label": "Missing", "ghost": true},
		],
		"edges": [
			{"a": "a.md", "b": "b.md", "ab": 2, "ba": 1, "count": 3, "ghost": false},
			{"a": "a.md", "b": "ghost:Missing", "ab": 1, "ba": 0, "count": 1, "ghost": true},
		],
		"truncated": false,
	}

func _make_view(graph: Dictionary = {}, current := "a.md") -> VaultGraphView:
	var view := VaultGraphView.new()
	add_child_autofree(view)
	view.size = Vector2(800, 600)
	view.show_graph(graph if not graph.is_empty() else _graph(), current)
	view._fit_if_needed()
	return view

func _click(view: VaultGraphView, point: Vector2) -> void:
	view._begin_press(point)
	view._end_press(point)


# ── Installation ───────────────────────────────────────────────────────

func test_show_graph_installs_nodes_edges_and_geometry():
	var view := _make_view()
	assert_eq(view.nodes.size(), 3)
	assert_eq(view.edges.size(), 2)
	assert_eq(view.positions.size(), 3)
	assert_true(view.positions.has("ghost:Missing"))


func test_the_open_note_is_selected_and_a_stale_one_is_not():
	var view := _make_view()
	assert_eq(view.selected_id, "a.md")
	view.set_selected("nope.md")
	assert_eq(view.selected_id, "", "a note that left the graph stops being selected")
	view.set_selected("b.md")
	assert_eq(view.selected_id, "b.md")


func test_status_counts_notes_links_and_missing_targets():
	var view := _make_view()
	assert_string_contains(view._status.text, "2 notes")
	assert_string_contains(view._status.text, "2 links")
	assert_string_contains(view._status.text, "1 missing")


func test_fit_puts_every_node_on_screen():
	var view := _make_view()
	var screen := Rect2(Vector2.ZERO, view.size)
	for id in view.positions:
		var point := view.to_screen(view.positions[id])
		assert_true(screen.grow(1.0).has_point(point), "%s must fit in the view" % id)


# ── Gestures ───────────────────────────────────────────────────────────

func test_clicking_a_note_emits_its_path():
	var view := _make_view()
	watch_signals(view)
	var point := view.to_screen(view.positions["b.md"])
	_click(view, point)
	assert_signal_emitted_with_parameters(view, "node_activated", ["b.md"])


func test_clicking_a_ghost_emits_the_bare_target():
	var view := _make_view()
	watch_signals(view)
	var point := view.to_screen(view.positions["ghost:Missing"])
	_click(view, point)
	assert_signal_emitted_with_parameters(view, "ghost_activated", ["Missing"])


func test_dragging_a_node_moves_it_without_opening_it():
	var view := _make_view()
	watch_signals(view)
	var before: Vector2 = view.positions["a.md"]
	var start := view.to_screen(before)
	view._begin_press(start)
	var motion := InputEventMouseMotion.new()
	motion.position = start + Vector2(40.0, 20.0)
	motion.relative = Vector2(40.0, 20.0)
	view._gui_input(motion)
	view._end_press(motion.position)
	assert_ne(view.positions["a.md"], before, "dragging must move the node")
	assert_signal_not_emitted(view, "node_activated")


func test_dragging_the_background_pans_without_selecting():
	var view := _make_view()
	watch_signals(view)
	var before := view._pan
	# A background point: the view's corner is always empty after a fit.
	var start := Vector2(2.0, 2.0)
	view._begin_press(start)
	var motion := InputEventMouseMotion.new()
	motion.position = start + Vector2(25.0, 0.0)
	motion.relative = Vector2(25.0, 0.0)
	view._gui_input(motion)
	view._end_press(motion.position)
	assert_ne(view._pan, before, "dragging the background pans the canvas")
	assert_signal_not_emitted(view, "node_activated")


func test_wheel_zoom_keeps_the_world_point_under_the_cursor():
	var view := _make_view()
	var cursor := Vector2(300.0, 200.0)
	var world := view.to_world(cursor)
	var zoom := view._zoom
	view.zoom_at(cursor, 2.0)
	assert_almost_eq(view._zoom, zoom * 2.0, 0.001)
	assert_true(view.to_world(cursor).is_equal_approx(world),
		"the point under the cursor must not slide")


func test_zoom_is_clamped():
	var view := _make_view()
	for i in 200:
		view.zoom_at(Vector2(400.0, 300.0), 2.0)
	assert_lte(view._zoom, VaultGraphView.ZOOM_MAX)
	for i in 400:
		view.zoom_at(Vector2(400.0, 300.0), 0.5)
	assert_gte(view._zoom, VaultGraphView.ZOOM_MIN)


# ── Session geometry ───────────────────────────────────────────────────

func test_a_requery_keeps_dragged_geometry():
	var view := _make_view()
	view.positions["a.md"] = Vector2(200.0, 200.0)
	view.show_graph(_graph(), "b.md")
	assert_eq(view.positions["a.md"], Vector2(200.0, 200.0),
		"a re-query must not reshuffle a graph the user arranged")
	assert_eq(view.selected_id, "b.md")


func test_a_new_note_is_placed_without_moving_the_others():
	var view := _make_view()
	view.positions["a.md"] = Vector2(111.0, 111.0)
	var grown := _graph()
	grown["nodes"].append({"id": "c.md", "label": "C", "ghost": false})
	grown["edges"].append(
		{"a": "c.md", "b": "a.md", "ab": 1, "ba": 0, "count": 1, "ghost": false}
	)
	view.show_graph(grown, "a.md")
	assert_eq(view.positions["a.md"], Vector2(111.0, 111.0))
	assert_true(view.positions.has("c.md"))
	var point: Vector2 = view.positions["c.md"]
	assert_true(is_finite(point.x) and is_finite(point.y))


func test_relayout_returns_to_the_deterministic_arrangement():
	var view := _make_view()
	view.positions["a.md"] = Vector2(5.0, 5.0)
	view.relayout()
	var fresh := VaultGraphModel.layout(view.nodes, view.edges, {})
	for id in fresh:
		assert_true((view.positions[id] as Vector2).is_equal_approx(fresh[id]),
			"%s must match the model's layout" % id)


# ── The declared-weight control ────────────────────────────────────────

## Put the two drawn pairs on known screen coordinates, so a test point is a
## point and not a fit-dependent guess.
func _pin_geometry(view: VaultGraphView) -> void:
	view._zoom = 1.0
	view._pan = Vector2.ZERO
	view.positions["a.md"] = Vector2(100.0, 100.0)
	view.positions["b.md"] = Vector2(300.0, 100.0)
	view.positions["ghost:Missing"] = Vector2(100.0, 300.0)


func _edge_between(view: VaultGraphView, a: String, b: String) -> Dictionary:
	for edge in view.edges:
		if edge is Dictionary and str(edge["a"]) == a and str(edge["b"]) == b:
			return edge
	return {}


func test_edge_at_finds_the_segment_under_the_pointer():
	var view := _make_view()
	_pin_geometry(view)
	var hit := view._edge_at(Vector2(200.0, 102.0))
	assert_eq(str(hit.get("a", "")), "a.md")
	assert_eq(str(hit.get("b", "")), "b.md")
	assert_true(view._edge_at(Vector2(200.0, 160.0)).is_empty(),
		"well off the line is not the edge")


func test_the_edge_menu_requests_a_weight_for_the_pair():
	var view := _make_view()
	_pin_geometry(view)
	watch_signals(view)
	var edge := view._edge_at(Vector2(200.0, 100.0))
	view._pending_edge = edge
	view._on_edge_menu_pressed(0)
	assert_signal_emitted_with_parameters(
		view, "weight_set_requested", [edge["a"], edge["b"], 0]
	)


func test_the_edge_menu_reports_the_current_declaration_and_can_clear_it():
	var view := _make_view()
	_pin_geometry(view)
	view.set_weights({"a.md": {"b.md": 12}})
	var edge := _edge_between(view, "a.md", "b.md")
	assert_eq(int(edge["declared"]), 12)
	watch_signals(view)
	view._pending_edge = edge
	view._on_edge_menu_pressed(0)
	assert_signal_emitted_with_parameters(
		view, "weight_set_requested", ["a.md", "b.md", 12]
	)
	view._pending_edge = edge
	view._on_edge_menu_pressed(1)
	assert_signal_emitted_with_parameters(view, "weight_cleared", ["a.md", "b.md"])


func test_a_ghost_edge_offers_no_weight_control():
	var view := _make_view()
	_pin_geometry(view)
	view._pending_edge = {}
	view._open_edge_menu(Vector2(100.0, 300.0))
	assert_true(view._pending_edge.is_empty(),
		"a declaration names two notes, and a missing target is not one")


func test_set_weights_updates_thickness_scale_and_status():
	var view := _make_view()
	var edge := _edge_between(view, "a.md", "b.md")
	assert_eq(int(edge.get("declared", 0)), 0, "a fresh edge has no declaration")
	view.set_weights({"a.md": {"b.md": 50}})
	assert_eq(int(edge["declared"]), 50)
	assert_eq(int(edge["weight"]), 50, "the displayed weight replaced the measured count")
	assert_eq(view._max_count, 50, "the stroke scale follows the display weights")
	assert_string_contains(view._status.text, "1 declared")
	assert_string_contains(view._status.text, "2 links", "the edge set is unchanged")


func test_the_edge_menu_opens_for_a_drawn_edge():
	var view := _make_view()
	_pin_geometry(view)
	view._pending_edge = {}
	view._open_edge_menu(Vector2(200.0, 100.0))
	assert_false(view._pending_edge.is_empty(),
		"the edge under the pointer is the menu's target")
	assert_true(view._edge_menu.visible, "the menu actually opened")
	view._edge_menu.hide()


# ── Keyboard ───────────────────────────────────────────────────────────
#
# The map is keyboard-operable (the v0.8.0 row "The vault link graph is
# mouse-only"): the canvas and its three actions are one ring, arrows pan the
# view, `+`/`-` zoom about the crosshair, and Enter acts on whatever the
# crosshair covers — through the same `hit_test`/`hit_test_edge` the pointer
# uses, so the two cannot disagree about what is under the cursor.

func _press(keycode: Key, shift := false) -> void:
	var down := InputEventKey.new()
	down.keycode = keycode
	down.physical_keycode = keycode
	down.shift_pressed = shift
	down.pressed = true
	Input.parse_input_event(down)
	Input.flush_buffered_events()
	await wait_process_frames(1)
	var up: InputEventKey = down.duplicate()
	up.pressed = false
	Input.parse_input_event(up)
	Input.flush_buffered_events()
	await wait_process_frames(1)


## A focused view whose transform the test sets, not the fit: zoom 1 and the
## world origin under the crosshair (the canvas centre), so `a.md` sits at the
## centre and `b.md`/the ghost are known distances away.
func _centred_view() -> VaultGraphView:
	var view := _make_view()
	view.positions = {
		"a.md": Vector2.ZERO,
		"b.md": Vector2(300, 0),
		"ghost:Missing": Vector2(0, 300),
	}
	view._zoom = 1.0
	view._pan = view.size * 0.5
	view.grab_focus()
	return view


func test_the_graph_is_one_keyboard_ring():
	var view := _make_view()
	var ring: Array[Control] = [
		view, view._arrows_button, view._relayout_button, view._fit_button,
	]
	for i in ring.size():
		var c: Control = ring[i]
		var next: Control = ring[(i + 1) % ring.size()]
		var prev: Control = ring[(i - 1 + ring.size()) % ring.size()]
		assert_ne(c.focus_mode, Control.FOCUS_NONE, "%s must be a tab stop" % c.name)
		assert_eq(c.get_node(c.focus_next), next, "%s must tab to %s" % [c.name, next.name])
		assert_eq(c.get_node(c.focus_previous), prev,
			"%s must shift-tab to %s" % [c.name, prev.name])


func test_arrows_pan_and_shift_pans_four_times_further():
	var view := _centred_view()
	assert_eq(view.get_viewport().gui_get_focus_owner(), view,
		"precondition: the canvas holds the keyboard")
	var x := view._pan.x
	await _press(KEY_RIGHT)
	assert_almost_eq(view._pan.x, x + VaultGraphView.PAN_STEP, 0.01)
	await _press(KEY_RIGHT, true)
	assert_almost_eq(view._pan.x,
		x + VaultGraphView.PAN_STEP * (1.0 + VaultGraphView.PAN_FAST), 0.01)
	var y := view._pan.y
	await _press(KEY_DOWN)
	assert_almost_eq(view._pan.y, y + VaultGraphView.PAN_STEP, 0.01)
	await _press(KEY_UP)
	assert_almost_eq(view._pan.y, y, 0.01, "the four arrows are up/down/left/right pan")


func test_the_zoom_keys_scale_about_the_crosshair():
	var view := _centred_view()
	var zoom := view._zoom
	await _press(KEY_EQUAL)
	assert_gt(view._zoom, zoom, "`=` (the unshifted `+`) zooms in")
	assert_eq(view.cursor_hit(), "a.md", "the node under the crosshair stays under it")
	await _press(KEY_MINUS)
	assert_almost_eq(view._zoom, zoom, 0.0001, "`-` undoes the step")
	assert_almost_eq(view.to_world(view._cursor_screen()).length(), 0.0, 0.0001,
		"zooming about the crosshair keeps the world point fixed")


func test_enter_opens_the_node_under_the_crosshair():
	var view := _centred_view()
	var opened := []
	view.node_activated.connect(func(id: String): opened.append(id))
	assert_eq(view.cursor_hit(), "a.md", "the crosshair covers the node at the centre")
	await _press(KEY_ENTER)
	assert_eq(opened, ["a.md"])


func test_enter_resolves_a_ghost_under_the_crosshair():
	var view := _centred_view()
	view._pan = view.size * 0.5 - (view.positions["ghost:Missing"] as Vector2) * view._zoom
	var resolved := []
	view.ghost_activated.connect(func(target: String): resolved.append(target))
	assert_eq(view.cursor_hit(), "ghost:Missing")
	await _press(KEY_ENTER)
	assert_eq(resolved, ["Missing"], "a ghost resolves to its bare target")


func test_enter_on_an_edge_opens_its_weight_actions():
	var view := _make_view()
	view.positions = {
		"a.md": Vector2(-120, 0),
		"b.md": Vector2(120, 0),
		"ghost:Missing": Vector2(0, 900),
	}
	view._zoom = 1.0
	view._pan = view.size * 0.5
	view.grab_focus()
	assert_eq(view.cursor_hit(), "", "the crosshair is on the segment, not on a node")
	await _press(KEY_ENTER)
	assert_eq(str(view._pending_edge.get("a", "")), "a.md",
		"Enter opened the weight actions for the edge under the crosshair")
	assert_eq(str(view._pending_edge.get("b", "")), "b.md")
	view._edge_menu.hide()


# ── Labels at density ──────────────────────────────────────────────────
#
# The v0.8.0 row "The vault graph's labels overlap at the bundled vault's
# density": every node used to print its title at the fitted zoom, so titles
# landed on top of each other. Placement is now a priority list culled against
# itself and the node circles, and the fit reserves room for the labels.

func test_a_dense_cluster_keeps_only_the_labels_that_fit():
	# Eight notes within a few pixels of each other — the bundled vault's
	# crowded centre at the fitted zoom.
	var graph := {"nodes": [], "edges": [], "truncated": false}
	for i in 8:
		graph["nodes"].append({"id": "n%d.md" % i, "label": "Note %d" % i, "ghost": false})
	var view := _make_view(graph, "n0.md")
	view.positions = {}
	for i in 8:
		view.positions["n%d.md" % i] = Vector2(i * 3, i * 2)
	view._zoom = 1.0
	view._pan = view.size * 0.5
	view.grab_focus()

	var placements := view.label_placements()
	assert_lt(placements.size(), 8, "the cluster cannot print every label")
	assert_gt(placements.size(), 0, "the ones that fit still draw")
	var ids := []
	for placement in placements:
		ids.append(placement["id"])
	assert_has(ids, "n0.md", "the open note keeps its label")


func test_no_two_placed_labels_overlap():
	# Three notes far enough apart that every label can be placed: the
	# pair-wise assertion below is only meaningful when more than one survives.
	var view := _make_view()
	view.positions = {
		"a.md": Vector2(-300, -200),
		"b.md": Vector2(300, 200),
		"ghost:Missing": Vector2(-300, 250),
	}
	view._zoom = 1.0
	view._pan = view.size * 0.5
	var placed := view.label_placements()
	assert_gte(placed.size(), 2, "the labels that fit are still drawn")
	for i in placed.size():
		for j in range(i + 1, placed.size()):
			var a: Rect2 = placed[i]["rect"]
			var b: Rect2 = placed[j]["rect"]
			assert_false(a.intersects(b),
				"%s and %s must not print over each other" % [placed[i]["id"], placed[j]["id"]])


func test_fit_leaves_room_for_the_labels():
	# The fit used node positions only, so a fitted map's right-hand labels ran
	# off the canvas. Every node's label box now lands inside the view.
	var view := _make_view()
	view.fit_to_view()
	var font := view.get_theme_default_font()
	for node in view.nodes:
		var id := str(node["id"])
		var point := view.to_screen(view.positions[id] as Vector2)
		var width := font.get_string_size(
			str(node["label"]), HORIZONTAL_ALIGNMENT_LEFT, -1, VaultGraphView.LABEL_FONT_SIZE
		).x
		assert_between(point.x, 0.0, view.size.x)
		assert_lte(point.x + width, view.size.x,
			"%s's label must fit at the fitted zoom" % id)


func test_past_the_label_cap_only_the_aimed_at_nodes_are_named():
	# 120+ notes: the always-on labels would be a wall of text, so only the
	# selected/hovered/aimed node keeps its name (the pre-cull view drew one for
	# every node, which is where the overlap came from).
	var graph := {"nodes": [], "edges": [], "truncated": false}
	for i in VaultGraphView.MAX_ALWAYS_LABELS + 10:
		graph["nodes"].append({"id": "n%03d.md" % i, "label": "Note %d" % i, "ghost": false})
	var view := _make_view(graph, "n000.md")
	view._zoom = 1.0

	var ids := []
	for placement in view.label_placements():
		ids.append(placement["id"])
	assert_eq(ids.size(), 1, "past the cap the open note is the only label")
	assert_has(ids, "n000.md")
