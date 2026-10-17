extends GutTest
# Integration tests: settings application to pane bodies.
# Verifies that apply_settings propagates correctly.

var _scene: Control
var _tm: TerminalManager

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()
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

## Each of these checks the *effect* of the setting on the live pane, not that
## a property reads back what was assigned — a setter that stored the value
## and applied it nowhere would have passed the read-back.

func test_apply_settings_font_size():
	var body = _tm.create_body("terminal")
	_scene.add_child(body)
	assert_not_null(body)
	var cell_w: float = body._cell_w
	var cell_h: float = body._cell_h
	assert_gt(cell_w, 0.0, "the pane must have measured its glyphs before the change")

	body.apply_settings({"font_size": 28})

	assert_eq(body.font_size, 28)
	assert_gt(body._cell_w, cell_w, "a larger font must widen the cell")
	assert_gt(body._cell_h, cell_h, "a larger font must heighten the cell")
	assert_eq(body._font.fixed_size, 28, "the font itself is resized, not just the property")

func test_apply_settings_rows_cols():
	var body = _tm.create_body("terminal")
	_scene.add_child(body)
	assert_not_null(body._terminal, "the pane must own a grid for this test")
	body.apply_settings({"rows": 30, "cols": 100})
	assert_eq(body.rows, 30)
	assert_eq(body.cols, 100)
	assert_eq(body._terminal.get_rows(), 30, "the terminal grid is resized to the setting")
	assert_eq(body._terminal.get_cols(), 100)

func test_apply_settings_pane_name():
	var body = _tm.create_body("code_viewer")
	_scene.add_child(body)
	watch_signals(body)
	body.apply_settings({"pane_name": "CustomName"})
	assert_eq(body.pane_name, "CustomName")
	assert_signal_emitted_with_parameters(body, "title_changed", ["CustomName"])
	assert_eq(body._get_layout_state()["pane_name"], "CustomName",
		"the name is what gets saved")

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
	watch_signals(body)
	SettingsManager.apply_pane_settings(body, {"font_size": 22, "pane_name": "Delegated"})
	assert_eq(body.font_size, 22)
	# `title_changed` only comes out of the body's own `apply_settings`, so this
	# fails if the call stops going through it (a bare property write would
	# still have set font_size).
	assert_signal_emitted_with_parameters(body, "title_changed", ["Delegated"])

# ── Layout state ───────────────────────────────────────────────────────

func test_terminal_get_layout_state_carries_what_the_pane_holds():
	var body = _tm.create_body("terminal")
	_scene.add_child(body)
	body.shell_command = "/opt/custom-shell"
	body.shell_args = ["--login"]
	body.rows = 33
	body.cols = 91
	var state = body._get_layout_state()
	assert_eq(state.get("type"), "terminal")
	assert_eq(state.get("shell"), "/opt/custom-shell")
	assert_eq(state.get("shell_args"), ["--login"])
	assert_eq([state.get("rows"), state.get("cols")], [33, 91])
	assert_false(state.has("shell_env"), "a saved file must never carry the pane's env")

func test_code_viewer_get_layout_state_round_trips_through_apply_settings():
	var body = _tm.create_body("code_viewer")
	_scene.add_child(body)
	body.apply_settings({"pane_name": "Viewer", "font_size": 19})
	var state = body._get_layout_state()
	assert_eq(state.get("type"), "code_viewer")
	var twin = _tm.create_body("code_viewer")
	_scene.add_child(twin)
	twin.apply_settings(state)
	assert_eq(twin._get_layout_state(), state, "state -> apply -> state is stable")

# ── spawn_pane applies global settings ─────────────────────────────────

func test_spawn_pane_applies_global_settings():
	SettingsManager.cfg_font_size = 18
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()
	var body = _tm.spawn_pane("terminal", {})
	assert_not_null(body)
	assert_eq(body.font_size, 18, "spawn_pane must apply global font size")
	assert_eq(body.shell_command, SettingsManager.default_shell_command(), "spawn_pane must apply global shell")
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
