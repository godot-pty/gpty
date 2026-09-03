extends GutTest
# Settings About tab — version label must show the live app version and
# the tab itself must be present in the panel's TabContainer.

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
