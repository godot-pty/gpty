extends GutTest
# Integration tests: the command palette and the workspace commands it offers.
#
# The list comes from `PaletteModel`, which the workspace dispatches against by
# command string, so a literal list in a test would only pin the list against
# itself. What can actually break is the other half: a command the palette
# offers that the workspace does not execute, a "new …" entry that spawns the
# wrong pane type, a row that shows a bare command id or no chord, a cursor key
# that does nothing, an empty list on open, or a card that lands off-centre.
# These tests drive a real `Workspace` through all of it.

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
	return PaletteModel.commands().filter(func(c): return c.begins_with("new "))

func _rows(ws: Control) -> Array:
	return ws._palette._results.get_children()

func _commands(ws: Control) -> Array:
	var out := []
	for row in _rows(ws):
		out.append(str(row.get_meta("command")))
	return out

func _row(ws: Control, command: String) -> Button:
	for row in _rows(ws):
		if str(row.get_meta("command")) == command:
			return row
	return null

func _row_text(row: Button, label: String) -> String:
	return (row.get_node("RowBody/" + label) as Label).text

func _press(ws: Control, keycode: Key) -> void:
	var ev := InputEventKey.new()
	ev.keycode = keycode
	ev.pressed = true
	ws._palette._input(ev)

# ── The list ───────────────────────────────────────────────────────────

func test_the_palette_lists_one_new_command_per_pane_type_then_the_actions():
	var cmds := PaletteModel.commands()
	assert_eq(_new_commands().size(), PaneTypes.ALL.size(),
		"one 'new …' entry per registered pane type")
	var actions := []
	for entry in PaletteModel.ACTIONS:
		actions.append(str(entry["command"]))
	assert_eq(cmds.slice(cmds.size() - actions.size()), actions,
		"the actions follow the pane-type entries")
	var seen := {}
	for c in cmds:
		assert_false(seen.has(c), "'%s' is listed twice" % c)
		seen[c] = true

func test_the_legacy_observer_type_is_not_offered():
	assert_false(PaneTypes.ALL.has("observer"),
		"observer stays accepted from old layouts only; it must not be a pane type")
	assert_false(PaletteModel.commands().has("new observer"))

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
	# added to PaletteModel.ACTIONS with no `match` arm would sit in the palette
	# and do nothing. (The destructive ones — reset and load — are checked here
	# rather than run.)
	var src := FileAccess.get_file_as_string("res://scenes/terminal/workspace.gd")
	var start := src.find("func _execute_command")
	assert_gt(start, -1, "_execute_command must exist")
	var end := src.find("\nfunc ", start + 1)
	var handler := src.substr(start, end - start)
	for entry in PaletteModel.ACTIONS:
		var action := str(entry["command"])
		assert_true(handler.contains("\"%s\":" % action),
			"the palette offers '%s' but _execute_command has no arm for it" % action)

# ── Opening ────────────────────────────────────────────────────────────

func test_the_palette_is_populated_before_anything_is_typed():
	var ws = await _make_workspace()
	ws._toggle_palette()
	assert_true(ws._palette.visible, "the first toggle opens the palette")
	assert_eq(_commands(ws), PaletteModel.commands(),
		"the list is built on open, before a keystroke")
	assert_false(ws._palette._empty.visible, "a full list shows no empty state")

func test_a_row_names_its_action_and_shows_its_glyph_and_chord():
	var ws = await _make_workspace()
	ws._toggle_palette()
	var terminal := _row(ws, "new terminal")
	assert_not_null(terminal, "the registry's terminal entry has a row")
	assert_eq(_row_text(terminal, "Name"), "New Terminal", "a row shows words, not a command id")
	assert_eq(_row_text(terminal, "Glyph"), ">_", "the registry's glyph rides on the row")
	assert_eq(_row_text(terminal, "Hint"), "Ctrl+Shift+N", "the row names the chord it answers")
	var close := _row(ws, "close active")
	var chord := ShortcutManager.chord("app:close_pane")
	assert_eq(chord, "Ctrl+Shift+W", "the workspace registered the close-active chord")
	assert_eq(_row_text(close, "Hint"), chord,
		"the hint reads the binding registry instead of repeating a literal")
	assert_eq(str(close.get_meta("hint")), chord)
	assert_eq(close.accessibility_name, "Close Active Pane",
		"a row is named for a screen reader, since it has no button text")

func test_no_row_is_the_developer_command():
	var ws = await _make_workspace()
	ws._toggle_palette()
	assert_false(_commands(ws).has("spawn 16 terminals"),
		"the developer-only bulk spawn is gone")
	var save := _row_text(_row(ws, "save"), "Name")
	var load := _row_text(_row(ws, "load"), "Name")
	assert_ne(save, load, "save and load must not read the same")
	assert_true(save.contains("Workspaces") and load.contains("Workspaces"),
		"both name what they act on")
	assert_true(save.contains("Save") and load.contains("Reload"),
		"the destructive one says what it destroys")

# ── Keyboard ───────────────────────────────────────────────────────────

func test_arrow_keys_move_a_visible_cursor_and_enter_runs_it():
	var ws = await _make_workspace()
	ws._toggle_palette()
	assert_true(_rows(ws)[0].button_pressed, "the first row starts selected")
	_press(ws, KEY_DOWN)
	_press(ws, KEY_DOWN)
	assert_false(_rows(ws)[0].button_pressed, "the cursor left the first row")
	assert_true(_rows(ws)[2].button_pressed, "Down moves the cursor one row at a time")
	var before: int = ws._tm.tiles.size()
	ws._palette._field.text_submitted.emit("")
	assert_eq(ws._tm.tiles.size(), before + 1, "Enter runs the cursor, not the first match")
	assert_false(ws._palette.visible, "running a command dismisses the palette")
	var body = ws._tm._find_body(ws._tm.tiles[ws._tm.tiles.size() - 1].wrapper)
	assert_eq(body._pane_type(), PaneTypes.ALL.keys()[2],
		"row 2 is the third registry type, so Enter spawned that type")

func test_the_cursor_stops_at_the_ends():
	var ws = await _make_workspace()
	ws._toggle_palette()
	_press(ws, KEY_UP)
	assert_true(_rows(ws)[0].button_pressed, "Up at the top stays on the first row")
	for i in PaletteModel.commands().size() + 5:
		_press(ws, KEY_DOWN)
	assert_true(_rows(ws)[-1].button_pressed, "Down past the end stops on the last row")

func test_typing_in_the_palette_filters_its_commands():
	var ws = await _make_workspace()
	ws._toggle_palette()
	var input: LineEdit = ws._palette._field

	input.text_changed.emit("")
	assert_eq(_commands(ws), PaletteModel.commands(),
		"an empty query lists everything the workspace can execute")

	input.text_changed.emit("wiki")
	assert_eq(_commands(ws), ["new wiki"], "the query narrows the list")
	assert_true(_rows(ws)[0].button_pressed, "a filtered list starts with its first row selected")

	input.text_changed.emit("no such command")
	assert_eq(_commands(ws), [], "a query matching nothing lists nothing")

func test_a_query_with_no_match_shows_its_empty_state():
	var ws = await _make_workspace()
	ws._toggle_palette()
	ws._palette._field.text_changed.emit("zzz")
	assert_eq(_rows(ws).size(), 0, "a miss lists nothing")
	assert_true(ws._palette._empty.visible, "and says so")
	assert_eq(ws._palette._empty.text, CommandPalette.NO_MATCH_TEXT)
	ws._palette._field.text_changed.emit("")
	assert_eq(_rows(ws).size(), PaletteModel.commands().size(), "clearing the query restores the list")
	assert_false(ws._palette._empty.visible)

func test_enter_runs_the_match_and_closes_the_palette():
	var ws = await _make_workspace()
	ws._toggle_palette()
	var input: LineEdit = ws._palette._field
	input.text_changed.emit("wiki")
	var before: int = ws._tm.tiles.size()

	input.text_submitted.emit("wiki")

	assert_eq(ws._tm.tiles.size(), before + 1, "Enter executes the command it landed on")
	var body = ws._tm._find_body(ws._tm.tiles[ws._tm.tiles.size() - 1].wrapper)
	assert_eq(body._pane_type(), "wiki")
	assert_false(ws._palette.visible, "running a command dismisses the palette")

func test_close_active_removes_the_last_spawned_pane():
	var ws = await _make_workspace()
	ws._execute_command("new code viewer")
	var before: int = ws._tm.tiles.size()
	ws._execute_command("close active")
	await get_tree().process_frame
	assert_eq(ws._tm.tiles.size(), before - 1, "'close active' closes one pane")

# ── Layout ─────────────────────────────────────────────────────────────

func test_the_card_is_sized_and_centred():
	var ws = await _make_workspace()
	ws.size = Vector2(1200, 800)
	ws._toggle_palette()
	await get_tree().process_frame
	await get_tree().process_frame
	var card: Control = ws._palette._card
	assert_eq(card.size, Vector2(CommandPalette.PALETTE_WIDTH, CommandPalette.PALETTE_HEIGHT),
		"the card is the palette's own size, not a 320x160 strip")
	var origin: Vector2 = card.global_position - ws.global_position
	assert_eq(origin, Vector2(320, 160),
		"the card is centred: (1200-560)/2, (800-480)/2")
	assert_true(origin.y + card.size.y <= 800.0, "and stays inside its host")

	# The layout floor (UiTokens.MIN_LAYOUT): the card clamps to the host
	# instead of hanging outside it.
	ws.size = Vector2(560, 340)
	await get_tree().process_frame
	await get_tree().process_frame
	ws._toggle_palette()
	ws._toggle_palette()
	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(card.size, Vector2(528, 308),
		"clamped by SPACE_XXL on each side of the 560x340 floor")
	assert_true(card.global_position.y - ws.global_position.y + card.size.y <= 340.0,
		"the palette never draws outside its host")
