extends GutTest
# Integration tests: Sidebar popup menu and pane type listing.

var _scene: Control
var _sidebar: Sidebar

func before_each():
	MockAutoloads.setup()
	_scene = TestScene.create()
	add_child(_scene)

	# Build a minimal Sidebar (requires a bg ColorRect for parent)
	var bg = ColorRect.new()
	bg.name = "SidebarBg"
	bg.color = Color(0.12, 0.12, 0.15)
	bg.offset_right = 180
	_scene.add_child(bg)

	_sidebar = Sidebar.new()
	_sidebar.name = "Sidebar"
	bg.add_child(_sidebar)
	_sidebar.offset_right = 180
	_sidebar.build(bg)

func after_each():
	MockAutoloads.teardown()
	if _scene:
		for c in _scene.get_children():
			_scene.remove_child(c)
			c.free()
		remove_child(_scene)
		_scene.free()

func test_a_row_label_never_claims_more_width_than_the_panel():
	# The sidebar is a fixed 180 px panel (16 px of margins) whose right edge is
	# covered by the workspace grid, so a row that sizes itself to its text is
	# not wrapped or scrolled — it is cut, and it also drags the centring of the
	# rows above it out of view. Measured before the fix: the catalog hint
	# claimed 220 px and a 52-character profile name 415 px, and the profile row
	# then read "Agent Workspac" (it had fit in the previous release).
	# `clip_text` is the mechanism — it drops the text from the button's minimum
	# width (220 -> 8 px) so the row stays inside the panel and the overrun
	# ellipsizes instead of being sliced.
	# The hint row exists only while no plugin profile is installed, so the
	# list has to be built (empty) before it can be measured.
	_sidebar.update_profile_list([], "")
	var hint = _sidebar.find_child("CatalogHintBtn", true, false)
	assert_not_null(hint, "the catalog hint row must exist")
	assert_lte((hint as Button).get_combined_minimum_size().x, 164.0,
		"the hint row must not claim more width than the panel offers")
	# By identity, not by index: `update_profile_list` frees the previous rows
	# with `queue_free()`, so within one frame the list still holds the row the
	# first call built and index 0 is not the profile row at all.
	var long_name := "a user profile name long enough to stretch the panel"
	var profiles: Array[Dictionary] = [{"name": long_name}]
	_sidebar.update_profile_list(profiles, "")
	var btn: Button = null
	for row in _sidebar._profile_list.get_children():
		var candidate := row.get_child(0) as Button
		if candidate != null and candidate.text == long_name:
			btn = candidate
			break
	assert_not_null(btn, "the profile row must have a label button")
	assert_lte(btn.get_combined_minimum_size().x, 164.0,
		"a user-authored name must ellipsize, not stretch the row")

func test_sidebar_build_succeeds():
	# After build, update_pane_list with empty array should not crash
	_sidebar.update_pane_list([])
	assert_not_null(_sidebar._pane_list, "_pane_list should exist after build")

func test_sidebar_emits_request_new_pane():
	watch_signals(_sidebar)
	_sidebar.request_new_pane.emit("terminal")
	assert_signal_emitted(_sidebar, "request_new_pane")

func test_sidebar_emits_request_settings():
	watch_signals(_sidebar)
	_sidebar.request_settings.emit()
	assert_signal_emitted(_sidebar, "request_settings")

func test_sidebar_emits_request_reset():
	watch_signals(_sidebar)
	_sidebar.request_reset.emit()
	assert_signal_emitted(_sidebar, "request_reset")


func test_update_pane_list_shows_label():
	var mock_body = PaneBody.new()
	mock_body.pane_label = "T1"
	_sidebar.update_pane_list([mock_body])

	var pane_list = _sidebar._pane_list
	assert_not_null(pane_list, "_pane_list should exist after build")
	assert_gt(pane_list.get_child_count(), 0, "update_pane_list should add rows")

	# First row's first button should show the pane label
	var row = pane_list.get_child(0)
	var focus_btn = row.get_child(0)
	assert_true(focus_btn is Button, "first child should be focus Button")
	assert_eq(focus_btn.text, "T1", "focus button should show pane label")

func test_workspace_row_double_click_renames():
	_sidebar.update_workspace_list(["Workspace 1", "Workspace 2"], 0)
	var row = _sidebar._workspace_list.get_child(0)
	var btn: Button = row.get_child(0)

	var ev = InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.double_click = true
	_sidebar._on_workspace_row_input(0, btn, ev)

	# The label button swaps for an inline LineEdit.
	var found_edit := false
	for c in row.get_children():
		if c is LineEdit:
			found_edit = true
			break
	assert_true(found_edit, "double-click must open an inline rename editor")
	assert_true(not btn.visible, "the label button must hide during rename")

	# Submitting emits request_workspace_rename with the index and new name.
	watch_signals(_sidebar)
	var le: LineEdit = null
	for c in row.get_children():
		if c is LineEdit:
			le = c
			break
	le.text = "Renamed"
	le.text_submitted.emit("Renamed")
	assert_signal_emitted_with_parameters(_sidebar, "request_workspace_rename", [0, "Renamed"])

	# A subsequent blur (focus_exited fires again after the list rebuild
	# frees the editor) must NOT corrupt the rebuilt rows — regression for
	# the "rows disappear after Enter" bug.
	le.focus_exited.emit()
	await get_tree().process_frame
	assert_eq(_sidebar._workspace_list.get_child_count(), 2,
		"workspace rows must survive the post-commit blur")

func test_profile_row_double_click_renames():
	var profiles: Array[Dictionary] = [
		{"name": "Mine", "description": "", "_user_index": 0},
	]
	_sidebar.update_profile_list(profiles, "")
	var row = _sidebar._profile_list.get_child(0)
	var btn: Button = row.get_child(0)

	var ev = InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.double_click = true
	btn.gui_input.emit(ev)

	var le: LineEdit = null
	for c in row.get_children():
		if c is LineEdit:
			le = c
			break
	assert_not_null(le, "double-click must open an inline rename editor on user profiles")

	watch_signals(_sidebar)
	le.text = "NewName"
	le.text_submitted.emit("NewName")
	assert_signal_emitted_with_parameters(_sidebar, "request_profile_rename", [0, "NewName"])

func test_update_pane_list_replaces_previous():
	var body1 = PaneBody.new(); body1.pane_label = "T1"
	var body2 = PaneBody.new(); body2.pane_label = "C1"

	_sidebar.update_pane_list([body1, body2])
	var pane_list = _sidebar._pane_list
	assert_gt(pane_list.get_child_count(), 1, "should have multiple rows")

	# Replace with single pane — new label should appear
	_sidebar.update_pane_list([body1])
	var focus_btn = pane_list.get_child(pane_list.get_child_count() - 1).get_child(0)
	assert_eq(focus_btn.text, "T1", "replacement should show updated label")

func test_update_pane_list_accents_active_body():
	var b1 = PaneBody.new(); b1.pane_label = "T1"
	var b2 = PaneBody.new(); b2.pane_label = "T2"
	_sidebar.update_pane_list([b1, b2], b2)

	var rows = _sidebar._pane_list.get_children()
	var btn1: Button = rows[0].get_child(0)
	var btn2: Button = rows[1].get_child(0)
	assert_false(btn1.button_pressed, "inactive pane row must not be pressed")
	assert_true(btn2.button_pressed, "active pane row must be pressed")
	assert_true(btn2.has_theme_color_override("font_color"), "active pane row must carry the accent")
	assert_true(btn2.has_theme_color_override("font_pressed_color"),
		"pressed active row must keep the accent (font_pressed_color falls back to theme otherwise)")
	assert_false(btn1.has_theme_color_override("font_color"), "inactive pane row must not carry the accent")

func test_set_active_pane_moves_accent_without_rebuild():
	var b1 = PaneBody.new(); b1.pane_label = "T1"
	var b2 = PaneBody.new(); b2.pane_label = "T2"
	_sidebar.update_pane_list([b1, b2], b1)
	var rows = _sidebar._pane_list.get_children()

	_sidebar.set_active_pane(b2)
	assert_false((rows[0].get_child(0) as Button).button_pressed)
	assert_true((rows[1].get_child(0) as Button).button_pressed)
	# Same row instances — the accent moved, the list was not rebuilt.
	assert_eq(rows, _sidebar._pane_list.get_children())

func test_update_profile_list_accents_active_profile():
	var profiles: Array[Dictionary] = [
		{"name": "A", "description": ""},
		{"name": "B", "description": "", "builtin": true},
	]
	_sidebar.update_profile_list(profiles, "B")

	var rows = _sidebar._profile_list.get_children()
	assert_false((rows[0].get_child(0) as Button).button_pressed, "unactivated profile must not be pressed")
	assert_true((rows[1].get_child(0) as Button).button_pressed, "active profile row must be pressed")
	assert_true((rows[1].get_child(0) as Button).has_theme_color_override("font_color"),
		"active profile row must carry the accent")
	assert_true((rows[1].get_child(0) as Button).has_theme_color_override("font_pressed_color"),
		"pressed active profile row must keep the accent")

# ── Installed-plugin profiles in the section ───────────────────────────

func _plugin_profile(name := "OMP") -> Dictionary:
	return {
		"name": name, "plugin": true,
		"plugin_id": "godot-pty/gpty-omp", "revision": "a1b2c3d4e5f6",
		"tiles": [{"col": 0, "row": 0, "cspan": 60, "rspan": 60}],
	}

func test_plugin_profile_row_shows_provenance_without_delete():
	var profiles: Array[Dictionary] = [_plugin_profile()]
	_sidebar.update_profile_list(profiles, "")

	assert_eq(_sidebar._profile_list.get_child_count(), 1,
		"the plugin row is the whole section: no catalog hint")
	var row = _sidebar._profile_list.get_child(0)
	var btn := row.get_child(0) as Button
	assert_eq(btn.text, "OMP")
	assert_eq(row.get_child_count(), 1, "a plugin profile has no delete button")
	assert_string_contains(btn.tooltip_text, "Installed from godot-pty/gpty-omp@a1b2c3d4e5f6",
		"the tooltip must name where the profile came from")
	assert_string_contains(btn.tooltip_text, "plugin profiles follow the plugin",
		"the tooltip must say why the row cannot be edited")

func test_plugin_profile_row_does_not_offer_rename():
	var profiles: Array[Dictionary] = [_plugin_profile()]
	_sidebar.update_profile_list(profiles, "")
	var row = _sidebar._profile_list.get_child(0)
	var btn := row.get_child(0) as Button

	var ev = InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.double_click = true
	btn.gui_input.emit(ev)

	for c in row.get_children():
		assert_false(c is LineEdit, "a plugin profile must not open a rename editor")

func test_catalog_hint_row_shows_only_without_plugin_profiles():
	var profiles: Array[Dictionary] = [
		{"name": "Agent Workspace", "builtin": true},
		{"name": "Mine", "description": "", "_user_index": 0},
	]
	_sidebar.update_profile_list(profiles, "")

	assert_eq(_sidebar._profile_list.get_child_count(), 3, "two profiles plus the catalog hint")
	var hint := _sidebar._profile_list.get_child(2).get_child(0) as Button
	# Against the constant, not a literal: this test is about the hint being a
	# row of its own, and pinning the wording made a one-word copy change fail
	# a placement test.
	assert_eq(hint.text, Sidebar.CATALOG_HINT_TEXT)
	assert_eq(_sidebar._profile_list.get_child(2).get_child_count(), 1,
		"the hint is a row of its own, with no delete button")
	# The height cap must still see the hint as a row: the measured section
	# height covers all three rows, so nothing is clipped at the row limit.
	var expected := float(_sidebar._profile_list.get_theme_constant("separation")) * 2.0
	for i in _sidebar._profile_list.get_child_count():
		expected += _sidebar._profile_list.get_child(i).get_combined_minimum_size().y
	var sc = _sidebar._profile_list.get_parent() as ScrollContainer
	assert_almost_eq(float(sc.custom_minimum_size.y), expected, 1.0,
		"the section height must cover every rendered row, the hint included")
