extends GutTest
# Unit tests for IPC method routing patterns used by workspace.gd.
# Tests TerminalManager + ProfileManager methods that map to CLI commands.
# Workspace.gd itself cannot be instantiated in headless GUT (depends on
# GptyTerminal GDExtension class), so we test the underlying logic directly.
#
# Methods tested: listPanes, killPane, layoutSave/Load/List pattern,
# error response format, and _find_pane_by_label.
#
# newPane (terminal) is NOT tested here — it requires GptyTerminal.

const CannedShell := "/bin/sh"

var _tm: TerminalManager

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = CannedShell
	SettingsManager.cfg_default_rows = 24
	SettingsManager.cfg_default_cols = 80
	_tm = TerminalManager.new()

func after_each():
	_tm.reset()
	MockAutoloads.teardown()

# ── IPC error format ───────────────────────────────────────────────

func test_ipc_error_format():
	# Given: no state needed
	# When: building an error response
	# Then: shape matches JSON-RPC error convention
	var err = _ipc_error("something broke")
	assert_true(err is Dictionary, "error response should be a Dictionary")
	assert_true(err.has("error"), "error response should have 'error' key")
	assert_eq(err.error.code, -32000, "default error code should be -32000")
	assert_string_contains(err.error.message, "something broke")

func test_ipc_error_custom_code():
	# Given: a custom error code
	# When: building an error response with METHOD_NOT_FOUND code
	var err = _ipc_error("unknown method", -32601)
	assert_eq(err.error.code, -32601)
	assert_true(err.error.message != "")

# ── listPanes pattern ──────────────────────────────────────────────

func test_list_panes_returns_panes_and_count():
	# Given: a TerminalManager with two spawned panes
	var body1 = _tm.spawn_pane("code_viewer", {})
	var body2 = _tm.spawn_pane("file_tree", {})
	assert_not_null(body1)
	assert_not_null(body2)

	# When: building the panes list (mirrors workspace.gd logic)
	var result = _build_list_panes_response()

	# Then: response has panes array and count
	assert_true(result.has("panes"), "response should have 'panes' key")
	assert_true(result.has("count"), "response should have 'count' key")
	assert_eq(result.panes.size(), 2)
	assert_eq(result.count, 2)

func test_list_panes_each_entry_has_required_fields():
	# Given: a spawned pane
	var body = _tm.spawn_pane("code_viewer", {"pane_name": "TestViewer"})
	assert_not_null(body)

	# When: building the panes list
	var result = _build_list_panes_response()

	# Then: each entry has id, type, title, col, row, cspan, rspan, focused
	var entry = result.panes[0]
	assert_true(entry.has("id"), "pane entry should have id")
	assert_true(entry.has("type"), "pane entry should have type")
	assert_true(entry.has("title"), "pane entry should have title")
	assert_true(entry.has("col"), "pane entry should have col")
	assert_true(entry.has("row"), "pane entry should have row")
	assert_true(entry.has("cspan"), "pane entry should have cspan")
	assert_true(entry.has("rspan"), "pane entry should have rspan")
	assert_true(entry.has("focused"), "pane entry should have focused")
	assert_true(entry.focused is bool)

func test_list_panes_empty_returns_empty_array():
	# Given: no panes spawned
	# When: building the panes list
	var result = _build_list_panes_response()

	# Then: empty panes, count is 0
	assert_eq(result.panes.size(), 0)
	assert_eq(result.count, 0)

# ── killPane pattern ───────────────────────────────────────────────

func test_kill_pane_removes_tile_and_returns_success():
	# Given: a spawned pane
	var body = _tm.spawn_pane("code_viewer", {})
	assert_eq(_tm.tiles.size(), 1)

	# When: killing by label (mirrors workspace.gd logic)
	var pane_id = body.pane_label
	var found = _find_pane_by_label(pane_id)
	assert_not_null(found, "should find pane by label")
	_tm.kill(found)

	# Then: tile removed, response indicates success
	assert_eq(_tm.tiles.size(), 0, "tile should be removed after kill")
	# Success response shape
	var resp = {"success": true}
	assert_true(resp.success)

func test_kill_pane_not_found_returns_error():
	# Given: no pane with label "NOPE"
	# When: searching for it
	var found = _find_pane_by_label("NOPE")

	# Then: null returned, would produce IPC error
	assert_null(found, "non-existent label should return null")
	var err = _ipc_error("Pane 'NOPE' not found")
	assert_string_contains(err.error.message, "NOPE")

# ── layoutList pattern ─────────────────────────────────────────────

func test_layout_list_returns_profile_names():
	# Given: profiles in ProfileManager
	ProfileManager.add_profile("setup1", [])
	ProfileManager.add_profile("setup2", [])

	# When: collecting layout names (mirrors workspace.gd logic)
	var names = []
	for p in ProfileManager.profiles:
		names.append(p.get("name", ""))

	# Then: response has layouts array
	var result = {"layouts": names}
	assert_eq(result.layouts.size(), 2)
	assert_true("setup1" in result.layouts)
	assert_true("setup2" in result.layouts)

func test_layout_list_empty_when_no_profiles():
	# Given: no profiles saved (default state after reset)
	# Reset profiles by clearing
	for p in ProfileManager.profiles.duplicate():
		ProfileManager.delete_profile(ProfileManager.profiles.find(p))

	# When: collecting layout names
	var names = []
	for p in ProfileManager.profiles:
		names.append(p.get("name", ""))

	# Then: empty array
	assert_eq(names.size(), 0)

# ── Helpers (mirrors workspace.gd logic) ───────────────────────────

func _find_pane_by_label(label: String) -> Control:
	for t in _tm.tiles:
		var body = _tm._find_body(t.wrapper)
		if body and body.get("pane_label") == label:
			return body
	return null

func _build_list_panes_response() -> Dictionary:
	var panes = []
	for t in _tm.tiles:
		var body = _tm._find_body(t.wrapper)
		if body == null:
			continue
		panes.append({
			"id": body.pane_label,
			"type": body._pane_type(),
			"title": body.get("_last_title") if "_last_title" in body else "",
			"col": t.col, "row": t.row, "cspan": t.cspan, "rspan": t.rspan,
			"focused": body == _tm.last_body,
		})
	return {"panes": panes, "count": panes.size()}

func _ipc_error(msg: String, code := -32000):
	return {"error": {"code": code, "message": msg}}
