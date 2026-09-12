extends GutTest
# Titlebar agent-state badges — display layer for the tiered AgentState
# tracker. The badge must stay hidden while idle, light up on an OSC
# declaration, and swap glyphs when the state changes.

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

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

func _badge(ws: Control) -> Label:
	var tm: TerminalManager = ws._tm
	var wrapper: Control = tm.tiles[0].wrapper
	return wrapper.get_node_or_null("BodyVBox/TitleBar/StateBadge")

func _first_body(ws: Control) -> Control:
	var tm: TerminalManager = ws._tm
	return tm._find_body(tm.tiles[0].wrapper)

## Await until the badge predicate holds, with a real-time deadline. Generous
## on purpose: the declaration comes from a child process, and the Windows
## fixture starts PowerShell to print it.
func _wait_until(ws: Control, predicate: Callable, timeout_s := 8.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		if predicate.call(_badge(ws)):
			return true
	return false

## Declarations are suppressed for 750 ms after a resize; startup layout
## churn resizes the pane several times. Wait out the window, then emit.
##
## The sequence is printed by a child process (`ShellFixtures`), not echoed by
## the shell: the parser must see real output bytes, and `printf` does not exist
## in every shell gpty has to run its tests under.
func _declare_after_settle(body: Control, state: String):
	await get_tree().create_timer(1.2).timeout
	var sequence := "\u001b]gpty_state=%s\u0007" % state
	body._terminal.send_line(ShellFixtures.print_text(sequence))

## Tier 2 (the `gpty_state` OSC a program prints) needs the sequence to travel
## from the child to the pane's parser. On Windows it cannot: ConPTY re-renders
## its own model and consumes sequences its VT engine does not implement —
## measured in CI, where the paste tests (the same child-side byte emission and
## PowerShell fixture, a DECSET instead of an OSC) pass while every declaration
## test fails. That is a platform property rather than a gap to close here: the
## declaration path on Windows is `gpty state <value>`, which submits over the
## event socket with the pane's own capability and is asserted live on every
## platform by `scripts/smoke_pane_api.py` (including the `windows-smoke` job).
## AGENTS.md records the decision.
func _needs_osc_delivery() -> bool:
	if OS.get_name() != "Windows":
		return false
	pending("ConPTY consumes the gpty_state OSC; `gpty state` is the Windows declaration path (AGENTS.md)")
	return true


func test_badge_hidden_when_idle():
	var ws = await _make_workspace()
	var badge := _badge(ws)
	assert_not_null(badge, "every terminal titlebar must carry a badge label")
	assert_false(badge.visible, "idle terminals must hide the badge")

func test_declaration_lights_badge_and_swaps_glyph():
	if _needs_osc_delivery():
		return
	var ws = await _make_workspace()
	var body = _first_body(ws)
	await _declare_after_settle(body, "working")

	assert_true(await _wait_until(ws, func(b: Label) -> bool:
		return b != null and b.visible), "working declaration must light the badge")
	var badge := _badge(ws)
	assert_true(badge.text in [Icons.SPINNER, Icons.SPINNER_GAP, Icons.CIRCLE_NOTCH],
		"working badge must show a spinner glyph")

	await _declare_after_settle(body, "completed")
	assert_true(await _wait_until(ws, func(b: Label) -> bool:
		return b != null and b.visible and b.text == Icons.CHECK_CIRCLE),
		"completed declaration must swap the badge to the check glyph")

func test_failed_declaration_shows_warning():
	if _needs_osc_delivery():
		return
	var ws = await _make_workspace()
	var body = _first_body(ws)
	await _declare_after_settle(body, "failed")
	assert_true(await _wait_until(ws, func(b: Label) -> bool:
		return b != null and b.visible and b.text == Icons.WARNING_CIRCLE),
		"failed declaration must show the warning badge")

func test_badge_is_display_only_projection():
	if _needs_osc_delivery():
		return
	var ws = await _make_workspace()
	var body = _first_body(ws)
	# The badge mirrors the engine state — no pane behavior may depend on it.
	await _declare_after_settle(body, "working")
	assert_true(await _wait_until(ws, func(b: Label) -> bool:
		return b != null and b.visible))
	var tm: TerminalManager = ws._tm
	assert_true(tm.tiles.size() == 1, "badge state must never spawn or remove panes")

func test_generic_event_to_state_mapping():
	var W = WorkspaceScript
	assert_eq(W.agent_state_for_event({"name": "agent.started"}), "working")
	assert_eq(W.agent_state_for_event({"name": "agent.settled"}), "completed")
	assert_eq(W.agent_state_for_event({"name": "session.bound"}), "idle")
	assert_eq(W.agent_state_for_event({"name": "session.shutdown"}), "idle")
	assert_eq(W.agent_state_for_event({"name": "tool.finished", "is_error": true}),
		"needs-attention")
	assert_eq(W.agent_state_for_event({"name": "tool.finished", "is_error": false}), "")
	assert_eq(W.agent_state_for_event({"name": "thinking.delta"}), "")
	assert_eq(W.agent_state_for_event({"name": "turn.started"}), "")
	assert_eq(W.agent_state_for_event({}), "")
	# An explicit declaration carries its own value; a declaration without one
	# declares nothing (the socket refuses an unknown value, so it cannot
	# arrive with a value outside the vocabulary).
	assert_eq(W.agent_state_for_event({"name": "state.declared", "state": "needs-attention"}),
		"needs-attention")
	assert_eq(W.agent_state_for_event({"name": "state.declared"}), "")

func test_tier1_overrides_tier2_declaration():
	var ws = await _make_workspace()
	var body = _first_body(ws)
	# Authoritative Tier 1 observation from a capability event.
	body._terminal.set_agent_state("working")
	# A later Tier 2 OSC declaration must not override it.
	await _declare_after_settle(body, "completed")
	await get_tree().create_timer(0.5).timeout
	var st = JSON.parse_string(str(body._terminal.get_status()))
	assert_true(st is Dictionary)
	assert_eq(str(st.get("agent_state", "")), "working",
		"Tier 2 must never override an authoritative Tier 1 state")
	assert_eq(int(st.get("agent_state_tier", 0)), 1, "the state must stay Tier 1")
	assert_true(_badge(ws).visible, "the badge must mirror the Tier 1 state")
