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

	var btn := _tab_reset_button("System")
	assert_not_null(btn, "System tab must have a reset button")
	btn.pressed.emit()

	assert_eq(SettingsManager.cfg_window_mode, 0, "window mode must reset to OS")
	assert_eq(SettingsManager.cfg_max_fps, 0, "max fps must reset to unlimited")

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

# ── Reset button layout ────────────────────────────────────────────────

func test_reset_buttons_are_tab_wide_and_centered():
	for tab_name in ["System", "Terminal", "Appearance", "Reasoning"]:
		var btn := _tab_reset_button(tab_name)
		assert_not_null(btn, "%s tab must have a reset button" % tab_name)
		assert_eq(btn.size_flags_horizontal, Control.SIZE_EXPAND_FILL,
			"%s reset must span the tab width" % tab_name)
		assert_eq(btn.alignment, HORIZONTAL_ALIGNMENT_CENTER,
			"%s reset text must be centered" % tab_name)

# ── Color picker OK/Cancel ─────────────────────────────────────────────

func _color_picker_for(label_text: String) -> ColorPickerButton:
	var lbl := _row_label(label_text)
	assert_not_null(lbl, "row label must exist: " + label_text)
	for c in lbl.get_parent().get_children():
		if c is ColorPickerButton:
			return c
	return null

func _row_label(label_text: String) -> Label:
	for lbl in _panel.find_children("*", "Label", true, false):
		if lbl.text == label_text:
			return lbl
	return null

func test_color_pickers_have_ok_cancel_buttons():
	var picker := _color_picker_for("Wrapper bg")
	assert_not_null(picker, "wrapper bg row must carry a ColorPickerButton")
	picker.pressed.emit()  # first press creates the picker pane
	assert_not_null(picker.get_picker(), "pressing must create the picker")
	var texts: Array[String] = []
	for b in picker.get_picker().find_children("*", "Button", true, false):
		texts.append(b.text)
	assert_has(texts, "OK", "picker pane must offer an OK button")
	assert_has(texts, "Cancel", "picker pane must offer a Cancel button")

func test_color_picker_cancel_restores_pre_open_color():
	var picker := _color_picker_for("Wrapper bg")
	assert_not_null(picker)
	var pre_open := picker.color
	picker.pressed.emit()
	assert_not_null(picker.get_picker())
	# Simulate the popup-open capture and a live pick.
	picker.set_meta("_pre_open_color", pre_open)
	picker.color = Color(0.9, 0.1, 0.2)
	var cancel: Button = null
	for b in picker.get_picker().find_children("*", "Button", true, false):
		if b.text == "Cancel":
			cancel = b
			break
	assert_not_null(cancel)
	cancel.pressed.emit()
	assert_eq(picker.color, pre_open, "Cancel must restore the pre-open color")

# ── Concept dialog width ───────────────────────────────────────────────

func _find_accept_dialog(node: Node) -> AcceptDialog:
	for c in node.get_children():
		if c is AcceptDialog:
			return c
		var found := _find_accept_dialog(c)
		if found != null:
			return found
	return null

func test_concept_dialog_is_90_percent_of_menu_width():
	_panel._show_concept_dialog(-1)
	var dlg := _find_accept_dialog(_panel)
	assert_not_null(dlg, "concept dialog must exist after opening")
	assert_almost_eq(float(dlg.min_size.x), _panel._menu_width * 0.9, 0.01,
		"concept dialog must be 90 percent of the settings menu width")

# ── Titlebar toggle placement ──────────────────────────────────────────

## The pane titlebar on/off is a global setting with no per-pane equivalent, so
## the panel is the only place to find it — and it belongs with the chrome it
## switches, next to the Title bar colour, not in the System tab where a user
## looking for "titlebar" never looks.
func test_show_titlebar_toggle_lives_with_the_chrome_colors():
	var cb: CheckBox = _panel.find_child("ShowTitlebarCb", true, false)
	assert_not_null(cb, "the settings panel must expose a titlebar toggle")
	var tab := _tab_of(cb)
	assert_eq(tab, "Appearance",
		"the titlebar toggle belongs with the chrome colors, not in %s" % tab)

func test_show_titlebar_toggle_is_bound_to_the_setting():
	var cb: CheckBox = _panel.find_child("ShowTitlebarCb", true, false)
	SettingsManager.cfg_show_titlebar = true
	assert_true(cb.button_pressed, "the toggle must reflect the setting")
	cb.button_pressed = false
	_panel._debounce_timer.timeout.emit()  # the panel saves on a debounce
	assert_false(SettingsManager.cfg_show_titlebar,
		"toggling it off must reach the setting that hides every titlebar")

func test_appearance_reset_restores_the_titlebar():
	SettingsManager.cfg_show_titlebar = false
	_panel.find_child("ShowTitlebarCb", true, false).button_pressed = false
	var btn := _tab_reset_button("Appearance")
	assert_not_null(btn, "the Appearance tab must have a reset")
	btn.pressed.emit()
	assert_true(SettingsManager.cfg_show_titlebar,
		"resetting Appearance must bring the titlebars back")

## The ScrollContainer that holds a control carries its tab's title as its name.
func _tab_of(node: Node) -> String:
	var cur := node
	while cur != null:
		if cur is ScrollContainer:
			return cur.name
		cur = cur.get_parent()
	return ""

# ── Scrollback on disk ─────────────────────────────────────────────────

## The store is bounded by rows *and* bytes, so a user cannot work out what
## scrollback costs from the "History lines" setting — the panel has to say it.
func test_terminal_tab_reports_the_scrollback_store_size():
	var label: Label = null
	for candidate in _panel.find_children("*", "Label", true, false):
		if candidate.name == "HistorySizeLabel":
			label = candidate
			break
	assert_not_null(label, "the Terminal tab must carry a scrollback size row")
	assert_ne(label.text, "", "the row must show something, even with no store yet")
	assert_true(
		label.text.ends_with("B") or label.text == "unavailable",
		"the row must be a byte count; got '%s'" % label.text
	)
	# The path behind the number is worth a hover: it is where the user would
	# look (or delete) if the number got large.
	assert_string_contains(label.tooltip_text, "history.db")

## The row must show what the store answers, in the units it answers in — the
## provider is pinned here because the real store grows while the suite runs.
func test_the_row_reports_what_the_store_answers():
	_panel._history_stats_provider = func():
		return '{"path": "/tmp/user/history.db", "bytes": 1536}'
	_panel._refresh_history_size()
	var label: Label = null
	for candidate in _panel.find_children("*", "Label", true, false):
		if candidate.name == "HistorySizeLabel":
			label = candidate
			break
	assert_not_null(label)
	assert_eq(label.text, "1.5 KiB")
	assert_string_contains(label.tooltip_text, "/tmp/user/history.db")

func test_format_bytes_scales_through_the_units():
	assert_eq(SettingsPanel.format_bytes(0), "0 B")
	assert_eq(SettingsPanel.format_bytes(999), "999 B")
	assert_eq(SettingsPanel.format_bytes(1024), "1.0 KiB")
	assert_eq(SettingsPanel.format_bytes(1536), "1.5 KiB")
	assert_eq(SettingsPanel.format_bytes(5 * 1024 * 1024), "5.0 MiB")
	assert_eq(SettingsPanel.format_bytes(3 * 1024 * 1024 * 1024), "3.0 GiB")
	assert_eq(SettingsPanel.format_bytes(-1), "unavailable")
