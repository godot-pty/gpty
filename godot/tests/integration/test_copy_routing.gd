extends GutTest
# Keyboard routing: Ctrl+Shift+C is copy-only — it consumes the event
# with or without a selection, so it can never fall through to the
# code-viewer spawn shortcut (now on Ctrl+Shift+D).

class ProbedPane:
	extends TerminalPane


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
	_pane.shell_command = "/bin/sh"
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


func _fake_cache() -> Dictionary:
	return {
		"rows": 1, "cols": 3, "chars": ["abc"],
		"fg": PackedColorArray([Color.WHITE, Color.WHITE, Color.WHITE]),
		"bg": PackedColorArray([Color.BLACK, Color.BLACK, Color.BLACK]),
		"attrs": PackedInt32Array([0, 0, 0]),
	}


func _dispatch(ev: InputEventKey):
	Input.parse_input_event(ev)
	Input.flush_buffered_events()
	await get_tree().process_frame
	await get_tree().process_frame


func test_copy_with_selection_routes_copy_only():
	_pane._cell_cache = _fake_cache()
	_pane._sel_start = Vector2i(0, 0)
	_pane._sel_end = Vector2i(0, 2)
	await _dispatch(_press_copy())
	assert_eq(_spawns, 0, "no code-viewer spawn when a selection is copied")
	assert_eq(_pane._sel_start, Vector2i(-1, -1), "copy branch cleared the selection")


func test_copy_without_selection_does_not_spawn():
	_pane._cell_cache = _fake_cache()
	_pane._sel_start = Vector2i(-1, -1)
	_pane._sel_end = Vector2i(-1, -1)
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
