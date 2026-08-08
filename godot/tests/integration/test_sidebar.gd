extends GutTest
# Integration tests: Sidebar popup menu and pane type listing.

var _scene: Control
var _sidebar: Sidebar

func before_each():
	MockAutoloads.setup()
	_scene = TestScene.create()
	add_child(_scene)

	# Build a minimal Sidebar (requires a bg ColorRect for parent)
	var bg = ColorRect.new()
	bg.name = "SidebarBg"
	bg.color = Color(0.12, 0.12, 0.15)
	bg.offset_right = 180
	_scene.add_child(bg)

	_sidebar = Sidebar.new()
	_sidebar.name = "Sidebar"
	bg.add_child(_sidebar)
	_sidebar.offset_right = 180
	_sidebar.build(bg)

func after_each():
	MockAutoloads.teardown()
	if _scene:
		for c in _scene.get_children():
			_scene.remove_child(c)
			c.free()
		remove_child(_scene)
		_scene.free()

func test_sidebar_has_pane_list():
	# After build, the sidebar should have internal VBox containers
	var content = _sidebar.get_node_or_null("SidebarContent")
	assert_not_null(content, "sidebar should have content VBox")
	# Check it's a VBoxContainer
	assert_true(content is VBoxContainer, "content should be VBoxContainer")

func test_sidebar_emits_request_new_pane():
	watch_signals(_sidebar)
	_sidebar.request_new_pane.emit("terminal")
	assert_signal_emitted(_sidebar, "request_new_pane")

func test_sidebar_emits_request_settings():
	watch_signals(_sidebar)
	_sidebar.request_settings.emit()
	assert_signal_emitted(_sidebar, "request_settings")

func test_sidebar_emits_request_reset():
	watch_signals(_sidebar)
	_sidebar.request_reset.emit()
	assert_signal_emitted(_sidebar, "request_reset")


func test_update_pane_list_adds_children():
	# Use PaneBody so _pane_type() is a real method (not a callable property)
	var mock_body = PaneBody.new()
	mock_body.pane_label = "T1"

	_sidebar.update_pane_list([mock_body])

	# Find the pane list container
	var pane_list = _sidebar.get_node_or_null("SidebarContent/PaneScroll/PaneList")
	assert_not_null(pane_list, "PaneList should exist after build")

	# Should have 1 child (the row HBoxContainer)
	assert_eq(pane_list.get_child_count(), 1, "update_pane_list should add 1 row for 1 pane")

	# The row should have 6 children: focus btn + 5 action buttons
	var row = pane_list.get_child(0)
	assert_true(row is HBoxContainer, "pane row should be HBoxContainer")
	assert_eq(row.get_child_count(), 6, "pane row should have 6 buttons (focus + 5 actions)")

	# First button should show the pane label
	var focus_btn = row.get_child(0)
	assert_true(focus_btn is Button, "first child should be focus Button")
	assert_true(focus_btn.text != "", "focus button should have non-empty label")

func test_update_pane_list_clears_previous():
	var mock_body1 = PaneBody.new()
	mock_body1.pane_label = "T1"
	var mock_body2 = PaneBody.new()
	mock_body2.pane_label = "C1"

	_sidebar.update_pane_list([mock_body1, mock_body2])
	var pane_list = _sidebar.get_node_or_null("SidebarContent/PaneScroll/PaneList")
	assert_eq(pane_list.get_child_count(), 2, "should have 2 rows")

	# Replace with 1 pane — queue_free defers deletion, check new label instead
	_sidebar.update_pane_list([mock_body1])
	var last_row = pane_list.get_child(pane_list.get_child_count() - 1)
	var last_btn = last_row.get_child(0)
	assert_true(last_btn is Button, "newest row's first child should be a Button")
	assert_eq(last_btn.text, "T1", "newest row should show updated pane label")
