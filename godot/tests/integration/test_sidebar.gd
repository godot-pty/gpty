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
	# The hint row is always built, so an empty list is enough to measure it.
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

## The footer buttons are a `Button` holding an icon Label and a text Label;
## find one by its text.
func _icon_text_button(label: String) -> Button:
	for b in _sidebar.find_children("*", "Button", true, false):
		var row = b.get_node_or_null("IconTextRow")
		if row == null:
			continue
		for l in row.get_children():
			if l is Label and l.text == label:
				return b
	return null

func test_build_offers_one_add_button_per_pane_type():
	var row = _sidebar.find_child("PaneTypeRow", true, false)
	assert_not_null(row, "the Add Pane row must exist after build")
	assert_eq(row.get_child_count(), PaneTypes.ALL.size(),
		"one button per registered pane type")
	assert_lte(row.get_combined_minimum_size().x, 164.0,
		"the pane buttons must fit the sidebar's content width (eight in one row clipped the last icon)")
	for i in PaneTypes.ALL.size():
		var info: Dictionary = PaneTypes.ALL[PaneTypes.ALL.keys()[i]]
		assert_string_contains((row.get_child(i) as Button).tooltip_text, info["name"],
			"button %d must be labelled for its pane type" % i)
	_sidebar.update_pane_list([])
	assert_eq(_sidebar._pane_list.get_child_count(), 0, "no panes, no rows")

## These press the real buttons. They used to call `signal.emit()` themselves
## and assert it was emitted, which proves Godot emits signals and nothing
## about whether a button is wired to one.
func test_each_add_pane_button_requests_its_own_pane_type():
	var row = _sidebar.find_child("PaneTypeRow", true, false)
	var keys := PaneTypes.ALL.keys()
	watch_signals(_sidebar)
	for i in keys.size():
		(row.get_child(i) as Button).pressed.emit()
		assert_eq(get_signal_emit_count(_sidebar, "request_new_pane"), i + 1,
			"pressing button %d emits exactly one request" % i)
		assert_eq(get_signal_parameters(_sidebar, "request_new_pane"), [keys[i]],
			"button %d asks for %s, not a neighbour's type" % [i, keys[i]])

func test_the_settings_button_requests_settings_and_nothing_else():
	var btn := _icon_text_button("Settings")
	assert_not_null(btn, "the Settings button must exist")
	watch_signals(_sidebar)
	btn.pressed.emit()
	assert_signal_emit_count(_sidebar, "request_settings", 1)
	assert_signal_not_emitted(_sidebar, "request_reset")

func test_the_close_all_panes_button_requests_reset_and_nothing_else():
	var btn := _icon_text_button("Close all panes")
	assert_not_null(btn, "the Close all panes button must exist")
	# UX-02: the bulk close used the same counter-clockwise-arrow glyph as
	# "change pane type" and pane defaults, so the destructive action looked
	# like a refresh. It must keep its own icon.
	var row := btn.get_node_or_null("IconTextRow")
	assert_not_null(row)
	assert_eq((row.get_child(0) as Label).text, Icons.DELETE,
		"the bulk close must not reuse the pane-type swap glyph")
	watch_signals(_sidebar)
	btn.pressed.emit()
	assert_signal_emit_count(_sidebar, "request_reset", 1)
	assert_signal_not_emitted(_sidebar, "request_settings")

func test_a_pane_rows_buttons_each_act_on_that_pane():
	var body = autofree(PaneBody.new())
	body.pane_label = "T1"
	_sidebar.update_pane_list([body])
	var row = _sidebar._pane_list.get_child(0)
	var actions := [
		"request_focus", "request_minimize", "request_position_swap",
		"request_type_swap", "request_pane_settings", "request_close",
	]
	assert_eq(row.get_child_count(), actions.size(), "a row is label + six actions")
	watch_signals(_sidebar)
	for i in actions.size():
		(row.get_child(i) as Button).pressed.emit()
		assert_eq(get_signal_emit_count(_sidebar, actions[i]), 1,
			"button %d must emit %s" % [i, actions[i]])
		assert_eq(get_signal_parameters(_sidebar, actions[i])[0], body,
			"%s must carry this row's pane" % actions[i])
		var total := 0
		for a in actions:
			total += get_signal_emit_count(_sidebar, a)
		assert_eq(total, i + 1, "button %d must not also fire another action" % i)


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

func test_workspace_cog_emits_cwd_request():
	_sidebar.update_workspace_list(["Repo"], 0, ["/tmp/repo"])
	var row = _sidebar._workspace_list.get_child(0)
	var cog: Button = row.get_node_or_null("WorkspaceCwdBtn")
	assert_not_null(cog, "each workspace row carries a settings cog")
	assert_string_contains(cog.tooltip_text, "/tmp/repo",
		"the cog names the workspace's current directory")
	watch_signals(_sidebar)
	cog.pressed.emit()
	assert_signal_emitted_with_parameters(_sidebar, "request_workspace_cwd", [0])

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
	var body1 = autofree(PaneBody.new()); body1.pane_label = "T1"
	var body2 = autofree(PaneBody.new()); body2.pane_label = "C1"

	_sidebar.update_pane_list([body1, body2])
	var pane_list = _sidebar._pane_list
	assert_eq(pane_list.get_child_count(), 2, "one row per pane")

	# The old rows are `queue_free()`d, so they are still children until the
	# frame ends: the replacement has to be judged after it, or "the old rows
	# were never cleared" and "they were" read the same.
	_sidebar.update_pane_list([body1])
	await get_tree().process_frame
	assert_eq(pane_list.get_child_count(), 1, "the previous rows are gone")
	var labels := []
	for row in pane_list.get_children():
		labels.append((row.get_child(0) as Button).text)
	assert_eq(labels, ["T1"], "only the replacement's pane is listed — no stale 'C1'")

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

	assert_eq(_sidebar._profile_list.get_child_count(), 2,
		"the plugin row plus the catalog hint")
	var row = _sidebar._profile_list.get_child(0)
	var btn := row.get_child(0) as Button
	assert_eq(btn.text, "OMP")
	assert_eq(row.get_child_count(), 1, "a plugin profile has no delete button")
	assert_eq((_sidebar._profile_list.get_child(1).get_child(0) as Button).name,
		"CatalogHintBtn", "the catalog hint must stay the last row")
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

func test_catalog_hint_row_is_last_with_and_without_plugin_profiles():
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

	# With an installed plugin profile the hint must NOT disappear (the
	# reported bug): the plugin row comes first and the catalog row stays last.
	_sidebar.update_profile_list([_plugin_profile()], "")
	await get_tree().process_frame  # the previous rows are queue_free()d
	assert_eq(_sidebar._profile_list.get_child_count(), 2,
		"the plugin profile plus the catalog hint")
	assert_eq(_sidebar._profile_list.get_child(0).get_child(0).text, "OMP")
	assert_eq(_sidebar._profile_list.get_child(1).get_child(0).name,
		"CatalogHintBtn", "the catalog hint must be the last row")
