extends GutTest
# GUI-135: the frame cap and every live terminal's sync cadence resolve against
# the window's screen, and a window moved to a display with a different refresh
# rate used to keep the launch display's numbers until the next settings change
# or restart. The screen/rate seams stand in for a second display, so the move
# is deterministic on a one-display runner.

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

var _ws: Workspace
var _saved_screen: Callable
var _saved_rate: Callable
var _saved_engine_fps: int
var _screen := 0
var _rate := 60.0

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()
	# The seams are process-global statics: save what this suite found and put
	# them back, so a later suite never inherits a display.
	_saved_screen = DisplayRate.window_screen
	_saved_rate = DisplayRate.screen_hz
	_saved_engine_fps = Engine.max_fps
	_screen = 0
	_rate = 60.0
	DisplayRate.window_screen = _seam_screen
	DisplayRate.screen_hz = _seam_rate

func after_each():
	DisplayRate.window_screen = _saved_screen
	DisplayRate.screen_hz = _saved_rate
	Engine.max_fps = _saved_engine_fps
	if _ws:
		if _ws.get_parent():
			_ws.get_parent().remove_child(_ws)
		_ws.free()
		_ws = null
	MockAutoloads.teardown()

# Method references, not lambdas: a lambda captures a member by value at
# creation, and these must read the display the test moved the window to.
func _seam_screen() -> int:
	return _screen
func _seam_rate(_ignored: int) -> float:
	return _rate

func _make() -> Workspace:
	_ws = WorkspaceScript.new()
	add_child(_ws)
	_ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame
	return _ws

func _pane() -> TerminalPane:
	var tiles := _ws._tm.tiles
	assert_gt(tiles.size(), 0, "a fresh workspace holds one terminal")
	if tiles.is_empty():
		return null
	var body := _ws._tm._find_body(tiles[0].wrapper) as TerminalPane
	assert_not_null(body, "the fresh tile holds a terminal body")
	return body

func _move_to(screen: int, rate: float) -> void:
	_screen = screen
	_rate = rate
	_ws._check_display_change()

# ── The cap ────────────────────────────────────────────────────────────

func test_a_native_cap_follows_the_window_to_a_faster_display():
	SettingsManager.cfg_max_fps = -1
	await _make()
	assert_eq(Engine.max_fps, 60, "the launch display's rate caps the engine")
	_move_to(1, 165.0)
	assert_eq(Engine.max_fps, 165,
		"the new display's rate caps it after the move")

func test_an_explicit_cap_does_not_follow_the_move():
	SettingsManager.cfg_max_fps = 60
	await _make()
	var pane := _pane()
	assert_eq(Engine.max_fps, 60, "an explicit cap applies at launch")
	assert_almost_eq(pane._sync_interval, 1.0 / 60.0, 0.000001,
		"a pane with its own cap runs at that cap")
	_move_to(1, 165.0)
	assert_eq(Engine.max_fps, 60, "an explicit cap is left alone on a move")
	assert_almost_eq(pane._sync_interval, 1.0 / 60.0, 0.000001,
		"and the pane's own cadence is left alone too")

func test_a_rate_change_on_the_same_screen_is_noticed():
	SettingsManager.cfg_max_fps = -1
	await _make()
	_move_to(0, 120.0)
	assert_eq(Engine.max_fps, 120,
		"raising the display's mode re-resolves the cap")
	assert_almost_eq(_pane()._sync_interval, 1.0 / 120.0, 0.000001,
		"and the pane cadence with it")

func test_an_unknown_rate_keeps_the_unlimited_cap_and_the_fallback_cadence():
	SettingsManager.cfg_max_fps = -1
	_rate = 0.0
	await _make()
	assert_eq(Engine.max_fps, 0,
		"a display that reports no rate leaves the engine uncapped")
	assert_almost_eq(_pane()._sync_interval, 1.0 / DisplayRate.FALLBACK_HZ, 0.000001,
		"while the pane cadence falls back to 60 Hz")

func test_an_unchanged_display_reapplies_nothing():
	SettingsManager.cfg_max_fps = -1
	await _make()
	Engine.max_fps = 999
	_ws._check_display_change()
	assert_eq(Engine.max_fps, 999,
		"the poll must not rewrite the cap while the display is unchanged")

# ── Every live pane, including a hidden workspace ─────────────────────

func test_a_live_pane_cadence_resolves_at_launch_and_follows_the_move():
	SettingsManager.cfg_max_fps = -1
	_rate = 144.0
	await _make()
	assert_almost_eq(_pane()._sync_interval, 1.0 / 144.0, 0.000001,
		"a fresh pane resolves the launch display, not the 1/60 default")
	_move_to(1, 60.0)
	assert_almost_eq(_pane()._sync_interval, 1.0 / 60.0, 0.000001,
		"and its follow-the-display cadence moves with the window")

func test_a_hidden_workspace_pane_follows_the_move():
	SettingsManager.cfg_max_fps = -1
	await _make()
	var live := _pane()
	_ws._add_workspace()
	var hidden = _ws._spawn_pane("terminal", {})
	assert_not_null(hidden, "the second workspace holds a terminal")
	_ws._switch_workspace(0)
	_move_to(1, 144.0)
	assert_almost_eq(live._sync_interval, 1.0 / 144.0, 0.000001,
		"the visible workspace's pane follows the move")
	assert_almost_eq(hidden._sync_interval, 1.0 / 144.0, 0.000001,
		"a hidden workspace's pane is live, so it follows too")

# ── The notice is a low-frequency timer, not a per-frame read ─────────

func test_the_screen_watch_is_a_low_frequency_timer():
	await _make()
	assert_not_null(_ws._screen_watch, "the window watches its screen")
	assert_almost_eq(_ws._screen_watch.wait_time, WorkspaceScript.SCREEN_POLL_SECONDS,
		0.000001, "the poll uses the one declared interval")
	assert_gt(_ws._screen_watch.wait_time, 1.0,
		"the screen is re-read on a timer, never per frame")
	assert_false(_ws._screen_watch.one_shot, "the watch repeats")
