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
		 "actions": [{"cmd": "echo test", "target": "terminal"}]}
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
	assert_eq(actions[0].get("cmd", ""), "",
		"default action command should be preserved")
# ── Save/load roundtrip ─────────────────────────────────────────────────

func test_save_concepts_stores_to_file():
	var concepts = [
		{"name": "test_concept", "trigger": "test_regex", "enabled": true,
		 "capture_mode": "single_line", "stop_timeout_ms": 0, "stop_on_input": false,
		 "actions": [{"cmd": "echo hello", "target": "terminal"}]}
	]
	ConceptManager.save_concepts(concepts)
	# After save, the in-memory store should have our data
	var saved = ConceptManager._read_file(ConceptManager.CONCEPTS_FILE)
	assert_true(saved.has("concepts"), "saved data should have concepts key")
	assert_eq(saved["concepts"].size(), 1, "should have 1 saved concept")

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
		"actions": [{"cmd": "", "target": "observer"}],
	}
	ConceptManager._migrate_actions_target(entry)
	assert_eq(entry["actions"][0]["target"], "observer")
	assert_eq(entry["enabled"], false)

func test_migrate_actions_target_leaves_other_targets():
	var entry: Dictionary = {
		"name": "boom",
		"actions": [
			{"cmd": "", "target": "code_viewer"},
			{"cmd": "echo x", "target": "terminal"},
		],
	}
	ConceptManager._migrate_actions_target(entry)
	assert_eq(entry["actions"][0]["target"], "code_viewer")
	assert_eq(entry["actions"][1]["target"], "terminal")

func test_migrate_actions_target_survives_malformed_actions():
	var entry: Dictionary = {"name": "odd", "actions": "not-an-array"}
	ConceptManager._migrate_actions_target(entry)
	pass # no crash is the assertion

func test_merge_disables_user_concept_observer_target():
	var user = [
		{"name": "legacy_observe", "trigger": "err", "enabled": true,
		 "capture_mode": "single_line", "stop_timeout_ms": 0, "stop_on_input": false,
		 "actions": [{"cmd": "", "target": "observer"}]}
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
		 "capture_mode": "single_line", "stop_timeout_ms": 0, "stop_on_input": false,
		 "actions": [{"cmd": "", "target": "inspector"}]}
	]
	ConceptManager.save_concepts(user)
	var merged = ConceptManager._merge_concepts()
	var modern = _find_by_name(merged, "modern")
	var actions = modern.get("actions", [])
	assert_eq(actions[0].get("target", ""), "inspector",
		"inspector targets should pass through unchanged")

# ── Helpers ────────────────────────────────────────────────────────────
func _find_by_name(arr: Array, name: String):
	for item in arr:
		if item is Dictionary and item.get("name", "") == name:
			return item
	return null
