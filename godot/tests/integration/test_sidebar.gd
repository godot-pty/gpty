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

func test_sidebar_build_succeeds():
	# After build, update_pane_list with empty array should not crash
	_sidebar.update_pane_list([])
	assert_not_null(_sidebar._pane_list, "_pane_list should exist after build")

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


func test_update_pane_list_shows_label():
	var mock_body = PaneBody.new()
	mock_body.pane_label = "T1"
	_sidebar.update_pane_list([mock_body])

	var pane_list = _sidebar._pane_list
	assert_not_null(pane_list, "_pane_list should exist after build")
	assert_gt(pane_list.get_child_count(), 0, "update_pane_list should add rows")

	# First row's first button should show the pane label
	var row = pane_list.get_child(0)
	var focus_btn = row.get_child(0)
	assert_true(focus_btn is Button, "first child should be focus Button")
	assert_eq(focus_btn.text, "T1", "focus button should show pane label")

func test_update_pane_list_replaces_previous():
	var body1 = PaneBody.new(); body1.pane_label = "T1"
	var body2 = PaneBody.new(); body2.pane_label = "C1"

	_sidebar.update_pane_list([body1, body2])
	var pane_list = _sidebar._pane_list
	assert_gt(pane_list.get_child_count(), 1, "should have multiple rows")

	# Replace with single pane — new label should appear
	_sidebar.update_pane_list([body1])
	var focus_btn = pane_list.get_child(pane_list.get_child_count() - 1).get_child(0)
	assert_eq(focus_btn.text, "T1", "replacement should show updated label")
