extends GutTest
# The scrollback-return chevron.
# Defends: a view scrolled off live output says so in a way the user can act on
# with one press, the press never reaches a child that owns the mouse, and the
# selection survives the jump (it is grid-space, so it must).

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

var _ws: Control
var _probe: ScrollProbe

## A pane whose child claims the mouse (DECSET 1000). The click has to be taken
## by the chevron itself; `_send_to_term` records anything that would have
## reached the reporting path instead.
class ScrollProbe extends TerminalPane:
	var sent: Array = []
	func _mouse_mode() -> int:
		return MOUSE_MODE_CLICK
	func _send_to_term(text: String) -> bool:
		sent.append(text)
		return true

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()
	SettingsManager.cfg_history_lines = 1000

func after_each():
	if _ws:
		if _ws.get_parent():
			_ws.get_parent().remove_child(_ws)
		_ws.free()
		_ws = null
	if _probe:
		if _probe.get_parent():
			_probe.get_parent().remove_child(_probe)
		_probe.free()
		_probe = null
	MockAutoloads.teardown()

## Poll a predicate up to six seconds: the child's output is the only thing that
## makes scrollback, and how fast it arrives is the shell's business.
func _wait_for(predicate: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + 6000
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await get_tree().create_timer(0.05).timeout
	return false

## A workspace with one running terminal that has scrollback to leave.
func _pane_with_scrollback() -> Control:
	_ws = WorkspaceScript.new()
	add_child(_ws)
	_ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame
	var body = _ws._tm._find_body(_ws._tm.tiles[0].wrapper)
	body._terminal.send_line("seq 1 100")
	var filled := await _wait_for(func(): return body._terminal.get_history_size() > 30)
	assert_true(filled, "the pane needs scrollback before the view can leave live output")
	return body

func test_the_chevron_shows_only_while_the_view_is_scrolled_back():
	var body = await _pane_with_scrollback()
	body._terminal.scroll_up(10)
	await get_tree().create_timer(0.15).timeout
	assert_gt(body._terminal.get_scroll_offset(), 0, "the view left live output")
	assert_true(body._scroll_hints.bottom_button.visible, "the chevron follows the offset")
	body._snap_to_bottom()
	await get_tree().create_timer(0.15).timeout
	assert_false(body._scroll_hints.bottom_button.visible, "back at live output, the chevron hides")

func test_a_click_returns_to_live_output_and_keeps_the_selection():
	var body = await _pane_with_scrollback()
	body._terminal.selection_start(0, 0)
	body._terminal.selection_extend(1, 5)
	var selected: String = body._terminal.get_selection_text()
	assert_ne(selected, "", "the test needs a selection to carry across the jump")
	body._terminal.scroll_up(10)
	assert_gt(body._terminal.get_scroll_offset(), 0)
	body._sync_scroll_hints()
	body._scroll_hints.bottom_button.pressed.emit()
	assert_eq(body._terminal.get_scroll_offset(), 0, "one press returns to live output")
	assert_eq(body._terminal.get_selection_text(), selected,
		"the selection is grid-space and survives the jump")
	# The chevron fades out; `visible` is still true while it is on screen.
	await get_tree().create_timer(0.15).timeout
	assert_false(body._scroll_hints.bottom_button.visible, "the control hides once its ramp ends")

func test_the_click_is_chrome_in_a_mouse_reporting_pane():
	_probe = ScrollProbe.new()
	_probe.size = Vector2(800, 480)
	add_child(_probe)
	await get_tree().process_frame
	assert_true(_probe._started, "the probe's child starts at a size that holds the grid")
	_probe._terminal.send_line("seq 1 100")
	var filled := await _wait_for(func(): return _probe._terminal.get_history_size() > 30)
	assert_true(filled, "the probe needs scrollback")
	_probe._terminal.selection_start(0, 0)
	_probe._terminal.selection_extend(1, 5)
	var selected: String = _probe._terminal.get_selection_text()
	_probe._terminal.scroll_up(10)
	_probe._sync_scroll_hints()
	assert_true(_probe._scroll_hints.bottom_button.visible)
	assert_eq(_probe._scroll_hints.bottom_button.mouse_filter, Control.MOUSE_FILTER_STOP,
		"the button takes the click, so it never reaches the reporting path")
	assert_eq(_probe._scroll_hints.bottom_button.focus_mode, Control.FOCUS_NONE,
		"the chevron never takes focus")
	assert_ne(KeyboardFocus.mouse_only_reason(_probe._scroll_hints.bottom_button), "",
		"the mouse-only control declares why the keyboard reaches the same end")
	_probe._scroll_hints.bottom_button.pressed.emit()
	assert_eq(_probe._terminal.get_scroll_offset(), 0)
	assert_eq(_probe.sent, [], "a chrome click sends nothing to the child")
	assert_eq(_probe._terminal.get_selection_text(), selected)

## Let the pane's shell finish producing: the up-chevron assertions compare an
## offset with `get_history_size()`, and a line arriving between the two calls
## would move the maximum under them.
func _wait_history_quiet(body) -> void:
	var last := -1
	var quiet := 0
	var deadline := Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < deadline:
		var size_now: int = body._terminal.get_history_size()
		if size_now == last:
			quiet += 1
			if quiet >= 3:
				return
		else:
			quiet = 0
		last = size_now
		await get_tree().create_timer(0.05).timeout

func test_the_up_chevron_reaches_the_oldest_line_and_hides():
	var body = await _pane_with_scrollback()
	await _wait_history_quiet(body)
	body._terminal.selection_start(0, 0)
	body._terminal.selection_extend(1, 5)
	var selected: String = body._terminal.get_selection_text()
	assert_ne(selected, "", "the test needs a selection to carry across the jump")
	body._terminal.scroll_up(10)
	await get_tree().create_timer(0.15).timeout
	assert_true(body._scroll_hints.top_button.visible,
		"scrollback above the view shows the up chevron")
	assert_true(body._scroll_hints.bottom_button.visible, "and live output is still below")
	body._scroll_hints.top_button.pressed.emit()
	assert_eq(body._terminal.get_scroll_offset(), body._terminal.get_history_size(),
		"one press lands on the oldest line the grid holds")
	# The chevron fades out; `visible` is still true while it is on screen.
	await get_tree().create_timer(0.15).timeout
	assert_false(body._scroll_hints.top_button.visible, "the control hides at the start")
	assert_true(body._scroll_hints.bottom_button.visible)
	assert_eq(body._terminal.get_selection_text(), selected,
		"the selection is grid-space and survives the jump")
	body._scroll_hints.bottom_button.pressed.emit()
	assert_eq(body._terminal.get_scroll_offset(), 0)
	await get_tree().create_timer(0.15).timeout
	assert_false(body._scroll_hints.bottom_button.visible, "live output hides the down chevron")
	assert_true(body._scroll_hints.top_button.visible,
		"scrollback above live output keeps the up chevron")

func test_the_up_chevron_hides_with_the_search_strip():
	var body = await _pane_with_scrollback()
	body._terminal.scroll_up(10)
	body._sync_scroll_hints()
	assert_true(body._scroll_hints.top_button.visible, "the up chevron is available first")
	body._toggle_search()
	await get_tree().create_timer(0.15).timeout
	assert_false(body._scroll_hints.top_button.visible,
		"the strip owns the top-right corner while it is open")
	body._close_search()
	# The strip fades out first, then its callback returns the chevron.
	await get_tree().create_timer(0.3).timeout
	assert_true(body._scroll_hints.top_button.visible, "closing the strip returns the chevron")

func test_the_search_strip_fades_in_and_out():
	var body = await _pane_with_scrollback()
	body._toggle_search()
	assert_true(body._search_strip.visible, "the strip is on screen at once")
	assert_lt(body._search_strip.modulate.a, 1.0, "and fades in")
	await get_tree().create_timer(0.15).timeout
	assert_almost_eq(body._search_strip.modulate.a, 1.0, 0.001)
	body._close_search()
	assert_true(body._search_strip.visible, "closing keeps it drawn while it fades")
	await get_tree().create_timer(0.15).timeout
	assert_false(body._search_strip.visible, "hidden once the ramp ends")

func test_a_search_keystroke_creates_no_arrival():
	var body = await _pane_with_scrollback()
	body._toggle_search()
	await get_tree().create_timer(0.15).timeout
	var rect: Rect2 = body._search_strip.get_global_rect()
	var pane_size: Vector2 = body.size
	body._search_bar.text = "1"
	body._search_bar.text_changed.emit("1")
	await get_tree().process_frame
	assert_almost_eq(body._search_strip.modulate.a, 1.0, 0.001,
		"a filter keystroke is an update, not an arrival")
	assert_eq(body._search_strip.get_global_rect(), rect, "the strip never moves on a keystroke")
	assert_eq(body.size, pane_size)

func test_the_scrollback_indicator_ramps():
	var body = await _pane_with_scrollback()
	var pane_size: Vector2 = body.size
	var first_row: Vector2 = body._row_texts[0].position
	body._terminal.scroll_up(10)
	body._sync_scroll_hints()
	assert_eq(body._indicator_target, 1.0, "the indicator wants to show")
	assert_lt(body._indicator_alpha, 1.0, "it fades in")
	assert_ne(body._indicator_text, "", "the readout is cached while visible")
	await get_tree().create_timer(0.15).timeout
	assert_almost_eq(body._indicator_alpha, 1.0, 0.001)
	var readout: String = body._indicator_text
	body._snap_to_bottom()
	assert_eq(body._indicator_target, 0.0, "live output wants it gone")
	await get_tree().create_timer(0.04).timeout
	assert_lt(body._indicator_alpha, 1.0, "the fade is under way")
	assert_eq(body._indicator_text, readout, "the readout does not flip to 0/N mid-fade")
	await get_tree().create_timer(0.15).timeout
	assert_almost_eq(body._indicator_alpha, 0.0, 0.001)
	assert_eq(body.size, pane_size, "the indicator is drawn, never laid out")
	assert_eq(body._row_texts[0].position, first_row)

func test_the_scrollback_indicator_is_static_at_off():
	SettingsManager.cfg_motion = UiMotion.OFF
	var body = await _pane_with_scrollback()
	body._terminal.scroll_up(10)
	body._sync_scroll_hints()
	assert_eq(body._indicator_alpha, 1.0, "Off draws the indicator final")
	body._snap_to_bottom()
	assert_eq(body._indicator_alpha, 0.0, "and removes it in one frame")
	SettingsManager.cfg_motion = UiMotion.SUBTLE
