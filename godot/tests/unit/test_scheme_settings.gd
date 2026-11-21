extends GutTest
# The dark/light scheme pair: which slot the resolved appearance selects, the
# old single-path key's one-shot migration, and the save that drops it.

var _saved_system_is_dark: Callable

func before_each():
	MockAutoloads.setup()
	_saved_system_is_dark = SettingsManager.system_is_dark
	SettingsManager.cfg_scheme_dark = ""
	SettingsManager.cfg_scheme_light = ""
	SettingsManager.cfg_appearance_mode = SettingsManager.APPEARANCE_DARK

func after_each():
	SettingsManager.system_is_dark = _saved_system_is_dark
	SettingsManager.cfg_scheme_dark = ""
	SettingsManager.cfg_scheme_light = ""
	SettingsManager.cfg_appearance_mode = SettingsManager.APPEARANCE_DARK
	SettingsManager.apply_appearance()
	MockAutoloads.teardown()

func _desktop(dark: bool) -> void:
	SettingsManager.system_is_dark = func() -> bool: return dark

func test_active_scheme_path_follows_the_resolved_appearance():
	SettingsManager.cfg_scheme_dark = "res://schemes/gruvbox-dark.json"
	SettingsManager.cfg_scheme_light = "res://schemes/one-light.json"

	SettingsManager.cfg_appearance_mode = SettingsManager.APPEARANCE_DARK
	assert_eq(SettingsManager.active_scheme_path(), "res://schemes/gruvbox-dark.json")

	SettingsManager.cfg_appearance_mode = SettingsManager.APPEARANCE_LIGHT
	assert_eq(SettingsManager.active_scheme_path(), "res://schemes/one-light.json")

	SettingsManager.cfg_appearance_mode = SettingsManager.APPEARANCE_SYSTEM
	_desktop(false)
	assert_eq(SettingsManager.active_scheme_path(), "res://schemes/one-light.json",
		"Follow system on a light desktop takes the light slot")
	_desktop(true)
	assert_eq(SettingsManager.active_scheme_path(), "res://schemes/gruvbox-dark.json",
		"Follow system on a dark desktop takes the dark slot")

func test_an_empty_light_slot_follows_the_dark_scheme():
	SettingsManager.cfg_scheme_dark = "res://schemes/nord.json"
	SettingsManager.cfg_scheme_light = ""

	SettingsManager.cfg_appearance_mode = SettingsManager.APPEARANCE_LIGHT
	assert_eq(SettingsManager.active_scheme_path(), "res://schemes/nord.json",
		"one chosen scheme still styles both modes")
	SettingsManager.cfg_appearance_mode = SettingsManager.APPEARANCE_SYSTEM
	_desktop(false)
	assert_eq(SettingsManager.active_scheme_path(), "res://schemes/nord.json")

func test_a_store_with_the_old_color_scheme_key_migrates_to_scheme_dark():
	MockAutoloads.set_store(SettingsManager.SETTINGS_FILE, {"color_scheme": "/tmp/old.txt"})
	SettingsManager.load_settings()
	assert_eq(SettingsManager.cfg_scheme_dark, "/tmp/old.txt",
		"the pre-0.8.6 single path becomes the dark slot")
	assert_eq(SettingsManager.cfg_scheme_light, "",
		"an old store has no light slot, so light follows dark")

func test_save_drops_the_old_color_scheme_key():
	MockAutoloads.set_store(SettingsManager.SETTINGS_FILE, {"color_scheme": "/tmp/old.txt"})
	SettingsManager.load_settings()
	SettingsManager.cfg_scheme_light = "res://schemes/one-light.json"
	SettingsManager.save_settings()
	var saved: Dictionary = MockAutoloads.get_store(SettingsManager.SETTINGS_FILE)
	assert_eq(saved.get("scheme_dark"), "/tmp/old.txt")
	assert_eq(saved.get("scheme_light"), "res://schemes/one-light.json")
	assert_false(saved.has("color_scheme"),
		"the migrated key is not written back; the loader's fallback is one-shot")
