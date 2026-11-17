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

func test_about_tab_exists():
	var tabs := _find_tab_container(_panel)
	assert_not_null(tabs, "TabContainer must exist inside SettingsPanel")
	var found := false
	for i in tabs.get_tab_count():
		if tabs.get_tab_title(i) == "About":
			found = true
			break
	assert_true(found, "Settings must contain an 'About' tab")

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

func test_the_about_tab_holds_the_documentation_viewer():
	assert_not_null(_panel._docs_viewer, "About builds a DocsViewer")
	assert_true(_panel._docs_viewer.is_inside_tree())
	var tabs := _find_tab_container(_panel)
	var body := _panel.find_child("About", true, false) as Control
	assert_not_null(body)
	tabs.current_tab = tabs.get_tab_idx_from_control(body)
	await wait_frames(2)
	assert_eq(_panel._docs_viewer._current, DocsBundle.ROOT_DOC,
		"the About page opens on the bundled README")
	assert_string_contains(_panel._docs_viewer._view.get_parsed_text(), "desktop workspace")

func test_the_about_tab_is_a_fill_tab():
	var tabs := _find_tab_container(_panel)
	var body := _panel.find_child("About", true, false) as Control
	assert_not_null(body)
	assert_eq(body.get_parent(), tabs, "the tab body is a direct child of the tab container")
	assert_false(body is ScrollContainer,
		"the document body owns its scrollbar; a ScrollContainer would clip it to one line")

func test_shortcuts_have_their_own_tab():
	var tabs := _find_tab_container(_panel)
	var titles: Array[String] = []
	for i in tabs.get_tab_count():
		titles.append(tabs.get_tab_title(i))
	assert_true(titles.has("Shortcuts"), "the chord table moved to its own tab")
	assert_eq(titles[titles.size() - 1], "About", "About stays the last tab")
	var list := _panel.find_child("ShortcutList", true, false) as VBoxContainer
	assert_not_null(list)
	var owner: Node = list
	while owner != null and owner.get_parent() != tabs:
		owner = owner.get_parent()
	assert_not_null(owner)
	assert_eq(owner.name, "Shortcuts",
		"the table lives under the Shortcuts tab, not under About")

# ── helpers ────────────────────────────────────────────────────────────

## Walk the immediate children of the panel to find the TabContainer.
func _find_tab_container(node: Control) -> TabContainer:
	for child in node.get_children():
		var tc := _find_tab_container_recursive(child)
		if tc != null:
			return tc
	return null

func _find_tab_container_recursive(node: Node) -> TabContainer:
	if node is TabContainer:
		return node as TabContainer
	for child in node.get_children():
		var tc := _find_tab_container_recursive(child)
		if tc != null:
			return tc
	return null
