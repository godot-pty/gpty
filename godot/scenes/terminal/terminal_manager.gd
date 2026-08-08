extends RefCounted
class_name TerminalManager
# godopty Terminal Manager — owns tile lifecycle and pane building.
# Now supports any PaneBody type via spawn_pane().

const GRID = 12
const MIN_TILE = 2
const TITLE_BAR_HEIGHT = 26
const BUTTON_MIN_WIDTH = 22
const BUTTON_MIN_HEIGHT = 18

const _PaneScripts := {
	"terminal":    preload("res://scenes/terminal/terminal_pane.gd"),
	"code_viewer": preload("res://scenes/panes/code_viewer.gd"),
	"file_tree":   preload("res://scenes/panes/file_tree.gd"),
	"observer":    preload("res://scenes/panes/observer_pane.gd"),
}

var on_close: Callable  # set by workspace to refresh layout after kill
var on_swap: Callable    # set by workspace to handle pane type swap

var tiles: Array[Dictionary] = []
var last_body: Control
signal tiles_resized
var _pane_counters: Dictionary = {}  # type_name -> next int

var _pane_settings_panel  # set by workspace

# ── Public spawn API ───────────────────────────────────────────────────

func spawn(shell := "") -> Control:
	var s = shell if shell != "" else SettingsManager.cfg_shell_command
	return spawn_pane("terminal", {
		"shell_command": s,
		"rows": SettingsManager.cfg_default_rows,
		"cols": SettingsManager.cfg_default_cols,
	})

func spawn_bulk(count: int, shell := "") -> Array[Control]:
	var spawned: Array[Control] = []
	var s = shell if shell != "" else SettingsManager.cfg_shell_command
	for i in count:
		var body = spawn_pane("terminal", {
			"shell_command": s,
			"rows": SettingsManager.cfg_default_rows,
			"cols": SettingsManager.cfg_default_cols,
		})
		if body == null: break
		spawned.append(body)
	return spawned

func spawn_pane(type_name: String, opts: Dictionary = {}) -> Control:
	var script = _PaneScripts.get(type_name)
	if script == null:
		push_error("Unknown pane type: " + type_name)
		return null

	var body: Control = script.new()
	body.name = "Body"
	body.pane_label = _next_label(type_name)
	body.apply_settings(opts)

	var title = opts.get("title_label", PaneTypes.ALL.get(type_name, {}).get("name", type_name))
	var w = _build_wrapper_body(body, title)

	if tiles.is_empty():
		tiles.append({wrapper = w, col = 0, row = 0, cspan = GRID, rspan = GRID})
	else:
		if not _split_for(w):
			w.queue_free()
			return null

	# For terminal panes, apply global defaults and wire dynamic title
	if type_name == "terminal":
		if body.has_method("_terminal"):
			SettingsManager.apply_to_terminal(body)
			var s = opts.get("shell_command", SettingsManager.cfg_shell_command)
			body.shell_command = s if s != "" else SettingsManager.cfg_shell_command
		body.title_changed.connect(func(t: String):
			var lbl = w.get_node_or_null("BodyVBox/TitleBar/TitleLabel")
			if lbl: lbl.text = " " + t
		)

	return body

# Create a pane body without auto-split (used by restore/activate)
func create_body(type_name: String) -> Control:
	var script = _PaneScripts.get(type_name)
	if script == null:
		push_error("Unknown pane type: " + type_name)
		return null
	var body: Control = script.new()
	body.name = "Body"
	body.pane_label = _next_label(type_name)
	return body

func _next_label(type_name: String) -> String:
	var count = _pane_counters.get(type_name, 0) + 1
	_pane_counters[type_name] = count
	var prefix = PaneTypes.ALL.get(type_name, {}).get("label_prefix", "?")
	return "%s%d" % [prefix, count]

# ── Legacy wrapper builder (for backward compat during transition) ─────

func build_wrapper(shell: String, rows: int, cols: int) -> Control:
	var body: Control = _PaneScripts["terminal"].new()
	body.name = "Body"
	body.rows = rows
	body.cols = cols

	var title = shell.get_file() if shell else "terminal"
	var w = _build_wrapper_body(body, title)

	SettingsManager.apply_to_terminal(body)
	body.shell_command = shell if shell != "" else SettingsManager.cfg_shell_command

	body.title_changed.connect(func(t: String):
		var lbl = w.get_node_or_null("BodyVBox/TitleBar/TitleLabel")
		if lbl: lbl.text = " " + t
	)
	return w

# ── Wrapper shell builder (shared across all pane types) ───────────────

func _build_wrapper_body(body: Control, title: String) -> Control:
	var root = PanelContainer.new()
	var sb = StyleBoxFlat.new()
	sb.bg_color = SettingsManager.cfg_wrapper_bg
	sb.border_width_left = 1; sb.border_width_right = 1
	sb.border_width_top = 1; sb.border_width_bottom = 1
	sb.border_color = SettingsManager.cfg_wrapper_border
	root.add_theme_stylebox_override("panel", sb)

	var vbox = _make_vbox()
	root.add_child(vbox)

	_add_title_bar(vbox, title, root)

	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(body)

	root.gui_input.connect(func(event: InputEvent): _on_tile_edge_drag(event, root))
	return root

func _make_vbox() -> VBoxContainer:
	var v = VBoxContainer.new()
	v.name = "BodyVBox"
	v.add_theme_constant_override("separation", 0)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return v

func _add_title_bar(parent: VBoxContainer, title: String, root: Control) -> Label:
	var bar = Control.new()
	bar.name = "TitleBar"
	bar.custom_minimum_size = Vector2(0, TITLE_BAR_HEIGHT)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.mouse_filter = Control.MOUSE_FILTER_STOP
	parent.add_child(bar)

	var tbg = ColorRect.new()
	tbg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tbg.color = SettingsManager.cfg_title_bar_bg
	bar.add_child(tbg)
	tbg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var lbl = Label.new()
	lbl.name = "TitleLabel"
	lbl.text = " " + title
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	bar.add_child(lbl)
	lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


	var btn_hbox = HBoxContainer.new()
	btn_hbox.add_theme_constant_override("separation", 2)
	btn_hbox.anchor_left = 1.0; btn_hbox.anchor_right = 1.0
	btn_hbox.anchor_top = 0.0; btn_hbox.anchor_bottom = 1.0
	var btn_total = 5 * BUTTON_MIN_WIDTH + 12
	btn_hbox.offset_left = -btn_total
	btn_hbox.offset_right = -2
	bar.add_child(btn_hbox)

	var min_btn = Button.new()
	min_btn.text = Icons.MINIMIZE; min_btn.focus_mode = Control.FOCUS_NONE
	Icons.style_button(min_btn)
	min_btn.custom_minimum_size = Vector2(BUTTON_MIN_WIDTH, BUTTON_MIN_HEIGHT)
	min_btn.pressed.connect(func(): _toggle_minimize(root, min_btn))
	btn_hbox.add_child(min_btn)

	var pos_swap_btn = Button.new()
	pos_swap_btn.text = Icons.POSITION_SWAP; pos_swap_btn.focus_mode = Control.FOCUS_NONE
	Icons.style_button(pos_swap_btn)
	pos_swap_btn.custom_minimum_size = Vector2(BUTTON_MIN_WIDTH, BUTTON_MIN_HEIGHT)
	pos_swap_btn.tooltip_text = "Swap position with another pane"
	pos_swap_btn.pressed.connect(func():
		var b = _find_body(root)
		if b:
			_show_swap_popup(b, bar, pos_swap_btn.get_screen_position() + Vector2(0, pos_swap_btn.size.y))
	)
	btn_hbox.add_child(pos_swap_btn)

	var swap_btn = Button.new()
	swap_btn.text = Icons.SWAP; swap_btn.focus_mode = Control.FOCUS_NONE
	Icons.style_button(swap_btn)
	swap_btn.custom_minimum_size = Vector2(BUTTON_MIN_WIDTH, BUTTON_MIN_HEIGHT)
	# PopupMenu listing all pane types
	var swap_menu = PopupMenu.new()
	swap_menu.name = "SwapMenu"
	for key in PaneTypes.ALL:
		swap_menu.add_item(PaneTypes.ALL[key]["name"])
		swap_menu.set_item_metadata(swap_menu.item_count - 1, key)
	swap_menu.index_pressed.connect(func(idx: int):
		var type_name = swap_menu.get_item_metadata(idx)
		_handle_swap(_find_body(root), type_name, swap_menu)
	)
	swap_btn.pressed.connect(func():
		swap_menu.position = swap_btn.get_screen_position() + Vector2(0, swap_btn.size.y)
		swap_menu.reset_size()
		swap_menu.popup()
	)
	btn_hbox.add_child(swap_btn)
	# PopupMenu must be a child of root to receive input
	root.add_child(swap_menu)

	var settings_btn = Button.new()
	settings_btn.text = Icons.SETTINGS; settings_btn.focus_mode = Control.FOCUS_NONE
	Icons.style_button(settings_btn)
	settings_btn.custom_minimum_size = Vector2(BUTTON_MIN_WIDTH, BUTTON_MIN_HEIGHT)
	settings_btn.pressed.connect(func(): _open_pane_settings(_find_body(root)))
	btn_hbox.add_child(settings_btn)

	var close_btn = Button.new()
	close_btn.text = Icons.CLOSE; close_btn.focus_mode = Control.FOCUS_NONE
	Icons.style_button(close_btn)
	close_btn.custom_minimum_size = Vector2(BUTTON_MIN_WIDTH, BUTTON_MIN_HEIGHT)
	close_btn.pressed.connect(func(): _handle_close(_find_body(root)))
	btn_hbox.add_child(close_btn)

	return lbl

# ── Lifecycle ──────────────────────────────────────────────────────────

func kill(body: Control):
	if last_body == body: last_body = null
	var wi = -1
	for i in tiles.size():
		if _find_body(tiles[i].wrapper) == body: wi = i; break
	if wi == -1: return
	var rm = tiles[wi]
	tiles.remove_at(wi)
	if not _expand_exact(rm):
		_expand_partial(rm)
	rm.wrapper.queue_free()

func kill_last():
	if last_body: kill(last_body)


func swap_pane(body: Control, new_type_name: String) -> Control:
	# Find the tile owning this body.
	var ti = -1
	for i in tiles.size():
		if _find_body(tiles[i].wrapper) == body: ti = i; break
	if ti == -1:
		push_error("swap_pane: body not found in tiles")
		return null

	var tile = tiles[ti]
	var old_wrapper = tile.wrapper

	# Create a new body of the swapped-to type.
	var new_body = create_body(new_type_name)
	if new_body == null:
		push_error("swap_pane: unknown type '%s'" % new_type_name)
		return null
	new_body.name = "Body"

	# Copy compatible settings from the old body to the new one.
	if body.has_method("_get_layout_state"):
		var state = body._get_layout_state()
		new_body.apply_settings(state)

	# Build a new wrapper with the new type's display title.
	var title = PaneTypes.ALL.get(new_type_name, {}).get("name", new_type_name)
	var new_wrapper = _build_wrapper_body(new_body, title)

	# Replace the wrapper in the tile — grid position (col/row/cspan/rspan) is unchanged.
	tile.wrapper = new_wrapper

	# Clean up the old wrapper and its body.
	old_wrapper.queue_free()

	if last_body == body:
		last_body = new_body

	return new_body
func reset():
	for t in tiles: t.wrapper.queue_free()
	tiles.clear()
	last_body = null
	_pane_counters.clear()

# ── Tiling ─────────────────────────────────────────────────────────────

func _split_for(w: Control) -> bool:
	var bi = 0; var ba = 0
	for i in tiles.size():
		var a = tiles[i].cspan * tiles[i].rspan
		if a > ba: ba = a; bi = i
	var s = tiles[bi]
	var oc = s.col; var or1 = s.row; var os = s.cspan; var ot = s.rspan
	if os >= ot:
		var half = maxi(os / 2, 1)
		if half < MIN_TILE or (os - half) < MIN_TILE: return false
		s.cspan = half
		tiles.append({wrapper = w, col = oc + half, row = or1, cspan = os - half, rspan = ot})
	else:
		var half = maxi(ot / 2, 1)
		if half < MIN_TILE or (ot - half) < MIN_TILE: return false
		s.rspan = half
		tiles.append({wrapper = w, col = oc, row = or1 + half, cspan = os, rspan = ot - half})
	return true

func _expand_exact(rm: Dictionary) -> bool:
	for t in tiles:
		if t.row == rm.row and t.rspan == rm.rspan:
			if t.col + t.cspan == rm.col: t.cspan += rm.cspan; return true
			if rm.col + rm.cspan == t.col: t.col = rm.col; t.cspan += rm.cspan; return true
		if t.col == rm.col and t.cspan == rm.cspan:
			if t.row + t.rspan == rm.row: t.rspan += rm.rspan; return true
			if rm.row + rm.rspan == t.row: t.row = rm.row; t.rspan += rm.rspan; return true
	return false

func _expand_partial(rm: Dictionary):
	var left = []; var right = []; var up = []; var down = []
	for t in tiles:
		if t.col + t.cspan == rm.col: left.append(t)
		if rm.col + rm.cspan == t.col: right.append(t)
		if t.row + t.rspan == rm.row: up.append(t)
		if rm.row + rm.rspan == t.row: down.append(t)
	if left.size() > 0 or right.size() > 0:
		var new_right = rm.col + rm.cspan
		for t in left: t.cspan = new_right - t.col
		for t in right: t.cspan = (t.col + t.cspan) - rm.col; t.col = rm.col
		return
	if up.size() > 0 or down.size() > 0:
		var new_bottom = rm.row + rm.rspan
		for t in up: t.rspan = new_bottom - t.row
		for t in down: t.rspan = (t.row + t.rspan) - rm.row; t.row = rm.row
		return
	if tiles.size() > 0:
		tiles[0].col = 0; tiles[0].row = 0
		tiles[0].cspan = GRID; tiles[0].rspan = GRID

# ── Helpers ────────────────────────────────────────────────────────────

func _find_body(w: Control) -> Control:
	return w.get_node_or_null("BodyVBox/Body")

func _toggle_minimize(w: Control, btn: Button):
	var body = _find_body(w)
	if body:
		body.visible = not body.visible
		btn.text = Icons.MINIMIZE if body.visible else Icons.RESTORE

func _handle_close(body: Control):
	if on_close.is_valid():
		on_close.call(body)

func _open_pane_settings(body: Control):
	if _pane_settings_panel == null:
		_pane_settings_panel = load("res://scenes/ui/pane_settings_panel.gd").new()
	_pane_settings_panel.open_for(body)



func _show_swap_popup(body: Control, bar: Control, pos: Vector2):
	var this_ti = -1
	for i in tiles.size():
		if _find_body(tiles[i].wrapper) == body: this_ti = i; break
	if this_ti == -1: return

	var menu = PopupMenu.new()
	menu.name = "SwapTargetMenu"
	for i in tiles.size():
		if i == this_ti: continue
		var other = _find_body(tiles[i].wrapper)
		if other == null: continue
		var label = other.get("pane_label")
		if label == null or label == "":
			var type_name = other._pane_type() if other.has_method("_pane_type") else "?"
			label = PaneTypes.ALL.get(type_name, {}).get("name", type_name)
		menu.add_item(String(label))
		menu.set_item_metadata(menu.item_count - 1, i)
	menu.index_pressed.connect(func(idx: int):
		var other_ti = menu.get_item_metadata(idx)
		_swap_tile_positions(this_ti, other_ti)
		tiles_resized.emit()
		menu.queue_free()
	)
	# Menu must be added to root so it can receive input
	var root = bar.get_parent().get_parent()  # BodyVBox -> PanelContainer
	if root is PanelContainer:
		root.add_child(menu)
	menu.position = pos
	menu.reset_size()
	menu.popup()
	menu.popup_hide.connect(menu.queue_free)

func _swap_tile_positions(a: int, b: int):
	var ta = tiles[a]
	var tb = tiles[b]
	var tmp = {"col": ta.col, "row": ta.row, "cspan": ta.cspan, "rspan": ta.rspan}
	ta.col = tb.col; ta.row = tb.row; ta.cspan = tb.cspan; ta.rspan = tb.rspan
	tb.col = tmp.col; tb.row = tmp.row; tb.cspan = tmp.cspan; tb.rspan = tmp.rspan
func _handle_swap(body: Control, new_type_name: String, _menu: PopupMenu):
	if on_swap.is_valid():
		on_swap.call(body, new_type_name)


# ── Edge Drag Resize ───────────────────────────────────────────────────

var _drag_edge: String = ""
var _drag_wrapper: Control = null

const EDGE_THRESHOLD = 4

func _on_tile_edge_drag(event: InputEvent, wrapper: Control):
	if event is InputEventMouseMotion and _drag_edge == "":
		var e = _edge_at(wrapper, event.position)
		if e != "":
			match e:
				"left", "right": DisplayServer.cursor_set_shape(DisplayServer.CURSOR_HSIZE)
				"top", "bottom": DisplayServer.cursor_set_shape(DisplayServer.CURSOR_VSIZE)
		else:
			DisplayServer.cursor_set_shape(DisplayServer.CURSOR_ARROW)
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			var e = _edge_at(wrapper, event.position)
			if e != "":
				_drag_edge = e
				_drag_wrapper = wrapper
				_drag_start_pos = event.global_position
				_save_drag_initial_sizes()
		elif event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			if _drag_edge != "":
				_drag_edge = ""
				_drag_wrapper = null
				DisplayServer.cursor_set_shape(DisplayServer.CURSOR_ARROW)
				tiles_resized.emit()
	elif event is InputEventMouseMotion and _drag_edge != "":
		var delta = event.global_position - _drag_start_pos
		_resize_tile(_drag_wrapper, _drag_edge, delta)
		_drag_start_pos = event.global_position

var _drag_start_pos: Vector2
var _drag_saved_sizes: Dictionary = {}

func _save_drag_initial_sizes():
	_drag_saved_sizes.clear()
	for i in tiles.size():
		var t = tiles[i]
		_drag_saved_sizes[t.wrapper] = {"col": t.col, "row": t.row, "cspan": t.cspan, "rspan": t.rspan}

func _edge_at(wrapper: Control, pos: Vector2) -> String:
	var s = wrapper.size
	if pos.x <= EDGE_THRESHOLD: return "left"
	if pos.x >= s.x - EDGE_THRESHOLD: return "right"
	if pos.y <= EDGE_THRESHOLD: return "top"
	if pos.y >= s.y - EDGE_THRESHOLD: return "bottom"
	return ""

func _resize_tile(wrapper: Control, edge: String, delta: Vector2):
	var ti = -1
	for i in tiles.size():
		if tiles[i].wrapper == wrapper: ti = i; break
	if ti == -1: return

	var t = tiles[ti]
	var saved = _drag_saved_sizes.get(wrapper, {})
	if saved.is_empty(): return

	# Reset both tiles to saved positions before applying delta
	t.col = saved.get("col", t.col)
	t.row = saved.get("row", t.row)
	t.cspan = saved.get("cspan", t.cspan)
	t.rspan = saved.get("rspan", t.rspan)

	match edge:
		"left":
			var adj = _adjacent_left(t)
			if adj == null: return
			# Reset adjacent too
			var adj_saved = _drag_saved_sizes.get(adj.wrapper, {})
			if adj_saved.is_empty(): return
			adj.col = adj_saved.get("col", adj.col)
			adj.cspan = adj_saved.get("cspan", adj.cspan)
			# Compute delta in grid units (approximate)
			var total_w = maxf(wrapper.size.x, 1.0)
			var grid_px = total_w / float(maxi(t.cspan + adj.cspan, 1))
			var dg = int(round(delta.x / grid_px))
			if dg >= 0: return  # dragging left edge left means shrinking self
			dg = maxi(dg, -(t.cspan - MIN_TILE))  # don't push past MIN_TILE on self
			dg = mini(dg, adj.cspan - MIN_TILE)   # don't push past MIN_TILE on adj
			if dg == 0: return
			t.col += dg
			t.cspan -= dg
			adj.cspan += dg
		"right":
			var adj = _adjacent_right(t)
			if adj == null: return
			var adj_saved = _drag_saved_sizes.get(adj.wrapper, {})
			if adj_saved.is_empty(): return
			adj.col = adj_saved.get("col", adj.col)
			adj.cspan = adj_saved.get("cspan", adj.cspan)
			var total_w = maxf(wrapper.size.x, 1.0)
			var grid_px = total_w / float(maxi(t.cspan + adj.cspan, 1))
			var dg = int(round(delta.x / grid_px))
			if dg <= 0: return  # dragging right edge right means growing self
			dg = mini(dg, GRID - t.col - t.cspan)  # don't go past grid
			dg = mini(dg, adj.cspan - MIN_TILE)    # don't push past MIN_TILE on adj
			if dg == 0: return
			t.cspan += dg
			adj.col += dg
			adj.cspan -= dg
		"top":
			var adj = _adjacent_above(t)
			if adj == null: return
			var adj_saved = _drag_saved_sizes.get(adj.wrapper, {})
			if adj_saved.is_empty(): return
			adj.row = adj_saved.get("row", adj.row)
			adj.rspan = adj_saved.get("rspan", adj.rspan)
			var total_h = maxf(wrapper.size.y, 1.0)
			var grid_px = total_h / float(maxi(t.rspan + adj.rspan, 1))
			var dg = int(round(delta.y / grid_px))
			if dg >= 0: return
			dg = maxi(dg, -(t.rspan - MIN_TILE))
			dg = mini(dg, adj.rspan - MIN_TILE)
			if dg == 0: return
			t.row += dg
			t.rspan -= dg
			adj.rspan += dg
		"bottom":
			var adj = _adjacent_below(t)
			if adj == null: return
			var adj_saved = _drag_saved_sizes.get(adj.wrapper, {})
			if adj_saved.is_empty(): return
			adj.row = adj_saved.get("row", adj.row)
			adj.rspan = adj_saved.get("rspan", adj.rspan)
			var total_h = maxf(wrapper.size.y, 1.0)
			var grid_px = total_h / float(maxi(t.rspan + adj.rspan, 1))
			var dg = int(round(delta.y / grid_px))
			if dg <= 0: return
			dg = mini(dg, GRID - t.row - t.rspan)
			dg = mini(dg, adj.rspan - MIN_TILE)
			if dg == 0: return
			t.rspan += dg
			adj.row += dg
			adj.rspan -= dg

func _adjacent_left(t: Dictionary):
	for o in tiles:
		if o == t: continue
		if o.col + o.cspan == t.col and o.row == t.row and o.rspan == t.rspan:
			return o
	return null

func _adjacent_right(t: Dictionary):
	for o in tiles:
		if o == t: continue
		if o.col == t.col + t.cspan and o.row == t.row and o.rspan == t.rspan:
			return o
	return null

func _adjacent_above(t: Dictionary):
	for o in tiles:
		if o == t: continue
		if o.row + o.rspan == t.row and o.col == t.col and o.cspan == t.cspan:
			return o
	return null

func _adjacent_below(t: Dictionary):
	for o in tiles:
		if o == t: continue
		if o.row == t.row + t.rspan and o.col == t.col and o.cspan == t.cspan:
			return o
	return null