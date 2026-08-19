extends GutTest
# Integration tests: pane creation via TerminalManager with mock autoloads.
# Verifies that pane types, title labels, and options are wired correctly.

var _scene: Control
var _tm: TerminalManager

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = "/bin/sh"
	SettingsManager.cfg_default_rows = 24
	SettingsManager.cfg_default_cols = 80
	_scene = TestScene.create()
	add_child(_scene)
	_tm = TerminalManager.new()

func after_each():
	# Free wrapper nodes synchronously; they're not in the scene tree
	# (TerminalManager creates them but our test has no grid parent).
	for t in _tm.tiles:
		if t.wrapper:
			t.wrapper.free()
	_tm.tiles.clear()
	_tm.last_body = null
	MockAutoloads.teardown()
	if _scene:
		remove_child(_scene)
		_scene.free()

# ── Spawn terminal via TerminalManager ─────────────────────────────────

func test_spawn_terminal_creates_body():
	var body = _tm.spawn()
	assert_not_null(body, "spawn should return a body")
	assert_eq(_tm.tiles.size(), 1, "tiles should have 1 entry")
	var wrapper = _tm.tiles[0].wrapper
	assert_not_null(wrapper, "wrapper should exist")

	# Title bar label should contain "Terminal"
	var lbl = wrapper.get_node_or_null("BodyVBox/TitleBar/TitleLabel")
	assert_not_null(lbl, "title label should exist")
	assert_string_contains(lbl.text, "Terminal")

func test_spawn_terminal_body_is_terminal_pane():
	var body = _tm.spawn()
	assert_true(body is TerminalPane, "body should be TerminalPane")

# ── Spawn all pane types ───────────────────────────────────────────────

func test_spawn_all_pane_types():
	# Verify each pane type via _pane_type() discriminator.
	var expected := ["terminal", "code_viewer", "file_tree", "inspector", "reasoning"]
	for type_name in expected:
		_tm.reset()
		var body = _tm.spawn_pane(type_name, {})
		assert_not_null(body, "spawn_pane(%s) should return a body" % type_name)
		assert_eq(body._pane_type(), type_name, "body._pane_type() should be %s" % type_name)

func test_spawn_applies_rows_cols():
	var body = _tm.spawn_pane("terminal", {"rows": 30, "cols": 100})
	assert_not_null(body)
	# rows/cols are set on the body but may be overridden by resize
	# Just check they were applied initially
	assert_eq(body.rows, 30, "rows should be applied")
	assert_eq(body.cols, 100, "cols should be applied")

func test_spawn_sets_title_label():
	var body = _tm.spawn_pane("code_viewer", {})
	assert_not_null(body)
	var wrapper = _tm.tiles[-1].wrapper
	var lbl = wrapper.get_node_or_null("BodyVBox/TitleBar/TitleLabel")
	assert_not_null(lbl)
	assert_string_contains(lbl.text, "Code Viewer")

func test_pane_name_overrides_title():
	var body = _tm.spawn_pane("terminal", {"pane_name": "MyTerm", "title_label": "MyTerm"})
	assert_not_null(body)
	var wrapper = _tm.tiles[-1].wrapper
	var lbl = wrapper.get_node_or_null("BodyVBox/TitleBar/TitleLabel")
	assert_not_null(lbl)
	# The title label shows the title_label from opts
	assert_string_contains(lbl.text, "MyTerm")


# ── Swap via TerminalManager ──────────────────────────────────────────

func test_swap_pane_preserves_tile():
	var body = _tm.spawn_pane("terminal", {"pane_name": "Before"})
	assert_not_null(body)
	assert_eq(_tm.tiles.size(), 1)

	_tm.on_swap = func(b: Control, t: String):
		_tm.swap_pane(b, t)

	# Simulate what _handle_swap does
	_tm.on_swap.call(body, "code_viewer")

	assert_eq(_tm.tiles.size(), 1, "tiles should still have 1 entry after swap")
	var new_body = _tm._find_body(_tm.tiles[0].wrapper)
	assert_not_null(new_body, "new body should exist in tile")
	assert_eq(new_body._pane_type(), "code_viewer", "swapped body should be code_viewer")
	assert_eq(new_body.pane_name, "Before", "pane_name should be preserved across swap")

# ── Pane labels ─────────────────────────────────────────────────────────

func test_pane_labels_have_correct_prefixes():
	# Verify each pane type gets the right prefix on pane_label
	var cases := {
		"terminal": "T", "code_viewer": "C", "file_tree": "F",
		"inspector": "I", "reasoning": "R",
	}
	for type_name in cases:
		_tm.reset()
		var body = _tm.spawn_pane(type_name, {})
		assert_not_null(body, "spawn_pane(%s) should return a body" % type_name)
		var expected_label = cases[type_name] + "1"
		assert_eq(body.pane_label, expected_label,
			"%s should have label %s, got %s" % [type_name, expected_label, body.pane_label])