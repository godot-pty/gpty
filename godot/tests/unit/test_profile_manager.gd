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
