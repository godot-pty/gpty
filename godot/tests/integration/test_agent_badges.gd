extends GutTest
# Titlebar agent-state badges — display layer for the tiered AgentState
# tracker. The badge must stay hidden while idle, light up on an OSC
# declaration, and swap silhouette when the state changes.

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

func _badge(ws: Control) -> AgentBadge:
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
	assert_not_null(badge, "every terminal titlebar must carry a badge")
	assert_false(badge.visible, "idle terminals must hide the badge")

func test_declaration_lights_badge_and_swaps_silhouette():
	if _needs_osc_delivery():
		return
	var ws = await _make_workspace()
	var body = _first_body(ws)
	await _declare_after_settle(body, "working")

	assert_true(await _wait_until(ws, func(b: AgentBadge) -> bool:
		return b != null and b.visible), "working declaration must light the badge")
	var badge := _badge(ws)
	assert_eq(badge.state(), "working",
		"working badge must show the ring, which no glyph can carry")

	await _declare_after_settle(body, "completed")
	assert_true(await _wait_until(ws, func(b: AgentBadge) -> bool:
		return b != null and b.visible and b.state() == "completed"),
		"completed declaration must swap the badge to the check silhouette")

func test_failed_declaration_shows_the_x_circle():
	if _needs_osc_delivery():
		return
	var ws = await _make_workspace()
	var body = _first_body(ws)
	await _declare_after_settle(body, "failed")
	assert_true(await _wait_until(ws, func(b: AgentBadge) -> bool:
		return b != null and b.visible and b.state() == "failed"),
		"failed declaration must show the x-circle badge")

## `failed` and `needs-attention` used to share one warning glyph and differ
## only by hue, which a protan/deutan user cannot rely on. Every state now has
## its own silhouette - three Phosphor glyphs and one painted ring - and the
## glyph is checked against the bundled font: a wrong codepoint renders tofu,
## which no colour difference can rescue.
func test_every_state_has_its_own_silhouette():
	var by_kind := {}
	var by_glyph := {}
	for state in AgentBadge.STATES:
		var spec: Dictionary = AgentBadge.STATES[state]
		var kind := str(spec["kind"])
		assert_ne(kind, "", "%s: a state names its silhouette" % state)
		assert_false(by_kind.has(kind),
			"%s and %s share the %s silhouette" % [state, by_kind.get(kind, ""), kind])
		by_kind[kind] = state
		var glyph := str(spec["glyph"])
		if glyph != "":
			assert_eq(glyph.length(), 1, "%s: the glyph must be one codepoint" % state)
			assert_true(Icons.font_resource.has_char(glyph.unicode_at(0)),
				"%s: %s is not a glyph in the bundled Phosphor font" % [state, glyph])
			assert_false(by_glyph.has(glyph),
				"%s and %s share the glyph %s" % [state, by_glyph.get(glyph, ""), glyph])
			by_glyph[glyph] = state
		assert_ne(str(spec["label"]), "",
			"%s: a label is the tooltip and the accessible name" % state)
		# The tint is a palette role, not a captured colour: the badge has to
		# read on a light title bar too.
		var role := str(spec.get("role", ""))
		assert_true(UiPalette.DARK.has(role), "%s: role %s is a dark token" % [state, role])
		assert_true(UiPalette.LIGHT.has(role), "%s: role %s is a light token" % [state, role])
	assert_eq(by_kind.size(), 4, "the four visible states must have four silhouettes")
	assert_eq(str(AgentBadge.STATES["working"]["glyph"]), "",
		"working is painted, not drawn: the font's spinner arcs are the defect")
	assert_eq(by_glyph.size(), 3, "the other three states draw a glyph")
	assert_eq(str(AgentBadge.STATES["failed"]["glyph"]), Icons.X_CIRCLE,
		"failed is the X-circle")
	assert_eq(str(AgentBadge.STATES["needs-attention"]["glyph"]), Icons.WARNING,
		"needs-attention is the warning triangle")
	assert_false(AgentBadge.STATES.has("idle"), "idle hides the badge")

## The state reaches a user who cannot see the colour or the shape at all: the
## tooltip needs a hover target (a MOUSE_FILTER_IGNORE control is never one) and
## the accessible name is what a screen reader reads instead of a private-use
## codepoint. Tier 1 is set directly, so this path also covers Windows, where
## the OSC declaration the other tests use is consumed by ConPTY.
func test_badge_carries_text_for_pointer_and_screen_reader():
	var ws = await _make_workspace()
	var body = _first_body(ws)
	body._terminal.set_agent_state("needs-attention")
	assert_true(await _wait_until(ws, func(b: AgentBadge) -> bool:
		return b != null and b.visible and b.state() == "needs-attention"),
		"a Tier 1 needs-attention state must show the triangle")
	var badge := _badge(ws)
	assert_eq(badge.tooltip_text, "Needs attention", "the tooltip names the state")
	assert_eq(badge.accessibility_name, "Needs attention",
		"the accessible name names the state, not a codepoint")
	assert_ne(badge.mouse_filter, Control.MOUSE_FILTER_IGNORE,
		"a tooltip needs the badge to be the control under the pointer")
	assert_eq(badge.accessibility_live, A11y.LIVE_POLITE,
		"a state change must reach a screen reader without focus")
	# `get_tooltip()` is the engine's own resolver for the badge, so the string
	# a dwell would show is asserted here. The popup itself is not: headless
	# Godot tracks no pointer at all (`gui_get_hovered_control()` is null even
	# over a plain `Button`), and the hover was verified on the headed build
	# instead - the badge is the control under the pointer, which is the
	# precondition this `mouse_filter` line protects.
	assert_eq(badge.get_tooltip(), "Needs attention",
		"the tooltip the engine would show must name the state")

func test_badge_is_display_only_projection():
	if _needs_osc_delivery():
		return
	var ws = await _make_workspace()
	var body = _first_body(ws)
	# The badge mirrors the engine state — no pane behavior may depend on it.
	await _declare_after_settle(body, "working")
	assert_true(await _wait_until(ws, func(b: AgentBadge) -> bool:
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
	# Gated like the declaration tests above: where ConPTY eats the OSC no Tier 2
	# declaration ever arrives, so "it did not override Tier 1" would hold with
	# the precedence rule deleted — a pass that tests nothing.
	if _needs_osc_delivery():
		return
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
