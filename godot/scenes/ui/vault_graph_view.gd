class_name VaultGraphView
extends Control
## The wiki pane's link graph canvas.
##
## A custom-drawn `Control`, not a `GraphEdit` of node controls: the walk caps
## a vault at 2000 notes, and one Godot node (plus a connection, plus a label)
## per note is where that renderer stops being the right one. This draws the
## whole graph with `draw_line`/`draw_circle`/`draw_string` and culls what is
## off screen, so the cost follows what is visible.
##
## All logic that can be tested without a renderer lives in
## [VaultGraphModel] — parsing, pair aggregation, damped weights, the
## deterministic layout and hit-testing. This class owns only presentation
## state: the session's node geometry (so a drag survives a re-query), the
## pan/zoom transform, hover/selection, and the input gestures.
##
## The graph is generated, never stored: [method show_graph] takes one
## normalized answer from the index and a mutation simply re-queries and calls
## it again. Nothing here writes to the vault.

## A note node was clicked. `id` is the vault-relative path the index uses.
signal node_activated(id: String)
## An unresolved-target node was clicked. `target` is the `[[…]]` target with
## its synthetic node prefix removed; the pane decides what an unresolved
## mention means (it is the same rule the preview's mention click applies).
signal ghost_activated(target: String)

const ZOOM_MIN := 0.06
const ZOOM_MAX := 4.0
const ZOOM_STEP := 1.15
## Fraction of the view kept as padding when fitting.
const FIT_PADDING := 0.08
## Screen pixels of pointer travel before a press counts as a drag rather than
## a click. Godot delivers motion in small steps, so this is measured from the
## press, not per event.
const DRAG_THRESHOLD := 4.0
## The click radius around a node, in screen pixels.
const HIT_RADIUS := 11.0
## Labels are drawn for every node only while the graph is both zoomed in
## enough to read them and small enough that they do not become a wall of
## text; the hovered and selected nodes always get one.
const LABEL_ZOOM := 0.55
const MAX_ALWAYS_LABELS := 120
## A dragged node may not be moved past this world box (roughly the layout box
## and a generous margin), so it cannot be lost off-canvas by accident.
const DRAG_BOUND := 4000.0

var nodes: Array = []
var edges: Array = []
## Session geometry: id -> [Vector2] in the model's world space. Kept across
## re-queries so dragging a node lasts as long as the pane does; the model
## only places ids that are not here.
var positions: Dictionary = {}
var selected_id := ""
var hovered_id := ""
var show_arrows := false

var _zoom := 1.0
var _pan := Vector2.ZERO
var _panning := false
var _drag_id := ""
var _drag_offset := Vector2.ZERO
var _press_screen := Vector2.ZERO
var _moved := false
var _needs_fit := true
var _truncated := false
var _max_count := 1
var _max_degree := 1
var _degrees: Dictionary = {}
var _status: Label
var _hint: Label
var _relayout_button: Button
var _fit_button: Button
var _arrows_button: Button


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_chrome()
	set_process_unhandled_key_input(false)


## Install one normalized graph answer ([method VaultGraphModel.parse]'s
## result), keeping any node geometry this view already holds.
##
## `current_id` is the note the pane has open (highlighted when it is still in
## the graph). The first call fits the graph to the view; later calls keep the
## user's pan/zoom, because a re-query is often the same graph with one note
## added.
func show_graph(data: Dictionary, current_id := "") -> void:
	nodes = data.get("nodes", []) if data.get("nodes") is Array else []
	edges = data.get("edges", []) if data.get("edges") is Array else []
	_truncated = bool(data.get("truncated", false))
	var first_show := positions.is_empty()
	var previous := positions
	positions = VaultGraphModel.layout(nodes, edges, previous)
	_degrees = VaultGraphModel.degrees(edges)
	_max_degree = 1
	for id in _degrees:
		_max_degree = maxi(_max_degree, int(_degrees[id]["in"]) + int(_degrees[id]["out"]))
	_max_count = 1
	for edge in edges:
		_max_count = maxi(_max_count, int(edge.get("count", 1)))
	if current_id != "" and _has_node(current_id):
		selected_id = current_id
	elif selected_id != "" and not _has_node(selected_id):
		selected_id = ""
	_needs_fit = first_show
	_update_status()
	queue_redraw()
	if first_show:
		call_deferred("_fit_if_needed")


## Highlight one node without opening it (the pane passes its open note).
func set_selected(id: String) -> void:
	var next := id if _has_node(id) else ""
	if next == selected_id:
		return
	selected_id = next
	_update_status()
	queue_redraw()


## Recompute the deterministic layout, discarding every drag in this session.
func relayout() -> void:
	positions = VaultGraphModel.layout(nodes, edges, {})
	_needs_fit = true
	_update_status()
	queue_redraw()
	call_deferred("_fit_if_needed")


## Scale and centre the graph in the view.
func fit_to_view() -> void:
	var box := VaultGraphModel.bounds(positions)
	if box.size.x <= 0.0 or box.size.y <= 0.0 or size.x < 2.0 or size.y < 2.0:
		return
	var usable := Vector2(size) * (1.0 - 2.0 * FIT_PADDING)
	var scale := minf(usable.x / maxf(box.size.x, 0.001), usable.y / maxf(box.size.y, 0.001))
	_zoom = clampf(scale, ZOOM_MIN, ZOOM_MAX)
	_pan = size * 0.5 - box.get_center() * _zoom
	queue_redraw()


## Zoom about a screen point, keeping the world point under the cursor fixed.
func zoom_at(screen_point: Vector2, factor: float) -> void:
	var before := to_world(screen_point)
	_zoom = clampf(_zoom * factor, ZOOM_MIN, ZOOM_MAX)
	_pan = screen_point - before * _zoom
	queue_redraw()


## Screen point -> world point.
func to_world(screen_point: Vector2) -> Vector2:
	return (screen_point - _pan) / _zoom


## World point -> screen point.
func to_screen(world_point: Vector2) -> Vector2:
	return world_point * _zoom + _pan


func _build_chrome() -> void:
	_status = Label.new()
	_status.name = "GraphStatus"
	_status.add_theme_font_size_override("font_size", 11)
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
	controls.offset_left = -236
	controls.offset_right = -8
	controls.offset_top = 4
	controls.offset_bottom = 28
	controls.alignment = BoxContainer.ALIGNMENT_END
	# The container spans the top-right strip; only its buttons should take
	# clicks, or the empty pixels beside them would swallow a pan/drag.
	controls.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(controls)

	_arrows_button = _make_button("Arrows", "Draw edge direction (mutual pairs both ways)")
	_arrows_button.toggle_mode = true
	_arrows_button.toggled.connect(func(on: bool):
		show_arrows = on
		queue_redraw()
	)
	controls.add_child(_arrows_button)

	_relayout_button = _make_button("Relayout", "Run the deterministic layout again")
	_relayout_button.pressed.connect(relayout)
	controls.add_child(_relayout_button)

	_fit_button = _make_button("Fit", "Fit the whole graph in the view")
	_fit_button.pressed.connect(fit_to_view)
	controls.add_child(_fit_button)

	_hint = Label.new()
	_hint.name = "GraphHint"
	_hint.text = "Drag to pan · Wheel to zoom · Drag a node to move it · Click a note to open it"
	_hint.add_theme_font_size_override("font_size", 10)
	_hint.modulate = Color(1, 1, 1, 0.55)
	_hint.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_hint.offset_left = 8
	_hint.offset_top = -20
	_hint.offset_right = 720
	_hint.offset_bottom = -4
	_hint.grow_horizontal = Control.GROW_DIRECTION_END
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_hint)


func _make_button(text: String, tooltip: String) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.tooltip_text = tooltip
	button.add_theme_font_size_override("font_size", 11)
	return button


func _has_node(id: String) -> bool:
	for node in nodes:
		if node is Dictionary and str(node.get("id", "")) == id:
			return true
	return false


func _update_status() -> void:
	if _status == null:
		return
	var notes := 0
	var ghosts := 0
	for node in nodes:
		if node is Dictionary and bool(node.get("ghost", false)):
			ghosts += 1
		else:
			notes += 1
	var text := "%d notes · %d links" % [notes, edges.size()]
	if ghosts > 0:
		text += " · %d missing" % ghosts
	if _truncated:
		text += " · truncated"
	if selected_id != "":
		for node in nodes:
			if node is Dictionary and str(node.get("id", "")) == selected_id:
				text += " · %s" % str(node.get("label", selected_id))
				break
	_status.text = text


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_fit_if_needed()
		queue_redraw()
	elif what == NOTIFICATION_VISIBILITY_CHANGED and is_visible_in_tree():
		_fit_if_needed()


func _fit_if_needed() -> void:
	if not _needs_fit or size.x < 16.0 or size.y < 16.0:
		return
	_needs_fit = false
	fit_to_view()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			zoom_at(event.position, ZOOM_STEP)
			accept_event()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			zoom_at(event.position, 1.0 / ZOOM_STEP)
			accept_event()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_begin_press(event.position)
			else:
				_end_press(event.position)
			accept_event()
		elif event.button_index == MOUSE_BUTTON_MIDDLE:
			if event.pressed:
				_panning = true
				_press_screen = event.position
				_moved = false
			else:
				_panning = false
			accept_event()
	elif event is InputEventMouseMotion:
		if _panning:
			_pan += event.relative
			if event.position.distance_to(_press_screen) > DRAG_THRESHOLD:
				_moved = true
			queue_redraw()
		elif _drag_id != "":
			var world := to_world(event.position) - _drag_offset
			positions[_drag_id] = Vector2(
				clampf(world.x, -DRAG_BOUND, DRAG_BOUND),
				clampf(world.y, -DRAG_BOUND, DRAG_BOUND)
			)
			if event.position.distance_to(_press_screen) > DRAG_THRESHOLD:
				_moved = true
			queue_redraw()
		else:
			_hover(event.position)


func _begin_press(screen_point: Vector2) -> void:
	_press_screen = screen_point
	_moved = false
	var hit := VaultGraphModel.hit_test(
		nodes, positions, to_world(screen_point), HIT_RADIUS / _zoom
	)
	if hit == "":
		_drag_id = ""
		_panning = true
		return
	_drag_id = hit
	_drag_offset = to_world(screen_point) - (positions[hit] as Vector2)
	_panning = false


func _end_press(screen_point: Vector2) -> void:
	var dragged := _drag_id
	var moved := _moved
	var panning := _panning
	_drag_id = ""
	_panning = false
	if dragged != "" and not moved:
		# A click, not a drag: the node is the action. The pane decides what
		# an unresolved target means — the same resolution the preview uses.
		if dragged.begins_with("ghost:"):
			ghost_activated.emit(dragged.trim_prefix("ghost:"))
		else:
			node_activated.emit(dragged)
	elif panning and not moved:
		_hover(screen_point)


func _hover(screen_point: Vector2) -> void:
	var hit := VaultGraphModel.hit_test(
		nodes, positions, to_world(screen_point), HIT_RADIUS / _zoom
	)
	if hit == hovered_id:
		return
	hovered_id = hit
	mouse_default_cursor_shape = (
		Control.CURSOR_POINTING_HAND if hit != "" else Control.CURSOR_DRAG
	)
	queue_redraw()


# ── Drawing ────────────────────────────────────────────────────────────

func _draw() -> void:
	if nodes.is_empty():
		_draw_empty()
		return
	var view := Rect2(Vector2.ZERO, size)
	var text_color := get_theme_color("font_color", "Label")
	var accent := Palette.ACCENT_COLOR
	var edge_color := Color(text_color, 0.28)
	var selected_edge := Color(accent, 0.85)
	var labels_all := _zoom >= LABEL_ZOOM and nodes.size() <= MAX_ALWAYS_LABELS
	var font := get_theme_default_font()
	# A fixed, small label size: the graph is a map, not a text view, and the
	# default theme's 16 px turns a dense vault into a wall of words.
	var font_size := 11
	if font == null:
		return
	for edge in edges:
		if not (edge is Dictionary):
			continue
		var a := str(edge.get("a", ""))
		var b := str(edge.get("b", ""))
		if not positions.has(a) or not positions.has(b):
			continue
		var pa := to_screen(positions[a] as Vector2)
		var pb := to_screen(positions[b] as Vector2)
		if not _segment_visible(pa, pb, view):
			continue
		var related := selected_id != "" and (a == selected_id or b == selected_id)
		var color := selected_edge if related else edge_color
		var width := VaultGraphModel.edge_width(int(edge.get("count", 1)), _max_count)
		width *= clampf(sqrt(_zoom), 0.6, 1.6)
		draw_line(pa, pb, color, width, true)
		if show_arrows:
			if int(edge.get("ab", 0)) > 0:
				_arrowhead(pa, pb, color, width)
			if int(edge.get("ba", 0)) > 0:
				_arrowhead(pb, pa, color, width)
	for node in nodes:
		if not (node is Dictionary):
			continue
		var id := str(node.get("id", ""))
		if not positions.has(id):
			continue
		var point := to_screen(positions[id] as Vector2)
		if not view.grow(12.0).has_point(point):
			continue
		var ghost := bool(node.get("ghost", false))
		var degree := int(_degrees.get(id, {}).get("in", 0)) + int(_degrees.get(id, {}).get("out", 0))
		var radius := VaultGraphModel.node_radius(degree, _max_degree) * _zoom
		radius = clampf(radius, 2.0, 22.0)
		if ghost:
			draw_arc(point, radius, 0.0, TAU, 20, Color(text_color, 0.6), 1.5, true)
			draw_arc(point, radius + 2.0, 0.0, TAU, 20, Color(text_color, 0.18), 1.0, true)
		else:
			var fill := Color(text_color, 0.75)
			if id == hovered_id:
				fill = Color(text_color, 0.95)
			draw_circle(point, radius, fill)
		if id == hovered_id:
			draw_arc(point, radius + 2.0, 0.0, TAU, 24, Color(text_color, 0.5), 1.0, true)
		if id == selected_id:
			draw_arc(point, radius + 3.5, 0.0, TAU, 28, accent, 2.0, true)
		if labels_all or id == hovered_id or id == selected_id:
			var label := str(node.get("label", id))
			var label_color := accent if id == selected_id else text_color
			if ghost:
				label_color = Color(text_color, 0.75)
			draw_string(
				font,
				point + Vector2(radius + 4.0, font_size * 0.35),
				label,
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				font_size,
				label_color
			)


func _draw_empty() -> void:
	var text := "No notes to graph."
	if _status != null:
		_status.text = text
	var font := get_theme_default_font()
	if font == null:
		return
	var font_size := 11
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	draw_string(
		font,
		(size - Vector2(width, 0.0)) * 0.5,
		text,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		font_size,
		Color(get_theme_color("font_color", "Label"), 0.6)
	)


## Cheap viewport cull: a segment is skipped only when both ends are outside
## on the same side, which never drops a line that crosses the view.
func _segment_visible(a: Vector2, b: Vector2, view: Rect2) -> bool:
	if (a.x < view.position.x and b.x < view.position.x) \
		or (a.x > view.end.x and b.x > view.end.x) \
		or (a.y < view.position.y and b.y < view.position.y) \
		or (a.y > view.end.y and b.y > view.end.y):
		return false
	return true


## A small double-line head at `tip`, pointing away from `tail`.
func _arrowhead(tail: Vector2, tip: Vector2, color: Color, width: float) -> void:
	var direction := (tip - tail)
	if direction.length() < 0.001:
		return
	direction = direction.normalized()
	var side := Vector2(-direction.y, direction.x)
	var back := tip - direction * (6.0 + width * 2.0)
	draw_line(tip, back + side * 3.0, color, width, true)
	draw_line(tip, back - side * 3.0, color, width, true)
