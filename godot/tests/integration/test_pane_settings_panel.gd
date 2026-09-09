extends GutTest
# Pane settings popup lifecycle — the popup must close when its target
# pane is torn down (kill, type swap, reset) and never stay open over a
# freed body (a dead popup swallows every interaction as script errors).

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

var _ws: Control

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = "/bin/sh"

func after_each():
	if _ws:
		if _ws.get_parent():
			_ws.get_parent().remove_child(_ws)
		_ws.free()
		_ws = null
	MockAutoloads.teardown()

func _make_workspace() -> Control:
	var ws: Control = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame
	return ws

func _panel(ws: Control) -> Control:
	return ws._tm._pane_settings_panel

func _first_body(ws: Control) -> Control:
	var tm: TerminalManager = ws._tm
	return tm._find_body(tm.tiles[0].wrapper)

func test_popup_closes_when_target_pane_killed():
	var ws = await _make_workspace()
	var body = _first_body(ws)
	assert_true(body is TerminalPane, "startup must spawn a terminal")

	ws._tm._open_pane_settings(body)
	var panel = _panel(ws)
	assert_true(panel.visible, "popup opens for the pane")

	ws._kill(body)
	assert_false(panel.visible, "killing the target pane must close the popup")

func test_popup_closes_when_killed_via_sidebar_signal_path():
	var ws = await _make_workspace()
	var body = _first_body(ws)
	ws._tm._open_pane_settings(body)
	var panel = _panel(ws)
	assert_true(panel.visible)

	# The sidebar close button emits request_close → workspace _kill.
	ws._sidebar.request_close.emit(body)
	assert_false(panel.visible, "sidebar close must close the popup too")

func test_popup_closes_on_type_swap():
	var ws = await _make_workspace()
	var body = _first_body(ws)
	ws._tm._open_pane_settings(body)
	var panel = _panel(ws)
	assert_true(panel.visible)

	ws._swap_pane(body, "code_viewer")
	assert_false(panel.visible, "swapping the target pane must close the popup")
	var tm: TerminalManager = ws._tm
	var swapped = tm._find_body(tm.tiles[0].wrapper)
	assert_eq(swapped._pane_type(), "code_viewer", "the tile must now hold the swapped pane type")

func test_popup_self_closes_when_target_freed_without_kill():
	var ws = await _make_workspace()
	var body = _first_body(ws)
	ws._tm._open_pane_settings(body)
	var panel = _panel(ws)
	assert_true(panel.visible)

	# teardown paths (reset/restore/workspace close) free wrappers without
	# going through _kill — the panel's _process backstop must hide it.
	ws._tm.reset()
	await get_tree().process_frame
	await get_tree().process_frame
	assert_false(panel.visible, "popup must self-close once its target is freed")

func test_popup_opens_again_after_close_for_another_pane():
	var ws = await _make_workspace()
	var body = _first_body(ws)
	var body2 = ws._spawn_pane("terminal")
	assert_not_null(body2, "second terminal must spawn")
	var panel = _panel(ws)

	ws._tm._open_pane_settings(body)
	assert_true(panel.visible)
	panel.close()
	assert_false(panel.visible)

	ws._tm._open_pane_settings(body2)
	assert_true(panel.visible, "popup must reopen for a different pane")
	assert_eq(panel._target, body2, "reopened popup must target the new pane")

func test_open_for_null_target_stays_closed():
	var ws = await _make_workspace()
	var panel = _panel(ws)
	panel.open_for(null)
	assert_false(panel.visible, "a null target must not open the popup")

func test_popup_moves_to_end_of_tree_when_opened():
	# Godot 4 GUI input picking ignores z_index and uses reverse tree
	# order — the LAST sibling gets clicks first. Workspace grids are
	# added after the panel, so the popup must move to the end of the
	# workspace's children or later grids would eat its input while
	# z_index still renders it on top (visible-but-dead popup).
	var ws = await _make_workspace()
	ws._add_workspace()  # a grid added AFTER the pane settings panel
	var body = ws._spawn_pane("terminal")
	assert_not_null(body, "spawning into the second workspace must work")
	var panel = _panel(ws)
	ws._tm._open_pane_settings(body)
	assert_eq(panel.get_index(), ws.get_child_count() - 1,
		"open popup must be the last child so tree-order picking hits it first")

func test_settings_panel_moves_to_end_of_tree_when_opened():
	var ws = await _make_workspace()
	ws._add_workspace()
	await get_tree().process_frame
	ws._toggle_settings()
	assert_true(ws._settings_panel.visible, "global settings must open")
	assert_eq(ws._settings_panel.get_index(), ws.get_child_count() - 1,
		"open settings panel must be the last child for tree-order picking")

func test_palette_moves_to_end_of_tree_when_opened():
	var ws = await _make_workspace()
	ws._add_workspace()
	await get_tree().process_frame
	ws._toggle_palette()
	assert_true(ws._palette.visible, "palette must open")
	assert_eq(ws._palette.get_index(), ws.get_child_count() - 1,
		"open palette must be the last child for tree-order picking")

func test_popup_does_not_activate_panes_underneath():
	var ws = await _make_workspace()
	var body = _first_body(ws)
	ws._tm._open_pane_settings(body)
	var panel = _panel(ws)
	assert_true(panel.visible)

	# A click landing on the popup area must not re-target the active pane
	# to whatever tile happens to sit underneath the overlay.
	ws._tm.last_body = null
	var wrapper: Control = ws._tm.tiles[0].wrapper
	var ev = InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = wrapper.get_global_rect().get_center()
	ws._input(ev)
	assert_null(ws._tm.last_body, "clicks over the open popup must not activate panes")

func test_global_settings_close_pane_settings_popup():
	var ws = await _make_workspace()
	var body = _first_body(ws)
	ws._tm._open_pane_settings(body)
	assert_true(_panel(ws).visible)

	ws._toggle_settings()
	assert_false(_panel(ws).visible, "opening global settings must close the pane popup")
	assert_true(ws._settings_panel.visible, "global settings must open")

func test_pane_settings_close_global_settings_popup():
	var ws = await _make_workspace()
	ws._toggle_settings()
	assert_true(ws._settings_panel.visible)

	var body = _first_body(ws)
	ws._tm._open_pane_settings(body)
	assert_false(ws._settings_panel.visible, "opening pane settings must close global settings")
	assert_true(_panel(ws).visible, "pane popup must open")
