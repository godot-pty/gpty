extends GutTest
# The terminal font loader reads bytes, never a resource loader.
#
# `res://tests/fixtures/evil_font.tres` executes an embedded GDScript when a
# resource loader reads it (it writes the path in `GPTY_EXPLOIT_SENTINEL`).
# Every refusal below is asserted twice: the bundled font came back AND the
# sentinel never appeared. `test_the_fixture_really_executes_on_load` keeps the
# second half from becoming vacuous - it loads the fixture's `res://` path on
# purpose, which is a different loader cache key from the absolute path the
# refusals use.

const BUNDLED := "res://fonts/DejaVuSansMono.ttf"
const EVIL_RES := "res://tests/fixtures/evil_font.tres"

var _sentinel: String
var _previous_env: String

func before_each():
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

func _abs(pretty_path: String) -> String:
	return ProjectSettings.globalize_path(pretty_path)

func _write(path: String, bytes: PackedByteArray):
	var f := FileAccess.open(path, FileAccess.WRITE)
	assert_not_null(f, "the test must be able to write its fixture")
	f.store_buffer(bytes)
	f.close()

func test_the_fixture_really_executes_on_load():
	# Guards the guards: without this, a fixture that stopped executing would
	# make every refusal pass while proving nothing. The res:// path is loaded
	# here only; the tests below use the absolute path.
	assert_not_null(load(EVIL_RES), "the fixture must be a loadable resource")
	assert_true(FileAccess.file_exists(_sentinel), "loading the fixture must execute it")

func test_a_valid_font_file_is_read_as_bytes():
	var f := TerminalFonts.load_for(_abs(BUNDLED), BUNDLED)
	assert_eq(f.resource_path, "", "a data font is built from bytes, not a loader")
	assert_eq(f.get_face_count(), 1, "the bundled DejaVu face must parse")
	assert_string_contains(f.get_font_name(), "DejaVu Sans Mono")
	assert_false(FileAccess.file_exists(_sentinel))

func test_a_resource_file_never_reaches_a_loader():
	var f := TerminalFonts.load_for(_abs(EVIL_RES), BUNDLED)
	assert_eq(f.resource_path, BUNDLED, "a .tres must fall back to the bundled font")
	assert_false(FileAccess.file_exists(_sentinel),
		"the fallback path must not load the resource")

func test_a_missing_file_falls_back():
	assert_eq(TerminalFonts.load_for("/no/such/font.ttf", BUNDLED).resource_path, BUNDLED)
	assert_false(FileAccess.file_exists(_sentinel))

func test_a_res_path_is_not_a_data_path():
	# Only compile-time bundled constants are res://; a data value naming one
	# still resolves to the trusted fallback, never to the named resource.
	assert_eq(TerminalFonts.load_for(BUNDLED, BUNDLED).resource_path, BUNDLED)
	assert_eq(TerminalFonts.load_for("res://fonts/DejaVuSansMono-Bold.ttf", BUNDLED).resource_path, BUNDLED)

func test_junk_bytes_with_a_font_extension_fall_back():
	var junk := _abs("user://gpty_junk_font.ttf")
	_write(junk, "definitely not a font".to_utf8_buffer())
	assert_eq(TerminalFonts.load_for(junk, BUNDLED).resource_path, BUNDLED)
	DirAccess.remove_absolute(junk)
	assert_false(FileAccess.file_exists(_sentinel))

func test_a_resource_disguised_as_a_font_falls_back():
	# The bytes of the exploit fixture under a .ttf name: the extension gate
	# passes, the magic gate must refuse it before FreeType sees it.
	var disguised := _abs("user://gpty_disguised.ttf")
	_write(disguised, FileAccess.get_file_as_bytes(EVIL_RES))
	assert_eq(TerminalFonts.load_for(disguised, BUNDLED).resource_path, BUNDLED)
	DirAccess.remove_absolute(disguised)
	assert_false(FileAccess.file_exists(_sentinel))

func test_only_the_loader_extensions_are_fonts():
	assert_true(PaneTypes.font_extension_ok("/fonts/x.ttf"))
	assert_true(PaneTypes.font_extension_ok("/fonts/x.OTF"))
	assert_true(PaneTypes.font_extension_ok("/fonts/x.ttc"))
	assert_true(PaneTypes.font_extension_ok("/fonts/x.woff"))
	assert_true(PaneTypes.font_extension_ok("/fonts/x.woff2"))
	assert_false(PaneTypes.font_extension_ok("/fonts/x.tres"), "a resource is not a font")
	assert_false(PaneTypes.font_extension_ok("/fonts/x.png"))
	assert_false(PaneTypes.font_extension_ok("/fonts/x"))
	assert_string_contains(PaneTypes.font_filter(), "*.ttf")
