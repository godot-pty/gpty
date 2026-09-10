extends SceneTree
# Draw-cost harness for the terminal renderer.
#
# Fills a terminal pane with a deterministic ANSI-rich screen (bold, italic,
# underline, inverse, wide characters, colors, plain text), saves the rendered
# viewport as a PNG so two revisions can be diffed pixel-for-pixel, and times a
# forced full repaint against an idle frame.
#
#   godot --path godot --disable-vsync -s res://tests/bench/draw_bench.gd
#
# A real display driver is required: under `--headless` there is no redraw pass
# and every timing reads zero. `--disable-vsync` matters because a vsync-locked
# present can block indefinitely on a window the compositor never shows.
#
#   BENCH_COLS, BENCH_ROWS  grid size (default 90×30)
#   BENCH_TAG               suffix of the saved PNG (default "run")
#
# Read the delta between `idle_us` and `forced_us` as the cost of one full
# repaint; compare two revisions by diffing the two PNGs, which must be
# byte-for-byte identical in pixels.

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

var _pane

func _initialize():
	var cols := int(OS.get_environment("BENCH_COLS")) if OS.get_environment("BENCH_COLS") != "" else 90
	var rows := int(OS.get_environment("BENCH_ROWS")) if OS.get_environment("BENCH_ROWS") != "" else 30
	if OS.get_environment("BENCH_FLOOD") != "":
		_measure_flood(cols, rows)
	else:
		_measure(cols, rows)

## Flood mode: a pane repaints its whole screen in a loop (clear + home +
## a screenful of lines). Every frame sees full-grid damage — the case that
## makes a pane expensive — while the write rate stays bounded, so this
## measures the UI-thread cost rather than the unbounded output channel.
func _measure_flood(cols: int, rows: int):
	await _new_pane(cols, rows, "while :; do printf '\\033[2J\\033[H'; seq -f 'flood %g 0123456789 abcdefghijklmnopqrstuvwxyz' 1 35; done")
	var start := Time.get_ticks_usec()
	var frames := 0
	var work := 0
	var busy_frames := 0
	var gen_changes := 0
	var last_gen := -1
	while frames < FRAMES and (Time.get_ticks_usec() - start) / 1000 < DEADLINE_MS:
		await process_frame
		var frame_work: int = _pane._fetch_ms + _pane._draw_ms
		work += frame_work
		if frame_work > 0:
			busy_frames += 1
		var gen: int = _pane._terminal.get_grid_generation()
		if gen != last_gen:
			gen_changes += 1
			last_gen = gen
		frames += 1
	var elapsed_ms := float(Time.get_ticks_usec() - start) / 1000.0
	print("flood grid=%dx%d frames=%d fps=%.1f avg_frame_ms=%.2f avg_work_ms=%.3f busy_frames=%d gen_changes=%d" % [
		cols, rows, frames, float(frames) * 1000.0 / elapsed_ms,
		elapsed_ms / maxf(float(frames), 1.0), float(work) / maxf(float(frames), 1.0),
		busy_frames, gen_changes])
	quit()

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
	_pane.queue_redraw()
	await process_frame
	await RenderingServer.frame_post_draw
	var tag := OS.get_environment("BENCH_TAG")
	if tag == "":
		tag = "run"
	root.get_texture().get_image().save_png("/tmp/gpty_draw_%s.png" % tag)

	var idle := await _time_frames(false)
	var forced := await _time_frames(true)
	print("grid=%dx%d cells=%d idle_us=%.1f forced_us=%.1f draw_us=%.1f" % [
		cols, rows, cols * rows, idle, forced, forced - idle])
	quit()

func _time_frames(force: bool) -> float:
	var start := Time.get_ticks_usec()
	var frames := 0
	while frames < FRAMES and (Time.get_ticks_usec() - start) / 1000 < DEADLINE_MS:
		if force:
			_pane._cursor_visible = true
			_pane.queue_redraw()
		await process_frame
		frames += 1
	return float(Time.get_ticks_usec() - start) / maxf(float(frames), 1.0)
