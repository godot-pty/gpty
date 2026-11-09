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

## A pane that records what a saved command writes, without a PTY: the exact
## bytes, and whether Enter followed them, are the contract under test.
class _RecordingPane extends TerminalPane:
	var sent: Array[String] = []
	var sent_lines: Array[String] = []
	var snaps := 0

	func _send_to_term(text: String):
		sent.append(text)

	func _send_line_to_term(text: String):
		sent_lines.append(text)

	func _snap_to_bottom():
		snaps += 1

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

## The rows' command ids. Only Buttons are rows: a saved-command section draws
## a heading Label among them, and a heading is not selectable.
func _commands(ws: Control) -> Array:
	var out := []
	for row in _rows(ws):
		if row is Button:
			out.append(str(row.get_meta("command")))
	return out

func _row(ws: Control, command: String) -> Button:
	for row in _rows(ws):
		# A section heading is a Label among the rows and carries no meta.
		if row is Button and str(row.get_meta("command")) == command:
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

# ── Saved commands ─────────────────────────────────────────────────────

func _seed_saved() -> void:
	SavedCommandStore.add("Build", "cargo build --workspace", false)
	SavedCommandStore.add("Deploy", "make deploy", true)

## How many times `needle` appears in a pane's drained grid.
func _count(body: Control, needle: String) -> int:
	return str(body._terminal.get_plain_text(4000)).count(needle)

## Poll the grid until `needle` appears `at_least` times.
func _wait_for_count(body: Control, needle: String, at_least: int,
		timeout_ms := 20000) -> int:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		var n := _count(body, needle)
		if n >= at_least:
			return n
		await get_tree().create_timer(0.05).timeout
	return _count(body, needle)

func test_saved_commands_list_under_one_heading_after_the_actions():
	var ws = await _make_workspace()
	_seed_saved()
	ws._toggle_palette()
	var rows := _rows(ws)
	var headings := []
	for child in rows:
		if child.name == CommandPalette.SECTION_LABEL_NAME:
			headings.append(child)
	assert_eq(headings.size(), 1, "one heading, not one per row")
	# The heading is an inset box holding the label, so the label is a child.
	var heading_label := (headings[0] as Node).get_child(0) as Label
	assert_not_null(heading_label, "the heading carries its text")
	assert_eq(heading_label.text, PaletteModel.SAVED_SECTION)
	var last_action := rows.find(_row(ws, "load"))
	assert_gt(rows.find(headings[0]), last_action,
		"the section follows the whole fixed list")
	assert_eq(_commands(ws).slice(-2), ["saved: Build", "saved: Deploy"],
		"store order under the heading")

func test_a_saved_command_with_nowhere_to_go_is_refused_by_the_palette():
	var ws = await _make_workspace()
	_seed_saved()
	# A code viewer is a pane, not a shell: the rows must say so instead of
	# arming themselves and doing nothing when clicked.
	ws._execute_command("new code viewer")
	var reason: String = ws._saved_command_refusal()
	assert_eq(reason, Workspace.SAVED_NOT_TERMINAL)
	ws._toggle_palette()
	var build := _row(ws, "saved: Build")
	assert_true(build.disabled, "a refused row cannot be clicked")
	assert_eq(build.tooltip_text, reason, "the tooltip is the dispatcher's own sentence")
	assert_eq(build.accessibility_description, reason, "and a screen reader gets it too")
	assert_false(_row(ws, "new terminal").disabled, "the rest of the palette still works")

	# Enter cannot land on one either: the cursor only rests on enabled rows.
	ws._palette._field.text_changed.emit("build")
	assert_eq(_commands(ws), ["saved: Build"], "the query leaves only the refused row")
	assert_eq(ws._palette._selected, -1, "nothing enabled is selected")
	ws._palette._field.text_submitted.emit("build")
	assert_true(ws._palette.visible, "Enter on a refused row does nothing, not even close")

func test_an_insert_writes_the_text_and_a_run_writes_a_line():
	var ws = await _make_workspace()
	var pane := _RecordingPane.new()
	ws._deliver_saved_command(pane, {"name": "Build", "command": "cargo build", "run": false})
	assert_eq(pane.sent, ["cargo build"], "the exact characters, nothing appended")
	assert_eq(pane.sent_lines, [], "an insert does not press Enter")
	ws._deliver_saved_command(pane, {"name": "Test", "command": "cargo test", "run": true})
	assert_eq(pane.sent_lines, ["cargo test"], "run sends the line, which carries the Enter")
	assert_eq(pane.sent, ["cargo build"], "and never sends the text twice")
	assert_eq(pane.snaps, 2, "the pane comes back to the prompt either way")
	pane.free()

## The real shell is the proof the recording pane cannot give: an insert leaves
## the command at the prompt unexecuted, a run executes it. Each half is judged
## by a file the command would create, not by an occurrence count: the shell
## redraws a pending line (a resize makes it redraw in place or again), so the
## echo can appear any number of times and is only useful as "it arrived".
func test_insert_and_run_differ_through_a_real_shell():
	if ShellFixtures.is_windows():
		pending("a POSIX shell is the harness here; the recording pane proves the bytes on Windows")
		return
	var ws = await _make_workspace()
	var root := BasePersistenceManager.user_root()
	var insert_probe := root.path_join("insert-probe.txt")
	var run_probe := root.path_join("run-probe.txt")
	for path in [insert_probe, run_probe]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)

	ws._execute_command("new terminal")
	var insert_pane: Control = ws._tm.last_body
	assert_not_null(insert_pane, "the spawned terminal is the active pane")
	SavedCommandStore.add("Insert", "touch '%s' # MARK_INSERT" % insert_probe, false)
	ws._execute_command("saved: Insert")
	assert_gt(await _wait_for_count(insert_pane, "MARK_INSERT", 1), 0,
		"the inserted text reaches the shell's line")
	await get_tree().create_timer(0.5).timeout
	assert_false(FileAccess.file_exists(insert_probe),
		"nothing pressed Enter, so the command did not run")

	# A second pane for the run half: the first prompt still holds the insert.
	ws._execute_command("new terminal")
	var run_pane: Control = ws._tm.last_body
	assert_ne(run_pane, insert_pane, "a second terminal is the active pane")
	SavedCommandStore.add("Run", "touch '%s' # MARK_RUN" % run_probe, true)
	ws._execute_command("saved: Run")
	assert_true(await _wait_for_file(run_probe),
		"a run executes: the shell created the file")
	assert_eq(_count(insert_pane, "MARK_RUN"), 0,
		"the other pane was never written to")
	if FileAccess.file_exists(run_probe):
		DirAccess.remove_absolute(run_probe)

## Poll for a path the child shell would create.
func _wait_for_file(path: String, timeout_ms := 20000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if FileAccess.file_exists(path):
			return true
		await get_tree().create_timer(0.05).timeout
	return FileAccess.file_exists(path)

func test_a_command_deleted_from_the_store_writes_nothing():
	var ws = await _make_workspace()
	var pane := _RecordingPane.new()
	ws._tm.last_body = pane
	SavedCommandStore.add("Gone", "echo NOPE", false)
	SavedCommandStore.remove(0)
	ws._execute_command("saved: Gone")
	assert_eq(pane.sent, [], "an unknown name is not guessed at")
	assert_eq(pane.sent_lines, [])
	pane.free()

func test_the_save_command_entry_opens_the_commands_tab_with_the_form():
	var ws = await _make_workspace()
	ws._execute_command("save command")
	var panel: SettingsPanel = ws._settings_panel
	assert_not_null(panel, "the palette command builds the settings panel")
	assert_true(panel.visible, "and shows it")
	assert_eq(panel._tabs.get_tab_title(panel._tabs.current_tab), "Commands",
		"it lands on the Commands tab, not the first one")
	var dialogs := []
	for child in panel.get_children():
		if child is AcceptDialog:
			dialogs.append(child)
	assert_eq(dialogs.size(), 1, "the add form is already open")
	assert_true((dialogs[0] as AcceptDialog).visible)
