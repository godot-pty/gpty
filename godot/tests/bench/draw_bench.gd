extends SceneTree
# Draw-cost harness for the terminal renderer.
#
# Fills a terminal pane with a deterministic ANSI-rich screen (bold, italic,
# underline, inverse, wide characters, colors, plain text), saves the rendered
# viewport as a PNG so two revisions can be diffed pixel-for-pixel, and times
# the three repaint shapes against an idle frame:
#
#   forced_us   one full repaint of the grid (every row's bands + the overlay)
#   row_us      one row's bands (the partial-update path)
#   overlay_us  the layer above the rows (a cursor blink)
#
#   godot --path godot --disable-vsync -s res://tests/bench/draw_bench.gd
#
# A real display driver is required: under `--headless` there is no redraw pass
# and every timing reads zero. `--disable-vsync` matters because a vsync-locked
# present can block indefinitely on a window the compositor never shows.
#
#   BENCH_COLS, BENCH_ROWS  grid size (default 90×30)
#   BENCH_TAG               suffix of the saved PNG (default "run")
#   BENCH_FLOOD=1           a full-screen repaint loop instead of the static
#                           screen: every sync sees full-grid damage
#   BENCH_SPARSE=1          one line every 0.2 s instead: the case the row
#                           split exists for - a mostly-idle streamer whose
#                           repaint must not set the pane's settled cadence
#
# Both stream modes need `--max-fps 60` added when the question is the pane's
# cadence: unthrottled, the loop outruns the flood back-off and every frame
# syncs, which measures the cost but not the rate. They print `syncs`,
# `sync_hz`, `sync_us` (fetch + repaint of the syncs that found damage),
# `avg_rows` (rows repainted per damage sync, after the initial load),
# `avg_work_ms` and `backoff_ms`; the stream modes force no repaint
# themselves, so the file also runs against a pane build that predates the row
# split.
#
# Read the delta between `idle_us` and `forced_us` as the cost of one full
# repaint, and `row_us - idle_us` as the cost of one changed row; compare two
# revisions by diffing the two PNGs, which must be byte-for-byte identical in
# pixels.

const FRAMES := 150
const DEADLINE_MS := 20000
const CONTENT := """
printf '\\033[1;31mBOLD RED TEXT\\033[0m plain \\033[4;32mUNDERLINE GREEN\\033[0m\\n';
printf '\\033[3;33mITALIC YELLOW\\033[0m \\033[7m INVERSE \\033[0m \\033[38;5;208mORANGE\\033[0m\\n';
printf 'wide: \\u65e5\\u672c\\u8a9e\\u30c6\\u30ad\\u30b9\\u30c8 and mixed wide \\u4f60\\u597d tail\\n';
printf 'rgb: \\033[31mR\\033[32mG\\033[34mB\\033[36mC\\033[35mM\\033[33mY\\033[0m distinct colors\\n';
seq -f 'line %g: the quick brown fox jumps over the lazy dog 0123456789' 1 25;
sleep 120
"""
## A full screen repaint in a loop: every sync sees full-grid damage.
const FLOOD := "while :; do printf '\\033[2J\\033[H'; seq -f 'flood %g 0123456789 abcdefghijklmnopqrstuvwxyz' 1 35; done"
## One line every 0.2 s: fewer than a screenful in the measured window, so the
## grid never scrolls and each tick damages one row.
const SPARSE := "while :; do echo tick; sleep 0.2; done"

var _pane

func _initialize():
	var cols := int(OS.get_environment("BENCH_COLS")) if OS.get_environment("BENCH_COLS") != "" else 90
	var rows := int(OS.get_environment("BENCH_ROWS")) if OS.get_environment("BENCH_ROWS") != "" else 30
	if OS.get_environment("BENCH_FLOOD") != "":
		_measure_stream(cols, rows, FLOOD, "flood")
	elif OS.get_environment("BENCH_SPARSE") != "":
		_measure_stream(cols, rows, SPARSE, "sparse")
	else:
		_measure(cols, rows)

## The stream modes: a pane whose child keeps producing, measured per frame for
## `FRAMES` frames. Every frame sees damage - a full screen in the flood, one
## line in the sparse case - and `avg_rows` says how much of the grid the pane
## repainted per sync, which is the row split's whole claim.
func _measure_stream(cols: int, rows: int, cmd: String, mode: String):
	await _new_pane(cols, rows, cmd)
	var start := Time.get_ticks_usec()
	var frames := 0
	var work := 0
	var busy_frames := 0
	var gen_changes := 0
	var tallied := 0
	var last_gen := -1
	var syncs := 0
	var rows_sum := 0
	var sync_work_us := 0.0
	var first_sync := true
	var last_sync_gen: int = _pane._last_grid_gen
	while frames < FRAMES and (Time.get_ticks_usec() - start) / 1000 < DEADLINE_MS:
		await process_frame
		var frame_work: float = _pane._fetch_ms + _pane._draw_ms
		work += frame_work
		if frame_work >= 1.0:
			busy_frames += 1
		var gen: int = _pane._terminal.get_grid_generation()
		if gen != last_gen:
			gen_changes += 1
			last_gen = gen
		if _pane._last_grid_gen != last_sync_gen:
			syncs += 1
			last_sync_gen = _pane._last_grid_gen
			# The first sync is the initial load, which repaints the whole grid;
			# `sync_us` and `avg_rows` are the means over the damage syncs after
			# it.
			if first_sync:
				first_sync = false
			else:
				# What the sync that consumed the damage cost: the fetch plus
				# the rows it repainted. This is the number the row split moves.
				sync_work_us += frame_work * 1000.0
				rows_sum += _painted_rows(_pane)
				tallied += 1
		frames += 1
	var elapsed_ms := float(Time.get_ticks_usec() - start) / 1000.0
	print("%s grid=%dx%d frames=%d fps=%.1f avg_frame_ms=%.2f sync_us=%.0f avg_work_ms=%.3f busy_frames=%d gen_changes=%d syncs=%d sync_hz=%.1f avg_rows=%.1f backoff_ms=%.1f" % [
		mode, cols, rows, frames, float(frames) * 1000.0 / elapsed_ms,
		elapsed_ms / maxf(float(frames), 1.0), sync_work_us / maxf(float(syncs), 1.0),
		float(work) / maxf(float(frames), 1.0),
		busy_frames, gen_changes, syncs, float(syncs) * 1000.0 / elapsed_ms,
		float(rows_sum) / maxf(float(tallied), 1.0), _pane._sync_backoff * 1000.0])
	quit()

## The rows the pane's last repaint queued, or -1 on a build that predates the
## row split - the stream modes must run against one for the before/after
## comparison the roadmap row records.
func _painted_rows(pane) -> int:
	if "_painted_rows" not in pane:
		return -1
	return int(pane._painted_rows.size())

func _new_pane(cols: int, rows: int, cmd: String):
	_pane = load("res://scenes/terminal/terminal_pane.gd").new()
	_pane.shell_command = "/bin/sh"
	_pane.shell_args = ["-c", cmd]
	_pane.font_size = 14
	_pane.cursor_blink = false
	root.add_child(_pane)
	_pane.position = Vector2.ZERO
	_pane.size = Vector2(cols * 9, rows * 18)
	await process_frame
	_pane.size = Vector2(cols * 9, rows * 18)
	_pane._terminal.resize_grid(rows, cols)
	_pane.rows = rows
	_pane.cols = cols

func _measure(cols: int, rows: int):
	await _new_pane(cols, rows, CONTENT)

	# Let the content land and the grid settle.
	var last := -1
	var stable := 0
	for _i in 900:
		await process_frame
		var gen: int = _pane._terminal.get_grid_generation() if _pane._terminal else -1
		if gen == last:
			stable += 1
			if stable > 20:
				break
		else:
			stable = 0
			last = gen

	_pane._cursor_visible = true
	_pane._repaint_all()
	await process_frame
	await RenderingServer.frame_post_draw
	var tag := OS.get_environment("BENCH_TAG")
	if tag == "":
		tag = "run"
	root.get_texture().get_image().save_png("/tmp/gpty_draw_%s.png" % tag)

	var idle := await _time_frames(0)
	var forced := await _time_frames(1)
	var row := await _time_frames(2)
	var overlay := await _time_frames(3)
	print("grid=%dx%d cells=%d rows=%d idle_us=%.1f forced_us=%.1f row_us=%.1f overlay_us=%.1f draw_us=%.1f" % [
		cols, rows, cols * rows, rows, idle, forced, row, overlay, forced - idle])
	quit()

## 0 = idle, 1 = a full repaint, 2 = one row, 3 = the overlay alone.
func _time_frames(mode: int) -> float:
	var start := Time.get_ticks_usec()
	var frames := 0
	while frames < FRAMES and (Time.get_ticks_usec() - start) / 1000 < DEADLINE_MS:
		match mode:
			1: _pane._repaint_all()
			2: _pane._repaint_row(0)
			3: _pane._repaint_overlay()
		await process_frame
		frames += 1
	return float(Time.get_ticks_usec() - start) / maxf(float(frames), 1.0)
