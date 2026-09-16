extends BasePersistenceManager

const PROFILES_FILE = "user://profiles.json"
const DEFAULTS_FILE = "res://profiles.default.json"

var profiles: Array[Dictionary] = []
var _builtin_profiles: Array[Dictionary] = []
## Profiles installed with a plugin, refreshed from the extension. Never
## written back to PROFILES_FILE: the plugin owns them, and they disappear
## with the plugin.
var _plugin_profiles: Array[Dictionary] = []

## Test seam. When valid it answers with the same JSON the FFI returns, so
## the merge can be exercised without an install; otherwise the extension
## is asked (`installed_plugin_profiles()` — the CLI writes every installed
## plugin's validated profiles into the store and this reads them).
var plugin_profiles_source: Callable

signal profiles_changed

func _on_init():
	_load_defaults()
	load_profiles()
	refresh_plugin_profiles()

func _load_defaults():
	_builtin_profiles = []
	var data := _read_file(DEFAULTS_FILE)
	var raw = _as_array(data, "profiles", [])
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
	var raw: Array = _as_array(d, "profiles", [])
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


## Rename a user profile by its index (builtins are not in this list).
## Follows the add_profile dedupe convention: colliding names get a
## " (n)" suffix. Returns the final name, or "" when the index/name is
## invalid. Renaming to its own name is a no-op.
func rename_profile(index: int, p_name: String) -> String:
	if index < 0 or index >= profiles.size():
		return ""
	var base := p_name.strip_edges()
	if base == "" or base.length() > 128:
		return ""
	if base == str(profiles[index].get("name", "")):
		return base
	var result_name = base
	var n = 1
	while _name_exists(result_name):
		n += 1
		result_name = "%s (%d)" % [base, n]
	profiles[index]["name"] = result_name
	save_profiles()
	return result_name

func get_profiles() -> Array[Dictionary]:
	return profiles

## Rebuild the installed-plugin profiles from the extension's JSON:
## `[{"plugin_id": "owner/repo", "revision": "...", "name": "OMP",
## "tiles": [ ... ]}, ...]` — enabled plugins only, one entry per profile,
## `[]` when nothing is installed.
##
## The answer is store data like any other, so one bad entry costs itself: a
## non-array answer, a non-dict entry, or an entry with no usable name/tiles
## is skipped instead of raising. Every refresh emits `profiles_changed`, so
## the sidebar and the layout list pick the installed set up.
func refresh_plugin_profiles():
	_plugin_profiles = []
	var raw = _parse_plugin_profiles()
	if raw is Array:
		for item in raw:
			if not (item is Dictionary):
				continue
			var base := str(item.get("name", ""))
			var tiles = item.get("tiles")
			if base == "" or not (tiles is Array):
				continue
			_plugin_profiles.append({
				"name": _plugin_profile_name(base),
				"tiles": tiles,
				"plugin": true,
				"plugin_id": str(item.get("plugin_id", "")),
				"revision": str(item.get("revision", "")),
			})
	profiles_changed.emit()

func _plugin_profiles_json() -> String:
	if plugin_profiles_source.is_valid():
		return str(plugin_profiles_source.call())
	return str(GptyTerminal.installed_plugin_profiles())

## Parse that answer. `null` for anything that is not JSON — the extension
## answers `[]` when nothing is installed, so a parse failure means the store
## or the binding is broken, not that there are no profiles to show. Parsed
## through `JSON.new()` rather than `JSON.parse_string` so a bad answer is a
## value, not an engine error line.
func _parse_plugin_profiles():
	var j := JSON.new()
	if j.parse(_plugin_profiles_json()) != OK:
		return null
	return j.get_data()

## Resolve a plugin profile's name, mirroring add_profile's convention: a
## built-in or a user profile keeps the bare name and the plugin yields with
## the " (n)" suffix, and among plugin profiles the first one wins.
func _plugin_profile_name(base: String) -> String:
	var result_name := base
	var n := 1
	while _name_exists(result_name) or _plugin_profile_exists(result_name):
		n += 1
		result_name = "%s (%d)" % [base, n]
	return result_name

func _plugin_profile_exists(p_name: String) -> bool:
	for plugin_profile in _plugin_profiles:
		if str(plugin_profile.get("name", "")) == p_name:
			return true
	return false

## Built-ins, then installed-plugin profiles, then the user's own — the order
## the sidebar renders and the order `find_profile` resolves a `layoutLoad`
## name in.
func get_all_profiles() -> Array[Dictionary]:
	var all: Array[Dictionary] = []
	for builtin in _builtin_profiles:
		all.append(builtin.duplicate(true))
	for plugin_profile in _plugin_profiles:
		all.append(plugin_profile.duplicate(true))
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
