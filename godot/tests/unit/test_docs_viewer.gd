extends GutTest
# DocsViewer — the Settings > About documentation viewer, driven against the
# real shipped bundle (`res://docs.json`). The link clicks go through the same
# seam a reader's click does: `meta_clicked`, which the view connects to its
# own `_confirm_link`.

func before_each():
	DocsBundle.reset()
	DocsBundle.bundle_path = DocsBundle.BUNDLE_FILE

func after_each():
	DocsBundle.bundle_path = DocsBundle.BUNDLE_FILE
	DocsBundle.reset()

func _make_viewer() -> DocsViewer:
	var viewer := DocsViewer.new()
	add_child_autofree(viewer)
	return viewer

func test_the_readme_is_the_home_page():
	var viewer := _make_viewer()
	await wait_frames(2)
	assert_eq(viewer._current, DocsBundle.ROOT_DOC)
	assert_eq(viewer._path_label.text, DocsBundle.ROOT_DOC)
	assert_string_contains(viewer._view.get_parsed_text(), "desktop workspace",
		"the README's own prose is rendered")
	assert_false(viewer._view.get_parsed_text().contains("<div align=\"center\">"),
		"the generator dropped the badge header instead of shipping its tags")
	assert_true(viewer._back.disabled, "Back is disabled at the home page")
	assert_true(viewer._forward.disabled)

func test_following_a_link_opens_the_document_in_place():
	var viewer := _make_viewer()
	await wait_frames(2)
	viewer._view.meta_clicked.emit("gpty-doc:SECURITY.md")
	await wait_frames(2)
	assert_eq(viewer._current, "SECURITY.md")
	assert_eq(viewer._path_label.text, "SECURITY.md")
	assert_string_contains(viewer._view.get_parsed_text(), "Security",
		"the linked document's body replaced the README")
	assert_false(viewer._back.disabled, "the README is one step back")
	assert_true(viewer._forward.disabled)

func test_back_returns_to_the_readme_and_stops_there():
	var viewer := _make_viewer()
	await wait_frames(2)
	viewer._view.meta_clicked.emit("gpty-doc:SECURITY.md")
	await wait_frames(1)
	viewer._back.pressed.emit()
	await wait_frames(1)
	assert_eq(viewer._current, DocsBundle.ROOT_DOC)
	assert_true(viewer._back.disabled, "the README is always the last back link")
	viewer._back.pressed.emit()
	assert_eq(viewer._current, DocsBundle.ROOT_DOC, "and going further back is a no-op")
	assert_false(viewer._forward.disabled)

func test_forward_re_walks_the_trail():
	var viewer := _make_viewer()
	await wait_frames(2)
	viewer._view.meta_clicked.emit("gpty-doc:SECURITY.md")
	await wait_frames(1)
	viewer._back.pressed.emit()
	await wait_frames(1)
	viewer._forward.pressed.emit()
	await wait_frames(1)
	assert_eq(viewer._current, "SECURITY.md")
	assert_true(viewer._forward.disabled)

func test_a_link_to_an_unbundled_document_is_refused():
	var viewer := _make_viewer()
	await wait_frames(2)
	watch_signals(ToastManager)
	viewer._view.meta_clicked.emit("gpty-doc:not-bundled.md")
	await wait_frames(1)
	assert_eq(viewer._current, DocsBundle.ROOT_DOC,
		"a refused link leaves the current page on screen")
	assert_signal_emitted(ToastManager, "toast_requested")

func test_a_fragment_on_the_open_page_adds_no_history_step():
	var viewer := _make_viewer()
	await wait_frames(2)
	viewer._view.meta_clicked.emit("gpty-doc:SECURITY.md")
	await wait_frames(1)
	var steps := viewer._history.size()
	viewer._view.meta_clicked.emit("gpty-doc:SECURITY.md#Reporting")
	await wait_frames(1)
	assert_eq(viewer._current, "SECURITY.md")
	assert_eq(viewer._history.size(), steps,
		"scrolling inside the open document is not a new page")

func test_a_missing_bundle_shows_a_notice_instead_of_a_document():
	DocsBundle.bundle_path = TestPaths.user_path("no-such-about-bundle.json")
	DocsBundle.reset()
	var viewer := _make_viewer()
	await wait_frames(2)
	assert_true(viewer._notice.visible)
	assert_ne(viewer._notice.text, "")
	assert_false(viewer._view.visible)
	assert_false(viewer.open(DocsBundle.ROOT_DOC), "no document can open without a bundle")
