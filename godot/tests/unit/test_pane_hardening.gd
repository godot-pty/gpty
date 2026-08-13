extends GutTest
# Unit tests for layout/tile sanitization (PaneTypes helpers) and typed
# pane settings application. No GDExtension classes required.

var _scene: Control

func before_each():
	MockAutoloads.setup()
	_scene = TestScene.create()
	add_child(_scene)

func after_each():
	for c in _scene.get_children():
		_scene.remove_child(c)
		c.free()
	MockAutoloads.teardown()
	if _scene:
		remove_child(_scene)
		_scene.free()

# ── PaneTypes.clamp_grid_int ───────────────────────────────────────────

func test_clamp_grid_int_non_numeric_yields_lo():
	assert_eq(PaneTypes.clamp_grid_int("x", 0, 11), 0)
	assert_eq(PaneTypes.clamp_grid_int(null, 0, 11), 0)

func test_clamp_grid_int_clamps_range():
	assert_eq(PaneTypes.clamp_grid_int(-5, 0, 11), 0)
	assert_eq(PaneTypes.clamp_grid_int(99, 0, 11), 11)
	assert_eq(PaneTypes.clamp_grid_int(4.7, 0, 11), 4)

# ── PaneTypes.sanitize_tile ────────────────────────────────────────────

func test_sanitize_tile_rejects_non_dictionary():
	assert_eq(PaneTypes.sanitize_tile("not-a-dict"), {})

func test_sanitize_tile_rejects_non_dict_settings():
	assert_eq(PaneTypes.sanitize_tile({"settings": "not-a-dict"}), {})

func test_sanitize_tile_rejects_unknown_type():
	assert_eq(PaneTypes.sanitize_tile({"settings": {"type": "teleporter"}}), {})

func test_sanitize_tile_clamps_bad_geometry():
	var st = PaneTypes.sanitize_tile({
		"settings": {"type": "terminal"},
		"col": "x", "row": -3, "cspan": 99, "rspan": 0,
	}, 12)
	assert_eq(st["col"], 0)
	assert_eq(st["row"], 0)
	assert_eq(st["cspan"], 12)
	assert_eq(st["rspan"], 1)

func test_sanitize_tile_keeps_cspan_within_grid():
	var st = PaneTypes.sanitize_tile({
		"settings": {"type": "code_viewer"},
		"col": 10, "row": 0, "cspan": 12, "rspan": 12,
	}, 12)
	assert_eq(st["col"], 10)
	assert_eq(st["cspan"], 2)
	assert_eq(st["rspan"], 12)

func test_sanitize_tile_roundtrips_valid_tile():
	var st = PaneTypes.sanitize_tile({
		"settings": {"type": "file_tree", "root_path": "/tmp"},
		"col": 0, "row": 0, "cspan": 6, "rspan": 12,
	}, 12)
	assert_eq(st["type_name"], "file_tree")
	assert_eq(st["settings"]["root_path"], "/tmp")
	assert_eq(st["cspan"], 6)
	assert_eq(st["rspan"], 12)

# ── PaneTypes.sanitize_shell ───────────────────────────────────────────

func test_sanitize_shell_accepts_valid_string():
	assert_eq(PaneTypes.sanitize_shell("/bin/zsh", "/bin/bash"), "/bin/zsh")

func test_sanitize_shell_falls_back_on_bad_values():
	assert_eq(PaneTypes.sanitize_shell(null, "/bin/bash"), "/bin/bash")
	assert_eq(PaneTypes.sanitize_shell("sh\u0000rm", "/bin/bash"), "/bin/bash")
	assert_eq(PaneTypes.sanitize_shell("", "/bin/bash"), "/bin/bash")

func test_sanitize_shell_rejects_nul_and_oversized():
	assert_eq(PaneTypes.sanitize_shell("sh\u0000rm", "/bin/bash"), "/bin/bash")
	var long: String = "x".repeat(2048)
	assert_eq(PaneTypes.sanitize_shell(long, "/bin/bash"), "/bin/bash")

# ── PaneBody typed settings application ────────────────────────────────

func test_pane_body_ignores_unknown_and_bad_type_keys():
	var body = PaneBody.new()
	_scene.add_child(body)
	body.font_size = 14
	body.pane_name = "keep"
	body.apply_settings({"font_size": "big", "pane_name": 99, "bogus": true})
	assert_eq(body.font_size, 14)
	assert_eq(body.pane_name, "keep")
