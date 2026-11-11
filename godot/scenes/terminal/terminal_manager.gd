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
## The divider drag over these units lives in tile_drag.gd.
const TITLE_BAR_HEIGHT = 26
## The title bar's button row, named so the chrome keyboard path can find it
## (`focus_title_bar`) and a test can name one button.
const TITLE_BAR_BUTTONS = "TitleBarButtons"

const _PaneScripts := {
	"terminal":    preload("res://scenes/terminal/terminal_pane.gd"),
	"code_viewer": preload("res://scenes/panes/code_viewer.gd"),
	"file_tree":   preload("res://scenes/panes/file_tree.gd"),
	"inspector":   preload("res://scenes/panes/inspector_pane.gd"),
	"reasoning":   preload("res://scenes/panes/reasoning_pane.gd"),
	"cli_view":    preload("res://scenes/panes/cli_view_pane.gd"),
	"wiki":        preload("res://scenes/panes/wiki_pane.gd"),
	"media":       preload("res://scenes/panes/media_pane.gd"),
}

## The three callbacks the workspace binds (bound methods, never lambdas that
## capture this manager - see `_wire_tm` in workspace.gd). `on_open_pane_settings`
## receives `(manager, body)` so the hook can reach this manager's panel without
## the closure capturing it.
var on_close: Callable    # set by workspace to refresh layout after kill
var on_swap: Callable    # set by workspace to handle pane type swap
var on_open_pane_settings: Callable  # (manager, body): workspace closes conflicting overlays first

var tiles: Array[Dictionary] = []
var last_body: Control
signal tiles_resized


var _pane_settings_panel  # set by workspace

# ── Public spawn API ───────────────────────────────────────────────────

func spawn(shell := "", cwd := "") -> Control:
	var s = shell if shell != "" else SettingsManager.cfg_shell_command
	return spawn_pane("terminal", {
		"shell_command": s,
		"rows": SettingsManager.cfg_default_rows,
		"cols": SettingsManager.cfg_default_cols,
	}, cwd)

func spawn_pane(type_name: String, opts: Dictionary = {}, workspace_cwd := "") -> Control:
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
	# The workspace owns the directory, so it wins over any stored tile key.
	if body is TerminalPane:
		body.workspace_cwd = str(workspace_cwd)

	var title = opts.get("title_label", PaneTypes.ALL.get(type_name, {}).get("name", type_name))
	var w = _build_wrapper_body(body, title)

	if tiles.is_empty():
		tiles.append({wrapper = w, col = 0, row = 0, cspan = PaneTypes.GRID, rspan = PaneTypes.GRID})
	else:
		if not _split_for(w, str(opts.get("split", ""))):
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
	# A traversal that leaves the body visits this pane's own chrome before the
	# next tile's (tree order would otherwise walk into the neighbouring pane).
	var row := vbox.get_node_or_null("TitleBar/" + TITLE_BAR_BUTTONS)
	if row != null and row.get_child_count() > 0 and body is Control:
		(body as Control).focus_next = body.get_path_to(row.get_child(0))

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
	# `agent_badge.gd` owns the silhouette, its tint and its own animation.
	var state_badge := AgentBadge.new()
	state_badge.name = "StateBadge"
	bar.add_child(state_badge)
	state_badge.anchor_left = 0.0; state_badge.anchor_right = 0.0
	state_badge.anchor_top = 0.0; state_badge.anchor_bottom = 1.0
	state_badge.offset_left = UiTokens.SPACE_MD
	state_badge.offset_right = UiTokens.SPACE_MD + UiTokens.BUTTON_MIN_WIDTH


	var btn_hbox = HBoxContainer.new()
	btn_hbox.name = TITLE_BAR_BUTTONS
	btn_hbox.add_theme_constant_override("separation", UiTokens.SPACE_XS)
	btn_hbox.anchor_left = 1.0; btn_hbox.anchor_right = 1.0
	btn_hbox.anchor_top = 0.0; btn_hbox.anchor_bottom = 1.0
	# Three controls, not five. Settings, the one menu that holds everything
	# else, and close: the type list alone used to cost a whole button, and the
	# ~122 px the five reserves is what squeezed a narrow pane's title.
	var btn_total = 3 * UiTokens.BUTTON_MIN_WIDTH + 8
	btn_hbox.offset_left = -btn_total
	btn_hbox.offset_right = -2
	bar.add_child(btn_hbox)

	var settings_btn = Button.new()
	settings_btn.name = "PaneSettings"
	settings_btn.tooltip_text = "Pane settings"
	settings_btn.custom_minimum_size = Vector2(UiTokens.BUTTON_MIN_WIDTH, UiTokens.BUTTON_MIN_HEIGHT)
	Icons.icon_button(settings_btn, Icons.SETTINGS, "Pane settings")
	settings_btn.pressed.connect(func(): _open_pane_settings(_find_body(root)))
	btn_hbox.add_child(settings_btn)

	var more_btn = Button.new()
	more_btn.name = "MoreActions"
	more_btn.tooltip_text = "More pane actions"
	more_btn.custom_minimum_size = Vector2(UiTokens.BUTTON_MIN_WIDTH, UiTokens.BUTTON_MIN_HEIGHT)
	Icons.icon_button(more_btn, Icons.MORE, "More pane actions")
	more_btn.pressed.connect(func():
		show_pane_actions_popup(_find_body(root), root,
			more_btn.get_screen_position() + Vector2(0, more_btn.size.y))
	)
	btn_hbox.add_child(more_btn)

	var close_btn = Button.new()
	close_btn.name = "ClosePane"
	close_btn.tooltip_text = "Close pane"
	close_btn.custom_minimum_size = Vector2(UiTokens.BUTTON_MIN_WIDTH, UiTokens.BUTTON_MIN_HEIGHT)
	Icons.icon_button(close_btn, Icons.DELETE, "Close pane")
	close_btn.pressed.connect(func(): _handle_close(_find_body(root)))
	btn_hbox.add_child(close_btn)

	_wire_chrome_keyboard(btn_hbox)

	return lbl

## Make the title bar's buttons a keyboard toolbar: one explicit ring
## (`KeyboardFocus.ring`), so Tab moves through the chrome and wraps instead of
## leaking into the next pane's tile. A focused terminal consumes Tab for its
## child, so the way in is `Workspace`'s chrome shortcut and the way out is
## Escape in `Workspace._escape_pane_chrome`; without both, the buttons would be
## reachable only by a traversal no user can trigger.
func _wire_chrome_keyboard(row: HBoxContainer) -> void:
	KeyboardFocus.ring(KeyboardFocus.reachable_children(row))

## Focus the first title-bar button of `body`'s tile. False when that pane has
## no title bar to focus (the bar is hidden by a setting, or the body is gone).
func focus_title_bar(body: Control) -> bool:
	if not (body is Control) or not is_instance_valid(body):
		return false
	for t in tiles:
		if _find_body(t.wrapper) != body:
			continue
		var bar: Control = t.wrapper.get_node_or_null("BodyVBox/TitleBar")
		if bar == null or not bar.visible:
			return false
		for child in bar.get_node(TITLE_BAR_BUTTONS).get_children():
			if child is Control and (child as Control).focus_mode != Control.FOCUS_NONE:
				(child as Control).grab_focus()
				return true
		return false
	return false

## Chrome actions end with the keyboard back in the pane. A mouse click focuses
## the clicked button (Godot does that for any `FOCUS_ALL` control), so a pane
## whose action leaves it on screen would otherwise swallow the next keystroke.
## A terminal takes the keyboard itself; another pane may name its own entry
## point (`PaneBody.keyboard_entry` — a wiki note aims at its buffer), and a
## pane without one gets its first tab stop (the wiki's note list or search).
func _return_focus_to_body(body: Control) -> void:
	if body == null or not is_instance_valid(body) or not body.is_visible_in_tree():
		return
	if body is TerminalPane:
		body._take_focus()
		return
	var entry: Control = null
	if body is PaneBody:
		entry = (body as PaneBody).keyboard_entry()
	if entry != null and entry.is_visible_in_tree():
		entry.grab_focus()
		return
	var target := KeyboardFocus.first_reachable(body)
	if target != null:
		target.grab_focus()

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

## Split the largest tile for the new wrapper `w`, preferring the caller's
## `side` (one of `PaneTypes.SPLIT_SIDES`; absent or unknown means no
## preference) and letting the tile's aspect decide when no side was named.
##
## A side is a preference, never a refusal: an axis that cannot hold two
## `MIN_TILE` tiles falls back to the aspect choice, and false is returned only
## when neither axis can. The target keeps the span the aspect split gives it
## (`floor(span / 2)`) in every direction - `left`/`top` move the target and
## put the new tile at the old edge, so `right`/`bottom` are exactly the
## pre-direction geometry.
func _split_for(w: Control, side: String = "") -> bool:
	if not PaneTypes.SPLIT_SIDES.has(side):
		side = ""
	var bi = 0; var ba = 0
	for i in tiles.size():
		var a = tiles[i].cspan * tiles[i].rspan
		if a > ba: ba = a; bi = i
	var s = tiles[bi]
	var horizontal: bool = side == "left" or side == "right" \
			or (side == "" and s.cspan >= s.rspan)
	if horizontal and _split_horizontal(s, w, side == "left"): return true
	if not horizontal and _split_vertical(s, w, side == "top"): return true
	if side != "":
		# The named axis cannot satisfy MIN_TILE; take the aspect choice.
		if not horizontal and _split_horizontal(s, w, false): return true
		if horizontal and _split_vertical(s, w, false): return true
	return false

## Halve the tile along its columns, the new wrapper on the left or the right.
## The target keeps `floor(cspan / 2)`; the new tile takes the rest.
func _split_horizontal(s: Dictionary, w: Control, new_on_left: bool) -> bool:
	var span: int = s.cspan
	var half := maxi(span / 2, 1)
	var rest := span - half
	if half < PaneTypes.MIN_TILE or rest < PaneTypes.MIN_TILE: return false
	var col: int = s.col
	s.cspan = half
	if new_on_left:
		s.col = col + rest
		tiles.append({wrapper = w, col = col, row = s.row, cspan = rest, rspan = s.rspan})
	else:
		tiles.append({wrapper = w, col = col + half, row = s.row, cspan = rest, rspan = s.rspan})
	return true

## Halve the tile along its rows, the new wrapper on the top or the bottom.
## The target keeps `floor(rspan / 2)`; the new tile takes the rest.
func _split_vertical(s: Dictionary, w: Control, new_on_top: bool) -> bool:
	var span: int = s.rspan
	var half := maxi(span / 2, 1)
	var rest := span - half
	if half < PaneTypes.MIN_TILE or rest < PaneTypes.MIN_TILE: return false
	var row: int = s.row
	s.rspan = half
	if new_on_top:
		s.row = row + rest
		tiles.append({wrapper = w, col = s.col, row = row, cspan = s.cspan, rspan = rest})
	else:
		tiles.append({wrapper = w, col = s.col, row = row + half, cspan = s.cspan, rspan = rest})
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

## No single neighbour matches the freed rect, so a *group* of tiles along one
## side absorbs it. Exactly one side may: the old code stretched the tiles on
## both sides of a freed strip across it, so each claimed the whole strip and
## the two groups overlapped. A side qualifies only if its tiles lie within the
## freed edge and together span all of it — a tile that merely shares a
## coordinate with the edge, or one that sticks out past it, would stretch into
## a neighbour's area or leave part of the gap open.
func _expand_partial(rm: Dictionary):
	var left := _edge_group(rm, true, false)
	if not left.is_empty():
		for t in left: t.cspan += rm.cspan
		return
	var right := _edge_group(rm, true, true)
	if not right.is_empty():
		for t in right: t.col = rm.col; t.cspan += rm.cspan
		return
	var up := _edge_group(rm, false, false)
	if not up.is_empty():
		for t in up: t.rspan += rm.rspan
		return
	var down := _edge_group(rm, false, true)
	if not down.is_empty():
		for t in down: t.row = rm.row; t.rspan += rm.rspan
		return
	# Nothing tiles that edge (a hand-edited or pinwheel layout). A lone
	# survivor is simply the whole grid. With several tiles there is no
	# rectangle-preserving way to fill the hole, and stretching one tile over
	# the rest would stack panes on top of each other, so the gap stays.
	if tiles.size() == 1:
		tiles[0].col = 0; tiles[0].row = 0
		tiles[0].cspan = PaneTypes.GRID; tiles[0].rspan = PaneTypes.GRID

## The tiles abutting one side of `rm` that can absorb it — `vertical_edge`
## picks the left/right sides (the shared edge runs along rows), otherwise
## the top/bottom (along columns); `far_side` picks right/bottom. Returns the
## group only when it is contained in the edge and spans all of it, else [].
func _edge_group(rm: Dictionary, vertical_edge: bool, far_side: bool) -> Array:
	var group := []
	var covered := 0
	for t in tiles:
		if vertical_edge:
			var abuts: bool = (rm.col + rm.cspan == t.col) if far_side \
					else (t.col + t.cspan == rm.col)
			if abuts and t.row >= rm.row and t.row + t.rspan <= rm.row + rm.rspan:
				group.append(t)
				covered += t.rspan
		else:
			var abuts: bool = (rm.row + rm.rspan == t.row) if far_side \
					else (t.row + t.rspan == rm.row)
			if abuts and t.col >= rm.col and t.col + t.cspan <= rm.col + rm.cspan:
				group.append(t)
				covered += t.cspan
	var needed: int = rm.rspan if vertical_edge else rm.cspan
	return group if covered == needed else []

# ── Helpers ────────────────────────────────────────────────────────────

func _find_body(w: Control) -> Control:
	return w.get_node_or_null("BodyVBox/Body")

## Tell a tile's pane that `_apply_layout` positioned it (see
## `PaneBody.mark_tile_laid_out`). A terminal's child is spawned on that first
## laid-out size, never on the container's minimum.
func mark_tile_laid_out(t: Dictionary) -> void:
	var body: Control = _find_body(t.wrapper)
	if body is PaneBody:
		body.mark_tile_laid_out()

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

## The one minimize/restore transition, for the title bar and the sidebar alike.
## Hiding a pane leaves nothing to focus on purpose; restoring brings the
## keyboard back, so the next keystroke is not swallowed by chrome that is no
## longer there.
func toggle_pane_minimize(body: Control) -> void:
	if body == null or not is_instance_valid(body):
		return
	body.visible = not body.visible
	if body.visible:
		_return_focus_to_body(body)

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
		on_open_pane_settings.call(self, body)
	else:
		_pane_settings_panel.open_for(body)



func _swap_tile_positions(a: int, b: int):
	var ta = tiles[a]
	var tb = tiles[b]
	var tmp = {"col": ta.col, "row": ta.row, "cspan": ta.cspan, "rspan": ta.rspan}
	ta.col = tb.col; ta.row = tb.row; ta.cspan = tb.cspan; ta.rspan = tb.rspan
	tb.col = tmp.col; tb.row = tmp.row; tb.cspan = tmp.cspan; tb.rspan = tmp.rspan

## Every type change goes through here: the workspace owns the transaction (the
## running-work/unsaved-work guard, the rebuild, the toast).
func _handle_swap(body: Control, new_type_name: String) -> void:
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

## A pane's type key, or "" for a control that is not a pane (a tile mid-build).
func _pane_type_of(body: Control) -> String:
	return body._pane_type() if body != null and body.has_method("_pane_type") else ""

## The one pane-action menu: everything a pane's chrome offers, with its current
## type marked. The title bar's overflow button and the sidebar's row both open
## this, so the two cannot disagree about what a pane can do or which type it is.
##
## Built per open and freed when it closes (the `show_position_swap_popup`
## pattern): a minimized pane reads "Restore pane", and the check mark follows a
## type change, without a menu that outlives the pane it describes.
func show_pane_actions_popup(for_body: Control, menu_parent: Control, at_pos: Vector2) -> void:
	if for_body == null or not is_instance_valid(for_body):
		return
	var menu := PopupMenu.new()
	menu.name = "PaneActionsMenu"
	var current := _pane_type_of(for_body)
	menu.add_item("Restore pane" if not for_body.visible else "Minimize pane")
	menu.set_item_metadata(menu.item_count - 1, {"kind": "minimize"})
	menu.add_item("Swap position\u2026")
	menu.set_item_metadata(menu.item_count - 1, {"kind": "position"})
	# One tile has nothing to swap with: a live item that opens nothing reads as
	# a broken click.
	menu.set_item_disabled(menu.item_count - 1, tiles.size() < 2)
	menu.add_separator()
	for key in PaneTypes.ALL:
		menu.add_radio_check_item(PaneTypes.ALL[key]["name"])
		var idx := menu.item_count - 1
		menu.set_item_metadata(idx, {"kind": "type", "key": key})
		menu.set_item_checked(idx, key == current)
	menu.index_pressed.connect(func(idx: int):
		var meta = menu.get_item_metadata(idx)
		menu.queue_free()
		if not (meta is Dictionary):
			return
		var action: Dictionary = meta
		match str(action.get("kind", "")):
			"minimize":
				toggle_pane_minimize(for_body)
			"position":
				show_position_swap_popup(for_body, menu_parent, at_pos)
			"type":
				var key := str(action.get("key", ""))
				# The checked item is the pane's own type: choosing it is a
				# no-op, not a request to destroy and rebuild an identical body
				# (`swap_pane` does allow a same-type swap - a test pins it).
				if key == "" or key == current:
					_return_focus_to_body(for_body)
					return
				_handle_swap(for_body, key)
	)
	menu_parent.add_child(menu)
	menu.position = at_pos
	menu.reset_size()
	menu.popup()
	menu.popup_hide.connect(menu.queue_free)

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
		_return_focus_to_body(for_body)
		tiles_resized.emit()
	)
	menu_parent.add_child(menu)
	menu.position = at_pos
	menu.reset_size()
	menu.popup()
	menu.popup_hide.connect(menu.queue_free)

# ── Edge drag resize (the state machine lives in tile_drag.gd) ─────────

var _drag: TileDrag


func _init() -> void:
	_drag = TileDrag.new(self)

## True while an edge drag owns the mouse.
func drag_active() -> bool:
	return _drag.drag_active()

## Start a resize drag. Called by an edge strip's press; the drag itself is
## driven by `drive_edge_drag` from the workspace's raw input, because the
## motion after a press on the border immediately leaves the strip for the pane
## body. The geometry snapshot, preview and commit live in TileDrag.
func begin_edge_drag(wrapper: Control, edge: String, at: Vector2) -> void:
	_drag.begin_edge_drag(wrapper, edge, at)

## End the drag: snap the previewed travel to whole units, apply it to the tile
## model, and emit `tiles_resized` once (the only thing that moves a tile).
func end_edge_drag() -> void:
	_drag.end_edge_drag()

## Drive an in-flight drag; true when the event belonged to it, so the caller
## consumes it and the pane body does not read the motion as a text selection.
func drive_edge_drag(event: InputEvent) -> bool:
	return _drag.drive_edge_drag(event)

func _on_edge_strip_input(event: InputEvent, wrapper: Control, edge: String) -> void:
	_drag.on_strip_input(event, wrapper, edge)

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
