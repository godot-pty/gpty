class_name TileDrag
## Divider-drag state machine, extracted from terminal_manager.gd.
##
## Owns everything about dragging a divider line: the press-time geometry
## snapshot, the preview, and the commit. The tile model is integer
## (`PaneTypes.GRID` units), and so is the preview: the divider moves from one
## unit to the next as the pointer travels. A pixel-continuous preview used to
## look smoother and then hop up to half a unit (~16 px on a 1920 px window) on
## release, which is movement the user never chose; snapping while dragging
## means what is shown is what is committed.
##
## The grab target is a *line*, not a pane edge (`DividerHandles` owns one
## handle per divider segment), so a drag is started by its axis and grid line
## rather than by a wrapper and an edge.
##
## The TerminalManager owns one instance (`_tm._drag`) and keeps thin delegators
## for the entry points the workspace and the handle layer call. Everything this
## object moves lives in the manager's tile list, reached through `_tm`.

## The manager that owns this object, held weakly.
##
## The manager stores this instance, and this instance reads the manager's tile
## list back, so a strong reference here closes a `RefCounted` cycle neither
## side can release: the manager, its drag and the two scripts they hold
## survived every exit (and every closed workspace tab). The manager outlives
## the drag by construction - it owns it - so `_tm` is null only during
## teardown, after which nothing calls into a drag.
var _tm_ref: WeakRef

func _init(manager: TerminalManager) -> void:
	_tm_ref = weakref(manager)

var _tm: TerminalManager:
	get:
		return _tm_ref.get_ref() as TerminalManager if _tm_ref else null


# ── Divider Drag ───────────────────────────────────────────────────────

## Axis of the in-flight drag ("x" or "y"), empty when none. The axis *is* the
## active flag: a drag always belongs to one divider line.
var _drag_axis: String = ""
var _drag_start_pos := Vector2.ZERO

## Pixel geometry of the divider line, captured at the press.
##
## The tile model is integer, so everything the preview needs — which tiles sit
## on the line, their committed rects, one grid unit in pixels, the travel
## limits in units — is snapshotted before the first preview moves anything,
## because afterwards the wrappers no longer describe the committed layout.
var _drag_saved_sizes: Dictionary = {}
var _drag_before: Array = []
var _drag_after: Array = []
var _drag_rects: Dictionary = {}
var _drag_line: int = 0
var _drag_unit: float = 0.0
var _drag_lo: int = 0
var _drag_hi: int = 0
var _drag_preview_px: float = 0.0

## True while a drag owns the mouse.
func drag_active() -> bool:
	return _drag_axis != ""

## Axis the in-flight drag moves along ("x" or "y"); empty when idle.
func drag_axis() -> String:
	return _drag_axis

## Start a resize drag on a divider line. Called by the handle layer's press;
## the drag itself is driven by `drive_edge_drag` from raw input, because the
## motion that follows a press on the divider immediately leaves the handle for
## the pane body.
##
## Returns false when the line cannot move (a border line, no tile on one side,
## or both sides already at `MIN_TILE`), so such a press never becomes a drag.
func begin_line_drag(axis: String, line: int, at: Vector2) -> bool:
	if _tm == null or _tm.tiles.size() < 2:
		# A single pane fills the grid; there is no divider to move. The handle
		# layer shows no handle in that state (see `DividerHandles.refresh`),
		# this is the belt under those braces.
		return false
	var limits := line_limits(axis, line)
	if not bool(limits.get("ok", false)):
		return false
	_save_drag_initial_sizes()
	var horizontal := axis == "x"
	var sides := _tiles_on_divider(horizontal, line)
	if sides["before"].is_empty() or sides["after"].is_empty():
		_drag_saved_sizes.clear()
		return false
	_drag_axis = axis
	_drag_line = line
	_drag_unit = float(limits["unit"])
	_drag_lo = int(limits["lo"])
	_drag_hi = int(limits["hi"])
	_drag_before = sides["before"]
	_drag_after = sides["after"]
	_drag_start_pos = at
	_drag_preview_px = 0.0
	_drag_rects = {}
	for o in _drag_before + _drag_after:
		var w: Control = o.wrapper
		_drag_rects[w] = {
			"left": w.offset_left, "top": w.offset_top,
			"right": w.offset_right, "bottom": w.offset_bottom,
		}
	_tm.divider_drag_started.emit(axis)
	return true

## End the drag: apply the previewed travel to the tile model and relayout
## once. The commit is the only thing that moves a tile, so a drag emits
## `tiles_resized` exactly once (the consumer is `workspace._apply_layout`,
## which also restores the wrappers to the model) and then
## `divider_drag_finished`, which is what asks the panes for their final
## reflow - after the grid is the released one.
func end_edge_drag():
	if _drag_axis == "":
		return
	_commit_edge_drag()
	_drag_axis = ""
	_drag_line = 0
	_drag_unit = 0.0
	_drag_before = []
	_drag_after = []
	_drag_rects.clear()
	_drag_saved_sizes.clear()
	_drag_preview_px = 0.0
	_tm.tiles_resized.emit()
	_tm.divider_drag_finished.emit()

## Drive an in-flight drag from the workspace's raw `_input`: motion previews
## the divider, the button release commits it. Returns true when the caller must
## consume the event.
##
## The release is deliberately **not** consumed. The press that started the drag
## was taken by the handle, and a viewport that never sees the matching release
## keeps its stale mouse focus and stops updating the cursor shape until some
## other press-and-release pair reaches it - the frozen resize cursor after
## every drag. The release reaches only the handle that took the press, whose
## `end_edge_drag` is a no-op by then.
func drive_edge_drag(event: InputEvent) -> bool:
	if _drag_axis == "":
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
		return false
	return false

func _save_drag_initial_sizes():
	_drag_saved_sizes.clear()
	for i in _tm.tiles.size():
		var t = _tm.tiles[i]
		_drag_saved_sizes[t.wrapper] = {"col": t.col, "row": t.row, "cspan": t.cspan, "rspan": t.rspan}

## Whether a divider line can move, and how far, in whole units.
##
## This is the query the handle layer asks before it offers a cursor, and the
## source of truth `begin_line_drag` starts from, so the two can never disagree.
## It reads the live tile model: no press has happened yet, so a saved snapshot
## would not exist.
##
## `unit` is one grid unit in pixels, measured on a tile that ends on the line.
## Returns `{"ok": false}` when no tile sits on the far side (a border line) or
## both sides are already at `MIN_TILE` (lo >= hi), because a divider that cannot
## move must not advertise a resize.
func line_limits(axis: String, line: int) -> Dictionary:
	if _tm == null or _tm.tiles.size() < 2:
		return {"ok": false}
	var horizontal := axis == "x"
	var sides := _tiles_on_divider(horizontal, line)
	if sides["before"].is_empty() or sides["after"].is_empty():
		return {"ok": false}
	# Travel limits in whole units — the same clamps the commit uses, so the
	# preview can never show a position the release would refuse: the line
	# stays inside the grid and no tile shrinks past MIN_TILE.
	var lo := -line
	var hi := PaneTypes.GRID - line
	for o in sides["before"]:
		lo = maxi(lo, PaneTypes.MIN_TILE - _span_of(o, horizontal))
	for o in sides["after"]:
		hi = mini(hi, _span_of(o, horizontal) - PaneTypes.MIN_TILE)
	if lo >= hi:
		return {"ok": false}
	var ref_tile: Dictionary = sides["before"][0]
	var unit := _unit_for(ref_tile, horizontal)
	if unit <= 0.0:
		return {"ok": false}
	return {"ok": true, "lo": lo, "hi": hi, "unit": unit}

## The tiles touching a divider line: `before` ends on it, `after` starts on
## it. Read from the spans saved at the press when there is one, and from the
## live model otherwise (the pre-press `line_limits` query).
func _tiles_on_divider(horizontal: bool, line: int) -> Dictionary:
	var before := []
	var after := []
	for o in _tm.tiles:
		var saved: Dictionary = _drag_saved_sizes.get(o.wrapper, {})
		if horizontal:
			var col: int = int(saved.get("col", o.col))
			var cspan: int = int(saved.get("cspan", o.cspan))
			if col + cspan == line: before.append(o)
			if col == line: after.append(o)
		else:
			var row: int = int(saved.get("row", o.row))
			var rspan: int = int(saved.get("rspan", o.rspan))
			if row + rspan == line: before.append(o)
			if row == line: after.append(o)
	return {"before": before, "after": after}

func _span_of(tile: Dictionary, horizontal: bool) -> int:
	var saved: Dictionary = _drag_saved_sizes.get(tile.wrapper, {})
	if saved.is_empty():
		return int(tile.cspan) if horizontal else int(tile.rspan)
	return int(saved.cspan) if horizontal else int(saved.rspan)

## One grid unit in pixels, measured on `tile`'s committed rect.
func _unit_for(tile: Dictionary, horizontal: bool) -> float:
	var w: Control = tile.wrapper
	if not is_instance_valid(w):
		return 0.0
	return (w.size.x if horizontal else w.size.y) / float(maxi(_span_of(tile, horizontal), 1))

## Preview the divider at the nearest whole grid unit to the pointer.
##
## The tile model only holds whole units, so the preview does too: the divider
## moves one unit at a time and the commit rounds to the same integer, which is
## what removes the hop on release. What makes the drag *follow* is the pane's
## own reflow while the drag runs (`TerminalPane.set_drag_resizing`).
func _preview_edge_drag(delta_px: float):
	if _drag_unit <= 0.0:
		return
	var clamped := clampf(delta_px, float(_drag_lo) * _drag_unit, float(_drag_hi) * _drag_unit)
	var step := clampi(int(roundf(clamped / _drag_unit)), _drag_lo, _drag_hi)
	_drag_preview_px = float(step) * _drag_unit
	for o in _drag_before:
		var w: Control = o.wrapper
		if not is_instance_valid(w): continue
		var r: Dictionary = _drag_rects.get(w, {})
		if r.is_empty(): continue
		if _drag_axis == "x": w.offset_right = float(r["right"]) + _drag_preview_px
		else: w.offset_bottom = float(r["bottom"]) + _drag_preview_px
	for o in _drag_after:
		var w: Control = o.wrapper
		if not is_instance_valid(w): continue
		var r: Dictionary = _drag_rects.get(w, {})
		if r.is_empty(): continue
		if _drag_axis == "x": w.offset_left = float(r["left"]) + _drag_preview_px
		else: w.offset_top = float(r["top"]) + _drag_preview_px

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
