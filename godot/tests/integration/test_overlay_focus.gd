extends GutTest
# Overlay keyboard ownership — the v0.8.0 finding "An open overlay neither
# takes keyboard focus nor blocks the terminal behind it".
#
# The four overlays (Settings, Pane Settings, the command palette and the
# concept editor) share one contract: opening one takes the keyboard off the
# pane, so a typed character is a keystroke into the overlay and never a byte
# in the child's PTY; Escape closes it from an input stage a terminal cannot
# pre-empt, without writing the raw ESC the terminal would otherwise send; and
# closing puts the keyboard back.
#
# The observable is the app's own: the viewport's focus owner and the pane's
# grid. A direct `_handle_keyboard` call would pass with no focus owner at all
# — the exact failure this file pins — so every key goes through
# `Input.parse_input_event`, as from a user's keyboard.

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

## The shell has produced output; a typed character can only leak into a child
## that is running.
const SHELL_READY_MS := 30000

## The typed line reaches the grid twice: the shell's echo and the output.
const OUTPUT_ARRIVAL_MS := 20000

## Typed while an overlay owns the keyboard, and never submitted: if it reached
## the child it would sit on the prompt, visible in the grid.
const LEAK := "gpty_overlay_leak"

var _ws: Control

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()
	SettingsManager.cfg_default_rows = 24
	SettingsManager.cfg_default_cols = 80

func after_each():
	if _ws:
		if _ws.get_parent():
			_ws.get_parent().remove_child(_ws)
		_ws.free()
		_ws = null
	MockAutoloads.teardown()

func _start_workspace() -> Control:
	var ws: Control = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame
	return ws

func _first_terminal(ws: Control) -> Control:
	var tm: TerminalManager = ws._tm
	for t in tm.tiles:
		var body = tm._find_body(t.wrapper)
		if body is TerminalPane:
			return body
	return null

func _grid_text(body: Control) -> String:
	return str(body._terminal.get_plain_text(2000))

func _wait_for_shell_output(body: Control, timeout_ms: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		var status = JSON.parse_string(str(body._terminal.get_status()))
		if status is Dictionary and status.get("idle_ms") != null:
			return true
		await get_tree().create_timer(0.05).timeout
	return false

func _wait_for_grid_count(body: Control, needle: String, count: int, timeout_ms: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if _grid_text(body).count(needle) >= count:
			return true
		await get_tree().create_timer(0.05).timeout
	return false

## Dispatch `text` through the real input path: each key goes to the viewport's
## focus owner exactly as a user's keystroke would.
func _type(text: String) -> void:
	for ch in text:
		var ev := InputEventKey.new()
		ev.pressed = true
		if ch == "\n":
			ev.keycode = KEY_ENTER
			ev.unicode = 13
		else:
			ev.keycode = ch.to_upper().unicode_at(0)
			ev.unicode = ch.unicode_at(0)
		Input.parse_input_event(ev)
	Input.flush_buffered_events()
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

## Open `name` through the same path a user takes, and return the overlay.
func _open_overlay(ws: Control, name: String) -> OverlayPanel:
	match name:
		"Settings":
			ws._sidebar.request_settings.emit()
			return ws._settings_panel
		"Pane Settings":
			ws._tm._open_pane_settings(ws._tm.last_body)
			return ws._tm._pane_settings_panel
		"Palette":
			ws._toggle_palette()
			return ws._palette
		"Concept Editor":
			ws._open_concept_graph()
			return ws._concept_graph
	return null

func _focus_owner_path(ws: Control) -> String:
	var owner := ws.get_viewport().gui_get_focus_owner()
	return "<none>" if owner == null else str(ws.get_path_to(owner))

func _is_inside(outer: Control, node: Control) -> bool:
	return node != null and (node == outer or outer.is_ancestor_of(node))

const OVERLAYS := ["Settings", "Pane Settings", "Palette", "Concept Editor"]

func test_every_overlay_owns_the_keyboard_until_escape():
	var ws = await _start_workspace()
	var body = _first_terminal(ws)
	assert_not_null(body, "the startup tile holds a terminal")
	assert_true(await _wait_for_shell_output(body, SHELL_READY_MS),
		"the shell must be running before a leak can be observed: %s" % _grid_text(body).right(400))
	assert_eq(ws.get_viewport().gui_get_focus_owner(), body,
		"precondition: the startup terminal holds the keyboard")

	for name in OVERLAYS:
		var overlay := _open_overlay(ws, name)
		await get_tree().process_frame
		assert_not_null(overlay, "%s must open" % name)
		if overlay == null:
			continue
		assert_true(overlay.visible, "%s must be visible" % name)
		assert_same(ws._keyboard_overlay(), overlay, "%s must own the keyboard" % name)
		assert_true(_is_inside(overlay, ws.get_viewport().gui_get_focus_owner()),
			"%s must take the keyboard off the terminal (owner: %s)"
			% [name, _focus_owner_path(ws)])

		await _type(LEAK)
		await get_tree().process_frame
		assert_false(_grid_text(body).contains(LEAK),
			"%s: a typed character must not reach the PTY" % name)

		var before := _grid_text(body)
		await _press_key(KEY_ESCAPE)
		assert_false(overlay.visible, "%s must close on Escape" % name)
		assert_eq(ws.get_viewport().gui_get_focus_owner(), body,
			"%s: Escape must give the terminal the keyboard back" % name)
		assert_eq(_grid_text(body), before,
			"%s: Escape must not write the raw ESC byte to the child" % name)

		# The line is clean and the keyboard is really back: the command echoes
		# and runs, so its marker appears twice. A leaked ESC would have eaten
		# the first character and the command would not run.
		var marker := "ok_%s" % name.to_lower().replace(" ", "_")
		await _type("echo %s\n" % marker)
		assert_true(await _wait_for_grid_count(body, marker, 2, OUTPUT_ARRIVAL_MS),
			"%s: the typed command must run after Escape: %s"
			% [name, _grid_text(body).right(400)])

func test_escape_from_the_concept_editor_returns_to_settings():
	var ws = await _start_workspace()
	ws._sidebar.request_settings.emit()
	var settings: SettingsPanel = ws._settings_panel
	assert_true(settings.visible, "precondition: Settings is open")

	ws._open_concept_graph()
	var graph: ConceptGraphEditor = ws._concept_graph
	assert_true(graph.visible, "the concept editor opens over the panel")
	assert_true(_is_inside(graph, ws.get_viewport().gui_get_focus_owner()),
		"the editor owns the keyboard")

	await _press_key(KEY_ESCAPE)
	assert_false(graph.visible, "Escape closes the editor")
	assert_true(settings.visible, "the Settings panel stays open underneath")
	assert_true(_is_inside(settings, ws.get_viewport().gui_get_focus_owner()),
		"the keyboard goes back to the panel, not to the terminal behind it")

func test_a_command_that_spawns_a_pane_keeps_the_new_pane_focused():
	# The palette gives the keyboard back before it runs the command, so the
	# thing the command focuses must win, not the pane the palette was opened
	# from.
	var ws = await _start_workspace()
	var first = _first_terminal(ws)
	ws._toggle_palette()
	var palette: CommandPalette = ws._palette
	await get_tree().process_frame

	palette._field.text_changed.emit("new terminal")
	palette._field.text_submitted.emit("new terminal")
	await get_tree().process_frame

	assert_false(palette.visible, "running a command closes the palette")
	var tiles: Array = ws._tm.tiles
	var spawned = ws._tm._find_body(tiles[tiles.size() - 1].wrapper)
	assert_true(spawned is TerminalPane, "the command spawned a terminal")
	assert_ne(spawned, first, "the new pane is a different terminal")
	assert_eq(ws.get_viewport().gui_get_focus_owner(), spawned,
		"the spawned pane keeps the keyboard the palette gave back")

func test_a_click_behind_an_open_overlay_does_not_take_the_keyboard():
	var ws = await _start_workspace()
	ws._toggle_palette()
	var palette: CommandPalette = ws._palette
	await get_tree().process_frame

	# A point inside the tile but outside the palette: without the guard the
	# raw input stage would activate the pane and focus it while the overlay
	# is still open, and the next letters would reach the shell.
	var rect: Rect2 = ws._tm.tiles[0].wrapper.get_global_rect()
	var point: Vector2 = rect.position + Vector2(10, 10)
	assert_false(palette.get_global_rect().has_point(point),
		"precondition: the click lands behind the palette, not on it")

	ws._tm.last_body = null
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = point
	ws._input(ev)
	assert_null(ws._tm.last_body,
		"a click behind an open overlay must not activate a pane")

func test_a_pane_shortcut_while_an_overlay_is_open_does_not_take_the_keyboard():
	# The shortcut layer is global on purpose (Ctrl+Shift+B toggles the sidebar
	# while a panel is open), so a spawn shortcut still runs — but the pane it
	# creates must not steal the keyboard from the overlay that owns it.
	var ws = await _start_workspace()
	ws._sidebar.request_settings.emit()
	var settings: SettingsPanel = ws._settings_panel
	assert_true(settings.visible, "precondition: Settings is open")
	var before: int = ws._tm.tiles.size()

	await _press_key(KEY_N, true, true)
	await get_tree().process_frame

	assert_eq(ws._tm.tiles.size(), before + 1, "Ctrl+Shift+N still spawns a terminal")
	assert_true(_is_inside(settings, ws.get_viewport().gui_get_focus_owner()),
		"the open overlay keeps the keyboard the spawn would have taken (owner: %s)"
		% _focus_owner_path(ws))
