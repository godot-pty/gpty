extends GutTest
# Integration tests: keyboard routing through the evdev keymap and the
# paste handler. Defends:
#   1. Printable ASCII keys no longer collide with special-key scancodes
#      ('z' → ESC O j, ';' → F1, '`' → KP_Enter) — they now route through
#      the unicode path and reach the PTY as themselves.
#   2. Paste is Ctrl+Shift+V only; plain Ctrl+V passes through to the
#      shell as a literal ^V (vim visual-block, readline quoted-insert).


class RecordingPane:
	extends TerminalPane

	var sent: Array[String] = []
	var sent_lines: Array[String] = []
	var clip := "clip-payload"

	func _send_to_term(text: String):
		sent.append(text)

	func _send_line_to_term(text: String):
		sent_lines.append(text)

	func _get_clipboard_text() -> String:
		return clip


var _pane: RecordingPane


func before_each():
	_pane = RecordingPane.new()
	# Real GptyTerminal for the keymap FFI; never started, so grid calls
	# (scroll_reset) are safe no-ops. Keyboard writes are captured by the
	# RecordingPane seams instead of reaching the PTY.
	_pane._terminal = ClassDB.instantiate("GptyTerminal")


func after_each():
	if _pane:
		_pane._terminal.free()
		_pane._terminal = null
		_pane.free()
	_pane = null


func _key_event(keycode: int, unicode: int, ctrl := false, shift := false, alt := false) -> InputEventKey:
	var ev = InputEventKey.new()
	ev.keycode = keycode
	ev.unicode = unicode
	ev.ctrl_pressed = ctrl
	ev.shift_pressed = shift
	ev.alt_pressed = alt
	ev.pressed = true
	return ev


func test_plain_z_reaches_unicode_path():
	_pane._handle_keyboard(_key_event(KEY_Z, 122))
	assert_eq(_pane.sent, ["z"], "plain 'z' must be sent as itself, not a keymap escape")


func test_shift_z_reaches_unicode_path():
	_pane._handle_keyboard(_key_event(KEY_Z, 90, false, true))
	assert_eq(_pane.sent, ["Z"], "shift 'Z' must be sent as itself")


func test_colliding_punctuation_keys():
	var cases := {
		KEY_SEMICOLON: ";", KEY_LESS: "<", KEY_EQUAL: "=", KEY_GREATER: ">",
		KEY_QUESTION: "?", KEY_AT: "@", KEY_QUOTELEFT: "`",
	}
	for keycode in cases:
		_pane.sent.clear()
		_pane._handle_keyboard(_key_event(keycode, cases[keycode].unicode_at(0)))
		assert_eq(_pane.sent, [cases[keycode]],
			"keycode %d must send '%s'" % [keycode, cases[keycode]])


func test_special_keys_still_mapped():
	# Positive controls: the printable guard must not break special keys.
	_pane._handle_keyboard(_key_event(KEY_LEFT, 0))
	assert_eq(_pane.sent, ["\u001b[D"], "Left arrow still maps to ESC[D")
	_pane.sent.clear()
	_pane._handle_keyboard(_key_event(KEY_F1, 0))
	assert_eq(_pane.sent, ["\u001b[P"], "F1 still maps through the keymap")


func test_enter_still_uses_send_line():
	_pane._handle_keyboard(_key_event(KEY_ENTER, 13))
	assert_eq(_pane.sent_lines, [""], "Enter still routes through the send_line seam")


func test_ctrl_z_sends_control_char():
	_pane._handle_keyboard(_key_event(KEY_Z, 0, true))
	assert_eq(_pane.sent, ["\u001a"], "Ctrl+Z sends SUB (0x1a)")


func test_ctrl_c_still_reaches_shell_as_sigint():
	_pane._handle_keyboard(_key_event(KEY_C, 0, true))
	assert_eq(_pane.sent, ["\u0003"], "plain Ctrl+C must not be intercepted by copy")


func test_ctrl_v_sends_literal_caret_v():
	_pane._gui_input(_key_event(KEY_V, 22, true))
	assert_eq(_pane.sent, ["\u0016"], "plain Ctrl+V passes through as literal ^V")


func test_ctrl_shift_v_pastes_clipboard():
	_pane._gui_input(_key_event(KEY_V, 22, true, true))
	assert_eq(_pane.sent, ["clip-payload"], "Ctrl+Shift+V pastes the clipboard")


func test_paste_works_on_second_pane():
	# The reported "works on first terminal only" symptom: paste must be
	# pane-local with no cross-pane state.
	var pane2 = RecordingPane.new()
	pane2._terminal = ClassDB.instantiate("GptyTerminal")
	pane2._gui_input(_key_event(KEY_V, 22, true, true))
	assert_eq(pane2.sent, ["clip-payload"], "second pane pastes independently")
	pane2._terminal.free()
	pane2.free()


func test_empty_clipboard_pastes_nothing():
	_pane.clip = ""
	_pane._gui_input(_key_event(KEY_V, 22, true, true))
	assert_eq(_pane.sent, [], "empty clipboard sends nothing (and not ^V)")


func test_ctrl_shift_c_copy_does_not_leak_control_char():
	# Regression: a missing `return` after the copy branch let execution
	# fall through to _key_to_text, sending a literal ^C to the shell.
	_pane._handle_keyboard(_key_event(KEY_C, 0, true, true))
	assert_eq(_pane.sent, [], "Ctrl+Shift+C must not send bytes to the shell")


func test_ctrl_shift_c_with_selection_copies_without_leaking():
	_pane._cell_cache = {"rows": 1, "cols": 3, "chars": ["abc"]}
	_pane._sel_start = Vector2i(0, 0)
	_pane._sel_end = Vector2i(0, 2)
	_pane._handle_keyboard(_key_event(KEY_C, 0, true, true))
	assert_eq(_pane.sent, [], "copy with selection must not send bytes to the shell")
