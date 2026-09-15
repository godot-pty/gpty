extends GutTest
# Pane contract: agent-state observation (PaneBody.agent_state_source_id /
# on_agent_state_changed). These tests drive the real dispatcher in
# workspace.gd — a terminal's tiered tracker changes, the workspace routes the
# state to every pane that observes that terminal and to nothing else — rather
# than reimplementing the routing. Display only: see AGENTS.md for the rule,
# and PaneBody for the contract itself.

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")
const STATES := ["idle", "working", "needs-attention", "completed", "failed"]

## A custom pane in the shape a third-party pane has: it observes one terminal
## by stable id and records every state it is told.
class ProbePane extends PaneBody:
	var source := ""
	var seen: Array[String] = []

	func agent_state_source_id() -> String:
		return source

	func on_agent_state_changed(state: String) -> void:
		seen.append(state)

var _ws: Control

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

func _make_workspace() -> Control:
	var ws: Control = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame
	return ws

func _first_body(ws: Control) -> Control:
	var tm: TerminalManager = ws._tm
	return tm._find_body(tm.tiles[0].wrapper)

func _badge(ws: Control) -> Label:
	var tm: TerminalManager = ws._tm
	return tm.tiles[0].wrapper.get_node_or_null("BodyVBox/TitleBar/StateBadge")

func _add_probe(ws: Control, source_id: String) -> ProbePane:
	var probe := ProbePane.new()
	probe.source = source_id
	ws.add_child(probe)
	return probe

## Real-time wait: a state change is observed on the terminal's slow poll
## (`SLOW_POLL_INTERVAL`), not on the next frame.
func _wait_until(predicate: Callable, timeout_s := 3.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		if predicate.call():
			return true
	return false

# ── The terminal is its own source (the badge path) ────────────────────

func test_a_terminal_observes_itself_and_lights_its_badge():
	var ws := await _make_workspace()
	var body := _first_body(ws)
	assert_eq(
		body.agent_state_source_id(), body.attachment_id,
		"a terminal observes itself by its stable id")
	body._terminal.set_agent_state("working")
	assert_true(
		await _wait_until(func(): return _badge(ws).visible),
		"the terminal's own hook must apply the badge")

# ── A custom pane observing a terminal ─────────────────────────────────

func test_a_follower_is_primed_on_attach_and_told_every_change():
	var ws := await _make_workspace()
	var body := _first_body(ws)
	var probe := _add_probe(ws, body.attachment_id)
	assert_true(
		await _wait_until(func(): return probe.seen.size() >= 1),
		"a new observer must be told the current state once")
	assert_eq(probe.seen[0], "idle", "the primed state is the tracker's current one")

	body._terminal.set_agent_state("needs-attention")
	assert_true(
		await _wait_until(func(): return probe.seen.size() >= 2),
		"a state change must reach the follower: %s" % str(probe.seen))
	assert_eq(probe.seen[-1], "needs-attention")
	# Every value the hook can receive is in the published vocabulary — the
	# hook is third-party code and must be able to match exhaustively.
	for state in probe.seen:
		assert_true(state in STATES, "unexpected state '%s'" % state)

func test_a_pane_that_observes_nothing_is_never_told():
	var ws := await _make_workspace()
	var body := _first_body(ws)
	var probe := _add_probe(ws, "")
	body._terminal.set_agent_state("working")
	await _wait_until(func(): return false, 0.6)
	assert_eq(probe.seen.size(), 0, "a pane with no source must not be called")

func test_a_follower_attached_before_its_terminal_is_primed_when_it_appears():
	# Restore order is not fixed: a layout may list the companion before the
	# terminal it follows, so priming has to work in both directions.
	var ws := await _make_workspace()
	var probe := _add_probe(ws, "late-terminal")
	assert_eq(probe.seen.size(), 0, "no terminal exists yet")
	var late = ws._spawn_pane("terminal", {"attachment_id": "late-terminal"})
	assert_not_null(late, "the late terminal must spawn")
	assert_true(
		await _wait_until(func(): return probe.seen.size() >= 1),
		"the terminal attaching later must prime its follower")
	assert_eq(probe.seen[0], "idle")

func test_a_follower_that_repoints_is_primed_for_the_new_source():
	# A custom pane's source is a setting, so it can change while the pane
	# lives; the dispatcher must not treat it as "already told".
	var ws := await _make_workspace()
	var body := _first_body(ws)
	var probe := _add_probe(ws, "")
	await _wait_until(func(): return false, 0.3)
	probe.source = body.attachment_id
	assert_true(
		await _wait_until(func(): return probe.seen.size() >= 1),
		"a re-pointed pane must be primed for its new source")
	assert_eq(probe.seen[0], "idle")
