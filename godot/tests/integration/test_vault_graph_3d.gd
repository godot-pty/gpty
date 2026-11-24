extends GutTest
# Integration tests for VaultGraph3D — the orbital map's bodies, springs,
# persistence and pause rules. Headless has a real physics server but no
# renderer, so these assert state and geometry, never pixels; the visible half
# is proven by `scripts/ui-capture wiki-graph`.

const NODES_3 := [
	{"id": "a.md", "label": "A", "ghost": false},
	{"id": "b.md", "label": "B", "ghost": false},
	{"id": "c.md", "label": "C", "ghost": false},
]
const EDGES_3 := [
	{"a": "a.md", "b": "b.md", "ab": 2, "ba": 1, "count": 3, "ghost": false, "declared": 0, "weight": 3},
	{"a": "b.md", "b": "c.md", "ab": 1, "ba": 0, "count": 1, "ghost": false, "declared": 0, "weight": 1},
]

var _motion := UiMotion.SUBTLE


func before_each():
	MockAutoloads.setup()
	_motion = SettingsManager.cfg_motion


func after_each():
	SettingsManager.cfg_motion = _motion
	MockAutoloads.teardown()


func _graph(nodes: Array = NODES_3, edges: Array = EDGES_3) -> Dictionary:
	return {"nodes": nodes, "edges": edges, "truncated": false}


func _make_view(data: Dictionary = {}) -> VaultGraph3D:
	var view := VaultGraph3D.new()
	add_child_autofree(view)
	view.size = Vector2(800.0, 600.0)
	view.show_graph(_graph() if data.is_empty() else data)
	return view


func _two_node_graph() -> Dictionary:
	return {
		"nodes": [
			{"id": "a.md", "label": "A", "ghost": false},
			{"id": "b.md", "label": "B", "ghost": false},
		],
		"edges": [
			{"a": "a.md", "b": "b.md", "ab": 1, "ba": 0, "count": 1, "ghost": false, "declared": 0, "weight": 1},
		],
		"truncated": false,
	}


func _await_physics(frames: int) -> void:
	for i in frames:
		await get_tree().physics_frame


func _await_settled(view: VaultGraph3D, timeout_ms := 3000) -> void:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while not view.is_settled() and Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame


## Two process frames: the view's chrome and the first deferred fit run, and
## the SubViewport has a size for the camera projection.
func _prepare(view: VaultGraph3D) -> void:
	await get_tree().process_frame
	await get_tree().process_frame


func test_a_push_moves_a_neighbour_and_settles():
	var view := _make_view(_two_node_graph())
	await _prepare(view)
	var before_a: Vector2 = view.positions["a.md"]
	var before_b: Vector2 = view.positions["b.md"]
	var direction := (before_a - before_b).normalized()
	view._begin_drag("a.md")
	view._drag_to("a.md", before_a + direction * 60.0)
	await _await_physics(30)
	var moved: Vector2 = view.positions["b.md"] - before_b
	assert_gt(moved.dot(direction), 1.0, "a held node must pull its neighbour")
	assert_lt(
		(view.positions["a.md"] - (before_a + direction * 60.0)).length(),
		2.0,
		"the held node must stay where the pointer put it"
	)

	view._finish_drag(true)
	await _await_settled(view)
	assert_true(view.is_settled(), "the released map must settle")
	assert_lt(
		(view.positions["a.md"] - (before_a + direction * 60.0)).length(),
		20.0,
		"the dropped node must stay near where it was released"
	)


func test_a_hidden_view_ticks_nothing():
	var view := _make_view()
	await _prepare(view)
	await _await_settled(view)
	assert_true(view.is_settled(), "precondition: the map settled")
	var ticks := view.simulation_ticks()
	var snapshot := view.positions.duplicate(true)

	view.visible = false
	await _await_physics(10)

	assert_eq(view.simulation_ticks(), ticks, "a hidden view must not simulate")
	for id in snapshot:
		assert_lt(
			(view.positions[id] - (snapshot[id] as Vector2)).length(),
			0.001,
			"%s must not move while hidden" % id
		)
	assert_eq(
		view._viewport.render_target_update_mode,
		SubViewport.UPDATE_DISABLED,
		"a hidden viewport must stop rendering"
	)
	view.visible = true


func test_a_link_follows_both_endpoints():
	var view := _make_view()
	await _prepare(view)
	view._place_body("a.md", Vector2(200.0, 200.0))
	view._place_body("b.md", Vector2(450.0, 330.0))
	var segment := view.link_segment("a.md", "b.md")
	assert_eq(segment.size(), 2, "the drawn link has two recorded endpoints")
	assert_true(segment[0].is_equal_approx(view._bodies["a.md"].global_position),
		"the link's first end is the body's current position")
	assert_true(segment[1].is_equal_approx(view._bodies["b.md"].global_position),
		"the link's second end is the body's current position")


func test_positions_round_trip_through_the_layout():
	var view := _make_view()
	await _prepare(view)
	view._place_body("a.md", Vector2(210.0, 220.0))
	view._place_body("c.md", Vector2(480.0, 500.0))
	var exported := view.export_positions()
	assert_eq(exported.size(), 3)

	var twin := VaultGraph3D.new()
	add_child_autofree(twin)
	twin.size = Vector2(800.0, 600.0)
	twin.show_graph(_graph(), "", exported)
	for id in exported:
		assert_lt(
			(twin.positions[id] - view.positions[id]).length(),
			0.11,
			"%s must restore where it was saved" % id
		)


func test_a_deleted_note_is_ignored():
	var exported := {
		"a.md": [100.0, 100.0],
		"gone.md": [200.0, 200.0],
	}
	var view := VaultGraph3D.new()
	add_child_autofree(view)
	view.size = Vector2(800.0, 600.0)
	view.show_graph(_graph(), "", exported)
	assert_false(view.positions.has("gone.md"), "a note the graph lacks is never placed")
	assert_false(view._bodies.has("gone.md"), "and never becomes a body")
	assert_false(view.export_positions().has("gone.md"), "nor survives the save")


func test_the_graph_data_is_unchanged_after_a_drag():
	var view := _make_view()
	await _prepare(view)
	var nodes_before := view.nodes.duplicate(true)
	var edges_before := view.edges.duplicate(true)
	var before_a: Vector2 = view.positions["a.md"]
	view._begin_drag("a.md")
	view._drag_to("a.md", before_a + Vector2(40.0, 25.0))
	view._finish_drag(true)
	await _await_settled(view)
	assert_eq(view.nodes, nodes_before, "a drag never edits the node list")
	assert_eq(view.edges, edges_before, "a drag never edits the link list")


func test_motion_off_moves_only_the_dragged_node():
	SettingsManager.cfg_motion = UiMotion.OFF
	var view := _make_view()
	await _prepare(view)
	var before_b: Vector2 = view.positions["b.md"]
	var before_a: Vector2 = view.positions["a.md"]
	view._begin_drag("a.md")
	view._drag_to("a.md", before_a + Vector2(80.0, 0.0))
	await _await_physics(10)
	assert_lt(
		(view.positions["b.md"] - before_b).length(),
		0.5,
		"with Motion Off the neighbours must not follow"
	)
	assert_gt(
		(view.positions["a.md"] - before_a).length(),
		20.0,
		"the dragged node still moves"
	)
	view._finish_drag(true)


func test_orbiting_rotates_the_camera_not_the_graph():
	var view := _make_view()
	await _prepare(view)
	await _await_settled(view)
	var before := {}
	for id in view._bodies:
		before[id] = view._bodies[id].global_position
	var yaw := view.camera_angles().x
	assert_eq(view._node_at(Vector2(2.0, 2.0)), "", "precondition: the corner is empty")
	view._begin_left(Vector2(2.0, 2.0))
	var motion := InputEventMouseMotion.new()
	motion.position = Vector2(42.0, 2.0)
	motion.relative = Vector2(40.0, 0.0)
	view._gui_input(motion)
	view._end_left(Vector2(42.0, 2.0))
	assert_ne(view.camera_angles().x, yaw, "the background drag orbits the camera")
	for id in before:
		assert_true(
			(view._bodies[id].global_position - before[id]).length() < 0.01,
			"%s must not move for a camera gesture" % id
		)


## A workspace switch hides the wiki pane's whole grid. A settled map that is
## shown again must clear the pause flag and ask for a frame; leaving the flag
## set kept UPDATE_DISABLED, so the SubViewportContainer showed the pre-switch
## map as a static background (reported 2026-11-18).
func test_a_settled_view_repaints_after_hiding():
	var host := Control.new()
	add_child_autofree(host)
	var view := VaultGraph3D.new()
	host.add_child(view)
	view.size = Vector2(800.0, 600.0)
	view.show_graph(_two_node_graph())
	await _prepare(view)
	await _await_settled(view)

	host.visible = false
	await get_tree().process_frame
	assert_true(view._hidden_paused, "hiding must pause the view")
	assert_eq(
		view._viewport.render_target_update_mode,
		SubViewport.UPDATE_DISABLED,
		"hiding must stop rendering"
	)

	host.visible = true
	assert_false(view._hidden_paused, "showing must clear the pause flag")
	assert_ne(
		view._viewport.render_target_update_mode,
		SubViewport.UPDATE_DISABLED,
		"showing must request a frame, not keep the old texture"
	)
	await get_tree().process_frame


# ── Perspective camera and depth travel ────────────────────────────────

func test_the_orbital_camera_is_perspective_and_fits_by_view_height():
	var view := _make_view()
	await _prepare(view)
	assert_eq(view._camera.projection, Camera3D.PROJECTION_PERSPECTIVE)
	var height := view.camera_view_height()
	assert_true(height >= VaultGraph3D.VIEW_HEIGHT_MIN, "the fit keeps a usable height")
	assert_true(height <= VaultGraph3D.VIEW_HEIGHT_MAX)
	var expected := height / (2.0 * tan(deg_to_rad(view._camera.fov) * 0.5))
	assert_almost_eq(view.camera_distance(), expected, 0.01,
		"the camera distance is derived from the view height")


func test_depth_travel_moves_the_target_along_the_view_without_zooming():
	var view := _make_view()
	await _prepare(view)
	var height := view.camera_view_height()
	var target := view._target
	var forward := -view._camera.global_basis.z
	view._travel_depth(2.0)
	assert_almost_eq(view.camera_view_height(), height, 0.001, "depth travel is not zoom")
	var moved := view._target - target
	assert_almost_eq(moved.length(), 2.0 * height * VaultGraph3D.DEPTH_STEP_FRACTION, 0.01)
	assert_true(moved.normalized().is_equal_approx(forward), "depth follows the view axis")


func test_shift_wheel_travels_and_plain_wheel_zooms():
	var view := _make_view()
	await _prepare(view)
	var height := view.camera_view_height()
	var target := view._target
	var wheel := InputEventMouseButton.new()
	wheel.position = view.size * 0.5
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	wheel.shift_pressed = true
	view._gui_input(wheel)
	assert_almost_eq(view.camera_view_height(), height, 0.001, "shift-wheel must not zoom")
	assert_gt((view._target - target).length(), 0.01, "shift-wheel travels depth")

	target = view._target
	height = view.camera_view_height()
	wheel.shift_pressed = false
	view._gui_input(wheel)
	assert_lt(view.camera_view_height(), height, "plain wheel keeps its zoom meaning")
	assert_almost_eq(
		(view._target - target).length(), 0.0, 0.01,
		"a centred zoom keeps the target"
	)


func test_depth_changes_the_projected_scale():
	var view := _make_view()
	await _prepare(view)
	await _await_settled(view)
	var near := ""
	var far := ""
	for id in view._depths:
		if near == "" or float(view._depths[id]) > float(view._depths[near]):
			near = id
		if far == "" or float(view._depths[id]) < float(view._depths[far]):
			far = id
	assert_ne(near, "", "precondition: the graph has bodies at depth")
	var near_upp := view._units_per_pixel_at(view._bodies[near].global_position)
	var far_upp := view._units_per_pixel_at(view._bodies[far].global_position)
	assert_lt(near_upp, far_upp, "a nearer body has fewer world units per pixel")
	var before_ratio := far_upp / near_upp
	view._travel_depth(2.0)
	var near_after := view._units_per_pixel_at(view._bodies[near].global_position)
	var far_after := view._units_per_pixel_at(view._bodies[far].global_position)
	assert_gt(far_after / near_after, before_ratio, "travelling forward spreads the depth scale")


func test_a_background_drag_orbits_by_default_and_shift_drag_pans():
	var view := _make_view()
	await _prepare(view)
	await _await_settled(view)
	var yaw := view.camera_angles().x
	view._begin_left(Vector2(2.0, 2.0))
	var motion := InputEventMouseMotion.new()
	motion.position = Vector2(42.0, 2.0)
	motion.relative = Vector2(40.0, 0.0)
	view._gui_input(motion)
	view._end_left(motion.position)
	assert_ne(view.camera_angles().x, yaw, "a plain background drag orbits")
	var orbited_yaw := view.camera_angles().x

	var target := view._target
	view._begin_left(Vector2(2.0, 2.0), true)
	motion.position = Vector2(42.0, 2.0)
	motion.relative = Vector2(40.0, 0.0)
	view._gui_input(motion)
	view._end_left(motion.position)
	assert_ne(view._target, target, "shift-drag pans")
	assert_almost_eq(view.camera_angles().x, orbited_yaw, 0.001, "shift-drag does not orbit")


func test_the_graph_toolbar_has_one_presentation_switch_and_no_orbit_toggle():
	var view := _make_view()
	await _prepare(view)
	assert_eq(view._mode_button.text, "Planar")
	assert_null(view.get("_orbit_button"), "the dead Orbit toggle is gone")


func test_the_planetary_theme_swaps_glyphs_without_moving_bodies():
	var view := _make_view()
	await _prepare(view)
	await _await_settled(view)
	var before := {}
	for id in view._bodies:
		before[id] = view._bodies[id].global_position
	view.apply_graph_theme("planetary")
	assert_eq(view.graph_theme, "planetary")
	assert_eq(view._notes_mesh.multimesh.mesh, view._sphere_mesh,
		"planetary notes are lit spheres")
	assert_true(view._sun.visible, "the planetary scene has a sun")
	assert_gt(view._rings_mesh.multimesh.instance_count, 0,
		"the busiest note carries a planet ring")
	for id in before:
		assert_true(
			(view._bodies[id].global_position - before[id]).length() < 0.01,
			"%s must not move for a theme" % id
		)
	assert_string_contains(view._status.text, "Planetary")

	view.apply_graph_theme("default")
	assert_eq(view._notes_mesh.multimesh.mesh, view._quad, "the default is back to billboards")
	assert_false(view._sun.visible)
	assert_eq(view._rings_mesh.multimesh.instance_count, 0)
