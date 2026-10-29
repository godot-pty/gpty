extends GutTest
# Paste payloads. A paste is not typing: the terminal has to say so, and it has
# to stop the text from saying something else.
#
# With DECSET 2004 the application is told ("bracketed paste") and receives the
# text between `ESC[200~` and `ESC[201~`. That terminator is why both branches
# share one filter: a clipboard holding `ESC[201~` would end the paste early,
# and whatever followed - a newline included - would arrive as typed input, a
# "pastejacking" shape any web page can plant. So C0 controls other than
# newline and tab, and DEL, are dropped whether the child asked for the mode or
# not; without it they are dropped for the older reason (`\x03` interrupts, a
# CR submits the line).

func test_bracketed_paste_wraps_the_text():
	var payload = TerminalPane.build_paste_payload("echo hi\nrm -rf /\n", true)
	assert_eq(payload, "\u001b[200~echo hi\nrm -rf /\n\u001b[201~")

func test_bracketed_paste_cannot_be_closed_early():
	# The exploit shape: the pasted text carries the paste terminator, so the
	# rest of it would be read as typing (a newline submits it).
	var payload = TerminalPane.build_paste_payload("echo ok\u001b[201~;whoami\nrm -rf ~", true)
	assert_eq(payload, "\u001b[200~echo ok[201~;whoami\nrm -rf ~\u001b[201~")
	assert_eq(payload.count("\u001b"), 2, "only the wrapper's escapes survive")
	assert_eq(payload.count("\u001b[201~"), 1, "exactly one terminator, and it is ours")
	assert_eq(payload.count("\u001b[200~"), 1, "the text cannot open a second bracket")

func test_bracketed_paste_drops_control_bytes():
	# The application asked to be told this is a paste; it did not ask to be
	# handed escape sequences or interrupts.
	var payload = TerminalPane.build_paste_payload("a\u001bb\u0003c\u007fd", true)
	assert_eq(payload, "\u001b[200~abcd\u001b[201~")

func test_bracketed_paste_keeps_newlines_and_tabs():
	var payload = TerminalPane.build_paste_payload("one\ntwo\tthree", true)
	assert_eq(payload, "\u001b[200~one\ntwo\tthree\u001b[201~")

func test_plain_paste_drops_escape_and_control_bytes():
	var payload = TerminalPane.build_paste_payload("safe\u001b[201~rm -rf /\u0003x\u007f", false)
	assert_eq(payload, "safe[201~rm -rf /x", "only the control bytes go")

func test_plain_paste_keeps_newlines_and_tabs():
	var payload = TerminalPane.build_paste_payload("one\ntwo\tthree", false)
	assert_eq(payload, "one\ntwo\tthree", "a multi-line paste into a shell stays usable")

func test_plain_paste_drops_bare_carriage_return():
	# The PTY turns a bare CR into Enter, so it is an injection, not a line end.
	var payload = TerminalPane.build_paste_payload("ls\rrm -rf /", false)
	assert_eq(payload, "lsrm -rf /")

func test_plain_paste_is_unchanged_for_ordinary_text():
	var text = "mise à jour — €100 (see README.md)"
	assert_eq(TerminalPane.build_paste_payload(text, false), text)

func test_every_c0_control_but_tab_and_newline_is_dropped():
	# The policy in one assertion, for both branches: the filter is shared, so
	# a byte dropped on one path cannot survive on the other. Starts at 1
	# because a Godot String cannot carry a NUL - `String.chr(0)` yields
	# U+FFFD and `get_string_from_utf8` stops at the byte.
	var controls := ""
	for code in range(1, 32):
		controls += String.chr(code)
	controls += String.chr(127)
	var text := "a" + controls + "b"
	var expected := "a\t\nb"
	assert_eq(TerminalPane.build_paste_payload(text, false), expected)
	assert_eq(TerminalPane.build_paste_payload(text, true), "\u001b[200~" + expected + "\u001b[201~")

# ── The handler path ───────────────────────────────────────────────────
#
# Same shape as the mouse-report tests: a probe pane whose FFI reads are
# stubbed, so the real Ctrl+Shift+V branch runs without a live child.

var _probe: PasteProbePane

class PasteProbePane:
	extends TerminalPane

	var sent := ""
	var bracketed := false
	var clipboard := ""

	func _is_bracketed_paste() -> bool:
		return bracketed

	func _get_clipboard_text() -> String:
		return clipboard

	func _send_to_term(text: String):
		sent += text

func _paste_event() -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = KEY_V
	event.ctrl_pressed = true
	event.shift_pressed = true
	event.pressed = true
	return event

func test_ctrl_shift_v_brackets_when_the_child_asked_for_it():
	_probe = PasteProbePane.new()
	_probe.bracketed = true
	_probe.clipboard = "line one\nline two"
	_probe._handle_keyboard(_paste_event())
	assert_eq(_probe.sent, "\u001b[200~line one\nline two\u001b[201~")
	_probe.free()

func test_ctrl_shift_v_bracket_survives_a_hostile_clipboard():
	# End to end through the real Ctrl+Shift+V branch: what reaches the PTY
	# holds one terminator, the one the pane wrote.
	_probe = PasteProbePane.new()
	_probe.bracketed = true
	_probe.clipboard = "echo ok\u001b[201~\nrm -rf ~"
	_probe._handle_keyboard(_paste_event())
	assert_eq(_probe.sent, "\u001b[200~echo ok[201~\nrm -rf ~\u001b[201~")
	assert_eq(_probe.sent.count("\u001b[201~"), 1)
	_probe.free()

func test_ctrl_shift_v_guards_when_it_did_not():
	_probe = PasteProbePane.new()
	_probe.bracketed = false
	_probe.clipboard = "echo ok\u001b[201~\u0003danger"
	_probe._handle_keyboard(_paste_event())
	assert_eq(_probe.sent, "echo ok[201~danger")
	_probe.free()

func test_ctrl_shift_v_with_an_empty_clipboard_sends_nothing():
	_probe = PasteProbePane.new()
	_probe.bracketed = true
	_probe._handle_keyboard(_paste_event())
	assert_eq(_probe.sent, "")
	_probe.free()
