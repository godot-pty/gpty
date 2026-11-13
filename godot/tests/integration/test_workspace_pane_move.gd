extends GutTest
# Pane moves between workspaces: policy A (a terminal moves with the panes
# that follow it), the defects the move exposes, and the refusal rules.
#
# The PTY is the stake: a move re-parents the wrapper and must not respawn or
# kill anything. The extension's own `Drop` is the only teardown, so the
# session id and the child's liveness are the proof.
#
# One workspace for the whole script, like `test_ipc_dispatch_contract.gd`:
# each instance schedules a deferred concept push 2 s after `_ready`. Every
# test builds its own target workspace and closes it, which is also the
# cleanup - `_close_workspace_now` resets that manager and frees its grid, so
# the moved panes die with the workspace they were moved into.

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

var _ws: Control

func before_all():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()
	SettingsManager.cfg_default_rows = 24
	SettingsManager.cfg_default_cols = 80
	ConceptManager.plugin_concepts_source = func(): return "[]"
	ConceptManager.refresh_plugin_concepts()
	_ws = WorkspaceScript.new()
	add_child(_ws)
	_ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame

func after_all():
	# Let the workspace's deferred concept push land while it is still alive.
	await get_tree().create_timer(2.1).timeout
	remove_child(_ws)
	_ws.free()
	_ws = null
	ConceptManager.plugin_concepts_source = Callable()
	ConceptManager._plugin_concept_entries = []
	MockAutoloads.teardown()

func _source() -> Dictionary:
	return _ws._workspaces[0]

func _spawn(type_name: String, opts := {}) -> Control:
	var body = _ws._spawn_pane(type_name, opts, false)
	assert_not_null(body, "spawning a %s pane must work" % type_name)
	return body

## A fresh empty workspace, switched away from so the source stays active -
## the GUI moves a pane out of the workspace the user is looking at.
func _target() -> Dictionary:
	var before: int = _ws._workspaces.size()
	_ws._add_workspace()
	assert_eq(_ws._workspaces.size(), before + 1, "a workspace must be created")
	var target: Dictionary = _ws._workspaces[before]
	_ws._switch_workspace(0)
	return target

func _close(target: Dictionary) -> void:
	var idx: int = _ws._workspaces.find(target)
	if idx != -1:
		_ws._close_workspace_now(idx)

func _geometry(tm: TerminalManager) -> Array:
	var out := []
	for t in tm.tiles:
		out.append("%d,%d,%d,%d" % [t.col, t.row, t.cspan, t.rspan])
	return out

func _status(body: Control) -> Dictionary:
	var raw = JSON.parse_string(str(body._terminal.get_status()))
	return raw if raw is Dictionary else {}

# ── Policy A: a terminal brings its follower ───────────────────────────

func test_terminal_moves_with_its_reasoning_follower():
	var term := _spawn("terminal")
	var follower := _spawn("reasoning")
	follower.apply_settings({"source_attachment_id": str(term.attachment_id)})
	assert_eq(str(follower.source_attachment_id), str(term.attachment_id),
		"the follower must watch the terminal")
	var target := _target()
	var src_id := term.get_instance_id()
	var follower_id := follower.get_instance_id()

	_ws._move_panes_to(term, str(target.name))

	assert_eq(term.get_instance_id(), src_id, "the terminal must be the same node")
	assert_eq(follower.get_instance_id(), follower_id, "the follower must be the same node")
	assert_false(_ws._workspace_for_body(term).is_empty(), "the terminal must have a workspace")
	assert_eq(_ws._workspace_for_body(term).tm, target.tm, "the terminal must move")
	assert_eq(_ws._workspace_for_body(follower).tm, target.tm,
		"the follower must move with it")
	assert_eq(target.tm.tiles.size(), 2, "both panes must land in the target")
	_close(target)

func test_move_keeps_the_pty_alive():
	var term := _spawn("terminal")
	# The child starts on the first laid-out size, a frame after the spawn.
	await get_tree().process_frame
	var session := str(term._terminal.get_terminal_session_id())
	assert_ne(session, "", "a live terminal has a session id")
	var child_alive := bool(_status(term).get("child_alive", false))
	var target := _target()

	var refusal: String = _ws._move_panes_into([term], _source(), target)

	assert_eq(refusal, "", "the move must succeed")
	assert_eq(str(term._terminal.get_terminal_session_id()), session,
		"the PTY session must be the same one, not a respawn")
	assert_eq(bool(_status(term).get("child_alive", false)), child_alive,
		"the child must survive the reparent")
	_close(target)

func test_moved_grid_tiles_the_grid():
	var term := _spawn("terminal")
	var follower := _spawn("reasoning")
	follower.apply_settings({"source_attachment_id": str(term.attachment_id)})
	var target := _target()

	_ws._move_panes_to(term, str(target.name))

	var cells := {}
	for t in target.tm.tiles:
		for x in range(t.col, t.col + t.cspan):
			for y in range(t.row, t.row + t.rspan):
				var key := "%d:%d" % [x, y]
				assert_false(cells.has(key), "no two tiles may overlap at %s" % key)
				cells[key] = true
	assert_eq(cells.size(), PaneTypes.GRID * PaneTypes.GRID,
		"the target's tiles must cover the whole grid exactly once")
	_close(target)

func test_full_grid_refuses_and_moves_nothing():
	var term := _spawn("terminal")
	var target := _target()
	# A full 10x10 tiling of 6x6 tiles: no tile can be halved at MIN_TILE.
	var full: Array[Dictionary] = []
	for x in 10:
		for y in 10:
			full.append({"wrapper": null, "col": x * 6, "row": y * 6,
				"cspan": 6, "rspan": 6})
	var saved: Array[Dictionary] = target.tm.tiles
	target.tm.tiles = full
	assert_false(target.tm.plan_adopt(1), "the synthetic grid must be full")
	var src_before := _geometry(_source().tm)
	var dst_before := _geometry(target.tm)

	var refusal: String = _ws._move_panes_into([term], _source(), target)

	assert_string_contains(refusal, "full", "the refusal must say the grid is full")
	assert_eq(_geometry(_source().tm), src_before, "a refusal must not touch the source")
	assert_eq(_geometry(target.tm), dst_before, "a refusal must not touch the target")
	assert_true(is_instance_valid(term), "a refused move must not free the pane")
	assert_eq(_ws._workspace_for_body(term).tm, _source().tm,
		"the pane must still be in its source workspace")
	target.tm.tiles = saved
	_ws._kill_now(term)
	_close(target)

func test_moved_label_is_unique_in_target():
	var target := _target()
	var resident: Control = _ws._spawn_pane_into(target, "terminal", {}, false)
	assert_not_null(resident, "the target must get a terminal")
	assert_eq(str(resident.pane_label), "T1", "labels restart per workspace")
	var term := _spawn("terminal")
	assert_eq(str(term.pane_label), "T2", "the source numbers its own panes")
	# Force the collision a real reused label produces.
	term.pane_label = "T1"

	var refusal: String = _ws._move_panes_into([term], _source(), target)

	assert_eq(refusal, "", "the move must succeed")
	var seen := {}
	for t in target.tm.tiles:
		var body = target.tm._find_body(t.wrapper)
		if body == null:
			continue
		assert_false(seen.has(str(body.pane_label)),
			"labels in one workspace must stay unique (%s)" % body.pane_label)
		seen[str(body.pane_label)] = true
	assert_eq(str(term.pane_label), "T2", "the admitted pane takes the next free label")
	_close(target)

# ── The active pane and the focus rule ────────────────────────────────

func test_active_pane_does_not_follow_a_move():
	var resident: Control = _source().tm._find_body(_source().tm.tiles[0].wrapper)
	assert_not_null(resident, "the seeded terminal must exist")
	var term := _spawn("terminal")
	_ws.activate_pane(term)
	assert_eq(_ws._tm.last_body, term, "the spawned pane is the active one")
	var target := _target()
	_ws._switch_workspace(0)
	_ws.activate_pane(term)

	var refusal: String = _ws._move_panes_into([term], _source(), target)

	assert_eq(refusal, "", "the move must succeed")
	assert_eq(_ws._workspace_for_body(term).tm, target.tm, "the pane must move")
	assert_ne(_ws._tm.last_body, term,
		"the active workspace must not remember a pane it no longer owns")
	assert_eq(_ws._tm.last_body, resident,
		"the fallback must name a pane that is still there")
	_close(target)

# ── Signals follow the pane, not the workspace it was wired in ────────

func test_moved_pane_requests_into_its_current_workspace():
	var tree := _spawn("file_tree")
	var target := _target()

	var refusal: String = _ws._move_panes_into([tree], _source(), target)
	assert_eq(refusal, "", "the move must succeed")
	var before: int = _ws._pane_bodies(target).size()

	tree.request_pane.emit("code_viewer", {})
	await get_tree().process_frame
	await get_tree().process_frame

	assert_eq(_ws._pane_bodies(target).size(), before + 1,
		"the requested pane must land beside the pane that asked")
	for body in _ws._pane_bodies(target):
		assert_eq(str(body._pane_type()), "code_viewer" if body != tree else "file_tree",
			"the target holds the viewer and the tree")
	_close(target)

func test_badge_resumes_after_a_move():
	var term := _spawn("terminal")
	var target := _target()

	var refusal: String = _ws._move_panes_into([term], _source(), target)
	assert_eq(refusal, "", "the move must succeed")
	assert_false(_ws._agent_state_primed.has(term.get_instance_id()),
		"a moved pane must be re-primed in its new workspace")
	await get_tree().process_frame
	assert_true(_ws._agent_state_primed.has(term.get_instance_id()),
		"the scan must settle the pane again")

	term.agent_state_changed.emit("working")

	assert_eq(str(term._badge_state), "working",
		"the badge must take the state the moved pane emits")
	_close(target)

# ── The notes policy A cannot infer ───────────────────────────────────

func test_move_notes():
	var target := _target()
	var resident: Control = _ws._spawn_pane_into(target, "terminal", {}, false)
	assert_not_null(resident, "the target must hold another terminal")
	var term := _spawn("terminal")
	var follower := _spawn("reasoning")
	follower.apply_settings({"source_attachment_id": str(term.attachment_id)})
	var inspector := _spawn("inspector")
	inspector.set("auto_run", true)

	var alone: Array = _ws._move_notes([follower], target)
	assert_eq(alone.size(), 1, "a follower moved alone must be reported")
	assert_string_contains(alone[0], "observe nothing")
	assert_string_contains(alone[0], str(term.attachment_id))

	var refusal: String = _ws._move_panes_into([term, follower], _source(), target)
	assert_eq(refusal, "", "the move must succeed")
	assert_eq(_ws._move_notes([term, follower], target), [],
		"a follower moved with its source needs no note")

	var inspector_notes: Array = _ws._move_notes([inspector], target)
	assert_eq(inspector_notes.size(), 1, "an auto-run Inspector must be reported")
	assert_string_contains(inspector_notes[0], "auto-runs")

	_ws._kill_now(inspector)
	_close(target)
