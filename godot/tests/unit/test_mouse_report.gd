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
	var cell := Vector2i(2, 1)  # 0-based; the protocol reports (3, 2)

	func _mouse_mode() -> int:
		return mode

	func _mouse_to_cell(_pos: Vector2) -> Vector2i:
		return cell

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

## The expected bytes below are written from the xterm control-sequence
## spec (Cb = button + 32 for a motion report), not derived from the encoder:
## this test used to expect a drag to be byte-for-byte a press (`<0;3;2M`), so
## it passed while an app under 1002 could not tell a drag from a click.
func test_drag_mode_reports_motion_while_a_button_is_held():
	_probe.mode = TerminalPane.MOUSE_MODE_DRAG
	_probe._handle_mouse(_motion(MOUSE_BUTTON_MASK_LEFT))
	# Cb = 0 (left) + 32 (motion) = 32, sent as 32 + 32 = 64 ('@').
	assert_eq(
		_probe.sent, ESC + "[M" + char(64) + char(35) + char(34),
		"1002 reports the drag in the legacy form when 1006 is off")

	_probe.sent = ""
	_probe.mode = TerminalPane.MOUSE_MODE_DRAG | TerminalPane.MOUSE_MODE_SGR
	_probe._handle_mouse(_motion(MOUSE_BUTTON_MASK_LEFT))
	assert_eq(_probe.sent, ESC + "[<32;3;2M", "SGR form when 1006 is on")

func test_a_drag_is_distinguishable_from_the_press_that_started_it():
	_probe.mode = TerminalPane.MOUSE_MODE_DRAG | TerminalPane.MOUSE_MODE_SGR
	_probe._handle_mouse(_press(MOUSE_BUTTON_LEFT))
	var press := _probe.sent
	_probe.sent = ""
	_probe._handle_mouse(_motion(MOUSE_BUTTON_MASK_LEFT))
	assert_ne(_probe.sent, press, "an app must be able to tell motion from a press")
	assert_eq(press, ESC + "[<0;3;2M", "the press itself carries no motion bit")

func test_drag_reports_the_button_that_is_held():
	_probe.mode = TerminalPane.MOUSE_MODE_DRAG | TerminalPane.MOUSE_MODE_SGR
	_probe._handle_mouse(_motion(MOUSE_BUTTON_MASK_MIDDLE))
	assert_eq(_probe.sent, ESC + "[<33;3;2M", "middle (1) + motion (32)")
	_probe.sent = ""
	_probe._handle_mouse(_motion(MOUSE_BUTTON_MASK_RIGHT))
	assert_eq(_probe.sent, ESC + "[<34;3;2M", "right (2) + motion (32)")

func test_motion_mode_reports_a_buttonless_move():
	_probe.mode = TerminalPane.MOUSE_MODE_MOTION | TerminalPane.MOUSE_MODE_SGR
	_probe._handle_mouse(_motion(0))
	assert_eq(_probe.sent, ESC + "[<35;3;2M",
		"1003 reports motion with no button: 3 (none) + 32 (motion)")

func test_drag_mode_ignores_a_buttonless_move():
	_probe.mode = TerminalPane.MOUSE_MODE_DRAG | TerminalPane.MOUSE_MODE_SGR
	_probe._handle_mouse(_motion(0))
	assert_eq(_probe.sent, "", "1002 reports only moves with a button held")

func test_a_cell_outside_the_grid_is_not_reported():
	var outside := MouseProbePane.new()
	outside._terminal = ClassDB.instantiate("GptyTerminal")
	outside.mode = TerminalPane.MOUSE_MODE_CLICK | TerminalPane.MOUSE_MODE_SGR
	outside.cell = Vector2i(-1, 1)
	outside._handle_mouse(_press(MOUSE_BUTTON_LEFT))
	assert_eq(outside.sent, "", "a negative cell is the pointer outside the grid")
	outside._terminal.free()
	outside.free()

func test_a_button_outside_the_protocol_is_not_reported():
	_probe.mode = TerminalPane.MOUSE_MODE_CLICK | TerminalPane.MOUSE_MODE_SGR
	_probe._handle_mouse(_press(MOUSE_BUTTON_XBUTTON1))
	assert_eq(_probe.sent, "", "the protocol has no code for a side button")

func test_wheel_directions_map_to_64_to_67():
	_probe.mode = TerminalPane.MOUSE_MODE_CLICK | TerminalPane.MOUSE_MODE_SGR
	var expected := {
		MOUSE_BUTTON_WHEEL_UP: 64, MOUSE_BUTTON_WHEEL_DOWN: 65,
		MOUSE_BUTTON_WHEEL_LEFT: 66, MOUSE_BUTTON_WHEEL_RIGHT: 67,
	}
	for button in expected:
		_probe.sent = ""
		_probe._handle_mouse(_press(button))
		assert_eq(_probe.sent, ESC + "[<%d;3;2M" % expected[button], "wheel %d" % button)

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

func test_motion_adds_32_to_the_button_in_both_encodings():
	assert_eq(
		TerminalPane.encode_mouse_report(_sgr(), false, 0, Vector2i(4, 3), 0, true),
		ESC + "[<32;4;3M", "left drag, SGR")
	assert_eq(
		TerminalPane.encode_mouse_report(
			TerminalPane.MOUSE_MODE_CLICK, false, 0, Vector2i(1, 2), 0, true),
		ESC + "[M" + char(64) + char(33) + char(34), "left drag, legacy: 32 + 32 + 0")

func test_motion_stacks_with_modifiers():
	assert_eq(
		TerminalPane.encode_mouse_report(
			_sgr(), false, 0, Vector2i(1, 1), TerminalPane.MOD_CTRL, true),
		ESC + "[<48;1;1M", "left (0) + ctrl (16) + motion (32)")

func test_a_motion_report_is_never_a_release():
	# 1003 with no button held is the one report that carries button 3 on a
	# press-form final; it must stay `M`, never the release's lowercase `m`.
	assert_eq(
		TerminalPane.encode_mouse_report(
			_sgr(), false, TerminalPane.NO_BUTTON, Vector2i(1, 1), 0, true),
		ESC + "[<35;1;1M")

func test_legacy_drops_cells_past_its_addressing_range():
	assert_eq(
		TerminalPane.encode_mouse_report(
			TerminalPane.MOUSE_MODE_CLICK, false, 0,
			Vector2i(TerminalPane.LEGACY_CELL_MAX + 1, 1), 0),
		"", "the X10 form cannot express that cell — drop it, do not clamp")
