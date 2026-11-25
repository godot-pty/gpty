extends GutTest
# Settings About tab — the versions row, the bundled documentation viewer, and
# the Shortcuts split. The About page is the README now; the chord table moved
# to its own tab.

class MockWorkspace extends Control:
	func get_terminal_for_ffi() -> Node:
		return null

var _ws: MockWorkspace
var _panel: SettingsPanel

func before_each():
	MockAutoloads.setup()
	_ws = MockWorkspace.new()
	add_child_autofree(_ws)
	_panel = SettingsPanel.new(_ws)
	add_child_autofree(_panel)
	await get_tree().process_frame

func after_each():
	MockAutoloads.teardown()

# ── About tab structure ────────────────────────────────────────────────

func test_about_section_exists():
	_panel.show_section("About")
	assert_eq(_panel.current_section(), "About", "Settings must contain an 'About' section")
	assert_not_null(_panel.section_content("About"), "the About section has content")

func test_version_label_is_created():
	assert_not_null(_panel._version_label, "About tab must expose _version_label")
	assert_true(_panel._version_label.is_inside_tree())

func test_version_label_contains_app_version():
	var expected := GptyTerminal.get_app_version()
	assert_string_contains(
		_panel._version_label.text,
		expected,
		"Version label must contain the live app version from get_app_version()"
	)

func test_version_label_prefixed_with_gpty():
	assert_true(
		_panel._version_label.text.begins_with("gpty v"),
		"Version label should begin with 'gpty v'"
	)

func test_protocol_label_comes_from_the_ffi_source():
	# The About tab showed a hardcoded "2.0"; the wire value now has one
	# definition, so the tab must read the same source the server reports.
	assert_not_null(_panel._protocol_label, "About tab must expose _protocol_label")
	assert_eq(
		_panel._protocol_label.text,
		GptyTerminal.get_ipc_protocol_version(),
		"the About tab must show the protocol the wire actually carries"
	)
	assert_false(_panel._protocol_label.text.is_empty())

func test_version_and_protocol_share_one_top_level_row():
	var row := _panel._version_label.get_parent()
	assert_not_null(row, "the version label has a row")
	assert_true(row is HBoxContainer, "the two versions sit on one line")
	assert_eq(_panel._protocol_label.get_parent(), row,
		"the IPC protocol label is on the same row, not below it")

func test_the_repository_url_row_is_gone():
	assert_null(_panel.find_child("RepoUrl", true, false),
		"the README links the repository itself; the standalone URL row is removed")

func test_the_about_section_holds_the_documentation_viewer():
	assert_not_null(_panel._docs_viewer, "About builds a DocsViewer")
	assert_true(_panel._docs_viewer.is_inside_tree())
	_panel.show_section("About")
	await wait_frames(2)
	assert_eq(_panel._docs_viewer._current, DocsBundle.ROOT_DOC,
		"the About page opens on the bundled README")
	assert_string_contains(_panel._docs_viewer._view.get_parsed_text(), "desktop workspace")

func test_the_about_section_is_a_fill_section():
	var content := _panel.section_content("About")
	assert_not_null(content)
	if content == null:
		return
	var body := content.get_parent() as Control
	assert_not_null(body, "the About content has a body")
	if body == null:
		return
	assert_eq(body.name, "AboutBody", "the fill body is the padded document host")
	assert_false(body is ScrollContainer,
		"the document body owns its scrollbar; a ScrollContainer would clip it to one line")
	assert_null(_panel.section_scroll("About"),
		"the fill section has no outer scroll")

func test_shortcuts_have_their_own_section():
	var titles: Array[String] = []
	for id in SettingsPanel.SETTINGS_SECTIONS:
		titles.append(SettingsPanel.SECTION_TITLES[id])
	assert_true(titles.has("Shortcuts"), "the chord table moved to its own section")
	assert_eq(titles[titles.size() - 1], "About", "About stays the last section")
	var list := _panel.find_child("ShortcutList", true, false) as VBoxContainer
	assert_not_null(list)
	var content := _panel.section_content("Shortcuts")
	assert_not_null(content)
	if list != null and content != null:
		assert_true(content.is_ancestor_of(list),
			"the table lives under the Shortcuts section, not under About")
