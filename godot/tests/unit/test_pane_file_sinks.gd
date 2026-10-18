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


## Collect `request_pane` emissions as `[type, settings]` pairs. The captured
## Array is shared by reference, so the lambda appends where the test reads.
func _requests(pane: FileTreePane) -> Array:
	var requests := []
	pane.request_pane.connect(func(type_name: String, settings: Dictionary):
		requests.append([type_name, settings])
	)
	return requests


func _activate(pane: FileTreePane, name: String) -> TreeItem:
	var item := _item_named(pane._tree, name)
	if item == null:
		assert_not_null(item, "the tree must list " + name)
		return null
	item.select(0)
	pane._tree.emit_signal("item_activated")
	return item

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
	var cap: int = TextRead.DEFAULT_MAX_BYTES
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
	var cap: int = TextRead.DEFAULT_MAX_BYTES
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

# ── Code viewer: Reload ────────────────────────────────────────────────

## Opening the same file again focuses a viewer instead of re-reading it, so
## a file changed on disk is picked up only through the explicit action.
func test_reload_re_reads_the_file_from_disk():
	var pane := _make_viewer()
	await get_tree().process_frame
	var path := _write(_tmp.path_join("reload.txt"), "before\n")
	pane.load_file(path)
	assert_eq(pane._content, "before\n")
	_write(path, "after\n")
	assert_eq(pane._content, "before\n", "a load is a read, not a watch")

	pane._reload_button.pressed.emit()

	assert_eq(pane._content, "after\n", "Reload re-reads through the same gate")
	assert_eq(pane.file_path, path, "the pane still shows the same file")

func test_reload_is_disabled_when_the_pane_shows_no_file():
	var pane := _make_viewer()
	await get_tree().process_frame
	assert_true(pane._reload_button.disabled, "a fresh viewer has nothing to reload")
	pane.receive_content("some capture")
	assert_true(pane._reload_button.disabled, "a routed capture is not a file")
	assert_eq(pane.file_path, "")

## A capture replaces the document; keeping the old path would make a later
## "open this file" focus a pane that no longer shows it.
func test_a_routed_capture_drops_the_file_identity():
	var pane := _make_viewer()
	await get_tree().process_frame
	var path := _write(_tmp.path_join("before.txt"), "file\n")
	pane.load_file(path)
	pane.receive_content("capture")
	assert_eq(pane.file_path, "", "the pane no longer shows the file")

# ── File tree: in-app viewer route ─────────────────────────────────────

## A supported text file opens in-app: the tree asks its workspace for a
## `code_viewer` pane and never reaches the system handler or a confirmation.
func test_file_tree_activation_of_a_supported_file_requests_a_viewer():
	var path := _write(_tmp.path_join("note.md"), "# hi\n")
	var pane := _make_tree(_tmp)
	await get_tree().process_frame
	var opened := []
	pane.open_external = func(uri: String): opened.append(uri)
	var requests := _requests(pane)

	_activate(pane, "note.md")

	assert_eq(requests.size(), 1, "one activation asks the workspace once")
	assert_eq(requests[0][0], "code_viewer", "Markdown is a viewer type")
	assert_eq(requests[0][1].get("file_path"), path, "the request carries the exact path")
	assert_eq(_dialogs_of(pane).size(), 0, "the in-app route never asks for confirmation")
	assert_eq(opened, [], "the in-app route never reaches the system handler")

## Anything the table does not name keeps the old behavior exactly: confirm,
## then hand the constructed `file://` URI to the system's default handler.
func test_file_tree_activation_of_an_unsupported_file_still_confirms():
	_write(_tmp.path_join("picture.png"), "not really a png")
	var pane := _make_tree(_tmp)
	await get_tree().process_frame
	var opened := []
	pane.open_external = func(uri: String): opened.append(uri)
	var requests := _requests(pane)

	_activate(pane, "picture.png")

	assert_eq(requests, [], "an unsupported type must not reach a pane")
	var dialogs := _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "the system route asks first")
	assert_string_contains(dialogs[0].dialog_text, "picture.png",
		"the confirmation must show what will be opened")
	assert_eq(opened, [], "nothing opens before the answer")
	dialogs[0].confirmed.emit()
	assert_eq(opened.size(), 1, "a confirmed open reaches the handler")
	assert_true(opened[0].begins_with(pane.OPEN_SCHEME),
		"the sink constructs the URI itself")

## The per-tree setting can keep every file on the system path, including the
## types the viewer supports.
func test_open_in_system_keeps_the_confirmation_for_a_supported_file():
	_write(_tmp.path_join("note.md"), "# hi\n")
	var pane := _make_tree(_tmp)
	pane.open_in = "system"
	await get_tree().process_frame
	var requests := _requests(pane)

	_activate(pane, "note.md")

	assert_eq(requests, [], "system mode must not request a pane")
	assert_eq(_dialogs_of(pane).size(), 1,
		"even a supported file gets the system confirmation in this mode")

## A non-absolute path never becomes a pane request either — the same guard
## the system path applies (`_confirm_open`, covered below).
func test_file_tree_refuses_a_non_absolute_viewer_open():
	var pane := _make_tree(_tmp)
	await get_tree().process_frame
	var requests := _requests(pane)
	pane._open_activated("relative/note.md")
	assert_eq(requests, [], "a relative path must not reach the workspace")
	assert_eq(_dialogs_of(pane).size(), 0)

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

## Past the read cap the text view carries the notice after the text; the
## rendered view has to show it above the body instead, because a notice
## appended to a source at the renderer's cap is the first thing the cut drops
## — which is exactly the size this notice exists for.
func test_a_markdown_file_past_the_cap_announces_the_cut_in_the_rendered_view():
	var pane := _make_viewer()
	await get_tree().process_frame
	var cap: int = TextRead.DEFAULT_MAX_BYTES
	var path := _write(_tmp.path_join("huge.md"), "# Head\n\n" + "a".repeat(cap))
	pane.load_file(path)

	assert_true(pane._markdown.visible, "a .md file renders by default")
	var shown: String = pane._markdown.get_parsed_text()
	assert_true(shown.begins_with("… truncated"), "the notice belongs above the body")
	assert_string_contains(shown, "Head", "and the head of the file is still rendered")
	# The source the renderer parsed carries no notice of its own — the pane
	# shows one line, not the notice twice (once as a paragraph at the end).
	assert_true(pane._source.begins_with("# Head"))
	assert_false(pane._source.contains("truncated"))
	assert_eq(pane._notice, TextRead.truncation_notice(cap, cap + 8))
	assert_string_contains(pane._content, "truncated",
		"the text view still says so at the end of the text it holds")
