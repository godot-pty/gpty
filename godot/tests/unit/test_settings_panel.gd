extends GutTest
# Settings panel — per-tab resets, scheme reset, and per-color resets.
# Defends: reset buttons restore only their own scope and update both
# the cfg vars and the visible controls.

class MockWorkspace extends Control:
	func get_terminal_for_ffi() -> Node:
		return null

var _ws: MockWorkspace
var _panel: SettingsPanel
var _original_window_size := Vector2i.ZERO

func before_each():
	_original_window_size = get_window().size
	MockAutoloads.setup()
	_ws = MockWorkspace.new()
	add_child_autofree(_ws)
	_panel = SettingsPanel.new(_ws)
	add_child_autofree(_panel)
	await get_tree().process_frame

func after_each():
	# The palette is process-global; a picker test that left it light would
	# re-theme every later suite.
	SettingsManager.cfg_appearance_mode = SettingsManager.APPEARANCE_DARK
	SettingsManager.apply_appearance()
	# A failed assertion must not leave a small window for the rest of the
	# process; the layout assertions in this file are the card's own minimums.
	get_window().size = _original_window_size
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
			if c is Button and Icons.glyph(c) == Icons.RESET:
				return c
	return null

## Pin the window to the size an assertion measures the cap against, and prove
## it took: a headless or developer window of any other size would move the
## expected number.
func _pin_window(size: Vector2i) -> void:
	get_window().size = size
	assert_eq(get_window().size, size,
		"the test window must take a size the cap can be measured against")

# ── Per-tab resets ─────────────────────────────────────────────────────

func test_appearance_reset_restores_only_appearance_settings():
	SettingsManager.cfg_font_size = 22
	SettingsManager.cfg_wrapper_bg = Color(1.0, 0.0, 0.0)
	SettingsManager.cfg_color_scheme_path = "/tmp/scheme.csv"
	SettingsManager.cfg_ui_scale = 175
	SettingsManager.cfg_shell_command = "/bin/zsh"  # Terminal-tab setting, must survive

	var btn := _tab_reset_button("Appearance")
	assert_not_null(btn, "Appearance tab must have a reset button")
	btn.pressed.emit()

	assert_eq(SettingsManager.cfg_font_size, 14, "font size must reset to default")
	assert_eq(SettingsManager.cfg_wrapper_bg, UiPalette.active().BG,
		"wrapper bg must reset to the active palette's background")
	assert_eq(SettingsManager.cfg_ui_scale, 100, "the UI scale must reset to 100 %")
	assert_eq(SettingsManager.cfg_color_scheme_path, "", "scheme path must reset to empty")
	assert_eq(SettingsManager.cfg_shell_command, "/bin/zsh",
		"other tabs' settings must not be touched")

func test_terminal_reset_restores_only_terminal_settings():
	# The autoload outlives this file: a reset that left a hard-coded shell behind
	# is how the Windows run failed (later tests spawned panes with `/bin/bash`,
	# which gpty refuses to spawn there), so the value is put back either way.
	var original_shell := SettingsManager.cfg_shell_command
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
	assert_eq(SettingsManager.cfg_shell_command, SettingsManager.default_shell_command(),
		"the reset must restore this platform's shell, not a POSIX path")
	SettingsManager.cfg_shell_command = original_shell

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
	assert_eq(SettingsManager.cfg_wrapper_bg, UiPalette.active().BG,
		"per-color reset must restore the active palette's background")

func test_scrollback_color_reset():
	SettingsManager.cfg_scrollback_indicator = Color(0.1, 0.2, 0.9)
	var reset := _row_reset("Scroll")
	assert_not_null(reset, "Scroll row must have a reset button")
	reset.pressed.emit()
	assert_eq(SettingsManager.cfg_scrollback_indicator,
		UiPalette.active().SCROLLBACK_INDICATOR,
		"per-color reset must restore the default scrollback indicator color")

# ── Uniform picker width (issue: haphazard widths) ─────────────────────

func test_color_labels_have_uniform_minimum_width():
	for name in ["Wrapper bg", "Title bar", "Border", "Sidebar", "Focus", "Selection", "Scroll"]:
		var lbl := _row_label_prefix(name)
		assert_not_null(lbl, "the %s row must exist" % name)
		assert_eq(lbl.custom_minimum_size.x, 96.0,
			"color row labels must share one minimum width so pickers align")
	assert_string_contains(_row_label_prefix("Selection").text, "(40%)",
		"a translucent swatch names its opacity in the row")
	assert_string_contains(_row_label_prefix("Focus").text, "(30%)")

## The swatch's reading is its label: a pick updates it and the reset restores
## both the palette's colour and the words.
func test_swatch_label_follows_a_pick_and_the_reset():
	# Selection starts at the palette's translucent value and says so.
	assert_eq(_row_label_prefix("Selection").text, "Selection (40%)")
	var sel: ColorPickerButton = null
	for c in _row_label_prefix("Selection").get_parent().get_children():
		if c is ColorPickerButton:
			sel = c
	assert_not_null(sel, "the Selection row carries a picker")
	sel.color = Color(0.9, 0.1, 0.2)
	sel.color_changed.emit(sel.color)          # assignment does not emit; a pick does
	assert_eq(_row_label_prefix("Selection").text, "Selection",
		"an opaque colour drops the reading")
	assert_eq(_row_label_prefix("Selection").tooltip_text, "")
	var reset := _row_reset_prefix("Selection")
	assert_not_null(reset)
	reset.pressed.emit()
	assert_almost_eq(SettingsManager.cfg_selection.a, 0.4, 0.001)
	assert_eq(_row_label_prefix("Selection").text, "Selection (40%)",
		"the reset restores the palette's colour and the label says so again")

# ── Reset button layout ────────────────────────────────────────────────

func test_reset_buttons_are_tab_wide_and_centered():
	for tab_name in ["System", "Terminal", "Appearance", "Reasoning"]:
		var btn := _tab_reset_button(tab_name)
		assert_not_null(btn, "%s tab must have a reset button" % tab_name)
		assert_eq(btn.size_flags_horizontal, Control.SIZE_EXPAND_FILL,
			"%s reset must span the tab width" % tab_name)
		assert_eq(btn.alignment, HORIZONTAL_ALIGNMENT_CENTER,
			"%s reset text must be centered" % tab_name)

## The Terminal tab overflows the 540x560 card by 62 px, so the row *Every
## scrollable surface has a 0 px scrollbar* needs that overflow to have a real
## bar. The card keeps its design size here, so the column must not widen it.
func test_the_terminal_tab_shows_a_scrollbar_column():
	SettingsManager.cfg_ui_scale = 100
	_pin_window(Vector2i(1920, 1080))
	SettingsManager.apply_ui_scale()
	# The suite host carries no app theme, and the engine's own default bar is
	# also 8 px: without this the width assertion could pass for the wrong reason.
	_panel.theme = UiTheme.build()
	_panel.open()
	await wait_frames(2)
	var tab: ScrollContainer = null
	for node in _panel.find_children("*", "ScrollContainer", true, false):
		if node.name == "Terminal":
			tab = node as ScrollContainer
			break
	assert_not_null(tab, "the Terminal tab is a ScrollContainer")
	if tab == null:
		return
	# A tab is only laid out once it is current (`TabContainer` sizes the
	# current child), so the System tab would report a zero-sized viewport.
	var tabs := tab.get_parent() as TabContainer
	assert_not_null(tabs, "the Terminal tab belongs to the settings TabContainer")
	if tabs == null:
		return
	tabs.current_tab = tabs.get_tab_idx_from_control(tab)
	await wait_frames(2)
	var bar := tab.get_v_scroll_bar()
	assert_gt(bar.max_value, bar.page, "the Terminal tab's content overflows the card")
	assert_true(bar.visible, "the overflow shows a bar")
	assert_eq(bar.size.x, UiTokens.SCROLLBAR_THICKNESS, "the bar reserves the column it draws in")
	var card := (_panel.get_child(0) as Control).get_child(0) as Control
	assert_eq(card.size, SettingsPanel.CARD_SIZE,
		"the card keeps its design size in a window that fits it")

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

## The colour row for `text`. Five rows read as their setting name; two carry
## their swatch's reading in brackets (`Selection (40%)`). The bracket guard
## keeps `Scroll` away from the Terminal tab's `Scroll lines:`.
func _row_label_prefix(text: String) -> Label:
	for lbl in _panel.find_children("*", "Label", true, false):
		if lbl.text == text or lbl.text.begins_with(text + " ("):
			return lbl
	return null

func _row_reset_prefix(text: String) -> Button:
	var lbl := _row_label_prefix(text)
	if lbl == null:
		return null
	for c in lbl.get_parent().get_children():
		if c is Button and Icons.glyph(c) == Icons.RESET:
			return c
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

func test_concept_dialog_is_90_percent_of_card_width():
	_panel._show_concept_dialog(-1)
	var dlg := _find_accept_dialog(_panel)
	assert_not_null(dlg, "concept dialog must exist after opening")
	assert_almost_eq(float(dlg.min_size.x), _panel._card.size.x * 0.9, 0.01,
		"concept dialog must be 90 percent of the settings card's own width")

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
	# look (or delete) if the number got large - and a hover needs a target,
	# because the tooltip lookup skips a MOUSE_FILTER_IGNORE control.
	assert_string_contains(label.tooltip_text, "history.db")
	assert_eq(label.mouse_filter, Control.MOUSE_FILTER_STOP,
		"a MOUSE_FILTER_IGNORE label is never a hover target, so the tooltip would never show")

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

## Every label in the panel that carries a tooltip must be reachable by the
## pointer: the viewport's tooltip lookup skips a `MOUSE_FILTER_IGNORE` control,
## so the sentence is unreadable however good it is. The per-row fixes in this
## file are the concrete cases; this is the one assertion a new row cannot get
## past. (`Button`, `OptionButton` and the swatch rows are hover targets by
## construction, and their tooltips are not labels.)
func test_no_tooltip_label_ignores_the_mouse():
	for label in _panel.find_children("*", "Label", true, false):
		var lbl := label as Label
		if lbl == null or lbl.tooltip_text == "":
			continue
		assert_ne(lbl.mouse_filter, Control.MOUSE_FILTER_IGNORE,
			"the '%s' label carries a tooltip ('%s') but ignores the mouse"
			% [lbl.name, lbl.tooltip_text])

func test_format_bytes_scales_through_the_units():
	assert_eq(SettingsPanel.format_bytes(0), "0 B")
	assert_eq(SettingsPanel.format_bytes(999), "999 B")
	assert_eq(SettingsPanel.format_bytes(1024), "1.0 KiB")
	assert_eq(SettingsPanel.format_bytes(1536), "1.5 KiB")
	assert_eq(SettingsPanel.format_bytes(5 * 1024 * 1024), "5.0 MiB")
	assert_eq(SettingsPanel.format_bytes(3 * 1024 * 1024 * 1024), "3.0 GiB")
	assert_eq(SettingsPanel.format_bytes(-1), "unavailable")

# ── The UI scale picker ────────────────────────────────────────────────

func _ui_scale_opt() -> OptionButton:
	for opt in _panel.find_children("*", "OptionButton", true, false):
		if opt.name == "UiScaleOpt":
			return opt
	return null

func test_the_ui_scale_picker_offers_every_preset():
	var opt := _ui_scale_opt()
	assert_not_null(opt, "the Appearance tab carries a UI scale picker")
	assert_eq(opt.item_count, SettingsManager.UI_SCALE_PRESETS.size())
	for i in SettingsManager.UI_SCALE_PRESETS.size():
		assert_eq(opt.get_item_text(i), "%d%%" % SettingsManager.UI_SCALE_PRESETS[i])
	assert_eq(opt.selected, 0, "a fresh install sits at 100 %")

func test_selecting_a_scale_writes_and_saves_it():
	var opt := _ui_scale_opt()
	var idx := SettingsManager.UI_SCALE_PRESETS.find(150)
	opt.item_selected.emit(idx)
	assert_eq(SettingsManager.cfg_ui_scale, 150)
	assert_eq(MockAutoloads.get_store(SettingsManager.SETTINGS_FILE).get("ui_scale"), 150,
		"the picker saves, so the choice survives a restart")
	# Leave the shared autoload at its default for the suites that follow.
	SettingsManager.cfg_ui_scale = 100
	SettingsManager.apply_ui_scale()

func test_a_stored_value_that_is_not_a_preset_is_shown_as_its_own_entry():
	# The FPS picker's documented trap, in the same shape: `find()` returns -1
	# and `selected = -1` would leave the dropdown blank, hiding the value.
	# A second panel is built because the picker's items are fixed at
	# construction.
	SettingsManager.cfg_ui_scale = 133
	var panel := SettingsPanel.new(_ws)
	add_child_autofree(panel)
	await get_tree().process_frame
	var opt: OptionButton = null
	for o in panel.find_children("*", "OptionButton", true, false):
		if o.name == "UiScaleOpt":
			opt = o
			break
	assert_not_null(opt)
	assert_eq(opt.item_count, SettingsManager.UI_SCALE_PRESETS.size() + 1)
	assert_eq(opt.get_item_text(opt.item_count - 1), "133% (custom)")
	assert_eq(opt.selected, opt.item_count - 1, "the stored value is the visible selection")
	SettingsManager.cfg_ui_scale = 100

## The hint is the row's other half: the window can refuse a scale, and a
## picker that shows only the request would hide what is on screen.
func test_the_scale_hint_names_the_scale_the_window_shows():
	assert_eq(SettingsPanel.ui_scale_hint(125, 125), "",
		"no hint when the window shows the request")
	assert_eq(SettingsPanel.ui_scale_hint(125, 100), "shown at 100 %")
	assert_string_contains(SettingsPanel.ui_scale_hint_tooltip(125, 100), "560 x 340")
	assert_eq(SettingsPanel.ui_scale_hint_tooltip(125, 125), "")

func test_the_hint_follows_the_capped_scale():
	_pin_window(Vector2i(560, 340))
	SettingsManager.cfg_ui_scale = 125
	SettingsManager.apply_ui_scale()
	_panel._refresh_ui_scale_hint()
	var hint: Label = _panel.find_child("UiScaleHint", true, false)
	assert_not_null(hint, "the scale row carries the hint label")
	assert_eq(hint.text, "shown at 100 %")
	assert_eq(hint.theme_type_variation, UiTheme.MUTED_LABEL)
	assert_eq(hint.mouse_filter, Control.MOUSE_FILTER_STOP,
		"a MOUSE_FILTER_IGNORE label is never a hover target, so the tooltip would never show")
	# Leave the shared autoload at its default for the suites that follow.
	SettingsManager.cfg_ui_scale = 100
	SettingsManager.apply_ui_scale()

# ── Appearance mode ────────────────────────────────────────────────────

## The picker belongs to the tab whose colours it decides, and it must show the
## stored value rather than a fixed default - the panel reads it when it is
## built, which is what a restart on a stored Light mode looks like.
func test_the_appearance_picker_is_in_the_appearance_tab():
	SettingsManager.cfg_appearance_mode = SettingsManager.APPEARANCE_LIGHT
	SettingsManager.apply_appearance()
	var panel := SettingsPanel.new(_ws)
	add_child_autofree(panel)
	await get_tree().process_frame
	var opt: OptionButton = panel.find_child("AppearanceOpt", true, false)
	assert_not_null(opt, "the Appearance tab must expose the colour mode")
	assert_eq(_tab_of(opt), "Appearance", "the picker lives in the Appearance tab")
	assert_eq(opt.item_count, 3, "Dark, Light, Follow system")
	assert_eq(opt.selected, SettingsManager.APPEARANCE_LIGHT,
		"the picker reflects the stored mode")
	SettingsManager.cfg_appearance_mode = SettingsManager.APPEARANCE_DARK
	SettingsManager.apply_appearance()

func test_picking_light_applies_it():
	watch_signals(SettingsManager)
	var opt: OptionButton = _panel.find_child("AppearanceOpt", true, false)
	opt.item_selected.emit(SettingsManager.APPEARANCE_LIGHT)
	assert_eq(SettingsManager.cfg_appearance_mode, SettingsManager.APPEARANCE_LIGHT)
	assert_signal_emitted(SettingsManager, "appearance_changed")
	assert_eq(UiPalette.active().SURFACE, UiPalette.light().SURFACE,
		"the save resolves the palette the mode chose")
	SettingsManager.cfg_appearance_mode = SettingsManager.APPEARANCE_DARK
	SettingsManager.apply_appearance()

func test_appearance_reset_returns_to_dark():
	SettingsManager.cfg_appearance_mode = SettingsManager.APPEARANCE_LIGHT
	SettingsManager.apply_appearance()
	var btn := _tab_reset_button("Appearance")
	assert_not_null(btn, "the Appearance tab must have a reset")
	btn.pressed.emit()
	assert_eq(SettingsManager.cfg_appearance_mode, SettingsManager.APPEARANCE_DARK)
	assert_eq(UiPalette.active().SURFACE, UiPalette.dark().SURFACE)
	assert_eq(SettingsManager.cfg_wrapper_bg, UiPalette.active().BG,
		"the colour rows reset to the palette the reset just chose")

# ── Commands tab ───────────────────────────────────────────────────────

func _command_list() -> ItemList:
	return _panel.find_child("CommandList", true, false)

func _command_button(role: String) -> Button:
	return _panel._command_actions.get(role)

func _seed_commands() -> void:
	SavedCommandStore.add("Build", "cargo build", false)
	SavedCommandStore.add("Deploy", "make deploy", true)
	_panel._refresh_command_list()

func test_the_commands_tab_sits_before_about():
	var titles := []
	for i in _panel._tabs.get_tab_count():
		titles.append(_panel._tabs.get_tab_title(i))
	assert_eq(titles, ["System", "Terminal", "Appearance", "Reasoning", "Concepts",
		"Commands", "About"], "the shipped tabs keep their positions")

func test_the_commands_tab_lists_the_store_in_order():
	_seed_commands()
	var list := _command_list()
	assert_not_null(list, "the Commands tab carries the list")
	assert_eq(_tab_of(list), "Commands")
	assert_eq(list.item_count, 2)
	assert_eq(list.get_item_text(0), "Build  (Insert)", "a row says how it behaves")
	assert_eq(list.get_item_text(1), "Deploy  (Run)")
	assert_eq(list.get_item_tooltip(0), "cargo build", "the command itself is the tooltip")

func test_the_empty_state_says_how_to_start():
	var list := _command_list()
	assert_false(list.visible, "an empty store hides the list")
	var empty: Label = _panel.find_child("CommandEmpty", true, false)
	assert_true(empty.visible)
	assert_string_contains(empty.text, "Add")

func test_add_stores_the_typed_command_with_run_off():
	_panel._show_command_dialog(-1)
	var dlg := _find_accept_dialog(_panel)
	assert_not_null(dlg, "the form opens")
	var name_le: LineEdit = dlg.find_child("CommandName", true, false)
	var command_le: LineEdit = dlg.find_child("CommandText", true, false)
	var run_cb: CheckBox = dlg.find_child("CommandRun", true, false)
	assert_false(run_cb.button_pressed, "a new command inserts; pressing Enter is opt-in")
	name_le.text = "Build"
	command_le.text = "cargo build"
	dlg.confirmed.emit()
	assert_eq(SavedCommandStore.all(),
		[{"name": "Build", "command": "cargo build", "run": false}])
	assert_eq(_command_list().item_count, 1)
	await wait_frames(1)
	assert_false(is_instance_valid(dlg), "a stored entry closes the form")

## A refusal must not cost the text the user just typed: the dialog is built
## with `dialog_hide_on_ok = false` so only a stored entry closes it.
func test_a_duplicate_name_keeps_the_form_and_the_text():
	_seed_commands()
	_panel._show_command_dialog(-1)
	var dlg := _find_accept_dialog(_panel)
	assert_false(dlg.dialog_hide_on_ok, "a refusal has to be able to keep the dialog")
	var name_le: LineEdit = dlg.find_child("CommandName", true, false)
	name_le.text = "build"
	dlg.confirmed.emit()
	await wait_frames(1)
	assert_true(is_instance_valid(dlg), "the form stays open after a refusal")
	assert_eq(name_le.text, "build", "what the user typed survives")
	assert_eq(SavedCommandStore.all().size(), 2, "the store is unchanged")
	dlg.queue_free()

func test_edit_rewrites_the_selected_entry_in_place():
	_seed_commands()
	_panel._command_list.select(1)
	_panel._edit_selected_command()
	var dlg := _find_accept_dialog(_panel)
	assert_not_null(dlg, "Edit opens the form on the selected entry")
	assert_eq((dlg.find_child("CommandName", true, false) as LineEdit).text, "Deploy",
		"the form starts from the entry")
	(dlg.find_child("CommandText", true, false) as LineEdit).text = "make deploy PROD=1"
	(dlg.find_child("CommandRun", true, false) as CheckBox).button_pressed = false
	dlg.confirmed.emit()
	assert_eq(SavedCommandStore.all()[1],
		{"name": "Deploy", "command": "make deploy PROD=1", "run": false})
	assert_eq(SavedCommandStore.all()[0]["name"], "Build", "the other entry is untouched")

func test_delete_and_reorder_follow_the_store():
	_seed_commands()
	_panel._command_list.select(0)
	_panel._move_selected_command(1)
	assert_eq(SavedCommandStore.all().map(func(e): return e["name"]), ["Deploy", "Build"])
	assert_eq(Array(_panel._command_list.get_selected_items()), [1],
		"the moved row stays selected")
	_panel._delete_selected_command()
	assert_eq(SavedCommandStore.all().map(func(e): return e["name"]), ["Deploy"])

func test_the_row_buttons_follow_the_selection():
	_seed_commands()
	var list := _command_list()
	assert_eq(Array(list.get_selected_items()), [], "a fresh list selects nothing")
	_panel._sync_command_buttons()
	assert_true(_command_button("edit").disabled, "nothing selected, nothing to edit")
	assert_true(_command_button("delete").disabled)
	assert_false(_command_button("add").disabled, "Add works with nothing selected")
	list.select(0)
	_panel._sync_command_buttons()
	assert_false(_command_button("edit").disabled)
	assert_true(_command_button("up").disabled, "the first row cannot move up")
	assert_false(_command_button("down").disabled)
	list.select(1)
	_panel._sync_command_buttons()
	assert_false(_command_button("up").disabled)
	assert_true(_command_button("down").disabled, "the last row cannot move down")

func test_open_commands_lands_on_the_tab_and_can_open_the_form():
	_panel.open_commands()
	assert_true(_panel.visible)
	assert_eq(_panel._tabs.get_tab_title(_panel._tabs.current_tab), "Commands")
	assert_null(_find_accept_dialog(_panel), "no form unless asked for")
	_panel.open_commands(true)
	assert_not_null(_find_accept_dialog(_panel), "add_now opens the form")

## A seventh tab must stay on the bar. The engine does not widen the bar for
## an overflow: it hides trailing tabs behind a dropdown, and then re-lays the
## bar out on the first click, which mangles the card's measured 540 x 560.
func test_all_seven_tabs_fit_the_card():
	_pin_window(Vector2i(1920, 1080))
	SettingsManager.cfg_ui_scale = 100
	SettingsManager.apply_ui_scale()
	_panel.theme = UiTheme.build()
	_panel.open()
	await wait_frames(2)
	var tabs := _panel._tabs
	assert_eq(tabs.get_tab_count(), 7)
	var bar := tabs.get_tab_bar()
	assert_gt(bar.size.x, 0.0, "the bar has been laid out")
	# The rects are read as a running row: a tab the engine has hidden comes
	# back with a zero-based rect (measured: tab 6 read 0..56 on a bar whose
	# tabs ended at 464), so neither a per-tab end check nor a width sum alone
	# proves the row fits - the positions have to be contiguous as well.
	var edge := 0.0
	var total := 0.0
	for i in tabs.get_tab_count():
		var rect := bar.get_tab_rect(i)
		assert_almost_eq(rect.position.x, edge, 0.5,
			"tab %d (%s) starts at %.1f px after the tabs before it end at %.1f: the engine has hidden it or started a new row"
			% [i, tabs.get_tab_title(i), rect.position.x, edge])
		edge = rect.end.x
		total += rect.size.x
	assert_true(total <= bar.size.x,
		"the seven tabs need %.1f px of a %.1f px bar: the overflow would be hidden behind a dropdown"
		% [total, bar.size.x])

# ── About: the keyboard-shortcut table ─────────────────────────────────

## The chord the list prints for one description, read out of the About tab's
## grids: each row is `[chord, description]`.
func _row_chord(description: String) -> String:
	var list := _panel.find_child("ShortcutList", true, false) as VBoxContainer
	if list == null:
		return ""
	for grid in list.find_children("*", "GridContainer", true, false):
		var kids := grid.get_children()
		for i in range(0, kids.size() - 1, 2):
			if (kids[i + 1] as Label).text == description:
				return (kids[i] as Label).text
	return ""

func test_open_about_lands_on_the_about_tab():
	_panel.open_about()
	await wait_frames(2)
	assert_true(_panel.visible, "opening, never toggling")
	assert_eq(_panel._tabs.get_tab_title(_panel._tabs.current_tab), "About",
		"the palette's Keyboard Shortcuts row asks for this tab")

func test_the_shortcut_list_prints_the_registry_spelling():
	_panel.open_about()
	await wait_frames(2)
	# `term:*` is declared by the autoload, so it is bound in a bare panel; the
	# workspace's own app:* rows need a workspace and are covered by
	# `test_discoverability.gd`.
	assert_eq(_row_chord("Copy the selection"), ShortcutManager.chord("term:copy"))
	assert_eq(_row_chord("Copy the selection"), "Ctrl+Shift+C",
		"a literal here would be the drift this table exists to prevent")
	assert_eq(_row_chord("Open the scrollback search bar"), "Ctrl+Shift+F")
	assert_eq(_row_chord("Paste the clipboard"), "Ctrl+Shift+V")

func test_a_second_open_rebuilds_the_list_instead_of_appending():
	_panel.open_about()
	await wait_frames(2)
	var list := _panel.find_child("ShortcutList", true, false) as VBoxContainer
	assert_not_null(list)
	var first := list.get_child_count()
	assert_gt(first, 0, "the declared chords give the list at least one row")
	_panel.open_about()
	await wait_frames(2)
	assert_eq(list.get_child_count(), first,
		"the previous table is freed, not stacked under the new one")

func test_every_group_caption_precedes_its_rows_and_no_heading_is_empty():
	_panel.open_about()
	await wait_frames(2)
	var list := _panel.find_child("ShortcutList", true, false) as VBoxContainer
	# Read as pairs, not against a fixed count: another suite in this process
	# may have registered the workspace's own app:* actions, so which groups
	# appear depends on the run order - the structure does not.
	var expect_caption := true
	for child in list.get_children():
		if expect_caption:
			assert_true(child is Label, "a group starts with its heading")
			assert_ne((child as Label).text, "")
			assert_eq((child as Label).theme_type_variation, UiTheme.MUTED_LABEL,
				"a heading recedes instead of competing with the chords")
		else:
			assert_true(child is GridContainer, "a heading is followed by its rows")
			assert_gt(child.get_child_count(), 0,
				"an unbound group contributes no heading, so no grid is ever empty")
		expect_caption = not expect_caption
	assert_true(expect_caption, "the list ends on a grid, never a dangling heading")
