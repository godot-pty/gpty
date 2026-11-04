extends GutTest
# Pane chrome from the keyboard — the v0.8.0 finding "The keyboard cannot drive
# pane chrome or the Wiki pane".
#
# Every title-bar button used to be `FOCUS_NONE`, so pane settings, change type,
# swap and minimize had no key path at all (close had Ctrl+Shift+W). The fix has
# two halves and both are pinned here: the row is an explicit ring of tab stops,
# and `Ctrl+Shift+E` moves the keyboard from the active pane into its bar
# (a focused terminal consumes Tab for its child, so the ring alone is
# unreachable). Escape hands the keyboard back to the pane, and an action that
# leaves the pane on screen does too — a click focuses the clicked button, and a
# focused button would swallow the next keystroke.

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

var _ws: Control
var _vault: String

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()

func after_each():
	if _vault != "":
		var dir := DirAccess.open(_vault)
		if dir:
			for f in dir.get_files():
				DirAccess.remove_absolute(_vault.path_join(f))
		DirAccess.remove_absolute(_vault)
		_vault = ""
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
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame
	return ws

## The title bar of the tile that holds `body`.
func _bar(ws: Control, body: Control) -> Control:
	var tm: TerminalManager = ws._tm
	for t in tm.tiles:
		if tm._find_body(t.wrapper) == body:
			return t.wrapper.get_node("BodyVBox/TitleBar")
	return null

func _press_key(keycode: Key, ctrl := false, shift := false) -> void:
	var down := InputEventKey.new()
	down.keycode = keycode
	down.physical_keycode = keycode
	down.ctrl_pressed = ctrl
	down.shift_pressed = shift
	down.pressed = true
	Input.parse_input_event(down)
	Input.flush_buffered_events()
	await get_tree().process_frame
	var up: InputEventKey = down.duplicate()
	up.pressed = false
	Input.parse_input_event(up)
	Input.flush_buffered_events()
	await get_tree().process_frame

func _is_inside(outer: Control, node: Control) -> bool:
	return node != null and (node == outer or outer.is_ancestor_of(node))

func test_every_title_bar_button_is_a_tab_stop_in_an_explicit_ring():
	var ws = await _make_workspace()
	var body: Control = ws._tm.last_body
	assert_true(body is TerminalPane, "the startup tile holds a terminal")
	var row: HBoxContainer = _bar(ws, body).get_node(TerminalManager.TITLE_BAR_BUTTONS)
	assert_eq(row.get_child_count(), 5, "the bar carries five actions")

	for child in row.get_children():
		var b := child as Button
		assert_ne(b.focus_mode, Control.FOCUS_NONE, "%s is mouse-only" % b.name)

	# The body's own traversal continues into its chrome, not the next tile's.
	assert_eq(body.focus_next, body.get_path_to(row.get_child(0)),
		"leaving the body must visit this pane's first chrome action")

	# The ring is explicit in both directions and closes on itself, so Tab
	# cannot leak into a neighbouring pane from a chrome button.
	var count: int = row.get_child_count()
	for i in count:
		var b: Button = row.get_child(i)
		var next: Control = row.get_child((i + 1) % count)
		var prev: Control = row.get_child((i - 1 + count) % count)
		assert_eq(b.get_node(b.focus_next), next,
			"%s must tab to %s" % [b.name, next.name])
		assert_eq(b.get_node(b.focus_previous), prev,
			"%s must shift-tab to %s" % [b.name, prev.name])

func test_the_chrome_shortcut_enters_the_bar_and_escape_returns_to_the_pane():
	var ws = await _make_workspace()
	var body: Control = ws._tm.last_body
	assert_eq(ws.get_viewport().gui_get_focus_owner(), body,
		"precondition: the startup terminal holds the keyboard")

	await _press_key(KEY_E, true, true)
	var owner := ws.get_viewport().gui_get_focus_owner()
	assert_not_null(owner, "Ctrl+Shift+E must focus a title-bar button")
	if owner == null:
		return
	assert_eq(owner.get_parent().name, TerminalManager.TITLE_BAR_BUTTONS,
		"focus lands in the active pane's bar")
	assert_eq(owner.name, "Minimize", "the bar is entered at its first action")

	await _press_key(KEY_ESCAPE)
	assert_eq(ws.get_viewport().gui_get_focus_owner(), body,
		"Escape gives the keyboard back to the pane")

func test_the_chrome_shortcut_leaves_an_open_overlay_alone():
	var ws = await _make_workspace()
	ws._toggle_settings()
	var settings: SettingsPanel = ws._settings_panel
	assert_true(settings.visible, "precondition: Settings is open")

	await _press_key(KEY_E, true, true)

	assert_true(_is_inside(settings, ws.get_viewport().gui_get_focus_owner()),
		"an open overlay owns the keyboard; the chrome shortcut must not take it")

func test_restoring_a_minimized_pane_brings_the_keyboard_back():
	var ws = await _make_workspace()
	var body: Control = ws._tm.last_body
	var min_btn: Button = _bar(ws, body).get_node(
		TerminalManager.TITLE_BAR_BUTTONS + "/Minimize")

	min_btn.pressed.emit()
	assert_false(body.visible, "minimize hides the pane")

	min_btn.pressed.emit()
	assert_true(body.visible, "the second press restores it")
	assert_eq(ws.get_viewport().gui_get_focus_owner(), body,
		"a restored pane takes the keyboard, so the next keystroke is not swallowed")

func test_escape_from_a_read_only_panes_chrome_focuses_its_content():
	# A wiki pane cannot hold focus itself (`activate_pane` releases it), so
	# without a content fallback Escape would leave the keyboard on a chrome
	# button with nothing to type into - a trap of the fix's own making.
	_vault = TestPaths.user_path("title_bar_probe_vault")
	DirAccess.make_dir_recursive_absolute(_vault)
	var note := FileAccess.open(_vault.path_join("note.md"), FileAccess.WRITE)
	note.store_string("# Note\n")
	note.close()

	var ws = await _make_workspace()
	var wiki = ws._spawn_pane("wiki", {"vault_path": _vault})
	assert_true(wiki is WikiPane, "the workspace holds a wiki pane")
	ws.activate_pane(wiki)
	assert_true(ws._tm.focus_title_bar(wiki), "the wiki pane's bar takes the keyboard")

	await _press_key(KEY_ESCAPE)
	var owner := ws.get_viewport().gui_get_focus_owner()
	assert_not_null(owner, "Escape must put the keyboard back somewhere")
	if owner != null:
		assert_true(wiki.is_ancestor_of(owner),
			"Escape lands in the pane's content, not on a chrome button")
