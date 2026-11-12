extends BasePersistenceManager

const PROFILES_FILE = "user://profiles.json"
const DEFAULTS_FILE = "res://profiles.default.json"

var profiles: Array[Dictionary] = []
## The app-shipped layouts (`res://profiles.default.json`). They are a seed
## source, not sidebar rows: `_seed_defaults_once` copies them into `profiles`
## on first launch, after which they are ordinary user profiles.
var _default_profiles: Array[Dictionary] = []
## Whether the shipped defaults have been copied into `profiles` once.
var _seeded_defaults := false
## Profiles installed with a plugin, refreshed from the extension. Never
## written back to PROFILES_FILE: the plugin owns them, and they disappear
## with the plugin.
var _plugin_profiles: Array[Dictionary] = []
## The parsed store answer behind `_plugin_profiles`, kept so the display
## names can be re-derived without re-reading the store (see
## `_derive_plugin_profiles`). Untyped on purpose: the answer is store data,
## so it can be a non-array (a JSON object, or `null` for a parse failure)
## and a typed `Array` here would raise where the contract says skip.
var _plugin_profile_entries = []

## Test seam. When valid it answers with the same JSON the FFI returns, so
## the merge can be exercised without an install; otherwise the extension
## is asked (`installed_plugin_profiles()` — the CLI writes every installed
## plugin's validated profiles into the store and this reads them).
var plugin_profiles_source: Callable
## Test seam mirroring `plugin_profiles_source`: when valid it answers the
## same JSON `GptyTerminal.uninstall_plugin` does.
var plugin_uninstall_source: Callable

signal profiles_changed

func _on_init():
	_load_defaults()
	load_profiles()
	_seed_defaults_once()
	refresh_plugin_profiles()

## Load the shipped layouts as seed material. Only fields a user profile owns
## are copied: the file is app content, but the entries become user profiles
## and must not carry provenance claims or the authoring-only `id`.
func _load_defaults():
	_default_profiles = []
	var data := _read_file(DEFAULTS_FILE)
	var raw = _as_array(data, "profiles", [])
	if not (raw is Array):
		return
	for item in raw:
		if not (item is Dictionary):
			continue
		var name := str(item.get("name", ""))
		var tiles = item.get("tiles")
		if name == "" or not (tiles is Array):
			continue
		var profile := {"name": name, "tiles": tiles}
		if item.get("description") is String:
			profile["description"] = str(item["description"])
		_default_profiles.append(profile)

## Copy the shipped defaults into `profiles` once. Existing installs migrate
## on their first launch of this build: their store has no marker, so the two
## defaults are prepended and become deletable user rows. The marker is what
## keeps a deleted default deleted; it is not re-added on the next launch.
func _seed_defaults_once():
	if _seeded_defaults:
		return
	if _default_profiles.is_empty():
		# No seed file (a test store, or a build without defaults). Leave the
		# marker unset so a later app version that ships seeds can add them.
		return
	var existing := {}
	for profile in profiles:
		existing[str(profile.get("name", ""))] = true
	var seeded: Array[Dictionary] = []
	for profile in _default_profiles:
		var name := str(profile.get("name", ""))
		if name == "" or existing.has(name):
			continue
		seeded.append(profile.duplicate(true))
	var merged: Array[Dictionary] = []
	merged.append_array(seeded)
	merged.append_array(profiles)
	profiles = merged
	_seeded_defaults = true
	_derive_plugin_profiles()
	save_profiles()

## Where a profile was loaded from. Every dict `get_all_profiles()` answers
## carries one as `_origin`, and the consent gate (`Workspace._profile_consented`)
## branches on that stamp and nothing else — never on fields inside the
## profile, which a file can write.
const ORIGIN_PLUGIN := "plugin"
const ORIGIN_USER := "user"

## Identity fields a profile file may not claim. The loader that owns them
## stamps them after loading (`_derive_plugin_profiles` sets
## `plugin`/`plugin_id`/`revision`), so a user file that carries one is
## stripped here: consent is never looked up by a field the file chose.
## `builtin` stays in the list as a legacy claim a hand-edited file may carry;
## nothing stamps or branches on it any more.
const PROVENANCE_KEYS := ["builtin", "plugin", "plugin_id", "revision"]

func load_profiles():
	var d = _read_file(PROFILES_FILE)
	if d.is_empty():
		# A deleted or never-written store can seed again on the next call.
		_seeded_defaults = false
		return
	_seeded_defaults = _as_bool(d, "seeded_defaults", false)
	var raw: Array = _as_array(d, "profiles", [])
	profiles = []
	for item in raw:
		if item is Dictionary:
			var profile: Dictionary = item.duplicate(true)
			_strip_provenance(profile)
			profiles.append(profile)

## Remove whatever a file says about where it came from.
##
## Keys starting with `_` are this manager's own stamps (`_origin`,
## `_user_index`), so that rule covers a stamp added later instead of only the
## list above — a hand-written `"_origin": "builtin"` is stripped like
## `"builtin": true` is.
static func _strip_provenance(profile: Dictionary):
	for key in PROVENANCE_KEYS:
		profile.erase(key)
	for key in profile.keys():
		if key is String and key.begins_with("_"):
			profile.erase(key)

func save_profiles():
	var d = {"profiles": profiles, "seeded_defaults": _seeded_defaults}
	_write_file(PROFILES_FILE, d)
	profiles_changed.emit()

## Save one user profile. Returns the name the store kept: a name already
## spoken for by another user profile gets the same " (n)" suffix
## `rename_profile` gives, so a caller that saves twice under one name answers
## the row it actually created instead of the one it asked for. "" when the
## request names nothing (nothing is stored).
func add_profile(p_name: String, p_tiles: Array[Dictionary]) -> String:
	if p_name == "":
		return ""
	var result_name = p_name
	var base = p_name
	var n = 1
	while _name_exists(result_name):
		n += 1
		result_name = "%s (%d)" % [base, n]
	profiles.append({"name": result_name, "tiles": p_tiles})
	_derive_plugin_profiles()
	save_profiles()
	return result_name

func update_profile(index: int, p_name: String, p_tiles: Array[Dictionary]):
	if index < 0 or index >= profiles.size():
		return
	profiles[index] = {"name": p_name, "tiles": p_tiles}
	_derive_plugin_profiles()
	save_profiles()

func delete_profile(index: int):
	if index < 0 or index >= profiles.size():
		return
	profiles.remove_at(index)
	_derive_plugin_profiles()
	save_profiles()


## Rename a user profile by its index.
## Follows the add_profile dedupe convention: colliding names get a
## " (n)" suffix unless `replace_existing` is true, in which case the
## colliding user profile is removed and this one takes the bare name.
## Returns the final name, or "" when the index/name is invalid. Renaming to
## its own name is a no-op.
func rename_profile(index: int, p_name: String, replace_existing := false) -> String:
	if index < 0 or index >= profiles.size():
		return ""
	var base := p_name.strip_edges()
	if base == "" or base.length() > 128:
		return ""
	if base == str(profiles[index].get("name", "")):
		return base
	var target := find_user_profile(base)
	if target >= 0 and target != index:
		if not replace_existing:
			var result_name := base
			var n := 1
			while _name_exists(result_name):
				n += 1
				result_name = "%s (%d)" % [base, n]
			profiles[index]["name"] = result_name
			_derive_plugin_profiles()
			save_profiles()
			return result_name
		profiles.remove_at(target)
		if target < index:
			index -= 1
	profiles[index]["name"] = base
	_derive_plugin_profiles()
	save_profiles()
	return base

## Remove every user profile whose exact name is in `names`. Returns the
## removed names. One save and one plugin re-derive for the whole batch.
func delete_profiles_named(names: Array) -> Array[String]:
	var removed: Array[String] = []
	for i in range(profiles.size() - 1, -1, -1):
		var name := str(profiles[i].get("name", ""))
		if names.has(name):
			profiles.remove_at(i)
			removed.append(name)
	if not removed.is_empty():
		_derive_plugin_profiles()
		save_profiles()
	return removed

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
	_plugin_profile_entries = _parse_plugin_profiles()
	_derive_plugin_profiles()
	profiles_changed.emit()

## Derive the sidebar rows from the parsed entries, naming each against the
## names already spoken for: a user profile keeps the bare name and the plugin
## yields with ` (n)`, and among plugin profiles the first one wins. Split out
## from the refresh so it can run again *without* re-reading the store — a
## user profile added, renamed or deleted changes whose name wins, not the
## plugin's content, and without that re-run the sidebar shows two rows with
## one name for the rest of the session while `find_profile` resolves the
## colliding name to the user's row (users are listed first), so a click on
## the plugin's row — or `layoutLoad` by that name — would activate the user's
## profile.
func _derive_plugin_profiles():
	_plugin_profiles = []
	if not (_plugin_profile_entries is Array):
		return
	var raw: Array = _plugin_profile_entries
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

## The store's raw profile names for one plugin — not the deduped display
## names. A plugin-install replacement deletes a user profile only when the
## installed plugin actually ships that name.
func raw_plugin_profile_names(plugin_id: String) -> Array[String]:
	var names: Array[String] = []
	if not (_plugin_profile_entries is Array):
		return names
	for item in _plugin_profile_entries:
		if not (item is Dictionary):
			continue
		if str(item.get("plugin_id", "")) != plugin_id:
			continue
		var name := str(item.get("name", ""))
		var tiles = item.get("tiles")
		if name == "" or not (tiles is Array):
			continue
		if not names.has(name):
			names.append(name)
	return names

## Remove an installed plugin through the extension. Answers the parsed
## `{ok, id, warnings}` or `{ok: false, error}`; never raises. The caller owns
## the refresh order, so this only performs the store operation.
func uninstall_plugin(plugin_id: String) -> Dictionary:
	var raw := ""
	if plugin_uninstall_source.is_valid():
		raw = str(plugin_uninstall_source.call(plugin_id))
	else:
		raw = str(GptyTerminal.uninstall_plugin(plugin_id))
	var j := JSON.new()
	if j.parse(raw) != OK or not (j.get_data() is Dictionary):
		return {"ok": false, "error": "The plugin store answered an unreadable uninstall result"}
	return j.get_data()

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
## user profile keeps the bare name and the plugin yields with the " (n)"
## suffix, and among plugin profiles the first one wins.
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

## User profiles first (the seeded defaults are prepended to `profiles`, so
## they lead), then installed-plugin profiles — the order the sidebar renders
## and the order `find_profile` resolves a `layoutLoad` name in.
##
## This is also the one place that knows provenance, so it stamps `_origin` on
## every entry: it is what `Workspace._profile_consented` branches on, and a
## dict that did not come through here (a hand-written profile, a test fixture)
## has no stamp and is treated as user content.
func get_all_profiles() -> Array[Dictionary]:
	var all: Array[Dictionary] = []
	for i in profiles.size():
		var profile: Dictionary = profiles[i].duplicate(true)
		profile["_origin"] = ORIGIN_USER
		profile["_user_index"] = i
		all.append(profile)
	for plugin_profile in _plugin_profiles:
		var profile: Dictionary = plugin_profile.duplicate(true)
		profile["_origin"] = ORIGIN_PLUGIN
		all.append(profile)
	return all

func find_profile(p_name: String) -> Dictionary:
	for profile in get_all_profiles():
		if profile.get("name", "") == p_name:
			return profile
	return {}

func find_user_profile(p_name: String) -> int:
	for i in profiles.size():
		if profiles[i].get("name", "") == p_name:
			return i
	return -1

func _name_exists(p_name: String) -> bool:
	return find_user_profile(p_name) != -1
