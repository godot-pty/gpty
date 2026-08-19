extends BasePersistenceManager

const PROFILES_FILE = "user://profiles.json"
const DEFAULTS_FILE = "res://profiles.default.json"

var profiles: Array[Dictionary] = []
var _builtin_profiles: Array[Dictionary] = []

signal profiles_changed

func _on_init():
	_load_defaults()
	load_profiles()

func _load_defaults():
	_builtin_profiles = []
	var data := _read_file(DEFAULTS_FILE)
	var raw = data.get("profiles", [])
	if not (raw is Array):
		return
	for item in raw:
		if item is Dictionary:
			var profile: Dictionary = item.duplicate(true)
			profile["builtin"] = true
			_builtin_profiles.append(profile)

func load_profiles():
	var d = _read_file(PROFILES_FILE)
	if d.is_empty(): return
	var raw: Array = d.get("profiles", [])
	profiles = []
	for item in raw:
		if item is Dictionary:
			profiles.append(item)

func save_profiles():
	var d = {"profiles": profiles}
	_write_file(PROFILES_FILE, d)
	profiles_changed.emit()

func add_profile(p_name: String, p_tiles: Array[Dictionary]):
	if p_name == "":
		return
	var result_name = p_name
	var base = p_name
	var n = 1
	while _name_exists(result_name):
		n += 1
		result_name = "%s (%d)" % [base, n]
	profiles.append({"name": result_name, "tiles": p_tiles})
	save_profiles()

func update_profile(index: int, p_name: String, p_tiles: Array[Dictionary]):
	if index < 0 or index >= profiles.size():
		return
	profiles[index] = {"name": p_name, "tiles": p_tiles}
	save_profiles()

func delete_profile(index: int):
	if index < 0 or index >= profiles.size():
		return
	profiles.remove_at(index)
	save_profiles()

func get_profiles() -> Array[Dictionary]:
	return profiles

func get_all_profiles() -> Array[Dictionary]:
	var all: Array[Dictionary] = []
	for builtin in _builtin_profiles:
		all.append(builtin.duplicate(true))
	for i in profiles.size():
		var profile: Dictionary = profiles[i].duplicate(true)
		profile["_user_index"] = i
		all.append(profile)
	return all

func find_profile(p_name: String) -> Dictionary:
	for profile in get_all_profiles():
		if profile.get("name", "") == p_name:
			return profile
	return {}

func _find_by_name(p_name: String) -> int:
	for i in profiles.size():
		if profiles[i].get("name", "") == p_name:
			return i
	return -1

func _name_exists(p_name: String) -> bool:
	if _find_by_name(p_name) != -1:
		return true
	for profile in _builtin_profiles:
		if profile.get("name", "") == p_name:
			return true
	return false
