extends GutTest
# Integration tests: a pane's own working directory, with the workspace's as
# the fallback.
#
# The store is user-owned and keyed by `<workspace id>/<attachment id>`, so the
# same profile re-used in two workspaces keeps two directories, a rename moves
# the entry, and a file can never supply one. Everything here goes through the
# real `Workspace` (`_restore_into`, `_attach_pane_into`, the pane-settings
# handler), not a replay of them.

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

## The pane-settings panel the row builder talks to: only the debounce timer it
## starts and the gather func it holds are real.
class FakePanePanel extends Control:
	var _debounce_timer: Timer
	var _gather_func: Callable

	func _init():
		_debounce_timer = Timer.new()
		# A real panel's timer is its child; the builder calls `start()` on
		# every edit, and a tree-less Timer logs an error.
		add_child(_debounce_timer)

var _ws: Control
var _dirs: Array[String] = []

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()
	SettingsManager.cfg_default_rows = 24
	SettingsManager.cfg_default_cols = 80

func after_each():
	# Free while the mocks are still active: `_exit_tree()` writes the store.
	_free_workspace()
	for dir in _dirs:
		DirAccess.remove_absolute(dir)
	_dirs.clear()
	MockAutoloads.teardown()

func _free_workspace():
	if _ws:
		if _ws.get_parent():
			_ws.get_parent().remove_child(_ws)
		_ws.free()
		_ws = null

func _make_workspace() -> Control:
	_free_workspace()
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame
	if ws._workspaces.is_empty():
		ws._add_workspace()
	return ws

## An existing absolute directory in the throwaway user-data dir.
func _temp_dir(slug: String) -> String:
	var dir := OS.get_user_data_dir().path_join(
		"gpty-test-cwd-%s-%d" % [slug, Time.get_ticks_usec()])
	DirAccess.make_dir_absolute(dir)
	_dirs.append(dir)
	return dir

## A directory that does not exist: a moved repository or an unmounted disk.
func _gone_dir(slug: String) -> String:
	return OS.get_user_data_dir().path_join(
		"gpty-test-cwd-gone-%s-%d" % [slug, Time.get_ticks_usec()])

func _tile(settings: Dictionary) -> Dictionary:
	return {
		"col": 0, "row": 0, "cspan": PaneTypes.GRID, "rspan": PaneTypes.GRID,
		"settings": settings,
	}

## Restore one terminal carrying `attachment_id` into `container` and return
## the body, after the real attach path has run.
func _restored_terminal(ws: Control, container: Dictionary, attachment_id := "agent-terminal") -> Control:
	var tiles: Array[Dictionary] = [
		_tile({"type": "terminal", "attachment_id": attachment_id}),
	]
	ws._restore_into(container, tiles)
	var tm: TerminalManager = container["tm"]
	if tm.tiles.is_empty():
		return null
	return tm._find_body(tm.tiles[-1].wrapper)

func _first_body(ws: Control) -> Control:
	var tm: TerminalManager = ws._tm
	if tm.tiles.is_empty():
		return null
	return tm._find_body(tm.tiles[0].wrapper)

func _button_named(root: Node, node_name: String) -> Button:
	for node in root.find_children("*", "Button", true, false):
		if node.name == node_name:
			return node as Button
	return null

func _button_texted(root: Node, text: String) -> Button:
	for node in root.find_children("*", "Button", true, false):
		if (node as Button).text == text:
			return node as Button
	return null

# ── Two workspaces, one profile ────────────────────────────────────────

func test_same_profile_id_in_two_workspaces_keeps_two_directories():
	var ws = await _make_workspace()
	ws._add_workspace()
	assert_eq(ws._workspaces.size(), 2, "the fixture needs two workspaces")
	var one: Dictionary = ws._workspaces[0]
	var two: Dictionary = ws._workspaces[1]
	assert_ne(str(one.get("id", "")), str(two.get("id", "")),
		"two workspaces never share an id, or their entries would collide")
	var dir_one := _temp_dir("ws-one")
	var dir_two := _temp_dir("ws-two")
	# The same profile's logical pane in both workspaces: one store entry each,
	# under the same pane id. A key of the pane id alone would collapse them.
	PaneCwdStore.set_dir(str(one["id"]), "agent-terminal", dir_one)
	PaneCwdStore.set_dir(str(two["id"]), "agent-terminal", dir_two)

	# Attachment ids are unique window-wide, so only one instance can hold
	# `agent-terminal` at a time; the workspace half of the key is what keeps
	# the two directories apart.
	var body_two = _restored_terminal(ws, two)
	assert_not_null(body_two)
	assert_eq(str(body_two.attachment_id), "agent-terminal", "the first instance keeps the id")
	assert_eq(body_two.spawn_cwd(), dir_two,
		"the second workspace's instance starts in its own directory")
	two["tm"].reset()
	var body_one = _restored_terminal(ws, one)
	assert_not_null(body_one)
	assert_eq(str(body_one.attachment_id), "agent-terminal")
	assert_eq(body_one.spawn_cwd(), dir_one,
		"the first workspace's instance of the same id keeps its own directory")

# ── The store's lifecycle ──────────────────────────────────────────────

func test_a_pane_rename_carries_the_entry():
	var ws = await _make_workspace()
	var container: Dictionary = ws._workspaces[0]
	var ws_id := str(container.get("id", ""))
	var dir := _temp_dir("rename")
	PaneCwdStore.set_dir(ws_id, "old-id", dir)
	var body = _restored_terminal(ws, container, "old-id")
	assert_not_null(body)
	# What the pane settings panel does: apply, then announce the rename.
	body.apply_settings({"attachment_id": "new-id", "pane_cwd": dir})
	ws._tm._pane_settings_panel.settings_applied.emit(
		body, {"attachment_id": "new-id", "pane_cwd": dir}, "old-id")
	assert_eq(PaneCwdStore.dir_for(ws_id, "new-id"), dir,
		"the entry follows a rename, like env does")
	assert_eq(PaneCwdStore.dir_for(ws_id, "old-id"), "",
		"the old id must not keep a directory the pane no longer owns")

func test_closing_a_workspace_drops_its_entries():
	var ws = await _make_workspace()
	ws._add_workspace()
	var second: Dictionary = ws._workspaces[1]
	var ws_id := str(second.get("id", ""))
	PaneCwdStore.set_dir(ws_id, "agent-terminal", _temp_dir("close"))
	ws._close_workspace_now(1)
	assert_eq(PaneCwdStore.dir_for(ws_id, "agent-terminal"), "",
		"a closed workspace takes its pane directories with it")

# ── Resolution ─────────────────────────────────────────────────────────

func test_a_stale_override_falls_back_to_the_workspace_directory():
	var ws = await _make_workspace()
	var container: Dictionary = ws._workspaces[0]
	var live := _temp_dir("live")
	ws._workspaces[0]["cwd"] = live
	PaneCwdStore.set_dir(str(container["id"]), "agent-terminal", _gone_dir("stale"))
	var body = _restored_terminal(ws, container)
	assert_not_null(body)
	assert_eq(body.spawn_cwd(), live,
		"a directory that no longer exists falls back to the workspace's, not through to gpty's")

## The whole chain, for real: the pane's stored directory reaches the PTY
## through `spawn_cwd()` -> `start_shell`, and the child prints it. The tests
## above stop at `spawn_cwd()`; this one would fail if the spawn path went back
## to the workspace directory or dropped the argument.
func test_a_real_terminal_child_starts_in_the_pane_directory():
	if OS.get_name() == "Windows":
		# The hold idiom is POSIX (`sh -c "pwd; sleep"`), and a child that exits
		# at once can be gone before the pane is read; the spawn plumbing above
		# covers the same resolution on Windows.
		pending("a PTY child's cwd read needs the POSIX hold idiom here")
		return
	var ws = await _make_workspace()
	var container: Dictionary = ws._workspaces[0]
	var ws_id := str(container.get("id", ""))
	var own := _temp_dir("real-child")
	PaneCwdStore.set_dir(ws_id, "probe-pane", own)

	var body = ws._tm.create_body("terminal")
	body.apply_settings({"attachment_id": "probe-pane"})
	body.shell_command = "/bin/sh"
	body.shell_args = ["-c", "pwd; sleep 4"]
	var w = ws._tm._build_wrapper_body(body, "Probe")
	ws._attach_pane_into(container, w, body)
	ws._tm.tiles.append({wrapper = w, col = 0, row = 0,
		cspan = PaneTypes.GRID, rspan = PaneTypes.GRID})
	ws._apply_layout()

	var text := ""
	var deadline := Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < deadline:
		text = str(body._terminal.get_plain_text(50))
		if text.contains(own):
			break
		await get_tree().create_timer(0.1).timeout
	assert_true(text.contains(own),
		"the child must start in the pane's own directory, not the workspace's: %s" % text)

## Both spawn paths, one workspace, no configured directory: each child prints
## its own cwd, and they must agree. Before the fix a terminal started in the
## user's home while a `cli_view` inherited the GUI process's directory.
func test_a_terminal_and_a_cli_view_start_in_the_same_place():
	if OS.get_name() == "Windows":
		# The hold idiom is POSIX (`sh -c "pwd; sleep"`); the cli_view half is
		# covered on Windows by test_cli_view.gd.
		pending("a PTY child's cwd read needs the POSIX hold idiom here")
		return
	var home := PaneCwdStore.home_dir()
	if home == "" or not DirAccess.dir_exists_absolute(home):
		pending("this environment names no existing home directory")
		return
	var ws = await _make_workspace()
	var container: Dictionary = ws._workspaces[0]
	ws._workspaces[0]["cwd"] = ""
	assert_eq(str(container.get("cwd", "")), "", "the fixture needs no workspace directory")

	var term = ws._tm.create_body("terminal")
	term.apply_settings({"attachment_id": "probe-cwd-terminal"})
	term.shell_command = "/bin/sh"
	term.shell_args = ["-c", "pwd; sleep 4"]
	var view = ws._tm.create_body("cli_view")
	view.apply_settings({"attachment_id": "probe-cwd-view"})
	view.command = "/bin/pwd"
	view.shell_args = []

	var placed: Array[Dictionary] = []
	for pair in [[term, 0], [view, 1]]:
		var body: Control = pair[0]
		var w = ws._tm._build_wrapper_body(body, "Probe")
		ws._attach_pane_into(container, w, body)
		placed.append({
			"wrapper": w,
			"col": int(pair[1]) * PaneTypes.GRID / 2,
			"row": 0,
			"cspan": PaneTypes.GRID / 2,
			"rspan": PaneTypes.GRID,
		})
	ws._tm.tiles.append_array(placed)
	ws._apply_layout()

	var term_text := ""
	var view_text := ""
	var deadline := Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline:
		if term._terminal != null:
			term_text = str(term._terminal.get_plain_text(50))
		view_text = view.get_text()
		if term_text.contains(home) and view_text.contains(home):
			break
		await get_tree().create_timer(0.1).timeout
	assert_true(term_text.contains(home),
		"the terminal must start in the home directory %s: %s" % [home, term_text])
	assert_true(view_text.contains(home),
		"the cli_view must start in the same directory %s: %s" % [home, view_text])

func test_a_usable_override_wins_over_the_workspace_directory():
	var ws = await _make_workspace()
	var container: Dictionary = ws._workspaces[0]
	ws._workspaces[0]["cwd"] = _temp_dir("ws-base")
	var own := _temp_dir("own")
	PaneCwdStore.set_dir(str(container["id"]), "agent-terminal", own)
	var body = _restored_terminal(ws, container)
	assert_not_null(body)
	assert_eq(body.spawn_cwd(), own, "the pane's own directory is the first layer")

func test_a_profile_tile_cannot_carry_a_directory():
	var ws = await _make_workspace()
	var dir := _temp_dir("profile")
	ws._apply_workspace_cwd(0, dir)
	var from_the_tile := _temp_dir("from-the-tile")
	# Every spelling a crafted tile could try: the table's key, the property
	# name, and the legacy `cwd`.
	ws._do_activate({"name": "P", "tiles": [_tile({
		"type": "terminal",
		"pane_cwd": from_the_tile,
		"cwd": from_the_tile,
		"workspace_cwd": from_the_tile,
	})]}, false)
	await get_tree().process_frame
	var body = _first_body(ws)
	assert_not_null(body)
	assert_eq(body.pane_cwd, "", "a profile tile cannot choose a directory")
	assert_eq(body.workspace_cwd, dir, "the workspace owns the directory")
	assert_eq(body.spawn_cwd(), dir, "the resolution ignores the tile's attempt")

# ── The Pane Settings row ──────────────────────────────────────────────

func test_clearing_the_directory_inherits_again():
	var ws = await _make_workspace()
	var container: Dictionary = ws._workspaces[0]
	var ws_id := str(container.get("id", ""))
	var dir := _temp_dir("clear")
	PaneCwdStore.set_dir(ws_id, "agent-terminal", dir)
	var body = _restored_terminal(ws, container)
	assert_not_null(body)

	var panel := FakePanePanel.new()
	add_child(panel)
	var ui: Control = body._build_pane_settings_ui(panel)
	add_child(ui)
	var block: Control = ui.find_child("PaneDirectoryBlock", true, false)
	assert_not_null(block, "the settings UI must show a Directory block")
	assert_eq(str(block.get_meta("path", "")), dir,
		"the row opens on the pane's stored directory")
	var value_btn := _button_named(block, "PaneDirectory")
	assert_eq(value_btn.text, dir, "a set directory is shown as the value")

	var clear := _button_texted(block, "Use workspace directory")
	assert_not_null(clear)
	assert_false(clear.disabled, "the clear action is available while a directory is set")
	clear.pressed.emit()
	assert_eq(str(block.get_meta("path", "")), "", "clearing leaves the field empty")
	assert_true(clear.disabled, "nothing left to clear")
	assert_true(value_btn.text.begins_with("Inherits"),
		"an empty field names what it inherits: %s" % value_btn.text)

	# The panel's two steps, in order: apply the gathered settings, then let the
	# workspace write the stores.
	var gathered: Dictionary = panel._gather_func.call()
	assert_eq(str(gathered.get("pane_cwd", "")), "")
	body.apply_settings(gathered)
	ws._tm._pane_settings_panel.settings_applied.emit(body, gathered, body.attachment_id)
	assert_eq(PaneCwdStore.dir_for(ws_id, "agent-terminal"), "",
		"the cleared value removes the entry, so the pane inherits again")

	panel.free()
	ui.free()
