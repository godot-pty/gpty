extends SceneTree
# Streaming cost harness for the Reasoning pane.
#
# Measures what a live OMP reasoning stream costs on the GUI thread: the model
# append path (`receive_agent_event` → `_append_live_text`) for a burst, and
# the view's catch-up (Rust render + RichTextLabel parse/shape) until it goes
# idle. This is the "output rate" half; the input rate is observable live with
# `GPTY_REASONING_DEBUG=1` (the pane prints deltas/s, bytes/s and render ms).
#
#   godot --headless --path godot -s res://tests/bench/reasoning_bench.gd
#
#   BENCH_KIB=16,64,256   turn sizes to stream (default 16,64,256)
#   BENCH_DELTA=32        bytes per simulated delta (default 32)
#   BENCH_CAP=0           retention cap in KiB (0 = open, the default)
#
# Each size starts a fresh pane. `burst_ms` is the model's share (N appends,
# no rendering — the deferred work runs after the loop), `catchup_ms` is from
# the end of the burst to the last render of that turn, and `renders` is how
# many times the view re-parsed the accumulated turn. A healthy streaming pane
# keeps one render per RENDER_DELAY regardless of the delta rate; a pane that
# re-renders unchanged turns scales renders with the number of turns instead.
#
# Measured (Linux, headless, 32-byte deltas):
#   64 KiB:  burst 14 ms, one render 11 ms
#   256 KiB: burst 120 ms, one render 41 ms
#   256 KiB into a 64 KiB cap: burst 31 ms, render 10 ms — the old capped
#     append path re-encoded the whole turn per dropped delta and cost 486 ms.

const WIDTH := 900.0
const HEIGHT := 900.0
const UNIT := "Reasoning sentence with **bold**, `code`, and a [link](https://example.com).\n"

var _renders := 0
var _last_render_usec := 0
var _last_render_at_usec := 0
var _pane
var _view

func _initialize():
	_run()

func _run() -> void:
	var sizes := "16,64,256"
	if OS.get_environment("BENCH_KIB") != "":
		sizes = OS.get_environment("BENCH_KIB")
	var delta_bytes := 32
	if OS.get_environment("BENCH_DELTA") != "":
		delta_bytes = maxi(int(OS.get_environment("BENCH_DELTA")), 1)
	var cap_kib := 0
	if OS.get_environment("BENCH_CAP") != "":
		cap_kib = maxi(int(OS.get_environment("BENCH_CAP")), 0)
	print("reasoning_bench renderer=%s delta=%d B cap=%s" % [
		"yes" if ClassDB.class_exists("GptyMarkdown") else "MISSING", delta_bytes,
		"open" if cap_kib == 0 else "%d KiB" % cap_kib])
	for part in sizes.split(","):
		var kib := int(part.strip_edges())
		if kib > 0:
			await _measure(kib, delta_bytes, cap_kib)
	quit()


func _measure(kib: int, delta_bytes: int, cap_kib: int) -> void:
	_renders = 0
	_last_render_usec = 0
	_last_render_at_usec = 0
	var host := Control.new()
	host.size = Vector2(WIDTH, HEIGHT)
	root.add_child(host)
	_pane = load("res://scenes/panes/reasoning_pane.gd").new()
	_pane.source_attachment_id = "omp-terminal"
	host.add_child(_pane)
	await process_frame
	await process_frame
	# After `_ready`: it clamps the setting, which would overwrite a value set
	# before the pane entered the tree. A size above the cap measures the
	# capped-append path (the one that used to re-encode the whole turn per
	# dropped delta).
	_pane.max_turn_bytes = (cap_kib * 1024) if cap_kib > 0 else 8 * 1024 * 1024

	_pane.receive_agent_event(_envelope("agent.started"), "omp-terminal")
	_view = _pane._view_at(0)
	_view.rendered.connect(_on_rendered)

	var source := _source(kib)
	var t0 := Time.get_ticks_usec()
	var index := 0
	while index < source.length():
		var piece := source.substr(index, delta_bytes)
		index += piece.length()
		_pane.receive_agent_event(
			_envelope("thinking.delta", {"text": piece}), "omp-terminal")
	var burst_usec := Time.get_ticks_usec() - t0

	# Let the coalesced renders land. Wait for the first, then for a quiet
	# window longer than the render delay — a frame count is not a clock (the
	# headless loop runs frames far faster than the timer).
	var deadline := Time.get_ticks_msec() + 60000
	while _renders == 0 and Time.get_ticks_msec() < deadline:
		await process_frame
	var last_render_ms := Time.get_ticks_msec()
	var last_count := _renders
	while Time.get_ticks_msec() < deadline and Time.get_ticks_msec() - last_render_ms < 300:
		await process_frame
		if _renders != last_count:
			last_count = _renders
			last_render_ms = Time.get_ticks_msec()
	var catchup_usec := maxi(_last_render_at_usec - (t0 + burst_usec), 0)

	var text: String = _pane._turns[0]["text"]
	print("reasoning_bench kib=%d deltas=%d burst_ms=%.1f catchup_ms=%.1f renders=%d render_ms=%.2f text_bytes=%d" % [
		kib, int(ceil(float(source.length()) / delta_bytes)),
		float(burst_usec) / 1000.0, float(catchup_usec) / 1000.0,
		_renders, float(_last_render_usec) / 1000.0,
		text.to_utf8_buffer().size()])
	host.free()


func _on_rendered():
	_renders += 1
	_last_render_at_usec = Time.get_ticks_usec()
	_last_render_usec = int(_view.get("last_render_usec")) if "last_render_usec" in _view else 0


func _envelope(name: String, extra: Dictionary = {}) -> Dictionary:
	var event := {"name": name}
	event.merge(extra)
	return {"omp_session_id": "bench", "event": event}


func _source(kib: int) -> String:
	var source := ""
	while source.length() < kib * 1024:
		source += UNIT
	return source
