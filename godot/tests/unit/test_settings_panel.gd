extends GutTest
# Settings panel — per-tab resets, scheme reset, and per-color resets.
# Defends: reset buttons restore only their own scope and update both
# the cfg vars and the visible controls.

class MockWorkspace extends Control:
	func get_terminal_for_ffi() -> Node:
		return null

var _ws: MockWorkspace
var _panel: SettingsPanel

func before_each():
	MockAutoloads.setup()
	_ws = MockWorkspace.new()
	add_child_autofree(_ws)
	_panel = SettingsPanel.new(_ws)
	add_child_autofree(_panel)
	await get_tree().process_frame

func after_each():
	MockAutoloads.teardown()

# ── Helpers ────────────────────────────────────────────────────────────

func _tab_reset_button(tab_name: String) -> Button:
	for btn in _panel.find_children("*", "Button", true, false):
		if btn.text != "Reset tab to defaults":
			continue
		# The tab's ScrollContainer carries the tab title as its name.
		var node: Node = btn
		while node != null and not (node is ScrollContainer):
			node = node.get_parent()
		if node is ScrollContainer and node.name == tab_name:
			return btn
	return null

func _row_reset(label_text: String) -> Button:
	for lbl in _panel.find_children("*", "Label", true, false):
		if lbl.text != label_text:
			continue
		var row := lbl.get_parent()
		if row == null:
			continue
		for c in row.get_children():
			if c is Button and c.text == Icons.RESET:
				return c
	return null

# ── Per-tab resets ─────────────────────────────────────────────────────

func test_appearance_reset_restores_only_appearance_settings():
	SettingsManager.cfg_font_size = 22
	SettingsManager.cfg_wrapper_bg = Color(1.0, 0.0, 0.0)
	SettingsManager.cfg_color_scheme_path = "/tmp/scheme.csv"
	SettingsManager.cfg_shell_command = "/bin/zsh"  # Terminal-tab setting, must survive

	var btn := _tab_reset_button("Appearance")
	assert_not_null(btn, "Appearance tab must have a reset button")
	btn.pressed.emit()

	assert_eq(SettingsManager.cfg_font_size, 14, "font size must reset to default")
	assert_eq(SettingsManager.cfg_wrapper_bg, SettingsManager.WRAPPER_BG_COLOR,
		"wrapper bg must reset to default")
	assert_eq(SettingsManager.cfg_color_scheme_path, "", "scheme path must reset to empty")
	assert_eq(SettingsManager.cfg_shell_command, "/bin/zsh",
		"other tabs' settings must not be touched")

func test_terminal_reset_restores_only_terminal_settings():
	SettingsManager.cfg_scroll_lines = 9
	SettingsManager.cfg_default_rows = 60
	SettingsManager.cfg_reasoning_max_turns = 33

	var btn := _tab_reset_button("Terminal")
	assert_not_null(btn, "Terminal tab must have a reset button")
	btn.pressed.emit()

	assert_eq(SettingsManager.cfg_scroll_lines, 3, "scroll lines must reset to default")
	assert_eq(SettingsManager.cfg_default_rows, 24, "default rows must reset to default")
	assert_eq(SettingsManager.cfg_reasoning_max_turns, 33,
		"other tabs' settings must not be touched")

func test_system_reset_restores_system_settings():
	SettingsManager.cfg_window_mode = 2
	SettingsManager.cfg_max_fps = 60
	SettingsManager.cfg_show_titlebar = false

	var btn := _tab_reset_button("System")
	assert_not_null(btn, "System tab must have a reset button")
	btn.pressed.emit()

	assert_eq(SettingsManager.cfg_window_mode, 0, "window mode must reset to OS")
	assert_eq(SettingsManager.cfg_max_fps, 0, "max fps must reset to unlimited")
	assert_true(SettingsManager.cfg_show_titlebar, "titlebar must reset to shown")

func test_reasoning_reset_restores_reasoning_settings():
	SettingsManager.cfg_reasoning_max_turns = 3
	SettingsManager.cfg_reasoning_max_turn_bytes = 8192

	var btn := _tab_reset_button("Reasoning")
	assert_not_null(btn, "Reasoning tab must have a reset button")
	btn.pressed.emit()

	assert_eq(SettingsManager.cfg_reasoning_max_turns, 16, "max turns must reset")
	assert_eq(SettingsManager.cfg_reasoning_max_turn_bytes, 65536, "max bytes must reset")

func test_no_global_reset_button_remains():
	for btn in _panel.find_children("*", "Button", true, false):
		assert_ne(btn.text, "Reset to defaults",
			"the all-tabs reset button must be gone (per-tab resets only)")

# ── Scheme reset ───────────────────────────────────────────────────────

func test_scheme_reset_button_clears_path():
	SettingsManager.cfg_color_scheme_path = "/tmp/scheme.csv"
	var reset := _row_reset("Color scheme:")
	assert_not_null(reset, "Color scheme row must have a reset button")
	reset.pressed.emit()
	assert_eq(SettingsManager.cfg_color_scheme_path, "",
		"scheme reset must clear the configured path")

# ── Per-color resets ───────────────────────────────────────────────────

func test_wrapper_bg_color_reset():
	SettingsManager.cfg_wrapper_bg = Color(0.9, 0.1, 0.2)
	var reset := _row_reset("Wrapper bg")
	assert_not_null(reset, "Wrapper bg row must have a reset button")
	reset.pressed.emit()
	assert_eq(SettingsManager.cfg_wrapper_bg, SettingsManager.WRAPPER_BG_COLOR,
		"per-color reset must restore the default wrapper bg")

func test_scrollback_color_reset():
	SettingsManager.cfg_scrollback_indicator = Color(0.1, 0.2, 0.9)
	var reset := _row_reset("Scroll")
	assert_not_null(reset, "Scroll row must have a reset button")
	reset.pressed.emit()
	assert_eq(SettingsManager.cfg_scrollback_indicator,
		SettingsManager.SCROLLBACK_INDICATOR_COLOR,
		"per-color reset must restore the default scrollback indicator color")

# ── Uniform picker width (issue: haphazard widths) ─────────────────────

func test_color_labels_have_uniform_minimum_width():
	var labels := []
	for lbl in _panel.find_children("*", "Label", true, false):
		if lbl.text in ["Wrapper bg", "Title bar", "Border", "Sidebar", "Focus", "Selection", "Scroll"]:
			labels.append(lbl)
	assert_eq(labels.size(), 7, "all seven UI color rows must exist")
	for lbl in labels:
		assert_eq(lbl.custom_minimum_size.x, 96.0,
			"color row labels must share one minimum width so pickers align")
