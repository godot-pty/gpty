extends GutTest
# Wiki pane: the read-only vault browser — vault validation, the recursive
# .md scan (hidden skip, depth cap, entry cap), the note render, and the
# layout-state round trip.

var _tmp: String


func before_each():
	MockAutoloads.setup()
	_tmp = ProjectSettings.globalize_path("user://wiki_probe_vault")
	DirAccess.make_dir_recursive_absolute(_tmp)


func after_each():
	_remove_tree(_tmp)
	MockAutoloads.teardown()


func _remove_tree(path: String):
	var dir := DirAccess.open(path)
	if dir:
		for f in dir.get_files():
			DirAccess.remove_absolute(path.path_join(f))
		for d in dir.get_directories():
			_remove_tree(path.path_join(d))
	DirAccess.remove_absolute(path)


func _write(path: String, text: String) -> String:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	return path


func _make_pane(vault: String) -> WikiPane:
	var pane := WikiPane.new()
	pane.vault_path = vault
	# vault_path is set before add_child so _ready performs the scan.
	add_child_autofree(pane)
	return pane


func _list_texts(pane: WikiPane) -> Array:
	var out := []
	for i in pane._list.item_count:
		out.append(pane._list.get_item_text(i))
	return out


func test_pane_type_is_wiki():
	var pane := _make_pane("")
	assert_eq(pane._pane_type(), "wiki")


func test_unset_vault_shows_placeholder():
	var pane := _make_pane("")
	assert_true(pane._placeholder.visible)
	assert_false(pane._list.visible)
	assert_eq(pane._list.item_count, 0)


func test_a_non_directory_vault_is_refused():
	_write(_tmp.path_join("note.md"), "# hi")
	# A regular file is not a vault, and neither is a relative path; the typed
	# value stays (file_tree's rule) so the settings field keeps the typo.
	var file_pane := _make_pane(_tmp.path_join("note.md"))
	assert_true(file_pane._placeholder.visible)
	assert_eq(file_pane._list.item_count, 0)
	assert_eq(file_pane.vault_path, _tmp.path_join("note.md"))

	var relative_pane := _make_pane("not/absolute")
	assert_true(relative_pane._placeholder.visible)
	assert_eq(relative_pane._list.item_count, 0)
	assert_eq(relative_pane.vault_path, "not/absolute")


func test_lists_markdown_notes_recursively_and_skips_hidden():
	_write(_tmp.path_join("note.md"), "# Heading")
	DirAccess.make_dir_recursive_absolute(_tmp.path_join("sub"))
	_write(_tmp.path_join("sub").path_join("nested.md"), "# Nested")
	DirAccess.make_dir_recursive_absolute(_tmp.path_join(".hidden"))
	_write(_tmp.path_join(".hidden").path_join("secret.md"), "# Secret")
	_write(_tmp.path_join("top.txt"), "not a note")

	var pane := _make_pane(_tmp)
	assert_false(pane._placeholder.visible)
	assert_eq(
		_list_texts(pane),
		["note.md", "sub".path_join("nested.md")],
		"only .md notes, hidden dirs skipped, sorted",
	)


func test_depth_cap_stops_the_walk():
	var deep := _tmp
	for i in 17:
		deep = deep.path_join("d%d" % i)
	DirAccess.make_dir_recursive_absolute(deep)
	_write(deep.path_join("deep.md"), "# Deep")
	_write(_tmp.path_join("top.md"), "# Top")

	var pane := _make_pane(_tmp)
	assert_eq(_list_texts(pane), ["top.md"], "a note past the depth cap is not walked")


func test_entry_cap_reports_truncation():
	for i in 3:
		_write(_tmp.path_join("n%d.md" % i), "# N")
	var pane := _make_pane(_tmp)

	var scan: Dictionary = pane._scan_vault(2)
	assert_eq(scan["notes"].size(), 2)
	assert_true(scan["truncated"], "the cap must report that a note was left out")
	assert_false(pane._scan_vault()["truncated"], "the full scan is not truncated")


func test_activating_a_note_renders_it_and_back_returns():
	_write(_tmp.path_join("note.md"), "# Heading\n\nbody")
	var pane := _make_pane(_tmp)

	pane._list.item_activated.emit(0)
	assert_true(pane._reader.visible)
	assert_true(pane._back.visible)
	assert_false(pane._list.visible)
	assert_string_contains(pane._reader.get_parsed_text(), "Heading")

	pane._back.pressed.emit()
	assert_true(pane._list.visible)
	assert_false(pane._reader.visible)
	assert_false(pane._back.visible)


func test_layout_state_carries_the_vault_path():
	_write(_tmp.path_join("note.md"), "# N")
	var pane := _make_pane(_tmp)
	var state: Dictionary = pane._get_layout_state()
	assert_eq(state.get("type"), "wiki")
	assert_eq(state.get("vault_path"), _tmp)


func test_apply_settings_rescans_and_keeps_an_invalid_path():
	_write(_tmp.path_join("note.md"), "# N")
	var pane := _make_pane("")
	assert_true(pane._placeholder.visible)

	pane.apply_settings({"vault_path": _tmp})
	assert_false(pane._placeholder.visible)
	assert_eq(_list_texts(pane), ["note.md"])

	pane.apply_settings({"vault_path": "relative/path"})
	assert_true(pane._placeholder.visible)
	assert_eq(pane.vault_path, "relative/path")
