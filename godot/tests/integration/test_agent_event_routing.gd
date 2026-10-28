extends GutTest
# Agent events are routed by the emitting PTY's FFI session id and delivered
# only inside that terminal's own workspace. A profile activated twice reuses
# the same logical ids, so the second instance is renamed and its companion is
# re-pointed before either body exists — without that, the companion followed
# the first workspace's terminal (it showed that stream, and once delivery is
# scoped it would hear nothing at all).

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

## Receiver shaped like a companion pane: records every delivery.
class EventProbe extends PaneBody:
	var events: Array = []

	func receive_agent_event(envelope: Dictionary, source_id: String) -> void:
		events.append({"envelope": envelope, "source_id": source_id})

var _ws: Control

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()
	SettingsManager.cfg_shell_env = ""

func after_each():
	if _ws:
		if _ws.get_parent():
			_ws.get_parent().remove_child(_ws)
		_ws.free()
		_ws = null
	MockAutoloads.teardown()

func _make_workspace() -> Control:
	var ws: Control = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame
	return ws

func _body_with_id(ws: Control, workspace: int, id: String) -> Control:
	var tm: TerminalManager = ws._workspaces[workspace].tm
	for t in tm.tiles:
		var body = tm._find_body(t.wrapper)
		if body != null and str(body.get("attachment_id")) == id:
			return body
	return null

## A probe enters its workspace through the real attach path and owns a tile.
func _attach_probe(ws: Control, probe: PaneBody, workspace: int):
	probe.name = "Body"  # `_find_body` resolves tiles by this fixed child name
	var wsd: Dictionary = ws._workspaces[workspace]
	var w: Control = wsd.tm._build_wrapper_body(probe, "Probe")
	ws._attach_pane_into(wsd, w, probe)
	wsd.tm.tiles.append({wrapper = w, col = 0, row = 0,
		cspan = PaneTypes.MIN_TILE, rspan = PaneTypes.MIN_TILE})

## A companion profile: a terminal and a Reasoning pane that follows it, with
## the logical ids a shipped profile uses.
func _agent_profile() -> Dictionary:
	return {"name": "Agent", "tiles": [
		{"col": 0, "row": 0, "cspan": 30, "rspan": PaneTypes.GRID,
		 "settings": {"type": "terminal", "pane_name": "Agent Terminal",
		 	"attachment_id": "agent-terminal"}},
		{"col": 30, "row": 0, "cspan": 30, "rspan": PaneTypes.GRID,
		 "settings": {"type": "reasoning", "pane_name": "Reasoning",
		 	"attachment_id": "agent-reasoning",
		 	"source_attachment_id": "agent-terminal"}},
	]}

## The unscoped fan-out delivered every event to every receiver in every
## workspace, with the source id as the only filter.
func test_events_reach_only_the_source_terminal_s_workspace():
	var ws := await _make_workspace()
	var tm1: TerminalManager = ws._workspaces[0].tm
	var term_a = tm1._find_body(tm1.tiles[0].wrapper)
	assert_not_null(term_a, "the workspace starts with a terminal")
	var probe_a := EventProbe.new()
	_attach_probe(ws, probe_a, 0)

	ws._add_workspace()
	await get_tree().process_frame
	var term_b = ws._spawn_pane_into(ws._workspaces[1], "terminal", {})
	assert_not_null(term_b, "the second workspace gets a terminal")
	var probe_b := EventProbe.new()
	_attach_probe(ws, probe_b, 1)

	var sid_a := str(term_a._terminal.get_terminal_session_id())
	var sid_b := str(term_b._terminal.get_terminal_session_id())
	assert_ne(sid_a, "", "the first PTY must have a session id")
	assert_ne(sid_b, sid_a, "each PTY has its own session id")

	ws._route_agent_events([
		{"terminal_session_id": sid_a, "event": {"name": "agent.started"}},
		{"terminal_session_id": sid_b, "event": {"name": "session.bound",
			"omp_session_id": "s-b"}},
	])

	assert_eq(probe_a.events.size(), 1, "A's receiver hears A's one event")
	assert_eq(str(probe_a.events[0]["source_id"]), str(term_a.attachment_id))
	assert_eq(str(probe_a.events[0]["envelope"]["event"]["name"]), "agent.started")
	assert_eq(probe_b.events.size(), 1, "B's receiver hears only B's event")
	assert_eq(str(probe_b.events[0]["source_id"]), str(term_b.attachment_id))
	assert_eq(str(probe_b.events[0]["envelope"]["event"]["name"]), "session.bound")

	await get_tree().create_timer(2.1).timeout

## The reported 2026-10-28 case: activate the same profile in a second
## workspace. Its terminal is renamed (ids stay globally unique for IPC), and
## the companion must follow the renamed terminal — not keep pointing at the
## first workspace's id.
func test_a_profile_activated_twice_keeps_its_companion_on_its_own_terminal():
	var ws := await _make_workspace()
	ws._do_activate(_agent_profile(), false)
	await get_tree().process_frame

	var term_a = _body_with_id(ws, 0, "agent-terminal")
	var reason_a = _body_with_id(ws, 0, "agent-reasoning")
	assert_not_null(term_a, "W1's terminal keeps the profile's logical id")
	assert_not_null(reason_a, "W1's companion is restored")
	assert_eq(str(reason_a.source_attachment_id), "agent-terminal")

	# The user's env for that logical pane must spawn into every instance.
	PaneEnvStore.set_env("agent-terminal", "OWNED=1")

	ws._do_activate(_agent_profile(), false, true)
	await get_tree().process_frame
	assert_eq(ws._workspaces.size(), 2, "the profile opens in its own workspace")

	var term_b = null
	var reason_b = null
	var tm2: TerminalManager = ws._workspaces[1].tm
	for t in tm2.tiles:
		var body = tm2._find_body(t.wrapper)
		if body is TerminalPane:
			term_b = body
		elif body is ReasoningPane:
			reason_b = body
	assert_not_null(term_b, "W2's terminal is restored")
	assert_not_null(reason_b, "W2's companion is restored")
	assert_ne(str(term_b.attachment_id), "agent-terminal",
		"the duplicate terminal is renamed to keep ids globally unique")
	assert_eq(str(reason_b.source_attachment_id), str(term_b.attachment_id),
		"the companion follows its own renamed terminal")
	assert_eq(str(term_a.attachment_id), "agent-terminal", "W1's id is untouched")
	assert_eq(str(reason_a.source_attachment_id), "agent-terminal")

	assert_eq(term_b.shell_env, "OWNED=1",
		"the rename carries the user's env for the logical pane into spawn")
	assert_eq(PaneEnvStore.env_for("agent-terminal"), "OWNED=1",
		"and the first instance keeps its own store entry")

	# W2's terminal events reach W2's companion; W1's companion stays empty.
	ws._route_agent_events([{
		"terminal_session_id": str(term_b._terminal.get_terminal_session_id()),
		"omp_session_id": "session-b",
		"event": {"name": "session.bound"},
	}])
	assert_eq(reason_b._omp_session_id, "session-b",
		"the local terminal's events reach the local companion")
	assert_eq(reason_a._omp_session_id, "", "a foreign workspace's stream never does")

	await get_tree().create_timer(2.1).timeout
