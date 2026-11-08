extends GutTest
# The File Tree's "nothing here" surface (row *The File Tree shows an empty list
# when its root cannot be listed, and says nothing*).
#
# `_populate` used to return silently for a path that was not absolute, a folder
# that did not exist, a path that was a file, or a `DirAccess.open` that failed,
# and a folder that really was empty rendered the same way - so a saved layout
# naming a path this machine does not have read as a working, empty pane. Each
# state is now one sentence, built by the same static function the test reads.

var _tmp := ""


func before_each():
	MockAutoloads.setup()
	_tmp = TestPaths.user_path("file_tree_probe")
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


func _write(name: String, text: String) -> String:
	var path := _tmp.path_join(name)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	return path


func _make_pane(root: String) -> FileTreePane:
	var pane := FileTreePane.new()
	pane.root_path = root
	add_child_autofree(pane)
	return pane


func test_a_pane_with_no_root_says_so():
	var pane := _make_pane("")
	assert_true(pane._empty_host.visible, "an unset root must show the surface, not a blank tree")
	assert_false(pane._tree.visible, "there is nothing to show behind the message")
	assert_eq(pane._empty_title.text, "No folder open")
	assert_string_contains(pane._empty_hint.text, "pane settings")


func test_a_relative_root_repeats_the_value():
	var pane := _make_pane("docs/notes")
	assert_eq(pane._empty_title.text, "No folder open")
	assert_string_contains(pane._empty_hint.text, "docs/notes",
		"the message must repeat what the pane was given")
	assert_string_contains(pane._empty_hint.text, "absolute")


func test_a_file_root_is_not_a_folder():
	var file := _write("note.txt", "x")
	var pane := _make_pane(file)
	assert_eq(pane._empty_title.text, "Not a folder")
	assert_string_contains(pane._empty_hint.text, "note.txt")


func test_a_missing_root_names_the_path():
	var missing := _tmp.path_join("gone")
	var pane := _make_pane(missing)
	assert_eq(pane._empty_title.text, "Folder not found")
	assert_string_contains(pane._empty_hint.text, missing)
	assert_false(pane._tree.visible)


func test_a_folder_that_cannot_be_listed_says_why():
	var pane := _make_pane(_tmp)
	pane.open_dir = func(_path: String) -> DirAccess: return null
	pane._refresh_root()
	assert_eq(pane._empty_title.text, "Cannot list this folder")
	assert_string_contains(pane._empty_hint.text, _tmp)
	assert_false(pane._tree.visible)


func test_an_empty_folder_keeps_its_own_sentence():
	var pane := _make_pane(_tmp)
	assert_eq(pane._empty_title.text, "This folder is empty")
	assert_string_contains(pane._empty_hint.text, "not listed",
		"a dotfile-only folder must read as explained, not as broken")
	assert_false(pane._tree.visible)


func test_a_folder_with_entries_shows_the_rows_not_a_message():
	_write("a.txt", "x")
	var pane := _make_pane(_tmp)
	assert_true(pane._tree.visible)
	assert_false(pane._empty_host.visible)
	assert_eq(pane._tree.get_root().get_child_count(), 1)


func test_fixing_the_root_swaps_the_message_for_the_rows():
	_write("a.txt", "x")
	var pane := _make_pane(_tmp.path_join("gone"))
	assert_true(pane._empty_host.visible)
	pane.apply_settings({"root_path": _tmp})
	assert_false(pane._empty_host.visible, "a fixed root must show the rows again")
	assert_true(pane._tree.visible)
	assert_eq(pane._tree.get_root().get_child_count(), 1)


func test_the_gate_hands_back_the_open_folder():
	var listed := FileTreePane.open_for_listing(
		_tmp, func(path: String) -> DirAccess: return DirAccess.open(path))
	assert_true(listed.problem.is_empty(), "an openable folder has no problem to report")
	assert_not_null(listed.dir)
