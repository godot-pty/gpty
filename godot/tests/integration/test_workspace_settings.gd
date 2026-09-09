extends GutTest
# Integration tests: workspace-level settings consistency.
# Defends the fix for pane titlebars and terminal settings being
# dropped on profile activation and post-startup spawns.

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

var _ws: Control

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_show_titlebar = false
	SettingsManager.cfg_shell_command = "/bin/sh"
	SettingsManager.cfg_default_rows = 24
	SettingsManager.cfg_default_cols = 80
	SettingsManager.cfg_font_size = 17
	SettingsManager.cfg_cursor_shape = 1

func after_each():
	# Free synchronously while mocks are still active: _exit_tree() → _save()
	# would otherwise write the real layout/settings after teardown restores
	# the real persistence scripts.
	if _ws:
		if _ws.get_parent():
			_ws.get_parent().remove_child(_ws)
		_ws.free()
		_ws = null
	MockAutoloads.teardown()

func test_startup_spawn_gets_global_settings():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame

	var tm: TerminalManager = ws._tm
	assert_gt(tm.tiles.size(), 0, "workspace should spawn a terminal on empty layout")
	var body = tm._find_body(tm.tiles[0].wrapper)
	assert_eq(body.font_size, 17, "spawned terminal should get cfg font size")
	assert_eq(body.cursor_shape, 1, "spawned terminal should get cfg cursor shape")
	var tb = tm.tiles[0].wrapper.get_node_or_null("BodyVBox/TitleBar")
	assert_false(tb.visible, "spawned titlebar should be hidden when cfg_show_titlebar is false")
	# Wait out the deferred concept push timer so it doesn't resume after free.
	await get_tree().create_timer(2.1).timeout

func test_profile_activation_respects_show_titlebar():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame

	ws._do_activate({"name": "P", "tiles": [{
		"col": 0, "row": 0, "cspan": 12, "rspan": 12,
		"settings": {"type": "terminal", "shell": "/bin/sh", "rows": 24, "cols": 80},
	}]})
	await get_tree().process_frame

	var tm: TerminalManager = ws._tm
	assert_eq(tm.tiles.size(), 1, "profile activation should replace the layout")
	var tb = tm.tiles[0].wrapper.get_node_or_null("BodyVBox/TitleBar")
	assert_not_null(tb, "titlebar node should exist")
	assert_false(tb.visible, "profile-activated titlebar should be hidden when cfg_show_titlebar is false")
	# Wait out the deferred concept push timer so it doesn't resume after free.
	await get_tree().create_timer(2.1).timeout

func test_click_activates_non_terminal_pane():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame

	ws._do_activate({"name": "P", "tiles": [
		{"col": 0, "row": 0, "cspan": 6, "rspan": 12,
			"settings": {"type": "code_viewer", "pane_name": "C1"}},
		{"col": 6, "row": 0, "cspan": 6, "rspan": 12,
			"settings": {"type": "terminal", "shell": "/bin/sh", "rows": 24, "cols": 80}},
	]})
	await get_tree().process_frame
	await get_tree().process_frame

	var tm: TerminalManager = ws._tm
	var terminal_body = null
	var viewer_body = null
	for t in tm.tiles:
		var b = tm._find_body(t.wrapper)
		if b is TerminalPane:
			terminal_body = b
		else:
			viewer_body = b
	assert_not_null(terminal_body)
	assert_not_null(viewer_body)

	# A click inside the code viewer's wrapper must make it the active pane.
	var w0: Control = tm.tiles[0].wrapper
	var ev = InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = w0.get_global_rect().get_center()
	ws._input(ev)

	assert_eq(tm.last_body, viewer_body,
		"clicking a non-terminal pane must make it the active pane")

	# A click on the terminal must make it active again.
	var w1: Control = tm.tiles[1].wrapper
	ev.position = w1.get_global_rect().get_center()
	ws._input(ev)
	assert_eq(tm.last_body, terminal_body,
		"clicking the terminal must make it the active pane")
	# Wait out the deferred concept push timer so it doesn't resume after free.
	await get_tree().create_timer(2.1).timeout

func test_add_workspace_starts_blank():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame

	ws._add_workspace()
	assert_eq(ws._workspaces.size(), 2, "add_workspace must create a second workspace")
	var new_ws: Dictionary = ws._workspaces[1]
	assert_eq((new_ws.tm as TerminalManager).tiles.size(), 0,
		"a new workspace must be a blank slate — no auto-spawned terminal")
	# Wait out the deferred concept push timer so it doesn't resume after free.
	await get_tree().create_timer(2.1).timeout

func test_pane_run_executes_through_configured_shell():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame

	var result = WorkspaceIpcHandlers.handle(ws, "paneRun", {"command": "echo hi && exit 7"})
	assert_true(result is Dictionary and result.has("pane_id"), "paneRun must return a pane id")

	var tm: TerminalManager = ws._tm
	var body = null
	for t in tm.tiles:
		var b = tm._find_body(t.wrapper)
		if b is TerminalPane and b.attachment_id == str(result.get("pane_id", "")):
			body = b
			break
	assert_not_null(body, "paneRun must spawn a terminal pane")
	assert_eq(body.shell_command, SettingsManager.cfg_shell_command,
		"paneRun must use the configured shell as the program")
	assert_eq(body.shell_args, ["-c", "echo hi && exit 7"],
		"the command must run as shell arguments, not the program")

	var err = WorkspaceIpcHandlers.handle(ws, "paneRun", {"command": "   "})
	assert_true(err is Dictionary and err.has("error"), "empty command must error")
	# Wait out the deferred concept push timer so it doesn't resume after free.
	await get_tree().create_timer(2.1).timeout

func test_pane_settings_open_above_second_workspace_grid():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame

	ws._add_workspace()
	assert_eq(ws._workspaces.size(), 2, "add_workspace must create a second workspace")
	var body = ws._spawn_pane("terminal")
	assert_not_null(body, "spawning into the second workspace must work")

	ws._tm._open_pane_settings(body)
	var panel = ws._tm._pane_settings_panel
	assert_true(panel.visible, "pane settings popup must open on a non-first workspace")
	assert_gt(panel.z_index, ws._grid.z_index,
		"overlay panels must render above later-added workspace grids")
	# Wait out the deferred concept push timer so it doesn't resume after free.
	await get_tree().create_timer(2.1).timeout

func test_search_button_opens_active_terminal_search():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame

	ws._open_active_search()
	var tm: TerminalManager = ws._tm
	var body = tm._find_body(tm.tiles[0].wrapper)
	assert_true(body is TerminalPane, "startup must spawn a terminal")
	assert_true(body._search_visible, "search button must open the terminal search UI")
	# Wait out the deferred concept push timer so it doesn't resume after free.
	await get_tree().create_timer(2.1).timeout

func test_search_bar_is_compact_bottom_strip():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame

	var tm: TerminalManager = ws._tm
	var body = tm._find_body(tm.tiles[0].wrapper)
	assert_true(body is TerminalPane, "startup must spawn a terminal")
	body._toggle_search()
	await get_tree().process_frame

	# Regression: a missing anchor_top made every search control stretch to
	# full pane height — the bar covered the whole terminal as an overlay.
	assert_gt(body._search_bar.size.y, 20.0, "search bar must have real height")
	assert_lt(body._search_bar.size.y, 50.0, "search bar must be a compact strip, not a full-pane overlay")
	assert_lt(body._scope_btn.size.y, 50.0, "scope button must be a compact strip")
	assert_lt(body._history_panel.size.y, 250.0, "results panel must be bounded above the bar")
	assert_gt(body._search_bar.size.x, 400.0, "search bar must span most of the pane width")
	# Wait out the deferred concept push timer so it doesn't resume after free.
	await get_tree().create_timer(2.1).timeout

func test_profile_activation_refreshes_layout_and_pane_list():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)  # give layout math a real viewport
	await get_tree().process_frame
	await get_tree().process_frame

	ws._do_activate({"name": "P", "tiles": [
		{"col": 0, "row": 0, "cspan": 6, "rspan": 12,
			"settings": {"type": "code_viewer", "pane_name": "C1"}},
		{"col": 6, "row": 0, "cspan": 6, "rspan": 12,
			"settings": {"type": "terminal", "shell": "/bin/sh", "rows": 24, "cols": 80}},
	]})
	await get_tree().process_frame
	await get_tree().process_frame

	var tm: TerminalManager = ws._tm
	assert_eq(tm.tiles.size(), 2, "activation should restore two panes")
	# Regression: the pane list must populate immediately — no workspace
	# switch-and-back required.
	assert_eq(ws._sidebar._pane_list.get_child_count(), 2,
		"pane list must reflect the activated profile immediately")
	# Regression: wrappers must be laid out (not squished at the origin).
	var w0: Control = tm.tiles[0].wrapper
	assert_gt(w0.offset_right - w0.offset_left, 100.0,
		"activated wrapper must be laid out with real width")
	# Wait out the deferred concept push timer so it doesn't resume after free.
	await get_tree().create_timer(2.1).timeout
