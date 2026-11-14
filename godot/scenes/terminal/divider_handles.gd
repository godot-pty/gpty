class_name DividerHandles
extends Control
## The grab bands a workspace grid puts over its divider lines: one handle per
## divider segment, highlighted on hover.
##
## A divider is a *line*, not a pane edge. The old per-pane strips sat inside
## each wrapper's 1 px stylebox border, so two neighbouring panes left those two
## pixels dead between them and a divider was two 6 px targets with a hole in
## the middle. Here there is one band, centred on the line and spanning exactly
## the stretch of it where a tile sits on both sides, so a pane that spans
## across the line never has its content covered by a handle that could not
## move it.
##
## The layer itself is transparent to the mouse; only a handle that can move
## takes it (`TerminalManager.divider_limits`), which is what keeps a
## single-pane grid and a divider pinned at `MIN_TILE` from advertising a resize
## they cannot honour. A hover paints `HIGHLIGHT` px of the accent colour down
## the middle of the band, so the divider is visible even where the platform's
## cursor shape does not change.
##
## Geometry is pure and static (`segments`, `handle_rect`), so it is testable
## without a scene tree; the instance half owns a pool of `Control`s that is
## grown, never freed mid-event (`refresh` can run inside input dispatch).

## Total grab band of a divider, px, centred on the line: 6 px of reach into
## each pane and no dead strip between them (the old pair of 6 px strips plus
## the two 1 px borders was a 14 px target with a 2 px hole).
const HIT := 12
## Thickness of the hover highlight, px.
const HIGHLIGHT := 2

## The manager whose tiles the bands are drawn over, held weakly: the layer
## lives in a grid, the grid's workspace owns the manager, and a strong
## reference here would close a cycle neither side could release.
##
## Both the field and `_init`'s parameter are deliberately untyped. A
## `TerminalManager` annotation makes the global class registry compile
## `terminal_manager.gd` - which reads the `SettingsManager` autoload - before
## the autoloads exist, and in a `godot -s` launch that leaves every workspace
## with a Nil manager (`Nonexistent function 'new' in base 'GDScript'`).
var _tm_ref: WeakRef

var _tm:
	get:
		return _tm_ref.get_ref() if _tm_ref else null

## The segments currently on screen, in the order `refresh` laid them out.
var _segments: Array[Dictionary] = []
## One `Control` per segment, reused across refreshes.
var _pool: Array[Control] = []
## The segment each pool slot currently shows (`{}` when the slot is unused).
var _slot: Array[Dictionary] = []
## The pool slot the pointer is over, or -1.
var _hovered := -1

func _init(tm) -> void:
	_tm_ref = weakref(tm)
	name = "DividerHandles"
	mouse_filter = Control.MOUSE_FILTER_IGNORE

# ── Pure geometry ──────────────────────────────────────────────────────

## Every divider segment of a tile model, in grid units.
##
## `tiles` holds `{col, row, cspan, rspan}` ints; `grid` is `PaneTypes.GRID`.
## For each axis and each interior line, a segment is a maximal run along the
## line where some tile ends on it and another starts on it — the stretch where
## both sides exist, which is exactly what the drag moves.
##
## Returns `[{"axis": "x"|"y", "line": int, "from": int, "to": int}]` with `to`
## exclusive, sorted by axis, then line, then position along the line. One pane
## yields nothing (it has no divider); a layout whose tiles span a line on one
## side only yields no segment there.
static func segments(tiles: Array, grid: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if grid <= 1:
		return out
	for axis in ["x", "y"]:
		var horizontal: bool = axis == "x"
		for line in range(1, grid):
			# Along the line: which units have a tile ending on it, and which
			# have one starting on it. A unit where both hold is a divider.
			var ends := PackedByteArray()
			var starts := PackedByteArray()
			ends.resize(grid)
			starts.resize(grid)
			for t in tiles:
				if not (t is Dictionary):
					continue
				var along_start: int = int(t.get("col", 0)) if horizontal else int(t.get("row", 0))
				var along_span: int = int(t.get("cspan", 0)) if horizontal else int(t.get("rspan", 0))
				var perp_start: int = int(t.get("row", 0)) if horizontal else int(t.get("col", 0))
				var perp_span: int = int(t.get("rspan", 0)) if horizontal else int(t.get("cspan", 0))
				var touches_end: bool = along_start + along_span == line
				var touches_start: bool = along_start == line
				if not touches_end and not touches_start:
					continue
				for u in range(perp_start, perp_start + perp_span):
					if u < 0 or u >= grid:
						continue
					if touches_end:
						ends[u] = 1
					if touches_start:
						starts[u] = 1
			var run := -1
			for u in range(grid + 1):
				var both: bool = u < grid and ends[u] == 1 and starts[u] == 1
				if both and run < 0:
					run = u
				elif not both and run >= 0:
					out.append({"axis": axis, "line": line, "from": run, "to": u})
					run = -1
	return out

## A segment's band in pixels, inside a grid `size_px` across `grid` units.
## `HIT` wide across the line, centred on it, and exactly the segment's length
## along it.
static func handle_rect(segment: Dictionary, size_px: Vector2, grid: int) -> Rect2:
	var units := float(maxi(grid, 1))
	var from := int(segment.get("from", 0))
	var to := int(segment.get("to", 0))
	var line := int(segment.get("line", 0))
	if str(segment.get("axis", "x")) == "x":
		var ux := size_px.x / units
		var uy := size_px.y / units
		return Rect2(line * ux - HIT * 0.5, from * uy, HIT, (to - from) * uy)
	var ux2 := size_px.x / units
	var uy2 := size_px.y / units
	return Rect2(from * ux2, line * uy2 - HIT * 0.5, (to - from) * ux2, HIT)

# ── The layer ──────────────────────────────────────────────────────────

## Re-read the manager's tiles and re-place the bands.
##
## Called from `Workspace._apply_layout`, which every create, kill, swap,
## restore, workspace switch and window resize reaches, so this is the one
## place the bands are derived from. Pixel space is the parent grid's: this
## layer is anchored to it, and the grid's size is valid a frame before the
## layer's own is.
func refresh() -> void:
	if _tm == null:
		return
	var host := get_parent() as Control
	if host == null:
		return
	var extent := host.size
	var model: Array = []
	for t in _tm.tiles:
		model.append({
			"col": int(t.col), "row": int(t.row),
			"cspan": int(t.cspan), "rspan": int(t.rspan),
		})
	_segments = segments(model, PaneTypes.GRID)
	_ensure_pool(_segments.size())
	if _hovered >= _segments.size():
		_hovered = -1
	for i in _pool.size():
		var handle: Control = _pool[i]
		if i >= _segments.size():
			_slot[i] = {}
			handle.visible = false
			handle.mouse_filter = Control.MOUSE_FILTER_IGNORE
			handle.mouse_default_cursor_shape = Control.CURSOR_ARROW
			continue
		var seg: Dictionary = _segments[i]
		_slot[i] = seg
		var rect := handle_rect(seg, extent, PaneTypes.GRID)
		handle.position = rect.position
		handle.size = rect.size
		handle.visible = true
		# Only a divider that can move is a resize target: a single-pane grid
		# has no line at all, and a divider with both sides at MIN_TILE has no
		# travel, so neither may show a cursor the press cannot honour.
		var movable := bool(_tm.divider_limits(str(seg["axis"]), int(seg["line"])).get("ok", false))
		handle.mouse_filter = Control.MOUSE_FILTER_STOP if movable else Control.MOUSE_FILTER_IGNORE
		handle.mouse_default_cursor_shape = (
			(Control.CURSOR_HSIZE if str(seg["axis"]) == "x" else Control.CURSOR_VSIZE)
			if movable else Control.CURSOR_ARROW)
		handle.queue_redraw()

func _ensure_pool(count: int) -> void:
	while _pool.size() < count:
		var i := _pool.size()
		var handle := Control.new()
		handle.name = "Divider%d" % i
		handle.visible = false
		handle.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(handle)
		handle.gui_input.connect(_on_handle_input.bind(i))
		handle.mouse_entered.connect(_set_hover.bind(i, true))
		handle.mouse_exited.connect(_set_hover.bind(i, false))
		handle.draw.connect(_draw_slot.bind(i))
		_pool.append(handle)
		_slot.append({})

func _on_handle_input(event: InputEvent, slot: int) -> void:
	if not (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT):
		return
	if not event.pressed:
		return
	var seg: Dictionary = _slot[slot]
	if seg.is_empty():
		return
	if _tm.begin_line_drag(str(seg["axis"]), int(seg["line"]), event.global_position):
		# The drag owns the divider from here; the hover affordance has served
		# its purpose and the moving divider is the feedback now.
		_hovered = -1
		_pool[slot].queue_redraw()

func _set_hover(slot: int, on: bool) -> void:
	if on:
		_hovered = slot
	elif _hovered == slot:
		_hovered = -1
	if slot >= 0 and slot < _pool.size():
		_pool[slot].queue_redraw()

## The hover highlight, drawn by the handle itself so it is clipped to the band.
func _draw_slot(slot: int) -> void:
	if slot != _hovered or slot < 0 or slot >= _pool.size() or slot >= _slot.size():
		return
	if _slot[slot].is_empty():
		return
	var handle: Control = _pool[slot]
	var accent: Color = UiPalette.active().ACCENT
	if str(_slot[slot]["axis"]) == "x":
		handle.draw_rect(
			Rect2(Vector2(handle.size.x * 0.5 - HIGHLIGHT * 0.5, 0.0),
				Vector2(HIGHLIGHT, handle.size.y)), accent)
	else:
		handle.draw_rect(
			Rect2(Vector2(0.0, handle.size.y * 0.5 - HIGHLIGHT * 0.5),
				Vector2(handle.size.x, HIGHLIGHT)), accent)
