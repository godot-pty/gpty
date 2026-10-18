extends GutTest
# The pane-request contract end to end: a pane asks its workspace for another
# pane (the file tree's "open in a viewer" is the first origin), the workspace
# spawns through its only spawner and activates the result, and a viewer that
# already shows the same file is focused instead of duplicated — a viewer's
# scroll, selection and mode belong to its document.
#
# One workspace for the whole script, like `test_pane_close_guard.gd`: each
# instance schedules a deferred concept push 2 s after `_ready`. The panes
# here hold no PTYs; the workspace's own startup terminal is reset after each
# test, so nothing accumulates.

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

var _ws: Control
var _tmp: String
var _file_a: String
var _file_b: String


func before_all():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()
	SettingsManager.cfg_default_rows = 24
	SettingsManager.cfg_default_cols = 80
	ConceptManager.plugin_concepts_source = func(): return "[]"
	ConceptManager.refresh_plugin_concepts()
	_tmp = ProjectSettings.globalize_path("user://pane_open_request")
	DirAccess.make_dir_recursive_absolute(_tmp)
	_file_a = _write(_tmp.path_join("a.md"), "# A\n")
	_file_b = _write(_tmp.path_join("b.md"), "# B\n")
	_ws = WorkspaceScript.new()
	add_child(_ws)
	_ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame


func after_all():
	# Let the workspace's deferred concept push land while it is still alive.
	await get_tree().create_timer(2.1).timeout
	remove_child(_ws)
	_ws.free()
	_ws = null
	_remove_tree(_tmp)
	ConceptManager.plugin_concepts_source = Callable()
	ConceptManager._plugin_concept_entries = []
	MockAutoloads.teardown()


func after_each():
	for ws in _ws._workspaces:
		ws.tm.reset()
	await get_tree().process_frame


func _write(path: String, text: String) -> String:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	return path


func _remove_tree(path: String):
	var dir := DirAccess.open(path)
	if dir:
		for f in dir.get_files():
			DirAccess.remove_absolute(path.path_join(f))
		for d in dir.get_directories():
			_remove_tree(path.path_join(d))
	DirAccess.remove_absolute(path)


func _file_tree() -> Control:
	var body = _ws._spawn_pane("file_tree", {"root_path": _tmp})
	assert_not_null(body, "spawning a file tree must work")
	return body


func _viewers() -> Array:
	var found := []
	for t in _ws._tm.tiles:
		var body = _ws._tm._find_body(t.wrapper)
		if body is CodeViewerPane:
			found.append(body)
	return found


func test_a_request_spawns_and_activates_a_code_viewer():
	var tree := _file_tree()
	assert_eq(_viewers().size(), 0, "the request is what creates the viewer")

	tree.request_pane.emit("code_viewer", {"file_path": _file_a})

	var viewers := _viewers()
	assert_eq(viewers.size(), 1, "the request spawns exactly one viewer")
	assert_eq(viewers[0].file_path, _file_a, "the viewer opens the requested file")
	assert_eq(_ws._tm.last_body, viewers[0], "the new pane is activated")


func test_a_second_request_for_the_same_file_focuses_the_existing_viewer():
	var tree := _file_tree()
	tree.request_pane.emit("code_viewer", {"file_path": _file_a})
	var viewer = _viewers()[0]
	var tile_count: int = _ws._tm.tiles.size()
	_ws.activate_pane(tree)
	assert_ne(_ws._tm.last_body, viewer, "the test must start with another pane active")

	tree.request_pane.emit("code_viewer", {"file_path": _file_a})

	assert_eq(_ws._tm.tiles.size(), tile_count, "the same file must not get a second viewer")
	assert_eq(_ws._tm.last_body, viewer, "the existing viewer is focused")


func test_a_different_file_gets_its_own_viewer():
	var tree := _file_tree()
	tree.request_pane.emit("code_viewer", {"file_path": _file_a})
	tree.request_pane.emit("code_viewer", {"file_path": _file_b})

	assert_eq(_viewers().size(), 2, "side-by-side is the reason the grid exists")
	var active = _ws._tm.last_body
	assert_true(active is CodeViewerPane, "the newest viewer is activated")
	assert_eq(active.file_path, _file_b)


## The spawn surface stays closed even though the signal is reachable: only a
## registered pane type can be spawned.
func test_an_unknown_pane_type_is_refused():
	var tree := _file_tree()
	var tile_count: int = _ws._tm.tiles.size()
	tree.request_pane.emit("not_a_pane_type", {})
	assert_eq(_ws._tm.tiles.size(), tile_count, "an unregistered type must not spawn")
