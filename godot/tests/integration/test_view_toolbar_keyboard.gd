extends GutTest
# The view panes' own toolbars from the keyboard — the v0.8.1 finding "The view
# panes' toolbars are mouse-only".
#
# `CodeViewerPane`'s Reload/view toggle and `CliViewPane`'s Restart/Stop were
# built with `focus_mode = FOCUS_NONE`, and no chord reached them. Both panes
# hold a read-only `CodeEdit`, which keeps Tab for indentation, so the fix is
# the wiki note toolbar's pattern generalized into `PaneBody`: one
# `KeyboardFocus.ring`, `Ctrl+Shift+L` to enter it, Escape back to the text the
# pane is read through, and a disabled button is never a stop.

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

var _ws: Control
var _fixture: String

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()
	_fixture = TestPaths.user_path("view_toolbar_fixture.md")
	var f := FileAccess.open(_fixture, FileAccess.WRITE)
	f.store_string("# Fixture\n\nA paragraph.\n")
	f.close()

func after_each():
	if _fixture != "":
		DirAccess.remove_absolute(_fixture)
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

func test_the_code_viewer_toolbar_is_one_closed_ring():
	var ws = await _make_workspace()
	var pane = ws._spawn_pane("code_viewer", {"file_path": _fixture})
	assert_true(pane is CodeViewerPane, "the viewer opens")
	assert_true(pane._toolbar.visible, "a loaded file keeps the toolbar on screen")
	for b in [pane._reload_button, pane._view_toggle]:
		assert_ne(b.focus_mode, Control.FOCUS_NONE, "%s is mouse-only" % b.name)
		assert_ne(b.focus_next, NodePath(), "%s joins the explicit ring" % b.name)
	assert_eq(pane._reload_button.get_node(pane._reload_button.focus_next),
		pane._view_toggle, "Reload tabs to the view toggle")
	assert_eq(pane._view_toggle.get_node(pane._view_toggle.focus_next),
		pane._reload_button, "the toggle tabs back to Reload, wrapping the ring")

func test_the_chord_enters_the_code_viewer_toolbar_and_escape_returns_to_the_text():
	var ws = await _make_workspace()
	var pane = ws._spawn_pane("code_viewer", {"file_path": _fixture})
	# The viewer's Markdown renders by default, so its text view is the rendered
	# document; switch to source so the return target is the CodeEdit.
	pane.view_mode = "source"
	pane._refresh_view()
	ws.activate_pane(pane)

	await _press_key(KEY_L, true, true)
	var owner := ws.get_viewport().gui_get_focus_owner()
	assert_not_null(owner, "Ctrl+Shift+L must focus a toolbar button")
	if owner == null:
		return
	assert_eq(owner.name, "ReloadButton", "the toolbar is entered at its first action")

	await _press_key(KEY_ESCAPE)
	assert_eq(ws.get_viewport().gui_get_focus_owner(), pane._editor,
		"Escape gives the keyboard back to the text")

func test_the_chord_is_inert_on_an_empty_viewer():
	var pane = CodeViewerPane.new()
	add_child_autofree(pane)
	await get_tree().process_frame
	assert_false(pane._toolbar.visible, "precondition: an empty viewer hides its toolbar")
	var before := get_viewport().gui_get_focus_owner()
	assert_false(pane.focus_toolbar(), "nothing to focus")
	assert_eq(get_viewport().gui_get_focus_owner(), before, "the keyboard does not move")

func test_the_cli_view_ring_follows_the_buttons_that_can_be_pressed():
	# No command: `_ready` calls `_start()` for a configured pane, and this test
	# is about the ring, not about spawning a child.
	var pane = CliViewPane.new()
	add_child_autofree(pane)
	await get_tree().process_frame
	assert_true(pane._restart_btn.disabled and pane._stop_btn.disabled,
		"precondition: an unconfigured, stopped pane offers nothing")
	assert_eq(pane._restart_btn.focus_mode, Control.FOCUS_NONE,
		"a disabled button is not a stop the engine can walk to either")
	assert_eq(pane._stop_btn.focus_mode, Control.FOCUS_NONE)
	assert_false(pane.focus_toolbar(), "a disabled row has no stop")

	pane.command = "/bin/sh"
	pane._running = true
	pane._sync_buttons()
	assert_false(pane._restart_btn.disabled or pane._stop_btn.disabled,
		"a running pane offers both")
	assert_eq(pane._restart_btn.focus_mode, Control.FOCUS_ALL)
	assert_eq(pane._stop_btn.focus_mode, Control.FOCUS_ALL)
	assert_eq(pane._restart_btn.get_node(pane._restart_btn.focus_next),
		pane._stop_btn, "Restart tabs to Stop")
	assert_eq(pane._stop_btn.get_node(pane._stop_btn.focus_next),
		pane._restart_btn, "Stop tabs back to Restart")
	assert_true(pane.focus_toolbar())
	assert_eq(get_viewport().gui_get_focus_owner(), pane._restart_btn)

func test_the_chord_enters_the_cli_view_header_and_escape_returns_to_the_text():
	var ws = await _make_workspace()
	var pane = ws._spawn_pane("cli_view", {})
	assert_true(pane is CliViewPane, "the CLI pane opens")
	pane.command = "/bin/sh"
	pane._running = true
	pane._sync_buttons()
	ws.activate_pane(pane)

	await _press_key(KEY_L, true, true)
	var owner := ws.get_viewport().gui_get_focus_owner()
	assert_not_null(owner, "Ctrl+Shift+L must focus a header button")
	if owner == null:
		return
	assert_eq(owner.name, "RestartButton", "the header is entered at its first action")

	await _press_key(KEY_ESCAPE)
	assert_eq(ws.get_viewport().gui_get_focus_owner(), pane._editor,
		"Escape gives the keyboard back to the output")
