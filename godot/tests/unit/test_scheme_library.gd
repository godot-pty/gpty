extends GutTest
# SchemeLibrary — the shipped and imported schemes, the capped read, the import
# copy and the id rule. The parsers themselves are Rust tests
# (`gpty_core::scheme`); this file pins the Godot-side contract: what the
# picker lists, and that an import lands as a native file under the user dir.

var _temp_dir := ""

func before_each():
	MockAutoloads.setup()
	_temp_dir = OS.get_temp_dir().path_join("gpty-schemes-%s" % Crypto.new().generate_random_bytes(4).hex_encode())
	DirAccess.make_dir_recursive_absolute(_temp_dir)
	SchemeLibrary.user_dir = _temp_dir
	SchemeLibrary.reset()

func after_each():
	SchemeLibrary.user_dir = SchemeLibrary.USER_DIR
	SchemeLibrary.reset()
	_remove_dir_recursive(_temp_dir)
	MockAutoloads.teardown()

func _remove_dir_recursive(dir: String) -> void:
	var access := DirAccess.open(dir)
	if access == null:
		return
	for file_name in access.get_files():
		access.remove(file_name)
	DirAccess.remove_absolute(dir)

func _write_source(name: String, body: String) -> String:
	var path := OS.get_temp_dir().path_join(name)
	var file := FileAccess.open(path, FileAccess.WRITE)
	assert_not_null(file, "the temp scheme fixture must be writable")
	if file != null:
		file.store_string(body)
		file.close()
	return path

func _native_body(name: String) -> String:
	var palette := PackedStringArray()
	for i in range(16):
		palette.append("#%02x%02x%02x" % [i, i, i])
	return JSON.stringify({
		"name": name, "palette": palette, "foreground": "#abcdef",
		"background": "#123456", "cursor": "#e0e0e0", "selection": "#445566",
	})

func test_list_includes_the_shipped_schemes():
	var ids := {}
	for entry in SchemeLibrary.list():
		ids[str(entry.id)] = true
	for wanted in ["dracula", "nord", "tokyo-night", "one-light",
			"solarized-light", "gruvbox-dark", "catppuccin-mocha"]:
		assert_true(ids.has(wanted), "%s must ship" % wanted)

func test_an_import_writes_a_native_copy_and_reports_its_path():
	var source := _write_source("probe-import.json", _native_body("Probe Import"))
	var result := SettingsManager.import_scheme(source)
	DirAccess.remove_absolute(source)
	assert_eq(result.get("ok"), true, str(result.get("error", "")))
	var target := str(result.get("path", ""))
	assert_eq(target, SchemeLibrary.user_dir.path_join("probe-import.json"),
		"the copy is named from the sanitised scheme name")
	var written := str(MockAutoloads.get_store("text:" + target))
	assert_ne(written, "", "the copy is written through the store writer")
	var parsed = JSON.parse_string(written)
	assert_true(parsed is Dictionary, "the copy is native JSON")
	assert_eq(parsed.get("name"), "Probe Import")
	assert_eq(parsed.get("palette").size(), 16)

func test_an_unparseable_import_is_refused_and_reports_the_parser_sentence():
	var source := _write_source("not-a-scheme.txt", "hello, world")
	var result := SettingsManager.import_scheme(source)
	DirAccess.remove_absolute(source)
	assert_eq(result.get("ok"), false)
	assert_string_contains(str(result.get("error", "")), "not an Alacritty",
		"the parser's own sentence reaches the user")

func test_unique_user_id_appends_a_suffix_when_the_name_is_taken():
	var taken := SchemeLibrary.user_dir.path_join("probe.json")
	var file := FileAccess.open(taken, FileAccess.WRITE)
	assert_not_null(file)
	if file != null:
		file.store_string("{}")
		file.close()
	assert_eq(SchemeLibrary.unique_user_id("probe"), "probe-2")
	assert_eq(SchemeLibrary.unique_user_id("A Scheme /  Name!"), "a-scheme-name",
		"an id is lowercase ASCII words joined by hyphens")

func test_a_loaded_scheme_carries_the_six_keys():
	var scheme := SchemeLibrary.loaded("res://schemes/nord.json")
	assert_false(scheme.is_empty(), "a shipped native scheme loads")
	assert_eq(scheme.get("name"), "Nord")
	assert_eq(scheme.get("palette").size(), 16)
	assert_eq(SchemeLibrary.color(scheme, "background", Color.BLACK).to_html(false),
		"2e3440")
	assert_eq(SchemeLibrary.color(scheme, "missing", Color.BLACK), Color.BLACK,
		"a missing key keeps the caller's fallback")
