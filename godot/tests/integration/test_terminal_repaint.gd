extends GutTest
# The terminal's paint is split into per-row canvas layers so a partial grid
# update repaints only the rows its damage covers. Godot rebuilds a
# CanvasItem's whole command list on any `queue_redraw()`, so the split is the
# only way to make a one-line change cost one line.
#
# Defends three things that would fail silently:
#   - a band that paints another row (a stale line on screen),
#   - a band with its own transform (the text server picks the glyph raster
#     from the pen position, so a shifted item repaints every glyph with a
#     different antialiasing than the single-canvas pass did),
#   - a partial update that queues the whole grid anyway (the cost the split
#     exists to remove).

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

## The pane's shell is up and has produced output.
const SHELL_READY_MS := 30000

## The fixture's own process, plus the pane's sync cadence.
const OUTPUT_WAIT_MS := 20000

class ProbePane:
	extends TerminalPane

var _probe: ProbePane
var _ws: Control

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()
	_probe = ProbePane.new()

func after_each():
	if _probe:
		if _probe._terminal:
			_probe._terminal.free()
		_probe.free()
	_probe = null
	if _ws:
		if _ws.get_parent():
			_ws.get_parent().remove_child(_ws)
		_ws.free()
		_ws = null
	MockAutoloads.teardown()

## A synthetic packed cache: the grep of `_sync_layers` and `_repaint_rows` does
## not need a PTY, and a literal cache is what makes the row layout assertable.
func _seed_cache(rows: int, cols: int) -> void:
	var line := "x".repeat(cols)
	var chars: Array = []
	var fg := PackedColorArray()
	var bg := PackedColorArray()
	var attrs := PackedInt32Array()
	for _r in rows:
		chars.append(line)
		for _c in cols:
			fg.append(Color.WHITE)
			bg.append(Color.BLACK)
			attrs.append(0)
	_probe._cell_w = 9.0
	_probe._cell_h = 18.0
	_probe.size = Vector2(200.0, 200.0)
	_probe._cell_cache = {
		"is_full": true, "rows": rows, "cols": cols,
		"chars": chars, "fg": fg, "bg": bg, "attrs": attrs,
	}

func test_a_full_repaint_lays_out_one_background_and_one_text_band_per_row():
	_seed_cache(4, 10)
	_probe._repaint_all()
	assert_eq(_probe._row_backgrounds.size(), 4, "one background band per row")
	assert_eq(_probe._row_texts.size(), 4, "one text band per row")
	for i in 4:
		assert_eq(_probe._row_backgrounds[i].row, i, "a background band paints its own row")
		assert_eq(_probe._row_texts[i].row, i, "a text band paints its own row")
		assert_eq(_probe._row_backgrounds[i].position, Vector2.ZERO,
			"a band must not shift the text: the pen position sets the glyph raster")
		assert_eq(_probe._row_texts[i].position, Vector2.ZERO,
			"a band must not shift the text: the pen position sets the glyph raster")
		assert_eq(_probe._row_backgrounds[i].get_index(), i, "background bands come first, in row order")
		assert_eq(_probe._row_texts[i].get_index(), 4 + i, "every text band paints above every background")
	assert_eq(_probe._overlay.get_index(), 8, "the overlay paints above the bands")
	assert_eq(Array(_probe._painted_rows), [0, 1, 2, 3], "a full repaint queues every row")

func test_a_smaller_grid_frees_the_extra_bands_and_keeps_the_order():
	_seed_cache(4, 10)
	_probe._repaint_all()
	_seed_cache(2, 10)
	_probe._repaint_all()
	assert_eq(_probe._row_backgrounds.size(), 2, "a smaller grid frees the extra background bands")
	assert_eq(_probe._row_texts.size(), 2, "a smaller grid frees the extra text bands")
	assert_eq(_probe._overlay.get_index(), 4, "the overlay stays above the remaining bands")
	assert_eq(Array(_probe._painted_rows), [0, 1], "the repaint covers the grid it holds")

func test_a_partial_update_queues_only_the_rows_it_damages():
	_seed_cache(4, 10)
	_probe._repaint_all()
	_probe._repaint_rows({2: true, 5: true})
	assert_eq(Array(_probe._painted_rows), [2, 5],
		"only the damaged rows are queued - 5 is past the grid and is skipped when drawn")
	_probe._repaint_row(9)
	assert_eq(Array(_probe._painted_rows), [2, 5],
		"a repaint past the last band records nothing")

## The end-to-end half: a real shell, a typed line, and the sync that consumes
## its damage. The repaint must cover every row whose text changed and stay a
## handful of rows - never the grid.
##
## It must NOT assert that the repainted rows are the cursor's: ConPTY rewrites
## the rows it relays, so a typed line there damaged rows 0, 3, 4 and 6 with the
## cursor on 6 and still repainted 4 of 20 (Windows CI, 2026-11-13). The
## platform-neutral direction is text-changed => repainted.
func test_a_typed_line_repaints_only_the_rows_it_changed():
	var body = await _pane_with_a_shell()
	if body == null:
		return
	# The pane's own resize debounce produces one full sync; wait for it to
	# settle so the sync the typing lands in cannot be that one.
	var settled_gen := await _settle(body)
	var rows_total: int = int(body._cell_cache.get("rows", 0))
	assert_gte(rows_total, 10, "the pane needs a real grid: %s" % _pane_state(body))
	var before: Array = body._cell_cache["chars"].duplicate()
	body._send_line_to_term("echo REPAINT_MARKER")
	var deadline := Time.get_ticks_msec() + OUTPUT_WAIT_MS
	while Time.get_ticks_msec() < deadline and body._last_grid_gen == settled_gen:
		await get_tree().create_timer(0.05).timeout
	assert_ne(body._last_grid_gen, settled_gen,
		"the typed line must reach the pane: %s" % _pane_state(body))
	var after: Array = body._cell_cache["chars"]
	var changed: Array[int] = []
	for r in mini(before.size(), after.size()):
		if str(before[r]) != str(after[r]):
			changed.append(r)
	assert_gt(changed.size(), 0, "the typed line must change at least one row: %s" % _pane_state(body))
	var painted: PackedInt32Array = body._painted_rows
	assert_lte(painted.size(), 4,
		"one typed line must not repaint the screen (%d of %d rows)" % [painted.size(), rows_total])
	for r in changed:
		assert_true(painted.has(r),
			"a row whose text changed must be repainted (row %d, painted %s)" % [r, str(painted)])
	# The bands are children of the pane, so their order against the pane's own
	# chrome decides what covers what: every band must sit below the search
	# strip and the scroll hints, or the grid paints over them.
	assert_lt(body._row_texts.back().get_index(), body._search_strip.get_index(),
		"every band must sit below the search strip")

## A workspace with one terminal whose shell is ready to run a fixture line.
##
## The startup pane is closed so the file leaves one pane per test, matching
## `test_inverse_paint.gd`: every pane keeps a history writer on the run's
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

## Wait until the pane's own sync has been quiet for 10 frames, and answer the
## generation it settled on.
func _settle(body: Control) -> int:
	var last: int = body._last_grid_gen
	var stable := 0
	var deadline := Time.get_ticks_msec() + OUTPUT_WAIT_MS
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		if body._last_grid_gen == last:
			stable += 1
			if stable >= 10:
				return last
		else:
			stable = 0
			last = body._last_grid_gen
	return last

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

## What the pane holds when an assertion gives up.
func _pane_state(body: Control) -> String:
	var grid := str(body._terminal.get_plain_text(2000))
	if grid.length() > 400:
		grid = grid.substr(grid.length() - 400)
	return "grid=%s cache_empty=%s" % [grid.replace("\n", "\\n"), body._cell_cache.is_empty()]
