extends GutTest
# Integration tests: a workspace directory is a trust input only where the
# spawn is already untrusted.
#
# `workspaces.json` supplies each workspace's `cwd`, and a plain shell may
# restore in it without a prompt (a directory is not executable, and asking at
# every launch would train the user to dismiss the dialog). A tile that also
# names a program or argv is approved together with that directory — the plan
# key carries it — so editing the store cannot repoint an approved program at
# attacker-chosen content. The picker applies the same rule to a live
# workspace: it asks only when a change would move an untrusted plan.

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

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

## A real Workspace over the (mocked) store. Free any previous one first:
## its `_exit_tree()` save would overwrite a store a test just seeded.
func _make_workspace() -> Control:
	_free_workspace()
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame
	return ws

## An existing absolute directory in the throwaway user-data dir.
func _temp_dir(slug: String) -> String:
	var dir := OS.get_user_data_dir().path_join(
		"gpty-test-%s-%d" % [slug, Time.get_ticks_usec()])
	DirAccess.make_dir_absolute(dir)
	_dirs.append(dir)
	return dir

## A shell that exists here and is not the configured default — an untrusted
## tile needs a program that could actually spawn once the dialog is answered.
func _other_shell() -> String:
	return "cmd.exe" if OS.get_name() == "Windows" else "/bin/sh"

func _tile(settings: Dictionary) -> Dictionary:
	return {
		"col": 0, "row": 0, "cspan": PaneTypes.GRID, "rspan": PaneTypes.GRID,
		"settings": settings,
	}

func _seed_workspace(cwd: String, settings: Dictionary):
	MockAutoloads.set_store(WorkspaceStore.FILE, {
		"active": 0,
		"workspaces": [{"name": "Crafted", "cwd": cwd, "layout": [_tile(settings)]}],
	})

func _dialogs() -> Array:
	var out: Array = []
	for child in _ws.get_children():
		if child is ConfirmationDialog:
			out.append(child)
	return out

func _first_body() -> Control:
	var tm: TerminalManager = _ws._tm
	if tm.tiles.is_empty():
		return null
	return tm._find_body(tm.tiles[0].wrapper)

func _stored_cwd() -> String:
	var saved: Array = WorkspaceStore.load().get("workspaces", [])
	if saved.is_empty() or not (saved[0] is Dictionary):
		return ""
	return str(saved[0].get("cwd", ""))

# ── Restore: the workspace file's directory ────────────────────────────

func test_a_crafted_directory_is_shown_when_a_tile_names_a_program():
	var dir := _temp_dir("crafted")
	_seed_workspace(dir, {"type": "terminal", "command": _other_shell()})

	var ws = await _make_workspace()

	assert_eq(ws._workspaces.size(), 0, "an untrusted plan must stop the restore")
	var dialogs := _dialogs()
	assert_eq(dialogs.size(), 1, "the Workspace Trust dialog gates the restore")
	var text: String = dialogs[0].dialog_text
	assert_string_contains(text, dir, "the dialog names the directory the plan would start in")
	assert_string_contains(text, _other_shell(), "the dialog names the program")
	assert_string_contains(text, "Crafted", "the dialog names the workspace")

	dialogs[0].confirmed.emit()
	await get_tree().process_frame
	assert_eq(ws._workspaces.size(), 1, "confirming restores the workspace")
	var body = _first_body()
	assert_not_null(body)
	assert_eq(body.workspace_cwd, dir, "the accepted plan starts in the directory it named")

func test_a_plain_shell_in_a_file_supplied_directory_restores_without_asking():
	var dir := _temp_dir("plain")
	_seed_workspace(dir, {"type": "terminal"})

	var ws = await _make_workspace()

	assert_eq(_dialogs().size(), 0, "a directory alone is not a trust decision")
	assert_eq(ws._workspaces.size(), 1, "the workspace restores directly")
	var body = _first_body()
	assert_not_null(body)
	assert_eq(body.workspace_cwd, dir, "the accepted case starts in the file's directory")

func test_an_approved_plan_does_not_cover_another_directory():
	# The consent record from a builtin activation names the directory it was
	# approved for; a crafted store that keeps the program but moves the
	# directory is a new decision (the next step the trust gate exists for).
	var approved_dir := _temp_dir("approved")
	var crafted_dir := _temp_dir("repointed")
	var program := _other_shell()
	var approved_tile := _tile({"type": "terminal", "command": program})
	TrustedStore.approve_builtin(
		"Demo", GptyTerminal.get_app_version(),
		[PaneTypes.tile_plan_key(approved_tile, approved_dir)])

	_seed_workspace(approved_dir, {"type": "terminal", "command": program})
	var ws = await _make_workspace()
	assert_eq(_dialogs().size(), 0, "the approved directory restores silently")
	assert_eq(ws._workspaces.size(), 1)

	_free_workspace()
	_seed_workspace(crafted_dir, {"type": "terminal", "command": program})
	ws = await _make_workspace()
	var dialogs := _dialogs()
	assert_eq(dialogs.size(), 1, "another directory re-prompts")
	assert_string_contains(dialogs[0].dialog_text, crafted_dir)

# ── Picker: a live workspace's directory change ────────────────────────

func test_the_picker_asks_only_for_a_workspace_with_untrusted_tiles():
	var dir_a := _temp_dir("picker-a")
	var dir_b := _temp_dir("picker-b")
	var ws = await _make_workspace()
	assert_eq(ws._workspaces.size(), 1)

	# A workspace of default shells: the change is silent and persists.
	ws._set_workspace_cwd(0, dir_a)
	assert_eq(_dialogs().size(), 0, "a plain workspace changes directory without a prompt")
	assert_eq(str(ws._workspaces[0].get("cwd")), dir_a)
	assert_eq(_stored_cwd(), dir_a, "the picked directory reaches the store")

	# Give the workspace an untrusted tile: moving it is now a decision.
	# (`shell_command` is the terminal's runtime program key; a file's
	# `command`/`shell` are restore-only keys and the live pane saves its
	# program as `shell`.)
	assert_not_null(ws._spawn_pane("terminal", {"shell_command": _other_shell()}))
	await get_tree().process_frame
	ws._set_workspace_cwd(0, dir_b)
	var dialogs := _dialogs()
	assert_eq(dialogs.size(), 1, "an untrusted tile turns the change into a decision")
	assert_string_contains(dialogs[0].dialog_text, dir_b, "the dialog names the new directory")
	assert_string_contains(dialogs[0].dialog_text, _other_shell())

	dialogs[0].canceled.emit()
	await get_tree().process_frame
	assert_eq(str(ws._workspaces[0].get("cwd")), dir_a, "canceling keeps the current directory")
	assert_eq(_stored_cwd(), dir_a, "canceling writes nothing")

	ws._set_workspace_cwd(0, dir_b)
	_dialogs()[0].confirmed.emit()
	await get_tree().process_frame
	assert_eq(str(ws._workspaces[0].get("cwd")), dir_b, "confirming applies the directory")
	assert_eq(_stored_cwd(), dir_b, "confirming persists it")

func test_a_picked_directory_persists_and_restores():
	var dir := _temp_dir("persist")
	var ws = await _make_workspace()
	ws._set_workspace_cwd(0, dir)
	assert_eq(str(ws._workspaces[0].get("cwd")), dir)

	# A fresh Workspace reads the store it wrote and starts its pane there.
	ws = await _make_workspace()
	assert_eq(ws._workspaces.size(), 1)
	var body = _first_body()
	assert_not_null(body)
	assert_eq(body.workspace_cwd, dir, "the restored pane takes the picked directory")

# ── A tile cannot choose the directory ─────────────────────────────────

func test_a_profile_tile_cannot_carry_a_directory():
	var dir := _temp_dir("profile")
	var ws = await _make_workspace()
	ws._apply_workspace_cwd(0, dir)

	# Both the property name and a would-be settings key: neither is a tile
	# field, so the workspace's directory is what reaches the pane.
	ws._do_activate({"name": "P", "tiles": [
		_tile({
			"type": "terminal",
			"cwd": "/tmp/from-the-tile",
			"workspace_cwd": "/tmp/from-the-tile",
		}),
	]}, false)
	await get_tree().process_frame

	var body = _first_body()
	assert_not_null(body)
	assert_eq(body.workspace_cwd, dir,
		"the workspace owns the directory; a profile tile cannot choose one")
