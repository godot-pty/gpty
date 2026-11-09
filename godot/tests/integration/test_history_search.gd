extends GutTest
# History (FTS5) search from the pane.
#
# Two failures this defends against, both silent before:
#   1. Raw FTS5 syntax rejected ordinary search text — `main.rs` is a syntax
#      error near ".", `error: x` is read as a column filter, `warning:` and
#      `*` fail too — and every rejection came back as an empty result list,
#      indistinguishable from "no match". Live regex search accepts all of
#      them, which is why the two scopes disagreed.
#   2. The panel only appeared when there were results, so a failed query, a
#      pane with no stored history, and a genuine no-match all looked the
#      same: nothing at all.

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

var _ws: Control

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
	MockAutoloads.teardown()

## A workspace with one running terminal whose history holds MARKER.
func _pane_with_marker() -> Control:
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame
	var body = ws._tm._find_body(ws._tm.tiles[0].wrapper)
	body._terminal.send_line("echo HISTSEARCH_MARKER")
	await get_tree().create_timer(1.2).timeout
	# The search box only renders results in the History scope.
	body._search_visible = true
	body._scope_history = true
	return body

func test_punctuated_queries_find_stored_lines():
	var body = await _pane_with_marker()
	# Each of these is rejected by raw FTS5 MATCH.
	for pattern in ["HISTSEARCH_MARKER", "HISTSEARCH_MARKER:", "echo HISTSEARCH_MARKER"]:
		body._do_history_search(pattern)
		assert_gt(
			body._history_results.size(), 0,
			"'%s' must find the stored line, not silently return nothing" % pattern
		)
	assert_eq(body._search_error, "", "a findable query must not report an error")
	await get_tree().create_timer(2.1).timeout

func test_no_match_explains_itself():
	var body = await _pane_with_marker()
	body._do_history_search("zzz_no_such_text_zzz")
	assert_eq(body._history_results.size(), 0)
	assert_true(
		body._history_panel.visible,
		"the panel must appear to explain the empty result"
	)
	assert_gt(
		body._history_list.get_child_count(), 0,
		"an explanation row must be present when nothing matches"
	)
	await get_tree().create_timer(2.1).timeout

func test_unsearchable_input_is_not_an_error():
	# Punctuation-only input reduces to no terms: empty, but not a failure.
	var body = await _pane_with_marker()
	body._do_history_search("*")
	assert_eq(body._history_results.size(), 0)
	assert_eq(body._search_error, "", "punctuation-only input is an empty search, not an error")
	await get_tree().create_timer(2.1).timeout


# ── The keyboard path through the History scope ─────────────────────────
#
# The rows were `FOCUS_NONE` buttons: a hit could only be copied with the
# pointer, and Up/Down in the field fell through to `_handle_keyboard`, which
# sent an arrow sequence to the child and snapped the view to the bottom. Every
# key here goes through `Input.parse_input_event`, so the focus owner and the
# viewport's own routing are part of what is asserted.

## Dispatch one key press and release through the real input path.
func _press_key(keycode: Key, ctrl := false, shift := false) -> void:
	var down := InputEventKey.new()
	down.keycode = keycode
	down.physical_keycode = keycode
	down.ctrl_pressed = ctrl
	down.shift_pressed = shift
	down.pressed = true
	Input.parse_input_event(down)
	Input.flush_buffered_events()
	await get_tree().process_frame
	var up: InputEventKey = down.duplicate()
	up.pressed = false
	Input.parse_input_event(up)
	Input.flush_buffered_events()
	await get_tree().process_frame

## A pane whose stored history holds MARKER, with the strip really open (the
## strip node visible, the field focused) and two History rows staged directly,
## so the cursor and copy paths run without a store round-trip.
func _history_rows_pane() -> Control:
	var body = await _pane_with_marker()
	_ws.size = Vector2(1200, 800)
	# `_pane_with_marker` stages the flags only; open for real so the strip is
	# visible and its field can own the keyboard.
	body._search_visible = false
	body._search_strip.visible = false
	body._toggle_search()
	body._history_results = [[11, "first hit"], [12, "second hit"]]
	body._rebuild_history_panel()
	await get_tree().process_frame
	return body

## A pane with enough output to scroll back into, strip open on the Live scope.
func _scrolled_pane() -> Control:
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame
	var body = ws._tm._find_body(ws._tm.tiles[0].wrapper)
	for i in 120:
		body._terminal.send_line("echo scrollline %d" % i)
	var deadline := Time.get_ticks_msec() + 20000
	while body._terminal.get_history_size() < 20 and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	# Wait for the child to stop printing. A scrolled-back pane anchors its view
	# to the output it holds - a line appended between the scroll and the key
	# moves the offset by that many lines - so the assertion below only means
	# something once nothing more is arriving (measured on windows-smoke: the
	# offset doubled 44 -> 88 while cmd.exe was still flushing).
	var quiescent := 0
	var last_size := -1
	var quiet_deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < quiet_deadline and quiescent < 6:
		var size_now: int = body._terminal.get_history_size()
		if size_now == last_size:
			quiescent += 1
		else:
			quiescent = 0
			last_size = size_now
		await get_tree().create_timer(0.05).timeout
	body._search_visible = false
	body._search_strip.visible = false
	body._toggle_search()
	return body

func test_the_result_rows_are_tab_stops_and_the_arrows_move_the_cursor():
	var body = await _history_rows_pane()
	var rows: Array[Button] = body._history_row_buttons()
	assert_eq(rows.size(), 2, "the two staged hits are two rows")
	for row in rows:
		assert_ne(row.focus_mode, Control.FOCUS_NONE,
			"a result row must be reachable without the pointer")
	assert_eq(body._history_cursor, -1, "nothing is selected until the first step")
	await _press_key(KEY_DOWN)
	assert_eq(body._history_cursor, 0, "Down from the field selects the first hit")
	assert_true(rows[0].button_pressed, "the cursor is the row's selected treatment")
	await _press_key(KEY_DOWN)
	assert_eq(body._history_cursor, 1)
	await _press_key(KEY_DOWN)
	assert_eq(body._history_cursor, 1, "the end of the list is a stop, not a wrap")
	await _press_key(KEY_UP)
	assert_eq(body._history_cursor, 0)
	assert_false(rows[1].button_pressed, "moving off a row clears its selected treatment")
	await get_tree().create_timer(2.1).timeout

func test_enter_copies_the_cursor_row_and_escape_closes_the_strip():
	var body = await _history_rows_pane()
	var toasts: Array = []
	var record := func(data: Dictionary) -> void: toasts.append(str(data.get("text", "")))
	ToastManager.toast_requested.connect(record)
	await _press_key(KEY_DOWN)
	await _press_key(KEY_ENTER)
	assert_eq(toasts.size(), 1, "Enter copies exactly the row the cursor shows")
	assert_eq(toasts[0], "Copied line 11")
	await _press_key(KEY_ESCAPE)
	assert_false(body._search_visible, "Escape closes the strip")
	assert_true(body.has_focus(), "and hands the keyboard back to the pane")
	ToastManager.toast_requested.disconnect(record)
	await get_tree().create_timer(2.1).timeout

func test_up_from_an_unselected_list_starts_at_the_last_row():
	var body = await _history_rows_pane()
	await _press_key(KEY_UP)
	assert_eq(body._history_cursor, 1, "Up from nothing selects the last row")
	await get_tree().create_timer(2.1).timeout

func test_a_focused_row_moves_the_cursor_with_the_arrows():
	var body = await _history_rows_pane()
	var rows: Array[Button] = body._history_row_buttons()
	rows[0].grab_focus()
	await get_tree().process_frame
	assert_eq(body._history_cursor, 0, "focusing a row makes it the cursor")
	await _press_key(KEY_DOWN)
	assert_same(get_viewport().gui_get_focus_owner(), rows[1],
		"Down on a focused row moves focus to the next row")
	assert_eq(body._history_cursor, 1, "and the cursor follows the focus")
	await _press_key(KEY_UP)
	assert_same(get_viewport().gui_get_focus_owner(), rows[0])
	assert_eq(body._history_cursor, 0)
	await get_tree().create_timer(2.1).timeout

## The reported defect: Up/Down in the field reached the pane's keymap, which
## sent an arrow to the child and reset the scroll. The view offset is the
## observable of that second half — and it is the half a user sees.
func test_the_arrows_never_reach_the_child_while_the_strip_is_open():
	var body = await _scrolled_pane()
	assert_gt(body._terminal.get_history_size(), 20, "the pane has scrollback to lose")
	body._note_view_input()
	body._terminal.scroll_up(20)
	await get_tree().process_frame
	var offset: int = body._terminal.get_scroll_offset()
	assert_gt(offset, 0, "the view is scrolled back")
	await _press_key(KEY_UP)
	var after: int = body._terminal.get_scroll_offset()
	assert_gt(after, 0,
		"an arrow in the strip must not reach the child and snap the view to the bottom")
	assert_eq(after, offset,
		"no output arrived during the key, so the view cannot have been anchored forward")
	await get_tree().create_timer(2.1).timeout
