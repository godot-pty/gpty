extends SceneTree
# Link-graph cost harness for the wiki pane.
#
# The graph used to be built on the frame that asked for it: the index query
# (`GptyTerminal.vault_graph`), the model (`VaultGraphModel.parse`) and the
# deterministic layout (`VaultGraphModel.layout`) all ran synchronously, so a
# large vault stalled every pane and `pane-view --graph` could outlast its
# caller's timeout. The build now runs in one `WorkerThreadPool` task, and this
# harness prints both halves of that:
#
#   query_us, parse_us, layout_us   the three old on-frame steps, timed here
#   old_stall_us                    their sum - what one frame used to pay
#   request_us                      what `request_graph()` costs the frame now
#   landed_ms                       request -> canvas, the build's real latency
#
#   godot --headless --path godot -s res://tests/bench/graph_bench.gd
#
#   BENCH_NOTES   notes in the synthetic vault (default 600; the walk's cap is
#                 2000, which is the worst case)
#   BENCH_LINKS   wikilinks per note (default 5), each to (i + k) % notes
#
# A warm pass follows (`warm_*`): the second layout starts from the positions
# the canvas already holds, which is what a re-query pays.

## Untyped on purpose: a typed `WikiPane` field would compile the pane's
## script (and its autoload identifiers) while this file loads, before the
## project's autoloads exist — script mode registers them only once the tree
## starts. The pane is loaded by path after the first frame instead.
var _pane = null
var _vault := ""
var _landed_ms := -1
var _request_start := 0


func _initialize():
	var notes := int(OS.get_environment("BENCH_NOTES")) if OS.get_environment("BENCH_NOTES") != "" else 600
	var links := int(OS.get_environment("BENCH_LINKS")) if OS.get_environment("BENCH_LINKS") != "" else 5
	notes = maxi(notes, 2)
	links = clampi(links, 1, notes - 1)
	_seed_vault(notes, links)
	_measure(notes, links)


## A vault with a deterministic link structure: every note names `links`
## others, so the index has one ordered pair per mention to aggregate.
func _seed_vault(notes: int, links: int) -> void:
	_vault = OS.get_temp_dir().path_join("gpty_graph_bench_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(_vault)
	for i in notes:
		var body := "# Note %d\n\n" % i
		for k in range(1, links + 1):
			body += "[[Note %d]] " % ((i + k) % notes)
		var file := FileAccess.open(_vault.path_join("note_%04d.md" % i), FileAccess.WRITE)
		file.store_string(body + "\n")
		file.close()


func _measure(notes: int, links: int):
	# Autoload names resolve only after the main loop starts, and the pane's
	# script references them, so it is loaded here rather than at file load.
	await process_frame
	_pane = load("res://scenes/panes/wiki_pane.gd").new()
	_pane.vault_path = _vault
	# Force the physical map: the bench is about the 3D view even when this
	# machine's headless renderer would resolve `auto` to the planar canvas.
	_pane.graph_mode = "3d"
	root.add_child(_pane)
	_pane.size = Vector2(1200, 800)
	# `_ready` indexes the vault; the graph reads that index, so wait for the
	# list before timing anything.
	var deadline := Time.get_ticks_msec() + 30000
	while _pane._list.item_count == 0 and Time.get_ticks_msec() < deadline:
		await process_frame
	if _pane._list.item_count == 0:
		print("notes=%d links=%d error=vault did not index" % [notes, links])
		_cleanup()
		return

	var cold := _time_steps({})
	print("notes=%d links=%d indexed=%d edges=%d truncated=%s query_us=%.1f parse_us=%.1f layout_us=%.1f old_stall_us=%.1f" % [
		notes, links, _pane._list.item_count, int(cold["edges"]), str(cold["truncated"]),
		cold["query_us"], cold["parse_us"], cold["layout_us"], cold["stall_us"]])

	_pane.graph_built.connect(func(_ok: bool, _reason: String):
		_landed_ms = Time.get_ticks_msec() - _request_start
	)
	_request_start = Time.get_ticks_msec()
	var requested := Time.get_ticks_usec()
	_pane.request_graph()
	var request_us := float(Time.get_ticks_usec() - requested)
	_landed_ms = -1
	deadline = Time.get_ticks_msec() + 20000
	while _landed_ms < 0 and Time.get_ticks_msec() < deadline:
		await process_frame
	print("request_us=%.1f landed_ms=%d canvas=%s" % [
		request_us, _landed_ms, str(_pane._graph_view.visible)])

	await _measure_3d(_pane._graph_view)

	# Warm: the geometry the canvas now holds is what the next build starts
	# from, so the layout only places what moved or appeared.
	var warm := _time_steps(_pane._graph_view.positions)
	print("warm_query_us=%.1f warm_parse_us=%.1f warm_layout_us=%.1f warm_stall_us=%.1f" % [
		warm["query_us"], warm["parse_us"], warm["layout_us"], warm["stall_us"]])

	_cleanup()


## The physical map's own cost: one body build, the settling ticks, the spring
## step and the link mesh rebuild. A windowed run also prints the frame time;
## a headless run has no renderer, so its frame number is the harness's loop.
func _measure_3d(view) -> void:
	# Duck-typed on purpose: a typed `VaultGraph3D` reference would compile the
	# view (and the autoloads it names) while this `-s` entry point loads,
	# before the project's autoloads exist.
	if view == null or not view.has_method("simulation_ticks") or not view.has_method("is_settled"):
		print("three_d=absent")
		return
	# A fresh map is at rest by construction; push one node so the measured
	# tick/link numbers are the cost of a real interaction, not an empty settle.
	if view.is_settled() and not view._bodies.is_empty():
		var id = view._bodies.keys()[0]
		var before: Vector2 = view.positions[id]
		view._begin_drag(id)
		view._drag_to(id, before + Vector2(60.0, 40.0))
		view._finish_drag(true)
	var steps: Array[float] = []
	var visuals: Array[float] = []
	var links: Array[float] = []
	var frames: Array[float] = []
	var deadline := Time.get_ticks_msec() + 10000
	while not view.is_settled() and Time.get_ticks_msec() < deadline:
		var frame_start := Time.get_ticks_usec()
		await process_frame
		frames.append(float(Time.get_ticks_usec() - frame_start))
		if view.last_step_us > 0:
			steps.append(float(view.last_step_us))
		if view.last_visual_us > 0:
			visuals.append(float(view.last_visual_us))
		if view.last_link_build_us > 0:
			links.append(float(view.last_link_build_us))
	print(
		"three_d bodies=%d build_ms=%.1f settle_ticks=%d settled=%s step_us_median=%.1f step_us_max=%.1f visual_us_median=%.1f visual_us_max=%.1f link_us_median=%.1f link_us_max=%.1f frames=%d frame_ms_median=%.2f"
		% [
			view._bodies.size(), float(view.last_build_us) / 1000.0,
			view.simulation_ticks(), str(view.is_settled()),
			_median(steps), _max(steps), _median(visuals), _max(visuals),
			_median(links), _max(links), frames.size(), _median(frames) / 1000.0,
		]
	)


func _median(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	return float(sorted[sorted.size() / 2])


func _max(values: Array[float]) -> float:
	var top := 0.0
	for value in values:
		top = maxf(top, value)
	return top


## The three steps the pane used to run on the frame, timed together.
func _time_steps(previous: Dictionary) -> Dictionary:
	var started := Time.get_ticks_usec()
	var answer = JSON.parse_string(str(GptyTerminal.vault_graph(_vault)))
	var query_us := float(Time.get_ticks_usec() - started)

	started = Time.get_ticks_usec()
	var graph := VaultGraphModel.parse(answer, {})
	var parse_us := float(Time.get_ticks_usec() - started)
	if not bool(graph["ok"]):
		return {
			"query_us": query_us, "parse_us": parse_us, "layout_us": 0.0,
			"stall_us": query_us + parse_us, "edges": 0, "truncated": false,
		}

	started = Time.get_ticks_usec()
	VaultGraphModel.layout(graph["nodes"], graph["edges"], previous)
	var layout_us := float(Time.get_ticks_usec() - started)
	return {
		"query_us": query_us,
		"parse_us": parse_us,
		"layout_us": layout_us,
		"stall_us": query_us + parse_us + layout_us,
		"edges": graph["edges"].size(),
		"truncated": bool(graph["truncated"]),
	}


func _cleanup() -> void:
	if _pane != null and is_instance_valid(_pane):
		_pane.queue_free()
	var dir := DirAccess.open(_vault)
	if dir != null:
		for f in dir.get_files():
			DirAccess.remove_absolute(_vault.path_join(f))
	DirAccess.remove_absolute(_vault)
	print("notes_dir_removed=%s" % _vault)
	_vault = ""
	quit()
