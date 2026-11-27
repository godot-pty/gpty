extends GutTest
# Integration test: rule priority in the visual concept editor.
#
# The canvas rows ARE the order rules are tried in. The trigger's title shows
# the rank, dragging a rule rewrites it, "Tidy" re-rows the canvas without
# reshuffling that order, and saving stores the order the manager applies.
#
# Driven through the editor's real API (`open`, `_save`, `_arrange`, and
# `position_offset` on the GraphNodes), so what is covered is the gesture a
# user makes — not a helper the test re-implemented.
#
# Ranks are read off the titles rather than hard-coded: the shipped defaults
# are loaded too, so a rule's absolute rank depends on how many of them there
# are, and a test that pinned the number would break every time one ships.

const GraphEditorScript = preload("res://scenes/ui/concept_graph_editor.gd")

var _scene: Control
var _editor: Control

func before_each():
	MockAutoloads.setup()
	_scene = TestScene.create()
	add_child(_scene)
	_editor = GraphEditorScript.new()
	_scene.add_child(_editor)

func after_each():
	if _editor:
		_editor.queue_free()
		_editor = null
	MockAutoloads.teardown()
	if _scene:
		_scene.queue_free()
		_scene = null

## Store the given rules as the user's concepts (the mocked store, no disk).
func _store_rules(names: Array) -> void:
	var concepts: Array = []
	for name in names:
		concepts.append({
			"name": name, "trigger": "trigger_" + str(name), "enabled": true,
			"capture_mode": "until_stop", "stop_timeout_ms": 300, "stop_on_input": true,
			"actions": [{"target": "terminal"}],
		})
	ConceptManager.save_state(concepts, {})

func _node(id: String) -> GraphNode:
	var gn = _editor._graph.get_node_or_null(NodePath(_editor._node_names.get(id, "")))
	assert_not_null(gn, "the canvas must hold the %s node" % id)
	return gn

## The rank a trigger's title advertises, with its shape checked on the way.
func _rank_of(id: String) -> int:
	var title := _node(id).title
	var dot := title.find(". ")
	assert_gt(dot, 0, "a rule title must carry its rank, got: %s" % title)
	assert_true(title.substr(dot + 2).begins_with("Trigger - "),
		"the rank is a prefix and the kind follows: %s" % title)
	return int(title.substr(0, dot))

# ── Ranks ──────────────────────────────────────────────────────────────

func test_titles_rank_the_rules_top_to_bottom():
	_store_rules(["alpha", "beta"])
	_editor.open()
	assert_lt(_rank_of("alpha#t"), _rank_of("beta#t"),
		"the higher row is tried first")
	assert_eq(_rank_of("beta#t"), _rank_of("alpha#t") + 1,
		"the two rows are adjacent in the order")

func test_dragging_a_rule_above_another_changes_its_rank():
	_store_rules(["alpha", "beta"])
	_editor.open()
	var beta_before := _rank_of("beta#t")
	_node("beta#t").position_offset = _node("alpha#t").position_offset - Vector2(0, 240)
	assert_lt(_rank_of("beta#t"), _rank_of("alpha#t"),
		"the rank follows the drag — the title names the rule that is tried first")
	assert_lt(_rank_of("beta#t"), beta_before, "beta moved up in the order")

# ── What gets saved ────────────────────────────────────────────────────

func test_saving_stores_the_canvas_order():
	_store_rules(["alpha", "beta"])
	_editor.open()
	_node("beta#t").position_offset = Vector2(40, 40)
	_node("alpha#t").position_offset = Vector2(40, 280)
	_editor._save()
	var order: Array = ConceptManager.get_graph_state()["order"]
	assert_true(order.has("alpha") and order.has("beta"),
		"both rules are ordered: %s" % str(order))
	assert_lt(order.find("beta"), order.find("alpha"),
		"the saved order is the canvas order: %s" % str(order))

func test_fit_re_rows_the_canvas_without_reordering():
	_store_rules(["alpha", "beta"])
	_editor.open()
	# Scattered, but beta is the higher row — the order is beta, alpha.
	_node("beta#t").position_offset = Vector2(500, 40)
	_node("alpha#t").position_offset = Vector2(900, 280)
	var beta_rank := _rank_of("beta#t")
	_editor._arrange()
	assert_eq(_rank_of("beta#t"), beta_rank, "tidying is never a reorder")
	assert_lt(_node("beta#t").position_offset.y, _node("alpha#t").position_offset.y,
		"tidying re-rows the canvas in the order it already has")
	assert_lt(_node("beta#t").position_offset.x, _node("beta#a").position_offset.x,
		"a chain still reads left to right")

# ── The error line ─────────────────────────────────────────────────────

## The status label shortens a long error list to three and puts the whole list
## on its tooltip, so the label has to stop the mouse: a `Label` defaults to
## `MOUSE_FILTER_IGNORE`, which the viewport's tooltip lookup skips (row *A
## concept row's provenance tooltip can never show*, the same trap).
func test_the_error_line_is_a_hover_target():
	var errors := []
	for i in 5:
		errors.append({"message": "rule %d is unreachable" % i, "ids": []})
	_editor._errors = errors
	_editor._update_error_display()
	var lbl: Label = _editor._error_label
	assert_not_null(lbl)
	if lbl == null:
		return
	assert_true(lbl.visible, "an error shows the line")
	assert_string_contains(lbl.text, "(+2 more)", "the text carries the count, not the list")
	assert_string_contains(lbl.tooltip_text, "rule 4 is unreachable",
		"the tooltip carries the whole list")
	assert_eq(lbl.mouse_filter, Control.MOUSE_FILTER_STOP,
		"a MOUSE_FILTER_IGNORE label is never a hover target, so the list could never be read")

func test_a_draft_node_lands_under_the_pointer():
	_store_rules(["alpha"])
	_editor.open()
	await wait_frames(2)
	await _size_scene()
	_editor._graph.zoom = 0.5
	await wait_frames(1)
	# The engine clamps a scroll to its content, so use the one it accepted.
	_editor._graph.scroll_offset = Vector2(200, 100)
	await wait_frames(1)
	var local := Vector2(300, 200)
	var gn: GraphNode = _node("alpha#t")
	gn.position_offset = _editor._graph_position_for(local)
	await wait_frames(2)
	assert_almost_eq(gn.position.x, local.x, 1.0, "x lands under the point")
	assert_almost_eq(gn.position.y, local.y, 1.0, "y lands under the point")
	# The toolbar spawns at the canvas centre.
	_editor._graph.zoom = 1.0
	await wait_frames(1)
	_editor._graph.scroll_offset = Vector2.ZERO
	await wait_frames(1)
	_editor._add_node(ConceptGraphModel.KIND_TRIGGER, Vector2.ZERO, false)
	await wait_frames(2)
	var toolbar_id := str(_editor._nodes.back()["id"])
	var toolbar_node: GraphNode = _node(toolbar_id)
	# The error line may appear with the draft and shrink the canvas by a row,
	# so the draft is near the centre, not exactly on it.
	assert_lt(toolbar_node.position_offset.distance_to(_editor._graph.size * 0.5), 64.0,
		"a toolbar draft lands at the canvas centre")

func _visible_graph_nodes() -> Array[GraphNode]:
	var out: Array[GraphNode] = []
	for child in _editor._graph.get_children():
		var gn := child as GraphNode
		if gn != null and gn.visible:
			out.append(gn)
	return out

func _nodes_fit() -> bool:
	var canvas := Rect2(Vector2.ZERO, _editor._graph.size)
	for gn in _visible_graph_nodes():
		if not canvas.encloses(Rect2(gn.position, gn.size * gn.scale)):
			return false
	return true

## Give the editor a laid-out canvas. `TestScene.create()` is full-rect, and
## assigning `size` on a Control with opposite anchors is overridden (and warns
## under GUT), so pin it top-left first.
func _size_scene(size := Vector2(1200, 800)) -> void:
	_scene.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_scene.size = size
	await wait_frames(2)

func test_selecting_a_node_moves_nothing():
	_store_rules(["alpha"])
	_editor.open()
	await wait_frames(2)
	await _size_scene()
	var gn: GraphNode = _node("alpha#t")
	var offset := gn.position_offset
	var screen := gn.position
	var node_size := gn.size
	_editor._graph.set_selected(gn)
	await wait_frames(2)
	assert_true(gn.selected)
	assert_eq(gn.position_offset, offset, "selection never moves the model's layout")
	assert_eq(gn.position, screen, "and never scrolls the canvas")
	assert_eq(gn.size, node_size, "the ring's content margins are the panel's")

func test_a_selected_node_resolves_the_accent_ring():
	_store_rules(["alpha"])
	_editor.open()
	await wait_frames(2)
	await _size_scene()
	_scene.theme = UiTheme.build()
	await wait_frames(1)
	var gn: GraphNode = _node("alpha#t")
	_editor._graph.set_selected(gn)
	var box := gn.get_theme_stylebox("panel_selected") as StyleBoxFlat
	assert_not_null(box, "the node resolves the selected box")
	assert_eq(box.border_width_left, 2)
	assert_eq(box.border_color, UiPalette.active().ACCENT)
	var panel := gn.get_theme_stylebox("panel") as StyleBoxFlat
	assert_eq(box.content_margin_left, panel.content_margin_left,
		"the ring does not resize the node")

func test_frame_all_fits_every_node():
	_store_rules(["alpha"])
	_editor.open()
	await wait_frames(2)
	await _size_scene()
	_node("alpha#t").position_offset = Vector2(4000, 1200)
	SettingsManager.cfg_motion = UiMotion.SUBTLE
	_editor._frame_all()
	assert_not_null(_editor._canvas_tween, "the frame eases")
	await wait_seconds(0.25)
	assert_true(_nodes_fit(), "every node is inside the canvas after the ease")
	SettingsManager.cfg_motion = UiMotion.SUBTLE

func test_frame_all_eases_and_off_lands_on_the_same_transform():
	_store_rules(["alpha"])
	_editor.open()
	await wait_frames(2)
	await _size_scene()
	_node("alpha#t").position_offset = Vector2(4000, 1200)
	SettingsManager.cfg_motion = UiMotion.SUBTLE
	var start_zoom: float = _editor._graph.zoom
	var start_scroll: Vector2 = _editor._graph.scroll_offset
	_editor._frame_all()
	# Two frames, not one: on Windows the tween's first step landed after the
	# frame the test awaited, so a single frame could not prove the ease moved.
	await wait_frames(2)
	assert_not_null(_editor._canvas_tween, "the frame eases")
	var mid_zoom: float = _editor._graph.zoom
	var mid_scroll: Vector2 = _editor._graph.scroll_offset
	assert_true(not is_equal_approx(mid_zoom, start_zoom)
		or not mid_scroll.is_equal_approx(start_scroll),
		"the camera moved off its start")
	await wait_seconds(0.25)
	var end_zoom: float = _editor._graph.zoom
	var end_scroll: Vector2 = _editor._graph.scroll_offset
	assert_true(_nodes_fit())
	_editor._graph.zoom = _editor._graph.zoom_min
	await wait_frames(1)
	SettingsManager.cfg_motion = UiMotion.OFF
	_editor._frame_all()
	assert_null(_editor._canvas_tween, "Off lands in one frame")
	assert_almost_eq(_editor._graph.zoom, end_zoom, 0.001)
	assert_true(_editor._graph.scroll_offset.is_equal_approx(end_scroll),
		"both paths land on the same transform")
	assert_true(_nodes_fit())
	SettingsManager.cfg_motion = UiMotion.SUBTLE

func test_an_interrupted_frame_all_leaves_one_tween():
	_store_rules(["alpha"])
	_editor.open()
	await wait_frames(2)
	await _size_scene()
	SettingsManager.cfg_motion = UiMotion.SUBTLE
	_editor._frame_all()
	await wait_frames(2)
	var first: Tween = _editor._canvas_tween
	assert_not_null(first)
	_editor._frame_all()
	assert_false(first.is_valid(), "the interrupted ease is killed")
	assert_not_null(_editor._canvas_tween)
	assert_ne(_editor._canvas_tween, first, "exactly one ease runs")
	await wait_seconds(0.25)
	assert_true(_nodes_fit())
	SettingsManager.cfg_motion = UiMotion.SUBTLE
