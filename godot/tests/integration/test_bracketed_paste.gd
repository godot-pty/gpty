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
# The pane's shell is spawned with line editing off (`ShellFixtures.no_line_editing_args()`),
# because the default one sets the mode itself and then the assertions cannot
# say whose bytes arrived — measured: with the fixture's command line replaced
# by a bare `sleep 30` the file still passed 3/3, since `bash -i` had turned
# bracketed paste on and turned it off again when the typed line ran. With that
# source removed, the mode either comes from the child or does not arrive, on
# every platform.
#
# Two waits, because the pane's shell and the fixture are different processes.
# The pane's shell has to be printing before a command line is typed into it —
# a line handed to a console app that has not attached yet is read by nothing —
# and the fixture's own startup then gets a budget of its own. That budget is
# the fixture's process, not the paste path: on Windows it is
# `powershell -Command`, whose first launch on a loaded runner measured past
# the 10 s this file used to allow, which reported a cold start as "the mode
# never arrived" (windows-smoke).

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

## A workspace with one terminal, handed over to the child that `line` starts.
##
## The pane is spawned here rather than taken from the workspace's startup pane
## because its shell has to start without line editing: `SettingsManager`
## carries no global arguments, and `bash -i` sets DECSET 2004 around every line
## readline edits — the very mode this file is about.
func _pane_owned_by_child(line: String) -> Control:
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame
	var body = ws._spawn_pane("terminal", {"shell_args": ShellFixtures.no_line_editing_args()})
	assert_not_null(body, "the file needs a terminal pane it can configure")
	# Then close the workspace's startup pane, so the file leaves one pane per
	# test exactly as it did before it configured its own. Every pane keeps a
	# history writer on the run's single SQLite store, and running two per test
	# here is what pushed a later file's append past the store's 5 s lock wait
	# (`history append failed (2 rows): database is locked`, windows-smoke) —
	# the collision was the file's footprint, not its assertions.
	var startup = ws._tm._find_body(ws._tm.tiles[0].wrapper)
	if startup != null and startup != body:
		ws._tm.kill(startup)
	assert_true(
		await _wait_for_shell_output(body, SHELL_READY_MS),
		"the pane's shell must print before a command line is typed into it: %s" % _pane_state(body)
	)
	# Nothing has been typed and the shell sets no modes, so the mode must be
	# off. This is the assertion that pins the setup: with the default shell it
	# fails, because readline had already turned bracketed paste on — which is
	# how a command line that prints nothing could pass the tests below.
	assert_false(
		body._terminal.is_bracketed_paste(),
		"the pane's shell must not set bracketed paste by itself: %s" % _pane_state(body)
	)
	body._terminal.send_line(line)
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
	# On, hold, off: one line, because a holding fixture cannot be typed into
	# again. Both halves are the child's doing, so this is a real transition on
	# every platform — with the default shell it was the *shell* that had set
	# the mode, which let a fixture that printed nothing pass.
	var body = await _pane_owned_by_child(
		ShellFixtures.print_text_pair("\u001b[?2004h", 3, "\u001b[?2004l"))
	assert_true(
		await _wait_for_mode(body, true, FIXTURE_STARTUP_MS),
		"DECSET 2004 from the child must reach the grid's mode: %s" % _pane_state(body)
	)
	assert_true(
		await _wait_for_mode(body, false, FIXTURE_STARTUP_MS),
		"2004l from the child must clear it again: %s" % _pane_state(body)
	)

func test_setting_the_mode_reaches_the_pane():
	var body = await _pane_owned_by_child(ShellFixtures.print_text("\u001b[?2004h", 30))
	assert_true(
		await _wait_for_mode(body, true, FIXTURE_STARTUP_MS),
		"DECSET 2004 from the child must reach the grid's mode: %s" % _pane_state(body)
	)

func test_the_paste_path_uses_the_child_mode():
	var body = await _pane_owned_by_child(ShellFixtures.print_text("\u001b[?2004h", 30))
	assert_true(
		await _wait_for_mode(body, true, FIXTURE_STARTUP_MS),
		"the paste path needs the child's mode: %s" % _pane_state(body)
	)

	# The real builder, driven by the real mode read.
	var payload = TerminalPane.build_paste_payload("a\nb", body._terminal.is_bracketed_paste())
	assert_eq(payload, "\u001b[200~a\nb\u001b[201~")
