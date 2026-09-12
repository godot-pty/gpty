extends GutTest
# A pane's public id is how IPC addresses it, and the pane settings can change
# it. The path that applies those settings runs *after* the pane is attached,
# which is why it used to be the one way to end up with two panes sharing an
# id — and id-targeted IPC then resolved to whichever came first.

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

var _ws: Control

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = "/bin/sh"

func after_each():
	if _ws:
		if _ws.get_parent():
			_ws.get_parent().remove_child(_ws)
		_ws.free()
		_ws = null
	MockAutoloads.teardown()

func _two_panes() -> Array:
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame
	var first = ws._tm._find_body(ws._tm.tiles[0].wrapper)
	var second = ws._spawn_pane("terminal", {})
	return [first, second]

func test_applying_a_duplicate_id_through_the_panel_renames_it():
	var panes = await _two_panes()
	var first = panes[0]
	var second = panes[1]
	assert_ne(first.attachment_id, second.attachment_id, "spawn already keeps ids unique")

	# Exactly what the settings overlay does: gather the fields (including the
	# id the user typed) and apply them to the live pane.
	var panel = _ws._tm._pane_settings_panel
	panel._target = second
	panel._gather_func = func(): return {"attachment_id": first.attachment_id}
	panel._apply_to_target()

	assert_ne(
		second.attachment_id, first.attachment_id,
		"the id typed into the pane settings must not collide with a live pane"
	)
	assert_ne(second.attachment_id, "", "and the pane keeps an id")

func test_the_renamed_pane_is_still_addressable_by_its_new_id():
	var panes = await _two_panes()
	var first = panes[0]
	var second = panes[1]
	var panel = _ws._tm._pane_settings_panel
	panel._target = second
	panel._gather_func = func(): return {"attachment_id": first.attachment_id}
	panel._apply_to_target()

	assert_eq(
		_ws._find_pane_by_label(second.attachment_id), second,
		"IPC resolution finds the pane under the id it now carries"
	)
	assert_eq(
		_ws._find_pane_by_label(first.attachment_id), first,
		"and the pane that kept the id is untouched"
	)
