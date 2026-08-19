extends GutTest
# Settings Concepts tab — list container must exist so saving a concept
# cannot null-deref `_concept_list` (that crashed the app on Add Concept).

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

func test_concept_list_is_created():
	assert_not_null(_panel._concept_list, "Concepts tab must own a list VBox")
	assert_true(_panel._concept_list.is_inside_tree())

func test_refresh_concept_list_does_not_crash_without_terminal():
	_panel._concept_terminal = null
	_panel._refresh_concept_list()
	assert_eq(_panel._concept_list.get_child_count(), 0)

func test_refresh_survives_null_list():
	_panel._concept_list = null
	_panel._refresh_concept_list()
	pass # no crash is the assertion
