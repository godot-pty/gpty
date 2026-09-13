extends GutTest
# Bracketed paste, end to end: the mode the pane reads must follow what the
# child prints (DECSET 2004 on, 2004l off).
#
# The obligation is split — the grid reports the mode, the pane wraps or
# guards — and the grid's half is only true if the child's own bytes reach
# alacritty's mode bits through the vte parser. The child is a process that
# writes the bytes and then holds (`ShellFixtures`), not the shell: an
# interactive shell's readline enables bracketed paste by itself, so it cannot
# be the thing that decides.
#
# Two waits, because the pane's shell and the fixture are different processes.
# The pane's shell has to be printing before a command line is typed into it —
# a line handed to a console app that has not attached yet is read by nothing —
# and the fixture's own startup then gets a budget of its own. That budget is
# the fixture's process, not the paste path: on Windows it is
# `powershell -Command`, whose first launch on a loaded runner measured past
# the 10 s this file used to allow, which reported a cold start as "the mode
# never arrived" (windows-smoke). On Unix the same 10 s hid the problem behind
# readline, which had already set the mode; the assertions below still exercise
# the parser there, but only Windows exercises the child.

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

## The pane's shell is up and has produced output.
const SHELL_READY_MS := 30000

## The fixture's own process: a cold `powershell.exe` starts in seconds.
const FIXTURE_STARTUP_MS := 60000

var _ws: Control

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()

func after_each():
	if _ws:
		if _ws.get_parent():
			_ws.get_parent().remove_child(_ws)
		_ws.free()
		_ws = null
	MockAutoloads.teardown()

## A workspace with one running terminal, handed over to a child that prints
## `sequence` and stays alive while the test reads the grid's mode.
func _pane_owned_by_child(sequence: String) -> Control:
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame
	var body = ws._tm._find_body(ws._tm.tiles[0].wrapper)
	assert_true(
		await _wait_for_shell_output(body, SHELL_READY_MS),
		"the pane's shell must print before a command line is typed into it: %s" % _pane_state(body)
	)
	body._terminal.send_line(ShellFixtures.print_text(sequence, 30))
	return body

## The shell has produced output — `idle_ms` is stamped by the first PTY bytes
## the child writes (core's `last_output_unix_ms`), so it says the shell is
## running rather than that a spawn was requested.
func _wait_for_shell_output(body: Control, timeout_ms: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		var status = JSON.parse_string(str(body._terminal.get_status()))
		if status is Dictionary and status.get("idle_ms") != null:
			return true
		await get_tree().create_timer(0.05).timeout
	return false

func _wait_for_mode(body: Control, expected: bool, timeout_ms: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if body._terminal.is_bracketed_paste() == expected:
			return true
		await get_tree().create_timer(0.05).timeout
	return false

## What the pane holds when an assertion above gives up, so the failure says
## which half went missing: the child never printed (the prompt and the echoed
## command line are all there is, or an error is), or its bytes landed and the
## mode did not follow them.
func _pane_state(body: Control) -> String:
	var grid := str(body._terminal.get_plain_text(2000))
	if grid.length() > 400:
		grid = grid.substr(grid.length() - 400)
	return "mode=%s grid=%s" % [body._terminal.is_bracketed_paste(), grid.replace("\n", "\\n")]

func test_resetting_the_mode_reaches_the_pane():
	var body = await _pane_owned_by_child("\u001b[?2004l")
	# readline usually set it already, so this is a real transition rather
	# than an unset default.
	assert_true(
		await _wait_for_mode(body, false, FIXTURE_STARTUP_MS),
		"2004l from the child must clear the grid's mode: %s" % _pane_state(body)
	)

func test_setting_the_mode_reaches_the_pane():
	var body = await _pane_owned_by_child("\u001b[?2004h")
	assert_true(
		await _wait_for_mode(body, true, FIXTURE_STARTUP_MS),
		"DECSET 2004 from the child must reach the grid's mode: %s" % _pane_state(body)
	)

func test_the_paste_path_uses_the_child_mode():
	var body = await _pane_owned_by_child("\u001b[?2004h")
	assert_true(
		await _wait_for_mode(body, true, FIXTURE_STARTUP_MS),
		"the paste path needs the child's mode: %s" % _pane_state(body)
	)

	# The real builder, driven by the real mode read.
	var payload = TerminalPane.build_paste_payload("a\nb", body._terminal.is_bracketed_paste())
	assert_eq(payload, "\u001b[200~a\nb\u001b[201~")
