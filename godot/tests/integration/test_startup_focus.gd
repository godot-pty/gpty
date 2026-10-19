extends GutTest
# Startup focus (UX-01): a fresh workspace's first terminal owns the keyboard,
# so the first keystroke after launch reaches the shell without a click.
#
# The audit's control run is the precedent — typing did nothing until the pane
# was clicked, then the same line reached the prompt. The observable here is
# the viewport's focus owner plus a line that arrives in the grid through real
# input dispatch, because a direct `_handle_keyboard` call would pass with no
# focus owner at all, which is exactly the failure this file pins.
#
# The same fallback covers two more entries the audit did not exercise: a
# workspace restored (or spawned into) without ever being viewed, and one
# rebuilt by a profile. Both had the same hole — `last_body` is only set by a
# click, a spawn, or a focus event, and neither path does any of those.

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

## The shell has produced output — `idle_ms` is stamped by the first PTY bytes
## the child writes, so it says the shell is running rather than that a spawn
## was requested, and a line typed into a console app that has not attached yet
## is read by nothing.
const SHELL_READY_MS := 30000

## The typed line reaches the grid twice: once as the shell's echo and once as
## the output of `echo`. Timing is the PTY round trip, not a process launch.
const OUTPUT_ARRIVAL_MS := 20000

const MARKER := "gpty_startup_focus"

var _ws: Control

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()
	SettingsManager.cfg_default_rows = 24
	SettingsManager.cfg_default_cols = 80

func after_each():
	# Free synchronously while mocks are still active, and only after the
	# workspace's deferred concept push (2 s after `_ready`) has landed — a
	# resume on a freed instance is an engine error, which GUT counts as a
	# failure.
	if _ws:
		await get_tree().create_timer(2.1).timeout
		if _ws.get_parent():
			_ws.get_parent().remove_child(_ws)
		_ws.free()
		_ws = null
	MockAutoloads.teardown()

## An empty (mocked) workspace store: the workspace builds its first tile
## through `_restore_into`'s empty-layout fallback, exactly like a first run.
func _start_workspace() -> Control:
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame
	return ws

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

## Dispatch `text` through the real input path: every key goes to the
## viewport's focus owner exactly as a user's keystroke would. Printable
## characters carry their unicode, which is the path the pane's fallback uses
## (the Rust keymap intentionally ignores printable ASCII).
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

func test_a_fresh_workspace_focuses_its_first_terminal_and_takes_typing():
	var ws = await _start_workspace()
	var tm: TerminalManager = ws._tm
	assert_gt(tm.tiles.size(), 0, "an empty layout spawns a startup terminal")
	var body = tm._find_body(tm.tiles[0].wrapper)
	assert_not_null(body, "the startup tile holds a body")
	assert_true(body is TerminalPane, "the startup pane is a terminal")
	assert_eq(tm.last_body, body, "launch must record the first terminal as the active pane")
	assert_eq(ws.get_viewport().gui_get_focus_owner(), body,
		"launch must leave the first terminal holding the keyboard")

	assert_true(await _wait_for_shell_output(body, SHELL_READY_MS),
		"the shell must print before a line is typed: %s" % _grid_text(body).right(400))
	await _type("echo %s\n" % MARKER)
	assert_true(await _wait_for_grid_count(body, MARKER, 2, OUTPUT_ARRIVAL_MS),
		"the typed line must be echoed and run without a click: %s" % _grid_text(body).right(400))

func test_switching_to_a_restored_but_unvisited_workspace_focuses_its_first_terminal():
	var ws = await _start_workspace()
	ws._add_workspace()
	assert_eq(ws._active, 1, "precondition: the new workspace is active")
	# Spawning does not activate: `_spawn_pane_into` attaches the tile, and
	# `_restore_into` is the same route for every restored pane.
	var spawned = ws._spawn_pane("terminal")
	assert_not_null(spawned, "precondition: the second workspace holds a terminal")
	var tm: TerminalManager = ws._workspaces[1].tm
	assert_null(tm.last_body, "precondition: building the workspace activated no pane")

	ws._switch_workspace(0)
	ws._switch_workspace(1)
	assert_eq(tm.last_body, spawned,
		"the first terminal becomes active the first time the workspace is viewed")
	assert_eq(ws.get_viewport().gui_get_focus_owner(), spawned,
		"switching in must give its first terminal the keyboard")
