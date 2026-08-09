extends BasePersistenceManager

const CONCEPTS_FILE = "user://concepts.json"
const DEFAULTS_FILE = "res://concepts.default.json"

signal concepts_changed

func _on_init():
	# Defer push — GDExtension may not be registered yet during autoload init
	call_deferred("_push_to_rust")

func _push_to_rust():
	var concepts = _merge_concepts()
	# Filter out disabled concepts before pushing to Rust
	var enabled_only: Array = []
	for c in concepts:
		if c is Dictionary and c.get("enabled", true) == true:
			enabled_only.append(c)
	print("[ConceptManager] Pushing %d enabled concepts (of %d total)" % [enabled_only.size(), concepts.size()])
	if enabled_only.is_empty():
		return
	var t = GptyTerminal.new()
	t.set_global_concepts(enabled_only)

func _merge_concepts() -> Array:
	var defaults = _load_defaults()
	var user = _load_from_file()
	# Build a name→index map for user concepts
	var user_map := {}
	for i in user.size():
		var c = user[i]
		if c is Dictionary:
			user_map[c.get("name", "")] = i
	# Deep-merge: start with default fields, overlay user fields
	var merged: Array = []
	for d in defaults:
		if not (d is Dictionary):
			continue
		var name = d.get("name", "")
		if name in user_map:
			# Start from default, then overlay every user key
			var entry: Dictionary = d.duplicate(true)
			var u = user[user_map[name]]
			if u is Dictionary:
				for key in u.keys():
					entry[key] = u[key]
			# Migrate old default triggers to the new patterns
			_migrate_trigger(entry, d)
			merged.append(entry)
		else:
			merged.append(d)
	# Append user-only concepts (not in defaults)
	for i in user.size():
		var c = user[i]
		if not (c is Dictionary):
			continue
		# Already merged above — skip
		if c.get("name", "") in _default_names(defaults):
			continue
		merged.append(c)
	return merged

func _default_names(defaults: Array) -> Dictionary:
	var names := {}
	for d in defaults:
		if d is Dictionary:
			names[d.get("name", "")] = true
	return names

func _load_defaults() -> Array:
	if not FileAccess.file_exists(DEFAULTS_FILE):
		return []
	var f = FileAccess.open(DEFAULTS_FILE, FileAccess.READ)
	if not f:
		return []
	var text = f.get_as_text()
	var json = JSON.new()
	var err = json.parse(text)
	if err != OK:
		return []
	var data = json.get_data()
	if not (data is Dictionary):
		return []
	var raw = data.get("concepts", [])
	if not (raw is Array):
		return []
	var result: Array = []
	for item in raw:
		if item is Dictionary:
			result.append(item)
	return result

func _load_from_file() -> Array:
	var d = _read_file(CONCEPTS_FILE)
	if d.is_empty():
		return []
	var raw = d.get("concepts", [])
	if not (raw is Array):
		return []
	return raw

## Return merged concepts with enabled status for IPC/MCP.
func get_concepts() -> Array:
	return _merge_concepts()

## Toggle a concept's enabled flag in the user overrides file.
func toggle_concept(name: String) -> bool:
	# Find the current enabled state from merged concepts
	var merged = _merge_concepts()
	var current_enabled = true
	for c in merged:
		if c is Dictionary and c.get("name", "") == name:
			current_enabled = c.get("enabled", true)
			break
	var new_enabled = not current_enabled
	var user = _load_from_file()
	var found = false
	for c in user:
		if c is Dictionary and c.get("name", "") == name:
			c["enabled"] = new_enabled
			found = true
			break
	if not found:
		var entry: Dictionary = {"name": name, "enabled": new_enabled}
		user.append(entry)
	save_concepts(user)
	return true


func save_concepts(concepts: Array):
	var d = {"concepts": concepts}
	_write_file(CONCEPTS_FILE, d)
	concepts_changed.emit()

# Migrate old default trigger patterns to the new ones.
const TRIGGER_MIGRATIONS := {
	"cat_command": {"old": ["^cat\\s+", "\\bcat\\s+\\S"], "new": "(?:^|[$#>]\\s)\\bcat\\s+\\S"},
	"git_diff":     {"old": ["^git\\s+diff", "\\bgit\\s+diff"], "new": "(?:^|[$#>]\\s)\\bgit\\s+diff"},
}

func _migrate_trigger(entry: Dictionary, default: Dictionary):
	var name: String = entry.get("name", "")
	if not name in TRIGGER_MIGRATIONS:
		return
	var mig = TRIGGER_MIGRATIONS[name]
	var trigger: String = entry.get("trigger", "")
	var olds: Array = mig["old"] if mig["old"] is Array else [mig["old"]]
	if trigger in olds:
		entry["trigger"] = mig["new"]
