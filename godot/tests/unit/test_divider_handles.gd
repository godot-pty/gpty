extends GutTest
# The divider grab bands are pure geometry: one band per stretch of a divider
# line that has a tile on both sides.
#
# Defends the shape the v0.8.3 resize row closed: the old per-pane strips were
# two 6 px targets with the two 1 px wrapper borders dead between them, and they
# existed even where nothing could move. A band here must span exactly the
# stretch where both sides exist (a pane that crosses the line must not have a
# handle over its own content) and be centred on the line.

const GRID := PaneTypes.GRID

func _tile(col: int, row: int, cspan: int, rspan: int) -> Dictionary:
	return {"col": col, "row": row, "cspan": cspan, "rspan": rspan}

func _axes(segments: Array) -> Array:
	var out := []
	for s in segments:
		out.append("%s:%d:%d-%d" % [s["axis"], s["line"], s["from"], s["to"]])
	return out

func test_one_pane_has_no_divider():
	assert_eq(DividerHandles.segments([_tile(0, 0, GRID, GRID)], GRID), [],
		"a single pane fills the grid and has nothing to drag")

func test_two_side_by_side_panes_get_one_full_height_band():
	var segs := DividerHandles.segments([_tile(0, 0, 30, GRID), _tile(30, 0, 30, GRID)], GRID)
	assert_eq(_axes(segs), ["x:30:0-60"],
		"the divider between two full-height panes is one line, not two strips")

## The layout that ships as "Agent Workspace": a full-height pane beside two
## stacked ones. The vertical line runs the whole height; the horizontal one
## exists only where there is a pane on both sides of it.
func test_a_stacked_layout_gets_a_band_per_existing_stretch():
	var segs := DividerHandles.segments([
		_tile(0, 0, 35, GRID),
		_tile(35, 0, 25, 30),
		_tile(35, 30, 25, 30),
	], GRID)
	assert_eq(_axes(segs), ["x:35:0-60", "y:30:35-60"],
		"the horizontal divider must not run over the full-height pane")

func test_a_two_by_two_layout_gets_both_full_lines():
	var half := int(GRID * 0.5)
	var segs := DividerHandles.segments([
		_tile(0, 0, half, half), _tile(half, 0, GRID - half, half),
		_tile(0, half, half, GRID - half), _tile(half, half, GRID - half, GRID - half),
	], GRID)
	assert_eq(_axes(segs), ["x:%d:0-60" % half, "y:%d:0-60" % half],
		"both dividers run across the whole grid")

## A tile that spans across a line removes the divider where it crosses: a band
## there would grab a press and move a line that does not exist at that point.
func test_a_spanning_tile_leaves_no_band_beside_it():
	var segs := DividerHandles.segments([
		_tile(0, 0, 30, GRID),
		_tile(30, 0, 30, 30),
	], GRID)
	assert_eq(_axes(segs), ["x:30:0-30"],
		"the band covers only the rows where both sides have a tile")

func test_the_band_is_centred_on_the_line_and_as_long_as_the_segment():
	var seg: Dictionary = {"axis": "x", "line": 30, "from": 0, "to": GRID}
	var rect := DividerHandles.handle_rect(seg, Vector2(1200, 600), GRID)
	assert_almost_eq(rect.size.x, float(DividerHandles.HIT), 0.01, "one band, not two strips")
	assert_almost_eq(rect.position.x + rect.size.x * 0.5, 600.0, 0.01,
		"the band is centred on the divider line")
	assert_almost_eq(rect.position.y, 0.0, 0.01, "a full-height segment starts at the top")
	assert_almost_eq(rect.size.y, 600.0, 0.01, "a full-height segment spans the grid")

func test_a_short_segment_maps_to_its_own_stretch():
	var seg: Dictionary = {"axis": "y", "line": 30, "from": 35, "to": GRID}
	var rect := DividerHandles.handle_rect(seg, Vector2(1200, 600), GRID)
	assert_almost_eq(rect.position.x, 35.0 * 1200.0 / GRID, 0.01,
		"the band starts where the pane above it starts")
	assert_almost_eq(rect.size.y, float(DividerHandles.HIT), 0.01, "a horizontal band is HIT tall")
	assert_almost_eq(rect.position.y + rect.size.y * 0.5, 300.0, 0.01,
		"the band is centred on the line")
	assert_almost_eq(rect.size.x, (GRID - 35) * 1200.0 / GRID, 0.01,
		"the band ends with the panes it separates")
