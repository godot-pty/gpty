extends GutTest
# Unit tests for ProfileManager — profile CRUD and serialization.

func before_each():
	MockAutoloads.setup()

func after_each():
	MockAutoloads.teardown()

func test_add_and_get_profiles():
	ProfileManager.add_profile("Dev", [{"col": 0, "row": 0, "cspan": 12, "rspan": 12}])
	var profs = ProfileManager.get_profiles()
	assert_eq(profs.size(), 1)
	assert_eq(profs[0].get("name"), "Dev")

func test_add_empty_name_ignored():
	ProfileManager.add_profile("", [])
	var profs = ProfileManager.get_profiles()
	assert_eq(profs.size(), 0, "empty name should be ignored")

func test_delete_profile():
	ProfileManager.add_profile("A", [])
	ProfileManager.add_profile("B", [])
	assert_eq(ProfileManager.get_profiles().size(), 2)
	ProfileManager.delete_profile(0)
	var profs = ProfileManager.get_profiles()
	assert_eq(profs.size(), 1)
	assert_eq(profs[0].get("name"), "B")

func test_delete_out_of_bounds_ignored():
	ProfileManager.add_profile("Only", [])
	ProfileManager.delete_profile(99)
	assert_eq(ProfileManager.get_profiles().size(), 1)

func test_save_load_roundtrip():
	ProfileManager.add_profile("MyProfile", [
		{"col": 0, "row": 0, "cspan": 6, "rspan": 12, "settings": {"type": "terminal", "shell": "/bin/zsh"}},
	])

	# Verify persistence via in-memory store
	var profs = ProfileManager.get_profiles()
	assert_eq(profs.size(), 1)
	assert_eq(profs[0].get("name"), "MyProfile")
	assert_eq(profs[0].get("tiles", []).size(), 1)

func test_duplicate_name_gets_suffixed():
	ProfileManager.add_profile("Dev", [])
	ProfileManager.add_profile("Dev", [])
	ProfileManager.add_profile("Dev", [])
	var profs = ProfileManager.get_profiles()
	assert_eq(profs.size(), 3)
	# Names should be: Dev, Dev (2), Dev (3)
	assert_eq(profs[0].get("name"), "Dev")
	assert_eq(profs[1].get("name"), "Dev (2)")
	assert_eq(profs[2].get("name"), "Dev (3)")

func test_update_profile():
	ProfileManager.add_profile("Old", [])
	var idx = 0
	ProfileManager.update_profile(idx, "New", [{"col": 1, "row": 1}])
	var profs = ProfileManager.get_profiles()
	assert_eq(profs[idx].get("name"), "New")
	assert_eq(profs[idx].get("tiles", []).size(), 1)

func test_profiles_changed_emits():
	watch_signals(ProfileManager)
	ProfileManager.add_profile("Test", [])
	assert_signal_emitted(ProfileManager, "profiles_changed")

func test_rename_profile_roundtrip():
	ProfileManager.add_profile("Old Name", [])
	var idx = ProfileManager.profiles.size() - 1
	var renamed = ProfileManager.rename_profile(idx, "New Name")
	assert_eq(renamed, "New Name")
	assert_eq(ProfileManager.profiles[idx].get("name"), "New Name")

func test_rename_profile_dedupes_collisions():
	ProfileManager.add_profile("Alpha", [])
	ProfileManager.add_profile("Beta", [])
	var renamed = ProfileManager.rename_profile(1, "Alpha")
	assert_eq(renamed, "Alpha (2)", "colliding rename must get the dedupe suffix")

func test_rename_profile_rejects_invalid():
	assert_eq(ProfileManager.rename_profile(99, "X"), "", "out-of-range index must fail")
	ProfileManager.add_profile("Real", [])
	var idx = ProfileManager.profiles.size() - 1
	assert_eq(ProfileManager.rename_profile(idx, "   "), "", "blank name must fail")
	# Renaming to its own name is a no-op returning the same name.
	assert_eq(ProfileManager.rename_profile(idx, "Real"), "Real")

# ── Installed-plugin profiles ──────────────────────────────────────────
#
# The seam stands in for `GptyTerminal.installed_plugin_profiles()`: the JSON
# the CLI writes when it installs a plugin, one entry per profile.

func _set_plugin_json(text: String):
	ProfileManager.plugin_profiles_source = func(): return text
	ProfileManager.refresh_plugin_profiles()

func _installed(name: String, plugin_id := "godot-pty/gpty-omp", revision := "a1b2c3d4e5f6") -> Dictionary:
	return {
		"plugin_id": plugin_id,
		"revision": revision,
		"name": name,
		"tiles": [{"col": 0, "row": 0, "cspan": 60, "rspan": 60,
			"settings": {"type": "terminal", "command": "omp"}}],
	}

func test_plugin_profiles_merge_between_builtins_and_user_profiles():
	# A builtin read from the shipped defaults, a user profile, and one
	# installed plugin profile.
	MockAutoloads.set_store(ProfileManager.DEFAULTS_FILE, {"profiles": [
		{"id": "builtin", "name": "Built-in", "tiles": []},
	]})
	ProfileManager._load_defaults()
	ProfileManager.add_profile("Mine", [])
	_set_plugin_json(JSON.stringify([_installed("OMP")]))

	var all := ProfileManager.get_all_profiles()
	assert_eq(all.size(), 3, "builtin + plugin + user")
	assert_eq(all[0].get("name"), "Built-in")
	assert_eq(all[1].get("name"), "OMP")
	assert_eq(all[2].get("name"), "Mine")
	assert_true(all[1].get("plugin", false), "a plugin profile is marked as one")
	assert_eq(all[1].get("plugin_id"), "godot-pty/gpty-omp")
	assert_eq(all[1].get("revision"), "a1b2c3d4e5f6")
	assert_eq((all[1].get("tiles") as Array).size(), 1, "the plugin's tiles come through as they are")
	assert_false(all[1].has("_user_index"), "a plugin profile is not a user profile")
	assert_eq(all[2].get("_user_index"), 0, "user rows keep the delete/rename index space")

	# The plugin's own profiles never land in the user store.
	assert_eq(ProfileManager.get_profiles().size(), 1, "only the user profile is persisted")
	assert_eq(MockAutoloads.get_store(ProfileManager.PROFILES_FILE).get("profiles", []).size(), 1)

func test_find_profile_resolves_an_installed_plugin_profile():
	_set_plugin_json(JSON.stringify([_installed("OMP")]))
	var found := ProfileManager.find_profile("OMP")
	assert_false(found.is_empty(), "find_profile must see installed plugin profiles")
	assert_eq(found.get("plugin_id"), "godot-pty/gpty-omp")
	assert_eq(found.get("revision"), "a1b2c3d4e5f6")
	var tiles: Array = found.get("tiles", [])
	assert_eq(tiles.size(), 1)
	assert_eq(tiles[0]["settings"]["command"], "omp", "the plugin's tiles arrive unmodified")

func test_user_profile_keeps_the_bare_name_when_a_plugin_collides():
	ProfileManager.add_profile("OMP", [])
	_set_plugin_json(JSON.stringify([_installed("OMP")]))

	var all := ProfileManager.get_all_profiles()
	assert_eq(all[0].get("name"), "OMP (2)", "the plugin profile yields the name")
	assert_true(all[0].get("plugin", false))
	assert_eq(all[1].get("name"), "OMP", "the user profile keeps the bare name")
	assert_false(all[1].get("plugin", false))

func test_builtin_keeps_the_bare_name_when_a_plugin_collides():
	MockAutoloads.set_store(ProfileManager.DEFAULTS_FILE, {"profiles": [
		{"id": "omp", "name": "OMP", "tiles": []},
	]})
	ProfileManager._load_defaults()
	_set_plugin_json(JSON.stringify([_installed("OMP")]))

	var all := ProfileManager.get_all_profiles()
	assert_eq(all[0].get("name"), "OMP", "the builtin keeps the bare name")
	assert_true(all[0].get("builtin", false))
	assert_eq(all[1].get("name"), "OMP (2)", "the plugin profile takes the suffix")
	assert_true(all[1].get("plugin", false))

func test_plugin_profiles_dedupe_among_themselves():
	_set_plugin_json(JSON.stringify([
		_installed("OMP", "godot-pty/gpty-omp"),
		_installed("OMP", "godot-pty/gpty-omp-alt", "f6e5d4c3b2a1"),
		_installed("OMP", "godot-pty/gpty-omp-third", "0123456789ab"),
	]))

	var all := ProfileManager.get_all_profiles()
	assert_eq(all.size(), 3)
	assert_eq(all[0].get("name"), "OMP", "the first plugin profile keeps the name")
	assert_eq(all[1].get("name"), "OMP (2)")
	assert_eq(all[2].get("name"), "OMP (3)")
	assert_eq(all[0].get("plugin_id"), "godot-pty/gpty-omp")
	assert_eq(all[2].get("plugin_id"), "godot-pty/gpty-omp-third")

func test_a_plugin_profile_yields_a_name_the_user_takes_later():
	_set_plugin_json(JSON.stringify([_installed("OMP")]))
	assert_eq(ProfileManager.get_all_profiles()[0].get("name"), "OMP")

	# The user saves their own "OMP" while the plugin is installed. The name is
	# theirs, so the plugin yields it now — not at the next launch, where
	# `get_all_profiles` would have listed the plugin first and resolved a click
	# on the user's row (and `layoutLoad "OMP"`) to the plugin's profile.
	ProfileManager.add_profile("OMP", [])

	var all := ProfileManager.get_all_profiles()
	assert_eq(all[0].get("name"), "OMP (2)", "the plugin yields the name it was holding")
	assert_true(all[0].get("plugin", false))
	assert_eq(all[1].get("name"), "OMP", "the user profile keeps the bare name")
	assert_eq(ProfileManager.find_profile("OMP").get("_user_index"), 0,
		"the bare name resolves to the user's profile, not the plugin's")

func test_deleting_a_user_profile_gives_the_name_back_to_the_plugin():
	_set_plugin_json(JSON.stringify([_installed("OMP")]))
	ProfileManager.add_profile("OMP", [])
	assert_eq(ProfileManager.get_all_profiles()[0].get("name"), "OMP (2)")

	ProfileManager.delete_profile(0)
	assert_eq(ProfileManager.get_all_profiles()[0].get("name"), "OMP",
		"with the user profile gone the plugin holds the bare name again")

func test_garbage_plugin_json_yields_no_profiles():
	for garbage in ["", "not json", "{}", "[1, \"x\", null]"]:
		_set_plugin_json(garbage)
		assert_eq(ProfileManager.get_all_profiles().size(), 0,
			"\"%s\" must yield no plugin profiles" % garbage)

func test_malformed_plugin_entries_are_skipped_not_fatal():
	_set_plugin_json(JSON.stringify([
		{"plugin_id": "godot-pty/gpty-omp", "revision": "a1b2c3d4e5f6", "tiles": []},
		{"plugin_id": "godot-pty/gpty-omp", "revision": "a1b2c3d4e5f6", "name": "OMP", "tiles": "not a list"},
		_installed("Herdr", "godot-pty/gpty-herdr", "c0ffee123456"),
	]))

	var all := ProfileManager.get_all_profiles()
	assert_eq(all.size(), 1, "only the complete entry survives")
	assert_eq(all[0].get("name"), "Herdr")

func test_refresh_plugin_profiles_replaces_the_installed_set():
	_set_plugin_json(JSON.stringify([_installed("OMP")]))
	assert_eq(ProfileManager.get_all_profiles().size(), 1)

	# A second refresh answers with the plugin uninstalled.
	_set_plugin_json("[]")
	assert_eq(ProfileManager.get_all_profiles().size(), 0, "an uninstalled plugin leaves nothing behind")

func test_refresh_plugin_profiles_emits_profiles_changed():
	watch_signals(ProfileManager)
	_set_plugin_json(JSON.stringify([_installed("OMP")]))
	assert_signal_emitted(ProfileManager, "profiles_changed")
