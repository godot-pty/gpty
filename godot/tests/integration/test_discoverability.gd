extends GutTest
# Integration tests: the v0.8.1 discoverability surfaces, end to end.
#
# Defends: every user-facing chord is read from the binding registry (so the
# sidebar's tooltips and the About table cannot spell a key that does nothing),
# the Add Pane header names the tile under the pointer and offers the shared
# Help table, and the window-mode control says what each mode draws.
#
# These need a real Workspace: the app:* chords are registered by `_ready()`, and
# the defect under test was that the sidebar was built before those
# registrations, so every chord it printed was empty.

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

var _ws: Control

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_show_titlebar = false
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()
	SettingsManager.cfg_window_mode = 0
	_ws = WorkspaceScript.new()
	add_child(_ws)
	_ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame

func after_each():
	# Wait out the deferred concept push timer before freeing, so it cannot
	# resume against a freed workspace.
	await get_tree().create_timer(2.1).timeout
	# Free synchronously while the mocks are still active: `_exit_tree()` would
	# otherwise write the real workspace store after teardown restores it.
	if _ws:
		if _ws.get_parent():
			_ws.get_parent().remove_child(_ws)
		_ws.free()
		_ws = null
	MockAutoloads.teardown()

## A sidebar row button by the start of its tooltip (the icon+text buttons keep
## their words in child labels, so the tooltip is the addressable part).
func _tooltip_button(prefix: String) -> Button:
	for btn in _ws._sidebar.find_children("*", "Button", true, false):
		if str(btn.tooltip_text).begins_with(prefix):
			return btn
	return null

## The chord the About tab prints for one description: each row is
## `[chord, description]` inside a per-group GridContainer.
func _about_chord(list: VBoxContainer, description: String) -> String:
	for grid in list.find_children("*", "GridContainer", true, false):
		var kids := grid.get_children()
		for i in range(0, kids.size() - 1, 2):
			if (kids[i + 1] as Label).text == description:
				return (kids[i] as Label).text
	return ""

# ── Sidebar: chords, heading, Help table ───────────────────────────────

func test_the_sidebar_tooltips_spell_the_registered_chords():
	# The registrations run before `_build_sidebar()`, so these read the binding
	# that fires. Before the reorder every tooltip printed the bare sentence.
	assert_eq(ShortcutManager.chord("term:search"), "Ctrl+Shift+F")
	assert_eq(ShortcutManager.chord("app:reset_workspace"), "Ctrl+Shift+R")

	var search := _tooltip_button("Search the active terminal")
	assert_not_null(search, "the sidebar's Search row exists")
	assert_eq(search.tooltip_text, "Search the active terminal (Ctrl+Shift+F)")

	var reset := _tooltip_button("Close every pane in this workspace")
	assert_not_null(reset, "the sidebar's Close All row exists")
	assert_eq(reset.tooltip_text, "Close every pane in this workspace (Ctrl+Shift+R)")

	var row := _ws._sidebar.find_child("PaneTypeRow", true, false) as GridContainer
	var terminal_tile := row.get_child(0) as Button
	assert_eq(terminal_tile.tooltip_text, "New Terminal (Ctrl+Shift+N)",
		"a tile's tooltip names the spawn chord from the registry")
	assert_eq(terminal_tile.accessibility_name, terminal_tile.tooltip_text)

func test_the_add_pane_help_names_every_glyph_with_its_chord():
	var btn := _ws._sidebar.find_child(SectionHelp.BUTTON_NAME, true, false) as Button
	assert_not_null(btn)
	btn.pressed.emit()
	# The popup is parented to the sidebar's background rect: the sidebar sets
	# `clip_contents`, which would cut a modal in half.
	var table := _ws._sidebar_bg.find_child(SectionHelp.TABLE_NAME, true, false) as GridContainer
	assert_not_null(table, "the press opens the table")
	var kids := table.get_children()
	assert_eq(kids.size(), PaneTypes.ALL.size() * 3, "one row per pane type")
	var chords := {}
	for i in range(0, kids.size(), 3):
		chords[(kids[i + 1] as Label).text] = (kids[i + 2] as Label).text
	assert_eq(str(chords.get("Add a Terminal pane")), "Ctrl+Shift+N")
	assert_eq(str(chords.get("Add a Code Viewer pane")), "Ctrl+Shift+D")
	assert_eq(str(chords.get("Add a Media pane")), "",
		"a type with no spawn chord claims none")

# ── Window mode ────────────────────────────────────────────────────────

func test_the_window_mode_control_says_what_each_mode_draws():
	var dd := _ws._sidebar.find_child("WindowModeDropdown", true, false) as OptionButton
	assert_not_null(dd)
	var labels: Array[String] = []
	for i in dd.item_count:
		labels.append(dd.get_item_text(i))
	var expected: Array[String] = []
	for label in SettingsManager.WINDOW_MODE_LABELS:
		expected.append(str(label))
	assert_eq(labels, expected)
	assert_eq(labels[0], "System Frame",
		"the old first label was 'OS', which named no behaviour")
	assert_eq(dd.accessibility_name, SettingsManager.WINDOW_MODE_TITLE)
	assert_eq(dd.tooltip_text, SettingsManager.WINDOW_MODE_HINT,
		"the hint is the sentence that says what each value draws")

func test_the_settings_panel_mode_dropdown_carries_the_same_name_and_hint():
	_ws._execute_command("shortcuts")
	await get_tree().process_frame
	var panel: SettingsPanel = _ws._settings_panel
	assert_not_null(panel)
	var named: Array = []
	for opt in panel.find_children("*", "OptionButton", true, false):
		if opt.accessibility_name == SettingsManager.WINDOW_MODE_TITLE:
			named.append(opt)
	assert_eq(named.size(), 1,
		"the panel's mode dropdown is named like the sidebar's, once")
	assert_eq((named[0] as OptionButton).tooltip_text, SettingsManager.WINDOW_MODE_HINT)

# ── Settings > About: the list, and the palette row that reaches it ────

func test_the_shortcuts_command_opens_the_about_list_from_the_registry():
	_ws._execute_command("shortcuts")
	await get_tree().process_frame
	var panel: SettingsPanel = _ws._settings_panel
	assert_not_null(panel, "the palette's Keyboard Shortcuts row builds the panel")
	assert_true(panel.visible, "opening, never toggling")
	assert_eq(panel._tabs.get_tab_title(panel._tabs.current_tab), "About")
	var list := panel.find_child("ShortcutList", true, false) as VBoxContainer
	assert_not_null(list)
	# The row that led here, the terminal's own keys, and a spawn chord: three
	# different registration paths, all spelled by the registry.
	assert_eq(_about_chord(list, "Command palette"), "Ctrl+Shift+P")
	assert_eq(_about_chord(list, "Copy the selection"), "Ctrl+Shift+C")
	assert_eq(_about_chord(list, "New Terminal pane"), "Ctrl+Shift+N")
	assert_eq(_about_chord(list, "Toggle fullscreen"), "F11")
