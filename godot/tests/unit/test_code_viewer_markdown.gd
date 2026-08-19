extends GutTest

func test_markdown_language_uses_rendered_view_by_default():
	var pane = CodeViewerPane.new()
	pane.language = "md"
	add_child_autofree(pane)
	await get_tree().process_frame

	pane.receive_content("# Heading\n\n**bold**")
	await get_tree().create_timer(0.1).timeout

	assert_true(pane._markdown.visible)
	assert_false(pane._editor.visible)
	assert_true(pane._view_toggle.visible)
	assert_string_contains(pane._markdown.get_parsed_text(), "Heading")
	assert_string_contains(pane._markdown.get_parsed_text(), "bold")

func test_markdown_view_can_toggle_to_source():
	var pane = CodeViewerPane.new()
	pane.language = "md"
	add_child_autofree(pane)
	await get_tree().process_frame
	pane.receive_content("# Heading")

	pane._toggle_view()

	assert_true(pane._editor.visible)
	assert_false(pane._markdown.visible)
	assert_eq(pane.view_mode, "source")

func test_non_markdown_language_stays_in_code_edit():
	var pane = CodeViewerPane.new()
	pane.language = "rs"
	add_child_autofree(pane)
	await get_tree().process_frame
	pane.receive_content("fn main() {}")

	assert_true(pane._editor.visible)
	assert_false(pane._markdown.visible)
	assert_false(pane._view_toggle.visible)

func test_invalid_path_clears_previous_content():
	var pane = CodeViewerPane.new()
	pane.language = "md"
	add_child_autofree(pane)
	await get_tree().process_frame
	pane.receive_content("# stale")
	pane.load_file("not/absolute.md")
	assert_eq(pane.file_path, "")
	assert_eq(pane._content, "")
	assert_eq(pane._editor.text, "")
