extends GutTest
# Keyboard routing: Ctrl+Shift+C is copy-only — it consumes the event
# with or without a selection, so it can never fall through to the
# code-viewer spawn shortcut (now on Ctrl+Shift+D).

class ProbedPane:
	extends TerminalPane

	var snaps := 0
	var clears := 0
	var sel_text := ""

	func _snap_to_bottom():
		snaps += 1

	# Selection content and grid rotation are covered by the core's own
	# tests (`term::tests::selection_*`); these tests are about routing, so
	# the text and the clear are seams.
	func _get_selected_text() -> String:
		return sel_text

	func _clear_selection():
		clears += 1
		sel_text = ""


var _scene: Control
var _pane: ProbedPane
var _spawns := 0


func before_each():
	MockAutoloads.setup()
	_spawns = 0
	# Hermetic: clear any app:new_code_viewer binding left by workspace
	# tests in this run, then register our own probe action.
	ShortcutManager._actions.erase("app:new_code_viewer")
	if InputMap.has_action("app:new_code_viewer"):
		InputMap.erase_action("app:new_code_viewer")
	ShortcutManager.register("test:code_viewer", "Ctrl+Shift+C", func(): _spawns += 1)
	_scene = TestScene.create()
	add_child(_scene)
	_pane = ProbedPane.new()
	_pane.shell_command = SettingsManager.default_shell_command()
	_scene.add_child(_pane)
	_pane.size = Vector2(800, 600)
	_pane.grab_focus()


func after_each():
	ShortcutManager._actions.erase("test:code_viewer")
	ShortcutManager._actions.erase("app:new_code_viewer")
	if InputMap.has_action("test:code_viewer"):
		InputMap.erase_action("test:code_viewer")
	if InputMap.has_action("app:new_code_viewer"):
		InputMap.erase_action("app:new_code_viewer")
	remove_child(_scene)
	_scene.free()
	MockAutoloads.teardown()


func _press(keycode: int) -> InputEventKey:
	var ev = InputEventKey.new()
	ev.keycode = keycode
	ev.unicode = 0
	ev.ctrl_pressed = true
	ev.shift_pressed = true
	ev.pressed = true
	return ev


func _press_copy() -> InputEventKey:
	return _press(KEY_C)


func _press_mod(keycode: int) -> InputEventKey:
	var ev = InputEventKey.new()
	ev.keycode = keycode
	ev.unicode = 0
	ev.ctrl_pressed = keycode == KEY_CTRL
	ev.shift_pressed = keycode == KEY_SHIFT
	ev.alt_pressed = keycode == KEY_ALT
	ev.pressed = true
	return ev


func _dispatch(ev: InputEventKey):
	Input.parse_input_event(ev)
	Input.flush_buffered_events()
	await get_tree().process_frame
	await get_tree().process_frame


func test_copy_with_selection_routes_copy_only():
	_pane.sel_text = "abc"
	await _dispatch(_press_copy())
	assert_eq(_spawns, 0, "no code-viewer spawn when a selection is copied")
	assert_eq(_pane.clears, 1, "the copy branch dismissed the selection")


func test_copy_without_selection_does_not_spawn():
	await _dispatch(_press_copy())
	assert_eq(_spawns, 0, "Ctrl+Shift+C without selection must not spawn the code viewer")


func test_code_viewer_shortcut_spawns_on_new_binding():
	# Rebind the probe action to the code viewer's new chord and verify the
	# spawn path still works through the unhandled-input chain.
	ShortcutManager._actions.erase("test:code_viewer")
	if InputMap.has_action("test:code_viewer"):
		InputMap.erase_action("test:code_viewer")
	ShortcutManager.register("test:code_viewer", "Ctrl+Shift+D", func(): _spawns += 1)
	await _dispatch(_press(KEY_D))
	assert_eq(_spawns, 1, "Ctrl+Shift+D spawns the code viewer")

func test_modifier_presses_do_not_clear_selection():
	_pane.sel_text = "abc"
	await _dispatch(_press_mod(KEY_CTRL))
	assert_eq(_pane.sel_text, "abc", "Ctrl press must not clear the selection")
	await _dispatch(_press_mod(KEY_SHIFT))
	assert_eq(_pane.sel_text, "abc", "Shift press must not clear the selection")
	await _dispatch(_press_mod(KEY_ALT))
	assert_eq(_pane.sel_text, "abc", "Alt press must not clear the selection")
	assert_eq(_pane.clears, 0, "no modifier press may dismiss the selection")
	assert_eq(_pane.snaps, 0, "modifier presses must not snap a scrolled-back view to the bottom")


func test_rapid_modifier_sequence_then_copy():
	# The reported flow: select, then press Ctrl, Shift, and C in rapid
	# succession. Modifiers must not clear the selection; the C chord copies.
	_pane.sel_text = "abc"
	await _dispatch(_press_mod(KEY_CTRL))
	await _dispatch(_press_mod(KEY_SHIFT))
	await _dispatch(_press_copy())
	assert_eq(_spawns, 0, "copy chord must not spawn the code viewer")
	assert_eq(_pane.clears, 1, "copy chord consumed and cleared the selection")


func test_typing_clears_selection():
	_pane.sel_text = "abc"
	var ev = InputEventKey.new()
	ev.keycode = KEY_X
	ev.unicode = 120
	ev.pressed = true
	await _dispatch(ev)
	assert_eq(_pane.sel_text, "", "typing still clears the selection")
