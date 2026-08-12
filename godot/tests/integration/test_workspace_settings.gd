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
	if _ws:
		_ws.queue_free()
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
