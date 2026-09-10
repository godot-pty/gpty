extends GutTest
# Unit tests for terminal mouse reporting: which events go to the child
# process when it tracks the mouse (DECSET 1000/1002/1003), and the exact
# bytes they are encoded as (SGR 1006, or the legacy X10 form).
#
# The probe pane stays out of the tree, so _ready() never runs: the terminal
# is created directly and the pane's FFI reads are stubbed. Same pattern as
# test_cursor_blink / test_flood_cadence.

const ESC := "\u001b"

var _probe: MouseProbePane

class MouseProbePane:
	extends TerminalPane

	var sent := ""
	var mode := 0

	func _mouse_mode() -> int:
		return mode

	func _mouse_to_cell(_pos: Vector2) -> Vector2i:
		return Vector2i(2, 1)  # 0-based; the protocol reports (3, 2)

	func _send_to_term(text: String):
		sent += text

func before_each():
	_probe = MouseProbePane.new()
	_probe._terminal = ClassDB.instantiate("GptyTerminal")

func after_each():
	if _probe:
		if _probe._terminal:
			_probe._terminal.free()
		_probe.free()
	_probe = null

func _press(button: int, shift := false) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = button as MouseButton
	event.pressed = true
	event.shift_pressed = shift
	event.position = Vector2.ZERO
	return event

func _release(button: int) -> InputEventMouseButton:
	var event := _press(button)
	event.pressed = false
	return event

func _motion(mask: int) -> InputEventMouseMotion:
	var event := InputEventMouseMotion.new()
	event.button_mask = mask as MouseButtonMask
	event.position = Vector2.ZERO
	return event

# ── Routing: what the pane hands to the app ────────────────────────────

func test_click_mode_reports_presses_but_not_drags():
	_probe.mode = TerminalPane.MOUSE_MODE_CLICK
	_probe._handle_mouse(_press(MOUSE_BUTTON_LEFT))
	assert_eq(_probe.sent, ESC + "[M" + char(32) + char(35) + char(34),
		"press must reach the app")

	_probe.sent = ""
	_probe._handle_mouse(_motion(MOUSE_BUTTON_MASK_LEFT))
	assert_eq(_probe.sent, "", "1000 does not report motion — a drag still selects")

func test_drag_mode_reports_motion_while_a_button_is_held():
	_probe.mode = TerminalPane.MOUSE_MODE_DRAG
	_probe._handle_mouse(_motion(MOUSE_BUTTON_MASK_LEFT))
	assert_eq(
		_probe.sent, ESC + "[M" + char(32) + char(35) + char(34),
		"1002 reports the drag in the legacy form when 1006 is off")

	_probe.sent = ""
	_probe.mode = TerminalPane.MOUSE_MODE_DRAG | TerminalPane.MOUSE_MODE_SGR
	_probe._handle_mouse(_motion(MOUSE_BUTTON_MASK_LEFT))
	assert_eq(_probe.sent, ESC + "[<0;3;2M", "SGR form when 1006 is on")

func test_motion_mode_reports_a_buttonless_move():
	_probe.mode = TerminalPane.MOUSE_MODE_MOTION | TerminalPane.MOUSE_MODE_SGR
	_probe._handle_mouse(_motion(0))
	assert_eq(_probe.sent, ESC + "[<3;3;2M", "1003 reports motion with no button")

func test_wheel_is_reported_in_any_tracking_mode():
	_probe.mode = TerminalPane.MOUSE_MODE_CLICK | TerminalPane.MOUSE_MODE_SGR
	_probe._handle_mouse(_press(MOUSE_BUTTON_WHEEL_UP))
	assert_eq(_probe.sent, ESC + "[<64;3;2M", "wheel up is button 64")

	_probe.sent = ""
	_probe._handle_mouse(_release(MOUSE_BUTTON_WHEEL_UP))
	assert_eq(_probe.sent, "", "a wheel release is swallowed, not reported")

func test_shift_bypasses_reporting():
	_probe.mode = TerminalPane.MOUSE_MODE_CLICK
	_probe._handle_mouse(_press(MOUSE_BUTTON_LEFT, true))
	assert_eq(_probe.sent, "", "shift-click must stay local (selection)")
	assert_true(_probe._selecting, "the pane selects instead of reporting")

func test_no_tracking_leaves_the_mouse_to_the_pane():
	_probe.mode = 0
	_probe._handle_mouse(_press(MOUSE_BUTTON_LEFT))
	assert_eq(_probe.sent, "")
	assert_true(_probe._selecting)

# ── Encoding ──────────────────────────────────────────────────────────

func _sgr() -> int:
	return TerminalPane.MOUSE_MODE_CLICK | TerminalPane.MOUSE_MODE_SGR

func test_sgr_press_carries_button_and_1_based_cell():
	assert_eq(
		TerminalPane.encode_mouse_report(_sgr(), false, 0, Vector2i(4, 3), 0),
		ESC + "[<0;4;3M")

func test_sgr_release_uses_the_lowercase_final():
	assert_eq(
		TerminalPane.encode_mouse_report(_sgr(), true, 2, Vector2i(1, 1), 0),
		ESC + "[<2;1;1m")

func test_modifiers_add_4_8_and_16():
	assert_eq(
		TerminalPane.encode_mouse_report(
			_sgr(), false, 1, Vector2i(1, 1),
			TerminalPane.MOD_SHIFT | TerminalPane.MOD_ALT | TerminalPane.MOD_CTRL),
		ESC + "[<29;1;1M", "1 + shift(4) + alt(8) + ctrl(16)")

func test_legacy_press_offsets_button_and_cell_by_32():
	var expected := ESC + "[M" + char(32) + char(33) + char(34)
	assert_eq(
		TerminalPane.encode_mouse_report(
			TerminalPane.MOUSE_MODE_CLICK, false, 0, Vector2i(1, 2), 0),
		expected)

func test_legacy_release_reports_button_3_plus_modifiers():
	var expected := ESC + "[M" + char(32 + 3 + 4) + char(33) + char(33)
	assert_eq(
		TerminalPane.encode_mouse_report(
			TerminalPane.MOUSE_MODE_CLICK, true, 0, Vector2i(1, 1),
			TerminalPane.MOD_SHIFT),
		expected)

func test_legacy_drops_cells_past_its_addressing_range():
	assert_eq(
		TerminalPane.encode_mouse_report(
			TerminalPane.MOUSE_MODE_CLICK, false, 0,
			Vector2i(TerminalPane.LEGACY_CELL_MAX + 1, 1), 0),
		"", "the X10 form cannot express that cell — drop it, do not clamp")
