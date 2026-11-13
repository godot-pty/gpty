extends GutTest
# Small windows adapt instead of clipping - the v0.8.3 row of that name.
#
# Three surfaces at the sizes the row names: the panel cards (the Settings card
# at 800x500 and 560x340, the Pane Settings card at 560x340), a pane title (it
# must stop before its own three controls and ellipsize), and the sidebar's
# column (its tail must be reachable by scrolling, not clipped away).

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

var _ws: Control

func before_each():
	MockAutoloads.setup()
	# Panes are spawned for real, so the suite needs the same shell the other
	# pane-spawning suites use (a bare workspace carries no user settings).
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()

func after_each():
	# Free while the mocks are active: `_exit_tree()` saves through them.
	if _ws and is_instance_valid(_ws):
		if _ws.get_parent():
			_ws.get_parent().remove_child(_ws)
		_ws.free()
		_ws = null
	MockAutoloads.teardown()

## A workspace at `size`, laid out once at that size. Sized after `add_child`,
## because `_ready` lays the grid out against the rect it was given.
func _make_workspace(size: Vector2) -> Control:
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = size
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	return ws

## Every edge of `rect` inside `host`, with half a pixel of slack (a centred
## container floors its offset).
func _assert_inside(rect: Rect2, host: Rect2, what: String) -> void:
	assert_gte(rect.position.x, host.position.x - 0.5, "%s: left edge" % what)
	assert_gte(rect.position.y, host.position.y - 0.5, "%s: top edge" % what)
	assert_lte(rect.end.x, host.end.x + 0.5, "%s: right edge" % what)
	assert_lte(rect.end.y, host.end.y + 0.5, "%s: bottom edge" % what)

func _open_settings(ws: Control) -> SettingsPanel:
	var panel: SettingsPanel = ws._ensure_settings_panel()
	panel.open()
	await get_tree().process_frame
	await get_tree().process_frame
	return panel

# ── The Settings card ──────────────────────────────────────────────────

func test_the_settings_card_fits_an_800x500_window():
	var ws = await _make_workspace(Vector2(800, 500))
	var panel := await _open_settings(ws)
	var card := panel._card
	assert_eq(card.size, Vector2(540, 484),
		"the design width, and the window's height less the card edge on each side")
	_assert_inside(card.get_global_rect(), ws.get_global_rect(), "the Settings card")

func test_the_settings_card_fits_a_560x340_window():
	var ws = await _make_workspace(Vector2(560, 340))
	var panel := await _open_settings(ws)
	var card := panel._card
	assert_eq(card.size, Vector2(540, 324),
		"the design width still fits (560 less the card edge on each side is 544); the height clamps")
	_assert_inside(card.get_global_rect(), ws.get_global_rect(), "the Settings card")

func test_the_card_reclamps_while_it_is_open():
	var ws = await _make_workspace(Vector2(1200, 800))
	var panel := await _open_settings(ws)
	assert_eq(panel._card.size, SettingsPanel.CARD_SIZE, "the design size fits")
	ws.size = Vector2(560, 340)
	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(panel._card.size, Vector2(540, 324), "a resize while open re-clamps the card")

# ── The Pane Settings card ────────────────────────────────────────────

func test_the_pane_settings_card_fits_a_560x340_window():
	var ws = await _make_workspace(Vector2(560, 340))
	assert_eq(ws._tm.tiles.size(), 1, "a first run restores one terminal")
	var body: Control = ws._tm._find_body(ws._tm.tiles[0].wrapper)
	ws._tm._open_pane_settings(body)
	await get_tree().process_frame
	await get_tree().process_frame
	var card := ws._tm._pane_settings_panel.find_child("Card", true, false) as Control
	assert_not_null(card, "the pane settings card exists")
	if card == null:
		return
	assert_eq(card.size, Vector2(380, 324), "the design width, the window's height less the edge")
	_assert_inside(card.get_global_rect(), ws.get_global_rect(), "the Pane Settings card")

# ── The pane title ────────────────────────────────────────────────────

func test_a_pane_title_stops_before_its_buttons():
	var ws = await _make_workspace(Vector2(560, 340))
	var wrapper: Control = ws._tm.tiles[0].wrapper
	var long_title := "a pane name long enough to overrun the tile and then keep going past it"
	TerminalManager.set_title_label(wrapper, long_title)
	await get_tree().process_frame
	await get_tree().process_frame
	var lbl := wrapper.get_node("BodyVBox/TitleBar/TitleLabel") as Label
	var row := wrapper.get_node("BodyVBox/TitleBar/TitleBarButtons") as Control
	assert_not_null(lbl, "the tile carries a title label")
	assert_not_null(row, "the tile carries its three controls")
	if lbl == null or row == null:
		return
	# The premise, measured from the font: `clip_text` drops the text from the
	# label's own minimum, so the label's minimum proves nothing.
	var font := lbl.get_theme_font("font")
	var font_px := int(lbl.get_theme_font_size("font_size"))
	var text_w := font.get_string_size(long_title, HORIZONTAL_ALIGNMENT_LEFT, -1, font_px).x
	assert_gt(text_w, lbl.size.x,
		"the premise: the title is %.0f px in a %.0f px label" % [text_w, lbl.size.x])
	assert_lte(lbl.get_global_rect().end.x, row.get_global_rect().position.x + 0.5,
		"the title never draws under its own buttons")
	assert_eq(lbl.text_overrun_behavior, TextServer.OVERRUN_TRIM_ELLIPSIS,
		"the overflow ellipsizes instead of being sliced")
	assert_eq(lbl.mouse_filter, Control.MOUSE_FILTER_STOP,
		"the full title is readable on hover, which needs a hover target")
	assert_eq(lbl.tooltip_text, long_title, "the tooltip carries the whole title")

func test_a_short_title_keeps_its_leading_space():
	var ws = await _make_workspace(Vector2(1200, 800))
	var wrapper: Control = ws._tm.tiles[0].wrapper
	TerminalManager.set_title_label(wrapper, "build")
	var lbl := wrapper.get_node("BodyVBox/TitleBar/TitleLabel") as Label
	assert_eq(lbl.text, " build", "the centred label keeps its edge inset")
	assert_eq(lbl.tooltip_text, "build", "the tooltip carries the title, not the padding")

# ── The sidebar column ────────────────────────────────────────────────

func test_the_sidebar_scrolls_as_one_column():
	var ws = await _make_workspace(Vector2(560, 340))
	var sc: ScrollContainer = ws._sidebar._content_scroll
	assert_not_null(sc, "the sidebar's content lives in one scroll container")
	if sc == null:
		return
	var bar := sc.get_v_scroll_bar()
	assert_gt(bar.max_value, bar.page,
		"the column's stack is taller than a 340 px window (%.0f px of content in %.0f px)"
		% [bar.max_value, bar.page])
	sc.scroll_vertical = int(bar.max_value)
	await get_tree().process_frame
	await get_tree().process_frame
	var list: VBoxContainer = ws._sidebar._pane_list
	assert_gt(list.get_child_count(), 0, "the pane list has a row to reach")
	var last := list.get_child(list.get_child_count() - 1) as Control
	assert_lte(last.get_global_rect().end.y, ws._sidebar.get_global_rect().end.y + 0.5,
		"scrolling the column brings the last pane row inside the sidebar")

func test_a_tall_window_keeps_the_pane_list_filling_the_sidebar():
	var ws = await _make_workspace(Vector2(1200, 800))
	var sc: ScrollContainer = ws._sidebar._content_scroll
	var bar := sc.get_v_scroll_bar()
	assert_lte(bar.max_value, bar.page,
		"the whole column fits an 800 px window: nothing to scroll")
	# The pane list still takes the height the sections above it leave over:
	# the outer scroll must not turn it into a fixed-height strip.
	var pane_scroll: Control = ws._sidebar._pane_list.get_parent()
	assert_gt(pane_scroll.size.y, ws._sidebar._pane_list.get_combined_minimum_size().y,
		"the pane list is taller than its own minimum on a tall window")
