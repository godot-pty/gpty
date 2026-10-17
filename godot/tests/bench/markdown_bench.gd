extends SceneTree
# Live-preview cost harness for the wiki pane's editor.
#
# Times one preview update — the Rust render *plus* the RichTextLabel's own
# BBCode parse and shape of the result — at the sizes a note is read under.
# The Rust half has its own probe (`probe_render_cost` in
# crates/gpty-gdext/src/markdown.rs); this harness is the other half, and the
# only place the label's cost is measurable.
#
#   godot --path godot --disable-vsync -s res://tests/bench/markdown_bench.gd
#
# Run headless or on a display — measured within ~5 % either way, because the
# parse and the shape pass are CPU work in the text server rather than draw
# work (the Rust render never needed a window either).
#
#   BENCH_KIB   comma-separated sizes in KiB (default 256,512,1024)
#
# Read `render_ms` as the Rust render (linear in the source, capped at the
# 1 MiB every pane reads under), `parse_ms` as the label's share of
# `render_now` — forcing the remaining parse with `get_parsed_text()` —
# `shape_ms` as the frame that lays the text out (the pass that a list-heavy
# document used to make superlinear: see `GptyMarkdown`'s docs), and
# `total_ms` as what one preview update actually costs the GUI thread.
#
#   BENCH_KIB   comma-separated sizes in KiB (default 256,512,1024)

const UNIT := "# Heading\n\nSome **bold** and `code` and a [link](https://example.com/x).\n\n- item one\n- item two\n\n> quoted line\n\n"
const WIDTH := 720.0
const HEIGHT := 900.0

func _initialize():
	_run()

func _run() -> void:
	var sizes := "256,512,1024"
	if OS.get_environment("BENCH_KIB") != "":
		sizes = OS.get_environment("BENCH_KIB")

	var host := Control.new()
	host.size = Vector2(WIDTH, HEIGHT)
	root.add_child(host)
	var view = load("res://scenes/ui/markdown_view.gd").new()
	view.size = Vector2(WIDTH, HEIGHT)
	host.add_child(view)
	# Let `_ready` run before anything is measured: it is what builds the
	# renderer and the coalescing timer.
	await process_frame
	print("markdown_bench renderer=%s" % ("yes" if view._renderer != null else "MISSING"))

	for part in sizes.split(","):
		var kib := int(part.strip_edges())
		if kib <= 0:
			continue
		await _measure(view, kib)
	quit()


func _measure(view, kib: int):
	var source := _source(kib)
	# Warm-up at a different size so the first measured render does not pay
	# lazy text-server and font setup, and so the label is shaped before the
	# measured text lands.
	view.render_now("# warm\n")
	view.get_parsed_text()
	await process_frame

	var t0 := Time.get_ticks_usec()
	view.render_now(source)
	var t1 := Time.get_ticks_usec()
	view.get_parsed_text()
	var t2 := Time.get_ticks_usec()
	# The shape pass runs on the next frame; that frame is the freeze a user
	# feels after an edit, so it is measured, not skipped.
	await process_frame
	var t3 := Time.get_ticks_usec()
	print("markdown_bench kib=%d source_bytes=%d render_ms=%.2f parse_ms=%.2f shape_ms=%.2f total_ms=%.2f" % [
		kib, source.length(), float(t1 - t0) / 1000.0, float(t2 - t1) / 1000.0,
		float(t3 - t2) / 1000.0, float(t3 - t0) / 1000.0])


func _source(kib: int) -> String:
	var source := ""
	while source.length() < kib * 1024:
		source += UNIT
	return source
