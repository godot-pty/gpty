extends GutTest
# Pane file sinks: the code viewer's read cap and path-type gate, and the file
# tree's confirmation before a name reaches the system's default handler.

var _tmp: String


func before_each():
	MockAutoloads.setup()
	_tmp = ProjectSettings.globalize_path("user://file_sink_probe")
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


func _make_viewer() -> CodeViewerPane:
	var pane := CodeViewerPane.new()
	add_child_autofree(pane)
	return pane


func _make_tree(root: String) -> FileTreePane:
	var pane := FileTreePane.new()
	pane.root_path = root
	add_child_autofree(pane)
	return pane


func _item_named(tree: Tree, name: String) -> TreeItem:
	for item in tree.get_root().get_children():
		if item.get_text(0) == name:
			return item
	return null


func _dialogs_of(node: Node) -> Array:
	var found := []
	for child in node.get_children():
		if child is ConfirmationDialog:
			found.append(child)
	return found

# ── Code viewer: read cap ──────────────────────────────────────────────

func test_small_file_loads_in_full():
	var pane := _make_viewer()
	await get_tree().process_frame
	var path := _write(_tmp.path_join("small.rs"), "fn main() {}\n")
	pane.load_file(path)
	assert_eq(pane.file_path, path)
	assert_eq(pane._content, "fn main() {}\n")
	assert_false(pane._content.contains("truncated"))
	# The load must reach the view refresh: a broken comment-delimiter call
	# used to abort `load_file` after setting the text, leaving the pane on
	# the previous file's view (the toggle stayed visible for a code file).
	assert_false(pane._view_toggle.visible, "a code file must not offer the Markdown toggle")
	assert_true(pane._editor.visible)

func test_file_over_the_cap_is_truncated_with_a_notice():
	var pane := _make_viewer()
	await get_tree().process_frame
	var cap: int = CodeViewerPane.MAX_FILE_BYTES
	var path := _write(_tmp.path_join("huge.txt"), "a".repeat(cap + 4096))
	pane.load_file(path)
	assert_eq(pane.file_path, path, "a truncated file is still shown (with a notice)")
	assert_true(pane._content.contains("truncated"), "the notice must be visible in the pane")
	assert_true(pane._content.begins_with("aaa"), "the head of the file is still shown")
	assert_lte(pane._content.length(), cap + 128, "the read must stop at the cap")

## The cap lands inside a UTF-8 sequence as often as not; the tail must be cut
## cleanly instead of arriving as a replacement glyph.
func test_torn_utf8_at_the_cap_is_not_shown_as_a_replacement_glyph():
	var pane := _make_viewer()
	await get_tree().process_frame
	var cap: int = CodeViewerPane.MAX_FILE_BYTES
	# cap bytes of "a" plus a 2-byte character: the read stops after its lead.
	var path := _write(_tmp.path_join("torn.txt"), "a".repeat(cap - 1) + "é")
	pane.load_file(path)
	assert_false(pane._content.contains("\uFFFD"),
		"a sequence cut by the cap must be dropped, not rendered as U+FFFD")
	assert_true(pane._content.contains("truncated"))

## Anything that is not a regular file is refused (the same gate covers
## directories, devices and FIFOs — `FileAccess.file_exists` is false for all
## of them, which is also what keeps a blocking FIFO open out of the GUI).
func test_non_regular_path_is_refused():
	var pane := _make_viewer()
	await get_tree().process_frame
	pane.load_file(_tmp)  # a directory
	assert_eq(pane.file_path, "", "a non-regular path must not become the pane's file")
	assert_eq(pane._content, "")

# ── File tree: confirmation before the system handler ─────────────────

func test_file_tree_activation_confirms_before_opening():
	_write(_tmp.path_join("note.md"), "# hi\n")
	var pane := _make_tree(_tmp)
	await get_tree().process_frame
	var item := _item_named(pane._tree, "note.md")
	assert_not_null(item, "the tree must list the file")
	item.select(0)
	pane._tree.emit_signal("item_activated")

	var dialogs := _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "opening a file must ask first")
	assert_string_contains(dialogs[0].dialog_text, "note.md",
		"the confirmation must show what will be opened")

func test_file_tree_directory_activation_expands_without_a_dialog():
	DirAccess.make_dir_recursive_absolute(_tmp.path_join("sub"))
	_write(_tmp.path_join("sub/inner.txt"), "x")
	var pane := _make_tree(_tmp)
	await get_tree().process_frame
	var item := _item_named(pane._tree, "sub")
	assert_not_null(item, "the tree must list the directory")
	item.select(0)
	pane._tree.emit_signal("item_activated")

	assert_eq(_dialogs_of(pane).size(), 0, "expanding a directory is not an open")
	assert_gt(item.get_child_count(), 0, "the directory must lazily list its children")

func test_file_tree_refuses_a_non_absolute_path():
	var pane := _make_tree(_tmp)
	await get_tree().process_frame
	pane._confirm_open("relative/note.md")
	assert_eq(_dialogs_of(pane).size(), 0, "a non-absolute path must not reach the handler")
