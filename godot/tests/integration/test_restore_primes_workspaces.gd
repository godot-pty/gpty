extends GutTest
# A restored workspace that has never been visited must already have its tiles
# laid out and their programs started: the first visit is then the same view
# change as every later one (roadmap: "The first workspace switch after launch
# takes 551 ms" - the first visit measured 551 ms against 12.3 ms).
#
# The observable is `child_start_resolved()` on the *inactive* workspace's
# terminal. `_restore_into` attaches every workspace's bodies, but only the
# active grid was ever laid out, so before the launch primer the inactive
# terminal stayed unresolved until somebody switched to it.

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

var _ws: Control

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()
	SettingsManager.cfg_default_rows = 24
	SettingsManager.cfg_default_cols = 80
	# Two workspaces, one terminal each: the store shape a real launch restores.
	MockAutoloads.set_store(WorkspaceStore.FILE, {
		"active": 0,
		"workspaces": [
			{"name": "First", "layout": [_tile()]},
			{"name": "Second", "layout": [_tile()]},
		],
	})

func after_each():
	# Free synchronously while mocks are still active, and only after the
	# workspace's deferred concept push (2 s after `_ready`) has landed - a
	# resume on a freed instance is an engine error, which GUT counts as a
	# failure.
	if _ws:
		await get_tree().create_timer(2.1).timeout
		if _ws.get_parent():
			_ws.get_parent().remove_child(_ws)
		_ws.free()
		_ws = null
	MockAutoloads.teardown()

func _tile() -> Dictionary:
	return {"col": 0, "row": 0, "cspan": PaneTypes.GRID, "rspan": PaneTypes.GRID,
		"settings": {"type": "terminal"}}

func _start_workspace() -> Control:
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	return ws

## The primer supplies one workspace per frame from `_process`.
func _wait_started(body: Control, timeout_ms: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if body.child_start_resolved():
			return true
		await get_tree().create_timer(0.02).timeout
	return false

func test_a_restored_workspace_starts_its_panes_before_it_is_viewed():
	var ws = await _start_workspace()
	assert_eq(ws._workspaces.size(), 2, "the store must restore both workspaces")
	assert_eq(ws._active, 0, "the store's active workspace is the one shown")
	var tile: Dictionary = ws._workspaces[1].tm.tiles[0]
	var body = ws._workspaces[1].tm._find_body(tile.wrapper)
	assert_not_null(body, "the second workspace must own its pane body")
	assert_true(await _wait_started(body, 3000),
		"a restored workspace's terminal starts without being switched to")
	assert_gt(tile.wrapper.size.x, 0.0,
		"the primer gives the tile the rect it will be drawn at")

func test_priming_does_not_restart_a_running_child():
	var ws = await _start_workspace()
	var active_body = ws._workspaces[0].tm._find_body(ws._workspaces[0].tm.tiles[0].wrapper)
	assert_true(await _wait_started(active_body, 3000), "the shown workspace starts as before")
	var body = ws._workspaces[1].tm._find_body(ws._workspaces[1].tm.tiles[0].wrapper)
	assert_true(await _wait_started(body, 3000))
	var before_pid = JSON.parse_string(str(active_body._terminal.get_status())).get("pid")
	assert_not_null(before_pid, "the shown workspace's child must be live for the comparison")
	for _i in 10:
		await get_tree().process_frame
	var after_pid = JSON.parse_string(str(active_body._terminal.get_status())).get("pid")
	assert_eq(after_pid, before_pid, "priming must not start a second child")
