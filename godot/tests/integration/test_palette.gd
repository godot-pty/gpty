extends GutTest
# Integration tests: Workspace palette commands.
#
# The command list comes from `PaneTypes.build_palette_commands()`, which the
# workspace also uses, so a literal list of commands in a test would only pin
# the list against itself. What can actually break is the other half: a
# command the palette offers that the workspace does not execute, a "new …"
# entry that spawns the wrong pane type, or a palette whose search or Enter
# key does nothing. These tests drive a real `Workspace` through all three.

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
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame
	return ws

func _new_commands() -> Array:
	return PaneTypes.build_palette_commands().filter(func(c): return c.begins_with("new "))

func test_the_palette_lists_one_new_command_per_pane_type_then_the_actions():
	var cmds := PaneTypes.build_palette_commands()
	assert_eq(_new_commands().size(), PaneTypes.ALL.size(),
		"one 'new …' entry per registered pane type")
	assert_eq(cmds.slice(cmds.size() - PaneTypes.PALETTE_ACTIONS.size()),
		PaneTypes.PALETTE_ACTIONS, "the actions follow the pane-type entries")
	var seen := {}
	for c in cmds:
		assert_false(seen.has(c), "'%s' is listed twice" % c)
		seen[c] = true

func test_the_legacy_observer_type_is_not_offered():
	assert_false(PaneTypes.ALL.has("observer"),
		"observer stays accepted from old layouts only; it must not be a pane type")
	assert_false(PaneTypes.build_palette_commands().has("new observer"))

func test_every_new_command_spawns_its_own_pane_type():
	var ws = await _make_workspace()
	var spawned := {}
	for cmd in _new_commands():
		var before: int = ws._tm.tiles.size()
		ws._execute_command(cmd)
		assert_eq(ws._tm.tiles.size(), before + 1, "'%s' must add exactly one pane" % cmd)
		var body = ws._tm._find_body(ws._tm.tiles[ws._tm.tiles.size() - 1].wrapper)
		var type_name: String = body._pane_type()
		assert_true(PaneTypes.ALL.has(type_name), "'%s' spawned an unregistered type" % cmd)
		assert_false(spawned.has(type_name),
			"'%s' spawned %s, which another command already spawned" % [cmd, type_name])
		spawned[type_name] = cmd
	var all_types := PaneTypes.ALL.keys()
	all_types.sort()
	var reached := spawned.keys()
	reached.sort()
	assert_eq(reached, all_types, "every pane type is reachable from the palette")

func test_every_palette_action_has_a_handler_in_the_workspace():
	# Reads the workspace's own dispatch rather than restating it: an action
	# added to PALETTE_ACTIONS with no `match` arm would sit in the palette and
	# do nothing. (The destructive ones — reset, load, spawn 16 — are checked
	# here rather than run.)
	var src := FileAccess.get_file_as_string("res://scenes/terminal/workspace.gd")
	var start := src.find("func _execute_command")
	assert_gt(start, -1, "_execute_command must exist")
	var end := src.find("\nfunc ", start + 1)
	var handler := src.substr(start, end - start)
	for action in PaneTypes.PALETTE_ACTIONS:
		assert_true(handler.contains("\"%s\":" % action),
			"the palette offers '%s' but _execute_command has no arm for it" % action)

func test_close_active_removes_the_last_spawned_pane():
	var ws = await _make_workspace()
	ws._execute_command("new code viewer")
	var before: int = ws._tm.tiles.size()
	ws._execute_command("close active")
	await get_tree().process_frame
	assert_eq(ws._tm.tiles.size(), before - 1, "'close active' closes one pane")

func _palette_results(ws: Control) -> Array:
	# Panel -> VBox [margin(LineEdit), results]
	var box: VBoxContainer = ws._palette.get_child(0)
	var out := []
	for b in box.get_child(1).get_children():
		if not b.is_queued_for_deletion():
			out.append((b as Button).text)
	return out

func _palette_input(ws: Control) -> LineEdit:
	return (ws._palette.get_child(0) as VBoxContainer).get_child(0).get_child(0)

func test_typing_in_the_palette_filters_its_commands():
	var ws = await _make_workspace()
	ws._toggle_palette()
	assert_true(ws._palette.visible, "the first toggle opens the palette")
	var input := _palette_input(ws)

	input.text_changed.emit("")
	assert_eq(_palette_results(ws), PaneTypes.build_palette_commands(),
		"an empty query lists everything the workspace can execute")

	input.text_changed.emit("wiki")
	assert_eq(_palette_results(ws), ["new wiki"], "the query narrows the list")

	input.text_changed.emit("no such command")
	assert_eq(_palette_results(ws), [], "a query matching nothing lists nothing")

func test_enter_runs_the_first_match_and_closes_the_palette():
	var ws = await _make_workspace()
	ws._toggle_palette()
	var input := _palette_input(ws)
	input.text_changed.emit("wiki")
	var before: int = ws._tm.tiles.size()

	input.text_submitted.emit("wiki")

	assert_eq(ws._tm.tiles.size(), before + 1, "Enter executes the command it landed on")
	var body = ws._tm._find_body(ws._tm.tiles[ws._tm.tiles.size() - 1].wrapper)
	assert_eq(body._pane_type(), "wiki")
	assert_false(ws._palette.visible, "running a command dismisses the palette")
