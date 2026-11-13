extends SceneTree
## The workspace-switch bench (roadmap: "A workspace switch costs about a
## second on the daily-use set").
##
## Two workspaces, both restored through the real store, both with a live pane:
## switching between them must be a view change. The bench separates the three
## phases a "slow switch" can hide in - the synchronous GDScript in
## `_switch_workspace`, the window-mode round trip in `WindowChrome.apply_mode`,
## and the wait to the first painted frame (the incoming terminal's repack and
## `_draw`) - and prints the incoming pane's own fetch/draw/back-off so a
## full-screen TUI's frame cost is distinguishable from the switch's.
##
##   . scripts/ui-sandbox && gpty_sandbox_init && \
##       SWITCH_CMD_A=omp SWITCH_CMD_B=btop godot --path godot \
##       --disable-vsync -s res://tests/bench/switch_bench.gd
##
## `scripts/ui-sandbox` is a sourced library, not a command: it owns the sandbox
## the app needs (a private `user://`, XDG dirs, HOME and control socket).
##
## Environment:
##   SWITCH_CMD_A   the first workspace's program (default: a quiet `sleep`)
##   SWITCH_CMD_B   the second workspace's program (default: a full-screen
##                  repaint loop, the `draw_bench` flood shape)
##   SWITCH_REPS    measured switches per direction (default 5, minimum 3)
##   SWITCH_WINDOW  "WxH" (default 2053x1382, the reporter's window)
##
## The reporter's own set is `SWITCH_CMD_A=omp SWITCH_CMD_B=btop`.
##
## Both panes are filled before the measured loop: a switch into a pane that
## has not painted yet skips exactly the focus-time work this bench exists to
## measure (measured 2026-11-11: the incoming pane held 0-24 characters at
## every switch, and the bench reported 37 ms for a switch whose real-store cost
## was 992 ms). An empty incoming pane is a failure, not a fast number.
##
## A real display driver is required: under `--headless` `frame_post_draw`
## never fires. POSIX only - the default payloads run through `/bin/sh -c`.

const SANDBOX_ENV := "GPTY_TEST_USER_DIR"

## The `draw_bench` flood shape: a full screen repaint every 0.4 s, so the
## incoming pane's frame is the expensive one.
const FLOOD := "while :; do printf '\\033[2J\\033[H'; seq -f 'row %g 0123456789 abcdefghijklmnopqrstuvwxyz' 1 70; sleep 0.4; done"
const QUIET := "echo quiet; sleep 600"

## A pane is settled once its screen is non-empty and its grid has not moved
## for this many frames - or once it has been filled for `SETTLE_MIN_MS`, which
## is how a payload that never goes quiet (the flood) settles.
const SETTLE_QUIET_FRAMES := 8
const SETTLE_MIN_MS := 1500
const SETTLE_MAX_MS := 20000

var _workspace: Control = null
var _settings: Node = null
var _store: Node = null
var _active := 0


func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		_fail("switch_bench needs a real display driver (frame_post_draw never fires headless)")
		return
	if OS.get_name() == "Windows":
		_fail("switch_bench is POSIX-only: its payloads run through /bin/sh -c")
		return
	var sandbox := OS.get_environment(SANDBOX_ENV)
	if not BasePersistenceManager.is_real_absolute_path(sandbox):
		_fail("%s must name an absolute directory; run scripts/ui-sandbox" % SANDBOX_ENV)
		return

	var reps := _reps()
	var size := _window_size()
	print("switch_bench: start sandbox=%s" % sandbox)
	_settings = root.get_node("SettingsManager")
	_store = root.get_node("WorkspaceStore")
	# In-memory settings only: the sandbox already keeps the stores private.
	_settings.cfg_cursor_blink = false
	_settings.cfg_check_updates = false
	_settings.cfg_show_titlebar = true
	_settings.cfg_window_size = size
	_settings.cfg_window_mode = 0
	_settings.cfg_max_fps = 165
	_settings.apply_ui_scale()
	_settings.apply_appearance()
	# The focus-time half of a switch is the accessibility publish of the screen
	# it arrives at (992 ms of the reporter's 992-1020 ms store), and it only
	# runs when the app's a11y gate is open - a developer's session usually has
	# no screen reader, so the bench would measure a switch with that work
	# switched off. Force it on for the run and say so.
	A11y.force_enabled = 1
	_seed()
	print("switch_bench: seeded (a11y forced on)")

	_workspace = load("res://scenes/main.tscn").instantiate()
	root.add_child(_workspace)
	await _settle_window(size)
	print("switch_bench: window %s" % root.size)
	await _settle()

	# Untyped on purpose: a `TerminalManager` annotation makes GDScript compile
	# `terminal_manager.gd` (which names the autoloads) while a `-s` script is
	# still loading, before those singletons exist - the `ui_capture` rule.
	var tm = _workspace._tm
	print("switch_bench: window=%dx%d workspaces=%d panes=%d reps=%d" % [
		size.x, size.y, _workspace._workspaces.size(), tm.tiles.size(), reps])
	if _workspace._workspaces.size() < 2:
		_fail("the store must restore two workspaces (got %d)" % _workspace._workspaces.size())
		return

	# The mode round trip, measured without switching: 20 calls where one would
	# do. Before the idempotence guard this is the cost every switch paid.
	var mode_us := 0
	for _i in 20:
		var t := Time.get_ticks_usec()
		_workspace._chrome.apply_mode()
		mode_us += Time.get_ticks_usec() - t
	await process_frame
	print("switch_bench: apply_mode_us=%.1f (per call, %d calls)" % [float(mode_us) / 20.0, 20])

	# Warm-up: the first switch into a workspace builds/lays out its panes for
	# the first time, which is not the steady-state cost under test. It must end
	# on the workspace the measured loop starts from (0), or the loop's first
	# switch is a no-op that re-prints the warm-up's numbers. Each workspace's
	# pane is settled while it is on screen: switching away one frame after
	# arriving left the incoming grid empty, so the focus-time work a real
	# switch pays - the publish of the screen it arrives at - was never there
	# to measure.
	await _switch(1, false)
	await _settle_pane(1)
	await _switch(0)
	await _settle_pane(0)
	print("switch_bench: warm-up done at workspace %d" % _active)

	var forward: Array[int] = []
	var backward: Array[int] = []
	var forward_frame: Array[int] = []
	var backward_frame: Array[int] = []
	for rep in reps:
		await _switch(1)
		forward.append(_last_sync_us)
		forward_frame.append(_last_frame_us)
		print("switch_bench: rep=%d to=1 sync_us=%d frame_us=%d chars=%d fetch_ms=%.2f draw_ms=%.2f backoff_ms=%.2f"
			% [rep + 1, _last_sync_us, _last_frame_us, _last_chars, _last_fetch_ms, _last_draw_ms, _last_backoff_ms])
		await _switch(0)
		backward.append(_last_sync_us)
		backward_frame.append(_last_frame_us)
		print("switch_bench: rep=%d to=0 sync_us=%d frame_us=%d chars=%d fetch_ms=%.2f draw_ms=%.2f backoff_ms=%.2f"
			% [rep + 1, _last_sync_us, _last_frame_us, _last_chars, _last_fetch_ms, _last_draw_ms, _last_backoff_ms])

	print("switch_bench: median 0->1 sync_us=%d frame_us=%d" % [_median(forward), _median(forward_frame)])
	print("switch_bench: median 1->0 sync_us=%d frame_us=%d" % [_median(backward), _median(backward_frame)])
	quit(0)


# ── One switch ─────────────────────────────────────────────────────────

var _last_sync_us := 0
var _last_frame_us := 0
var _last_fetch_ms := -1.0
var _last_draw_ms := -1.0
var _last_backoff_ms := -1.0
## Characters on the incoming pane's screen at the switch: the bench must never
## report a switch into an empty one.
var _last_chars := 0


## The pane a workspace shows: the one its last switch left active, else its
## first tile's body. Null when the workspace has no pane at all.
func _pane_of(ws_index: int) -> Control:
	var tm = _workspace._workspaces[ws_index].tm
	if tm.last_body != null:
		return tm.last_body
	if tm.tiles.size() > 0:
		return tm._find_body(tm.tiles[0].wrapper)
	return null


## Wait until a workspace's pane has a screen worth switching into: non-empty,
## its grid quiet for `SETTLE_QUIET_FRAMES`, or filled for `SETTLE_MIN_MS` when
## the payload never goes quiet. An empty pane fails the run - that is the bug
## this bench was fixed for.
func _settle_pane(ws_index: int) -> bool:
	var pane := _pane_of(ws_index)
	if pane == null:
		_fail("workspace %d has no pane to settle" % ws_index)
		return false
	var start := Time.get_ticks_msec()
	var last_gen: int = pane._terminal.get_grid_generation()
	var quiet := 0
	while Time.get_ticks_msec() - start < SETTLE_MAX_MS:
		await process_frame
		var chars: int = pane.visible_text().length()
		var gen: int = pane._terminal.get_grid_generation()
		if chars > 0 and gen == last_gen:
			quiet += 1
		else:
			quiet = 0
		last_gen = gen
		if chars > 0 and (quiet >= SETTLE_QUIET_FRAMES \
				or Time.get_ticks_msec() - start >= SETTLE_MIN_MS):
			print("switch_bench: settled workspace %d chars=%d gen=%d" % [ws_index, chars, gen])
			return true
	_fail("workspace %d's pane never filled its screen (chars=%d)" % [
		ws_index, pane.visible_text().length()])
	return false

## Switch to a workspace and record what the frame cost. `require_screen` is
## false for the warm-up's first arrival, which is the one switch that may land
## on a pane that has not painted yet — its settle fills it right after.
func _switch(to: int, require_screen: bool = true) -> void:
	if to == _active:
		# A no-op would leave `_last_*` at the previous switch's numbers and the
		# loop would print them as a fresh measurement.
		_fail("asked to switch to workspace %d while it is already active" % to)
		return
	var t0 := Time.get_ticks_usec()
	_workspace._switch_workspace(to)
	_last_sync_us = Time.get_ticks_usec() - t0
	_active = to
	# The first frame that draws the incoming workspace: its terminal's
	# `_process` (fetch/repack) and `_draw` both run in it.
	var t1 := Time.get_ticks_usec()
	await RenderingServer.frame_post_draw
	_last_frame_us = Time.get_ticks_usec() - t1
	var pane := _pane_of(to)
	_last_fetch_ms = float(pane.get("_fetch_ms")) if pane and "_fetch_ms" in pane else -1.0
	_last_draw_ms = float(pane.get("_draw_ms")) if pane and "_draw_ms" in pane else -1.0
	_last_backoff_ms = float(pane.get("_sync_backoff")) if pane and "_sync_backoff" in pane else -1.0
	_last_chars = pane.visible_text().length() if pane != null else 0
	if require_screen and _last_chars == 0:
		_fail("workspace %d's pane was empty at the switch - a switch into an untouched pane skips the focus-time work this bench measures" % to)


# ── Seeding ────────────────────────────────────────────────────────────

## Two workspaces through the real store, so the panes are built by the restore
## path the app uses - a spawn would skip the layout parse under test.
func _seed() -> void:
	var tiles_a: Array = [_tile("switch-a", _cmd("SWITCH_CMD_A", QUIET))]
	var tiles_b: Array = [_tile("switch-b", _cmd("SWITCH_CMD_B", FLOOD))]
	var workspaces: Array[Dictionary] = [
		{"name": "A", "cwd": "", "layout": tiles_a},
		{"name": "B", "cwd": "", "layout": tiles_b},
	]
	_store.save(0, workspaces)
	# Both tiles name a program that is not the configured default shell, which
	# is the restore gate's decision to ask about; a trust dialog is not the
	# state this bench measures, so the plans it seeded are approved under a
	# bench-owned name (the `ui_capture` pattern).
	var plans: Array = []
	for td in tiles_a + tiles_b:
		var key := PaneTypes.tile_plan_key(td)
		if key != "":
			plans.append(key)
	if not plans.is_empty():
		var trusted: Node = root.get_node("TrustedStore")
		trusted.approve_builtin("switch-bench", GptyTerminal.get_app_version(), plans)


func _cmd(env_name: String, script: String) -> Dictionary:
	var program := OS.get_environment(env_name).strip_edges()
	if program != "":
		return {"command": program, "shell_args": []}
	return {"command": "/bin/sh", "shell_args": ["-c", script]}


func _tile(id: String, cmd: Dictionary) -> Dictionary:
	var settings := {"type": "terminal", "attachment_id": id}
	for key in cmd:
		settings[key] = cmd[key]
	return {
		"col": 0, "row": 0, "cspan": PaneTypes.GRID, "rspan": PaneTypes.GRID,
		"settings": settings,
	}


# ── Harness ────────────────────────────────────────────────────────────

func _reps() -> int:
	var raw := OS.get_environment("SWITCH_REPS").strip_edges()
	if raw == "":
		return 5
	if not raw.is_valid_int():
		_fail("SWITCH_REPS must be a whole number (got '%s')" % raw)
		return 5
	return clampi(int(raw), 3, 50)


func _window_size() -> Vector2i:
	var raw := OS.get_environment("SWITCH_WINDOW").strip_edges()
	if raw == "":
		return Vector2i(2053, 1382)
	var parts := raw.split("x")
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		_fail("SWITCH_WINDOW must be WxH (got '%s')" % raw)
		return Vector2i(2053, 1382)
	return Vector2i(parts[0].to_int(), parts[1].to_int())


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


func _settle() -> void:
	for _i in 4:
		await process_frame


func _median(values: Array[int]) -> int:
	if values.is_empty():
		return 0
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2]


func _fail(message: String) -> void:
	push_error("switch_bench: " + message)
	print("switch_bench: FAIL " + message)
	quit(1)
