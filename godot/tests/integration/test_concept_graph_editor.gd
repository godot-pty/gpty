extends GutTest
# Integration test: rule priority in the visual concept editor.
#
# The canvas rows ARE the order rules are tried in. The trigger's title shows
# the rank, dragging a rule rewrites it, "Fit" re-rows the canvas without
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
