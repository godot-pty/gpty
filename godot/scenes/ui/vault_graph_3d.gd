class_name VaultGraph3D
extends VaultGraphCanvas
## The wiki pane's **physical** link map.
##
## A `SubViewport` renders a 3D scene: one `RigidBody3D` per note, one spring
## per link, a billboarded disc and halo per note, an `ImmediateMesh` for the
## links, and drifting dust. Motion is physical in x/y; every note's z is a
## deterministic depth layer (`VaultGraphModel.depth_for`) that bodies are
## locked to, so a saved x/y position restores the exact arrangement and the
## free-orbit camera still shows real parallax.
##
## [VaultGraphModel] remains the only owner of graph data, link resolution and
## the semantic hit-test. This class owns presentation and simulation state:
## bodies, rests, the camera, the meshes, the overlay and the gestures. The
## pane types the view as [VaultGraphCanvas] and swaps this with the planar
## [VaultGraphView].
##
## Nothing here writes to the vault. The authored weight layer still only
## changes thickness and spring stiffness; it never changes which edges exist.

const DEPTH_SPREAD := 180.0
const NODE_WORLD_SCALE := 1.8
const HALO_SCALE := 2.3
const HALO_ALPHA_DARK := 0.13
const HALO_ALPHA_LIGHT := 0.09

const SPRING_K := 50.0
const SPRING_DAMP := 6.0
const CENTER_PULL := 0.02
const MAX_SPRING_FORCE := 6000.0
const SETTLE_SPEED := 2.0
const SETTLE_TICKS := 10
const MIN_REST_LENGTH := 1.0

const CAMERA_DISTANCE := 2000.0
const PITCH_LIMIT_DEG := 75.0
const ORBIT_SENSITIVITY := 0.4
const ZOOM_MIN_SIZE := 60.0
const ZOOM_MAX_SIZE := 6000.0
const ZOOM_STEP := 1.15
const FIT_PADDING := 0.08

const PAN_STEP := 48.0
const PAN_FAST := 4.0
const CURSOR_ARM := 7.0

const LABEL_MIN_PPU := 0.55
const MAX_ALWAYS_LABELS := 120
const LABEL_FONT_SIZE := 11
const LABEL_GAP := 4.0
const MAX_LABEL_BLOCK := 180.0

const LINK_ALPHA := 0.42
const LINK_END_ALPHA := 0.12
## The worst-case bench (4000 bodies, 10 000 edges) made one rebuilt link mesh
## cost ~20 ms, so the fallback the plan pre-decided is in from the start: at
## most 2 000 edges get feathered quads (the rest are plain lines, already the
## cheaper primitive), and the mesh is rebuilt at 15 Hz, not 30. The node
## transforms still move at the physics rate; only the line geometry lags.
const LINK_REBUILD_HZ := 15.0
const MAX_FEATHERED_EDGES := 2000

const GLOW_INTENSITY := 0.35
const GLOW_STRENGTH := 0.9
const GLOW_BLOOM := 0.05
const GLOW_THRESHOLD := 0.45
## The camera sits 2 000 units out; exponential fog is measured from it, so
## 0.02 erased the whole graph into the background. At 0.00012 the far depth
## layer is about 20 % faded — a cue, not a veil.
const FOG_DENSITY := 0.00012
const FOG_ENERGY := 1.0
const VIGNETTE_DARK := 0.10
const VIGNETTE_LIGHT := 0.05

const DUST_COUNT := 64
const DUST_HZ := 20.0
const DUST_ALPHA := 0.05
const DUST_BOX_X := 1200.0
const DUST_BOX_Y := 700.0
const DUST_SEED := 0x67707479

const TEXTURE_SIZE := 64
const VIGNETTE_SIZE := 256
const KIND_DISC := 0
const KIND_RING := 1
const KIND_HALO := 2

var _container: SubViewportContainer
var _viewport: SubViewport
var _world: Node3D
var _camera: Camera3D
var _env: WorldEnvironment
var _bodies_root: Node3D
var _notes_mesh: MultiMeshInstance3D
var _ghosts_mesh: MultiMeshInstance3D
var _halos_mesh: MultiMeshInstance3D
var _dust_mesh: MultiMeshInstance3D
var _links_mi: MeshInstance3D
var _link_mesh: ImmediateMesh
var _overlay: Control

var _note_material: StandardMaterial3D
var _ghost_material: StandardMaterial3D
var _halo_material: StandardMaterial3D
var _dust_material: StandardMaterial3D
var _link_material: StandardMaterial3D
var _disc_texture: Texture2D
var _ring_texture: Texture2D
var _halo_texture: Texture2D
var _vignette: GradientTexture2D
var _quad: QuadMesh

var _status: Label
var _hint: Label
var _mode_button: Button
var _orbit_button: Button
var _arrows_button: Button
var _relayout_button: Button
var _fit_button: Button
var _edge_menu: PopupMenu
var _pending_edge: Dictionary = {}

var _bodies: Dictionary = {}
var _depths: Dictionary = {}
## Pair rest lengths: a -> b -> float, in the parsed edges' sorted order.
var _rest: Dictionary = {}
## The force loop's precomputed edge arrays, parallel and in the drawn edges'
## order. Dictionary/string lookups per edge were the difference between a
## 10 000-edge graph costing tens of milliseconds a tick and staying usable.
var _spring_a: Array[RigidBody3D] = []
var _spring_b: Array[RigidBody3D] = []
var _spring_rest: PackedFloat32Array = PackedFloat32Array()
var _spring_k: PackedFloat32Array = PackedFloat32Array()
var _note_index: Dictionary = {}
var _ghost_index: Dictionary = {}
var _halo_index: Dictionary = {}
var _screen_cache: Dictionary = {}
var _screen_dirty := true

var _target := Vector3.ZERO
var _yaw := 0.0
var _pitch := 0.0
var _orbit_mode := false
var _dragging_camera := false
var _panning := false
var _drag_id := ""
var _press_screen := Vector2.ZERO
var _moved := false
var _settled := true
var _settle_ticks := 0
var _ticks := 0
var _hidden_paused := false
var _needs_fit := false
var _degrees: Dictionary = {}
var _max_degree := 1
var _max_count := 1
var _label_block_w := 0.0
var _a11y_host: Control
var _a11y_cursor := ""

var _dust_positions: Array[Vector3] = []
var _dust_speeds: Array[float] = []
var _dust_scales: Array[float] = []
var _dust_accum := 0.0
var _link_accum := 0.0
var _last_link_ms := 0
## Ids whose body moved since the last transform pass. Only those instances
## are rewritten; a still graph costs no multi-mesh calls.
var _moved_ids: Dictionary = {}
## Endpoint pair recorded by the last link build: a -> b -> PackedVector3Array.
var _link_ends: Dictionary = {}

var last_build_us := 0
## The force phase only; the physics step's own cost.
var last_step_us := 0
## Position sync + node transform writes; presentation, reported separately.
var last_visual_us := 0
var last_link_build_us := 0


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	_ensure_scene()
	_build_chrome()
	focus_entered.connect(func(): _overlay.queue_redraw())
	focus_exited.connect(func(): _overlay.queue_redraw())
	set_process_unhandled_key_input(false)
	if _bodies.is_empty() or _settled:
		set_process(false)
		set_physics_process(false)


# ═══════════════════════════════════════════════════════════════════════
# The pane's contract
# ═══════════════════════════════════════════════════════════════════════

func show_graph(data: Dictionary, current_id := "", prepared_positions := {}) -> void:
	var started := Time.get_ticks_usec()
	_ensure_scene()
	var was_settled := _settled
	_cancel_gestures()
	nodes = data.get("nodes", []) if data.get("nodes") is Array else []
	edges = data.get("edges", []) if data.get("edges") is Array else []
	_truncated = bool(data.get("truncated", false))
	accessibility_description = _describe()
	var first_show := positions.is_empty()
	var previous := positions
	var source := _positions_source(prepared_positions, previous)
	positions = VaultGraphModel.layout(nodes, edges, source)
	_degrees = VaultGraphModel.degrees(edges)
	_max_degree = 1
	for id in _degrees:
		_max_degree = maxi(_max_degree, int(_degrees[id]["in"]) + int(_degrees[id]["out"]))
	_recompute_weight_scale()
	_label_block_w = _measure_label_block()
	if current_id != "" and _has_node(current_id):
		selected_id = current_id
	elif selected_id != "" and not _has_node(selected_id):
		selected_id = ""
	_sync_bodies()
	_rebuild_rests()
	_sync_mesh_layout()
	_update_node_transforms()
	_update_node_colors()
	_rebuild_links()
	_update_status()
	_screen_dirty = true
	_overlay.queue_redraw()
	_needs_fit = first_show
	# The rest lengths were just set to the current distances, so a view that
	# was already at rest (a fresh/restored map, a 2D/3D switch) has nothing to
	# simulate. Starting a settle there bought a visible physics pass for no
	# movement — at the 4 000-body cap that was the largest cost of an open.
	if nodes.is_empty() or not UiMotion.enabled() or was_settled:
		_settle_now()
	else:
		_begin_motion()
	if first_show:
		call_deferred("_fit_if_needed")
	last_build_us = Time.get_ticks_usec() - started


func set_weights(declared: Dictionary) -> void:
	VaultGraphModel.apply_weights(edges, declared)
	_recompute_weight_scale()
	_rebuild_springs()
	_rebuild_links()
	_update_status()
	_overlay.queue_redraw()
	_request_render()


func set_selected(id: String) -> void:
	var next := id if _has_node(id) else ""
	if next == selected_id:
		return
	selected_id = next
	_a11y_cursor = ""
	_update_node_colors()
	_update_status()
	_overlay.queue_redraw()
	_request_render()


func relayout() -> void:
	positions = VaultGraphModel.layout(nodes, edges, {})
	for id in _bodies:
		if not positions.has(id):
			continue
		var body: RigidBody3D = _bodies[id]
		if not is_instance_valid(body):
			continue
		body.global_position = _world_from_model(positions[id], float(_depths.get(id, 0.0)))
		body.linear_velocity = Vector3.ZERO
		body.angular_velocity = Vector3.ZERO
	_rest = {}
	_rebuild_rests()
	_settle_now()
	_update_status()
	_overlay.queue_redraw()
	_needs_fit = true
	call_deferred("_fit_if_needed")


func fit_to_view() -> void:
	if nodes.is_empty():
		return
	_yaw = 0.0
	_pitch = 0.0
	_update_camera()
	var box := VaultGraphModel.bounds(positions)
	if box.size.x <= 0.0 or box.size.y <= 0.0 or size.x < 2.0 or size.y < 2.0:
		return
	var pad := 1.0 - 2.0 * FIT_PADDING
	var usable_w := maxf(1.0, size.x * pad - _label_block_w)
	var usable_h := maxf(1.0, size.y * pad)
	var vertical := maxf(
		box.size.y * size.y / usable_h,
		box.size.x * size.y / usable_w
	)
	_camera.size = clampf(vertical, ZOOM_MIN_SIZE, ZOOM_MAX_SIZE)
	var upp := float(_camera.size) / maxf(1.0, size.y)
	_target = _world_from_model(box.get_center(), 0.0) \
		+ _camera.global_basis.x * (_label_block_w * 0.5 * upp)
	_update_camera()
	# The link widths are world-space from the old units-per-pixel; rebuild so
	# the fitted view keeps the 1-3 px strokes the planar canvas uses.
	_rebuild_links()
	_overlay.queue_redraw()
	_request_render()


func export_positions() -> Dictionary:
	return VaultGraphModel.serialize_positions(positions, nodes)


# ═══════════════════════════════════════════════════════════════════════
# Scene construction
# ═══════════════════════════════════════════════════════════════════════

func _ensure_scene() -> void:
	if _viewport != null:
		return
	_container = SubViewportContainer.new()
	_container.name = "MapViewport"
	_container.stretch = true
	_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_container.focus_mode = Control.FOCUS_NONE
	_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_container)

	_viewport = SubViewport.new()
	_viewport.name = "Map"
	_viewport.own_world_3d = true
	_viewport.disable_3d = false
	_viewport.gui_disable_input = true
	_viewport.physics_object_picking = false
	_viewport.transparent_bg = true
	_viewport.msaa_3d = Viewport.MSAA_2X
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_container.add_child(_viewport)

	_world = Node3D.new()
	_world.name = "World"
	_viewport.add_child(_world)

	_camera = Camera3D.new()
	_camera.name = "Camera"
	_camera.current = true
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.near = 1.0
	_camera.far = 10000.0
	_camera.size = 1000.0
	_world.add_child(_camera)

	_env = WorldEnvironment.new()
	_env.name = "Environment"
	_env.environment = _make_environment()
	_world.add_child(_env)

	_bodies_root = Node3D.new()
	_bodies_root.name = "Bodies"
	_world.add_child(_bodies_root)

	_quad = QuadMesh.new()
	_quad.size = Vector2(2.0, 2.0)
	_disc_texture = _make_radial_texture(KIND_DISC)
	_ring_texture = _make_radial_texture(KIND_RING)
	_halo_texture = _make_radial_texture(KIND_HALO)
	_note_material = _make_billboard_material(_disc_texture, false)
	_ghost_material = _make_billboard_material(_ring_texture, false)
	_halo_material = _make_billboard_material(_halo_texture, true)
	_dust_material = _make_billboard_material(_halo_texture, true)
	_link_material = StandardMaterial3D.new()
	_link_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_link_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_link_material.vertex_color_use_as_albedo = true
	_link_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_link_material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED

	_notes_mesh = _make_multimesh("Notes", _note_material)
	_ghosts_mesh = _make_multimesh("Ghosts", _ghost_material)
	_halos_mesh = _make_multimesh("Halos", _halo_material)
	_dust_mesh = _make_multimesh("Dust", _dust_material)

	_link_mesh = ImmediateMesh.new()
	_links_mi = MeshInstance3D.new()
	_links_mi.name = "Links"
	_links_mi.mesh = _link_mesh
	_links_mi.material_override = _link_material
	_world.add_child(_links_mi)

	_overlay = _GraphOverlay.new()
	_overlay.name = "Overlay"
	_overlay.host = self
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_overlay)

	_vignette = _make_vignette()
	_build_dust()
	_apply_theme()
	_update_camera()
	_request_render()


func _make_environment() -> Environment:
	var env := Environment.new()
	# The ground is painted by this Control in 2D (the palette's own sRGB
	# background); the viewport is transparent so the 3D scene composites over
	# it. A 3D background colour went through a different colour path and
	# crushed the dark surface to near-black.
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.fog_enabled = true
	env.fog_light_color = UiPalette.active().BG
	env.fog_light_energy = FOG_ENERGY
	env.fog_density = FOG_DENSITY
	env.fog_sky_affect = 0.0
	return env


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), UiPalette.active().BG)


func _apply_theme() -> void:
	var dark := SettingsManager.is_dark_appearance()
	if _env != null and _env.environment != null:
		var env := _env.environment
		env.fog_light_color = UiPalette.active().BG
		env.fog_light_energy = FOG_ENERGY
		env.fog_density = FOG_DENSITY
		# Fog is a depth cue for the graph, never a repaint of the ground: at
		# energy 0.6 it dimmed the whole background to a grey block in the
		# light theme. The sky/background keeps the surface colour.
		env.fog_sky_affect = 0.0
		env.glow_enabled = dark and RenderingServer.get_current_rendering_method() != "gl_compatibility"
		if env.glow_enabled:
			env.glow_intensity = GLOW_INTENSITY
			env.glow_strength = GLOW_STRENGTH
			env.glow_bloom = GLOW_BLOOM
			env.glow_hdr_threshold = GLOW_THRESHOLD
			env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	if _halo_material != null:
		_halo_material.blend_mode = (
			BaseMaterial3D.BLEND_MODE_ADD if dark else BaseMaterial3D.BLEND_MODE_MIX
		)
	if _dust_material != null:
		_dust_material.blend_mode = (
			BaseMaterial3D.BLEND_MODE_ADD if dark else BaseMaterial3D.BLEND_MODE_MIX
		)
	_update_node_colors()
	_update_dust_colors()
	queue_redraw()
	if _overlay != null:
		_overlay.queue_redraw()
	_request_render()


func _make_radial_texture(kind: int) -> ImageTexture:
	var image := Image.create(TEXTURE_SIZE, TEXTURE_SIZE, false, Image.FORMAT_RGBA8)
	var centre := float(TEXTURE_SIZE - 1) * 0.5
	for y in TEXTURE_SIZE:
		for x in TEXTURE_SIZE:
			var d := Vector2(float(x) - centre, float(y) - centre).length() / centre
			var alpha := 0.0
			match kind:
				KIND_DISC:
					alpha = clampf((1.0 - d) / 0.18, 0.0, 1.0)
				KIND_RING:
					alpha = clampf(1.0 - absf(d - 0.78) / 0.18, 0.0, 1.0)
				_:
					alpha = pow(clampf(1.0 - d, 0.0, 1.0), 2.2)
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, alpha))
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)


func _make_vignette() -> GradientTexture2D:
	var gradient := Gradient.new()
	gradient.set_color(0, Color(0.0, 0.0, 0.0, 0.0))
	gradient.set_color(1, Color(0.0, 0.0, 0.0, 1.0))
	gradient.add_point(0.55, Color(0.0, 0.0, 0.0, 0.0))
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(1.0, 1.0)
	texture.width = VIGNETTE_SIZE
	texture.height = VIGNETTE_SIZE
	return texture


func _make_billboard_material(texture: Texture2D, additive: bool) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.vertex_color_use_as_albedo = true
	material.albedo_texture = texture
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.billboard_keep_scale = true
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	if additive:
		material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	return material


func _make_multimesh(mesh_name: String, material: Material) -> MultiMeshInstance3D:
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = _quad
	multimesh.instance_count = 0
	var instance := MultiMeshInstance3D.new()
	instance.name = mesh_name
	instance.multimesh = multimesh
	instance.material_override = material
	instance.custom_aabb = AABB(Vector3(-6000, -6000, -3000), Vector3(12000, 12000, 6000))
	_world.add_child(instance)
	return instance


func _build_chrome() -> void:
	_status = Label.new()
	_status.name = "GraphStatus"
	_status.add_theme_font_size_override("font_size", UiTokens.FS_CAPTION)
	_status.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_status.offset_left = 8
	_status.offset_top = 5
	_status.offset_right = 520
	_status.offset_bottom = 24
	_status.grow_horizontal = Control.GROW_DIRECTION_END
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_status)

	var controls := HBoxContainer.new()
	controls.name = "GraphControls"
	controls.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	controls.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	controls.offset_left = -360
	controls.offset_right = -8
	controls.offset_top = 4
	controls.offset_bottom = 28
	controls.alignment = BoxContainer.ALIGNMENT_END
	controls.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(controls)

	_mode_button = _make_button("Planar", "Switch to the flat link map")
	_mode_button.pressed.connect(func(): mode_requested.emit("2d"))
	controls.add_child(_mode_button)

	_orbit_button = _make_button("Orbit", "Rotate the map with a background drag")
	_orbit_button.toggle_mode = true
	_orbit_button.toggled.connect(func(on: bool): _set_orbit(on))
	controls.add_child(_orbit_button)

	_arrows_button = _make_button("Arrows", "Draw edge direction (mutual pairs both ways)")
	_arrows_button.toggle_mode = true
	_arrows_button.toggled.connect(func(on: bool):
		show_arrows = on
		_overlay.queue_redraw()
	)
	controls.add_child(_arrows_button)

	_relayout_button = _make_button("Relayout", "Run the deterministic layout again")
	_relayout_button.pressed.connect(relayout)
	controls.add_child(_relayout_button)

	_fit_button = _make_button("Fit", "Fit the whole graph in the view (front view)")
	_fit_button.pressed.connect(fit_to_view)
	controls.add_child(_fit_button)

	KeyboardFocus.ring([self, _mode_button, _orbit_button, _arrows_button,
		_relayout_button, _fit_button])

	_edge_menu = PopupMenu.new()
	_edge_menu.name = "EdgeMenu"
	_edge_menu.add_item("Set declared weight…", 0)
	_edge_menu.add_item("Clear declared weight", 1)
	_edge_menu.id_pressed.connect(_on_edge_menu_pressed)
	add_child(_edge_menu)

	_hint = Label.new()
	_hint.name = "GraphHint"
	_hint.text = "Drag to pan · Middle-drag pans · Orbit makes left-drag rotate · Wheel to zoom · Drag a node to push it · Click a note to open it · Right-click an edge to declare its weight · Arrows pan · +/− zoom · Enter opens what the crosshair covers"
	_hint.add_theme_font_size_override("font_size", UiTokens.FS_CAPTION)
	_hint.modulate = Color(1, 1, 1, 0.55)
	_hint.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_hint.offset_left = 8
	_hint.offset_top = -20
	_hint.offset_right = 900
	_hint.offset_bottom = -4
	_hint.grow_horizontal = Control.GROW_DIRECTION_END
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_hint)

	accessibility_name = "Vault link graph"
	_a11y_host = A11y.announce_host(self)


func _describe() -> String:
	var notes := 0
	var ghosts := 0
	for node in nodes:
		if node is Dictionary and bool(node.get("ghost", false)):
			ghosts += 1
		else:
			notes += 1
	var text := "%d notes, %d links. 3D map. Arrows pan, plus and minus zoom, Enter opens what the crosshair covers." % [notes, edges.size()]
	if _truncated:
		text += " (map truncated)"
	return text


# ═══════════════════════════════════════════════════════════════════════
# Bodies and springs
# ═══════════════════════════════════════════════════════════════════════

func _sync_bodies() -> void:
	var wanted := {}
	for node in nodes:
		if not (node is Dictionary):
			continue
		var id := str(node.get("id", ""))
		if id != "":
			wanted[id] = true
	for id in _bodies.keys():
		if not wanted.has(id):
			_remove_body(id)
	for node in nodes:
		if not (node is Dictionary):
			continue
		var id := str(node.get("id", ""))
		if id == "" or _bodies.has(id):
			continue
		var model: Vector2 = positions.get(id, Vector2(500.0, 500.0))
		var depth := VaultGraphModel.depth_for(id, DEPTH_SPREAD)
		_depths[id] = depth
		var body := RigidBody3D.new()
		body.name = "Node"
		body.mass = 1.0
		body.gravity_scale = 0.0
		body.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
		body.linear_damp = SPRING_DAMP
		body.axis_lock_angular_x = true
		body.axis_lock_angular_y = true
		body.axis_lock_angular_z = true
		body.axis_lock_linear_z = true
		body.collision_layer = 0
		body.collision_mask = 0
		body.can_sleep = false
		body.freeze = true
		body.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		body.position = _world_from_model(model, depth)
		_bodies_root.add_child(body)
		_bodies[id] = body


func _remove_body(id: String) -> void:
	var body = _bodies.get(id)
	_bodies.erase(id)
	_depths.erase(id)
	_rest.erase(id)
	for other in _rest:
		(_rest[other] as Dictionary).erase(id)
	if body != null and is_instance_valid(body):
		_bodies_root.remove_child(body)
		body.queue_free()


func _rebuild_rests() -> void:
	var next := {}
	for edge in edges:
		if not (edge is Dictionary):
			continue
		var a := str(edge.get("a", ""))
		var b := str(edge.get("b", ""))
		if not _bodies.has(a) or not _bodies.has(b):
			continue
		var value: Variant = null
		if _rest.has(a) and (_rest[a] as Dictionary).has(b):
			value = (_rest[a] as Dictionary)[b]
		if value == null:
			var pa: Vector3 = (_bodies[a] as RigidBody3D).global_position
			var pb: Vector3 = (_bodies[b] as RigidBody3D).global_position
			value = maxf(pa.distance_to(pb), MIN_REST_LENGTH)
		if not next.has(a):
			next[a] = {}
		next[a][b] = float(value)
	_rest = next
	_rebuild_springs()


## Rebuild the force loop's parallel arrays from the current edges, bodies,
## rests and display weights. Called whenever any of those change; the physics
## tick then touches no dictionaries or strings for the 10 000-edge cap.
func _rebuild_springs() -> void:
	_spring_a.clear()
	_spring_b.clear()
	_spring_rest.clear()
	_spring_k.clear()
	for edge in edges:
		if not (edge is Dictionary):
			continue
		var a := str(edge.get("a", ""))
		var b := str(edge.get("b", ""))
		if not _bodies.has(a) or not _bodies.has(b):
			continue
		var body_a: RigidBody3D = _bodies[a]
		var body_b: RigidBody3D = _bodies[b]
		if not (is_instance_valid(body_a) and is_instance_valid(body_b)):
			continue
		_spring_a.append(body_a)
		_spring_b.append(body_b)
		_spring_rest.append(_rest_for(a, b))
		_spring_k.append(
			SPRING_K * VaultGraphModel.spring_strength(
				int(edge.get("weight", edge.get("count", 1)))
			)
		)


func _rest_for(a: String, b: String) -> float:
	if _rest.has(a) and (_rest[a] as Dictionary).has(b):
		return float((_rest[a] as Dictionary)[b])
	return MIN_REST_LENGTH


func _update_incident_rests(id: String) -> void:
	for edge in edges:
		if not (edge is Dictionary):
			continue
		var a := str(edge.get("a", ""))
		var b := str(edge.get("b", ""))
		if a != id and b != id:
			continue
		if not _bodies.has(a) or not _bodies.has(b):
			continue
		var pa: Vector3 = (_bodies[a] as RigidBody3D).global_position
		var pb: Vector3 = (_bodies[b] as RigidBody3D).global_position
		if not _rest.has(a):
			_rest[a] = {}
		_rest[a][b] = maxf(pa.distance_to(pb), MIN_REST_LENGTH)
	_rebuild_springs()


func _apply_forces() -> void:
	var centre := Vector3.ZERO
	for id in _bodies:
		var body: RigidBody3D = _bodies[id]
		if is_instance_valid(body):
			body.apply_central_force((centre - body.global_position) * CENTER_PULL)
	for i in _spring_a.size():
		var body_a := _spring_a[i]
		var body_b := _spring_b[i]
		if not (is_instance_valid(body_a) and is_instance_valid(body_b)):
			continue
		var delta := body_b.global_position - body_a.global_position
		var dist := delta.length()
		if dist < 0.0001:
			continue
		var force := delta / dist * (dist - _spring_rest[i]) * _spring_k[i]
		force = force.limit_length(MAX_SPRING_FORCE)
		body_a.apply_central_force(force)
		body_b.apply_central_force(-force)


func _sync_positions_from_bodies() -> void:
	var moved := false
	for id in _bodies:
		var body: RigidBody3D = _bodies[id]
		if not is_instance_valid(body):
			continue
		var point := _model_from_world(body.global_position)
		var clamped := Vector2(
			clampf(point.x, -VaultGraphModel.POSITION_BOUND, VaultGraphModel.POSITION_BOUND),
			clampf(point.y, -VaultGraphModel.POSITION_BOUND, VaultGraphModel.POSITION_BOUND)
		)
		var previous: Variant = positions.get(id)
		if not (previous is Vector2) \
				or (previous as Vector2).distance_squared_to(clamped) > 0.0001:
			_moved_ids[id] = true
			moved = true
		positions[id] = clamped
	if moved:
		_screen_dirty = true


func _begin_motion() -> void:
	if _viewport == null or _bodies.is_empty() or not UiMotion.enabled():
		_settle_now()
		return
	_hidden_paused = false
	for id in _bodies:
		var body: RigidBody3D = _bodies[id]
		if is_instance_valid(body):
			body.freeze = false
	_settled = false
	_settle_ticks = 0
	_link_accum = 0.0
	set_physics_process(true)
	set_process(true)
	_request_render()


func _settle_now() -> void:
	for id in _bodies:
		var body: RigidBody3D = _bodies[id]
		if not is_instance_valid(body):
			continue
		body.freeze = true
		body.linear_velocity = Vector3.ZERO
		body.angular_velocity = Vector3.ZERO
	_settled = true
	_settle_ticks = 0
	set_physics_process(false)
	set_process(false)
	_sync_positions_from_bodies()
	_update_node_transforms()
	_rebuild_links()
	_overlay.queue_redraw()
	_request_render()


func _physics_process(delta: float) -> void:
	if not is_visible_in_tree():
		_pause_for_hidden()
		return
	if _hidden_paused:
		_resume_from_hidden()
	if _settled:
		return
	_ticks += 1
	var started := Time.get_ticks_usec()
	_apply_forces()
	last_step_us = Time.get_ticks_usec() - started
	started = Time.get_ticks_usec()
	_sync_positions_from_bodies()
	_update_node_transforms(_moved_ids)
	_moved_ids.clear()
	last_visual_us = Time.get_ticks_usec() - started
	_link_accum += delta
	if _link_accum >= 1.0 / LINK_REBUILD_HZ:
		_link_accum = 0.0
		_rebuild_links()
	_overlay.queue_redraw()
	var speed := max_speed()
	if _drag_id != "":
		_settle_ticks = 0
	elif speed < SETTLE_SPEED:
		_settle_ticks += 1
		if _settle_ticks >= SETTLE_TICKS:
			_settle_now()
	else:
		_settle_ticks = 0


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		_pause_for_hidden()
		return
	if _hidden_paused or _dust_mesh == null or not UiMotion.enabled():
		return
	_dust_accum += delta
	if _dust_accum < 1.0 / DUST_HZ:
		return
	var step := _dust_accum
	_dust_accum = 0.0
	var multimesh: MultiMesh = _dust_mesh.multimesh
	for i in _dust_positions.size():
		var point: Vector3 = _dust_positions[i]
		point.y += _dust_speeds[i] * step
		if point.y > DUST_BOX_Y:
			point.y = -DUST_BOX_Y
		_dust_positions[i] = point
		multimesh.set_instance_transform(
			i, Transform3D(Basis.from_scale(Vector3.ONE * _dust_scales[i]), point)
		)


func _pause_for_hidden() -> void:
	if _hidden_paused:
		return
	_hidden_paused = true
	if _drag_id != "":
		_update_incident_rests(_drag_id)
		_drag_id = ""
	_dragging_camera = false
	_panning = false
	for id in _bodies:
		var body: RigidBody3D = _bodies[id]
		if not is_instance_valid(body):
			continue
		body.freeze = true
		body.linear_velocity = Vector3.ZERO
		body.angular_velocity = Vector3.ZERO
	set_process(false)
	if _viewport != null:
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED


func _resume_from_hidden() -> void:
	_hidden_paused = false
	if _settled:
		_request_render()
	else:
		_begin_motion()


# ═══════════════════════════════════════════════════════════════════════
# Camera and pointer
# ═══════════════════════════════════════════════════════════════════════

func _update_camera() -> void:
	if _camera == null:
		return
	var yaw := deg_to_rad(_yaw)
	var pitch := deg_to_rad(_pitch)
	var direction := Vector3(
		sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)
	)
	_camera.global_position = _target + direction * CAMERA_DISTANCE
	_camera.look_at(_target, Vector3.UP)
	_camera.size = clampf(_camera.size, ZOOM_MIN_SIZE, ZOOM_MAX_SIZE)
	_screen_dirty = true


func _units_per_pixel() -> float:
	# The SubViewport's size lags the first show_graph by a frame: its height
	# can still be 0 when the first link mesh is built. Falling back to 1 px
	# there produced thousand-unit-wide quads that covered the whole pane, so
	# the Control's own size is the second source and a sane default is last.
	var height := float(_viewport.size.y) if _viewport != null else 0.0
	if height < 2.0:
		height = size.y
	height = maxf(1.0, height)
	return float(_camera.size) / height if _camera != null else 1.0


func _pixels_per_unit() -> float:
	var upp := _units_per_pixel()
	return 0.0 if upp <= 0.0 else 1.0 / upp


func _world_from_model(point: Vector2, depth: float) -> Vector3:
	return Vector3(point.x - 500.0, 500.0 - point.y, depth)


func _model_from_world(point: Vector3) -> Vector2:
	return Vector2(point.x + 500.0, 500.0 - point.y)


func _cursor_screen() -> Vector2:
	return size * 0.5


func _world_under(screen_point: Vector2) -> Vector3:
	var upp := _units_per_pixel()
	var right := _camera.global_basis.x
	var up := _camera.global_basis.y
	return _target \
		+ right * ((screen_point.x - size.x * 0.5) * upp) \
		- up * ((screen_point.y - size.y * 0.5) * upp)


func _pan_by(screen_delta: Vector2) -> void:
	var upp := _units_per_pixel()
	var right := _camera.global_basis.x
	var up := _camera.global_basis.y
	_target -= right * (screen_delta.x * upp) - up * (screen_delta.y * upp)
	_update_camera()
	_overlay.queue_redraw()
	_request_render()


func _orbit_by(screen_delta: Vector2) -> void:
	_yaw += screen_delta.x * ORBIT_SENSITIVITY
	_pitch = clampf(
		_pitch - screen_delta.y * ORBIT_SENSITIVITY,
		-PITCH_LIMIT_DEG, PITCH_LIMIT_DEG
	)
	_update_camera()
	# The link quads' side vector is the camera's right; an orbit changes it.
	# The rebuild is throttled to the same rate as the simulation's.
	if Time.get_ticks_msec() - _last_link_ms >= int(1000.0 / LINK_REBUILD_HZ):
		_rebuild_links()
	_overlay.queue_redraw()
	_request_render()


func _zoom_at(screen_point: Vector2, factor: float) -> void:
	var before := _world_under(screen_point)
	_camera.size = clampf(_camera.size / factor, ZOOM_MIN_SIZE, ZOOM_MAX_SIZE)
	var after := _world_under(screen_point)
	_target += before - after
	_update_camera()
	_overlay.queue_redraw()
	_request_render()


func _set_orbit(on: bool) -> void:
	_orbit_mode = on
	if not on:
		_dragging_camera = false


func _screen_positions() -> Dictionary:
	if not _screen_dirty:
		return _screen_cache
	var out := {}
	if _camera != null:
		for id in _bodies:
			var body: RigidBody3D = _bodies[id]
			if is_instance_valid(body):
				out[id] = _camera.unproject_position(body.global_position)
	_screen_cache = out
	_screen_dirty = false
	return out


func _node_at(screen_point: Vector2) -> String:
	if nodes.is_empty():
		return ""
	return VaultGraphModel.hit_test(nodes, _screen_positions(), screen_point, HIT_RADIUS)


func _edge_at(screen_point: Vector2) -> Dictionary:
	return VaultGraphModel.hit_test_edge(
		edges, _screen_positions(), screen_point, EDGE_HIT_RADIUS
	)


func cursor_hit() -> String:
	if nodes.is_empty():
		return ""
	return _node_at(_cursor_screen())


func _node_screen_radius(id: String) -> float:
	var degrees: Dictionary = _degrees.get(id, {})
	var degree := int(degrees.get("in", 0)) + int(degrees.get("out", 0))
	return clampf(
		VaultGraphModel.node_radius(degree, _max_degree) * NODE_WORLD_SCALE * _pixels_per_unit(),
		2.0, 22.0
	)


# ═══════════════════════════════════════════════════════════════════════
# Input
# ═══════════════════════════════════════════════════════════════════════

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_zoom_at(event.position, ZOOM_STEP)
			accept_event()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_zoom_at(event.position, 1.0 / ZOOM_STEP)
			accept_event()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_begin_left(event.position)
			else:
				_end_left(event.position)
			accept_event()
		elif event.button_index == MOUSE_BUTTON_MIDDLE:
			if event.pressed:
				_panning = true
				_press_screen = event.position
				_moved = false
			else:
				_panning = false
			accept_event()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				_open_edge_menu(event.position)
			accept_event()
	elif event is InputEventMouseMotion:
		if _drag_id != "":
			_drag_by(event.relative)
			if event.position.distance_to(_press_screen) > DRAG_THRESHOLD:
				_moved = true
		elif _panning:
			_pan_by(event.relative)
			if event.position.distance_to(_press_screen) > DRAG_THRESHOLD:
				_moved = true
		elif _dragging_camera:
			_orbit_by(event.relative)
			if event.position.distance_to(_press_screen) > DRAG_THRESHOLD:
				_moved = true
		else:
			_hover(event.position)
	elif event is InputEventKey:
		if event.pressed and not event.echo and _handle_key(event):
			accept_event()


func _begin_left(screen_point: Vector2) -> void:
	_press_screen = screen_point
	_moved = false
	var hit := _node_at(screen_point)
	if hit != "":
		_begin_drag(hit)
	elif _orbit_mode:
		_dragging_camera = true
	else:
		_panning = true


func _end_left(screen_point: Vector2) -> void:
	var dragged := _drag_id
	var moved := _moved
	var travelled := _panning or _dragging_camera
	_panning = false
	_dragging_camera = false
	if dragged != "":
		if moved:
			_finish_drag(true)
		else:
			_finish_drag(false)
			if dragged.begins_with("ghost:"):
				ghost_activated.emit(dragged.trim_prefix("ghost:"))
			else:
				node_activated.emit(dragged)
	elif travelled and not moved:
		_hover(screen_point)
	_moved = false


func _begin_drag(id: String) -> void:
	_drag_id = id
	_moved = false
	if UiMotion.enabled():
		_begin_motion()
	var body = _bodies.get(id)
	if body != null and is_instance_valid(body):
		body.freeze = true
		body.linear_velocity = Vector3.ZERO


func _drag_by(screen_delta: Vector2) -> void:
	if _drag_id == "":
		return
	var upp := _units_per_pixel()
	var right := _camera.global_basis.x
	var up := _camera.global_basis.y
	var world := right * (screen_delta.x * upp) - up * (screen_delta.y * upp)
	var current: Vector2 = positions.get(_drag_id, Vector2(500.0, 500.0))
	var next := Vector2(
		clampf(current.x + world.x, -VaultGraphModel.POSITION_BOUND, VaultGraphModel.POSITION_BOUND),
		clampf(current.y - world.y, -VaultGraphModel.POSITION_BOUND, VaultGraphModel.POSITION_BOUND)
	)
	_place_body(_drag_id, next)
	if not UiMotion.enabled():
		_request_render()


func _place_body(id: String, model_point: Vector2) -> void:
	var body = _bodies.get(id)
	if body == null or not is_instance_valid(body):
		return
	var point := Vector2(
		clampf(model_point.x, -VaultGraphModel.POSITION_BOUND, VaultGraphModel.POSITION_BOUND),
		clampf(model_point.y, -VaultGraphModel.POSITION_BOUND, VaultGraphModel.POSITION_BOUND)
	)
	positions[id] = point
	body.global_position = _world_from_model(point, float(_depths.get(id, 0.0)))
	_screen_dirty = true
	_moved_ids[id] = true
	_update_node_transforms(_moved_ids)
	_moved_ids.clear()
	_rebuild_links()
	_overlay.queue_redraw()


func _drag_to(id: String, model_point: Vector2) -> void:
	_place_body(id, model_point)


func _finish_drag(settle: bool) -> void:
	if _drag_id == "":
		return
	var id := _drag_id
	_update_incident_rests(id)
	var body = _bodies.get(id)
	if body != null and is_instance_valid(body):
		body.freeze = true
		body.linear_velocity = Vector3.ZERO
	_drag_id = ""
	if settle and UiMotion.enabled():
		# A drop is not a throw: the released arrangement starts from rest, so
		# momentum gathered during the hold cannot drag the dropped node away
		# from where the user let go. The springs still settle the neighbours.
		for other_id in _bodies:
			var other: RigidBody3D = _bodies[other_id]
			if is_instance_valid(other):
				other.linear_velocity = Vector3.ZERO
				other.angular_velocity = Vector3.ZERO
		_begin_motion()
	elif not UiMotion.enabled():
		_settle_now()


func _cancel_gestures() -> void:
	if _drag_id != "":
		_update_incident_rests(_drag_id)
		_drag_id = ""
	_panning = false
	_dragging_camera = false
	_moved = false


func _hover(screen_point: Vector2) -> void:
	var hit := _node_at(screen_point)
	if hit == hovered_id:
		return
	hovered_id = hit
	mouse_default_cursor_shape = (
		Control.CURSOR_POINTING_HAND if hit != "" else Control.CURSOR_DRAG
	)
	_update_node_colors()
	_overlay.queue_redraw()
	_request_render()


func _handle_key(event: InputEventKey) -> bool:
	var step := PAN_STEP * (PAN_FAST if event.shift_pressed else 1.0)
	var upp := _units_per_pixel()
	var right := _camera.global_basis.x
	var up := _camera.global_basis.y
	match event.keycode:
		KEY_LEFT:
			_target += right * (step * upp)
		KEY_RIGHT:
			_target -= right * (step * upp)
		KEY_UP:
			_target -= up * (step * upp)
		KEY_DOWN:
			_target += up * (step * upp)
		KEY_PLUS, KEY_EQUAL, KEY_KP_ADD:
			_zoom_at(_cursor_screen(), ZOOM_STEP)
		KEY_MINUS, KEY_KP_SUBTRACT:
			_zoom_at(_cursor_screen(), 1.0 / ZOOM_STEP)
		KEY_ENTER, KEY_KP_ENTER:
			_activate_at_cursor()
		_:
			return false
	if event.keycode in [KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN]:
		_update_camera()
		_overlay.queue_redraw()
		_request_render()
	_announce_cursor()
	return true


func _activate_at_cursor() -> void:
	var hit := cursor_hit()
	if hit != "":
		if hit.begins_with("ghost:"):
			ghost_activated.emit(hit.trim_prefix("ghost:"))
		else:
			node_activated.emit(hit)
		return
	var edge := _edge_at(_cursor_screen())
	if not edge.is_empty() and not bool(edge.get("ghost", false)):
		_open_edge_menu(_cursor_screen())


func _open_edge_menu(screen_point: Vector2) -> void:
	var edge := _edge_at(screen_point)
	if edge.is_empty() or bool(edge.get("ghost", false)):
		return
	_pending_edge = edge
	var declared := int(edge.get("declared", 0))
	_edge_menu.set_item_text(
		0,
		"Set declared weight…" if declared <= 0 else "Change declared weight (%d)…" % declared
	)
	_edge_menu.set_item_disabled(1, declared <= 0)
	_edge_menu.popup_on_parent(Rect2i(Vector2i(screen_point), Vector2i.ZERO))


func _on_edge_menu_pressed(id: int) -> void:
	var edge := _pending_edge
	_pending_edge = {}
	if edge.is_empty():
		return
	var a := str(edge.get("a", ""))
	var b := str(edge.get("b", ""))
	if a == "" or b == "":
		return
	if id == 0:
		weight_set_requested.emit(a, b, int(edge.get("declared", 0)))
	elif id == 1:
		weight_cleared.emit(a, b)


# ═══════════════════════════════════════════════════════════════════════
# Meshes and labels
# ═══════════════════════════════════════════════════════════════════════

func _sync_mesh_layout() -> void:
	if _notes_mesh == null:
		return
	var notes: Array = []
	var ghosts: Array = []
	for node in nodes:
		if not (node is Dictionary):
			continue
		var id := str(node.get("id", ""))
		if id == "":
			continue
		if bool(node.get("ghost", false)):
			ghosts.append(id)
		else:
			notes.append(id)
	_note_index.clear()
	_ghost_index.clear()
	_halo_index.clear()
	_notes_mesh.multimesh.instance_count = notes.size()
	_ghosts_mesh.multimesh.instance_count = ghosts.size()
	_halos_mesh.multimesh.instance_count = notes.size() + ghosts.size()
	for i in notes.size():
		_note_index[notes[i]] = i
	for i in ghosts.size():
		_ghost_index[ghosts[i]] = i
	var halo := 0
	for id in notes:
		_halo_index[id] = halo
		halo += 1
	for id in ghosts:
		_halo_index[id] = halo
		halo += 1


func _update_node_transforms(only: Dictionary = {}) -> void:
	if _notes_mesh == null:
		return
	if only.is_empty():
		for id in _note_index:
			_set_note_transform(id)
		for id in _ghost_index:
			_set_ghost_transform(id)
		for id in _halo_index:
			_set_halo_transform(id)
		_moved_ids.clear()
		return
	for id in only:
		if _note_index.has(id):
			_set_note_transform(id)
		if _ghost_index.has(id):
			_set_ghost_transform(id)
		if _halo_index.has(id):
			_set_halo_transform(id)


func _set_note_transform(id: String) -> void:
	var body = _bodies.get(id)
	if body == null or not is_instance_valid(body):
		return
	var radius := _node_radius_world(id)
	_notes_mesh.multimesh.set_instance_transform(
		int(_note_index[id]),
		Transform3D(Basis.from_scale(Vector3(radius, radius, 1.0)), body.global_position)
	)


func _set_ghost_transform(id: String) -> void:
	var body = _bodies.get(id)
	if body == null or not is_instance_valid(body):
		return
	var radius := _node_radius_world(id)
	_ghosts_mesh.multimesh.set_instance_transform(
		int(_ghost_index[id]),
		Transform3D(Basis.from_scale(Vector3(radius, radius, 1.0)), body.global_position)
	)


func _set_halo_transform(id: String) -> void:
	var body = _bodies.get(id)
	if body == null or not is_instance_valid(body):
		return
	var radius := _node_radius_world(id) * HALO_SCALE
	_halos_mesh.multimesh.set_instance_transform(
		int(_halo_index[id]),
		Transform3D(Basis.from_scale(Vector3(radius, radius, 1.0)), body.global_position)
	)


func _node_radius_world(id: String) -> float:
	var degrees: Dictionary = _degrees.get(id, {})
	var degree := int(degrees.get("in", 0)) + int(degrees.get("out", 0))
	return VaultGraphModel.node_radius(degree, _max_degree) * NODE_WORLD_SCALE


func _update_node_colors() -> void:
	if _notes_mesh == null:
		return
	var palette := UiPalette.active()
	var dark := SettingsManager.is_dark_appearance()
	var halo_alpha := HALO_ALPHA_DARK if dark else HALO_ALPHA_LIGHT
	for id in _note_index:
		var color := Color(palette.TEXT, 0.8)
		if id == selected_id:
			color = palette.ACCENT
		elif id == hovered_id:
			color = Color(palette.TEXT, 1.0)
		_notes_mesh.multimesh.set_instance_color(int(_note_index[id]), color)
	for id in _ghost_index:
		var color := Color(palette.TEXT, 0.6)
		if id == hovered_id:
			color = Color(palette.TEXT, 0.95)
		_ghosts_mesh.multimesh.set_instance_color(int(_ghost_index[id]), color)
	for id in _halo_index:
		var color := Color(palette.TEXT, halo_alpha)
		if id == selected_id:
			color = Color(palette.ACCENT, halo_alpha * 1.6)
		elif id == hovered_id:
			color = Color(palette.TEXT, halo_alpha * 1.4)
		if not _note_index.has(id):
			color.a *= 0.5
		_halos_mesh.multimesh.set_instance_color(int(_halo_index[id]), color)


func _rebuild_links() -> void:
	if _link_mesh == null or _link_material == null:
		return
	var started := Time.get_ticks_usec()
	_link_mesh.clear_surfaces()
	_link_ends.clear()
	if edges.is_empty():
		last_link_build_us = Time.get_ticks_usec() - started
		return
	var palette := UiPalette.active()
	var upp := _units_per_pixel()
	var right := _camera.global_basis.x
	var feathered := edges.size() <= MAX_FEATHERED_EDGES
	var default_color := Color(palette.TEXT, LINK_ALPHA)
	var related_color := Color(palette.ACCENT, 0.85)
	var declared_color := Color(palette.ACCENT, 0.5)
	var added := false
	_link_mesh.surface_begin(
		Mesh.PRIMITIVE_TRIANGLES if feathered else Mesh.PRIMITIVE_LINES,
		_link_material
	)
	for edge in edges:
		if not (edge is Dictionary):
			continue
		var a := str(edge.get("a", ""))
		var b := str(edge.get("b", ""))
		if not _bodies.has(a) or not _bodies.has(b):
			continue
		var body_a: RigidBody3D = _bodies[a]
		var body_b: RigidBody3D = _bodies[b]
		if not (is_instance_valid(body_a) and is_instance_valid(body_b)):
			continue
		var pa := body_a.global_position
		var pb := body_b.global_position
		added = true
		var related := selected_id != "" and (a == selected_id or b == selected_id)
		var declared := int(edge.get("declared", 0))
		var color := default_color
		if related:
			color = related_color
		elif declared > 0:
			color = declared_color
		if feathered:
			# The debug record is for the small graphs the tests drive; at the
			# 10 000-edge cap it would allocate a nested dict per rebuild.
			if not _link_ends.has(a):
				_link_ends[a] = {}
			_link_ends[a][b] = PackedVector3Array([pa, pb])
		if not feathered:
			_link_mesh.surface_set_color(color)
			_link_mesh.surface_add_vertex(pa)
			_link_mesh.surface_add_vertex(pb)
			continue
		var width := VaultGraphModel.edge_width(
			int(edge.get("weight", edge.get("count", 1))), _max_count
		) * clampf(sqrt(upp), 0.6, 1.6)
		var side := right * (width * upp * 0.5)
		var mid := (pa + pb) * 0.5
		var end_color := Color(color, LINK_END_ALPHA)
		var a_left := pa - side
		var a_right := pa + side
		var m_left := mid - side
		var m_right := mid + side
		var b_left := pb - side
		var b_right := pb + side
		_link_mesh.surface_set_color(end_color)
		_link_mesh.surface_add_vertex(a_left)
		_link_mesh.surface_set_color(end_color)
		_link_mesh.surface_add_vertex(a_right)
		_link_mesh.surface_set_color(color)
		_link_mesh.surface_add_vertex(m_right)
		_link_mesh.surface_set_color(end_color)
		_link_mesh.surface_add_vertex(a_left)
		_link_mesh.surface_set_color(color)
		_link_mesh.surface_add_vertex(m_right)
		_link_mesh.surface_set_color(color)
		_link_mesh.surface_add_vertex(m_left)
		_link_mesh.surface_set_color(color)
		_link_mesh.surface_add_vertex(m_left)
		_link_mesh.surface_set_color(color)
		_link_mesh.surface_add_vertex(m_right)
		_link_mesh.surface_set_color(end_color)
		_link_mesh.surface_add_vertex(b_right)
		_link_mesh.surface_set_color(color)
		_link_mesh.surface_add_vertex(m_left)
		_link_mesh.surface_set_color(end_color)
		_link_mesh.surface_add_vertex(b_right)
		_link_mesh.surface_set_color(end_color)
		_link_mesh.surface_add_vertex(b_left)
	if added:
		_link_mesh.surface_end()
	last_link_build_us = Time.get_ticks_usec() - started
	_last_link_ms = Time.get_ticks_msec()


func link_segment(a: String, b: String) -> PackedVector3Array:
	if _link_ends.has(a) and (_link_ends[a] as Dictionary).has(b):
		return (_link_ends[a] as Dictionary)[b]
	if _link_ends.has(b) and (_link_ends[b] as Dictionary).has(a):
		return (_link_ends[b] as Dictionary)[a]
	return PackedVector3Array()


func _measure_label_block() -> float:
	var font := get_theme_default_font()
	if font == null:
		return 0.0
	var widest := 0.0
	for node in nodes:
		if not (node is Dictionary):
			continue
		var text := str(node.get("label", node.get("id", "")))
		widest = maxf(widest, font.get_string_size(
			text, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FONT_SIZE).x + LABEL_GAP)
	return minf(widest, MAX_LABEL_BLOCK)


func label_placements() -> Array:
	if nodes.is_empty():
		return []
	var font := get_theme_default_font()
	if font == null:
		return []
	var screens := _screen_positions()
	var ppu := _pixels_per_unit()
	var labels_all := ppu >= LABEL_MIN_PPU and nodes.size() <= MAX_ALWAYS_LABELS
	var view := Rect2(Vector2.ZERO, size)
	var palette := UiPalette.active()
	var cursor := cursor_hit() if has_focus() else ""
	var candidates: Array = []
	for node in nodes:
		if not (node is Dictionary):
			continue
		var id := str(node.get("id", ""))
		if not screens.has(id):
			continue
		var point: Vector2 = screens[id]
		if not view.grow(12.0).has_point(point):
			continue
		var ghost := bool(node.get("ghost", false))
		var degrees: Dictionary = _degrees.get(id, {})
		var degree := int(degrees.get("in", 0)) + int(degrees.get("out", 0))
		var radius := _node_screen_radius(id)
		var rank := 3
		if id == cursor:
			rank = 0
		elif id == hovered_id:
			rank = 1
		elif id == selected_id:
			rank = 2
		if not labels_all and rank == 3:
			continue
		var text := str(node.get("label", id))
		var color := palette.TEXT
		if ghost:
			color = Color(palette.TEXT, 0.75)
		elif id == selected_id:
			color = palette.ACCENT
		var width := font.get_string_size(
			text, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FONT_SIZE).x
		var baseline := point.y + LABEL_FONT_SIZE * 0.35
		candidates.append({
			"rank": rank,
			"degree": degree,
			"id": id,
			"text": text,
			"rect": Rect2(
				Vector2(point.x + radius + LABEL_GAP, baseline - LABEL_FONT_SIZE),
				Vector2(width, LABEL_FONT_SIZE + 2.0)
			),
			"color": color,
		})
	candidates.sort_custom(func(a, b):
		if a["rank"] != b["rank"]:
			return a["rank"] < b["rank"]
		if a["degree"] != b["degree"]:
			return a["degree"] > b["degree"]
		return a["id"] < b["id"]
	)
	var rects: Array = []
	for candidate in candidates:
		rects.append(candidate["rect"])
	var keep := VaultGraphModel.cull_labels(rects, view)
	var out: Array = []
	for i in keep:
		out.append(candidates[i])
	return out


# ═══════════════════════════════════════════════════════════════════════
# Drawing
# ═══════════════════════════════════════════════════════════════════════

func _draw_overlay(canvas: Control) -> void:
	var view_size := canvas.size
	if _vignette != null:
		var alpha := VIGNETTE_DARK if SettingsManager.is_dark_appearance() else VIGNETTE_LIGHT
		canvas.draw_texture_rect(
			_vignette, Rect2(Vector2.ZERO, view_size), false, Color(1, 1, 1, alpha)
		)
	var font := get_theme_default_font()
	if nodes.is_empty():
		if font != null:
			var text := "No notes to graph."
			var width := font.get_string_size(
				text, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FONT_SIZE).x
			canvas.draw_string(
				font,
				(view_size - Vector2(width, 0.0)) * 0.5,
				text,
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				LABEL_FONT_SIZE,
				Color(UiPalette.active().TEXT, 0.6)
			)
		_draw_focus_frame(canvas)
		return
	if font == null:
		return
	var screens := _screen_positions()
	var palette := UiPalette.active()
	var cursor := cursor_hit() if has_focus() else ""
	for node in nodes:
		if not (node is Dictionary):
			continue
		var id := str(node.get("id", ""))
		if not screens.has(id):
			continue
		var point: Vector2 = screens[id]
		var radius := _node_screen_radius(id)
		if id == hovered_id:
			canvas.draw_arc(point, radius + 2.0, 0.0, TAU, 24, Color(palette.TEXT, 0.5), 1.0, true)
		if id == selected_id:
			canvas.draw_arc(point, radius + 3.5, 0.0, TAU, 28, palette.ACCENT, 2.0, true)
		if id == cursor:
			canvas.draw_arc(point, radius + 5.5, 0.0, TAU, 32, Color(palette.ACCENT, 0.9), 1.5, true)
	if show_arrows:
		var view := Rect2(Vector2.ZERO, view_size)
		for edge in edges:
			if not (edge is Dictionary):
				continue
			var a := str(edge.get("a", ""))
			var b := str(edge.get("b", ""))
			if not screens.has(a) or not screens.has(b):
				continue
			var pa: Vector2 = screens[a]
			var pb: Vector2 = screens[b]
			if not _segment_visible(pa, pb, view):
				continue
			var related := selected_id != "" and (a == selected_id or b == selected_id)
			var color := Color(palette.ACCENT, 0.85) if related else Color(palette.TEXT, 0.28)
			if int(edge.get("ab", 0)) > 0:
				_arrowhead(canvas, pa, pb, color, 1.0)
			if int(edge.get("ba", 0)) > 0:
				_arrowhead(canvas, pb, pa, color, 1.0)
	for placement in label_placements():
		var rect: Rect2 = placement["rect"]
		canvas.draw_string(
			font,
			Vector2(rect.position.x, rect.position.y + LABEL_FONT_SIZE),
			str(placement["text"]),
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			LABEL_FONT_SIZE,
			placement["color"]
		)
	if has_focus():
		var mid := view_size * 0.5
		var ink := Color(palette.ACCENT, 0.9)
		canvas.draw_line(mid - Vector2(CURSOR_ARM, 0.0), mid + Vector2(CURSOR_ARM, 0.0), ink, 1.5, true)
		canvas.draw_line(mid - Vector2(0.0, CURSOR_ARM), mid + Vector2(0.0, CURSOR_ARM), ink, 1.5, true)
	_draw_focus_frame(canvas)


func _draw_focus_frame(canvas: Control) -> void:
	if has_focus():
		canvas.draw_rect(
			Rect2(Vector2(1, 1), canvas.size - Vector2(2, 2)),
			UiPalette.active().ACCENT, false, 2.0
		)


func _segment_visible(a: Vector2, b: Vector2, view: Rect2) -> bool:
	if (a.x < view.position.x and b.x < view.position.x) \
		or (a.x > view.end.x and b.x > view.end.x) \
		or (a.y < view.position.y and b.y < view.position.y) \
		or (a.y > view.end.y and b.y > view.end.y):
		return false
	return true


func _arrowhead(canvas: CanvasItem, tail: Vector2, tip: Vector2, color: Color, width: float) -> void:
	var direction := tip - tail
	if direction.length() < 0.001:
		return
	direction = direction.normalized()
	var side := Vector2(-direction.y, direction.x)
	var back := tip - direction * (6.0 + width * 2.0)
	canvas.draw_line(tip, back + side * 3.0, color, width, true)
	canvas.draw_line(tip, back - side * 3.0, color, width, true)


# ═══════════════════════════════════════════════════════════════════════
# Status, accessibility and lifecycle
# ═══════════════════════════════════════════════════════════════════════

func _recompute_weight_scale() -> void:
	_max_count = 1
	for edge in edges:
		if edge is Dictionary:
			_max_count = maxi(_max_count, int(edge.get("weight", edge.get("count", 1))))


func _update_status() -> void:
	if _status == null:
		return
	if nodes.is_empty():
		_status.text = "No notes to graph."
		return
	var notes := 0
	var ghosts := 0
	for node in nodes:
		if node is Dictionary and bool(node.get("ghost", false)):
			ghosts += 1
		else:
			notes += 1
	var declared := 0
	for edge in edges:
		if edge is Dictionary and int(edge.get("declared", 0)) > 0:
			declared += 1
	var text := "%d notes · %d links" % [notes, edges.size()]
	if ghosts > 0:
		text += " · %d missing" % ghosts
	if declared > 0:
		text += " · %d declared" % declared
	if _truncated:
		text += " · truncated"
	text += " · 3D"
	if selected_id != "":
		text += " · %s" % _label_for(selected_id)
	_status.text = text


func _announce_cursor() -> void:
	var hit := cursor_hit()
	if hit == _a11y_cursor:
		return
	_a11y_cursor = hit
	if hit == "":
		A11y.publish(_a11y_host, A11y.LIVE_NAME, "Cursor: none", A11y.LIVE_POLITE)
		return
	var degrees: Dictionary = _degrees.get(hit, {})
	var degree := int(degrees.get("in", 0)) + int(degrees.get("out", 0))
	A11y.publish(_a11y_host, A11y.LIVE_NAME,
		"Cursor: %s, %d links" % [_label_for(hit), degree], A11y.LIVE_POLITE)


func _fit_if_needed() -> void:
	if not _needs_fit or size.x < 16.0 or size.y < 16.0:
		return
	_needs_fit = false
	fit_to_view()


func _request_render() -> void:
	if _viewport == null:
		return
	if not is_visible_in_tree() or _hidden_paused:
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	elif _settled:
		_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	else:
		_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_RESIZED:
			_screen_dirty = true
			_fit_if_needed()
			if _overlay != null:
				_overlay.queue_redraw()
			_request_render()
		NOTIFICATION_VISIBILITY_CHANGED:
			if _viewport == null:
				return
			if is_visible_in_tree():
				if _settled:
					_request_render()
				else:
					_begin_motion()
			else:
				_pause_for_hidden()
		NOTIFICATION_THEME_CHANGED:
			_apply_theme()


func _build_dust() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = DUST_SEED
	_dust_positions.clear()
	_dust_speeds.clear()
	_dust_scales.clear()
	for i in DUST_COUNT:
		_dust_positions.append(Vector3(
			rng.randf_range(-DUST_BOX_X, DUST_BOX_X),
			rng.randf_range(-DUST_BOX_Y, DUST_BOX_Y),
			rng.randf_range(-DEPTH_SPREAD * 2.0, DEPTH_SPREAD * 2.0)
		))
		_dust_speeds.append(rng.randf_range(6.0, 18.0))
		_dust_scales.append(rng.randf_range(1.2, 3.0))
	_dust_mesh.multimesh.instance_count = DUST_COUNT
	for i in DUST_COUNT:
		_dust_mesh.multimesh.set_instance_transform(
			i, Transform3D(Basis.from_scale(Vector3.ONE * _dust_scales[i]), _dust_positions[i])
		)
	_update_dust_colors()


func _update_dust_colors() -> void:
	if _dust_mesh == null:
		return
	var color := Color(UiPalette.active().TEXT, DUST_ALPHA)
	for i in _dust_mesh.multimesh.instance_count:
		_dust_mesh.multimesh.set_instance_color(i, color)


# ── Read-only diagnostics (tests and the bench) ────────────────────────

func is_settled() -> bool:
	return _settled


func simulation_ticks() -> int:
	return _ticks


func max_speed() -> float:
	var fastest := 0.0
	for id in _bodies:
		var body: RigidBody3D = _bodies[id]
		if is_instance_valid(body):
			fastest = maxf(fastest, body.linear_velocity.length())
	return fastest


func camera_angles() -> Vector2:
	return Vector2(_yaw, _pitch)


class _GraphOverlay extends Control:
	var host = null

	func _draw() -> void:
		if host != null:
			host._draw_overlay(self)
