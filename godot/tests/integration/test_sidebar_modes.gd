extends GutTest
# The sidebar's three positions (expanded / icons / collapsed), the icons rail
# and the one section flyout. A real workspace gives the mode switch the grid
# layout it must not disturb and the live sections the flyout reparents.

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

var _ws: Control

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()
	SettingsManager.cfg_sidebar_mode = SettingsManager.SIDEBAR_EXPANDED
	SettingsManager.cfg_effect = UiEffects.DEFAULT_AMBIENT
	SettingsManager.cfg_effect_intensity = UiEffects.OFF
	SettingsManager.cfg_effect_scope = UiEffects.SCOPE_PANES
	await _make_workspace()

func after_each():
	if _ws and is_instance_valid(_ws):
		if _ws.get_parent():
			_ws.get_parent().remove_child(_ws)
		_ws.free()
		_ws = null
	SettingsManager.cfg_sidebar_mode = SettingsManager.SIDEBAR_EXPANDED
	MockAutoloads.teardown()

func _make_workspace(size := Vector2(1200, 800)) -> void:
	_ws = WorkspaceScript.new()
	add_child(_ws)
	_ws.size = size
	await wait_frames(3)

func _sidebar() -> Sidebar:
	return _ws._sidebar

func _inside(rect: Rect2, host: Rect2, what: String) -> void:
	assert_gte(rect.position.x, host.position.x - 0.5, "%s: left edge" % what)
	assert_gte(rect.position.y, host.position.y - 0.5, "%s: top edge" % what)
	assert_lte(rect.end.x, host.end.x + 0.5, "%s: right edge" % what)
	assert_lte(rect.end.y, host.end.y + 0.5, "%s: bottom edge" % what)

# ── Positions ──────────────────────────────────────────────────────────

func test_the_three_modes_set_the_widths():
	_sidebar().set_mode(SettingsManager.SIDEBAR_EXPANDED)
	await wait_frames(1)
	assert_almost_eq(_sidebar().offset_right, float(Sidebar.WIDTH), 0.5)
	assert_almost_eq(_ws._sidebar_bg.size.x, float(Sidebar.WIDTH), 0.5)
	assert_almost_eq(_ws._grid.offset_left, float(Sidebar.WIDTH), 0.5)

	_sidebar().set_mode(SettingsManager.SIDEBAR_ICONS)
	await wait_frames(1)
	assert_almost_eq(_sidebar().offset_right, float(Sidebar.ICONS_WIDTH), 0.5)
	assert_almost_eq(_ws._sidebar_bg.size.x, float(Sidebar.ICONS_WIDTH), 0.5)
	assert_almost_eq(_ws._grid.offset_left, float(Sidebar.ICONS_WIDTH), 0.5)

	_sidebar().set_mode(SettingsManager.SIDEBAR_COLLAPSED)
	await wait_frames(1)
	assert_almost_eq(_sidebar().offset_right, float(Sidebar.COLLAPSED_WIDTH), 0.5)
	assert_almost_eq(_ws._sidebar_bg.size.x, float(Sidebar.COLLAPSED_WIDTH), 0.5)
	assert_almost_eq(_ws._grid.offset_left, float(Sidebar.COLLAPSED_WIDTH), 0.5)

func test_a_mode_change_fades_the_shell():
	SettingsManager.cfg_motion = UiMotion.SUBTLE
	_ws._cycle_sidebar_mode()
	assert_eq(_sidebar().mode(), SettingsManager.SIDEBAR_ICONS)
	assert_almost_eq(_ws._grid.offset_left, float(Sidebar.ICONS_WIDTH), 0.5,
		"the width and the grid's reflow are written in the same call")
	assert_lt(_ws._sidebar_bg.modulate.a, 1.0, "the shell fades in over the reflow")
	await wait_seconds(0.2)
	assert_almost_eq(_ws._sidebar_bg.modulate.a, 1.0, 0.001)
	SettingsManager.cfg_motion = UiMotion.OFF
	_ws._cycle_sidebar_mode()
	assert_eq(_ws._sidebar_bg.modulate.a, 1.0, "Off draws the shell final")
	SettingsManager.cfg_motion = UiMotion.SUBTLE

func test_ctrl_shift_b_cycles_the_modes_and_persists():
	assert_eq(ShortcutManager.chord("app:toggle_sidebar"), "Ctrl+Shift+B")
	_ws._cycle_sidebar_mode()
	assert_eq(SettingsManager.cfg_sidebar_mode, SettingsManager.SIDEBAR_ICONS)
	assert_eq(_sidebar().mode(), SettingsManager.SIDEBAR_ICONS)
	_ws._cycle_sidebar_mode()
	assert_eq(SettingsManager.cfg_sidebar_mode, SettingsManager.SIDEBAR_COLLAPSED)
	_ws._cycle_sidebar_mode()
	assert_eq(SettingsManager.cfg_sidebar_mode, SettingsManager.SIDEBAR_EXPANDED)
	assert_eq(_sidebar().mode(), SettingsManager.SIDEBAR_EXPANDED)
	var stored: Dictionary = MockAutoloads.get_store(SettingsManager.SETTINGS_FILE)
	assert_eq(int(stored.get("sidebar_mode", -1)), SettingsManager.SIDEBAR_EXPANDED,
		"the cycle writes the store")

func test_the_header_control_and_the_collapsed_handle_move_between_modes():
	var header := _sidebar().find_child("SidebarHeaderModeBtn", true, false) as Button
	assert_not_null(header, "the expanded header carries the mode control")
	_sidebar().set_mode(SettingsManager.SIDEBAR_EXPANDED)
	await wait_frames(1)
	if header != null:
		assert_true(header.is_visible_in_tree(), "the header control is the expanded mode's")
	assert_true(_sidebar()._content_margin.visible)
	assert_false(_sidebar()._icon_rail.visible)
	assert_false(_sidebar()._collapsed_btn.visible)

	_sidebar().set_mode(SettingsManager.SIDEBAR_ICONS)
	await wait_frames(1)
	if header != null:
		assert_false(header.is_visible_in_tree(), "the content margin takes the header with it")
	assert_false(_sidebar()._content_margin.visible)
	assert_true(_sidebar()._icon_rail.visible)
	assert_false(_sidebar()._collapsed_btn.visible)

	_sidebar().set_mode(SettingsManager.SIDEBAR_COLLAPSED)
	await wait_frames(1)
	assert_false(_sidebar()._content_margin.visible)
	assert_false(_sidebar()._icon_rail.visible)
	assert_true(_sidebar()._collapsed_btn.visible)
	_sidebar()._collapsed_btn.pressed.emit()
	await wait_frames(1)
	assert_eq(_sidebar().mode(), SettingsManager.SIDEBAR_EXPANDED,
		"the collapsed handle restores the expanded column")

func test_the_expanded_and_collapsed_modes_keep_the_existing_layout():
	_sidebar().set_mode(SettingsManager.SIDEBAR_EXPANDED)
	await wait_frames(1)
	assert_true(_sidebar()._content_scroll.is_visible_in_tree())
	assert_true(_sidebar().find_child("WorkspaceSection", true, false).is_visible_in_tree())
	_sidebar().set_mode(SettingsManager.SIDEBAR_COLLAPSED)
	await wait_frames(1)
	assert_false(_sidebar()._content_scroll.is_visible_in_tree())
	assert_true(_sidebar()._collapsed_btn.visible)

func test_the_mode_survives_a_second_build():
	SettingsManager.set_sidebar_mode(SettingsManager.SIDEBAR_ICONS)
	if _ws != null:
		if _ws.get_parent():
			_ws.get_parent().remove_child(_ws)
		_ws.free()
		_ws = null
	await _make_workspace()
	assert_eq(_sidebar().mode(), SettingsManager.SIDEBAR_ICONS,
		"a second workspace builds the stored position")
	assert_almost_eq(_sidebar().offset_right, float(Sidebar.ICONS_WIDTH), 0.5)
	assert_true(_sidebar()._icon_rail.visible)

# ── Icons rail and flyout ──────────────────────────────────────────────

func test_the_icon_rail_offers_every_action():
	_sidebar().set_mode(SettingsManager.SIDEBAR_ICONS)
	await wait_frames(1)
	for name in ["SidebarRailModeBtn", "WindowModeBtn", "AddPaneBtn", "SearchBtn",
			"SettingsBtn", "FeedbackBtn", "WorkspacesBtn", "ProfilesBtn", "PanesBtn"]:
		var btn := _sidebar().find_child(name, true, false) as Button
		assert_not_null(btn, "the icons rail carries %s" % name)
		if btn != null:
			assert_false(btn.accessibility_name.is_empty(), "%s has an accessible name" % name)
			assert_false(btn.tooltip_text.is_empty(), "%s has a tooltip" % name)

func test_an_icon_opens_the_matching_flyout():
	_sidebar().set_mode(SettingsManager.SIDEBAR_ICONS)
	await wait_frames(1)
	_sidebar().rail_button("workspaces").pressed.emit()
	await wait_frames(2)
	assert_not_null(_ws._sidebar_flyout)
	if _ws._sidebar_flyout == null:
		return
	assert_true(_ws._sidebar_flyout.visible, "the Workspaces icon opens its flyout")
	assert_eq(_ws._flyout_section, "workspaces")
	assert_eq(_sidebar().section_node("workspaces").get_parent(),
		_ws._sidebar_flyout._body, "the live section is reparented, not copied")
	assert_true(_ws._sidebar_flyout._card.size.x > 0.0)

	_sidebar().rail_button("panes").pressed.emit()
	await wait_frames(2)
	assert_eq(_ws._flyout_section, "panes")
	assert_eq(_sidebar().section_node("panes").get_parent(), _ws._sidebar_flyout._body)
	assert_true(_sidebar().is_ancestor_of(_sidebar().section_node("workspaces")),
		"the previous section went back to the column")

	_sidebar().rail_button("add_pane").pressed.emit()
	await wait_frames(2)
	assert_eq(_ws._flyout_section, "add_pane")
	assert_eq(_sidebar().section_node("add_pane").get_parent(), _ws._sidebar_flyout._body)
	_ws._close_sidebar_flyout()

func test_a_selection_closes_the_flyout():
	_sidebar().set_mode(SettingsManager.SIDEBAR_ICONS)
	await wait_frames(1)
	_ws._open_sidebar_flyout("workspaces")
	await wait_frames(2)
	var list := _sidebar()._workspace_list
	assert_gt(list.get_child_count(), 0, "the workspace list is live")
	var row := list.get_child(0) as HBoxContainer
	assert_not_null(row)
	if row == null:
		return
	var choose := row.get_child(0) as Button
	assert_not_null(choose)
	if choose == null:
		return
	choose.pressed.emit()
	await wait_frames(2)
	assert_false(_ws._sidebar_flyout.visible, "choosing a workspace closes the flyout")
	assert_eq(_ws._flyout_section, "")
	assert_true(_sidebar().is_ancestor_of(_sidebar().section_node("workspaces")),
		"the section is back in the column")

func test_click_outside_and_escape_close_the_flyout():
	_sidebar().set_mode(SettingsManager.SIDEBAR_ICONS)
	await wait_frames(1)
	_ws._open_sidebar_flyout("panes")
	await wait_frames(2)
	var click := InputEventMouseButton.new()
	click.pressed = true
	click.button_index = MOUSE_BUTTON_LEFT
	_ws._sidebar_flyout._on_catcher_input(click)
	await wait_frames(2)
	assert_false(_ws._sidebar_flyout.visible, "a click outside closes the flyout")

	_ws._open_sidebar_flyout("panes")
	await wait_frames(2)
	assert_true(_ws._sidebar_flyout.visible)
	var esc := InputEventKey.new()
	esc.pressed = true
	esc.keycode = KEY_ESCAPE
	_ws._input(esc)
	await wait_frames(2)
	assert_false(_ws._sidebar_flyout.visible, "Escape closes the flyout")

func test_the_grid_rect_is_unchanged_while_the_flyout_is_open():
	_sidebar().set_mode(SettingsManager.SIDEBAR_ICONS)
	await wait_frames(1)
	var grid_before: Rect2 = _ws._grid.get_global_rect()
	var wrappers_before: Array[Rect2] = []
	for tile in _ws._tm.tiles:
		wrappers_before.append(tile.wrapper.get_global_rect())
	_ws._open_sidebar_flyout("panes")
	await wait_frames(2)
	assert_eq(_ws._grid.get_global_rect(), grid_before, "the overlay never reflows the grid")
	for i in _ws._tm.tiles.size():
		assert_eq(_ws._tm.tiles[i].wrapper.get_global_rect(), wrappers_before[i],
			"the tile rects are untouched")
	_ws._close_sidebar_flyout()

func test_the_pane_list_updates_while_the_flyout_is_open():
	_sidebar().set_mode(SettingsManager.SIDEBAR_ICONS)
	await wait_frames(1)
	_ws._open_sidebar_flyout("panes")
	await wait_frames(2)
	var before := _sidebar()._pane_list.get_child_count()
	_ws._spawn_pane_into(_ws._active_workspace(), "terminal", {}, false)
	await wait_frames(3)
	_ws._list()
	await wait_frames(1)
	assert_gt(_sidebar()._pane_list.get_child_count(), before,
		"the live pane list grows inside the open flyout")
	_ws._close_sidebar_flyout()

func test_the_flyout_clamps_at_the_560x340_floor():
	_ws.size = Vector2(560, 340)
	await wait_frames(3)
	_sidebar().set_mode(SettingsManager.SIDEBAR_ICONS)
	await wait_frames(2)
	_ws._open_sidebar_flyout("panes")
	await wait_frames(3)
	assert_not_null(_ws._sidebar_flyout)
	if _ws._sidebar_flyout == null:
		return
	var card: Panel = _ws._sidebar_flyout._card
	assert_lte(card.size.x, 320.0, "the card never grows past its design width")
	assert_gt(card.size.y, 0.0)
	_inside(card.get_global_rect(), _ws.get_global_rect(), "the flyout card")
	_ws._close_sidebar_flyout()

func test_the_flyout_card_is_at_most_320_wide_and_adds_no_clock():
	_sidebar().set_mode(SettingsManager.SIDEBAR_ICONS)
	await wait_frames(1)
	_ws._open_sidebar_flyout("panes")
	await wait_frames(2)
	assert_not_null(_ws._sidebar_flyout)
	if _ws._sidebar_flyout == null:
		return
	var card: Panel = _ws._sidebar_flyout._card
	assert_almost_eq(card.size.x, 320.0, 0.5)
	assert_gt(card.size.y, 0.0)
	print("sidebar flyout card: %s" % card.size)
	assert_false(_ws._sidebar_flyout.is_processing(),
		"the flyout is a one-time paint, not a per-frame surface")
	_ws._close_sidebar_flyout()

# ── The ambient effect on the sidebar ─────────────────────────────────

func _apply_effect(scope: int, intensity := UiEffects.FULL, id := "crt") -> void:
	SettingsManager.cfg_effect = id
	SettingsManager.cfg_effect_intensity = intensity
	SettingsManager.cfg_effect_scope = scope
	_ws._on_settings_changed()
	await wait_frames(1)

func test_the_sidebar_host_follows_the_scope():
	await _apply_effect(UiEffects.SCOPE_PANES)
	assert_false(_ws._sidebar_effects.visible, "panes-only leaves the sidebar plain")
	await _apply_effect(UiEffects.SCOPE_BOTH)
	assert_true(_ws._sidebar_effects.visible)
	assert_true(_ws._sidebar_effects.wants_backdrop())
	var body = _ws._tm.last_body
	assert_not_null(body, "the restored pane exists")
	if body != null:
		assert_eq(body.effect, "crt", "both paints the panes too")
	await _apply_effect(UiEffects.SCOPE_SIDEBAR)
	assert_true(_ws._sidebar_effects.visible)
	if body != null:
		assert_eq(int(body.effect_intensity), UiEffects.OFF,
			"sidebar-only broadcasts Off to the panes")
		assert_eq(str(body.effect), "crt", "the selected id survives the gate")
		assert_true(body._effects == null or not body._effects.wants_backdrop(),
			"the pane layer is freed")

func test_off_frees_both_layers():
	await _apply_effect(UiEffects.SCOPE_BOTH, UiEffects.OFF)
	assert_false(_ws._sidebar_effects.wants_backdrop(), "Off frees the sidebar layer")
	var body = _ws._tm.last_body
	if body != null:
		assert_true(body._effects == null or not body._effects.wants_backdrop(),
			"Off frees the pane layer too")

func test_the_sidebar_host_hides_in_collapsed_and_icons_keeps_it():
	await _apply_effect(UiEffects.SCOPE_BOTH)
	_sidebar().set_mode(SettingsManager.SIDEBAR_ICONS)
	await wait_frames(1)
	assert_true(_ws._sidebar_effects.visible, "the icons rail carries the effect")
	_sidebar().set_mode(SettingsManager.SIDEBAR_COLLAPSED)
	await wait_frames(1)
	assert_false(_ws._sidebar_effects.visible, "the 20 px handle draws no effect")
	_sidebar().set_mode(SettingsManager.SIDEBAR_EXPANDED)
	await wait_frames(1)
	assert_true(_ws._sidebar_effects.visible)

func test_the_sidebar_ground_follows_the_chrome_colour():
	var ground := Color(0.12, 0.2, 0.3)
	SettingsManager.cfg_sidebar_bg = ground
	_ws._apply_ui_colors()
	await wait_frames(1)
	assert_eq(_ws._sidebar_bg.color, ground)
	var pane: Node = _ws._sidebar_effects.get_node_or_null("PaneEffects")
	assert_not_null(pane)
	if pane != null:
		assert_eq(pane.get("_ground"), ground, "the effect quad paints the chrome ground")

func test_a_static_sidebar_effect_needs_no_clock():
	await _apply_effect(UiEffects.SCOPE_BOTH, UiEffects.FULL, "crt")
	assert_false(_ws._sidebar_effects.uses_buffer(), "crt is the static path")
	assert_null(_ws._sidebar_effects.find_child("EffectClock", true, false),
		"a static effect owns no clock")
	await _apply_effect(UiEffects.SCOPE_BOTH, UiEffects.FULL, "grain")
	assert_true(_ws._sidebar_effects.uses_buffer(), "grain is the 30 Hz buffer path")
	assert_not_null(_ws._sidebar_effects.find_child("EffectClock", true, false))

func test_the_effect_is_below_the_rows():
	var host_index: int = _ws._sidebar_effects.get_index()
	var sidebar_index := _sidebar().get_index()
	assert_eq(host_index, 0, "the effect host is the background's first child")
	assert_gt(sidebar_index, host_index, "the rows draw above the effect")
	assert_eq(_ws._sidebar_bg.color.a, 1.0, "the ground stays opaque")

func test_the_sidebar_effect_leaves_the_text_contrast_unchanged():
	var graded := false
	for pair in UiPalette.CONTRAST_PAIRS:
		if str(pair[0]) == "TEXT" and str(pair[1]) == "SIDEBAR":
			graded = true
			break
	assert_true(graded, "the sidebar text/surface pair is in the graded table")
	var search: Button = null
	for label in _sidebar().find_children("*", "Label", true, false):
		if (label as Label).text != "Search":
			continue
		var row := label.get_parent()
		if row != null:
			search = row.get_parent() as Button
		break
	assert_not_null(search, "the expanded column has its Search row")
	if search != null:
		var box := (search as Button).get_theme_stylebox("normal") as StyleBoxFlat
		assert_not_null(box)
		if box != null:
			assert_eq(box.bg_color.a, 1.0,
				"the row surface stays opaque, so the effect never tints text")
