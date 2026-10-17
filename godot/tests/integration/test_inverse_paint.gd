extends GutTest
# The packed cache a terminal pane draws from is paint-ready: SGR 7 (inverse)
# has already been resolved in core (`CellInfo::paint_colors`) before the
# colors are packed, so the renderer draws `fg` on `bg` and never swaps a cell
# itself. That is the shape bash's readline gives a bracketed paste — it wraps
# the echo in `ESC[7m`/`ESC[27m` — and swapping only the glyph color painted
# pasted text in its own background: blank cells with the cursor advancing,
# until the next arrow key made readline repaint the line unhighlighted.
# Reported by the user 2026-10.
#
# The assertion is on the cache the pane actually receives, not a copy of the
# core rule: a normal cell after the inverse span tells us what the palette's
# two colors are, and the inverse cell must carry exactly the other pairing.

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

## The pane's shell is up and has produced output.
const SHELL_READY_MS := 30000

## The fixture's own process, plus the pane's sync cadence.
const OUTPUT_WAIT_MS := 20000

const MARKER := "INVERSE"

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

func test_inverse_cells_reach_the_packed_cache_paint_ready():
	var body = await _pane_with_a_shell()
	if body == null:
		return
	body._terminal.send_line(
		ShellFixtures.print_text("\u001b[7mI\u001b[27mNVERSE\n")
	)
	var row := await _wait_for_cache_row(body, MARKER)
	assert_gte(row, 0, "the fixture's output must reach the pane's packed cache: %s" % _pane_state(body))
	if row < 0:
		return
	var cache: Dictionary = body._cell_cache
	var cols: int = cache["cols"]
	var fg: PackedColorArray = cache["fg"]
	var bg: PackedColorArray = cache["bg"]
	var inverse := row * cols
	var plain := inverse + 1
	assert_eq(fg[inverse], bg[plain], "inverse text is drawn in the normal background color")
	assert_eq(bg[inverse], fg[plain], "inverse background is drawn in the normal text color")
	assert_ne(fg[inverse], bg[inverse], "a glyph must never be painted in its own background")

## A workspace with one terminal whose shell is ready to run a fixture line.
##
## The startup pane is closed so the file leaves one pane per test, matching
## `test_bracketed_paste.gd`: every pane keeps a history writer on the run's
## single SQLite store, and two per test is what pushed a later file's append
## past the store's lock wait.
func _pane_with_a_shell() -> Control:
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame
	var body = ws._spawn_pane("terminal", {})
	assert_not_null(body, "the file needs a terminal pane")
	if body == null:
		return null
	var startup = ws._tm._find_body(ws._tm.tiles[0].wrapper)
	if startup != null and startup != body:
		ws._tm.kill(startup)
	assert_true(
		await _wait_for_shell_output(body, SHELL_READY_MS),
		"the pane's shell must print before a line is typed into it: %s" % _pane_state(body)
	)
	return body

## `idle_ms` is stamped by the first PTY bytes the child writes, so it says
## the shell is running rather than that a spawn was requested.
func _wait_for_shell_output(body: Control, timeout_ms: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		var status = JSON.parse_string(str(body._terminal.get_status()))
		if status is Dictionary and status.get("idle_ms") != null:
			return true
		await get_tree().create_timer(0.05).timeout
	return false

## Row of the packed cache that holds `marker`, once the pane's own `_process`
## has merged it — the sync is what this test is about, so waiting on the grid
## alone would read a cache that has not caught up.
func _wait_for_cache_row(body: Control, marker: String) -> int:
	var deadline := Time.get_ticks_msec() + OUTPUT_WAIT_MS
	while Time.get_ticks_msec() < deadline:
		if not body._cell_cache.is_empty():
			var chars: Array = body._cell_cache["chars"]
			for r in chars.size():
				if str(chars[r]).contains(marker):
					return r
		await get_tree().create_timer(0.05).timeout
	return -1

## What the pane holds when an assertion gives up.
func _pane_state(body: Control) -> String:
	var grid := str(body._terminal.get_plain_text(2000))
	if grid.length() > 400:
		grid = grid.substr(grid.length() - 400)
	return "grid=%s cache_empty=%s" % [grid.replace("\n", "\\n"), body._cell_cache.is_empty()]
