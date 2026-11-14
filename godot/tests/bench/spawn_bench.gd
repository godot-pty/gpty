extends SceneTree
## The pane-spawn bench (roadmap: "Creating a pane gets slower as the window
## fills").
##
## Spawns terminals into the active workspace one at a time and prints the cost
## of each create, so a per-call cost that grows with the live pane count shows
## as a slope instead of one slow number. The original measurement (2026-10-30,
## a `new-pane` loop against the headless GUI) was 15 ms at one pane and about
## 1 s at 64; this harness is the before/after check that row asks for.
##
##   . scripts/ui-sandbox && gpty_sandbox_init && \
##       godot --path godot --display-driver x11 --disable-vsync \
##         -s res://tests/bench/spawn_bench.gd
##
## `scripts/ui-sandbox` is a sourced library, not a command: it owns the sandbox
## the app needs (a private `user://`, XDG dirs, HOME and control socket).
##
## Environment:
##   SPAWN_BENCH_MAX    the pane count to stop at (default 64, clamp 1..96)
##   SPAWN_BENCH_MARKS  iterations per pass micro-measure (default 20)
##
## A real display driver is required: under `--headless` a `-s` launch clamps the
## root to 64x64, every tile is too small to hold the minimum grid, and no child
## starts - the run fails rather than reporting numbers for a path it never
## exercised. POSIX only - the payload runs through `/bin/sh` and RSS/child
## counts come from `/proc`.
##
## Two numbers per spawn:
##   sync_us   the synchronous create call (`_spawn_pane`, what the CLI's
##             `new-pane` handler runs before the answer is held)
##   total_us  from the call to the child being resolved (`child_started`),
##             which is what an IPC caller waits for (`_hold_pane_answer`)
##
## At each milestone the run also prints the whole-window passes the create path
## can touch (layout, divider refresh, title-bar sweep) and the sidebar's
## unchanged-model refresh, so a remaining per-call term is attributable instead
## of guessed. `rss_mib` and `children` are the leak axis: the shells are direct
## children of this process, so `children` tracks `/proc` rather than the app's
## own bookkeeping.

const SANDBOX_ENV := "GPTY_TEST_USER_DIR"
## Where the attribution line is printed. Pane 64 is the count the roadmap row
## measured; the grid refuses some count above it.
const MILESTONES := [1, 8, 16, 32, 48, 64]
## A spawn whose child never starts is a harness failure, not a slow spawn.
const CHILD_START_MS := 3000
const DEFAULT_MAX_PANES := 64
const DEFAULT_MARKS := 20
const WINDOW := Vector2i(1920, 1080)
## A quiet child: the spawn call returns before the child starts, so a real
## shell's start-up would land in `total_us` noise rather than in `sync_us`.
const PAYLOAD := {"shell_command": "/bin/sh", "shell_args": ["-c", "sleep 600"]}

var _workspace: Control = null
## pane count -> sync_us, the slope the row reports.
var _sync_by_pane: Dictionary = {}


func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		_fail("spawn_bench needs a real display driver: a headless -s root is 64x64 and no pane can start its child")
		return
	if OS.get_name() == "Windows":
		_fail("spawn_bench is POSIX-only: its payload runs through /bin/sh and it reads /proc")
		return
	var sandbox := OS.get_environment(SANDBOX_ENV)
	if not BasePersistenceManager.is_real_absolute_path(sandbox):
		_fail("%s must name an absolute directory; run scripts/ui-sandbox" % SANDBOX_ENV)
		return
	var max_panes := _int_env("SPAWN_BENCH_MAX", DEFAULT_MAX_PANES, 96)
	var marks := _int_env("SPAWN_BENCH_MARKS", DEFAULT_MARKS, 200)
	print("spawn_bench: start sandbox=%s max=%d marks=%d" % [sandbox, max_panes, marks])

	var settings: Node = root.get_node("SettingsManager")
	# In-memory settings only: the sandbox already keeps the stores private.
	settings.cfg_cursor_blink = false
	settings.cfg_check_updates = false
	settings.cfg_max_fps = 165
	settings.cfg_window_size = WINDOW
	settings.cfg_window_mode = 0
	settings.apply_ui_scale()
	settings.apply_appearance()

	_workspace = load("res://scenes/main.tscn").instantiate()
	root.add_child(_workspace)
	await _settle_window(WINDOW)
	print("spawn_bench: window=%s" % root.size)
	for _i in 4:
		await process_frame

	# Untyped on purpose: a `TerminalManager` annotation makes GDScript compile
	# `terminal_manager.gd` (which names the autoloads) while a `-s` script is
	# still loading, before those singletons exist - the `ui_capture` rule.
	var tm = _workspace._tm
	print("spawn_bench: workspaces=%d panes=%d" % [_workspace._workspaces.size(), tm.tiles.size()])

	for n in range(1, max_panes + 1):
		var t0 := Time.get_ticks_usec()
		var body = _workspace._spawn_pane("terminal", PAYLOAD.duplicate(true), true)
		var sync_us := Time.get_ticks_usec() - t0
		if body == null:
			print("spawn_bench: grid full at %d panes" % (n - 1))
			break
		var deadline := Time.get_ticks_msec() + CHILD_START_MS
		while not body.child_start_resolved() and Time.get_ticks_msec() < deadline:
			await process_frame
		var total_us := Time.get_ticks_usec() - t0
		if n == 1 and not body.child_start_resolved():
			_fail("the first pane's child never started (is the GDExtension linked?)")
			return
		if _workspace._tm.tiles.size() != n:
			_fail("spawn %d left %d tiles" % [n, _workspace._tm.tiles.size()])
			return
		_sync_by_pane[n] = sync_us
		print("spawn_bench: pane=%d sync_us=%d total_us=%d" % [n, sync_us, total_us])
		if MILESTONES.has(n):
			_measure_passes(n, marks)

	if not _sync_by_pane.is_empty():
		var first_key: int = _sync_by_pane.keys()[0]
		var last_key: int = _sync_by_pane.keys()[-1]
		var slope := 0.0
		if last_key > first_key:
			slope = float(_sync_by_pane[last_key] - _sync_by_pane[first_key]) \
				/ float(last_key - first_key)
		print("spawn_bench: done panes=%d slope_us_per_pane=%.1f" % [last_key, slope])
	quit(0)


# ── Attribution ────────────────────────────────────────────────────────

## The whole-window passes plus the sidebar refresh on an unchanged model:
## enough to tell a growing pass from a constant one.
func _measure_passes(panes: int, marks: int) -> void:
	var dividers = _workspace._grid.get_node_or_null("DividerHandles")
	var divider_us := -1.0
	if dividers != null:
		divider_us = _avg_us(func(): dividers.refresh(), marks)
	print("spawn_bench: at=%d rss_mib=%d children=%d layout_us=%.1f dividers_us=%.1f titlebars_us=%.1f list_us=%.1f" % [
		panes,
		_rss_mib(),
		_child_count(),
		_avg_us(func(): _workspace._apply_layout(), marks),
		divider_us,
		_avg_us(func(): _workspace._sync_pane_titlebars(), marks),
		_avg_us(func(): _workspace._list(), marks),
	])


func _avg_us(work: Callable, marks: int) -> float:
	var t0 := Time.get_ticks_usec()
	for _i in marks:
		work.call()
	return float(Time.get_ticks_usec() - t0) / float(maxi(marks, 1))


## This process's resident set, MiB. `/proc/<pid>/status` is readable without
## `PR_SET_DUMPABLE` (gpty clears it), unlike `/proc/<pid>/maps`; it must be
## read line by line because a procfs file reports a zero length and a
## length-hinted read returns nothing.
func _rss_mib() -> int:
	var f := FileAccess.open("/proc/%d/status" % OS.get_process_id(), FileAccess.READ)
	if f == null:
		return -1
	var kib := -1
	while not f.eof_reached():
		var line := f.get_line()
		if not line.begins_with("VmRSS:"):
			continue
		var rest := line.substr(6).strip_edges().split(" ", false)
		if not rest.is_empty() and rest[0].is_valid_int():
			kib = int(rest[0])
		break
	f.close()
	return kib / 1024 if kib >= 0 else -1


## Direct children of this process - the PTY children are spawned from here, so
## this is the leak axis the app's own tile list cannot see.
func _child_count() -> int:
	var me := OS.get_process_id()
	var kids := 0
	for name in DirAccess.get_directories_at("/proc"):
		if not name.is_valid_int():
			continue
		var f := FileAccess.open("/proc/%s/stat" % name, FileAccess.READ)
		if f == null:
			continue
		var line := f.get_line()
		f.close()
		# comm is `(name)` and may contain spaces or parens; the fields after the
		# last `)` start with state then ppid.
		var close := line.rfind(")")
		if close < 0:
			continue
		var rest := line.substr(close + 2).split(" ", false)
		if rest.size() >= 2 and rest[1].is_valid_int() and int(rest[1]) == me:
			kids += 1
	return kids


# ── Harness ────────────────────────────────────────────────────────────

func _int_env(name: String, fallback: int, cap: int) -> int:
	var raw := OS.get_environment(name).strip_edges()
	if raw == "":
		return fallback
	if not raw.is_valid_int():
		_fail("%s must be a whole number (got '%s')" % [name, raw])
		return fallback
	return clampi(int(raw), 1, cap)


## The root viewport is the authority (the chrome's own restore may re-apply a
## saved size after launch), so set it and wait until it reads back.
func _settle_window(size: Vector2i) -> void:
	root.size = size
	for _i in 120:
		if Vector2i(root.size) == size:
			await process_frame
			await process_frame
			return
		await process_frame
	_fail("window did not reach %dx%d (root viewport is %s)" % [size.x, size.y, root.size])


func _fail(message: String) -> void:
	push_error("spawn_bench: " + message)
	print("spawn_bench: FAIL " + message)
	quit(1)
