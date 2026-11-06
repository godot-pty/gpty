extends GutTest
# WindowChrome — the titlebar's maximize control.
#
# The glyph is drawn by a child Label, so the button's own `text` is empty. The
# switch used to compare `max_btn.text` against the glyph constants, which could
# never match: the control said "maximize" in fullscreen forever (row
# *Window controls never swap maximize/restore*). These read the mode back off
# the control, and assert the bar's buttons draw through the shared treatment.

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

var _ws: Control


func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()
	SettingsManager.cfg_window_mode = 0


func after_each():
	SettingsManager.cfg_window_mode = 0
	SettingsManager.cfg_appearance_mode = SettingsManager.APPEARANCE_DARK
	SettingsManager.apply_appearance()
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
	ws.size = Vector2(1000, 700)
	return ws


func _controls(ws: Control) -> Dictionary:
	var bar: Control = ws._chrome.titlebar
	assert_not_null(bar, "the chrome builds a titlebar")
	return {
		"min": bar.get_node_or_null("WinControls/Minimize"),
		"max": bar.get_node_or_null("WinControls/Maximize"),
		"close": bar.get_node_or_null("WinControls/Close"),
	}


func test_the_maximize_control_swaps_glyph_and_name_with_the_mode():
	var ws = await _make_workspace()
	var chrome: WindowChrome = ws._chrome
	var max_btn: Button = _controls(ws)["max"]
	assert_not_null(max_btn, "the maximize control is named in the bar")

	SettingsManager.cfg_window_mode = 1
	chrome._sync_max_button()
	assert_eq(Icons.glyph(max_btn), Icons.MAXIMIZE_WIN, "windowed offers maximize")
	assert_eq(max_btn.accessibility_name, "Maximize window")

	SettingsManager.cfg_window_mode = 2
	chrome._sync_max_button()
	assert_eq(Icons.glyph(max_btn), Icons.RESTORE_WIN,
		"fullscreen offers restore, not a second maximize")
	assert_eq(max_btn.accessibility_name, "Restore window",
		"the name moves with the glyph: the button acts as what it says")

	SettingsManager.cfg_window_mode = 0
	chrome._sync_max_button()
	assert_eq(Icons.glyph(max_btn), Icons.MAXIMIZE_WIN, "back to a decorated window")
	assert_eq(max_btn.accessibility_name, "Maximize window")


func test_apply_mode_drives_the_switch():
	var ws = await _make_workspace()
	var max_btn: Button = _controls(ws)["max"]
	SettingsManager.cfg_window_mode = 2
	ws._chrome.apply_mode()
	assert_eq(Icons.glyph(max_btn), Icons.RESTORE_WIN,
		"every mode change goes through apply_mode")
	assert_eq(max_btn.accessibility_name, "Restore window")


func test_the_window_controls_draw_their_glyph_as_a_label():
	var ws = await _make_workspace()
	var buttons := _controls(ws)
	for key in ["min", "max", "close"]:
		var btn: Button = buttons[key]
		assert_not_null(btn, "the %s control is named in the bar" % key)
		assert_eq(btn.text, "",
			"nothing is composed into the exposed name for the %s control" % key)
		assert_ne(Icons.glyph(btn), "", "the %s control draws a glyph" % key)
		assert_eq(btn.custom_minimum_size.x, 36, "the bar's own target size wins")
