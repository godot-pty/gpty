extends GutTest
# Integration tests: settings application to pane bodies.
# Verifies that apply_settings propagates correctly.

var _scene: Control
var _tm: TerminalManager

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = "/bin/sh"
	SettingsManager.cfg_default_rows = 24
	SettingsManager.cfg_default_cols = 80
	SettingsManager.cfg_font_size = 14
	_scene = TestScene.create()
	add_child(_scene)
	_tm = TerminalManager.new()

func after_each():
	_tm.reset()
	MockAutoloads.teardown()
	if _scene:
		_scene.queue_free()

# ── Settings application ───────────────────────────────────────────────

func test_apply_settings_font_size():
	var body = _tm.create_body("terminal")
	_scene.add_child(body)
	assert_not_null(body)
	body.apply_settings({"font_size": 20})
	assert_eq(body.font_size, 20)

func test_apply_settings_rows_cols():
	var body = _tm.create_body("terminal")
	_scene.add_child(body)
	body.apply_settings({"rows": 30, "cols": 100})
	assert_eq(body.rows, 30)
	assert_eq(body.cols, 100)

func test_apply_settings_pane_name():
	var body = _tm.create_body("code_viewer")
	_scene.add_child(body)
	body.apply_settings({"pane_name": "CustomName"})
	assert_eq(body.pane_name, "CustomName")

func test_apply_to_terminal_from_settings():
	var body = _tm.create_body("terminal")
	_scene.add_child(body)
	SettingsManager.cfg_font_size = 18
	SettingsManager.cfg_cursor_shape = 1  # block
	SettingsManager.apply_to_terminal(body)
	assert_eq(body.font_size, 18)
	assert_eq(body.get("cursor_shape"), 1)

func test_apply_pane_settings_delegates():
	var body = _tm.create_body("code_viewer")
	_scene.add_child(body)
	SettingsManager.apply_pane_settings(body, {"font_size": 22})
	assert_eq(body.font_size, 22)

# ── Layout state ───────────────────────────────────────────────────────

func test_terminal_get_layout_state_has_type():
	var body = _tm.create_body("terminal")
	_scene.add_child(body)
	var state = body._get_layout_state()
	assert_eq(state.get("type"), "terminal")
	assert_true(state.has("shell"))

func test_code_viewer_get_layout_state_has_type():
	var body = _tm.create_body("code_viewer")
	_scene.add_child(body)
	var state = body._get_layout_state()
	assert_eq(state.get("type"), "code_viewer")

# ── spawn_pane applies global settings ─────────────────────────────────

func test_spawn_pane_applies_global_settings():
	SettingsManager.cfg_font_size = 18
	SettingsManager.cfg_shell_command = "/bin/sh"
	var body = _tm.spawn_pane("terminal", {})
	assert_not_null(body)
	assert_eq(body.font_size, 18, "spawn_pane must apply global font size")
	assert_eq(body.shell_command, "/bin/sh", "spawn_pane must apply global shell")
	for t in _tm.tiles:
		t.wrapper.free()
	_tm.tiles.clear()

func test_spawn_pane_opts_override_globals():
	SettingsManager.cfg_font_size = 18
	var body = _tm.spawn_pane("terminal", {"font_size": 22, "shell_command": "/bin/zsh"})
	assert_not_null(body)
	assert_eq(body.font_size, 22, "per-pane font_size must override global")
	assert_eq(body.shell_command, "/bin/zsh", "per-pane shell must override global")
	for t in _tm.tiles:
		t.wrapper.free()
	_tm.tiles.clear()
