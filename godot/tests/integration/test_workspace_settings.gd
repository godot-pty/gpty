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
