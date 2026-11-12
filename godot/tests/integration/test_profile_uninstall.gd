extends GutTest
# The plugin-profile trash: the sidebar confirms in place, the workspace
# clears the accents and refreshes the plugin content after the FFI answers.

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
	MockAutoloads.set_store(WorkspaceStore.FILE, {
		"active": 0, "workspaces": [{"name": "W", "layout": []}],
	})
	var ws: Control = WorkspaceScript.new()
	_ws = ws
	ws.size = Vector2(1200, 800)
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame
	return ws

func _plugin_json() -> String:
	return JSON.stringify([{
		"plugin_id": "godot-pty/gpty-omp", "revision": "a1b2c3d4e5f6",
		"name": "OMP",
		"tiles": [{"col": 0, "row": 0, "cspan": 60, "rspan": 60,
			"settings": {"type": "terminal", "command": "omp"}}],
	}])

func _seed_plugin(ws: Control):
	ProfileManager.plugin_profiles_source = func(): return _plugin_json()
	ProfileManager.refresh_plugin_profiles()
	ws._workspaces[0]["profile"] = "OMP"
	ws._active_profile = "OMP"
	ws._refresh_profile_buttons()

func test_uninstalling_clears_accents_and_removes_the_rows():
	var ws := await _make_workspace()
	_seed_plugin(ws)
	await get_tree().process_frame
	assert_false(ProfileManager.find_profile("OMP").is_empty(),
		"precondition: the plugin profile is visible")

	ConceptManager.plugin_concepts_source = func(): return "[]"
	ProfileManager.plugin_uninstall_source = func(plugin_id: String) -> String:
		ProfileManager.plugin_profiles_source = func(): return "[]"
		return JSON.stringify({"ok": true, "id": plugin_id, "warnings": []})
	ws._uninstall_profile_plugin("godot-pty/gpty-omp")
	await get_tree().process_frame

	assert_true(ProfileManager.find_profile("OMP").is_empty(),
		"the uninstalled plugin's profile leaves the list")
	assert_eq(str(ws._workspaces[0].get("profile", "")), "",
		"a workspace built from the profile loses its accent")
	assert_eq(ws._active_profile, "", "the active accent is cleared")
	assert_null(ws._sidebar._profile_list.get_child(0).get_node_or_null("ProfileUninstallBtn"),
		"the sidebar row is rebuilt without the plugin trash")
	ConceptManager.plugin_concepts_source = Callable()
	await get_tree().create_timer(2.1).timeout

func test_a_refused_uninstall_leaves_the_profile_in_place():
	var ws := await _make_workspace()
	_seed_plugin(ws)
	await get_tree().process_frame

	ProfileManager.plugin_uninstall_source = func(_plugin_id: String) -> String:
		return JSON.stringify({"ok": false, "error": "not installed"})
	ws._uninstall_profile_plugin("godot-pty/gpty-omp")

	assert_false(ProfileManager.find_profile("OMP").is_empty(),
		"a refused uninstall must not remove the row")
	assert_eq(str(ws._workspaces[0].get("profile", "")), "OMP",
		"and must not clear the workspace's accent")
	assert_eq(ws._active_profile, "OMP")
	assert_not_null(ws._sidebar._profile_list.get_child(0).get_node_or_null("ProfileUninstallBtn"))
	await get_tree().create_timer(2.1).timeout
