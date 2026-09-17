class_name TileDrag
## Divider-drag state machine, extracted from terminal_manager.gd.
##
## Owns everything about dragging a pane's edge: the press-time geometry
## snapshot, the pixel preview, and the unit-snapped commit. The tile model is
## integer (`PaneTypes.GRID` units), so the preview moves wrappers in pixels and
## the release applies whole units — the divider then follows the pointer
## continuously while the model stays integral.
##
## The TerminalManager owns one instance (`_tm._drag`) and keeps thin delegators
## for the four entry points the workspace and the edge strips call. Everything
## this object moves lives in the manager's tile list, reached through `_tm`.

var _tm: TerminalManager


func _init(manager: TerminalManager) -> void:
	_tm = manager


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
	if _tm.tiles.size() < 2:
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
	_tm.tiles_resized.emit()

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

func on_strip_input(event: InputEvent, wrapper: Control, edge: String):
	if not (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT):
		return
	if event.pressed:
		begin_edge_drag(wrapper, edge, event.global_position)
	else:
		end_edge_drag()

func _save_drag_initial_sizes():
	_drag_saved_sizes.clear()
	for i in _tm.tiles.size():
		var t = _tm.tiles[i]
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
	var ti := _tm._tile_index_for_wrapper(wrapper)
	if ti == -1 or _drag_saved_sizes.get(wrapper, {}).is_empty():
		return false
	var t = _tm.tiles[ti]
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
	for o in _tm.tiles:
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
	for o in _tm.tiles:
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
