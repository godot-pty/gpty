extends GutTest
# Unit tests for TerminalManager — spawn/kill/tile logic.
# No UI rendering; tests pure RefCounted logic.

const CannedShell := "/bin/sh"

var _tm: TerminalManager

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = CannedShell
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
	for key in ["terminal", "code_viewer", "file_tree", "observer"]:
		var body = _tm.create_body(key)
		assert_not_null(body, "create_body(%s) should return non-null" % key)

func test_spawn_pane_uses_default_shell():
	# spawn_pane applies global settings to fresh terminal bodies, so the
	# shell defaults to cfg_shell_command (mocked to "/bin/sh" in before_each).
	var body = _tm.spawn_pane("terminal", {})
	assert_not_null(body)
	assert_eq(body.shell_command, CannedShell)

# ── Kill ────────────────────────────────────────────────────────────────

func test_kill_removes_tile():
	var body = _tm.spawn()
	assert_eq(_tm.tiles.size(), 1)
	_tm.kill(body)
	assert_eq(_tm.tiles.size(), 0, "tiles should be empty after kill")

# kill_last and last_body tracking is done by Workspace, not TerminalManager.
# TerminalManager.kill_last() only calls kill() — it doesn't manage last_body.

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
	# Fill the grid: keep spawning until the split algorithm refuses.
	# With GRID=12, MIN_TILE=2, maximum tiles = (12/2)*(12/2) = 36.
	# Safety cap at 50 in case of logic changes.
	var count := 0
	while count < 50:
		var body = _tm.spawn()
		if body == null:
			break
		count += 1
	assert_gt(count, 0, "should have spawned at least one tile")
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

func test_pane_labels_persist_after_kill():
	var t1 = _tm.spawn_pane("terminal", {})
	var t2 = _tm.spawn_pane("terminal", {})
	assert_eq(t1.pane_label, "T1")
	assert_eq(t2.pane_label, "T2")

	_tm.kill(t1)
	_tm.kill(t2)
	assert_eq(_tm.tiles.size(), 0)

	var t3 = _tm.spawn_pane("terminal", {})
	assert_not_null(t3)
	assert_eq(t3.pane_label, "T3", "label should be T3, not recycled T1")

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