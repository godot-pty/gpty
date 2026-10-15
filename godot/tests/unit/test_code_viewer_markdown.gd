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

## Concept-routed output is the one source a pane receives that nothing else
## capped (a capture can be megabytes), so it is where the renderer's own cut
## has to be visible rather than silent.
func test_a_capture_over_the_render_cap_says_what_it_is_not_showing():
	var pane = CodeViewerPane.new()
	pane.language = "md"
	add_child_autofree(pane)
	await get_tree().process_frame

	pane.receive_content("# Head\n\n" + "a".repeat(TextRead.DEFAULT_MAX_BYTES + 1))

	var shown: String = pane._markdown.get_parsed_text()
	assert_true(shown.begins_with("… truncated"), "the banner is the first thing a reader sees")
	assert_string_contains(shown, String.humanize_size(TextRead.DEFAULT_MAX_BYTES),
		"and it names how much was rendered")
	assert_string_contains(shown, "Head", "the head of the capture is still rendered")
	# The text view holds the whole capture: the cut is the preview's, and the
	# pane must not invent a notice for text it has in full.
	assert_true(pane._editor.text.begins_with("# Head"))
	assert_false(pane._editor.text.contains("truncated"))
