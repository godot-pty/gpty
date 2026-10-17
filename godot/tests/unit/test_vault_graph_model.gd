extends GutTest
# Unit tests for VaultGraphModel — the pure half of the wiki pane's link graph
# canvas: answer normalization, pair aggregation, damped weights, deterministic
# layout, and hit-testing. No scene tree, no FFI.

func _node(id: String, label := "", ghost := false) -> Dictionary:
	return {"id": id, "label": label if label != "" else id, "ghost": ghost}

func _edge(src: String, dst: String, count: int, ghost := false) -> Dictionary:
	return {"src": src, "dst": dst, "count": count, "ghost": ghost}

func _answer(nodes: Array, edges: Array, truncated := false) -> Dictionary:
	return {"nodes": nodes, "edges": edges, "truncated": truncated}


# ── Parsing ────────────────────────────────────────────────────────────

func test_parse_refuses_a_non_answer_and_a_failed_answer():
	var missing := VaultGraphModel.parse(null)
	assert_false(missing["ok"])
	assert_ne(missing["error"], "")
	var failed := VaultGraphModel.parse({"error": "no such vault"})
	assert_false(failed["ok"])
	assert_eq(failed["error"], "no such vault")
	assert_eq(failed["nodes"], [])
	assert_eq(failed["edges"], [])


func test_parse_normalizes_nodes_and_labels():
	var parsed := VaultGraphModel.parse(_answer([
		_node("dir/note.md", "A Title"),
		# An empty label (not the helper's id default) is the no-title case.
		{"id": "bare.md", "label": "", "ghost": false},
		{"id": "ghost:Missing", "label": "Missing", "ghost": true},
		{"label": "no id"},
	], []))
	assert_true(parsed["ok"])
	assert_eq(parsed["nodes"].size(), 3)
	assert_eq(parsed["nodes"][0]["label"], "A Title")
	# A note the index gave no title gets its stem, not its path.
	assert_eq(parsed["nodes"][1]["label"], "bare")
	assert_eq(parsed["nodes"][2]["label"], "Missing")
	assert_true(parsed["nodes"][2]["ghost"])


func test_parse_flattens_a_multi_line_label():
	var parsed := VaultGraphModel.parse(_answer([
		_node("note.md", "First\nSecond"),
	], []))
	assert_eq(parsed["nodes"][0]["label"], "First Second")


func test_parse_aggregates_both_directions_into_one_pair():
	var parsed := VaultGraphModel.parse(_answer(
		[_node("a.md"), _node("b.md")],
		[_edge("a.md", "b.md", 2), _edge("b.md", "a.md", 1)]
	))
	assert_eq(parsed["edges"].size(), 1, "parallel directions are one drawn edge")
	var edge: Dictionary = parsed["edges"][0]
	assert_eq(edge["a"], "a.md")
	assert_eq(edge["b"], "b.md")
	assert_eq(edge["ab"], 2)
	assert_eq(edge["ba"], 1)
	assert_eq(edge["count"], 3)
	assert_true(edge["mutual"])
	assert_false(edge["ghost"])


func test_parse_drops_self_references():
	var parsed := VaultGraphModel.parse(_answer(
		[_node("a.md")],
		[_edge("a.md", "a.md", 4)]
	))
	assert_eq(parsed["edges"], [], "a note mentioning itself is not drawn")


func test_parse_drops_edges_with_an_unknown_endpoint():
	var parsed := VaultGraphModel.parse(_answer(
		[_node("a.md")],
		[_edge("a.md", "missing.md", 1), _edge("nowhere.md", "a.md", 1)]
	))
	assert_eq(parsed["edges"].size(), 0)


func test_parse_keeps_ghost_edges_and_a_deterministic_order():
	var parsed := VaultGraphModel.parse(_answer(
		[_node("b.md"), _node("a.md"), {"id": "ghost:Missing", "label": "Missing", "ghost": true}],
		[
			_edge("b.md", "ghost:Missing", 1, true),
			_edge("a.md", "b.md", 2),
		]
	))
	assert_eq(parsed["edges"].size(), 2)
	assert_eq(parsed["edges"][0]["a"], "a.md")
	assert_eq(parsed["edges"][1]["a"], "b.md")
	assert_true(parsed["edges"][1]["ghost"])
	assert_eq(parsed["edges"][1]["b"], "ghost:Missing")


func test_parse_carries_the_truncated_flag():
	var parsed := VaultGraphModel.parse(_answer([_node("a.md")], [], true))
	assert_true(parsed["truncated"])


# ── Weights ────────────────────────────────────────────────────────────

func test_edge_width_is_logarithmic_and_clamped():
	assert_eq(VaultGraphModel.edge_width(1, 1), VaultGraphModel.EDGE_MAX_WIDTH)
	assert_eq(VaultGraphModel.edge_width(0, 10), VaultGraphModel.EDGE_MIN_WIDTH)
	var light := VaultGraphModel.edge_width(1, 100)
	var heavy := VaultGraphModel.edge_width(50, 100)
	assert_lt(light, heavy)
	assert_gte(light, VaultGraphModel.EDGE_MIN_WIDTH)
	assert_lte(heavy, VaultGraphModel.EDGE_MAX_WIDTH)
	# A hundred mentions is not a hundred times a one-mention pair.
	assert_lt(VaultGraphModel.edge_width(100, 100), VaultGraphModel.EDGE_MIN_WIDTH * 100.0)


func test_spring_strength_is_damped_not_linear():
	assert_almost_eq(VaultGraphModel.spring_strength(0), 1.0, 0.0001)
	assert_gt(VaultGraphModel.spring_strength(10), VaultGraphModel.spring_strength(1))
	assert_eq(VaultGraphModel.spring_strength(1000000), VaultGraphModel.MAX_SPRING)
	assert_lt(VaultGraphModel.spring_strength(1000000), 1000000.0)


func test_degrees_count_both_directions():
	var edges := [{"a": "a", "b": "b", "ab": 2, "ba": 1, "count": 3}]
	var degrees := VaultGraphModel.degrees(edges)
	assert_eq(degrees["a"], {"in": 1, "out": 2})
	assert_eq(degrees["b"], {"in": 2, "out": 1})


func test_node_radius_stays_within_its_bounds():
	assert_almost_eq(
		VaultGraphModel.node_radius(0, 10), VaultGraphModel.NODE_MIN_RADIUS, 0.0001
	)
	assert_almost_eq(
		VaultGraphModel.node_radius(10, 10), VaultGraphModel.NODE_MAX_RADIUS, 0.0001
	)
	assert_lte(VaultGraphModel.node_radius(50, 10), VaultGraphModel.NODE_MAX_RADIUS)


# ── Layout ─────────────────────────────────────────────────────────────

func _chain_graph() -> Dictionary:
	var nodes: Array = []
	var edges: Array = []
	for i in 8:
		nodes.append(_node("n%d.md" % i))
	for i in 7:
		edges.append({"a": "n%d.md" % i, "b": "n%d.md" % (i + 1), "ab": 1, "ba": 0, "count": 1})
	edges.append({"a": "n0.md", "b": "n4.md", "ab": 2, "ba": 0, "count": 2})
	return {"nodes": nodes, "edges": edges}


func test_layout_is_deterministic():
	var graph := _chain_graph()
	var first := VaultGraphModel.layout(graph["nodes"], graph["edges"], {})
	var second := VaultGraphModel.layout(graph["nodes"], graph["edges"], {})
	assert_eq(first.size(), 8)
	for id in first:
		assert_true(
			(first[id] as Vector2).is_equal_approx(second[id]),
			"%s must lay out to the same point twice" % id
		)


func test_layout_fills_the_world_box():
	var graph := _chain_graph()
	var positions := VaultGraphModel.layout(graph["nodes"], graph["edges"], {})
	var box := VaultGraphModel.bounds(positions)
	assert_gt(box.size.x, 0.0)
	assert_gt(box.size.y, 0.0)
	assert_lte(box.end.x, VaultGraphModel.LAYOUT_SIZE + 0.01)
	assert_lte(box.end.y, VaultGraphModel.LAYOUT_SIZE + 0.01)


func test_layout_keeps_existing_geometry_and_places_only_new_nodes():
	var graph := _chain_graph()
	var previous := {"n0.md": Vector2(11.0, 22.0), "n1.md": Vector2(33.0, 44.0)}
	var positions := VaultGraphModel.layout(graph["nodes"], graph["edges"], previous)
	assert_eq(positions["n0.md"], Vector2(11.0, 22.0))
	assert_eq(positions["n1.md"], Vector2(33.0, 44.0))
	assert_eq(positions.size(), 8)
	for id in positions:
		var point: Vector2 = positions[id]
		assert_true(is_finite(point.x) and is_finite(point.y), "%s must be finite" % id)


func test_a_single_node_layout_is_finite():
	var positions := VaultGraphModel.layout([_node("only.md")], [], {})
	assert_true(positions.has("only.md"))
	var point: Vector2 = positions["only.md"]
	assert_true(is_finite(point.x) and is_finite(point.y))


# ── Hit-testing ────────────────────────────────────────────────────────

func test_hit_test_picks_the_nearest_node_inside_the_radius():
	var nodes := [_node("a.md"), _node("b.md")]
	var positions := {"a.md": Vector2(10.0, 10.0), "b.md": Vector2(30.0, 10.0)}
	assert_eq(VaultGraphModel.hit_test(nodes, positions, Vector2(12.0, 10.0), 5.0), "a.md")
	assert_eq(VaultGraphModel.hit_test(nodes, positions, Vector2(28.0, 10.0), 5.0), "b.md")


func test_hit_test_returns_nothing_outside_the_radius():
	var nodes := [_node("a.md")]
	var positions := {"a.md": Vector2(10.0, 10.0)}
	assert_eq(VaultGraphModel.hit_test(nodes, positions, Vector2(40.0, 40.0), 5.0), "")
