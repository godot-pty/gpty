extends GutTest
# A workspace, profile or settings file must never make the GUI `load()` a
# resource. `res://tests/fixtures/evil_font.tres` runs an embedded GDScript
# when a resource loader reads it (it writes `GPTY_EXPLOIT_SENTINEL`).
#
# Every test here drives the *real* path - `Workspace._restore_into` for a
# tile, `ProfileManager` + restore for a profile, `SettingsManager` + spawn
# for settings.json - and asserts the bundled font came out and the sentinel
# never appeared. Before the fix a tile's `font_bold_path` (never saved, but
# settable through the old open property path) reached `load()` here.

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

const BUNDLED := "res://fonts/DejaVuSansMono.ttf"
const BUNDLED_BOLD := "res://fonts/DejaVuSansMono-Bold.ttf"
const BUNDLED_ITALIC := "res://fonts/DejaVuSansMono-Oblique.ttf"
const EVIL_RES := "res://tests/fixtures/evil_font.tres"

var _ws: Control
var _sentinel: String
var _previous_env: String
var _saved_font_path: String
var _saved_scheme_path: String

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()
	SettingsManager.cfg_default_rows = 24
	SettingsManager.cfg_default_cols = 80
	_saved_font_path = SettingsManager.cfg_font_path
	_saved_scheme_path = SettingsManager.cfg_color_scheme_path
	_previous_env = OS.get_environment("GPTY_EXPLOIT_SENTINEL")
	_sentinel = ProjectSettings.globalize_path("user://gpty_exploit_sentinel.txt")
	OS.set_environment("GPTY_EXPLOIT_SENTINEL", _sentinel)
	DirAccess.remove_absolute(_sentinel)

func after_each():
	DirAccess.remove_absolute(_sentinel)
	if _previous_env == "":
		OS.unset_environment("GPTY_EXPLOIT_SENTINEL")
	else:
		OS.set_environment("GPTY_EXPLOIT_SENTINEL", _previous_env)
	SettingsManager.cfg_font_path = _saved_font_path
	SettingsManager.cfg_color_scheme_path = _saved_scheme_path
	if _ws:
		if _ws.get_parent():
			_ws.get_parent().remove_child(_ws)
		_ws.free()
		_ws = null
	MockAutoloads.teardown()

func _evil_path() -> String:
	return ProjectSettings.globalize_path(EVIL_RES)

func _make_workspace() -> Control:
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame
	return ws

func _restore(settings: Dictionary) -> Control:
	var ws := await _make_workspace()
	var tiles: Array[Dictionary] = [{
		"col": 0, "row": 0, "cspan": PaneTypes.GRID, "rspan": PaneTypes.GRID,
		"settings": settings,
	}]
	ws._restore_into(ws._workspaces[0], tiles)
	return ws._tm._find_body(ws._tm.tiles[0].wrapper)

## The bundled faces, and no code executed.
func _assert_bundled(body: Control):
	assert_true(body is TerminalPane, "the tile must restore as a terminal")
	assert_eq(body._font.resource_path, BUNDLED, "the base face must be the bundled font")
	assert_eq(body._font_bold.resource_path, BUNDLED_BOLD, "the bold face must be bundled")
	assert_eq(body._font_italic.resource_path, BUNDLED_ITALIC, "the italic face must be bundled")
	assert_false(FileAccess.file_exists(_sentinel),
		"no pane path may load the crafted resource")

func test_a_layout_tile_cannot_choose_a_font_to_load():
	var body := await _restore({
		"type": "terminal",
		"font_path": _evil_path(),
		"font_bold_path": _evil_path(),
		"font_italic_path": _evil_path(),
	})
	_assert_bundled(body)

func test_a_tile_font_path_still_chooses_the_font():
	# The refusals above must not amount to "custom fonts never load": a real
	# font file the user (or their layout) chose is used, built from bytes.
	var bold := ProjectSettings.globalize_path("res://fonts/DejaVuSansMono-Bold.ttf")
	var body := await _restore({"type": "terminal", "font_path": bold})
	assert_true(body is TerminalPane)
	assert_eq(body._font.resource_path, "", "a chosen font is built from bytes")
	assert_eq(body._font.get_font_style_name(), "Bold",
		"the tile's font must be the face the pane draws with")
	assert_false(FileAccess.file_exists(_sentinel))

func test_a_profile_tile_cannot_choose_a_font_to_load():
	var evil := _evil_path()
	ProfileManager.add_profile("Exploit font", [{
		"col": 0, "row": 0, "cspan": PaneTypes.GRID, "rspan": PaneTypes.GRID,
		"settings": {"type": "terminal", "font_path": evil, "font_bold_path": evil},
	}])
	var profile := ProfileManager.find_profile("Exploit font")
	assert_false(profile.is_empty(), "the profile must survive the store round-trip")
	var ws := await _make_workspace()
	ws._restore_into(ws._workspaces[0], profile.get("tiles", []))
	var body = ws._tm._find_body(ws._tm.tiles[0].wrapper)
	_assert_bundled(body)

	# Drop the probe profile again so the store keeps what the other tests see.
	var profiles := ProfileManager.get_all_profiles()
	for i in profiles.size():
		if str(profiles[i].get("name", "")) == "Exploit font":
			ProfileManager.delete_profile(i)
			break

func test_settings_json_cannot_choose_a_font_to_load():
	# settings.json is the live vector: `cfg_font_path` is applied to every
	# terminal through `apply_to_terminal`, before the old loader ran.
	SettingsManager.cfg_font_path = _evil_path()
	var ws := await _make_workspace()
	var startup = ws._tm._find_body(ws._tm.tiles[0].wrapper)
	_assert_bundled(startup)
	var spawned = ws._spawn_pane("terminal", {})
	_assert_bundled(spawned)

func test_settings_json_scheme_is_read_not_loaded():
	SettingsManager.cfg_color_scheme_path = _evil_path()
	var _ws_unused := await _make_workspace()
	assert_false(FileAccess.file_exists(_sentinel),
		"a scheme path is a capped text read, never a resource load")
