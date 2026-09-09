extends GutTest
# Titlebar agent-state badges — display layer for the tiered AgentState
# tracker. The badge must stay hidden while idle, light up on an OSC
# declaration, and swap glyphs when the state changes.

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

var _ws: Control

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = "/bin/sh"

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

## Await until the badge predicate holds, with a real-time deadline.
func _wait_until(ws: Control, predicate: Callable, timeout_s := 4.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		if predicate.call(_badge(ws)):
			return true
	return false

## Declarations are suppressed for 750 ms after a resize; startup layout
## churn resizes the pane several times. Wait out the window, then emit.
func _declare_after_settle(body: Control, state: String):
	await get_tree().create_timer(1.2).timeout
	body._terminal.send_line("printf '\\033]gpty_state=%s\\007'" % state)

func test_badge_hidden_when_idle():
	var ws = await _make_workspace()
	var badge := _badge(ws)
	assert_not_null(badge, "every terminal titlebar must carry a badge label")
	assert_false(badge.visible, "idle terminals must hide the badge")

func test_declaration_lights_badge_and_swaps_glyph():
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
	var ws = await _make_workspace()
	var body = _first_body(ws)
	await _declare_after_settle(body, "failed")
	assert_true(await _wait_until(ws, func(b: Label) -> bool:
		return b != null and b.visible and b.text == Icons.WARNING_CIRCLE),
		"failed declaration must show the warning badge")

func test_badge_is_display_only_projection():
	var ws = await _make_workspace()
	var body = _first_body(ws)
	# The badge mirrors the engine state — no pane behavior may depend on it.
	await _declare_after_settle(body, "working")
	assert_true(await _wait_until(ws, func(b: Label) -> bool:
		return b != null and b.visible))
	var tm: TerminalManager = ws._tm
	assert_true(tm.tiles.size() == 1, "badge state must never spawn or remove panes")
