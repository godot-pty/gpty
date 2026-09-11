extends GutTest
# Store corruption handling: a store is user-editable and can be half-written,
# so one value of the wrong type must cost that value — not every key after it.
#
# GDScript used to raise on `int([1, 2])`, on assigning an Array to an `int`
# variable, and on calling `.get()` on a String, which aborted the loader at
# that line. Everything after the bad key was dropped, and the next save wrote
# the reduced state back over the file, making the loss permanent: a whole
# workspace set, or every setting.

func before_each():
	MockAutoloads.setup()

func after_each():
	MockAutoloads.teardown()

# ── Settings ───────────────────────────────────────────────────────────

func test_settings_load_the_keys_after_a_wrong_typed_one():
	SettingsManager.cfg_cursor_shape = 9
	SettingsManager.cfg_font_size = 9
	SettingsManager.cfg_check_updates = true
	MockAutoloads.set_store(SettingsManager.SETTINGS_FILE, {
		"cursor_shape": [1, 2],            # an object where an int belongs
		"history_lines": {"n": 1000},      # and another
		"window_position": "everywhere",   # a String where a Vector2i belongs
		"wrapper_bg": 42,                  # a number where a hex colour belongs
		"font_size": 19,
		"check_updates": false,
	})

	SettingsManager.load_settings()

	assert_eq(SettingsManager.cfg_cursor_shape, 0, "a wrong type falls back")
	assert_eq(SettingsManager.cfg_history_lines, 10000, "so does a wrong-shaped object")
	assert_eq(SettingsManager.cfg_window_position, Vector2i(100, 100))
	assert_eq(
		SettingsManager.cfg_font_size, 19,
		"keys after the wrong-typed ones must still load"
	)
	assert_eq(SettingsManager.cfg_check_updates, false, "including the last key")

func test_settings_accept_numbers_stored_as_floats():
	MockAutoloads.set_store(SettingsManager.SETTINGS_FILE, {"font_size": 13.0})
	SettingsManager.load_settings()
	assert_eq(SettingsManager.cfg_font_size, 13, "JSON numbers are not all ints")

func test_settings_window_pair_keeps_its_good_member():
	MockAutoloads.set_store(SettingsManager.SETTINGS_FILE, {
		"window_size": {"x": "wide", "y": 720},
	})
	SettingsManager.load_settings()
	# The bad member falls back to the default, the good one is kept: the
	# loader reads a file, it does not merge with whatever is in memory.
	assert_eq(SettingsManager.cfg_window_size, Vector2i(1920, 720))

# ── Workspaces ─────────────────────────────────────────────────────────

func test_workspaces_survive_a_wrong_typed_container():
	MockAutoloads.set_store(WorkspaceStore.FILE, {
		"active": [3],                 # not an int
		"workspaces": "not a list",    # not a list
	})

	var d = WorkspaceStore.load()

	assert_eq(d["workspaces"].size(), 0)
	assert_eq(d["active"], 0, "a bad active index falls back instead of aborting")

func test_workspaces_keep_good_entries_around_junk():
	MockAutoloads.set_store(WorkspaceStore.FILE, {
		"active": 1,
		"workspaces": [
			{"name": "first", "layout": [{"row": 0}]},
			"junk entry",
			{"name": "second", "layout": "not a list"},
		],
	})

	var d = WorkspaceStore.load()

	assert_eq(d["workspaces"].size(), 2, "junk is skipped, good entries are kept")
	assert_eq(d["workspaces"][0]["name"], "first")
	assert_eq(d["workspaces"][1]["name"], "second")
	assert_eq(d["active"], 1)

func test_an_empty_workspace_list_is_a_valid_store():
	# The clamp used to be clampf(value, 0, size - 1) — an error of its own
	# when the list is empty, which is exactly what a fresh store looks like.
	MockAutoloads.set_store(WorkspaceStore.FILE, {"active": 0, "workspaces": []})

	var d = WorkspaceStore.load()

	assert_eq(d["workspaces"].size(), 0)
	assert_eq(d["active"], 0)

# ── Profiles ───────────────────────────────────────────────────────────

func test_profiles_survive_a_wrong_typed_container():
	MockAutoloads.set_store(ProfileManager.PROFILES_FILE, {"profiles": {"not": "a list"}})

	ProfileManager.load_profiles()

	assert_eq(ProfileManager.profiles.size(), 0, "a bad container is not fatal")

func test_profiles_keep_dictionary_entries_around_junk():
	MockAutoloads.set_store(ProfileManager.PROFILES_FILE, {
		"profiles": [{"name": "kept"}, "junk", 7],
	})

	ProfileManager.load_profiles()

	assert_eq(ProfileManager.profiles.size(), 1)
	assert_eq(ProfileManager.profiles[0].get("name"), "kept")
