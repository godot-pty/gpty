extends GutTest
# ScrollHints: the two chevrons a pane overlays on its scrolling body.
#
# Defends: each chevron is visible only while its direction has content (a body
# that fits shows neither), the two actions land on the ends the pointer cannot
# reach by itself, the pair is chrome (no focus, named, mouse-only), and the
# panes that bind it drive their own scroller.

var _root: Control
var _temp: String

func before_each():
	MockAutoloads.setup()
	_root = TestScene.create()
	_root.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_root.size = Vector2(800, 600)
	add_child(_root)
	_temp = TestPaths.user_path("scroll-hints-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(_temp)

func after_each():
	if _root:
		remove_child(_root)
		_root.free()
		_root = null
	_remove_tree(_temp)
	MockAutoloads.teardown()

func _remove_tree(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name != "." and name != "..":
			var child := path.path_join(name)
			if dir.current_is_dir():
				_remove_tree(child)
			else:
				DirAccess.remove_absolute(child)
		name = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)

## A `ScrollContainer` of `height` px holding one body of `body_height` px.
func _scroll_body(height: int, body_height: int) -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.size = Vector2(400, height)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_root.add_child(scroll)
	var body := Label.new()
	body.text = "body"
	body.custom_minimum_size = Vector2(200, body_height)
	scroll.add_child(body)
	return scroll

func test_a_body_that_fits_shows_no_chevrons():
	var scroll := _scroll_body(200, 40)
	await get_tree().process_frame
	var hints := ScrollHints.attach(_root, scroll)
	hints.bind_bar(scroll.get_v_scroll_bar())
	assert_false(hints.top_button.visible, "nothing above the top row")
	assert_false(hints.bottom_button.visible, "nothing below the last row")

func test_each_chevron_follows_its_direction():
	var scroll := _scroll_body(200, 4000)
	await get_tree().process_frame
	var bar := scroll.get_v_scroll_bar()
	var hints := ScrollHints.attach(_root, scroll)
	hints.bind_bar(bar)
	await get_tree().process_frame
	assert_false(hints.top_button.visible, "the view starts at the top")
	assert_true(hints.bottom_button.visible, "the body runs past the viewport")

	bar.value = 2000.0
	assert_true(hints.top_button.visible, "mid-range has both directions")
	assert_true(hints.bottom_button.visible)

	hints.bottom_button.pressed.emit()
	assert_true(bar.value + bar.page >= bar.max_value - 1.0,
		"the down chevron lands on the end")
	assert_true(hints.top_button.visible)
	assert_false(hints.bottom_button.visible, "there is nothing below the end")

	hints.top_button.pressed.emit()
	assert_eq(bar.value, bar.min_value, "the up chevron lands on the start")
	assert_false(hints.top_button.visible)
	assert_true(hints.bottom_button.visible)

func test_a_hidden_body_shows_no_chevrons():
	var scroll := _scroll_body(200, 4000)
	await get_tree().process_frame
	var hints := ScrollHints.attach(_root, scroll)
	hints.bind_bar(scroll.get_v_scroll_bar())
	await get_tree().process_frame
	assert_true(hints.bottom_button.visible)
	scroll.visible = false
	await get_tree().process_frame
	assert_false(hints.top_button.visible, "a hidden body has no directions")
	assert_false(hints.bottom_button.visible)
	scroll.visible = true
	await get_tree().process_frame
	assert_true(hints.bottom_button.visible, "the chevron returns with the body")

func test_a_tree_jumps_to_its_first_and_last_row():
	var tree := Tree.new()
	tree.size = Vector2(320, 200)
	tree.columns = 1
	_root.add_child(tree)
	var root_item := tree.create_item()
	for i in 60:
		var item := tree.create_item(root_item)
		item.set_text(0, "row %d" % i)
	await get_tree().process_frame
	await get_tree().process_frame
	var hints := ScrollHints.attach(_root, tree)
	hints.bind_tree(tree)
	await get_tree().process_frame
	assert_false(hints.top_button.visible, "the tree starts at its first row")
	assert_true(hints.bottom_button.visible, "60 rows do not fit 200 px")

	hints.bottom_button.pressed.emit()
	await get_tree().process_frame
	assert_gt(tree.get_scroll().y, 0.0, "the down chevron scrolled the tree")
	assert_true(hints.top_button.visible)
	assert_false(hints.bottom_button.visible, "the last row is visible")

	hints.top_button.pressed.emit()
	await get_tree().process_frame
	assert_eq(tree.get_scroll().y, 0.0, "the up chevron returns to the first row")
	assert_false(hints.top_button.visible)

func test_a_custom_binding_drives_the_chevrons():
	var state := {"offset": 0, "max": 3}
	var hints := ScrollHints.attach(_root, _root)
	hints.bind_custom(
		func(): return state.offset > 0,
		func(): return state.offset < state.max,
		func(): state.offset = 0,
		func(): state.offset = state.max)
	assert_false(hints.top_button.visible, "offset 0 has nothing above it")
	assert_true(hints.bottom_button.visible)
	hints.bottom_button.pressed.emit()
	assert_eq(state.offset, 3)
	assert_true(hints.top_button.visible)
	assert_false(hints.bottom_button.visible)
	hints.top_button.pressed.emit()
	assert_eq(state.offset, 0)

func test_the_chevrons_are_mouse_only_and_named():
	var hints := ScrollHints.attach(_root, _root)
	assert_eq(String(hints.name), "ScrollHints")
	assert_eq(hints.mouse_filter, Control.MOUSE_FILTER_IGNORE,
		"the overlay never eats the pane's own clicks")
	assert_eq(hints.top_button.mouse_filter, Control.MOUSE_FILTER_STOP,
		"the chevron takes its own click")
	for button in [hints.top_button, hints.bottom_button]:
		assert_eq(button.focus_mode, Control.FOCUS_NONE, "a chevron never takes focus")
		assert_ne(KeyboardFocus.mouse_only_reason(button), "",
			"the mouse-only control declares why the keyboard reaches the same end")
		assert_ne(button.accessibility_name, "", "the chevron is named for a screen reader")
		assert_eq(button.text, "", "the glyph is drawn by a child Label, not by text")
	assert_eq(Icons.glyph(hints.top_button), Icons.CARET_UP)
	assert_eq(Icons.glyph(hints.bottom_button), Icons.CARET_DOWN)

func test_the_file_tree_pane_binds_its_tree():
	var dir := _temp.path_join("tree")
	DirAccess.make_dir_recursive_absolute(dir)
	for i in 80:
		var file := FileAccess.open(dir.path_join("file-%02d.txt" % i), FileAccess.WRITE)
		file.store_string("x")
		file.close()
	var pane := FileTreePane.new()
	pane.root_path = dir
	pane.size = Vector2(360, 240)
	_root.add_child(pane)
	await get_tree().process_frame
	await get_tree().process_frame
	assert_true(pane._scroll_hints.bottom_button.visible, "80 rows do not fit 240 px")
	assert_false(pane._scroll_hints.top_button.visible, "the tree starts at its first row")
	pane._scroll_hints.bottom_button.pressed.emit()
	await get_tree().process_frame
	assert_gt(pane._tree.get_scroll().y, 0.0, "the chevron drove the pane's own tree")

func test_the_code_viewer_rebinds_on_a_view_toggle():
	var path := _temp.path_join("doc.md")
	var file := FileAccess.open(path, FileAccess.WRITE)
	var lines := PackedStringArray()
	for i in 300:
		lines.append("- item %d" % i)
	file.store_string("\n".join(lines))
	file.close()
	var pane := CodeViewerPane.new()
	pane.file_path = path
	pane.view_mode = "source"
	pane.size = Vector2(400, 260)
	_root.add_child(pane)
	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(pane._scroll_hints._bar, pane._editor.get_v_scroll_bar(),
		"source mode binds the editor's own bar")
	assert_true(pane._scroll_hints.bottom_button.visible, "300 lines do not fit 260 px")

	pane._toggle_view()
	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(pane._scroll_hints._bar, pane._markdown.get_v_scroll_bar(),
		"rendered mode rebinds the reader's bar")
	assert_true(pane._scroll_hints.bottom_button.visible,
		"the rendered body runs past the viewport too")
