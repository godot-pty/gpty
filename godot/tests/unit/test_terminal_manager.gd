extends GutTest
# Unit tests for TerminalManager — spawn/kill/tile logic.
# No UI rendering; tests pure RefCounted logic.

## The platform default, so the fixture is a program that exists here
## (a POSIX path is refused on Windows and would spawn nothing).
var _canned_shell := ""

var _tm: TerminalManager

func before_each():
	MockAutoloads.setup()
	_canned_shell = SettingsManager.default_shell_command()
	SettingsManager.cfg_shell_command = _canned_shell
	SettingsManager.cfg_default_rows = 24
	SettingsManager.cfg_default_cols = 80
	_tm = TerminalManager.new()

func after_each():
	_tm.reset()
	# TerminalManager is RefCounted — no free() needed
	MockAutoloads.teardown()

# ── Spawn ──────────────────────────────────────────────────────────────

func test_spawn_first_terminal():
	var body = _tm.spawn()
	assert_not_null(body, "spawn() should return a body")
	assert_eq(_tm.tiles.size(), 1, "tiles should have 1 entry after first spawn")
	assert_not_null(_tm.tiles[0].wrapper, "tile wrapper should exist")

func test_spawn_second_splits():
	_tm.spawn()
	var body2 = _tm.spawn()
	assert_not_null(body2, "second spawn should return a body")
	assert_eq(_tm.tiles.size(), 2, "tiles should have 2 entries")
	# Both tiles should have different positions
	var t0 = _tm.tiles[0]
	var t1 = _tm.tiles[1]
	var same_pos = (t0.col == t1.col and t0.row == t1.row)
	assert_false(same_pos, "tiles should have different grid positions")

func test_spawn_pane_terminal():
	var body = _tm.spawn_pane("terminal", {"shell_command": "/bin/zsh"})
	assert_not_null(body, "spawn_pane terminal should return a body")
	assert_eq(_tm.tiles.size(), 1)
	# Check title bar label
	var lbl = _tm.tiles[0].wrapper.get_node_or_null("BodyVBox/TitleBar/TitleLabel")
	assert_not_null(lbl, "title label should exist")
	assert_string_contains(lbl.text, "Terminal")

func test_spawn_pane_code_viewer():
	var body = _tm.spawn_pane("code_viewer", {})
	assert_not_null(body, "spawn_pane code_viewer should return a body")
	assert_eq(_tm.tiles.size(), 1)
	# Verify it's the correct class
	assert_true(body is CodeViewerPane, "body should be CodeViewerPane")

# test_spawn_pane_unknown_type removed — push_error from TerminalManager
# conflicts with GUT's error tracking. Covered by integration tests.

func test_create_body_all_types():
	for key in ["terminal", "code_viewer", "file_tree", "inspector", "reasoning"]:
		var body = _tm.create_body(key)
		assert_not_null(body, "create_body(%s) should return non-null" % key)

func test_spawn_pane_uses_default_shell():
	# spawn_pane applies global settings to fresh terminal bodies, so the
	# shell defaults to cfg_shell_command (the platform default, set in before_each).
	var body = _tm.spawn_pane("terminal", {})
	assert_not_null(body)
	assert_eq(body.shell_command, _canned_shell)

func test_spawn_pane_sets_workspace_cwd():
	# The workspace owns the directory, so it wins over any tile key.
	var dir := OS.get_user_data_dir()
	var body = _tm.spawn_pane("terminal", {"workspace_cwd": "/tmp/from-the-file"}, dir)
	assert_not_null(body)
	assert_eq(body.workspace_cwd, dir,
		"spawn_pane must pass the workspace's directory to the terminal")

# ── Kill ────────────────────────────────────────────────────────────────

func test_kill_removes_tile():
	var body = _tm.spawn()
	assert_eq(_tm.tiles.size(), 1)
	_tm.kill(body)
	assert_eq(_tm.tiles.size(), 0, "tiles should be empty after kill")

# "Close the last pane" is a Workspace path, not a TerminalManager one: the
# shortcut and the palette call `Workspace._kill_last`, which resolves
# `last_body` and goes through the pane's close ask like every other kill.

# ── Reset ──────────────────────────────────────────────────────────────

func test_reset_clears_everything():
	_tm.spawn()
	_tm.spawn()
	_tm.spawn()
	assert_eq(_tm.tiles.size(), 3)
	_tm.reset()
	assert_eq(_tm.tiles.size(), 0, "tiles should be empty after reset")
	assert_null(_tm.last_body, "last_body should be null after reset")

# ── Tile split refusal ─────────────────────────────────────────────────

func test_split_refused_when_grid_full():
	# Fill the grid: keep spawning until the split algorithm refuses. The cap
	# is the most tiles the grid can hold — (GRID / MIN_TILE)², i.e. 100 at
	# 60/6 — with margin, so it tracks the constants instead of drifting.
	var cap: int = int(pow(float(PaneTypes.GRID) / float(PaneTypes.MIN_TILE), 2.0)) + 5
	var count := 0
	while count < cap:
		var body = _tm.spawn()
		if body == null:
			break
		count += 1
	assert_gt(count, 0, "should have spawned at least one tile")
	assert_lt(count, cap, "the grid must refuse a split before the cap is reached")
	# After filling, next spawn should return null
	var extra = _tm.spawn()
	assert_null(extra, "spawn should return null when grid is full")


# ── Swap ─────────────────────────────────────────────────────────────────

func test_swap_pane_same_spot():
	var body = _tm.spawn_pane("terminal", {})
	assert_not_null(body)
	var old_tile = _tm.tiles[0]
	var old_col = old_tile.col; var old_row = old_tile.row
	var old_cspan = old_tile.cspan; var old_rspan = old_tile.rspan

	var new_body = _tm.swap_pane(body, "code_viewer")
	assert_not_null(new_body, "swap_pane should return a new body")
	assert_eq(_tm.tiles.size(), 1, "tiles should still have 1 entry")

	var new_tile = _tm.tiles[0]
	assert_eq(new_tile.col, old_col, "col should be unchanged")
	assert_eq(new_tile.row, old_row, "row should be unchanged")
	assert_eq(new_tile.cspan, old_cspan, "cspan should be unchanged")
	assert_eq(new_tile.rspan, old_rspan, "rspan should be unchanged")

	assert_eq(new_body._pane_type(), "code_viewer", "new body should be code_viewer")
	assert_ne(new_body, body, "new body should be different instance")

func test_swap_pane_same_type():
	var body = _tm.spawn_pane("terminal", {"pane_name": "Orig"})
	assert_not_null(body)
	assert_eq(body.pane_name, "Orig")

	var new_body = _tm.swap_pane(body, "terminal")
	assert_not_null(new_body, "swap_pane should return a new body")
	assert_eq(_tm.tiles.size(), 1, "tiles should still have 1 entry")
	assert_eq(new_body._pane_type(), "terminal", "new body should be terminal")
	assert_ne(new_body, body, "new body should be different instance")

func test_swap_preserves_settings():
	var body = _tm.spawn_pane("terminal", {"pane_name": "Test", "font_size": 20})
	assert_not_null(body)
	assert_eq(body.pane_name, "Test")
	assert_eq(body.font_size, 20)

	var new_body = _tm.swap_pane(body, "code_viewer")
	assert_not_null(new_body)
	assert_eq(new_body.pane_name, "Test", "pane_name should be preserved")
	assert_eq(new_body.font_size, 20, "font_size should be preserved")

# test_swap_pane_not_found removed — push_error from TerminalManager
# conflicts with GUT's error tracking. Covered by integration tests.

# ── Position swap target resolution ────────────────────────────────────

func test_swap_pair_resolves_against_the_current_tile_list():
	var b1 = _tm.spawn_pane("terminal", {})
	var b2 = _tm.spawn_pane("terminal", {})
	var b3 = _tm.spawn_pane("terminal", {})
	assert_not_null(b1)
	assert_not_null(b2)
	assert_not_null(b3)

	# A popup opened with (b1, b3) chosen. b2 is killed meanwhile, so the
	# index b3 had at open time now points at a different pane.
	_tm.kill(b2)

	assert_eq(
		_tm.resolve_swap_pair(b1, b3), Vector2i(0, 1),
		"surviving panes must resolve to their current indices")

func test_swap_pair_abandons_a_closed_target():
	var b1 = _tm.spawn_pane("terminal", {})
	var b2 = _tm.spawn_pane("terminal", {})
	assert_not_null(b1)
	assert_not_null(b2)

	_tm.kill(b2)

	assert_eq(
		_tm.resolve_swap_pair(b1, b2), Vector2i(-1, -1),
		"a pane that is no longer open must abandon the swap")

# ── Pane labels ─────────────────────────────────────────────────────────

func test_pane_labels_per_type():
	var t1 = _tm.spawn_pane("terminal", {})
	assert_not_null(t1)
	assert_eq(t1.pane_label, "T1", "first terminal should be T1")

	var c1 = _tm.spawn_pane("code_viewer", {})
	assert_not_null(c1)
	assert_eq(c1.pane_label, "C1", "first code viewer should be C1")

	var t2 = _tm.spawn_pane("terminal", {})
	assert_not_null(t2)
	assert_eq(t2.pane_label, "T2", "second terminal should be T2")

func test_pane_labels_reuse_newest_but_not_middle_gaps():
	var t1 = _tm.spawn_pane("terminal", {})
	var t2 = _tm.spawn_pane("terminal", {})
	assert_eq(t1.pane_label, "T1")
	assert_eq(t2.pane_label, "T2")

	# Close the newest: its number is reused.
	_tm.kill(t2)
	var t2b = _tm.spawn_pane("terminal", {})
	assert_not_null(t2b)
	assert_eq(t2b.pane_label, "T2", "newest closed label must be reused")

	# Middle gaps are never filled: T1,T2 exist, close T1, next is T3.
	_tm.kill(t1)
	var t3 = _tm.spawn_pane("terminal", {})
	assert_eq(t3.pane_label, "T3", "middle gap must not be filled")

func test_reset_clears_counters():
	_tm.spawn_pane("terminal", {})
	_tm.spawn_pane("terminal", {})
	_tm.reset()

	var t1 = _tm.spawn_pane("terminal", {})
	assert_not_null(t1)
	assert_eq(t1.pane_label, "T1", "label should restart at T1 after reset")

# ── Settings respect ─────────────────────────────────────────────────

func test_spawn_respects_show_titlebar_false():
	# Given: titlebar setting is off
	SettingsManager.cfg_show_titlebar = false

	# When: spawning a code_viewer pane (no terminal dependency)
	var body = _tm.spawn_pane("code_viewer", {})
	assert_not_null(body)

	# Then: titlebar should be hidden on the wrapper
	var tb = _tm.tiles[0].wrapper.get_node_or_null("BodyVBox/TitleBar")
	assert_not_null(tb, "titlebar node should exist")
	assert_false(tb.visible, "titlebar should be hidden when setting is false")

func test_spawn_respects_show_titlebar_true():
	# Given: titlebar setting is on (default)
	SettingsManager.cfg_show_titlebar = true

	# When: spawning a code_viewer pane
	var body = _tm.spawn_pane("code_viewer", {})
	assert_not_null(body)

	# Then: titlebar should be visible
	var tb = _tm.tiles[0].wrapper.get_node_or_null("BodyVBox/TitleBar")
	assert_not_null(tb, "titlebar node should exist")
	assert_true(tb.visible, "titlebar should be visible when setting is true")
# ── Tile geometry: split / kill / expand ───────────────────────────────
#
# These run the real `spawn_pane` / `kill` against the real tile list. They
# replaced `crates/gpty-core/tests/tile_layout.rs`, which tested a Rust copy of
# this algorithm and so passed whatever this file did. Panes are code viewers —
# no PTY — because only the geometry is under test.

func _spawn_panes(count: int) -> Array:
	var bodies: Array = []
	for i in count:
		var body = _tm.spawn_pane("code_viewer", {})
		assert_not_null(body, "pane %d of %d must fit in the grid" % [i + 1, count])
		bodies.append(body)
	return bodies

func _tile_of(body) -> Dictionary:
	var idx: int = _tm._tile_index_of(body)
	assert_ne(idx, -1, "the pane must still own a tile")
	return _tm.tiles[idx] if idx != -1 else {}

func _rect(tile: Dictionary) -> Array:
	return [tile.col, tile.row, tile.cspan, tile.rspan]

## The tiles must partition the grid: inside it, no tile under MIN_TILE, no two
## overlapping, and — with no overlap — total area equal to the grid's means no
## gap either. Returns a description of the first violation, "" when sound.
func _partition_fault() -> String:
	var fault := _overlap_fault()
	if fault != "":
		return fault
	var g: int = PaneTypes.GRID
	var area := 0
	for t in _tm.tiles:
		area += t.cspan * t.rspan
	if area != g * g:
		return "tiles cover %d of %d units" % [area, g * g]
	return ""

## Bounds, minimum size and overlap only — the part of `_partition_fault` that
## must hold even when a layout cannot be closed up without a hole.
func _overlap_fault() -> String:
	var g: int = PaneTypes.GRID
	for i in _tm.tiles.size():
		var a: Dictionary = _tm.tiles[i]
		if a.col < 0 or a.row < 0 or a.col + a.cspan > g or a.row + a.rspan > g:
			return "tile %s leaves the %d-unit grid" % [_rect(a), g]
		if a.cspan < PaneTypes.MIN_TILE or a.rspan < PaneTypes.MIN_TILE:
			return "tile %s is under MIN_TILE %d" % [_rect(a), PaneTypes.MIN_TILE]
		for j in range(i + 1, _tm.tiles.size()):
			var b: Dictionary = _tm.tiles[j]
			if a.col < b.col + b.cspan and b.col < a.col + a.cspan \
					and a.row < b.row + b.rspan and b.row < a.row + a.rspan:
				return "tiles %s and %s overlap" % [_rect(a), _rect(b)]
	return ""

func _assert_partition(context: String) -> void:
	assert_eq(_partition_fault(), "", "the tiles must partition the grid %s" % context)

## Place the tiles of freshly spawned panes at exact rects, for layouts the
## splitter cannot produce by itself (it only ever halves the largest tile).
## The algorithm reads nothing but geometry, so this is the whole setup.
func _arrange(bodies: Array, rects: Array) -> void:
	for i in bodies.size():
		var tile := _tile_of(bodies[i])
		tile.col = rects[i][0]
		tile.row = rects[i][1]
		tile.cspan = rects[i][2]
		tile.rspan = rects[i][3]
	_assert_partition("the hand-placed starting layout")

func test_the_first_pane_fills_the_grid():
	var bodies := _spawn_panes(1)
	var g: int = PaneTypes.GRID
	assert_eq(_rect(_tile_of(bodies[0])), [0, 0, g, g])

func test_splits_halve_the_largest_tile_along_its_longer_side():
	var g: int = PaneTypes.GRID
	var h: int = g / 2
	var bodies := _spawn_panes(3)
	# A square splits left|right (the first tile keeps the left half) ...
	assert_eq(_rect(_tile_of(bodies[1])), [h, 0, h, g], "the second pane takes the right half")
	# ... and the next split takes the largest tile — now the tall left half,
	# which splits top|bottom.
	assert_eq(_rect(_tile_of(bodies[0])), [0, 0, h, h], "the first pane keeps the top-left")
	assert_eq(_rect(_tile_of(bodies[2])), [0, h, h, h], "the third pane takes the bottom-left")
	_assert_partition("after three splits")

func test_every_split_up_to_the_grid_limit_keeps_a_partition():
	var spawned := 0
	while spawned < 200 and _tm.spawn_pane("code_viewer", {}) != null:
		spawned += 1
		assert_eq(_partition_fault(), "", "after %d panes" % spawned)
	assert_between(spawned, 4, 199, "the grid must hold several panes and then refuse")
	assert_eq(_tm.tiles.size(), spawned)

func test_a_refused_split_leaves_the_layout_untouched():
	while _tm.tiles.size() < 200 and _tm.spawn_pane("code_viewer", {}) != null:
		pass
	assert_lt(_tm.tiles.size(), 200, "the grid must fill and refuse before 200 panes")
	var before: Array = []
	for t in _tm.tiles:
		before.append(_rect(t))
	assert_null(_tm.spawn_pane("code_viewer", {}), "a full grid must refuse another pane")
	var after: Array = []
	for t in _tm.tiles:
		after.append(_rect(t))
	assert_eq(after, before, "a refused split must not move or resize any tile")
	_assert_partition("after the refused split")

func test_killing_either_half_of_a_pair_gives_the_survivor_the_grid():
	var g: int = PaneTypes.GRID
	for victim_index in [0, 1]:
		_tm.reset()
		var bodies := _spawn_panes(2)
		_tm.kill(bodies[victim_index])
		assert_eq(_tm.tiles.size(), 1)
		assert_eq(_rect(_tile_of(bodies[1 - victim_index])), [0, 0, g, g],
			"the survivor must grow to the whole grid (killed pane %d)" % victim_index)

func test_killing_a_stacked_tile_grows_its_partner_vertically():
	# Three panes: top-left, bottom-left, and a full-height right half.
	var g: int = PaneTypes.GRID
	var h: int = g / 2
	var bodies := _spawn_panes(3)
	_tm.kill(bodies[2])
	assert_eq(_rect(_tile_of(bodies[0])), [0, 0, h, g], "the tile above grows down over the gap")
	assert_eq(_rect(_tile_of(bodies[1])), [h, 0, h, g], "the other half is not disturbed")
	_assert_partition("after closing the bottom-left pane")

func test_killing_a_full_height_tile_stretches_every_neighbour_across():
	# No single neighbour matches the victim's edge, so the partial path must
	# widen *both* tiles that touch it.
	var g: int = PaneTypes.GRID
	var h: int = g / 2
	var bodies := _spawn_panes(3)
	_tm.kill(bodies[1])  # the full-height right half
	assert_eq(_rect(_tile_of(bodies[0])), [0, 0, g, h], "top-left stretches to full width")
	assert_eq(_rect(_tile_of(bodies[2])), [0, h, g, h], "bottom-left stretches to full width")
	_assert_partition("after closing the full-height pane")

func test_killing_a_left_tile_pulls_the_right_neighbours_across_it():
	# A full-height left strip, with two stacked tiles on the right: the right
	# tiles must move *left* to take the strip's place.
	var g: int = PaneTypes.GRID
	var strip := g / 5
	var top_h := g / 2
	var bodies := _spawn_panes(3)
	_arrange(bodies, [
		[0, 0, strip, g],
		[strip, 0, g - strip, top_h],
		[strip, top_h, g - strip, g - top_h],
	])
	_tm.kill(bodies[0])
	assert_eq(_rect(_tile_of(bodies[1])), [0, 0, g, top_h])
	assert_eq(_rect(_tile_of(bodies[2])), [0, top_h, g, g - top_h])
	_assert_partition("after closing the left strip")

func test_killing_a_top_tile_pulls_the_lower_neighbours_up_across_it():
	var g: int = PaneTypes.GRID
	var band := g / 5
	var half := g / 2
	var bodies := _spawn_panes(3)
	_arrange(bodies, [
		[0, 0, g, band],
		[0, band, half, g - band],
		[half, band, g - half, g - band],
	])
	_tm.kill(bodies[0])
	assert_eq(_rect(_tile_of(bodies[1])), [0, 0, half, g])
	assert_eq(_rect(_tile_of(bodies[2])), [half, 0, g - half, g])
	_assert_partition("after closing the top band")

## Closing the middle of three columns, each side split in two: the tiles on
## *both* sides touch the freed strip. The old code stretched both groups
## across it, so they overlapped each other — found by the oldest-first close
## order below, which reached this shape after four closes.
func test_closing_a_strip_with_tiles_on_both_sides_is_absorbed_by_one_side_only():
	var g: int = PaneTypes.GRID
	var third := g / 3
	var half := g / 2
	var bodies := _spawn_panes(5)
	_arrange(bodies, [
		[0, 0, third, half],              # left, top
		[0, half, third, g - half],       # left, bottom
		[third, 0, third, g],             # the strip that closes
		[2 * third, 0, g - 2 * third, half],
		[2 * third, half, g - 2 * third, g - half],
	])
	_tm.kill(bodies[2])
	_assert_partition("after closing the middle strip")
	assert_eq(_rect(_tile_of(bodies[0])), [0, 0, 2 * third, half],
		"the left group takes the strip")
	assert_eq(_rect(_tile_of(bodies[1])), [0, half, 2 * third, g - half])
	assert_eq(_rect(_tile_of(bodies[3])), [2 * third, 0, g - 2 * third, half],
		"the right group must not also stretch across it")
	assert_eq(_rect(_tile_of(bodies[4])), [2 * third, half, g - 2 * third, g - half])

## A tile whose right edge merely lines up with the freed tile's left edge, in
## a different row band, is not a neighbour and must not be stretched.
func test_a_tile_that_only_shares_a_coordinate_is_not_stretched():
	var g: int = PaneTypes.GRID
	var h := g / 2
	var q := g / 4
	var bodies := _spawn_panes(6)
	_arrange(bodies, [
		[0, 0, h, q],                # L1 — beside the freed tile
		[0, q, h, h - q],            # L2 — beside the freed tile
		[h, 0, h, h],                # R  — the one that closes (split below it)
		[0, h, h, h],                # E  — right edge lines up with R's left edge, rows do not
		[h, h, q, h],                # D1 — under R
		[h + q, h, g - h - q, h],    # D2 — under R
	])
	_tm.kill(bodies[2])
	_assert_partition("after closing the top-right tile")
	assert_eq(_rect(_tile_of(bodies[0])), [0, 0, g, q], "L1 takes the freed width")
	assert_eq(_rect(_tile_of(bodies[1])), [0, q, g, h - q], "L2 takes the freed width")
	assert_eq(_rect(_tile_of(bodies[3])), [0, h, h, h],
		"E shares only a column coordinate with the freed tile and must not move")

## Layouts the splitter cannot make (a hand-edited profile) may have a freed
## rect no group of tiles can absorb. Stacking one tile over the rest would
## hide panes behind each other, so the hole stays and nothing overlaps.
func test_a_hole_no_tiles_can_absorb_is_left_open_rather_than_overlapped():
	var g: int = PaneTypes.GRID
	var u := g / 3  # a pinwheel of four arms around a centre tile
	var bodies := _spawn_panes(5)
	_arrange(bodies, [
		[0, 0, 2 * u, u],
		[2 * u, 0, u, 2 * u],
		[u, 2 * u, 2 * u, u],
		[0, u, u, 2 * u],
		[u, u, u, u],                # the centre — no arm lies within its edges
	])
	_tm.kill(bodies[4])
	assert_eq(_tm.tiles.size(), 4)
	assert_eq(_overlap_fault(), "", "an unabsorbable hole must not become an overlap")
	assert_eq(_rect(_tile_of(bodies[0])), [0, 0, 2 * u, u], "the arms keep their places")
	assert_eq(_rect(_tile_of(bodies[2])), [u, 2 * u, 2 * u, u])

func test_every_close_order_of_five_panes_keeps_a_partition():
	var checked := 0
	for order in _permutations([0, 1, 2, 3, 4]):
		_tm.reset()
		var bodies := _spawn_panes(5)
		for i in 4:
			_tm.kill(bodies[order[i]])
			var fault := _partition_fault()
			if fault != "":
				assert_eq(fault, "", "closing panes in order %s, after close %d" % [order, i + 1])
				return
		checked += 1
	assert_eq(checked, 120, "all 5! close orders were exercised")

func _permutations(items: Array) -> Array:
	if items.size() <= 1:
		return [items.duplicate()]
	var out: Array = []
	for i in items.size():
		var rest := items.duplicate()
		var head = rest.pop_at(i)
		for tail in _permutations(rest):
			out.append([head] + tail)
	return out

func test_closing_panes_in_any_order_never_leaves_a_gap_or_overlap():
	# Build eight panes, then close them in three different orders; the
	# partition must hold after every single close.
	for order in ["newest_first", "oldest_first", "middle_out"]:
		_tm.reset()
		var bodies := _spawn_panes(8)
		var queue: Array = bodies.duplicate()
		var step := 0
		while queue.size() > 1:
			var pick: int = 0
			match order:
				"newest_first": pick = queue.size() - 1
				"oldest_first": pick = 0
				"middle_out": pick = queue.size() / 2
			_tm.kill(queue.pop_at(pick))
			step += 1
			assert_eq(_partition_fault(), "",
				"%s: after closing %d of 8 panes" % [order, step])
		assert_eq(_tm.tiles.size(), 1)
		var g: int = PaneTypes.GRID
		assert_eq(_rect(_tile_of(queue[0])), [0, 0, g, g],
			"%s: the last pane must own the whole grid" % order)

# ── Saved-layout grid unit migration ───────────────────────────────────

func test_scale_layout_converts_a_legacy_grid():
	# A 12-unit layout (before the grid was refined) always spans 12, which is
	# how the unit is inferred with no marker in the payload.
	var legacy := [
		{"col": 0, "row": 0, "cspan": 7, "rspan": 12},
		{"col": 7, "row": 0, "cspan": 5, "rspan": 6},
		{"col": 7, "row": 6, "cspan": 5, "rspan": 6},
	]
	var scaled: Array = TerminalManager.scale_layout(legacy)
	var g: int = PaneTypes.GRID
	assert_eq(scaled[0]["cspan"], int(round(7.0 / 12.0 * g)), "shares must survive")
	assert_eq(scaled[0]["rspan"], g, "a full-height pane stays full height")
	assert_eq(scaled[0]["col"] + scaled[0]["cspan"], scaled[1]["col"],
		"neighbours must still meet exactly")

func test_scale_layout_leaves_current_geometry_alone():
	var current := [{"col": 0, "row": 0, "cspan": PaneTypes.GRID, "rspan": PaneTypes.GRID}]
	assert_eq(TerminalManager.scale_layout(current), current,
		"geometry already in the current unit must not be rescaled")

func test_scale_layout_prefers_a_declared_unit():
	var legacy := [{"col": 0, "row": 0, "cspan": 12, "rspan": 12}]
	var same: Array = TerminalManager.scale_layout(legacy, PaneTypes.GRID)
	assert_eq(same[0]["cspan"], 12,
		"a declared unit of 60 means the payload is already in grid units")
