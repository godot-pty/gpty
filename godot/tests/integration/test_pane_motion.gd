extends GutTest
# Pane transitions against a real workspace: the tween is observable while it
# runs, the tile rects stay exact, and every guard (motion off, hidden
# workspace, flood cadence, an interrupting layout pass) draws the final state
# without leaving a tween or a ghost behind. The registry's shape and the
# settings sanitizers are tested in tests/unit/test_pane_transitions.gd.

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

var _ws: Control

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()
	SettingsManager.cfg_motion = UiMotion.SUBTLE
	SettingsManager.cfg_pane_animation = {}
	SettingsManager.cfg_pane_animation_params = {}

func after_each():
	if _ws:
		if _ws.get_parent():
			_ws.get_parent().remove_child(_ws)
		_ws.free()
		_ws = null
	SettingsManager.cfg_motion = UiMotion.SUBTLE
	SettingsManager.cfg_pane_animation = {}
	SettingsManager.cfg_pane_animation_params = {}
	MockAutoloads.teardown()

func _make_workspace() -> Control:
	var ws: Control = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame
	return ws

## An empty grid, so tile indices and rects are the test's own.
func _empty_grid(ws: Control) -> void:
	ws._reset_now()
	await get_tree().process_frame

func _wrapper_of(tm: TerminalManager, body: Control) -> Control:
	for t in tm.tiles:
		if tm._find_body(t.wrapper) == body:
			return t.wrapper
	return null

func _rect(w: Control) -> Rect2:
	return Rect2(w.position, w.size)

# ── Create / close ─────────────────────────────────────────────────────

func test_a_created_pane_fades_and_scales_into_its_final_rect():
	var ws = await _make_workspace()
	await _empty_grid(ws)
	var body = ws._spawn_pane("code_viewer", {}, false)
	assert_not_null(body)
	var w := _wrapper_of(ws._tm, body)
	assert_not_null(w)
	var final_rect := _rect(w)
	assert_almost_eq(w.scale.x, 0.92, 0.02, "the pane starts at the configured scale")
	assert_lt(w.modulate.a, 1.0, "and transparent")
	assert_eq(ws._transitions.playing(), 1)

	await wait_seconds(0.25)
	assert_eq(w.scale, Vector2.ONE)
	assert_eq(w.modulate, Color.WHITE)
	assert_eq(_rect(w), final_rect, "the tween never moves the tile rect")
	assert_eq(ws._transitions.playing(), 0)

func test_a_closed_pane_fades_out_then_is_freed_once():
	var ws = await _make_workspace()
	await _empty_grid(ws)
	var body = ws._spawn_pane("code_viewer", {}, false)
	var w := _wrapper_of(ws._tm, body)
	await wait_seconds(0.25)

	ws._kill_now(body)
	assert_eq(ws._tm.tiles.size(), 0, "the tile leaves the model at once")
	assert_true(is_instance_valid(w), "the ghost is drawn while it fades")
	assert_eq(ws._transitions.playing(), 1)

	await wait_seconds(0.25)
	assert_false(is_instance_valid(w))
	assert_eq(ws._transitions.playing(), 0)

func test_motion_off_draws_the_final_state_in_one_frame():
	SettingsManager.cfg_motion = UiMotion.OFF
	var ws = await _make_workspace()
	await _empty_grid(ws)
	var body = ws._spawn_pane("code_viewer", {}, false)
	var w := _wrapper_of(ws._tm, body)
	assert_eq(w.scale, Vector2.ONE)
	assert_eq(w.modulate, Color.WHITE)
	assert_eq(ws._transitions.playing(), 0)

	ws._kill_now(body)
	await wait_process_frames(1)
	assert_false(is_instance_valid(w))

func test_a_layout_pass_snaps_an_in_flight_create():
	SettingsManager.cfg_motion = UiMotion.FULL
	var ws = await _make_workspace()
	await _empty_grid(ws)
	var body = ws._spawn_pane("code_viewer", {}, false)
	var w := _wrapper_of(ws._tm, body)
	assert_eq(ws._transitions.playing(), 1)

	ws._apply_layout()
	assert_eq(w.scale, Vector2.ONE)
	assert_eq(w.modulate, Color.WHITE)
	assert_eq(ws._transitions.playing(), 0)

func test_closing_a_pane_mid_create_leaves_one_transition():
	var ws = await _make_workspace()
	await _empty_grid(ws)
	var body = ws._spawn_pane("code_viewer", {}, false)
	var w := _wrapper_of(ws._tm, body)
	assert_eq(ws._transitions.playing(), 1)

	ws._kill_now(body)
	assert_true(is_instance_valid(w), "the close took over the create")
	assert_eq(ws._transitions.playing(), 1)

	await wait_seconds(0.25)
	assert_false(is_instance_valid(w))
	assert_eq(ws._transitions.playing(), 0)

# ── Position swap ──────────────────────────────────────────────────────

func test_a_position_swap_eases_both_wrappers_between_the_rects():
	var ws = await _make_workspace()
	await _empty_grid(ws)
	var a = ws._spawn_pane("code_viewer", {}, false)
	var b = ws._spawn_pane("code_viewer", {}, false)
	await wait_seconds(0.25)
	var wa := _wrapper_of(ws._tm, a)
	var wb := _wrapper_of(ws._tm, b)
	var ra := _rect(wa)
	var rb := _rect(wb)
	assert_true(ra.is_equal_approx(rb) == false, "the two tiles have different rects")

	assert_true(ws._tm.swap_positions(0, 1))
	assert_true(_rect(wa).is_equal_approx(ra), "the move starts where the pane was")
	assert_true(_rect(wb).is_equal_approx(rb))
	assert_eq(ws._transitions.playing(), 2)

	await wait_seconds(0.3)
	assert_true(_rect(wa).is_equal_approx(rb), "each pane ends in the other's rect")
	assert_true(_rect(wb).is_equal_approx(ra))
	assert_eq(ws._transitions.playing(), 0)

	# The tile model and the drawn rects agree: a later layout pass is a no-op.
	ws._apply_layout()
	assert_true(_rect(wa).is_equal_approx(rb))
	assert_true(_rect(wb).is_equal_approx(ra))

# ── Guards ─────────────────────────────────────────────────────────────

func test_a_hidden_workspace_gets_no_transition():
	var ws = await _make_workspace()
	ws._add_workspace()
	assert_eq(ws._active, 1, "the new workspace is the visible one")
	var hidden: Dictionary = ws._workspaces[0]
	var body = ws._spawn_pane_into(hidden, "code_viewer", {}, false)
	assert_not_null(body)
	var w := _wrapper_of(hidden.tm, body)
	assert_eq(w.scale, Vector2.ONE)
	assert_eq(w.modulate, Color.WHITE)
	assert_eq(ws._transitions.playing(), 0)

func test_a_flooding_terminal_suppresses_the_transition():
	var ws = await _make_workspace()
	var term = ws._tm._find_body(ws._tm.tiles[0].wrapper)
	assert_true(term is TerminalPane, "the restored pane is a terminal")
	# The back-off the pane's own sync sets under a flood; set directly so the
	# guard is the thing under test, not the throughput of a test shell.
	term._sync_backoff = 0.1
	assert_false(ws._motion_allowed(ws._tm))

	var viewer = ws._spawn_pane("code_viewer", {}, false)
	var vt := _wrapper_of(ws._tm, viewer)
	assert_eq(vt.scale, Vector2.ONE, "the create is drawn final")

	var term_w = ws._tm.tiles[0].wrapper
	var viewer_was := _rect(vt)
	assert_true(ws._tm.swap_positions(0, 1))
	assert_true(_rect(term_w).is_equal_approx(viewer_was),
		"the swap lands without a tween")
	assert_eq(ws._transitions.playing(), 0)
