extends GutTest
# Unit tests for WorkspaceStore — workspace save/load, sanitization,
# and legacy layout.json migration.

func before_each():
	MockAutoloads.setup()

func after_each():
	MockAutoloads.teardown()

func _tile(type_name: String) -> Dictionary:
	return {"col": 0, "row": 0, "cspan": 12, "rspan": 12,
		"settings": {"type": type_name, "attachment_id": "pane-test01"}}

func test_save_load_roundtrip():
	var workspaces: Array[Dictionary] = [
		{"name": "Main", "layout": [_tile("terminal"), _tile("code_viewer")]},
		{"name": "Logs", "layout": [_tile("terminal")]},
	]
	WorkspaceStore.save(1, workspaces)
	var store = WorkspaceStore.load()
	assert_eq(store.get("active"), 1, "active index must survive")
	var wss: Array = store.get("workspaces", [])
	assert_eq(wss.size(), 2, "two workspaces must survive")
	assert_eq(wss[0].get("name"), "Main")
	assert_eq((wss[0].get("layout", []) as Array).size(), 2)
	assert_eq((wss[1].get("layout", []) as Array).size(), 1)

func test_load_empty_when_no_file():
	var store = WorkspaceStore.load()
	assert_eq(store.get("active"), 0)
	assert_eq((store.get("workspaces", []) as Array).size(), 0)

func test_active_clamped():
	var workspaces: Array[Dictionary] = [
		{"name": "A", "layout": []},
		{"name": "B", "layout": []},
	]
	WorkspaceStore.save(7, workspaces)
	assert_eq(WorkspaceStore.load().get("active"), 1, "out-of-range active must clamp")
	WorkspaceStore.save(-2, workspaces)
	assert_eq(WorkspaceStore.load().get("active"), 0, "negative active must clamp")

func test_name_sanitized():
	var workspaces: Array[Dictionary] = [
		{"name": "  Bad\nName\u0007 " + "x".repeat(64), "layout": []},
		{"name": "", "layout": []},
	]
	WorkspaceStore.save(0, workspaces)
	var wss: Array = WorkspaceStore.load().get("workspaces", [])
	assert_eq(String(wss[0].get("name", "")).length(), 32, "name must cap at 32 chars")
	assert_false(String(wss[0].get("name", "")).contains("\n"), "control chars must be dropped")
	assert_eq(wss[1].get("name"), "Workspace", "empty name must fall back")

func test_non_dict_entries_skipped():
	var workspaces: Array[Dictionary] = [
		{"name": "Good", "layout": [_tile("terminal"), "junk", 42, null]},
	]
	WorkspaceStore.save(0, workspaces)
	var wss: Array = WorkspaceStore.load().get("workspaces", [])
	assert_eq(wss.size(), 1)
	var layout: Array = wss[0].get("layout", [])
	assert_eq(layout.size(), 1, "non-dict tiles must be dropped")
	assert_true(layout[0] is Dictionary)

func test_legacy_layout_import():
	# Simulate a pre-workspaces layout.json with tiles at top level.
	MockAutoloads.set_store("user://layout.json", {
		"tiles": [_tile("terminal"), _tile("inspector")],
	})
	var legacy = WorkspaceStore.import_legacy_layout()
	assert_eq(legacy.size(), 2)
	assert_eq(legacy[0].get("settings", {}).get("type"), "terminal")

func test_legacy_import_empty_when_no_file():
	var legacy = WorkspaceStore.import_legacy_layout()
	assert_eq(legacy, [])
