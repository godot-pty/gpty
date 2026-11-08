extends GutTest
# The one pane-action menu — the v0.8.1 row "Pane chrome: distinct icons, a
# compact action menu, padding and consistent empty states".
#
# Five title-bar buttons became three: settings, one menu, close. The type list
# moved into that menu and it marks the current type, which is what a screenshot
# cannot pin. The sidebar row opens the same builder, so these tests also cover
# what the row's `request_pane_menu` ends up showing.

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

var _ws: Control

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()

func after_each():
	if _ws:
		if _ws.get_parent():
			_ws.get_parent().remove_child(_ws)
		_ws.free()
		_ws = null
	MockAutoloads.teardown()

func _make_workspace() -> Control:
	var ws: Control = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame
	return ws

## Open the menu for `body` and return the instance it added. A menu frees
## itself when it closes, so an earlier one may still be queued for deletion;
## the last match is always the one just opened.
func _open(ws: Control, body: Control) -> PopupMenu:
	ws._tm.show_pane_actions_popup(body, ws, Vector2.ZERO)
	var found: PopupMenu = null
	for c in ws.get_children():
		if c is PopupMenu and c.name == "PaneActionsMenu":
			found = c
	return found

## The type keys the menu lists, in item order.
func _listed_types(menu: PopupMenu) -> Array:
	var keys := []
	for i in menu.item_count:
		var meta = menu.get_item_metadata(i)
		if meta is Dictionary and meta.get("kind", "") == "type":
			keys.append(meta["key"])
	return keys

## The type keys the menu marks as checked.
func _checked_types(menu: PopupMenu) -> Array:
	var keys := []
	for i in menu.item_count:
		if menu.is_item_checked(i):
			keys.append(menu.get_item_metadata(i)["key"])
	return keys

## The startup terminal, swapped to `type_name` through the workspace's own
## transaction. `TerminalManager.swap_pane` alone replaces the tile's body
## without the grid surgery `Workspace._swap_pane_now` does, and a later swap
## would then `remove_child` a wrapper the grid never held.
func _swap_startup_pane(ws: Control, type_name: String) -> Control:
	ws._swap_pane_now(ws._tm.last_body, type_name)
	return ws._tm._find_body(ws._tm.tiles[0].wrapper)

func _index_of_type(menu: PopupMenu, key: String) -> int:
	for i in menu.item_count:
		var meta = menu.get_item_metadata(i)
		if meta is Dictionary and meta.get("kind", "") == "type" and meta["key"] == key:
			return i
	return -1

func test_the_menu_marks_the_current_type_once():
	var ws = await _make_workspace()
	var body: Control = _swap_startup_pane(ws, "code_viewer")
	var menu := _open(ws, body)
	assert_not_null(menu, "the builder must add a PaneActionsMenu")

	# Two actions, a separator, then the types: a visible divide between "what
	# the pane does" and "what the pane is".
	assert_eq(menu.get_item_text(2), "", "a separator divides actions from types")
	assert_true(menu.is_item_separator(2))
	assert_eq(_listed_types(menu), Array(PaneTypes.ALL.keys()),
		"every pane type is listed once, in registry order")
	assert_eq(_checked_types(menu), ["code_viewer"],
		"exactly the pane's own type is marked")


func test_the_menu_offers_minimize_then_swap_then_the_types():
	var ws = await _make_workspace()
	var body: Control = ws._tm.last_body
	var menu := _open(ws, body)
	assert_eq(menu.get_item_text(0), "Minimize pane")
	assert_eq(menu.get_item_text(1), "Swap position…")
	assert_true(menu.is_item_disabled(1),
		"one tile has nothing to swap with, so the item must not look live")


func test_the_first_item_follows_the_pane_it_was_opened_for():
	var ws = await _make_workspace()
	var body: Control = ws._tm.last_body
	ws._tm.toggle_pane_minimize(body)
	var menu := _open(ws, body)
	assert_eq(menu.get_item_text(0), "Restore pane",
		"a hidden pane is restored, not minimized again")


func test_choosing_the_current_type_does_not_rebuild_the_pane():
	# `swap_pane` does allow a same-type swap (a test pins it), so a press on
	# the checked item would otherwise destroy the pane and build an identical
	# one - losing its scroll, selection and mode on a click that changes nothing.
	var ws = await _make_workspace()
	var body: Control = _swap_startup_pane(ws, "code_viewer")
	var menu := _open(ws, body)
	var idx := _index_of_type(menu, "code_viewer")
	assert_ne(idx, -1, "the current type must have an item")

	menu.index_pressed.emit(idx)

	assert_true(is_instance_valid(body), "choosing the current type must not destroy the pane")
	assert_eq(ws._tm._find_body(ws._tm.tiles[0].wrapper), body,
		"the tile still holds the same body")


func test_choosing_another_type_swaps_the_pane():
	var ws = await _make_workspace()
	var body: Control = _swap_startup_pane(ws, "code_viewer")
	var menu := _open(ws, body)
	var idx := _index_of_type(menu, "reasoning")
	assert_ne(idx, -1)

	menu.index_pressed.emit(idx)

	var new_body: Control = ws._tm._find_body(ws._tm.tiles[0].wrapper)
	assert_not_null(new_body)
	assert_ne(new_body, body, "a different type is a different body")
	assert_eq(new_body._pane_type(), "reasoning")


func test_minimize_from_the_menu_hides_and_restores():
	var ws = await _make_workspace()
	var body: Control = ws._tm.last_body
	var menu := _open(ws, body)
	menu.index_pressed.emit(0)
	assert_false(body.visible, "Minimize pane hides the pane")

	var restore := _open(ws, body)
	restore.index_pressed.emit(0)
	assert_true(body.visible, "Restore pane brings it back")
	assert_eq(ws.get_viewport().gui_get_focus_owner(), body,
		"a restored pane takes the keyboard, so the next keystroke is not swallowed")
