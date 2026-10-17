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
