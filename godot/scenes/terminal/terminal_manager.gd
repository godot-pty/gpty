extends RefCounted
class_name TerminalManager
# gpty Terminal Manager — owns tile lifecycle and pane building.
# Now supports any PaneBody type via spawn_pane().

## The layout grid lives in PaneTypes: `PaneTypes.GRID`/`PaneTypes.MIN_TILE` are defined once
## there. One unit is the *commit* granularity — a divider drag previews in
## pixels and snaps to whole units on release, so the divider follows the
## pointer continuously while the tile model stays integer (60 units over a
## 1000 px pane: 12 was an 83 px jump, "resize is jarring").
## Saved layouts record the unit they were written in; `scale_layout` converts
## an older one.
const TITLE_BAR_HEIGHT = 26
const BUTTON_MIN_WIDTH = 22
const BUTTON_MIN_HEIGHT = 18

const _PaneScripts := {
	"terminal":    preload("res://scenes/terminal/terminal_pane.gd"),
	"code_viewer": preload("res://scenes/panes/code_viewer.gd"),
	"file_tree":   preload("res://scenes/panes/file_tree.gd"),
	"inspector":   preload("res://scenes/panes/inspector_pane.gd"),
	"reasoning":   preload("res://scenes/panes/reasoning_pane.gd"),
}

var on_close: Callable  # set by workspace to refresh layout after kill
var on_swap: Callable    # set by workspace to handle pane type swap
var on_open_pane_settings: Callable  # workspace closes conflicting overlays first

var tiles: Array[Dictionary] = []
var last_body: Control
signal tiles_resized


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
	# Global defaults first so explicit per-pane opts win.
	if type_name == "terminal" and body is TerminalPane:
		SettingsManager.apply_to_terminal(body)
	body.apply_settings(opts)

	var title = opts.get("title_label", PaneTypes.ALL.get(type_name, {}).get("name", type_name))
	var w = _build_wrapper_body(body, title)

	if tiles.is_empty():
		tiles.append({wrapper = w, col = 0, row = 0, cspan = PaneTypes.GRID, rspan = PaneTypes.GRID})
	else:
		if not _split_for(w):
			w.queue_free()
			return null
	_sync_edge_strips()

	# For terminal panes, resolve the shell override and wire dynamic title.
	if type_name == "terminal":
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
	var prefix = PaneTypes.ALL.get(type_name, {}).get("label_prefix", "?")
	# max(existing) + 1: closing the newest pane reuses its number, but a
	# middle gap is never filled — T1,T3 exist, the next pane is T4 (no
	# confusing reordering), while T1,T2 minus T2 yields T2 again.
	var highest := 0
	for t in tiles:
		var body = _find_body(t.wrapper)
		if body == null:
			continue
		var label: String = body.get("pane_label")
		if label != null and label.begins_with(prefix):
			highest = maxi(highest, label.substr(prefix.length()).to_int())
	return "%s%d" % [prefix, highest + 1]
# ── Legacy wrapper builder (for backward compat during transition) ─────

func build_wrapper(shell: String, rows: int, cols: int) -> Control:
	var body: Control = _PaneScripts["terminal"].new()
	body.name = "Body"
	body.rows = rows
	body.cols = cols

	var title = shell.get_file() if shell else "terminal"
	var w = _build_wrapper_body(body, title)

	SettingsManager.apply_to_terminal(body)
	body.ensure_attachment_id()
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

	# Edge strips: they must be the wrapper's topmost children, because Godot
	# picks the last sibling first and the pane body consumes every event over
	# it. They live in a plain Control of their own: a PanelContainer fits
	# *all* of its children into the content rect, so direct children would be
	# stretched over the whole pane and swallow every click.
	var edge_host := Control.new()
	edge_host.name = "EdgeHost"
	edge_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(edge_host)
	for edge in EDGE_EDGES:
		edge_host.add_child(_make_edge_strip(edge, root))
	return root

## Thickness of a pane's edge-drag strips.
##
## The pane body fills the wrapper, and a Control with `MOUSE_FILTER_STOP`
## consumes the events over it, so the wrapper's own `gui_input` only ever
## fired inside its 1 px stylebox border — a 4 px edge test was unreachable
## (landing within one pixel of the border and pressing without moving is not
## a gesture), and the imperative `cursor_set_shape` was overwritten by the
## body's default arrow cursor the moment the pointer entered it, which is
## why the resize cursor only flashed. The strips sit on top of the body, know
## their own edge, and carry the cursor shape as `mouse_default_cursor_shape`,
## which Godot applies on hover without any imperative call.
const EDGE_STRIP := 6
const EDGE_EDGES := ["left", "right", "top", "bottom"]

func _make_edge_strip(edge: String, root: Control) -> Control:
	var strip := Control.new()
	strip.name = "Edge" + edge.capitalize()
	strip.mouse_filter = Control.MOUSE_FILTER_STOP
	strip.mouse_default_cursor_shape = (
		Control.CURSOR_HSIZE if edge == "left" or edge == "right"
		else Control.CURSOR_VSIZE)
	strip.anchor_top = 0.0 if edge != "bottom" else 1.0
	strip.anchor_bottom = 1.0 if edge != "top" else 0.0
	strip.anchor_left = 0.0 if edge != "right" else 1.0
	strip.anchor_right = 1.0 if edge != "left" else 0.0
	match edge:
		"left": strip.offset_right = EDGE_STRIP
		"right": strip.offset_left = -EDGE_STRIP
		"top": strip.offset_bottom = EDGE_STRIP
		"bottom": strip.offset_top = -EDGE_STRIP
	strip.gui_input.connect(func(event: InputEvent): _on_edge_strip_input(event, root, edge))
	return strip

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
	bar.visible = SettingsManager.cfg_show_titlebar
	bar.custom_minimum_size = Vector2(0, TITLE_BAR_HEIGHT)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.mouse_filter = Control.MOUSE_FILTER_STOP
	parent.add_child(bar)

	var tbg = ColorRect.new()
	tbg.name = "TitleBarBg"
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

	# Agent-state badge (display only) — written by TerminalPane from the
	# tiered AgentState tracker; hidden while idle. Never a decision input.
	var state_badge = Label.new()
	state_badge.name = "StateBadge"
	state_badge.text = Icons.CHECK_CIRCLE
	state_badge.visible = false
	state_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	state_badge.add_theme_font_override("font", Icons.font_resource)
	state_badge.add_theme_font_size_override("font_size", 12)
	state_badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	state_badge.anchor_left = 0.0; state_badge.anchor_right = 0.0
	state_badge.anchor_top = 0.0; state_badge.anchor_bottom = 1.0
	state_badge.offset_left = 6; state_badge.offset_right = 24
	bar.add_child(state_badge)


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
	min_btn.tooltip_text = "Minimize / Restore"
	Icons.style_button(min_btn)
	min_btn.custom_minimum_size = Vector2(BUTTON_MIN_WIDTH, BUTTON_MIN_HEIGHT)
	min_btn.pressed.connect(func(): _toggle_minimize(root, min_btn))
	btn_hbox.add_child(min_btn)

	var pos_swap_btn = Button.new()
	pos_swap_btn.text = Icons.SWAP; pos_swap_btn.focus_mode = Control.FOCUS_NONE
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
	swap_btn.text = Icons.RESET; swap_btn.focus_mode = Control.FOCUS_NONE
	swap_btn.tooltip_text = "Change pane type"
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
	settings_btn.tooltip_text = "Pane settings"
	Icons.style_button(settings_btn)
	settings_btn.custom_minimum_size = Vector2(BUTTON_MIN_WIDTH, BUTTON_MIN_HEIGHT)
	settings_btn.pressed.connect(func(): _open_pane_settings(_find_body(root)))
	btn_hbox.add_child(settings_btn)

	var close_btn = Button.new()
	close_btn.text = Icons.CLOSE; close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.tooltip_text = "Close pane"
	Icons.style_button(close_btn)
	close_btn.custom_minimum_size = Vector2(BUTTON_MIN_WIDTH, BUTTON_MIN_HEIGHT)
	close_btn.pressed.connect(func(): _handle_close(_find_body(root)))
	btn_hbox.add_child(close_btn)

	return lbl

# ── Lifecycle ──────────────────────────────────────────────────────────

## Edge strips advertise a resize only when there is a divider to drag: with a
## single pane every edge is the grid's own border, and showing the resize
## cursor over an edge that cannot move is a lie the user will chase.
func _sync_edge_strips():
	var resizable := tiles.size() >= 2
	for t in tiles:
		var w: Control = t.wrapper
		for edge in EDGE_EDGES:
			var strip: Control = w.get_node_or_null("EdgeHost/Edge" + edge.capitalize())
			if strip == null: continue
			strip.mouse_filter = (
				Control.MOUSE_FILTER_STOP if resizable else Control.MOUSE_FILTER_IGNORE)
			strip.mouse_default_cursor_shape = (
				(Control.CURSOR_HSIZE if edge == "left" or edge == "right" else Control.CURSOR_VSIZE)
				if resizable else Control.CURSOR_ARROW)

func kill(body: Control):
	if last_body == body: last_body = null
	var wi := _tile_index_of(body)
	if wi == -1: return
	var rm = tiles[wi]
	tiles.remove_at(wi)
	if not _expand_exact(rm):
		_expand_partial(rm)
	rm.wrapper.queue_free()
	_sync_edge_strips()

func kill_last():
	if last_body: kill(last_body)


func swap_pane(body: Control, new_type_name: String) -> Control:
	# Find the tile owning this body.
	var ti := _tile_index_of(body)
	if ti == -1:
		push_error("swap_pane: body not found in tiles")
		return null

	var tile = tiles[ti]
	var old_wrapper = tile.wrapper

	# Create a new body of the swapped-to type.
	var new_body = create_body(new_type_name)
	if new_body == null:
		push_error("swap_pane: unknown type '%s'" % new_type_name)
	new_body.name = "Body"

	# Global defaults first so per-pane settings from the old body win.
	if new_type_name == "terminal" and new_body is TerminalPane:
		SettingsManager.apply_to_terminal(new_body)

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
	_sync_edge_strips()
	return new_body
func reset():
	for t in tiles: t.wrapper.queue_free()
	tiles.clear()
	last_body = null
	_sync_edge_strips()

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
		if half < PaneTypes.MIN_TILE or (os - half) < PaneTypes.MIN_TILE: return false
		s.cspan = half
		tiles.append({wrapper = w, col = oc + half, row = or1, cspan = os - half, rspan = ot})
	else:
		var half = maxi(ot / 2, 1)
		if half < PaneTypes.MIN_TILE or (ot - half) < PaneTypes.MIN_TILE: return false
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
		tiles[0].cspan = PaneTypes.GRID; tiles[0].rspan = PaneTypes.GRID

# ── Helpers ────────────────────────────────────────────────────────────

func _find_body(w: Control) -> Control:
	return w.get_node_or_null("BodyVBox/Body")

## Index of the tile whose wrapper owns `body`, or -1 when no tile does.
## Indices shift whenever a pane is added or removed, so a body must be
## re-found by identity rather than remembered by index.
func _tile_index_of(body: Variant) -> int:
	for i in tiles.size():
		if _find_body(tiles[i].wrapper) == body:
			return i
	return -1

## Index of the tile whose *wrapper* is `wrapper`, or -1. The edge-drag paths
## address tiles by wrapper (that is what the press carried), not by body —
## `_tile_index_of` resolves bodies and would never match a wrapper.
func _tile_index_for_wrapper(wrapper: Control) -> int:
	for i in tiles.size():
		if tiles[i].wrapper == wrapper:
			return i
	return -1

func _toggle_minimize(w: Control, btn: Button):
	var body = _find_body(w)
	if body:
		body.visible = not body.visible
		btn.text = Icons.MINIMIZE if body.visible else Icons.RESTORE

func _handle_close(body: Control):
	if on_close.is_valid():
		on_close.call(body)

func _open_pane_settings(body: Control):
	# The panel itself is owned by the workspace (shared across all
	# workspaces, one z-ordered overlay in the tree). Creating a fresh one
	# here would orphan it outside the tree — invisible and dead. The
	# workspace wires on_open_pane_settings to also close conflicting
	# overlays (global settings) before the popup opens.
	if _pane_settings_panel == null:
		push_warning("_open_pane_settings: no panel assigned by workspace")
		return
	if on_open_pane_settings.is_valid():
		on_open_pane_settings.call(body)
	else:
		_pane_settings_panel.open_for(body)



func _show_swap_popup(body: Control, bar: Control, pos: Vector2):
	var root = bar.get_parent().get_parent()  # BodyVBox -> PanelContainer
	if root is PanelContainer:
		show_position_swap_popup(body, root, pos)

func _swap_tile_positions(a: int, b: int):
	var ta = tiles[a]
	var tb = tiles[b]
	var tmp = {"col": ta.col, "row": ta.row, "cspan": ta.cspan, "rspan": ta.rspan}
	ta.col = tb.col; ta.row = tb.row; ta.cspan = tb.cspan; ta.rspan = tb.rspan
	tb.col = tmp.col; tb.row = tmp.row; tb.cspan = tmp.cspan; tb.rspan = tmp.rspan
func _handle_swap(body: Control, new_type_name: String, _menu: PopupMenu):
	if on_swap.is_valid():
		on_swap.call(body, new_type_name)


## Resolve a swap pair against the CURRENT tile list.
##
## A popup can stay open while the pane set changes under it (an IPC
## `killPane`, a workspace switch, another pane's close), so indices captured
## when it opened can point at a different pane or past the end. Both panes
## are re-found by identity and the swap is abandoned if either is gone.
## Takes Variants: the target may already be a freed instance by then.
func resolve_swap_pair(a: Variant, b: Variant) -> Vector2i:
	if not is_instance_valid(a) or not is_instance_valid(b):
		return Vector2i(-1, -1)
	var ia := _tile_index_of(a)
	var ib := _tile_index_of(b)
	if ia == -1 or ib == -1:
		return Vector2i(-1, -1)
	return Vector2i(ia, ib)

func show_position_swap_popup(for_body: Control, menu_parent: Control, at_pos: Vector2):
	var this_ti := _tile_index_of(for_body)
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
		# The pane itself, not its index: the row is resolved when it is
		# clicked, against whatever the tile list looks like by then.
		menu.set_item_metadata(menu.item_count - 1, other)
	menu.index_pressed.connect(func(idx: int):
		var target = menu.get_item_metadata(idx)
		var pair := resolve_swap_pair(for_body, target)
		menu.queue_free()
		if pair.x == -1 or pair.y == -1:
			# The pane set changed while the popup was open; swapping the
			# current occupants of those indices would swap the wrong pair.
			ToastManager.warn("Swap cancelled — that pane is no longer open")
			return
		_swap_tile_positions(pair.x, pair.y)
		tiles_resized.emit()
	)
	menu_parent.add_child(menu)
	menu.position = at_pos
	menu.reset_size()
	menu.popup()
	menu.popup_hide.connect(menu.queue_free)

func show_type_swap_popup(for_body: Control, menu_parent: Control, at_pos: Vector2):
	var menu = PopupMenu.new()
	menu.name = "SwapTypeMenu"
	for key in PaneTypes.ALL:
		menu.add_item(PaneTypes.ALL[key]["name"])
		menu.set_item_metadata(menu.item_count - 1, key)
	menu.index_pressed.connect(func(idx: int):
		var type_name = menu.get_item_metadata(idx)
		_handle_swap(for_body, type_name, menu)
	)
	menu_parent.add_child(menu)
	menu.position = at_pos
	menu.reset_size()
	menu.popup()
	menu.popup_hide.connect(menu.queue_free)

# ── Edge Drag Resize ───────────────────────────────────────────────────

var _drag_edge: String = ""
var _drag_wrapper: Control = null
var _drag_start_pos := Vector2.ZERO

## Pixel geometry of the divider line, captured at the press.
##
## The tile model is integer, so a drag previews in pixels and commits whole
## units on release. Everything the preview needs — which tiles sit on the
## line, their committed rects, one grid unit in pixels, the travel limits in
## units — is snapshotted before the first preview moves anything, because
## afterwards the wrappers no longer describe the committed layout.
var _drag_saved_sizes: Dictionary = {}
var _drag_before: Array = []
var _drag_after: Array = []
var _drag_rects: Dictionary = {}
var _drag_axis: String = "x"
var _drag_line: int = 0
var _drag_unit: float = 0.0
var _drag_lo: int = 0
var _drag_hi: int = 0
var _drag_preview_px: float = 0.0

## True while an edge drag owns the mouse.
func drag_active() -> bool:
	return _drag_edge != ""

## Start a resize drag. Called by an edge strip's press; the drag itself is
## driven by `drive_edge_drag` from raw input, because the motion that follows
## a press on the border immediately leaves the strip for the pane body.
##
## An edge on the window border has no tile on its far side, so it has nothing
## to move and must not become a drag: `_setup_drag_geometry` rejects it.
func begin_edge_drag(wrapper: Control, edge: String, at: Vector2):
	if tiles.size() < 2:
		# A single pane fills the grid; there is no divider to move. The strips
		# already show an arrow cursor in that state (see `_sync_edge_strips`),
		# this is the belt under those braces.
		return
	_save_drag_initial_sizes()
	if not _setup_drag_geometry(wrapper, edge):
		_drag_saved_sizes.clear()
		return
	_drag_edge = edge
	_drag_wrapper = wrapper
	_drag_start_pos = at
	_drag_preview_px = 0.0

## End the drag: snap the previewed pixel travel to whole grid units, apply it
## to the tile model, and relayout once. The commit is the only thing that
## moves a tile, so a drag emits `tiles_resized` exactly once (the consumer is
## `workspace._apply_layout`, which also restores the wrappers to the model).
func end_edge_drag():
	if _drag_edge == "":
		return
	_commit_edge_drag()
	_drag_edge = ""
	_drag_wrapper = null
	_drag_saved_sizes.clear()
	_drag_before = []
	_drag_after = []
	_drag_rects.clear()
	_drag_preview_px = 0.0
	tiles_resized.emit()

## Drive an in-flight drag from the workspace's raw `_input`: motion previews
## the divider in pixels, the button release commits it. Returns true when the
## event belonged to the drag, so the caller consumes it (the pane body must
## not also read the motion as a text selection).
func drive_edge_drag(event: InputEvent) -> bool:
	if _drag_edge == "":
		return false
	if event is InputEventMouseMotion:
		# Distance from the *press*, not from the previous motion event: the
		# preview is recomputed from the press-time rects on every event, so
		# the 1-3 px steps of real mouse motion cannot accumulate rounding and
		# a partially applied step cannot land on a fresh baseline.
		var delta: Vector2 = event.global_position - _drag_start_pos
		_preview_edge_drag(delta.x if _drag_axis == "x" else delta.y)
		return true
	if (
		event is InputEventMouseButton
		and event.button_index == MOUSE_BUTTON_LEFT
		and not event.pressed
	):
		end_edge_drag()
		return true
	return false

func _on_edge_strip_input(event: InputEvent, wrapper: Control, edge: String):
	if not (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT):
		return
	if event.pressed:
		begin_edge_drag(wrapper, edge, event.global_position)
	else:
		end_edge_drag()

func _save_drag_initial_sizes():
	_drag_saved_sizes.clear()
	for i in tiles.size():
		var t = tiles[i]
		_drag_saved_sizes[t.wrapper] = {"col": t.col, "row": t.row, "cspan": t.cspan, "rspan": t.rspan}

## Resolve the divider line the grabbed pane's `edge` sits on into everything
## the drag needs, from the state saved at the press.
##
## A divider is a *line*, not a pair: every tile on it moves when it moves, on
## both sides and across its whole length. Adjusting only the grabbed pane and
## whichever neighbour it matched left the other tiles on that line behind —
## visible as grey gaps (or overlaps) between panes — and made the result
## depend on which side of the divider the user happened to grab. Working from
## the line removes both problems: the operation is the same for either side.
##
## Returns false when no tile sits on the far side (an edge on the window
## border) or the geometry is degenerate, so such a press never starts a drag.
func _setup_drag_geometry(wrapper: Control, edge: String) -> bool:
	var ti := _tile_index_for_wrapper(wrapper)
	if ti == -1 or _drag_saved_sizes.get(wrapper, {}).is_empty():
		return false
	var t = tiles[ti]
	var horizontal := edge == "left" or edge == "right"
	var line := 0
	var unit := 0.0
	if horizontal:
		line = (t.col + t.cspan) if edge == "right" else t.col
		# One grid unit in pixels, from the grabbed pane's committed geometry.
		unit = maxf(wrapper.size.x, 1.0) / float(maxi(t.cspan, 1))
	else:
		line = (t.row + t.rspan) if edge == "bottom" else t.row
		unit = maxf(wrapper.size.y, 1.0) / float(maxi(t.rspan, 1))
	if unit <= 0.0:
		return false
	var sides := _tiles_on_divider(horizontal, line)
	if sides["before"].is_empty() or sides["after"].is_empty():
		return false
	# Travel limits in whole units — the same clamps the commit uses, so the
	# preview can never show a position the release would refuse: the line
	# stays inside the grid and no tile shrinks past MIN_TILE.
	var lo := -line
	var hi := PaneTypes.GRID - line
	for o in sides["before"]:
		var span: int = _saved_span(o, horizontal)
		lo = maxi(lo, PaneTypes.MIN_TILE - span)
	for o in sides["after"]:
		var span: int = _saved_span(o, horizontal)
		hi = mini(hi, span - PaneTypes.MIN_TILE)
	if lo > hi:
		return false
	_drag_axis = "x" if horizontal else "y"
	_drag_line = line
	_drag_unit = unit
	_drag_before = sides["before"]
	_drag_after = sides["after"]
	_drag_lo = lo
	_drag_hi = hi
	_drag_rects = {}
	for o in _drag_before + _drag_after:
		var w: Control = o.wrapper
		_drag_rects[w] = {
			"left": w.offset_left, "top": w.offset_top,
			"right": w.offset_right, "bottom": w.offset_bottom,
		}
	return true

## The tiles touching a divider line: `before` ends on it, `after` starts on
## it. Read from the spans saved at the press, recomputed per call so a tile
## that leaves mid-drag simply drops out of both sides.
func _tiles_on_divider(horizontal: bool, line: int) -> Dictionary:
	var before := []
	var after := []
	for o in tiles:
		var saved: Dictionary = _drag_saved_sizes.get(o.wrapper, {})
		if saved.is_empty():
			continue
		if horizontal:
			if int(saved.col) + int(saved.cspan) == line: before.append(o)
			if int(saved.col) == line: after.append(o)
		else:
			if int(saved.row) + int(saved.rspan) == line: before.append(o)
			if int(saved.row) == line: after.append(o)
	return {"before": before, "after": after}

func _saved_span(tile: Dictionary, horizontal: bool) -> int:
	var saved: Dictionary = _drag_saved_sizes.get(tile.wrapper, {})
	return int(saved.cspan) if horizontal else int(saved.rspan)

## Move the divider line in *pixels* without touching the tile model: this is
## the live preview, and the unit-snapped commit happens on release.
##
## The preview can sit up to half a unit away from where the release will put
## it; that is the trade for a divider that follows the pointer at pixel
## granularity (one unit is ~17 px on a 1000 px pane) and for not relaying out
## every pane on every motion event — the terminal content settles once, via
## the pane's own `RESIZE_DEBOUNCE`, after the release.
func _preview_edge_drag(delta_px: float):
	var clamped := clampf(delta_px, float(_drag_lo) * _drag_unit, float(_drag_hi) * _drag_unit)
	_drag_preview_px = clamped
	for o in _drag_before:
		var w: Control = o.wrapper
		if not is_instance_valid(w): continue
		var r: Dictionary = _drag_rects.get(w, {})
		if r.is_empty(): continue
		if _drag_axis == "x": w.offset_right = float(r["right"]) + clamped
		else: w.offset_bottom = float(r["bottom"]) + clamped
	for o in _drag_after:
		var w: Control = o.wrapper
		if not is_instance_valid(w): continue
		var r: Dictionary = _drag_rects.get(w, {})
		if r.is_empty(): continue
		if _drag_axis == "x": w.offset_left = float(r["left"]) + clamped
		else: w.offset_top = float(r["top"]) + clamped

## Apply the previewed travel to the tile model as whole units.
##
## Spans are rewound to the press-time values first: the preview never mutates
## them, so this is normally a no-op, but it is what makes the commit
## idempotent if anything else (a spawn, a kill, a restored layout) moved a
## tile while the button was held.
func _commit_edge_drag():
	if _drag_unit <= 0.0 or _drag_saved_sizes.is_empty():
		return
	for o in tiles:
		var saved: Dictionary = _drag_saved_sizes.get(o.wrapper, {})
		if saved.is_empty(): continue
		o.col = saved.get("col", o.col)
		o.row = saved.get("row", o.row)
		o.cspan = saved.get("cspan", o.cspan)
		o.rspan = saved.get("rspan", o.rspan)
	var step := clampi(int(round(_drag_preview_px / _drag_unit)), _drag_lo, _drag_hi)
	if step == 0:
		return
	var horizontal := _drag_axis == "x"
	var sides := _tiles_on_divider(horizontal, _drag_line)
	if sides["before"].is_empty() or sides["after"].is_empty():
		return
	if horizontal:
		for o in sides["before"]: o.cspan += step
		for o in sides["after"]:
			o.col += step
			o.cspan -= step
	else:
		for o in sides["before"]: o.rspan += step
		for o in sides["after"]:
			o.row += step
			o.rspan -= step

## Convert a saved layout written against a different grid unit to today's
## `PaneTypes.GRID`, so a restored pane keeps its share of the screen instead of a
## fraction of it (a 12-unit layout restored into a 60-unit grid would give a
## half-screen pane 6/60 of it). Colours, settings and ids are left alone;
## only geometry is scaled. Exact when the units divide (12 → 60 is ×5).
##
## `declared` wins when a payload carries an explicit unit. Otherwise it is
## inferred: a layout always tiles its whole grid, so the furthest edge among
## its tiles *is* the unit it was written in — which is how layouts saved by
## older builds (12) and by this one (60) are told apart with no format change.
static func scale_layout(tiles: Array, declared: int = 0) -> Array:
	var unit := declared
	if unit <= 0:
		for td in tiles:
			if not (td is Dictionary):
				continue
			unit = maxi(unit, int(td.get("col", 0)) + int(td.get("cspan", 0)))
			unit = maxi(unit, int(td.get("row", 0)) + int(td.get("rspan", 0)))
	if unit <= 0 or unit == PaneTypes.GRID:
		return tiles
	var factor := float(PaneTypes.GRID) / float(unit)
	var out := []
	for td in tiles:
		if not (td is Dictionary):
			continue
		var t: Dictionary = (td as Dictionary).duplicate(true)
		t["col"] = int(round(float(t.get("col", 0)) * factor))
		t["row"] = int(round(float(t.get("row", 0)) * factor))
		t["cspan"] = maxi(int(round(float(t.get("cspan", unit)) * factor)), 1)
		t["rspan"] = maxi(int(round(float(t.get("rspan", unit)) * factor)), 1)
		out.append(t)
	return out
