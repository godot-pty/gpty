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

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

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
	body._terminal.send_line(ShellFixtures.print_text(sequence, 30))
	return body

func _wait_for_mode(body: Control, expected: bool, timeout_ms: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if body._terminal.is_bracketed_paste() == expected:
			return true
		await get_tree().create_timer(0.05).timeout
	return false

func test_resetting_the_mode_reaches_the_pane():
	var body = await _pane_owned_by_child("\u001b[?2004l")
	# readline usually set it already, so this is a real transition rather
	# than an unset default.
	assert_true(
		await _wait_for_mode(body, false, 10000),
		"2004l from the child must clear the grid's mode"
	)

func test_setting_the_mode_reaches_the_pane():
	var body = await _pane_owned_by_child("\u001b[?2004h")
	assert_true(
		await _wait_for_mode(body, true, 10000),
		"DECSET 2004 from the child must reach the grid's mode"
	)

func test_the_paste_path_uses_the_child_mode():
	var body = await _pane_owned_by_child("\u001b[?2004h")
	assert_true(await _wait_for_mode(body, true, 10000))

	# The real builder, driven by the real mode read.
	var payload = TerminalPane.build_paste_payload("a\nb", body._terminal.is_bracketed_paste())
	assert_eq(payload, "\u001b[200~a\nb\u001b[201~")
