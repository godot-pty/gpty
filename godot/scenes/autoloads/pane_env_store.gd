extends BasePersistenceManager
# PaneEnvStore — the user's own per-pane environment, keyed by attachment_id.
#
# `user://pane_env.json` is the ONLY place per-pane env lives, and only the
# pane settings UI writes it (the workspace's settings_applied handler is the
# single write path). Profiles and workspaces never carry env: a file must not
# be able to supply spawn-time authority, and this store is the property the
# *user* grants through the UI. See the v0.5.5 "User-owned pane environment"
# roadmap item.
#
# The file is still hand-editable, so the loader treats it like every other
# store: typed reads, an id-pattern key check, and size caps — a bad entry
# costs itself, not the file.

const ENV_FILE := "user://pane_env.json"

## Caps for hand-edited file content.
const MAX_ENTRIES := 128
const MAX_VALUE_CHARS := 4096

var _env: Dictionary = {}

func _on_init():
	reload()

func reload():
	_env = {}
	var d = _read_file(ENV_FILE)
	for key in d:
		if not (key is String) or not _valid_id(key):
			continue
		if _env.size() >= MAX_ENTRIES:
			break
		var value := _as_string(d, key, "")
		if value == "":
			continue
		if value.length() > MAX_VALUE_CHARS:
			value = value.left(MAX_VALUE_CHARS)
		_env[key] = value

## The pane's own env override, or "" when it inherits the global environment.
func env_for(id: String) -> String:
	return str(_env.get(id, ""))

func has_env(id: String) -> bool:
	return _env.has(id)

## The pane settings UI's write path. An empty value removes the entry, so a
## cleared override falls back to the global environment.
func set_env(id: String, text: String):
	if not _valid_id(id):
		return
	var trimmed := text.strip_edges()
	if trimmed == "":
		remove_env(id)
		return
	if trimmed.length() > MAX_VALUE_CHARS:
		trimmed = trimmed.left(MAX_VALUE_CHARS)
	_env[id] = trimmed
	_write_file(ENV_FILE, _env)

func remove_env(id: String):
	if _env.has(id):
		_env.erase(id)
		_write_file(ENV_FILE, _env)

## attachment_id shape — the same `[a-z][a-z0-9_-]{0,31}` the pane sanitizer
## enforces, so an entry can never outlive the ids the panes actually carry.
static func _valid_id(id: String) -> bool:
	var re := RegEx.create_from_string("^[a-z][a-z0-9_-]{0,31}$")
	return re.search(id) != null
