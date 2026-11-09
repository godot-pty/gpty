extends GutTest
# The window's own title bar from the keyboard — the v0.8.1 finding "The
# window's own titlebar controls are mouse-only".
#
# Minimize, Maximize and Close were built with `focus_mode = FOCUS_NONE`, none
# of them was in a ring, and nothing short of F11 reached the bar: a borderless
# window could only be moved, maximized or closed with the pointer. The fix is
# the pane-chrome pattern one level out — an explicit ring, `Ctrl+Shift+A` to
# enter it, Escape to give the keyboard back to the active pane — and this file
# pins all three, plus the decorated mode where the bar is not on screen at all.

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

var _ws: Control

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()
	SettingsManager.cfg_window_mode = 0

func after_each():
	SettingsManager.cfg_window_mode = 0
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
	ws.size = Vector2(1000, 700)
	await get_tree().process_frame
	await get_tree().process_frame
	return ws

## The mode is applied on the first frame, deferred, so a test that wants the
## bar on screen asks for borderless after the scene exists.
func _use_borderless(ws: Control) -> void:
	SettingsManager.cfg_window_mode = 1
	ws._chrome.apply_mode()
	await get_tree().process_frame

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

func test_the_three_window_controls_are_one_closed_ring():
	var ws = await _make_workspace()
	await _use_borderless(ws)
	var row: HBoxContainer = ws._chrome._controls
	assert_not_null(row, "the bar builds its control row")
	assert_eq(row.get_child_count(), 3, "minimize, maximize and close")
	for i in row.get_child_count():
		var b: Button = row.get_child(i)
		assert_ne(b.focus_mode, Control.FOCUS_NONE, "%s is mouse-only" % b.name)
		assert_ne(b.focus_next, NodePath(),
			"%s must join the explicit ring, not fall back to tree order" % b.name)
		var prev: Button = row.get_child((i - 1 + 3) % 3)
		var next: Button = row.get_child((i + 1) % 3)
		assert_eq(b.get_node(b.focus_next), next,
			"%s must tab to %s" % [b.name, next.name])
		assert_eq(b.get_node(b.focus_previous), prev,
			"%s must shift-tab to %s" % [b.name, prev.name])

func test_the_chord_enters_the_bar_and_escape_returns_to_the_pane():
	var ws = await _make_workspace()
	await _use_borderless(ws)
	var body: Control = ws._tm.last_body
	assert_eq(ws.get_viewport().gui_get_focus_owner(), body,
		"precondition: the startup terminal holds the keyboard")

	await _press_key(KEY_A, true, true)
	var owner := ws.get_viewport().gui_get_focus_owner()
	assert_not_null(owner, "Ctrl+Shift+A must focus a window control")
	if owner == null:
		return
	assert_eq(owner.get_parent().name, "WinControls",
		"focus lands in the window's own bar, not a pane's")
	assert_eq(owner.name, "Minimize", "the bar is entered at its first control")

	await _press_key(KEY_ESCAPE)
	assert_eq(ws.get_viewport().gui_get_focus_owner(), body,
		"Escape gives the keyboard back to the pane")

func test_the_chord_is_inert_in_the_decorated_mode():
	var ws = await _make_workspace()
	var body: Control = ws._tm.last_body
	ws._chrome.apply_mode()
	assert_false(ws._chrome.titlebar.visible, "precondition: the desktop draws the frame")
	assert_false(ws._chrome.focus_controls(),
		"a hidden bar offers nothing to focus")

	await _press_key(KEY_A, true, true)

	assert_eq(ws.get_viewport().gui_get_focus_owner(), body,
		"the chord must not move the keyboard to an invisible control")

func test_escape_outside_the_bar_is_not_ours():
	# Escape in a terminal is the child's raw ESC byte; the new ladder step sits
	# above it in `Workspace._input`, so a sloppy predicate would eat it.
	var ws = await _make_workspace()
	await _use_borderless(ws)
	var body: Control = ws._tm.last_body
	assert_eq(ws.get_viewport().gui_get_focus_owner(), body,
		"precondition: the terminal holds the keyboard")

	assert_false(ws._escape_window_chrome(),
		"a focus owner outside the bar is not this branch's")
	await _press_key(KEY_ESCAPE)
	assert_eq(ws.get_viewport().gui_get_focus_owner(), body,
		"Escape still reaches the terminal")
