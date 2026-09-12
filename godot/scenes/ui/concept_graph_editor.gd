class_name ConceptGraphEditor
extends Control
## Visual concept-rule editor — a GraphEdit canvas over the concept store.
##
## Each rule is one chain: trigger → condition* → action. The canvas is stored
## as layout (positions) plus drafts (nodes outside a complete rule); the
## concept entries in `user://concepts.json` remain the single content store.
## [ConceptGraphModel] owns all of that logic; this class is the Godot UI:
## nodes, ports, field edits, connection gestures, save/close.
##
## Safety (same rule as the rest of the concept engine): a node can only ever
## describe a regex, a capture mode, stop conditions, or a routing target.
## There is no command field, no PTY write, and no action a trigger could
## invoke — the compiled entry's key set is closed by
## [method ConceptGraphModel.entry_for_path].

const RULE_HINT := "Each rule: trigger → conditions → action. Connect output ports to input ports. Rules run top to bottom — drag a rule to change its priority (the number on its title)."

var _graph: GraphEdit
var _status_label: Label
var _error_label: Label
var _save_button: Button

# Canvas state (source of truth while the editor is open).
var _nodes: Array = []
var _edges: Array = []
var _positions: Dictionary = {}
var _paths: Array = []
var _drafts: Array = []
var _errors: Array = []
var _node_names: Dictionary = {}
var _name_ids: Dictionary = {}
## Canvas node id → the 1-based rank the rule is tried at, and the order that
## produced it. Recomputed when the canvas is rebuilt and while a rule is
## dragged, so the titles never disagree with the order that will be saved.
var _ranks: Dictionary = {}
var _order_names: Array = []
var _frames: Array = []
var _defaults: Array = []
var _opened_default_names: Array = []
var _dirty := false
var _draft_serial := 0
var _node_serial := 0
var _debounce: Timer


func _ready():
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_ui()
	_debounce = Timer.new()
	_debounce.one_shot = true
	_debounce.wait_time = 0.25
	_debounce.timeout.connect(_revalidate)
	add_child(_debounce)
	visible = false


# ═══════════════════════════════════════════════════════════════════════
# UI construction
# ═══════════════════════════════════════════════════════════════════════

func _build_ui():
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	add_child(margin)

	var bg := Panel.new()
	bg.name = "GraphBg"
	margin.add_child(bg)

	var inner := MarginContainer.new()
	inner.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		inner.add_theme_constant_override("margin_" + side, 12)
	bg.add_child(inner)

	var v := VBoxContainer.new()
	v.name = "GraphLayout"
	v.add_theme_constant_override("separation", 6)
	inner.add_child(v)

	_add_header(v)
	_add_toolbar(v)

	_graph = GraphEdit.new()
	_graph.name = "Graph"
	_graph.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_graph.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_graph.show_grid = true
	_graph.snapping_enabled = true
	_graph.snapping_distance = 20
	_graph.right_disconnects = true
	# GraphEdit's floating chrome (zoom buttons, view menu, minimap toggle)
	# sits at the canvas origin in viewport space and covers the first node's
	# title at the default scroll offset; the toolbar's Fit button covers
	# arranging, and zoom is on ctrl+wheel.
	_graph.show_zoom_buttons = false
	_graph.show_zoom_label = false
	_graph.show_grid_buttons = false
	_graph.show_arrange_button = false
	_graph.show_minimap_button = false
	_graph.show_menu = false
	_graph.minimap_enabled = false
	_graph.connection_request.connect(_on_connection_request)
	_graph.disconnection_request.connect(_on_disconnection_request)
	_graph.delete_nodes_request.connect(_on_delete_nodes_request)
	_graph.popup_request.connect(_on_popup_request)
	# Panning scheme: middle-drag pans (Godot default); scroll pans too, so a
	# wheel over the canvas does not zoom past the nodes while editing.
	_graph.panning_scheme = GraphEdit.SCROLL_PANS
	v.add_child(_graph)

	_error_label = Label.new()
	_error_label.name = "GraphErrors"
	_error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_error_label.add_theme_font_size_override("font_size", 11)
	_error_label.add_theme_color_override("font_color", Color(1.0, 0.6, 0.5))
	_error_label.visible = false
	v.add_child(_error_label)

	var hint := Label.new()
	hint.text = RULE_HINT
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Color(0.6, 0.65, 0.7))
	v.add_child(hint)

func _add_header(v: VBoxContainer) -> void:
	var h := HBoxContainer.new()
	var title := Label.new()
	title.text = "Concept Graph"
	title.add_theme_font_size_override("font_size", 18)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(title)
	_status_label = Label.new()
	_status_label.name = "GraphStatus"
	_status_label.add_theme_font_size_override("font_size", 11)
	_status_label.add_theme_color_override("font_color", Color(0.7, 0.75, 0.8))
	h.add_child(_status_label)
	_save_button = Button.new()
	_save_button.text = "Save"
	_save_button.pressed.connect(_save)
	h.add_child(_save_button)
	var close_btn := Button.new()
	close_btn.text = Icons.CLOSE
	close_btn.flat = true
	Icons.style_button(close_btn)
	close_btn.tooltip_text = "Close (Esc)"
	close_btn.pressed.connect(close)
	h.add_child(close_btn)
	v.add_child(h)

func _add_toolbar(v: VBoxContainer) -> void:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	for entry in [["Add Trigger", "trigger"], ["Add Condition", "condition"], ["Add Action", "action"]]:
		var btn := Button.new()
		btn.text = entry[0]
		btn.pressed.connect(_add_node.bind(entry[1], Vector2.ZERO, false))
		h.add_child(btn)
	var delete_btn := Button.new()
	delete_btn.text = "Delete Selected"
	delete_btn.pressed.connect(_delete_selected)
	h.add_child(delete_btn)
	var fit_btn := Button.new()
	fit_btn.text = "Fit"
	fit_btn.tooltip_text = "Re-arrange nodes"
	fit_btn.pressed.connect(_arrange)
	h.add_child(fit_btn)
	v.add_child(h)

# ═══════════════════════════════════════════════════════════════════════
# Open / close
# ═══════════════════════════════════════════════════════════════════════

## Reload the canvas from ConceptManager (a manual-dialog edit or another
## session may have changed the entries) and show the editor.
func open() -> void:
	_load_from_manager()
	_rebuild_canvas_ui()
	_dirty = false
	_update_status()
	visible = true
	_graph.grab_focus()

## Save-on-close. A canvas with content errors would silently drop those
## rules to drafts, so it asks first; a clean canvas just saves.
func close() -> void:
	if not visible:
		return
	_sync_positions_from_nodes()
	var result := _analyze()
	if _dirty and result["errors"].size() > 0:
		_confirm_close_with_errors()
		return
	if _dirty:
		_save()
	visible = false

func _confirm_close_with_errors() -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "Concept Graph"
	dialog.dialog_text = (
		"%d rule(s) have problems (see the red line below).\n"
		% _errors.size()
		+ "They are kept as drafts so nothing you typed is lost, and they will not run."
	)
	dialog.ok_button_text = "Save anyway"
	dialog.cancel_button_text = "Keep editing"
	add_child(dialog)
	dialog.confirmed.connect(func():
		dialog.queue_free()
		_save()
		visible = false
	)
	dialog.canceled.connect(func(): dialog.queue_free())
	dialog.popup_centered()

func _unhandled_input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()

# ═══════════════════════════════════════════════════════════════════════
# Data flow
# ═══════════════════════════════════════════════════════════════════════

func _load_from_manager() -> void:
	_nodes = []
	_edges = []
	_positions = {}
	_defaults = ConceptManager._load_defaults()
	_opened_default_names = []
	for d in _defaults:
		if d is Dictionary:
			_opened_default_names.append(str(d.get("name", "")))
	var canvas := ConceptGraphModel.build_canvas(ConceptManager.get_concepts(), ConceptManager.get_graph_state())
	_nodes = canvas["nodes"]
	_edges = canvas["edges"]
	var positions: Dictionary = canvas["positions"]
	for id in positions:
		var p = positions[id]
		_positions[id] = Vector2(float(p[0]), float(p[1]))
	_draft_serial = 0
	for node in _nodes:
		var id := str(node["id"])
		if id.begins_with("draft:"):
			_draft_serial = maxi(_draft_serial, int(id.substr(6)))

func _analyze() -> Dictionary:
	var result := ConceptGraphModel.analyze(
		_nodes, _edges, _defaults, _opened_default_names, Callable(self, "_validate_pattern")
	)
	_paths = result["paths"]
	_drafts = result["drafts"]
	_errors = result["errors"]
	return result

## Engine-dialect regex validation. GDScript's RegEx is PCRE2 and accepts
## constructs the Rust engine rejects, so the editor must ask the engine.
func _validate_pattern(pattern: String) -> String:
	if not ClassDB.class_exists("GptyTerminal"):
		return ""
	return str(GptyTerminal.validate_regex(pattern))

func _save() -> void:
	_sync_positions_from_nodes()
	var result := _analyze()
	var graph_block := ConceptGraphModel.layout(result["paths"], _positions, result["drafts"])
	ConceptManager.save_state(result["concepts"], graph_block)
	_dirty = false
	_update_status()
	_update_error_display()
	ToastManager.info("Concept graph saved", 2.0, "Concept Graph")

func _revalidate() -> void:
	_analyze()
	if _refresh_ranks():
		_rewrite_titles()
	_refresh_frames()
	_update_error_display()

func _analyze_debounced() -> void:
	_debounce.start()

# ═══════════════════════════════════════════════════════════════════════
# Canvas UI
# ═══════════════════════════════════════════════════════════════════════

func _rebuild_canvas_ui() -> void:
	_sync_positions_from_nodes()
	_analyze()
	_refresh_ranks()
	_graph.clear_connections()
	# Only our own elements: GraphEdit owns internal children (the connection
	# layer, minimap container, popups) and removing those breaks the editor
	# with "connections_layer is missing".
	for child in _graph.get_children():
		if child is GraphElement:
			_graph.remove_child(child)
			child.queue_free()
	_node_names = {}
	_name_ids = {}
	_frames = []
	_create_frames()
	_create_nodes()
	_attach_frames()
	_update_error_display()

func _create_frames() -> void:
	for i in _paths.size():
		var path: Dictionary = _paths[i]
		var frame := GraphFrame.new()
		frame.name = "frame_%d" % i
		frame.title = str(path.get("name", "Rule"))
		frame.autoshrink_enabled = true
		frame.autoshrink_margin = 40
		frame.tint_color_enabled = true
		frame.tint_color = Color(0.45, 0.7, 1.0, 0.12)
		_graph.add_child(frame)
		_frames.append(frame)

func _attach_frames() -> void:
	for i in _paths.size():
		if i >= _frames.size():
			break
		var path: Dictionary = _paths[i]
		var ids: Dictionary = path.get("node_ids", {})
		var member_ids: Array = [str(ids.get("trigger", ""))]
		var condition_ids = ids.get("conditions", [])
		if condition_ids is Array:
			for cid in condition_ids:
				member_ids.append(str(cid))
		member_ids.append(str(ids.get("action", "")))
		for id in member_ids:
			if _node_names.has(id):
				_graph.attach_graph_element_to_frame(_node_names[id], _frames[i].name)

## Rank each rule by the canvas order and remember it, so a trigger's title can
## show where the rule sits in the order it will be tried in. Returns true when
## the order changed (the caller then rewrites the titles).
##
## Ranks are keyed by the canvas node id the paths carry, not by rule name: a
## rule renamed in the editor keeps its node ids until the next rebuild, and
## its rank must not blink out in the meantime.
func _refresh_ranks() -> bool:
	var names := ConceptGraphModel.rule_order(_paths, _positions)
	var changed := names != _order_names
	_order_names = names
	var trigger_id_by_name := {}
	for path in _paths:
		if path is Dictionary:
			var ids = path.get("node_ids", {})
			if ids is Dictionary:
				trigger_id_by_name[str(path.get("name", ""))] = str(ids.get("trigger", ""))
	_ranks = {}
	for i in names.size():
		var id := str(trigger_id_by_name.get(str(names[i]), ""))
		if id != "":
			_ranks[id] = i + 1
	return changed

func _rewrite_titles() -> void:
	for node in _nodes:
		var id := str(node["id"])
		if not _node_names.has(id):
			continue
		var gn := _graph.get_node_or_null(NodePath(_node_names[id]))
		if gn is GraphNode:
			gn.title = _title_for(node)

func _create_nodes() -> void:
	_node_serial = 0
	for node in _nodes:
		var id := str(node["id"])
		var node_name := "n%d" % _node_serial
		_node_serial += 1
		_node_names[id] = node_name
		_name_ids[node_name] = id
		var gn := _make_graph_node(node)
		gn.name = node_name
		gn.position_offset = _positions.get(id, Vector2.ZERO)
		_graph.add_child(gn)
	for edge in _edges:
		if edge is Array and edge.size() == 2:
			var from_name = _node_names.get(str(edge[0]))
			var to_name = _node_names.get(str(edge[1]))
			if from_name != null and to_name != null:
				_graph.connect_node(from_name, 0, to_name, 0)

func _make_graph_node(node: Dictionary) -> GraphNode:
	var kind := str(node["kind"])
	var gn := GraphNode.new()
	gn.resizable = false
	gn.custom_minimum_size = Vector2(340, 0)
	gn.title = _title_for(node)
	gn.set_meta("graph_id", str(node["id"]))
	var enable_left := kind != ConceptGraphModel.KIND_TRIGGER
	var enable_right := kind != ConceptGraphModel.KIND_ACTION
	var port_color := Color(0.55, 0.8, 1.0)
	if kind == ConceptGraphModel.KIND_CONDITION:
		port_color = Color(1.0, 0.8, 0.4)
	elif kind == ConceptGraphModel.KIND_ACTION:
		port_color = Color(0.6, 0.9, 0.6)
	gn.set_slot(0, enable_left, 0, port_color, enable_right, 0, port_color)
	gn.position_offset_changed.connect(func():
		_positions[str(node["id"])] = gn.position_offset
		_dirty = true
		# Moving a rule is a priority change, so the ranks follow the drag —
		# otherwise the titles would name the wrong rule as first.
		if _refresh_ranks():
			_rewrite_titles()
		_update_status()
	)
	var box := VBoxContainer.new()
	box.name = "Fields"
	box.position = Vector2(10, 38)
	box.custom_minimum_size = Vector2(320, 0)
	box.add_theme_constant_override("separation", 4)
	gn.add_child(box)
	match kind:
		ConceptGraphModel.KIND_TRIGGER:
			_add_trigger_fields(box, node)
		ConceptGraphModel.KIND_CONDITION:
			_add_condition_fields(box, node)
		ConceptGraphModel.KIND_ACTION:
			_add_action_fields(box, node)
	return gn

func _title_for(node: Dictionary) -> String:
	var params: Dictionary = node["params"]
	match str(node["kind"]):
		ConceptGraphModel.KIND_TRIGGER:
			var name := str(params.get("name", ""))
			var label := "Trigger - " + (name if name != "" else "(unnamed)")
			var rank := int(_ranks.get(str(node["id"]), 0))
			return ("%d. %s" % [rank, label]) if rank > 0 else label
		ConceptGraphModel.KIND_CONDITION:
			var pattern := str(params.get("pattern", ""))
			return "Condition - " + (pattern.substr(0, 40) if pattern != "" else "(empty)")
		_:
			if str(params.get("mode", ConceptGraphModel.MODE_CAPTURE)) == ConceptGraphModel.MODE_NOTIFY:
				return "Action - Notify only"
			return "Action - Capture → " + str(params.get("target", ""))

func _add_trigger_fields(box: VBoxContainer, node: Dictionary) -> void:
	var params: Dictionary = node["params"]
	var name_edit := LineEdit.new()
	name_edit.text = str(params.get("name", ""))
	name_edit.placeholder_text = "Rule name"
	name_edit.text_changed.connect(func(text: String):
		params["name"] = text
		_on_field_edited(node)
	)
	box.add_child(name_edit)
	var regex_edit := LineEdit.new()
	regex_edit.text = str(params.get("trigger", ""))
	regex_edit.placeholder_text = "Trigger regex, e.g. \\bcat\\s+\\S"
	regex_edit.text_changed.connect(func(text: String):
		params["trigger"] = text
		_on_field_edited(node)
	)
	box.add_child(regex_edit)
	var enabled := CheckButton.new()
	enabled.text = "Enabled"
	enabled.button_pressed = params.get("enabled", true) == true
	enabled.toggled.connect(func(on: bool):
		params["enabled"] = on
		_on_field_edited(node)
	)
	box.add_child(enabled)

func _add_condition_fields(box: VBoxContainer, node: Dictionary) -> void:
	var params: Dictionary = node["params"]
	var regex_edit := LineEdit.new()
	regex_edit.text = str(params.get("pattern", ""))
	regex_edit.placeholder_text = "Must also match the same line"
	regex_edit.text_changed.connect(func(text: String):
		params["pattern"] = text
		_on_field_edited(node)
	)
	box.add_child(regex_edit)

func _add_action_fields(box: VBoxContainer, node: Dictionary) -> void:
	var params: Dictionary = node["params"]
	var mode := OptionButton.new()
	mode.add_item("Capture & route")
	mode.add_item("Notify only")
	mode.selected = 1 if str(params.get("mode", ConceptGraphModel.MODE_CAPTURE)) == ConceptGraphModel.MODE_NOTIFY else 0
	box.add_child(mode)

	var target := OptionButton.new()
	var options: Array = PaneTypes.content_receivers()
	var current := str(params.get("target", ""))
	if current != "" and not options.has(current):
		# A hand-edited target stays selectable instead of being silently
		# rewritten to the first option on save.
		options.append(current)
	for option in options:
		target.add_item(str(PaneTypes.ALL.get(option, {}).get("name", option)))
		target.set_item_metadata(target.item_count - 1, option)
	var target_index := options.find(current)
	target.selected = target_index if target_index >= 0 else 0
	target.item_selected.connect(func(index: int):
		params["target"] = str(target.get_item_metadata(index))
		_on_field_edited(node)
	)
	var target_row := _labeled_row("Target:", target)
	box.add_child(target_row)

	var timeout := SpinBox.new()
	timeout.min_value = 50
	timeout.max_value = 600000
	timeout.step = 50
	timeout.value = int(params.get("stop_timeout_ms", 300))
	timeout.value_changed.connect(func(value: float):
		params["stop_timeout_ms"] = int(value)
		_on_field_edited(node)
	)
	var timeout_row := _labeled_row("Stop after (ms):", timeout)
	box.add_child(timeout_row)

	var stop_on_input := CheckButton.new()
	stop_on_input.text = "Stop on input"
	stop_on_input.button_pressed = params.get("stop_on_input", true) == true
	stop_on_input.toggled.connect(func(on: bool):
		params["stop_on_input"] = on
		_on_field_edited(node)
	)
	box.add_child(stop_on_input)

	var notify := mode.selected == 1
	target_row.visible = not notify
	timeout_row.visible = not notify
	stop_on_input.visible = not notify
	mode.item_selected.connect(func(index: int):
		params["mode"] = ConceptGraphModel.MODE_NOTIFY if index == 1 else ConceptGraphModel.MODE_CAPTURE
		target_row.visible = index == 0
		timeout_row.visible = index == 0
		stop_on_input.visible = index == 0
		_on_field_edited(node)
	)

func _labeled_row(label_text: String, control: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	label.add_theme_font_size_override("font_size", 11)
	label.custom_minimum_size = Vector2(96, 0)
	row.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	return row

func _on_field_edited(node: Dictionary) -> void:
	var id := str(node["id"])
	if _node_names.has(id):
		var gn := _graph.get_node_or_null(NodePath(_node_names[id]))
		if gn is GraphNode:
			gn.title = _title_for(node)
	_dirty = true
	_update_status()
	_analyze_debounced()

func _sync_positions_from_nodes() -> void:
	for id in _node_names:
		var gn := _graph.get_node_or_null(NodePath(_node_names[id]))
		if gn is GraphNode:
			_positions[id] = gn.position_offset

func _update_status() -> void:
	if _status_label == null:
		return
	_status_label.text = "Unsaved changes" if _dirty else "Saved"
	_save_button.disabled = not _dirty

func _update_error_display() -> void:
	if _error_label == null:
		return
	if _errors.is_empty():
		_error_label.visible = false
		_error_label.text = ""
		_error_label.tooltip_text = ""
	else:
		var messages: Array = []
		var lines: Array = []
		for error in _errors:
			var message := str(error.get("message", ""))
			messages.append(message)
			lines.append("• " + message)
		_error_label.text = "  ".join(messages.slice(0, 3))
		if messages.size() > 3:
			_error_label.text += "  (+%d more)" % (messages.size() - 3)
		_error_label.tooltip_text = "\n".join(lines)
		_error_label.visible = true
	# Tint nodes referenced by an error so the red line has a location.
	var error_ids := {}
	for error in _errors:
		for id in error.get("ids", []):
			error_ids[str(id)] = true
	for id in _node_names:
		var gn := _graph.get_node_or_null(NodePath(_node_names[id]))
		if gn is GraphNode:
			gn.self_modulate = Color(1.0, 0.7, 0.7) if error_ids.has(id) else Color.WHITE

func _refresh_frames() -> void:
	# A field edit can turn a compiled rule into a draft (invalid regex) but
	# cannot promote one — that needs a wire change, which rebuilds the canvas.
	# So frames only need their titles updated and stale ones hidden.
	for i in _frames.size():
		var frame = _frames[i]
		if not is_instance_valid(frame):
			continue
		if i < _paths.size():
			frame.title = str(_paths[i].get("name", "Rule"))
			frame.visible = true
		else:
			frame.visible = false

# ═══════════════════════════════════════════════════════════════════════
# Editing operations
# ═══════════════════════════════════════════════════════════════════════

func _on_connection_request(from_node: StringName, _from_port: int, to_node: StringName, _to_port: int) -> void:
	var from_id := str(_name_ids.get(str(from_node), ""))
	var to_id := str(_name_ids.get(str(to_node), ""))
	if from_id == "" or to_id == "":
		return
	var reason := ConceptGraphModel.can_connect(_nodes, _edges, from_id, to_id)
	if reason != "":
		ToastManager.warn(reason, 4.0, "Concept Graph")
		return
	_edges.append([from_id, to_id])
	_dirty = true
	_rebuild_canvas_ui()

func _on_disconnection_request(from_node: StringName, _from_port: int, to_node: StringName, _to_port: int) -> void:
	var from_id := str(_name_ids.get(str(from_node), ""))
	var to_id := str(_name_ids.get(str(to_node), ""))
	var kept: Array = []
	for edge in _edges:
		if not (edge is Array and edge.size() == 2 and str(edge[0]) == from_id and str(edge[1]) == to_id):
			kept.append(edge)
	_edges = kept
	_dirty = true
	_rebuild_canvas_ui()

func _on_delete_nodes_request(nodes: Array) -> void:
	var ids: Array = []
	for node_name in nodes:
		var id := str(_name_ids.get(str(node_name), ""))
		if id != "":
			ids.append(id)
	_request_delete(ids)

func _delete_selected() -> void:
	var ids: Array = []
	for child in _graph.get_children():
		if child is GraphNode and child.selected:
			ids.append(str(child.get_meta("graph_id", "")))
	if ids.is_empty():
		ToastManager.info("Select a node first", 2.0, "Concept Graph")
		return
	_request_delete(ids)

func _request_delete(ids: Array) -> void:
	if ids.is_empty():
		return
	var rule_names: Array = []
	for id in ids:
		for node in _nodes:
			if str(node["id"]) == str(id) and str(node["kind"]) == ConceptGraphModel.KIND_TRIGGER:
				var name := str(node["params"].get("name", ""))
				if name != "":
					rule_names.append(name)
	if rule_names.is_empty():
		_do_delete(ids)
		return
	var dialog := ConfirmationDialog.new()
	dialog.title = "Delete rule"
	dialog.dialog_text = "Delete %s? The rule is removed from the concepts file when you save." % ", ".join(PackedStringArray(rule_names))
	add_child(dialog)
	dialog.confirmed.connect(func():
		dialog.queue_free()
		_do_delete(ids)
	)
	dialog.canceled.connect(func(): dialog.queue_free())
	dialog.popup_centered()

func _do_delete(ids: Array) -> void:
	var removed := {}
	for id in ids:
		removed[str(id)] = true
	var kept_nodes: Array = []
	for node in _nodes:
		if not removed.has(str(node["id"])):
			kept_nodes.append(node)
		else:
			_positions.erase(str(node["id"]))
	_nodes = kept_nodes
	var kept_edges: Array = []
	for edge in _edges:
		if edge is Array and edge.size() == 2 and not (removed.has(str(edge[0])) or removed.has(str(edge[1]))):
			kept_edges.append(edge)
	_edges = kept_edges
	_dirty = true
	_rebuild_canvas_ui()

## Add a node. The toolbar buttons spawn at the canvas centre; the context
## menu spawns at the click.
func _add_node(kind: String, at: Vector2, at_click: bool = true) -> void:
	var position := at
	if not at_click:
		position = _graph_position_for(_graph.size * 0.5)
	var params := {}
	match kind:
		ConceptGraphModel.KIND_TRIGGER:
			params = {"name": _unique_rule_name(), "trigger": "", "enabled": true}
		ConceptGraphModel.KIND_CONDITION:
			params = {"pattern": ""}
		_:
			var receivers := PaneTypes.content_receivers()
			params = {
				"mode": ConceptGraphModel.MODE_CAPTURE,
				"target": str(receivers[0]) if receivers.size() > 0 else "",
				"stop_timeout_ms": 300,
				"stop_on_input": true,
			}
	var id := _next_draft_id()
	_nodes.append({"id": id, "kind": kind, "params": params})
	_positions[id] = position
	_dirty = true
	_rebuild_canvas_ui()

func _next_draft_id() -> String:
	_draft_serial += 1
	while _has_node_id("draft:%d" % _draft_serial):
		_draft_serial += 1
	return "draft:%d" % _draft_serial

func _has_node_id(id: String) -> bool:
	for node in _nodes:
		if str(node["id"]) == id:
			return true
	return false

func _unique_rule_name() -> String:
	var index := 1
	while true:
		var candidate := "rule_%d" % index
		var taken := false
		for node in _nodes:
			if str(node["kind"]) == ConceptGraphModel.KIND_TRIGGER and str(node["params"].get("name", "")) == candidate:
				taken = true
				break
		if not taken:
			return candidate
		index += 1
	return "rule_1"

func _on_popup_request(at_position: Vector2) -> void:
	var menu := PopupMenu.new()
	menu.add_item("Add Trigger", 0)
	menu.add_item("Add Condition", 1)
	menu.add_item("Add Action", 2)
	_graph.add_child(menu)
	menu.id_pressed.connect(func(id: int):
		menu.queue_free()
		_add_node([ConceptGraphModel.KIND_TRIGGER, ConceptGraphModel.KIND_CONDITION, ConceptGraphModel.KIND_ACTION][id], _graph_position_for(at_position))
	)
	menu.popup_hide.connect(func(): menu.queue_free())
	menu.popup_on_parent(Rect2i(Vector2i(at_position), Vector2i.ZERO))

## Tidy the canvas. Deliberately not `GraphEdit.arrange_nodes()`: that lays
## nodes out by connection shape, which would silently reshuffle the order the
## rules are tried in. Re-rowed in the order they already have, so this button
## is a tidy-up, never a reorder.
func _arrange() -> void:
	_sync_positions_from_nodes()
	# The model speaks file coordinates (arrays); the canvas speaks Vector2.
	var tidied := ConceptGraphModel.tidy_positions(_paths, _drafts, _positions)
	for id in _node_names:
		var gn := _graph.get_node_or_null(NodePath(_node_names[id]))
		if gn is GraphNode and tidied.has(id):
			var p = tidied[id]
			gn.position_offset = Vector2(float(p[0]), float(p[1]))
	_sync_positions_from_nodes()
	_dirty = true
	_update_status()

## GraphEdit space ← control-local point: graph positions are
## `(point - size/2) / zoom + scroll_offset`.
func _graph_position_for(local: Vector2) -> Vector2:
	if _graph.zoom <= 0.0:
		return Vector2.ZERO
	return (local - _graph.size * 0.5) / _graph.zoom + _graph.scroll_offset
