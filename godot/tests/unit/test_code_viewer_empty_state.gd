extends GutTest
# The code viewer's empty state and the panes' shared content inset — the v0.8.1
# row "Pane chrome: distinct icons, a compact action menu, padding and
# consistent empty states".
#
# The pane used to be a blank read-only editor under a disabled Reload button:
# no text, no explanation, no route to a file. Media and Wiki both named the fix;
# the code viewer now does too, on the same `PaneBody.empty_state` surface. The
# inset is `PaneBody.CONTENT_INSET` on the five text panes, whose roots used to
# print their first line on the tile's 1 px border.

var _tmp := ""

func before_each():
	MockAutoloads.setup()
	_tmp = TestPaths.user_path("code_viewer_empty_probe")
	DirAccess.make_dir_recursive_absolute(_tmp)

func after_each():
	if _tmp != "":
		var dir := DirAccess.open(_tmp)
		if dir:
			for f in dir.get_files():
				DirAccess.remove_absolute(_tmp.path_join(f))
		DirAccess.remove_absolute(_tmp)
		_tmp = ""
	MockAutoloads.teardown()

func _make_viewer() -> CodeViewerPane:
	var pane := CodeViewerPane.new()
	add_child_autofree(pane)
	return pane

func _write(name: String, text: String) -> String:
	var path := _tmp.path_join(name)
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()
	return path


func test_an_unset_pane_explains_itself():
	var pane := _make_viewer()
	assert_not_null(pane._empty, "the pane must build its empty surface")
	assert_true(pane._empty.visible, "no file means the empty state is what shows")
	assert_false(pane._toolbar.visible,
		"a disabled Reload over a blank editor is not an explanation")
	assert_false(pane._editor.visible)
	assert_false(pane._markdown.visible)

	assert_eq(pane._empty.get_node("EmptyBox/EmptyTitle").text, "No file open")
	assert_string_contains(pane._empty.get_node("EmptyBox/EmptyHint").text, "pane settings",
		"the hint must name where the path is set")
	assert_eq(pane._empty.get_node("EmptyBox/EmptyGlyph").text,
		str(PaneTypes.ALL["code_viewer"]["icon"]),
		"the glyph is the pane type's own, as the media placeholder uses its own")


func test_opening_a_file_replaces_the_empty_state():
	var pane := _make_viewer()
	pane.load_file(_write("note.gd", "extends Node\n"))

	assert_false(pane._empty.visible, "content means no empty state")
	assert_true(pane._toolbar.visible)
	assert_true(pane._editor.visible)
	assert_string_contains(pane._editor.text, "extends Node")


func test_a_routed_capture_is_content_without_a_file():
	# `receive_content` clears `file_path` on purpose, so "empty" cannot be
	# `file_path == ""` alone: that would hide a capture the pane is showing.
	var pane := _make_viewer()
	assert_true(pane.receive_content("captured\n"))

	assert_eq(pane.file_path, "", "a capture is not a file")
	assert_false(pane._empty.visible, "a capture is content")
	assert_true(pane._editor.visible)
	assert_eq(pane._editor.text, "captured\n")


func test_the_text_panes_inset_their_content():
	# The four that need no vault on disk; the wiki pane makes the same call.
	var panes: Array[PaneBody] = [
		CodeViewerPane.new(), InspectorPane.new(), ReasoningPane.new(), CliViewPane.new(),
	]
	for pane in panes:
		add_child_autofree(pane)
		var root := pane.get_child(0) as Control
		assert_not_null(root, "%s must build a content root" % pane._pane_type())
		assert_eq(root.offset_left, PaneBody.CONTENT_INSET,
			"%s must clear the left border" % pane._pane_type())
		assert_eq(root.offset_top, PaneBody.CONTENT_INSET,
			"%s must clear the top border" % pane._pane_type())
		assert_eq(root.offset_right, -PaneBody.CONTENT_INSET,
			"%s must clear the right border" % pane._pane_type())
		assert_eq(root.offset_bottom, -PaneBody.CONTENT_INSET,
			"%s must clear the bottom border" % pane._pane_type())
