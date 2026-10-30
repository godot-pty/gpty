extends GutTest
# The window's live-pane ceiling (`Workspace.MAX_LIVE_PANES`): one count over
# every workspace, one refusal text, enforced where panes are created so the
# control socket, the palette and a layout/profile file all share it.
#
# Reaching 96 real panes in a test would start 96 shells, so `PaddingWorkspace`
# stands in for the panes another workspace holds: the count is the only thing
# it adds to the shipped code, and every decision under test — the refusal's
# wording, the restore truncation, the room a close frees — is the real one.

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

## `pad` counts panes the test pretends are live elsewhere in the window; the
## real panes are counted by the shipped implementation.
class PaddingWorkspace extends Workspace:
	var pad := 0

	func _live_pane_count() -> int:
		return super._live_pane_count() + pad

var _ws: Workspace

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()

func after_each():
	if _ws:
		if _ws.get_parent():
			_ws.get_parent().remove_child(_ws)
		_ws.free()
		_ws = null
	MockAutoloads.teardown()

func _make() -> Workspace:
	var ws = PaddingWorkspace.new()
	_ws = ws
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame
	return ws

## Fill the window up to the ceiling minus `room` panes, so the next `room`
## spawns are the ones under test.
func _leave_room(ws: Workspace, room: int) -> void:
	ws.pad = WorkspaceScript.MAX_LIVE_PANES - ws._live_pane_count() - room

## Pretend the window already holds `live` panes elsewhere. For a restore, whose
## first act is to reset the workspace it targets, the window's count after that
## reset is exactly `live`.
func _window_holds(ws: Workspace, live: int) -> void:
	ws.pad = live

# ── One count for the whole window ─────────────────────────────────────

func test_the_count_spans_every_workspace():
	var ws: Workspace = await _make()
	assert_eq(ws._live_pane_count(), 1, "a fresh window holds its one starting pane")
	ws._add_workspace()
	assert_not_null(ws._spawn_pane("code_viewer", {}))
	ws._switch_workspace(0)
	assert_not_null(ws._spawn_pane("code_viewer", {}))
	assert_eq(
		ws._live_pane_count(), 3,
		"a hidden workspace's panes keep their grid alive, so they count")

## The boundary is the constant itself: one pane short is not a refusal, the
## pane that fills it is, and the text names the number the constant holds.
func test_the_boundary_is_the_one_constant():
	var ws: Workspace = await _make()
	_leave_room(ws, 1)
	assert_eq(ws._pane_ceiling_refusal(), "", "a window below the ceiling has room")
	assert_not_null(ws._spawn_pane("code_viewer", {}), "the last free slot must be usable")
	var refusal: String = ws._pane_ceiling_refusal()
	assert_string_contains(
		refusal, "the limit is %d" % WorkspaceScript.MAX_LIVE_PANES,
		"the refusal must state the constant, never a second copy of the number")

# ── The control socket ─────────────────────────────────────────────────

func test_new_pane_past_the_ceiling_is_refused_and_starts_nothing():
	var ws: Workspace = await _make()
	watch_signals(ToastManager)
	var before: int = ws._tm.tiles.size()
	_leave_room(ws, 0)
	var answer = WorkspaceIpcHandlers.handle(ws, "newPane", {})
	assert_true(answer is Dictionary and answer.has("error"), "a caller at the ceiling is refused")
	assert_string_contains(
		str(answer["error"]["message"]), str(WorkspaceScript.MAX_LIVE_PANES),
		"the error must name the limit, not drop the request silently")
	assert_eq(ws._tm.tiles.size(), before, "a refused spawn must not add a tile")
	assert_signal_emitted(ToastManager, "toast_requested")

func test_pane_run_past_the_ceiling_is_refused():
	var ws: Workspace = await _make()
	var before: int = ws._tm.tiles.size()
	_leave_room(ws, 0)
	var answer = WorkspaceIpcHandlers.handle(ws, "paneRun", {"command": "true"})
	assert_true(answer is Dictionary and answer.has("error"), "paneRun shares the ceiling")
	assert_string_contains(str(answer["error"]["message"]), str(WorkspaceScript.MAX_LIVE_PANES))
	assert_eq(ws._tm.tiles.size(), before, "a refused paneRun must start nothing")

# ── Files ──────────────────────────────────────────────────────────────

func test_restore_stops_at_the_ceiling_and_names_the_rest():
	var ws: Workspace = await _make()
	watch_signals(ToastManager)
	_window_holds(ws, WorkspaceScript.MAX_LIVE_PANES - 2)
	var tiles: Array[Dictionary] = []
	for i in 5:
		tiles.append({
			"col": i * 6, "row": 0, "cspan": 6, "rspan": PaneTypes.GRID,
			"settings": {"type": "code_viewer"},
		})
	ws._restore_into(ws._workspaces[0], tiles)
	assert_eq(ws._tm.tiles.size(), 2, "a layout restores what fits, not every tile it names")
	assert_signal_emitted_with_parameters(ToastManager, "toast_requested", [{
		"text": "Restored 2 of 5 panes. Pane limit reached: this window holds %d panes (the limit is %d). Close a pane to make room."
			% [WorkspaceScript.MAX_LIVE_PANES, WorkspaceScript.MAX_LIVE_PANES],
		"level": ToastManager.WARN,
		"duration": 8.0,
		"source": "",
	}])

func test_restore_into_one_workspace_leaves_room_for_the_next():
	# Two restored workspaces share the one window ceiling: the store's second
	# workspace must not get a fresh allowance.
	var ws: Workspace = await _make()
	_window_holds(ws, WorkspaceScript.MAX_LIVE_PANES - 3)
	ws._add_workspace()
	var empty: Array[Dictionary] = []
	ws._restore_into(ws._workspaces[0], empty)
	assert_eq(ws._workspaces[0].tm.tiles.size(), 1, "an empty layout falls back to one terminal")
	var tiles: Array[Dictionary] = []
	for i in 5:
		tiles.append({"col": i * 6, "row": 0, "cspan": 6, "rspan": PaneTypes.GRID,
			"settings": {"type": "code_viewer"}})
	ws._restore_into(ws._workspaces[1], tiles)
	assert_eq(
		ws._workspaces[1].tm.tiles.size(), 2,
		"the second workspace got what the first left, not a fresh allowance")
	assert_eq(ws._live_pane_count(), WorkspaceScript.MAX_LIVE_PANES)

func test_a_restore_with_no_room_leaves_the_workspace_empty_and_says_it_once():
	var ws: Workspace = await _make()
	watch_signals(ToastManager)
	_window_holds(ws, WorkspaceScript.MAX_LIVE_PANES)
	var tiles: Array[Dictionary] = [{
		"col": 0, "row": 0, "cspan": PaneTypes.GRID, "rspan": PaneTypes.GRID,
		"settings": {"type": "code_viewer"},
	}]
	ws._restore_into(ws._workspaces[0], tiles)
	assert_eq(ws._tm.tiles.size(), 0, "with no room the empty-layout fallback is refused too")
	assert_signal_emit_count(ToastManager, "toast_requested", 1,
		"the notice says why the workspace is empty; a second toast must not repeat it")

# ── Room freed by a close ──────────────────────────────────────────────

func test_closing_a_pane_frees_room_for_one_more():
	var ws: Workspace = await _make()
	_leave_room(ws, 0)
	assert_null(ws._spawn_pane("code_viewer", {}), "the ceiling refuses a spawn")
	var body = ws._tm._find_body(ws._tm.tiles[0].wrapper)
	ws._kill_now(body)
	assert_not_null(ws._spawn_pane("code_viewer", {}), "the closed pane's room is usable again")
