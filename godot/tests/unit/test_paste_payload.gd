extends GutTest
# Paste payloads. A paste is not typing: the terminal has to say so, or guard
# what it cannot say.
#
# With DECSET 2004 the application is told ("bracketed paste") and can insert
# the text verbatim. Without it, the pane's own guard applies — control bytes
# (escape sequences, ^C, DEL) are dropped — because there is no way to tell a
# pasted `ESC[201~` or `\x03` from one the user typed, and the clipboard is
# attacker-influenced in a way the keyboard is not.

func test_bracketed_paste_wraps_the_text_untouched():
	var payload = TerminalPane.build_paste_payload("echo hi\nrm -rf /\n", true)
	assert_eq(payload, "\u001b[200~echo hi\nrm -rf /\n\u001b[201~")

func test_bracketed_paste_keeps_control_bytes():
	# The application asked for them; mangling the payload would corrupt it.
	var payload = TerminalPane.build_paste_payload("a\u001bb", true)
	assert_eq(payload, "\u001b[200~a\u001bb\u001b[201~")

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
